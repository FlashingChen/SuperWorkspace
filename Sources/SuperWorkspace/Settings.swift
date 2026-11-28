import Foundation
import SwiftUI

enum MotionAgent: String, CaseIterable, Identifiable {
    case api, antigravity, claude
    var id: String { rawValue }
    var label: String {
        switch self {
        case .api: "内置 Pi"
        case .antigravity: "Antigravity CLI"
        case .claude: "Claude CLI"
        }
    }
}

/// 字幕校对、复核、AI 剪辑与素材描述使用的后端（与 Remotion 动效独立选择）。
enum GeneralAgent: String, CaseIterable, Identifiable {
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
    @AppStorage("aiGeneralAgent") var aiGeneralAgent: String = GeneralAgent.api.rawValue
    @AppStorage("aiMotionLaunchPath") var aiMotionLaunchPath: String = ""
    @AppStorage("aiMotionExtraArgs") var aiMotionExtraArgs: String = ""
    @AppStorage("aiAntigravityModel") var aiAntigravityModel: String = ""
    @AppStorage("aiAntigravityLaunchPath") var aiAntigravityLaunchPath: String = ""
    @AppStorage("aiAntigravityExtraArgs") var aiAntigravityExtraArgs: String = ""
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

    @Published private(set) var antigravityAccount: AntigravityCLI.AccountState = .unknown
    @Published private(set) var antigravityModels: [AntigravityCLI.Model] = []

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
        if selectedGeneralAgent == .api {
            guard EmbeddedPi.isAvailable else { return nil }
            return (try? apiConnection()).map(TranscriptCorrectionConfiguration.pi)
        }
        guard let launch = resolvedClaudePath() else { return nil }
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
    var selectedGeneralAgent: GeneralAgent { GeneralAgent(rawValue: aiGeneralAgent) ?? .api }

    var hasAPIConnection: Bool {
        EmbeddedPi.isAvailable && (try? apiConnection()) != nil
    }

    var hasAIConnection: Bool {
        switch selectedAgent {
        case .api: hasAPIConnection
        case .antigravity: resolvedAntigravityPath() != nil
        case .claude: resolvedClaudePath() != nil
        }
    }

    var hasGeneralAIConnection: Bool {
        switch selectedGeneralAgent {
        case .api: hasAPIConnection
        case .claude: resolvedClaudePath() != nil
        }
    }

    /// Describing library media means sending a picture, so only the built-in Pi
    /// route with image input can do it; the Claude CLI path never receives images.
    var canDescribeMedia: Bool { selectedGeneralAgent == .api && aiAPIImages && hasAPIConnection }

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

    func resolvedClaudePath() -> String? {
        if URL(fileURLWithPath: aiMotionLaunchPath).lastPathComponent == "claude", Shell.check(aiMotionLaunchPath) {
            return aiMotionLaunchPath
        }
        return ToolPaths.locate("claude")
    }

    func resolvedAntigravityPath() -> String? {
        AntigravityCLI.locate(customPath: aiAntigravityLaunchPath)
    }

    func resolvedLaunchPath() -> String {
        switch selectedAgent {
        case .api: return "/bin/true"
        case .antigravity: return resolvedAntigravityPath() ?? "/bin/true"
        case .claude: return resolvedClaudePath() ?? "/bin/true"
        }
    }

    func refreshAntigravityAccount() {
        guard antigravityAccount != .checking else { return }
        guard let executable = resolvedAntigravityPath() else {
            antigravityAccount = .unknown
            antigravityModels = []
            return
        }
        antigravityAccount = .checking
        Task {
            let (state, models) = await AntigravityCLI.discoverModels(executable: executable)
            self.antigravityAccount = state
            if !models.isEmpty {
                self.antigravityModels = models
            } else if state != .signedIn {
                self.antigravityModels = []
            }
        }
    }

    func signInAntigravity() {
        guard let executable = resolvedAntigravityPath() else { return }
        antigravityAccount = .signingIn
        AntigravityCLI.openTerminalSignIn(executable: executable)
    }

    func antigravityMotionExtraArguments(source1: URL, source2: URL, brief: URL) -> [String] {
        guard !aiAntigravityExtraArgs.isEmpty else { return [] }
        return aiAntigravityExtraArgs
            .split(separator: "\n")
            .map {
                String($0)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "{source1}", with: source1.path)
                    .replacingOccurrences(of: "{source2}", with: source2.path)
                    .replacingOccurrences(of: "{brief}", with: brief.path)
                    .replacingOccurrences(of: "{workdir}", with: source1.deletingLastPathComponent().path)
            }
            .filter { !$0.isEmpty }
    }

    func motionSkillURL() throws -> URL { try IntegratedMotionSkill.bundledURL() }

    static func scopedMotionPrompt(skill: URL) -> String {
        """
        以下技能正文来自 \(skill.path)，按需引用其同级 `references/` 文档。
        只在当前素材工作目录读写工程与产物；工作目录已预置 `src/sw-kit/` 与 `sw-motion.mjs`。
        先写出最小可渲染版本跑通，再用 edit 增量修改（单次写入控制在 250 行以内）；覆盖简报中全部可动区间。
        本次任务有工具步数和时长上限（安全边界，并非要求提前收工）；`sw-motion.mjs render` 返回 `ok: true` 后直接交付，由应用接手媒体校验。
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
