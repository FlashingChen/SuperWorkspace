import AVFoundation
import AppKit
import Foundation
import RecorderKit

@MainActor
final class AppState: ObservableObject {
    @Published var projects: [VideoProject] = ProjectLayout.loadAll()
    @Published var selectedProjectID: UUID?
    @Published var stage: WorkStage = .record
    @Published var toast: String?
    @Published var error: String?
    @Published var exportingProjects: Set<UUID> = []
    @Published var lastExports: [UUID: URL] = [:]
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
    }
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
        stage = .record
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
    func updateProject(_ id: UUID, _ mutate: (inout VideoProject) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        var project = projects[index]
        mutate(&project)
        project.updatedAt = Date()
        do { try ProjectLayout.save(project); projects[index] = project }
        catch { self.error = "保存失败：\(error.localizedDescription)" }
    }
    private func updateMaterial(_ projectID: UUID, _ id: UUID, _ mutate: (inout Material) -> Void) {
        updateProject(projectID) { project in
            if let index = project.materials.firstIndex(where: { $0.id == id }) { mutate(&project.materials[index]) }
        }
    }
    private func pair(_ projectID: UUID, _ id: UUID) -> (VideoProject, Material)? {
        guard let project = projects.first(where: { $0.id == projectID }),
              let material = project.materials.first(where: { $0.id == id }) else { return nil }
        return (project, material)
    }
    func record() {
        guard let projectID = selectedProjectID else { return }
        WorkspaceRecorder.shared.present { [weak self] id, wantsMotion in
            guard let self, let project = self.projects.first(where: { $0.id == projectID }) else {
                throw CocoaError(.fileNoSuchFile)
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
                    self.processMaterial(projectID, id)
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
        guard transcriptTasks[id] == nil, let (project, material) = pair(projectID, id), material.exportState == .complete else { return }
        updateMaterial(projectID, id) { $0.transcriptState = .running; $0.transcriptError = nil; $0.transcriptWarning = nil }
        let model = SettingsStore.shared.whisperModel()
        let language = SettingsStore.shared.whisperLanguage
        let correction = SettingsStore.shared.transcriptCorrectionConfiguration()
        transcriptTasks[id] = Task {
            defer { transcriptTasks[id] = nil }
            do {
                let directory = ProjectLayout.materialDirectory(material, in: project)
                let result = try await TranscriptService.transcribe(video: ProjectLayout.source(material, in: project), directory: directory, whisperModel: model, language: language, correction: correction)
                updateMaterial(projectID, id) { $0.subtitles = result.segments; $0.subtitleLayoutVersion = SubtitleSegmentation.version; $0.transcriptWarning = result.warning; $0.transcriptState = .complete }
            } catch {
                updateMaterial(projectID, id) { $0.transcriptState = .failed; $0.transcriptError = error.localizedDescription }
            }
        }
    }
    func correctSubtitles(_ projectID: UUID, _ id: UUID) {
        guard transcriptTasks[id] == nil, let (project, material) = pair(projectID, id),
              material.transcriptState == .complete, !material.subtitles.isEmpty else { return }
        guard let configuration = SettingsStore.shared.transcriptCorrectionConfiguration() else {
            showToast("请在字幕设置中开启 AI 校正。")
            return
        }
        updateMaterial(projectID, id) { $0.transcriptState = .running; $0.transcriptWarning = nil; $0.transcriptError = nil }
        transcriptTasks[id] = Task {
            defer { transcriptTasks[id] = nil }
            do {
                let directory = ProjectLayout.materialDirectory(material, in: project)
                let raw = directory.appendingPathComponent("transcript-raw.json")
                if !FileManager.default.fileExists(atPath: raw.path) {
                    try JSONEncoder().encode(material.subtitles).write(to: raw, options: .atomic)
                }
                let result = try await TranscriptCorrection.apply(material.subtitles,
                    video: ProjectLayout.picture(material, in: project), directory: directory, configuration: configuration)
                let segments = SubtitleSegmentation.split(result.segments)
                try JSONEncoder().encode(segments).write(to: directory.appendingPathComponent("transcript.json"), options: .atomic)
                updateMaterial(projectID, id) { $0.subtitles = segments; $0.subtitleLayoutVersion = SubtitleSegmentation.version; $0.transcriptState = .complete; $0.transcriptWarning = result.warning }
            } catch {
                updateMaterial(projectID, id) { $0.transcriptState = .complete; $0.transcriptWarning = "字幕校正未完成，已保留已有字幕，可重试。" }
            }
        }
    }
    func enqueueMotion(_ projectID: UUID, _ id: UUID) {
        guard activeMotion != id, !motionQueue.contains(where: { $0.1 == id }) else { return }
        updateMaterial(projectID, id) { $0.motionState = .queued; $0.motionError = nil }
        motionQueue.append((projectID, id))
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
                _ = try await Shell.run(launch, arguments: settings.aiMotionArguments(source1: source, source2: temporary, brief: brief), workingDirectory: output.deletingLastPathComponent())
                guard let duration = await RoughCutService.duration(of: temporary), duration.isFinite,
                      abs(duration - material.duration) <= 0.1 else {
                    throw ShellError.exitStatus(-1, "动效视频缺失或时长与原片不同，请重试。")
                }
                let sourceAudio = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)
                let motionAudio = try await AVURLAsset(url: temporary).loadTracks(withMediaType: .audio)
                guard sourceAudio.isEmpty || !motionAudio.isEmpty else {
                    throw ShellError.exitStatus(-1, "动效结果丢失了原片声音，已停止使用该结果，请重试。")
                }
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: temporary, to: output)
                updateMaterial(projectID, id) { $0.motionState = .complete }
            } catch { updateMaterial(projectID, id) { $0.motionState = .failed; $0.motionError = error.localizedDescription } }
        }
    }
    func editSubtitle(projectID: UUID, materialID: UUID, index: Int, text: String) {
        updateMaterial(projectID, materialID) {
            guard $0.subtitles.indices.contains(index) else { return }
            $0.subtitles[index].text = text
        }
    }
    func moveMaterial(_ projectID: UUID, index: Int, by delta: Int) {
        updateProject(projectID) { project in
            guard project.materials.indices.contains(index), project.materials.indices.contains(index + delta) else { return }
            project.materials.swapAt(index, index + delta)
        }
    }
    func export() {
        guard let project = currentProject, project.canExport, !exportingProjects.contains(project.id) else { return }
        exportingProjects.insert(project.id)
        Task {
            defer { exportingProjects.remove(project.id) }
            do {
                let output = try await ExportService.export(project: project)
                lastExports[project.id] = output
                showToast("导出完成")
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch { self.error = "导出失败：\(error.localizedDescription)" }
        }
    }
}
