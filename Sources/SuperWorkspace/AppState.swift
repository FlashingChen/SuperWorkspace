import AVFoundation
import AppKit
import Foundation
import RecorderKit
import SwiftUI
import Vision

/// Diagnostic timing for one motion dispatch, written next to the material.
private struct MotionTiming: Codable {
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Double
    let attempts: Int
    let error: String?
}

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
    @Published var motionPhases: [UUID: String] = [:]
    @Published var subtitleReviews: [UUID: SubtitleReview] = [:]
    @Published var reviewingProjects: Set<UUID> = []
    @Published var reviewPhases: [UUID: String] = [:]
    @Published private var undoRevision = 0
    private var undoManagers: [UUID: UndoManager] = [:]
    private var workspaceSession = WorkspaceSession.load()
    private var lastSessionSave = Date.distantPast
    private var motionTasks: [UUID: Task<Void, Never>] = [:]
    private var activeMotions: Set<UUID> = []
    private var motionAttempts: [UUID: Int] = [:]
    private var motionStartedAt: [UUID: Date] = [:]
    private var transcriptTasks: [UUID: Task<Void, Never>] = [:]
    private var aiEditTasks: [UUID: Task<Void, Never>] = [:]
    private var reviewTasks: [UUID: Task<Void, Never>] = [:]
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
            if let review = SubtitleReview.load(for: project) { subtitleReviews[project.id] = review }
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
    @discardableResult
    private func updateMaterial(_ projectID: UUID, _ id: UUID, _ mutate: (inout Material) -> Void) -> Bool {
        guard let (_, original) = pair(projectID, id) else { return false }
        return updateProject(projectID) { project in
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
    func pair(_ projectID: UUID, _ id: UUID) -> (VideoProject, Material)? {
        guard let project = projects.first(where: { $0.id == projectID }),
              let material = project.materials.first(where: { $0.id == id }) ?? project.materials.first(where: { $0.mediaID == id }) else { return nil }
        return (project, material)
    }
    func record() {
        guard let projectID = selectedProjectID else { return }
        let recorder = WorkspaceRecorder.shared
        if recorder.hasOpenSession {
            recorder.bringToFront()
            return
        }
        let transition = WorkspaceRecordingTransition.shared
        transition.prepare()
        recorder.returnActionStyle = { content in
            AnyView(ThemedContent {
                content.buttonStyle(StudioButtonStyle(kind: .secondary, size: .compact))
            })
        }
        recorder.exportSheetStyle = { content in
            AnyView(ThemedContent { StudioSheetSurface { content } })
        }
        recorder.exportPrimaryActionStyle = { content in
            AnyView(content.buttonStyle(StudioButtonStyle(kind: .primary)))
        }
        recorder.exportPromptField = { prompt in
            AnyView(VStack(alignment: .leading, spacing: Metrics.space2) {
                Text("剪辑提示词").font(.studio(.bodyMedium))
                TextField("例如：讲到结论时加入关键词动效", text: prompt, axis: .vertical)
                    .textFieldStyle(StudioTextFieldStyle())
                    .lineLimit(3...5)
                    .accessibilityLabel("剪辑提示词")
            })
        }
        recorder.present(onPresent: transition.collapse, onReturn: transition.restore) { [weak self] id, wantsMotion, editingPrompt, wantsAIEditing in
            guard let self, let project = self.projects.first(where: { $0.id == projectID }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            if wantsMotion, !SettingsStore.shared.hasAIConnection {
                throw ShellError.exitStatus(-1, "AI 动效尚未配置，请先在设置中连接 API 或选择执行器。")
            }
            if wantsAIEditing, !project.referenceMedia.isEmpty, !SettingsStore.shared.hasAIConnection {
                throw ShellError.exitStatus(-1, "AI 剪辑尚未配置，请先在设置中连接 API 或选择执行器。")
            }
            var material = Material()
            material.id = id
            material.wantsMotion = wantsMotion
            material.editingPrompt = editingPrompt
            material.wantsAIEditing = wantsAIEditing
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
                    self.startAIEditing(projectID, id)
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
    /// The recorder sheet's "AI 剪辑" choice is fixed onto the material while this recording
    /// finishes, so the final assembly uses the chosen cutaways instead of planning again.
    /// Manual retry after a failed plan: the recording and its subtitles are already there.
    func retryAIEditing(_ projectID: UUID, _ id: UUID) {
        startAIEditing(projectID, id)
    }

    private func startAIEditing(_ projectID: UUID, _ id: UUID) {
        guard let (project, material) = pair(projectID, id), material.wantsAIEditing == true,
              material.exportState == .complete, aiEditTasks[material.mediaID] == nil else { return }
        // With motion enabled the library is composed into the clip itself; planning cutaways
        // again would show every asset twice.
        guard material.wantsMotion == false else { return }
        guard !project.referenceMedia.isEmpty else {
            // No library assets: nothing to consult, and the choice must not block the export.
            updateMaterial(projectID, id) { $0.inserts = []; $0.aiEditWarning = nil }
            return
        }
        let taskID = material.mediaID
        aiEditTasks[taskID] = Task { [self] in
            defer {
                aiEditTasks[taskID] = nil
                if taskPhases[taskID] == "AI 剪辑" { taskPhases[taskID] = nil }
            }
            // The plan reads the transcript; wait for this recording's own instead of planning blind.
            if let transcript = transcriptTasks[taskID] { await transcript.value }
            guard !Task.isCancelled, let (project, current) = pair(projectID, id) else { return }
            taskPhases[taskID] = "AI 剪辑"
            let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: work) }
                // Only this recording and the library matter for a record-time plan.
                var scope = project
                scope.materials = [current]
                let plan = try await AIEditing.plan(scope, in: work)
                try Task.checkCancellation()
                guard let (latestProject, latest) = pair(projectID, id) else { return }
                let assets = Dictionary(uniqueKeysWithValues: latestProject.referenceMedia.map { ($0.id, $0) })
                let inserts = AIEditing.validatedInserts(plan.inserts, clipID: latest.id,
                                                         clipStart: latest.inPoint, clipEnd: latest.outPoint,
                                                         library: assets)
                updateMaterial(projectID, id) { $0.inserts = inserts; $0.aiEditWarning = nil }
                if !inserts.isEmpty { showToast("AI 剪辑已插入 \(inserts.count) 处画面") }
            } catch {
                guard !Task.isCancelled else { return }
                // The recording stays usable: the film can still be exported from the original picture.
                updateMaterial(projectID, id) {
                    $0.inserts = []
                    $0.aiEditWarning = "AI 剪辑未完成，已保留素材原样：\(error.localizedDescription)"
                }
            }
        }
    }
    func transcribe(_ projectID: UUID, _ id: UUID) {
        guard let (project, material) = pair(projectID, id), transcriptTasks[material.mediaID] == nil, material.exportState == .complete else { return }
        let taskID = material.mediaID
        invalidateSubtitleReview(projectID)
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
        invalidateSubtitleReview(projectID)
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
              motionTasks[material.mediaID] == nil, !motionQueue.contains(where: { $0.1 == material.mediaID }) else { return }
        motionAttempts[material.mediaID] = 0
        motionStartedAt[material.mediaID] = Date()
        updateMaterial(projectID, id) { $0.wantsMotion = true; $0.useOriginal = false; $0.motionState = .queued; $0.motionError = nil }
        motionQueue.append((projectID, material.mediaID))
        runNextMotion()
    }
    private func runNextMotion() {
        let limit = max(1, min(4, SettingsStore.shared.motionConcurrency))
        guard !motionQueue.isEmpty, activeMotions.count < limit else { return }
        let (projectID, id) = motionQueue.removeFirst()
        guard let (project, material) = pair(projectID, id) else { runNextMotion(); return }
        activeMotions.insert(id)
        activeMotion = id
        updateMaterial(projectID, id) { $0.motionState = .running }
        motionPhases[id] = "准备动效"
        let startedAt = motionStartedAt[id] ?? Date()
        motionStartedAt[id] = startedAt
        motionTasks[id] = Task {
            defer {
                motionTasks[id] = nil
                activeMotions.remove(id)
                activeMotion = activeMotions.first
                motionPhases[id] = nil
                runNextMotion()
            }
            let output = ProjectLayout.motion(material, in: project)
            let directory = output.deletingLastPathComponent()
            do {
                let source = ProjectLayout.source(material, in: project)
                let temporary = directory.appendingPathComponent("motion-pending.mp4")
                try? FileManager.default.removeItem(at: temporary)
                let settings = SettingsStore.shared
                let brief = directory.appendingPathComponent("motion-brief.txt")
                let context = "为输入视频叠加 Remotion 讲解动效，保留原有声音、画面内容和全部时间关系，不改变时长。输入：\(source.path)。输出：\(temporary.path)。"
                var description = context
                if let direction = material.editingPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !direction.isEmpty {
                    description += "\n剪辑提示词：\(direction)"
                }
                if let subtitles = Self.subtitleExcerpt(material.subtitles, limit: 2000), !subtitles.isEmpty {
                    description += "\n已有字幕（按时间顺序，仅用于理解内容，不要重新识别）：\n\(subtitles)"
                }
                // Pre-analyse the picture and hand over frames, so the agent never scans the clip itself.
                let supportsImages = settings.selectedAgent == .api && settings.aiAPIImages
                motionPhases[id] = "预分析画面"
                let analysis = await MotionPreanalysis.analyze(source: source)
                var attachments: [EmbeddedPi.ImageAttachment] = []
                if let analysis {
                    if let json = analysis.json {
                        try? json.write(to: directory.appendingPathComponent("motion-analysis.json"))
                    }
                    // On-screen wording follows the narration, not the language of the prompt template.
                if let detected = MotionLanguage.detect(from: material.subtitles) {
                    description += "\n" + detected.language.instruction(latinShare: detected.latinShare)
                } else {
                    description += "\n口播语言：未识别，画面文字按口播实际语言写，不要默认中文。"
                }
                // Facts come from the analyser; what may be drawn where comes from the policy.
                    // Keeping them apart means a new editorial rule is a one-line change here.
                    var policy = MotionPreanalysis.MotionPolicy.standard
                    // Quality first: let the whole clip animate, keeping a sane ceiling.
                    policy.maxOnScreenSeconds = min(600.0, max(20.0, analysis.duration * 0.6))
                    description += "\n" + policy.prompt(for: analysis)
                    if supportsImages {
                        attachments = analysis.keyframes.prefix(12).map {
                            EmbeddedPi.ImageAttachment(data: $0.data, mimeType: "image/jpeg")
                        }
                        if !analysis.keyframes.isEmpty {
                            let times = analysis.keyframes.prefix(12).map { String(format: "%.1f", $0.time) }.joined(separator: "、")
                            description += "\n附件依次为 t=\(times)s 的源帧，每个画面分区一张，无需再抽帧。"
                        }
                    }
                }
                // Library assets travel with the motion task: the agent designs their背景 and
                // animation inside the composition, so the picture is ready at material stage.
                let libraryAssets = project.referenceMedia
                if !libraryAssets.isEmpty {
                    var lines: [String] = []
                    var libraryImages: [EmbeddedPi.ImageAttachment] = []
                    for media in libraryAssets.prefix(4) where supportsImages && libraryImages.count < 4 {
                        let url = ProjectLayout.reference(media, in: project)
                        if let frame = await ReferenceMediaPreview.frame(media, at: url, maxSize: 720),
                           let jpeg = NSBitmapImageRep(cgImage: frame).representation(using: .jpeg,
                                                                                      properties: [.compressionFactor: 0.8]) {
                            libraryImages.append(.init(data: jpeg, mimeType: "image/jpeg"))
                            lines.append("素材库图片 \(libraryImages.count)：\(media.name)"
                                + (media.description.isEmpty ? "" : "（\(media.description)）"))
                        }
                    }
                    if !libraryImages.isEmpty {
                        let base = attachments.count
                        description += "\n素材库（这些内容属于本条素材，需要时直接渲染进镜头，不要等后期合成）：\n"
                            + lines.joined(separator: "\n")
                        description += "\n附件第 \(base + 1)–\(base + libraryImages.count) 张依次对应上面列出的素材库图片。"
                        description += "\n用到素材库图片时自己设计背景与入退场动画，保持原图比例、不得拉伸，禁止纯黑底直接贴图。"
                        attachments += libraryImages
                    }
                }
                if supportsImages, attachments.isEmpty {
                    motionPhases[id] = "提取关键帧"
                    let frames = await MotionInput.keyframes(from: source)
                    attachments = frames.map { EmbeddedPi.ImageAttachment(data: $0.data, mimeType: "image/jpeg") }
                    if !frames.isEmpty {
                        let times = frames.map { String(format: "%.1f", $0.time) }.joined(separator: "、")
                        description += "\n附件依次为 t=\(times)s 的源帧（取自输入视频，已转正）。"
                    }
                }
                try description.write(to: brief, atomically: true, encoding: .utf8)
                let onProgress: @Sendable (EmbeddedPi.Progress) -> Void = { [weak self] progress in
                    guard let label = AppState.motionPhaseLabel(progress) else { return }
                    Task { @MainActor in
                        guard let self, self.motionTasks[id] != nil else { return }
                        self.motionPhases[id] = label
                    }
                }
                // Long clips need proportionally more render time; the shell timeout always outlives the budget.
                let budget = Self.motionBudget(for: material.duration)
                if settings.selectedAgent == .api {
                    let connection = try settings.apiConnection()
                    let request = try settings.motionRequest(source1: source, source2: temporary, brief: brief)
                    let reply = try await EmbeddedPi.run(connection, system: request.system, prompt: request.prompt,
                                                 directory: directory, tools: true, images: supportsImages,
                                                 attachments: attachments,
                                                 timeout: TimeInterval(budget.minutes * 60 + 600),
                                                 budgetMinutes: budget.minutes, budgetToolCalls: budget.toolCalls,
                                                 onProgress: onProgress)
                    try? reply.data(using: .utf8)?.write(to: directory.appendingPathComponent("agent-response.txt"), options: .atomic)
                } else {
                    let launch = settings.resolvedLaunchPath()
                    guard launch != "/bin/true" else { throw ShellError.exitStatus(-1, "请在设置中连接内置 Pi 或配置 Claude。") }
                    let reply = try await Shell.run(launch, arguments: settings.claudeMotionArguments(source1: source, source2: temporary, brief: brief),
                                            workingDirectory: directory, timeout: TimeInterval(budget.minutes * 60 + 600))
                    try? reply.data(using: .utf8)?.write(to: directory.appendingPathComponent("agent-response.txt"), options: .atomic)
                }
                try Task.checkCancellation()
                let result = AVURLAsset(url: temporary)
                guard let (playable, duration) = try? await result.load(.isPlayable, .duration),
                      playable, duration.seconds.isFinite, abs(duration.seconds - material.duration) <= 0.1,
                      let video = try? await result.loadTracks(withMediaType: .video), !video.isEmpty else {
                    throw ShellError.exitStatus(-1, "动效视频缺失、无法播放或时长与原片不同，请重试。")
                }
                let sourceAudio = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)
                let motionAudio = try await result.loadTracks(withMediaType: .audio)
                guard sourceAudio.isEmpty || !motionAudio.isEmpty else {
                    throw ShellError.exitStatus(-1, "动效结果丢失了原片声音，已停止使用该结果，请重试。")
                }
                try Task.checkCancellation()
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: temporary, to: output)
                let attempts = (motionAttempts[id] ?? 0) + 1
                writeMotionTiming(directory, startedAt: startedAt, attempts: attempts, error: nil)
                motionAttempts[id] = nil
                motionStartedAt[id] = nil
                updateMaterial(projectID, id) { $0.motionState = .complete }
            } catch {
                let message = error.localizedDescription
                motionPhases[id] = nil
                if Task.isCancelled {
                    writeMotionTiming(directory, startedAt: startedAt, attempts: (motionAttempts[id] ?? 0) + 1, error: "已取消")
                    motionAttempts[id] = nil
                    motionStartedAt[id] = nil
                    return
                }
                let attempts = (motionAttempts[id] ?? 0) + 1
                motionAttempts[id] = attempts
                // One automatic retry for transient transport failures; never after a user cancel.
                if attempts < 2, Self.isTransientMotionFailure(message), pair(projectID, id) != nil,
                   !motionQueue.contains(where: { $0.1 == id }) {
                    motionPhases[id] = "连接中断，3 秒后重试"
                    updateMaterial(projectID, id) { $0.motionState = .queued; $0.motionError = nil }
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    motionQueue.append((projectID, id))
                    return
                }
                writeMotionTiming(directory, startedAt: startedAt, attempts: attempts, error: message)
                motionAttempts[id] = nil
                motionStartedAt[id] = nil
                updateMaterial(projectID, id) { $0.motionState = .failed; $0.motionError = message }
            }
        }
    }
    /// The product target is a ten-minute turnaround, so the agent budget leaves room for the
    /// final render: it is nudged to wrap up at 70% of it and hard-stopped at 100%.
    /// The ceiling is the user's choice, not the app's: 40 minutes by default, adjustable in 设置.
    @MainActor
    static func motionBudget(for duration: Double) -> (minutes: Int, toolCalls: Int) {
        let configured = SettingsStore.shared.motionTimeLimitMinutes
        let minutes = max(5, min(240, configured))
        let seconds = duration.isFinite ? max(0, duration) : 0
        let toolCalls = min(1200, 260 + Int(seconds * 2))
        return (minutes, toolCalls)
    }
    private func writeMotionTiming(_ directory: URL, startedAt: Date, attempts: Int, error: String?) {
        let endedAt = Date()
        let timing = MotionTiming(startedAt: startedAt, endedAt: endedAt,
                                  durationSeconds: max(0, endedAt.timeIntervalSince(startedAt)),
                                  attempts: attempts, error: error)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do { try encoder.encode(timing).write(to: directory.appendingPathComponent("motion-timing.json"), options: .atomic) }
        catch { }
    }
    private nonisolated static func subtitleExcerpt(_ subtitles: [TranscriptSegment], limit: Int) -> String? {
        let joined = subtitles.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        guard !joined.isEmpty else { return nil }
        return joined.count <= limit ? joined : String(joined.prefix(limit))
    }
    private nonisolated static func isTransientMotionFailure(_ message: String) -> Bool {
        let text = message.lowercased()
        // Budget stops and validation failures are final; only transport hiccups are worth a retry.
        guard !text.contains("超出预算"), !text.contains("缺失、无法播放或时长与原片不同"),
              !text.contains("丢失了原片声音") else { return false }
        let patterns = ["connection lost", "unexpected eof", "eof", "timeout", "超时", "429", "502", "503", "504",
                        "network", "aborted", "request aborted", "overloaded", "rate limit", "中断"]
        return patterns.contains { text.contains($0) }
    }
    private nonisolated static func motionPhaseLabel(_ progress: EmbeddedPi.Progress) -> String? {
        switch progress.type {
        case "start": return "准备动效"
        case "turn": return progress.n.map { "第 \($0) 轮" } ?? "模型处理中"
        case "tool":
            let name = progress.name ?? "工具"
            guard let detail = progress.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty else {
                return "运行 \(name)"
            }
            return "运行 \(name)：\(detail.prefix(24))"
        case "retry": return "模型重试 \(progress.attempt ?? 1)/\(progress.max ?? 3)"
        case "retry_end": return "模型重试成功，继续动效"
        case "budget": return "超出预算，正在中止"
        case "wrap_up": return "时间提醒：正在收尾"
        case "done": return "收尾"
        default: return nil
        }
    }
    func cancelProcessing(_ projectID: UUID, _ id: UUID, motion: Bool) {
        guard let (_, material) = pair(projectID, id) else { return }
        let taskID = material.mediaID
        if motion {
            motionQueue.removeAll { $0.0 == projectID && $0.1 == taskID }
            motionTasks[taskID]?.cancel()
            motionPhases[taskID] = nil
            motionAttempts[taskID] = nil
            motionStartedAt[taskID] = nil
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
        if updateMaterial(projectID, materialID, { $0.subtitles[index].text = text }) {
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
        let saved = updateMaterial(projectID, id) {
            $0.subtitles[index].start = start
            $0.subtitles[index].end = end
        }
        if saved {
            registerUndo(projectID, name: "调整字幕时间") { _ = $0.setSubtitleTiming(projectID, id, index: index, start: old.start, end: old.end) }
        }
        return saved
    }

    // MARK: - Manual caption edits

    @discardableResult
    func insertSubtitle(_ projectID: UUID, _ materialID: UUID, at sourceTime: Double) -> Int? {
        guard let (_, material) = pair(projectID, materialID), material.transcriptState == .complete,
              let subtitle = SubtitleEditing.insertion(at: sourceTime, in: material),
              let updated = SubtitleEditing.inserting(subtitle, into: material.subtitles),
              commitSubtitles(projectID, materialID, updated, name: "新增字幕") else { return nil }
        return updated.firstIndex { $0.start == subtitle.start && $0.end == subtitle.end }
    }

    @discardableResult
    func deleteSubtitle(_ projectID: UUID, _ materialID: UUID, index: Int) -> Bool {
        guard let (_, material) = pair(projectID, materialID),
              let updated = SubtitleEditing.removing(material.subtitles, at: index) else { return false }
        return commitSubtitles(projectID, materialID, updated, name: "删除字幕")
    }

    @discardableResult
    func mergeSubtitle(_ projectID: UUID, _ materialID: UUID, index: Int) -> Bool {
        guard let (_, material) = pair(projectID, materialID), index + 1 < material.subtitles.count else { return false }
        let next = material.subtitles[index + 1]
        guard next.end > material.inPoint, next.start < material.outPoint,
              let updated = SubtitleEditing.merging(material.subtitles, at: index) else { return false }
        return commitSubtitles(projectID, materialID, updated, name: "合并字幕")
    }

    @discardableResult
    func splitSubtitle(_ projectID: UUID, _ materialID: UUID, index: Int, at sourceTime: Double) -> Bool {
        guard let (_, material) = pair(projectID, materialID),
              let updated = SubtitleEditing.splitting(material.subtitles, at: index, time: sourceTime) else { return false }
        return commitSubtitles(projectID, materialID, updated, name: "分割字幕")
    }

    @discardableResult
    private func commitSubtitles(_ projectID: UUID, _ materialID: UUID,
                                 _ edited: [TranscriptSegment], name: String) -> Bool {
        guard let (_, material) = pair(projectID, materialID), material.transcriptState != .running,
              edited != material.subtitles else { return false }
        let old = material.subtitles
        guard updateMaterial(projectID, materialID, {
            $0.subtitles = edited
            $0.subtitleLayoutVersion = SubtitleSegmentation.version
        }) else { return false }
        registerUndo(projectID, name: name) { $0.restoreSubtitles(projectID, materialID, old, name: name) }
        return true
    }

    private func restoreSubtitles(_ projectID: UUID, _ materialID: UUID,
                                  _ subtitles: [TranscriptSegment], name: String) {
        guard let (_, material) = pair(projectID, materialID), material.subtitles != subtitles else { return }
        let old = material.subtitles
        guard updateMaterial(projectID, materialID, {
            $0.subtitles = subtitles
            $0.subtitleLayoutVersion = SubtitleSegmentation.version
        }) else { return }
        registerUndo(projectID, name: name) { $0.restoreSubtitles(projectID, materialID, old, name: name) }
    }

    // MARK: - Subtitle review

    func resolvedSubtitleIssues(_ projectID: UUID) -> [ResolvedSubtitleIssue] {
        guard let project = projects.first(where: { $0.id == projectID }) else { return [] }
        return SubtitleReviewer.resolvedIssues(subtitleReviews[projectID], in: project)
    }

    func reviewSubtitles(_ projectID: UUID) {
        guard reviewTasks[projectID] == nil else { return }
        guard let project = projects.first(where: { $0.id == projectID }),
              project.materials.contains(where: { $0.transcriptState != .running && !$0.subtitles.isEmpty }) else {
            showToast("还没有可复核的字幕。")
            return
        }
        let configuration = SettingsStore.shared.subtitleReviewConfiguration()
        let directory = ProjectLayout.directory(for: project)
        reviewingProjects.insert(projectID)
        reviewPhases[projectID] = configuration == nil ? "本地检查字幕" : "重建字幕"
        reviewTasks[projectID] = Task { [self] in
            defer {
                reviewTasks[projectID] = nil
                reviewingProjects.remove(projectID)
                reviewPhases[projectID] = nil
            }
            do {
                let phase: @Sendable (String) -> Void = { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.reviewTasks[projectID] != nil else { return }
                        self.reviewPhases[projectID] = text
                    }
                }
                if let configuration {
                    let rebuild = try await SubtitleReviewer.rebuild(project: project, directory: directory,
                                                                     configuration: configuration, onPhase: phase)
                    try Task.checkCancellation()
                    let result = applySubtitleRebuild(rebuild, projectID: projectID)
                    subtitleReviews[projectID] = result
                    if let current = projects.first(where: { $0.id == projectID }) { try? result.save(for: current) }
                    let summary = result.rebuild ?? RebuildSummary()
                    if summary.materials > 0 {
                        showToast("复核完成：已重组 \(summary.materials) 个素材，\(summary.before) → \(summary.after) 条字幕。")
                    } else if summary.failed > 0 {
                        showToast("复核完成：\(summary.failed) 个素材未重建，已保留原字幕。")
                    } else if summary.skipped > 0 {
                        showToast("复核完成：\(summary.skipped) 个素材因复核期间被修改而跳过。")
                    } else {
                        showToast("复核完成，字幕无需调整。")
                    }
                } else {
                    var result = try await SubtitleReviewer.review(project: project, directory: directory,
                                                                  configuration: nil, onPhase: phase)
                    try Task.checkCancellation()
                    result = applySubtitleReviewFixes(result, projectID: projectID)
                    subtitleReviews[projectID] = result
                    if let current = projects.first(where: { $0.id == projectID }) { try? result.save(for: current) }
                    let current = projects.first(where: { $0.id == projectID }) ?? project
                    let remaining = SubtitleReviewer.resolvedIssues(result, in: current).count
                    let fixed = result.applied.count
                    if fixed > 0, remaining > 0 {
                        showToast("复核完成：已自动修正 \(fixed) 处，\(remaining) 处需要留意。")
                    } else if fixed > 0 {
                        showToast("复核完成：已自动修正 \(fixed) 处。")
                    } else if remaining > 0 {
                        showToast("复核完成：\(remaining) 处需要留意。")
                    } else {
                        showToast("复核完成，未发现明显问题。")
                    }
                }
            } catch is CancellationError {
                // Invalidation (a new recognition run) cancels silently; a manual cancel is
                // visible in the panel closing, so no toast is needed.
            } catch {
                showToast("复核未完成：\(error.localizedDescription)")
            }
        }
    }

    func cancelSubtitleReview(_ projectID: UUID) {
        reviewTasks[projectID]?.cancel()
    }

    func clearSubtitleReview(_ projectID: UUID) {
        subtitleReviews[projectID] = nil
        if let project = projects.first(where: { $0.id == projectID }) { SubtitleReview.deleteFile(for: project) }
    }

    func dismissSubtitleReviewIssue(_ projectID: UUID, _ issueID: UUID) {
        guard var review = subtitleReviews[projectID] else { return }
        review.issues.removeAll { $0.id == issueID }
        subtitleReviews[projectID] = review
        if let project = projects.first(where: { $0.id == projectID }) { try? review.save(for: project) }
    }

    /// Applies the rebuilt tracks in one undoable edit. A recording that was edited while the
    /// model was working is left alone instead of being overwritten.
    @discardableResult
    func applySubtitleRebuild(_ rebuild: SubtitleRebuild, projectID: UUID) -> SubtitleReview {
        var review = rebuild.review
        guard let project = projects.first(where: { $0.id == projectID }) else { return review }
        var oldSnapshots: [UUID: [TranscriptSegment]] = [:]
        var newSnapshots: [UUID: [TranscriptSegment]] = [:]
        var summary = review.rebuild ?? RebuildSummary()
        var applied = 0, before = 0, after = 0, skipped = 0
        for (mediaID, track) in rebuild.tracks {
            let group = project.materials.filter { $0.mediaID == mediaID }
            guard let original = rebuild.originals[mediaID], !group.isEmpty,
                  group.allSatisfy({ $0.transcriptState != .running && $0.subtitles == original }) else {
                skipped += 1
                continue
            }
            for material in group {
                oldSnapshots[material.id] = material.subtitles
                newSnapshots[material.id] = track
            }
            applied += 1
            before += original.count
            after += track.count
        }
        if !newSnapshots.isEmpty {
            guard setSubtitleSnapshots(projectID, newSnapshots) else { return review }
            registerUndo(projectID, name: "AI 重组字幕") {
                $0.restoreSubtitleSnapshots(projectID, oldSnapshots, name: "AI 重组字幕")
            }
        }
        summary.materials = applied
        summary.before = before
        summary.after = after
        summary.skipped += skipped
        review.rebuild = summary
        if skipped > 0 {
            let message = "\(skipped) 个素材在复核期间被修改，已跳过并保留原字幕。"
            review.note = [review.note, message].compactMap { $0 }.joined(separator: " ")
        }
        return review
    }

    /// Applies verified text fixes and the merges the review asked for, as one undoable edit.
    /// Findings that cannot be rewritten safely stay in the report and remain informational.
    @discardableResult
    func applySubtitleReviewFixes(_ review: SubtitleReview, projectID: UUID) -> SubtitleReview {
        guard let project = projects.first(where: { $0.id == projectID }) else { return review }
        struct TextFix {
            let mediaID: UUID
            let start: Double
            let before: String
            let after: String
        }
        struct JoinFix {
            let mediaID: UUID
            let materialID: UUID
            let start: Double
            let direction: SubtitleReviewIssue.Join
        }
        func captionKey(_ mediaID: UUID, _ start: Double) -> String {
            "\(mediaID)-\(Int((start * 1000).rounded()))"
        }

        var textFixes: [TextFix] = []
        var textChanges: [AppliedSubtitleFix] = []
        var textAfterByKey: [String: String] = [:]
        var seenText: Set<String> = []
        for issue in review.issues {
            guard issue.kind == .text, let replacement = issue.replacement,
                  let material = project.materials.first(where: { $0.id == issue.materialID }),
                  material.transcriptState != .running,
                  let index = issue.resolvedIndex(in: material) else { continue }
            let current = material.subtitles[index].text
            guard let safe = SubtitleReviewer.validatedReplacement(current, replacement),
                  safe != current else { continue }
            let start = material.subtitles[index].start
            let key = captionKey(material.mediaID, start)
            guard seenText.insert(key).inserted else { continue }
            textFixes.append(TextFix(mediaID: material.mediaID, start: start, before: current, after: safe))
            textChanges.append(AppliedSubtitleFix(materialID: material.id, index: index, start: start,
                                                  before: current, after: safe))
            textAfterByKey[key] = safe
        }

        var joinFixes: [JoinFix] = []
        var seenJoin: Set<String> = []
        for issue in review.issues {
            guard issue.kind == .segmentation, let direction = issue.join,
                  let material = project.materials.first(where: { $0.id == issue.materialID }),
                  material.transcriptState != .running,
                  let index = material.subtitles.firstIndex(where: { abs($0.start - issue.start) < 0.02 })
            else { continue }
            let start = material.subtitles[index].start
            let key = "\(captionKey(material.mediaID, start))-\(direction.rawValue)"
            guard seenJoin.insert(key).inserted else { continue }
            joinFixes.append(JoinFix(mediaID: material.mediaID, materialID: material.id,
                                     start: start, direction: direction))
        }

        guard !textFixes.isEmpty || !joinFixes.isEmpty else { return review }

        var oldSnapshots: [UUID: [TranscriptSegment]] = [:]
        var newSnapshots: [UUID: [TranscriptSegment]] = [:]
        var mergedChanges: [AppliedSubtitleFix] = []
        var mergedCaptionKeys: Set<String> = []
        var appliedJoinKeys: Set<String> = []
        for material in project.materials {
            let fixes = textFixes.filter { $0.mediaID == material.mediaID }
            let joins = joinFixes.filter { $0.mediaID == material.mediaID }
            guard !fixes.isEmpty || !joins.isEmpty else { continue }
            var subtitles = material.subtitles
            var changed = false
            for fix in fixes {
                guard let index = subtitles.firstIndex(where: {
                    abs($0.start - fix.start) < 0.02 && $0.text == fix.before
                }) else { continue }
                subtitles[index].text = fix.after
                changed = true
            }
            for join in joins {
                guard let index = subtitles.firstIndex(where: { abs($0.start - join.start) < 0.02 }) else { continue }
                let mergeIndex = join.direction == .previous ? index - 1 : index
                guard mergeIndex >= 0, mergeIndex + 1 < subtitles.count,
                      let merged = SubtitleEditing.merging(subtitles, at: mergeIndex) else { continue }
                let before = "\(subtitles[mergeIndex].text) + \(subtitles[mergeIndex + 1].text)"
                let after = merged[mergeIndex].text
                let mergedStart = merged[mergeIndex].start
                subtitles = merged
                changed = true
                appliedJoinKeys.insert("\(captionKey(material.mediaID, join.start))-\(join.direction.rawValue)")
                mergedCaptionKeys.insert(captionKey(material.mediaID, join.start))
                mergedCaptionKeys.insert(captionKey(material.mediaID, mergedStart))
                let alreadyRecorded = mergedChanges.contains {
                    $0.materialID == join.materialID && abs($0.start - mergedStart) < 0.02 && $0.after == after
                }
                if !alreadyRecorded {
                    mergedChanges.append(AppliedSubtitleFix(materialID: join.materialID, index: mergeIndex,
                                                            start: mergedStart, before: before, after: after))
                }
            }
            guard changed else { continue }
            oldSnapshots[material.id] = material.subtitles
            newSnapshots[material.id] = subtitles
        }
        guard !newSnapshots.isEmpty, setSubtitleSnapshots(projectID, newSnapshots),
              let updated = projects.first(where: { $0.id == projectID }) else { return review }
        registerUndo(projectID, name: "AI 复核修正") {
            $0.restoreSubtitleSnapshots(projectID, oldSnapshots, name: "AI 复核修正")
        }

        var result = review
        // A text fix on a line that was merged away is represented by the merge entry instead.
        result.applied = (textChanges + mergedChanges).filter { fix in
            guard let material = updated.materials.first(where: { $0.id == fix.materialID }) else { return false }
            return material.subtitles.contains {
                abs($0.start - fix.start) < 0.02 && $0.text == fix.after
            }
        }
        var remaining: [SubtitleReviewIssue] = []
        for var issue in review.issues {
            guard let material = updated.materials.first(where: { $0.id == issue.materialID }) else { continue }
            let key = captionKey(material.mediaID, issue.start)
            if issue.kind == .text, textAfterByKey[key] != nil { continue }
            if issue.kind == .segmentation, let direction = issue.join,
               appliedJoinKeys.contains("\(key)-\(direction.rawValue)") { continue }
            if let after = textAfterByKey[key], issue.kind != .text {
                issue.text = after
            }
            if mergedCaptionKeys.contains(key) { continue }
            guard issue.resolvedIndex(in: material) != nil else { continue }
            remaining.append(issue)
        }
        result.issues = remaining
        return result
    }

    @discardableResult
    private func setSubtitleSnapshots(_ projectID: UUID, _ snapshots: [UUID: [TranscriptSegment]]) -> Bool {
        updateProject(projectID) { project in
            for index in project.materials.indices {
                guard let subtitles = snapshots[project.materials[index].id] else { continue }
                project.materials[index].subtitles = subtitles
                project.materials[index].subtitleLayoutVersion = SubtitleSegmentation.version
            }
        }
    }

    private func restoreSubtitleSnapshots(_ projectID: UUID, _ snapshots: [UUID: [TranscriptSegment]], name: String) {
        guard let project = projects.first(where: { $0.id == projectID }), !snapshots.isEmpty else { return }
        var before: [UUID: [TranscriptSegment]] = [:]
        for material in project.materials where snapshots[material.id] != nil {
            before[material.id] = material.subtitles
        }
        guard !before.isEmpty, before != snapshots, setSubtitleSnapshots(projectID, snapshots) else { return }
        registerUndo(projectID, name: name) { $0.restoreSubtitleSnapshots(projectID, before, name: name) }
    }

    /// A new recognition or correction replaces the reviewed text, so the old report no longer
    /// describes the project.
    private func invalidateSubtitleReview(_ projectID: UUID) {
        cancelSubtitleReview(projectID)
        clearSubtitleReview(projectID)
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
            aiEditTasks[material.mediaID]?.cancel()
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
    func export(projectID: UUID) {
        guard let project = projects.first(where: { $0.id == projectID }),
              project.canExport, !exportingProjects.contains(project.id) else { return }
        exportingProjects.insert(project.id)
        let progress = ExportProgress()
        exportProgress[project.id] = progress
        progress.task = Task {
            defer {
                progress.task = nil
                exportingProjects.remove(project.id)
                exportProgress[project.id] = nil
            }
            do {
                let output = try await exportMovie(project, progress: progress)
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

    private func exportMovie(_ project: VideoProject, progress: ExportProgress) async throws -> URL {
        var output = project
        // Cutaways fixed while each recording was exported; they apply even with the toggle off.
        let library = Dictionary(uniqueKeysWithValues: project.referenceMedia.map { ($0.id, $0) })
        var inserts = project.materials.flatMap { material in
            AIEditing.validatedInserts(material.inserts ?? [], clipID: material.id,
                                       clipStart: material.inPoint, clipEnd: material.outPoint,
                                       library: library)
        }
        if inserts.isEmpty, project.exportWithAIEditing == true {
            progress.phase = "AI 正在规划剪辑"
            let files = FileManager.default
            let work = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try files.createDirectory(at: work, withIntermediateDirectories: false)
            defer { try? files.removeItem(at: work) }
            let plan = try await AIEditing.plan(project, in: work)
            try AIEditing.apply(plan, to: &output)
            inserts = plan.inserts
        }
        progress.phase = "正在导出"
        return try await ExportService.export(project: output, progress: progress, inserts: inserts)
    }
}
