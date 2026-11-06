import AVFoundation
import AppKit
import Foundation
import RecorderKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var projects: [VideoProject] = ProjectLayout.loadAll()
    @Published var selectedProjectID: UUID? {
        didSet { workspaceSession.selectedProject = selectedProjectID; saveSession() }
    }
    @Published var stage: WorkStage = .record {
        didSet {
            if let id = selectedProjectID {
                workspaceSession.editors[id, default: EditorSession()].stage = stage
                saveSession()
            }
        }
    }
    @Published var toast: String?
    @Published var error: String?
    @Published var exportingProjects: Set<UUID> = []
    @Published var lastExports: [UUID: URL] = [:]
    @Published var exportProgress: [UUID: ExportProgress] = [:]
    @Published var taskPhases: [UUID: String] = [:]
    @Published private var undoRevision = 0
    private var undoManagers: [UUID: UndoManager] = [:]
    private var workspaceSession = WorkspaceSession.load()
    private var lastSessionSave = Date.distantPast
    private var motionTasks: [UUID: Task<Void, Never>] = [:]
    private var transcriptTasks: [UUID: Task<Void, Never>] = [:]
    private var motionQueue: [(UUID, UUID)] = []
    private var activeMotion: UUID?

    var currentProject: VideoProject? { projects.first { $0.id == selectedProjectID } }
    init() {
        // Interrupted jobs are explicit failures after a restart; never imply completion.
        for i in projects.indices {
            let original = projects[i]
            for j in projects[i].materials.indices {
                if !projects[i].materials[j].subtitles.isEmpty,
                   projects[i].materials[j].subtitleLayoutVersion != SubtitleSegmentation.version {
                    let material = projects[i].materials[j]
                    let metadata = ProjectLayout.materialDirectory(material, in: projects[i]).appendingPathComponent("transcript.json")
                    let saved = (try? Data(contentsOf: metadata)).flatMap { try? JSONDecoder().decode([TranscriptSegment].self, from: $0) }
                    let source = saved.flatMap { SubtitleSegmentation.sameSpeech($0, material.subtitles) ? $0 : nil } ?? material.subtitles
                    projects[i].materials[j].subtitles = SubtitleSegmentation.split(source)
                    projects[i].materials[j].subtitleLayoutVersion = SubtitleSegmentation.version
                }
                if projects[i].materials[j].exportState == .running {
                    projects[i].materials[j].exportState = .failed
                    projects[i].materials[j].exportError = "上次素材导出中断，请在录制编辑器重新导出。"
                }
                if [.running, .queued].contains(projects[i].materials[j].motionState) {
                    projects[i].materials[j].motionState = .failed
                    projects[i].materials[j].motionError = "动效处理已中断，可重试。"
                }
                if projects[i].materials[j].transcriptState == .running {
                    if projects[i].materials[j].subtitles.isEmpty {
                        projects[i].materials[j].transcriptState = .failed
                        projects[i].materials[j].transcriptError = "字幕识别已中断，可重试。"
                    } else {
                        projects[i].materials[j].transcriptState = .complete
                        projects[i].materials[j].transcriptWarning = "字幕处理已中断，已保留已有字幕，可重试。"
                    }
                }
            }
            if projects[i] != original {
                do { try ProjectLayout.save(projects[i]) }
                catch { self.error = "保存任务恢复状态失败：\(error.localizedDescription)" }
            }
        }
        selectedProjectID = workspaceSession.selectedProject.flatMap { id in projects.contains(where: { $0.id == id }) ? id : nil }
        stage = selectedProjectID.flatMap { workspaceSession.editors[$0]?.stage } ?? .record
        for project in projects {
            if let name = project.lastExportName, name == URL(fileURLWithPath: name).lastPathComponent {
                let url = ProjectLayout.url(name, for: project)
                if FileManager.default.fileExists(atPath: url.path) { lastExports[project.id] = url }
            }
        }
    }
    func editorSession(_ id: UUID) -> EditorSession { workspaceSession.editors[id] ?? EditorSession() }
    func rememberEditor(_ id: UUID, _ session: EditorSession, flush: Bool = false) {
        workspaceSession.editors[id] = session
        if flush || Date().timeIntervalSince(lastSessionSave) > 2 { saveSession() }
    }
    func saveSession() {
        do { try workspaceSession.save(); lastSessionSave = Date() }
        catch { self.error = "保存工作位置失败：\(error.localizedDescription)" }
    }
    private func history(_ id: UUID) -> UndoManager {
        if let manager = undoManagers[id] { return manager }
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.levelsOfUndo = 100
        undoManagers[id] = manager
        return manager
    }
    private func registerUndo(_ id: UUID, name: String, action: @escaping @MainActor (AppState) -> Void) {
        let manager = history(id)
        let grouping = !manager.isUndoing && !manager.isRedoing
        if grouping { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { state in MainActor.assumeIsolated { action(state) } }
        manager.setActionName(name)
        if grouping { manager.endUndoGrouping() }
        undoRevision += 1
    }
    var canUndo: Bool { guard let id = selectedProjectID else { return false }; return history(id).canUndo }
    var canRedo: Bool { guard let id = selectedProjectID else { return false }; return history(id).canRedo }
    func undo() { guard let id = selectedProjectID else { return }; history(id).undo(); undoRevision += 1 }
    func redo() { guard let id = selectedProjectID else { return }; history(id).redo(); undoRevision += 1 }

    func createProject(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = VideoProject(name: trimmed.isEmpty ? "未命名项目" : trimmed)
        do {
            try ProjectLayout.save(project)
            projects.insert(project, at: 0)
            select(project.id)
        } catch { self.error = error.localizedDescription }
    }
    func select(_ id: UUID) {
        selectedProjectID = id
        stage = editorSession(id).stage
        guard let project = currentProject else { return }
        for material in project.materials where material.exportState == .complete {
            Task {
                if material.duration <= 0 {
                    if let duration = await RoughCutService.duration(of: ProjectLayout.source(material, in: project)), duration.isFinite, duration > 0 {
                        updateMaterial(id, material.id) { $0.duration = duration }
                    }
                }
                if material.transcriptState == .idle { transcribe(id, material.id) }
            }
        }
    }
    func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if toast == message { toast = nil }
        }
    }
    @discardableResult
    func updateProject(_ id: UUID, _ mutate: (inout VideoProject) -> Void) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return false }
        var project = projects[index]
        mutate(&project)
        project.updatedAt = Date()
        do { try ProjectLayout.save(project); projects[index] = project; return true }
        catch { self.error = "保存失败：\(error.localizedDescription)"; return false }
    }
    private func updateMaterial(_ projectID: UUID, _ id: UUID, _ mutate: (inout Material) -> Void) {
        guard let (_, original) = pair(projectID, id) else { return }
        updateProject(projectID) { project in
            guard let index = project.materials.firstIndex(where: { $0.id == original.id }) else { return }
            mutate(&project.materials[index])
            let changed = project.materials[index]
            // Timeline cuts share one recording and one processing job; editorial ranges stay independent.
            for sibling in project.materials.indices where sibling != index && project.materials[sibling].mediaID == original.mediaID {
                if original.motionState != changed.motionState || original.motionError != changed.motionError {
                    project.materials[sibling].motionState = changed.motionState
                    project.materials[sibling].motionError = changed.motionError
                }
                if original.transcriptState != changed.transcriptState || original.subtitles != changed.subtitles || original.transcriptWarning != changed.transcriptWarning {
                    project.materials[sibling].transcriptState = changed.transcriptState
                    project.materials[sibling].transcriptError = changed.transcriptError
                    project.materials[sibling].transcriptWarning = changed.transcriptWarning
                    if original.subtitles != changed.subtitles {
                        project.materials[sibling].subtitles = changed.subtitles
                        project.materials[sibling].subtitleLayoutVersion = changed.subtitleLayoutVersion
                    }
                }
            }
        }
    }
    private func pair(_ projectID: UUID, _ id: UUID) -> (VideoProject, Material)? {
        guard let project = projects.first(where: { $0.id == projectID }),
              let material = project.materials.first(where: { $0.id == id }) ?? project.materials.first(where: { $0.mediaID == id }) else { return nil }
        return (project, material)
    }
    func record() {
        guard let projectID = selectedProjectID else { return }
        WorkspaceRecorder.shared.exportSheetStyle = { content in
            AnyView(ThemedContent { StudioSheetSurface { content } })
        }
        WorkspaceRecorder.shared.exportPrimaryActionStyle = { content in
            AnyView(content.buttonStyle(StudioButtonStyle(kind: .primary)))
        }
        WorkspaceRecorder.shared.present { [weak self] id, wantsMotion in
            guard let self, let project = self.projects.first(where: { $0.id == projectID }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            if wantsMotion, SettingsStore.shared.resolvedLaunchPath() == "/bin/true" {
                throw ShellError.exitStatus(-1, "AI 动效尚未配置，请先在设置中选择执行器，或关闭动效后继续。")
            }
            var material = Material()
            material.id = id
            material.wantsMotion = wantsMotion
            material.motionState = wantsMotion ? .queued : .idle
            try FileManager.default.createDirectory(at: ProjectLayout.materialDirectory(material, in: project), withIntermediateDirectories: true)
            var updated = project
            updated.materials.append(material)
            updated.updatedAt = Date()
            try ProjectLayout.save(updated)
            if let i = self.projects.firstIndex(where: { $0.id == projectID }) { self.projects[i] = updated }
            return ProjectLayout.source(material, in: project)
        } onFinish: { [weak self] id, result in
            guard let self else { return }
            switch result {
            case .success(let url):
                Task {
                    let duration = await RoughCutService.duration(of: url) ?? 0
                    guard duration > 0, duration.isFinite else {
                        self.updateMaterial(projectID, id) { $0.exportState = .failed; $0.exportError = "导出的视频无法读取。" }
                        return
                    }
                    self.updateMaterial(projectID, id) { $0.duration = duration; $0.exportState = .complete }
                    await self.lockCanvas(projectID)
                    self.processMaterial(projectID, id)
                    if self.selectedProjectID == projectID {
                        var session = self.editorSession(projectID)
                        session.stage = .assemble
                        session.selectedMaterial = id
                        session.playhead = self.projects.first(where: { $0.id == projectID })?.materials.prefix { $0.id != id }.reduce(0) { $0 + $1.timelineDuration } ?? 0
                        self.rememberEditor(projectID, session, flush: true)
                        self.stage = .assemble
                    }
                    self.showToast("素材已添加")
                }
            case .failure(let error):
                self.updateMaterial(projectID, id) { $0.exportState = .failed; $0.exportError = error.localizedDescription }
            }
        }
    }
    func processMaterial(_ projectID: UUID, _ id: UUID) {
        guard let (_, material) = pair(projectID, id), material.exportState == .complete else { return }
        if material.transcriptState != .complete { transcribe(projectID, id) }
        if material.wantsMotion && material.motionState != .complete { enqueueMotion(projectID, id) }
    }
    func transcribe(_ projectID: UUID, _ id: UUID) {
        guard let (project, material) = pair(projectID, id), transcriptTasks[material.mediaID] == nil, material.exportState == .complete else { return }
        let taskID = material.mediaID
        taskPhases[taskID] = "提取声音"
        updateMaterial(projectID, taskID) { $0.transcriptState = .running; $0.transcriptError = nil; $0.transcriptWarning = nil }
        let model = SettingsStore.shared.whisperModel()
        let language = SettingsStore.shared.whisperLanguage
        let correction = SettingsStore.shared.transcriptCorrectionConfiguration()
        transcriptTasks[taskID] = Task { [self] in
            defer { transcriptTasks[taskID] = nil; taskPhases[taskID] = nil }
            do {
                let directory = ProjectLayout.materialDirectory(material, in: project)
                let result = try await TranscriptService.transcribe(video: ProjectLayout.source(material, in: project), directory: directory, whisperModel: model, language: language, correction: correction, onPhase: { [weak self] phase in
                    Task { @MainActor in
                        guard let self, self.transcriptTasks[taskID] != nil,
                              self.pair(projectID, taskID)?.1.transcriptState == .running else { return }
                        self.taskPhases[taskID] = phase
                    }
                })
                try Task.checkCancellation()
                history(projectID).removeAllActions(); undoRevision += 1
                updateMaterial(projectID, taskID) { $0.subtitles = result.segments; $0.subtitleLayoutVersion = SubtitleSegmentation.version; $0.transcriptWarning = result.warning; $0.transcriptState = .complete }
            } catch {
                guard !Task.isCancelled else { return }
                updateMaterial(projectID, taskID) { $0.transcriptState = .failed; $0.transcriptError = error.localizedDescription }
            }
        }
    }
    func correctSubtitles(_ projectID: UUID, _ id: UUID) {
        guard let (project, material) = pair(projectID, id), transcriptTasks[material.mediaID] == nil,
              material.transcriptState == .complete, !material.subtitles.isEmpty else { return }
        guard let configuration = SettingsStore.shared.transcriptCorrectionConfiguration() else {
            showToast("请在字幕设置中开启 AI 校正。")
            return
        }
        let taskID = material.mediaID
        taskPhases[taskID] = "校正字幕"
        updateMaterial(projectID, taskID) { $0.transcriptState = .running; $0.transcriptWarning = nil; $0.transcriptError = nil }
        transcriptTasks[taskID] = Task { [self] in
            defer { transcriptTasks[taskID] = nil; taskPhases[taskID] = nil }
            do {
                let directory = ProjectLayout.materialDirectory(material, in: project)
                let raw = directory.appendingPathComponent("transcript-raw.json")
                if !FileManager.default.fileExists(atPath: raw.path) {
                    try JSONEncoder().encode(material.subtitles).write(to: raw, options: .atomic)
                }
                let result = try await TranscriptCorrection.apply(material.subtitles,
                    video: ProjectLayout.picture(material, in: project), directory: directory, configuration: configuration)
                try Task.checkCancellation()
                history(projectID).removeAllActions(); undoRevision += 1
                let segments = SubtitleSegmentation.split(result.segments)
                try JSONEncoder().encode(segments).write(to: directory.appendingPathComponent("transcript.json"), options: .atomic)
                updateMaterial(projectID, taskID) { $0.subtitles = segments; $0.subtitleLayoutVersion = SubtitleSegmentation.version; $0.transcriptState = .complete; $0.transcriptWarning = result.warning }
            } catch {
                guard !Task.isCancelled else { return }
                updateMaterial(projectID, taskID) { $0.transcriptState = .complete; $0.transcriptWarning = "字幕校正未完成，已保留已有字幕，可重试。" }
            }
        }
    }
    func enqueueMotion(_ projectID: UUID, _ id: UUID) {
        guard let (_, material) = pair(projectID, id), material.sourceReady,
              activeMotion != material.mediaID, !motionQueue.contains(where: { $0.1 == material.mediaID }) else { return }
        updateMaterial(projectID, id) { $0.wantsMotion = true; $0.useOriginal = false; $0.motionState = .queued; $0.motionError = nil }
        motionQueue.append((projectID, material.mediaID))
        runNextMotion()
    }
    private func runNextMotion() {
        guard activeMotion == nil, !motionQueue.isEmpty else { return }
        let (projectID, id) = motionQueue.removeFirst()
        guard let (project, material) = pair(projectID, id) else { runNextMotion(); return }
        activeMotion = id
        updateMaterial(projectID, id) { $0.motionState = .running }
        motionTasks[id] = Task {
            defer { motionTasks[id] = nil; activeMotion = nil; runNextMotion() }
            do {
                let source = ProjectLayout.source(material, in: project)
                let output = ProjectLayout.motion(material, in: project)
                let temporary = output.deletingLastPathComponent().appendingPathComponent("motion-pending.mp4")
                try? FileManager.default.removeItem(at: temporary)
                let brief = output.deletingLastPathComponent().appendingPathComponent("motion-brief.txt")
                try "为输入视频叠加 Remotion 讲解动效，保留原有声音、画面内容和全部时间关系，不改变时长。输入：\(source.path)。输出：\(temporary.path)。".write(to: brief, atomically: true, encoding: .utf8)
                let settings = SettingsStore.shared
                let launch = settings.resolvedLaunchPath()
                guard launch != "/bin/true" else { throw ShellError.exitStatus(-1, "请在设置中配置可用的 AI agent。") }
                _ = try await Shell.run(launch, arguments: settings.aiMotionArguments(source1: source, source2: temporary, brief: brief), workingDirectory: output.deletingLastPathComponent(), timeout: 1800)
                try Task.checkCancellation()
                guard let duration = await RoughCutService.duration(of: temporary), duration.isFinite,
                      abs(duration - material.duration) <= 0.1 else {
                    throw ShellError.exitStatus(-1, "动效视频缺失或时长与原片不同，请重试。")
                }
                let sourceAudio = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)
                let motionAudio = try await AVURLAsset(url: temporary).loadTracks(withMediaType: .audio)
                guard sourceAudio.isEmpty || !motionAudio.isEmpty else {
                    throw ShellError.exitStatus(-1, "动效结果丢失了原片声音，已停止使用该结果，请重试。")
                }
                try Task.checkCancellation()
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: temporary, to: output)
                updateMaterial(projectID, id) { $0.motionState = .complete }
            } catch {
                guard !Task.isCancelled else { return }
                updateMaterial(projectID, id) { $0.motionState = .failed; $0.motionError = error.localizedDescription }
            }
        }
    }
    func cancelProcessing(_ projectID: UUID, _ id: UUID, motion: Bool) {
        guard let (_, material) = pair(projectID, id) else { return }
        let taskID = material.mediaID
        if motion {
            motionQueue.removeAll { $0.0 == projectID && $0.1 == taskID }
            motionTasks[taskID]?.cancel()
            updateMaterial(projectID, id) { $0.motionState = .failed; $0.motionError = "动效已取消，可重试。"; $0.useOriginal = true }
        } else {
            transcriptTasks[taskID]?.cancel()
            updateMaterial(projectID, id) {
                $0.transcriptState = $0.subtitles.isEmpty ? .failed : .complete
                $0.transcriptError = $0.subtitles.isEmpty ? "字幕已取消，可重试或关闭字幕导出。" : nil
                $0.transcriptWarning = $0.subtitles.isEmpty ? nil : "已取消处理，保留已有字幕。"
            }
        }
    }
    func setUseOriginal(_ projectID: UUID, _ id: UUID, _ value: Bool) {
        guard let (_, material) = pair(projectID, id), (material.useOriginal ?? false) != value else { return }
        let old = material.useOriginal ?? false
        if updateProject(projectID, { p in p.materials[p.materials.firstIndex { $0.id == id }!].useOriginal = value }) {
            registerUndo(projectID, name: "切换原片") { $0.setUseOriginal(projectID, id, old) }
        }
    }
    func setIncludeSubtitles(_ projectID: UUID, _ value: Bool) {
        guard let project = projects.first(where: { $0.id == projectID }), project.includeSubtitles != value else { return }
        if updateProject(projectID, { $0.includeSubtitles = value }) {
            registerUndo(projectID, name: "字幕导出") { $0.setIncludeSubtitles(projectID, project.includeSubtitles) }
        }
    }
    func editSubtitle(projectID: UUID, materialID: UUID, index: Int, text: String) {
        guard let (_, material) = pair(projectID, materialID), material.subtitles.indices.contains(index),
              material.transcriptState != .running, material.subtitles[index].text != text else { return }
        let old = material.subtitles[index].text
        if updateProject(projectID, { p in
            p.materials[p.materials.firstIndex { $0.id == materialID }!].subtitles[index].text = text
        }) {
            registerUndo(projectID, name: "修改字幕") { $0.editSubtitle(projectID: projectID, materialID: materialID, index: index, text: old) }
        }
    }
    @discardableResult
    func setSubtitleTiming(_ projectID: UUID, _ id: UUID, index: Int, start: Double, end: Double) -> Bool {
        guard let (_, material) = pair(projectID, id), material.transcriptState != .running,
              material.subtitles.indices.contains(index), start.isFinite, end.isFinite,
              start >= 0, end <= material.duration, end - start >= 1 / 30 - 0.000_001,
              index == 0 || start >= material.subtitles[index - 1].end,
              index + 1 == material.subtitles.count || end <= material.subtitles[index + 1].start else { return false }
        let old = material.subtitles[index]
        guard old.start != start || old.end != end else { return true }
        let saved = updateProject(projectID) { p in
            let i = p.materials.firstIndex { $0.id == id }!
            p.materials[i].subtitles[index].start = start
            p.materials[i].subtitles[index].end = end
        }
        if saved {
            registerUndo(projectID, name: "调整字幕时间") { _ = $0.setSubtitleTiming(projectID, id, index: index, start: old.start, end: old.end) }
        }
        return saved
    }
    @discardableResult
    func setTrim(_ projectID: UUID, _ id: UUID, start: Double, end: Double) -> Bool {
        guard let (_, material) = pair(projectID, id), material.sourceReady, start.isFinite, end.isFinite,
              start >= 0, end <= material.duration, end - start >= 1 / 30 - 0.000_001 else { return false }
        let oldStart = material.inPoint, oldEnd = material.outPoint
        guard start != oldStart || end != oldEnd else { return true }
        let saved = updateProject(projectID) { p in
            let i = p.materials.firstIndex { $0.id == id }!
            p.materials[i].trimStart = start
            p.materials[i].trimEnd = end
        }
        if saved { registerUndo(projectID, name: "裁剪素材") { _ = $0.setTrim(projectID, id, start: oldStart, end: oldEnd) } }
        return saved
    }
    @discardableResult
    func splitMaterial(_ projectID: UUID, _ id: UUID, at sourceTime: Double, rightID: UUID = UUID()) -> UUID? {
        guard let (project, material) = pair(projectID, id), material.sourceReady,
              sourceTime.isFinite, sourceTime - material.inPoint >= 1 / 30 - 0.000_001,
              material.outPoint - sourceTime >= 1 / 30 - 0.000_001,
              !project.materials.contains(where: { $0.id == rightID }) else { return nil }
        var right = material
        right.id = rightID; right.storageID = material.mediaID; right.trimStart = sourceTime
        let saved = updateProject(projectID) { p in
            let index = p.materials.firstIndex { $0.id == material.id }!
            p.materials[index].trimEnd = sourceTime
            p.materials.insert(right, at: index + 1)
        }
        guard saved else { return nil }
        registerUndo(projectID, name: "分割素材") {
            $0.joinSplit(projectID, left: material.id, right: rightID, start: material.inPoint, end: material.outPoint, cut: sourceTime)
        }
        return rightID
    }
    private func joinSplit(_ projectID: UUID, left: UUID, right: UUID, start: Double, end: Double, cut: Double) {
        guard let project = projects.first(where: { $0.id == projectID }), project.materials.contains(where: { $0.id == left }),
              project.materials.contains(where: { $0.id == right }) else { return }
        if updateProject(projectID, { p in
            p.materials.removeAll { $0.id == right }
            let index = p.materials.firstIndex { $0.id == left }!
            p.materials[index].trimStart = start; p.materials[index].trimEnd = end
        }) {
            registerUndo(projectID, name: "分割素材") { _ = $0.splitMaterial(projectID, left, at: cut, rightID: right) }
        }
    }
    func setCanvas(_ projectID: UUID, width: Double?, height: Double?) {
        guard let project = projects.first(where: { $0.id == projectID }),
              project.canvasWidth != width || project.canvasHeight != height else { return }
        if let width, let height {
            guard width.isFinite, height.isFinite, width >= 2, height >= 2, width <= 7680, height <= 7680 else { return }
        } else if width != nil || height != nil { return }
        if updateProject(projectID, { $0.canvasWidth = width; $0.canvasHeight = height }) {
            registerUndo(projectID, name: "修改画幅") { $0.setCanvas(projectID, width: project.canvasWidth, height: project.canvasHeight) }
        }
    }
    func lockCanvas(_ projectID: UUID) async {
        guard let project = projects.first(where: { $0.id == projectID }), project.canvasWidth == nil,
              !project.materials.isEmpty, project.materials.allSatisfy(\.isReady),
              let assembly = try? await ExportService.assemble(project: project) else { return }
        updateProject(projectID) {
            guard $0.canvasWidth == nil else { return }
            $0.canvasWidth = assembly.size.width; $0.canvasHeight = assembly.size.height
        }
    }
    @discardableResult
    func removeMaterial(_ projectID: UUID, _ id: UUID) -> Bool {
        guard let index = projects.firstIndex(where: { $0.id == projectID }),
              let material = projects[index].materials.first(where: { $0.id == id }),
              material.exportState != .running, !exportingProjects.contains(projectID) else { return false }
        let position = projects[index].materials.firstIndex { $0.id == id }!
        var updated = projects[index]
        updated.materials.removeAll { $0.id == id }
        updated.updatedAt = Date()
        do {
            try ProjectLayout.save(updated)
        } catch {
            self.error = "删除素材失败：\(error.localizedDescription)"
            return false
        }
        projects[index] = updated
        registerUndo(projectID, name: "删除素材") { $0.restoreMaterial(projectID, material, at: position) }
        if !updated.materials.contains(where: { $0.mediaID == material.mediaID }) {
            motionQueue.removeAll { $0.0 == projectID && $0.1 == material.mediaID }
            motionTasks[material.mediaID]?.cancel()
            transcriptTasks[material.mediaID]?.cancel()
        }
        showToast("素材已从项目删除")
        return true
    }
    private func restoreMaterial(_ projectID: UUID, _ material: Material, at index: Int) {
        guard let project = projects.first(where: { $0.id == projectID }),
              !project.materials.contains(where: { $0.id == material.id }), !exportingProjects.contains(projectID) else { return }
        var restored = material
        if let sibling = project.materials.first(where: { $0.mediaID == material.mediaID }) {
            restored.motionState = sibling.motionState; restored.motionError = sibling.motionError
            if restored.transcriptState == .running {
                restored.transcriptState = sibling.transcriptState; restored.subtitles = sibling.subtitles
                restored.transcriptWarning = sibling.transcriptWarning; restored.transcriptError = sibling.transcriptError
            }
        }
        if [.queued, .running].contains(restored.motionState), motionTasks[material.mediaID] == nil { restored.motionState = .failed; restored.motionError = "动效已取消，可重试。" }
        if restored.transcriptState == .running, transcriptTasks[material.mediaID] == nil {
            restored.transcriptState = restored.subtitles.isEmpty ? .failed : .complete
            restored.transcriptError = restored.subtitles.isEmpty ? "字幕已取消，可重试。" : nil
        }
        if updateProject(projectID, { $0.materials.insert(restored, at: min(index, $0.materials.count)) }) {
            registerUndo(projectID, name: "恢复素材") { _ = $0.removeMaterial(projectID, material.id) }
        }
    }
    func moveMaterial(_ projectID: UUID, index: Int, by delta: Int) {
        guard let project = projects.first(where: { $0.id == projectID }),
              project.materials.indices.contains(index), project.materials.indices.contains(index + delta) else { return }
        var ids = project.materials.map(\.id)
        ids.swapAt(index, index + delta)
        setOrder(projectID, ids)
    }
    func reorderMaterial(_ projectID: UUID, source: UUID, target: UUID, after: Bool) {
        guard source != target, let project = projects.first(where: { $0.id == projectID }),
              project.materials.contains(where: { $0.id == source }), let index = project.materials.firstIndex(where: { $0.id == target }) else { return }
        var ids = project.materials.map(\.id)
        ids.removeAll { $0 == source }
        let destination = ids.firstIndex(of: project.materials[index].id)!
        ids.insert(source, at: destination + (after ? 1 : 0))
        setOrder(projectID, ids)
    }
    private func setOrder(_ projectID: UUID, _ ids: [UUID]) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        let old = project.materials.map(\.id)
        guard old != ids else { return }
        if updateProject(projectID, { p in
            let lookup = Dictionary(uniqueKeysWithValues: p.materials.map { ($0.id, $0) })
            p.materials = ids.compactMap { lookup[$0] } + p.materials.filter { !ids.contains($0.id) }
        }) { registerUndo(projectID, name: "排序素材") { $0.setOrder(projectID, old) } }
    }
    func export() {
        guard let project = currentProject, project.canExport, !exportingProjects.contains(project.id) else { return }
        exportingProjects.insert(project.id)
        let progress = ExportProgress()
        exportProgress[project.id] = progress
        Task {
            defer { exportingProjects.remove(project.id); exportProgress[project.id] = nil }
            do {
                let output = try await ExportService.export(project: project, progress: progress)
                lastExports[project.id] = output
                updateProject(project.id) {
                    $0.lastExportName = output.lastPathComponent
                    $0.lastExportSRTName = project.exportSRT == true ? output.deletingPathExtension().appendingPathExtension("srt").lastPathComponent : nil
                }
                showToast("导出完成")
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch is CancellationError { showToast("导出已取消") }
            catch { self.error = "导出失败：\(error.localizedDescription)" }
        }
    }
}
