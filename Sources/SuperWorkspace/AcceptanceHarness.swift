import AVFoundation
import Foundation

/// 端到端验收（无界面）：
/// `SuperWorkspace --accept [输入视频] [目标秒数=600]`
/// 构造 ≥10 分钟粗剪片 → 动效派发（内置 Pi + Remotion）→ whisper 字幕 → 导出，
/// 校验 source2 / 导出成片与输入等长、字幕 metadata 存在，打印证据后退出。
enum AcceptanceHarness {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--accept") else { return }
        let input = args.count > index + 1 ? args[index + 1] : nil
        let target = args.count > index + 2 ? Double(args[index + 2]) ?? 600 : 600
        Task { @MainActor in
            do {
                try await run(inputPath: input, targetSeconds: target)
                print("ACCEPT OK")
                exit(0)
            } catch {
                print("ACCEPT FAIL: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    static func log(_ line: String) {
        print("[accept \(Date().formatted(date: .omitted, time: .standard))] \(line)")
        fflush(stdout)
    }

    @MainActor
    static func run(inputPath: String?, targetSeconds: Double) async throws {
        configureSettings()
        let fm = FileManager.default
        guard let ffmpeg = ToolPaths.ffmpeg else { throw ShellError.exitStatus(-1, "缺少 ffmpeg") }

        // 1. 准备 ≥targetSeconds 的输入粗剪片。
        let inputURL: URL
        if let inputPath {
            inputURL = URL(fileURLWithPath: inputPath)
        } else {
            throw ShellError.exitStatus(-1, "请提供输入视频路径")
        }
        let workRoot = fm.temporaryDirectory.appendingPathComponent("sw-accept", isDirectory: true)
        try fm.createDirectory(at: workRoot, withIntermediateDirectories: true)
        let clip = workRoot.appendingPathComponent("clip.mp4")
        try? fm.removeItem(at: clip)
        log("截取输入片段 \(inputURL.lastPathComponent)")
        try await Shell.run(ffmpeg, arguments: ["-y", "-i", inputURL.path, "-c", "copy", clip.path])

        let source: URL
        let clipDuration = await RoughCutService.duration(of: clip) ?? 0
        if clipDuration >= targetSeconds {
            source = clip
        } else {
            // 循环拼接达到目标时长。
            let repeats = Int(ceil(targetSeconds / max(clipDuration, 1)))
            let list = workRoot.appendingPathComponent("list.txt")
            let lines = (0..<repeats).map { _ in "file '\(clip.path)'" }.joined(separator: "\n")
            try lines.write(to: list, atomically: true, encoding: .utf8)
            source = workRoot.appendingPathComponent("input-10min.mp4")
            try? fm.removeItem(at: source)
            log("拼接 \(repeats) 段生成 \(Int(targetSeconds)) 秒输入")
            try await Shell.run(ffmpeg, arguments: [
                "-y", "-f", "concat", "-safe", "0", "-i", list.path, "-c", "copy", source.path,
            ])
        }
        let inputDuration = await RoughCutService.duration(of: source) ?? 0
        log("输入时长: \(inputDuration)")


        let state = AppState()
        state.createProjectForAcceptance(name: "acceptance")
        guard let project = state.projects.first else { throw ShellError.exitStatus(-1, "项目创建失败") }
        var material = Material()
        material.wantsMotion = true
        material.exportState = .complete
        material.duration = inputDuration
        let directory = ProjectLayout.materialDirectory(material, in: project)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: ProjectLayout.source(material, in: project))
        state.attachMaterialForAcceptance(material, projectID: project.id)
        log("素材已挂载，开始动效 + 字幕处理")

        // 3. 等待动效与字幕完成（上限 90 分钟）。
        let deadline = Date().addingTimeInterval(90 * 60)
        var lastPhase = ""
        while Date() < deadline {
            guard let (_, m) = state.pairForAcceptance(project.id, material.id) else {
                throw ShellError.exitStatus(-1, "素材丢失")
            }
            let phase = state.taskPhases[material.mediaID] ?? ""
            let status = "motion=\(m.motionState.rawValue) transcript=\(m.transcriptState.rawValue) phase=\(phase)"
            if status != lastPhase {
                log(status)
                if let error = m.motionError ?? m.transcriptError { log("error: \(error)") }
                lastPhase = status
            }
            let motionDone = m.motionState == .complete || m.motionState == .failed
            let transcriptDone = m.transcriptState == .complete || m.transcriptState == .failed
            if motionDone, transcriptDone { break }
            try await Task.sleep(for: .seconds(5))
        }
        guard let (_, m) = state.pairForAcceptance(project.id, material.id) else {
            throw ShellError.exitStatus(-1, "素材丢失")
        }
        guard m.motionState == .complete else {
            throw ShellError.exitStatus(-1, "动效未完成：\(m.motionError ?? "?")")
        }
        guard m.transcriptState == .complete else {
            throw ShellError.exitStatus(-1, "字幕未完成：\(m.transcriptError ?? "?")")
        }

        // 4. 证据核对：source2 等长、字幕 metadata、导出等长。
        let motionURL = ProjectLayout.motion(m, in: project)
        let motionDuration = await RoughCutService.duration(of: motionURL) ?? 0
        log("source2 时长: \(motionDuration)（输入 \(inputDuration)）")
        guard abs(motionDuration - inputDuration) < 2.0 else {
            throw ShellError.exitStatus(-1, "source2 与输入时长不一致")
        }
        let transcriptURL = directory.appendingPathComponent("transcript.json")
        let transcriptData = try Data(contentsOf: transcriptURL)
        let segments = try JSONDecoder().decode([TranscriptSegment].self, from: transcriptData)
        log("字幕条数: \(segments.count)，首条: \(segments.first.map { "\($0.start)-\($0.end) \($0.text.prefix(30))" } ?? "-")")
        guard !segments.isEmpty, segments.allSatisfy({ $0.end > $0.start }) else {
            throw ShellError.exitStatus(-1, "字幕 metadata 无效")
        }

        let output = try await ExportService.export(project: state.projects[0])
        let outputDuration = await RoughCutService.duration(of: output) ?? 0
        log("导出: \(output.path) 时长 \(outputDuration)")
        guard abs(outputDuration - inputDuration) < 2.0 else {
            throw ShellError.exitStatus(-1, "导出与输入时长不一致")
        }
        print("ACCEPT ARTIFACTS:")
        print("  input:   \(source.path) (\(inputDuration)s)")
        print("  source2: \(motionURL.path) (\(motionDuration)s)")
        print("  transcript: \(transcriptURL.path) (\(segments.count) segments)")
        print("  export:  \(output.path) (\(outputDuration)s)")
    }
}

extension AcceptanceHarness {
    @MainActor
    static func configureSettings() {
        SettingsStore.shared.aiMotionAgent = MotionAgent.api.rawValue
        SettingsStore.shared.aiAPIBaseURL = ProcessInfo.processInfo.environment["ACCEPT_API_BASE"] ?? "http://127.0.0.1:3425/v1"
        SettingsStore.shared.aiAPIModel = ProcessInfo.processInfo.environment["ACCEPT_API_MODEL"] ?? "auto/step-5-preview"
        SettingsStore.shared.transcriptAICorrection = false // 验收聚焦动效与本地字幕
        guard SettingsStore.shared.hasAIConnection else {
            print("ACCEPT FAIL: 内置 Pi 组件不可用")
            exit(1)
        }
    }
}

extension AppState {
    func createProjectForAcceptance(name: String) {
        createProject(name: name)
    }

    func attachMaterialForAcceptance(_ material: Material, projectID: UUID) {
        guard var project = projects.first(where: { $0.id == projectID }) else { return }
        project.materials.append(material)
        project.updatedAt = Date()
        try? ProjectLayout.save(project)
        if let i = projects.firstIndex(where: { $0.id == projectID }) { projects[i] = project }
        processMaterial(projectID, material.id)
    }

    func pairForAcceptance(_ projectID: UUID, _ id: UUID) -> (VideoProject, Material)? {
        pair(projectID, id)
    }
}
