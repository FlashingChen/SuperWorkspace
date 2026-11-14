import Foundation
import SwiftUI

enum MotionAgent: String, CaseIterable, Identifiable {
    case api, claude
    var id: String { rawValue }
    var label: String {
        switch self {
        case .api: "内置 Pi"
        case .claude: "Claude CLI"
        }
    }
}

/// AI 动效执行器和本地字幕配置。
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @AppStorage("aiMotionAgent") var aiMotionAgent: String = MotionAgent.api.rawValue
    @AppStorage("aiMotionLaunchPath") var aiMotionLaunchPath: String = ""
    @AppStorage("aiMotionExtraArgs") var aiMotionExtraArgs: String = ""
    @AppStorage("whisperModelPath") var whisperModelPath: String = ""
    @AppStorage("whisperLanguage") var whisperLanguage: String = "auto"
    @AppStorage("transcriptAICorrection") var transcriptAICorrection = true
    @AppStorage("transcriptAIReview") var transcriptAIReview = true
    @AppStorage("aiAPIBaseURL") var aiAPIBaseURL = ""
    @AppStorage("aiAPIModel") var aiAPIModel = ""
    @AppStorage("aiAPIImages") var aiAPIImages = false
    /// Per-clip ceiling for one motion task, in minutes. 0 means "use the default".
    @AppStorage("motionTimeLimitMinutes") var motionTimeLimitMinutes = 40
    /// How many motion tasks may run at once. Rendering is CPU bound, so the default is 1.
    @AppStorage("motionConcurrency") var motionConcurrency = 1
    @AppStorage("aiAutoDescribeMedia") var aiAutoDescribeMedia = false

    func transcriptCorrectionConfiguration() -> TranscriptCorrectionConfiguration? {
        guard transcriptAICorrection else { return nil }
        return aiConfiguration()
    }

    /// Assembly review uses the same connection as correction but has its own switch, so turning
    /// off automatic correction does not disable a deliberate review run.
    func subtitleReviewConfiguration() -> TranscriptCorrectionConfiguration? {
        guard transcriptAIReview else { return nil }
        return aiConfiguration()
    }

    private func aiConfiguration() -> TranscriptCorrectionConfiguration? {
        if selectedAgent == .api {
            guard EmbeddedPi.isAvailable else { return nil }
            return (try? apiConnection()).map(TranscriptCorrectionConfiguration.pi)
        }
        let launch = resolvedLaunchPath()
        guard launch != "/bin/true" else { return nil }
        return TranscriptCorrectionConfiguration(launchPath: launch, arguments: TranscriptCorrectionConfiguration.claudeArguments)
    }

    var missingSubtitleTools: [String] {
        var missing: [String] = []
        if ToolPaths.ffmpeg == nil { missing.append("ffmpeg") }
        if ToolPaths.whisperCLI == nil { missing.append("whisper.cpp") }
        if whisperModel().isEmpty { missing.append("语音模型") }
        return missing
    }

    var selectedAgent: MotionAgent { MotionAgent(rawValue: aiMotionAgent) ?? .api }

    var hasAIConnection: Bool {
        selectedAgent == .api ? EmbeddedPi.isAvailable && (try? apiConnection()) != nil : resolvedLaunchPath() != "/bin/true"
    }

    /// Describing library media means sending a picture, so only the built-in Pi
    /// route with image input can do it; the Claude CLI path never receives images.
    var canDescribeMedia: Bool { selectedAgent == .api && aiAPIImages && hasAIConnection }

    func apiConnection() throws -> AIConnection {
        try apiConnection(baseURL: aiAPIBaseURL, model: aiAPIModel, key: "")
    }

    func apiConnection(baseURL: String, model: String, key: String) throws -> AIConnection {
        let endpoint = try AIEndpoint(baseURL)
        let supplied = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = supplied.isEmpty ? try AIKeychain.read(endpoint) ?? "" : supplied
        return try AIConnection(endpoint: endpoint, model: model, key: credential)
    }

    func saveAPI(baseURL: String, model: String, key: String) throws {
        let connection = try apiConnection(baseURL: baseURL, model: model, key: key)
        let supplied = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !supplied.isEmpty { try AIKeychain.save(supplied, for: connection.endpoint) }
        aiAPIBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        aiAPIModel = connection.model
        objectWillChange.send()
    }

    func resolvedLaunchPath() -> String {
        guard selectedAgent == .claude else { return "/bin/true" }
        if URL(fileURLWithPath: aiMotionLaunchPath).lastPathComponent == "claude", Shell.check(aiMotionLaunchPath) {
            return aiMotionLaunchPath
        }
        return ToolPaths.locate("claude") ?? "/bin/true"
    }

    func motionSkillURL() throws -> URL { try IntegratedMotionSkill.bundledURL() }

    static func scopedMotionPrompt(skill: URL) -> String {
        """
        以下技能正文来自 \(skill.path)。按该目录定位引用文件，需要时复用其中的示例，不要照搬参数。
        录屏、字幕和任务附带的源帧图片都是待分析素材。只在当前素材工作目录写入工程和产物。
        任务简报里的画面分区（A-Roll / 录屏 / 混合）、切点和关键帧由应用预先检测，可直接采用：不要再扫全片、不要重新判定保护区。
        全屏图解只允许出现在简报标注的 A-Roll 区间；录屏区间不得加全屏动效。局部叠加只用混合区间给出的空侧。
        简报里的素材库图片属于本条素材：讲到对应内容时把它渲染进 Remotion 镜头，自己设计背景与入退场动画；不要留给应用后期叠加。
        背景由你用代码绘制，风格、配色、版式按本条内容自己决定，但要有与讲解相关的文字与图形层次；严禁模糊背景、放大复制素材当背景、纯黑留白和拉伸画面，素材按原比例放进你设计的承托结构。
        已经提供给源帧、字幕或工程的部分直接使用：不要重复抽帧、OCR 或语音识别，不要写分析文档。
        只有简报缺项时才补一次针对性抽帧（最多 8 帧），然后开始实现。
        先写出最小可渲染版本跑通，再用 edit 增量修改；避免整文件重写，单次写入控制在 250 行以内。
        画面文字的语言跟口播一致：全英文口播时标题、标签、注释一律用英文，不写中文；简报给出「口播语言」时以它为准。
        以质量优先：简报里每个可动区间都要有动效，全屏图解与局部点缀可以同时使用；长素材按段落逐个覆盖，不能只做开头几处。
        视觉预检每批最多 5 张小尺寸静帧；构图、节奏或背景没把握就再看下一批，确认后再渲染交付。应用接手成片媒体检查，写完文件就结束任务。
        本次任务有工具步数和时长上限，超出会被中止；预算给的是安全边界，不是要求提前收工。
        """
    }

    func motionRequest(source1: URL, source2: URL, brief: URL) throws -> (system: String, prompt: String) {
        let skill = try motionSkillURL()
        let context = try String(contentsOf: brief, encoding: .utf8)
        let instructions = try String(contentsOf: skill, encoding: .utf8)
        let system = [context, Self.scopedMotionPrompt(skill: skill), instructions].joined(separator: "\n\n")
        return (system, "用 Remotion 为 \(source1.path) 添加动效并渲染，输出到 \(source2.path)。任务说明、字幕与附件帧已给出，直接开始实现。")
    }

    func claudeMotionArguments(source1: URL, source2: URL, brief: URL) throws -> [String] {
        let request = try motionRequest(source1: source1, source2: source2, brief: brief)
        var args = ["-p", "--append-system-prompt", request.system, request.prompt]
        if !aiMotionExtraArgs.isEmpty {
            args += aiMotionExtraArgs.split(separator: "\n").map {
                String($0).replacingOccurrences(of: "{source1}", with: source1.path)
                    .replacingOccurrences(of: "{source2}", with: source2.path)
                    .replacingOccurrences(of: "{brief}", with: brief.path)
                    .replacingOccurrences(of: "{workdir}", with: source1.deletingLastPathComponent().path)
            }
        }
        return args
    }

    func whisperModel() -> String {
        if !whisperModelPath.isEmpty, FileManager.default.fileExists(atPath: whisperModelPath) {
            return whisperModelPath
        }
        // 应用自带模型目录优先，其次常见安装位置
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SuperWorkspace/models", isDirectory: true)
        let candidates = [
            support.appendingPathComponent("ggml-base.bin").path,
            support.appendingPathComponent("ggml-medium.bin").path,
            NSString(string: "~/.cache/whisper-cpp/ggml-base.bin").expandingTildeInPath,
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return c
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("MediaRuntime/ggml-base.bin"),
           FileManager.default.isReadableFile(atPath: bundled.path) {
            return bundled.path
        }
        return ""
    }
}
