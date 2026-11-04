import Foundation
import SwiftUI

enum MotionAgent: String, CaseIterable, Identifiable {
    case automatic, pi, claude, deepseek
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "自动"
        case .pi: "Pi"
        case .claude: "Claude"
        case .deepseek: "DeepSeek（Pi）"
        }
    }
}

/// AI 动效执行器和本地字幕配置。
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @AppStorage("aiMotionAgent") var aiMotionAgent: String = MotionAgent.automatic.rawValue
    @AppStorage("deepseekMotionModel") var deepseekMotionModel: String = "deepseek-flash"
    @AppStorage("aiMotionLaunchPath") var aiMotionLaunchPath: String = ""
    @AppStorage("aiMotionExtraArgs") var aiMotionExtraArgs: String = ""
    @AppStorage("whisperModelPath") var whisperModelPath: String = ""
    @AppStorage("whisperLanguage") var whisperLanguage: String = "zh"

    var selectedAgent: MotionAgent { MotionAgent(rawValue: aiMotionAgent) ?? .automatic }

    func resolvedLaunchPath() -> String {
        let preferred: [String]
        switch selectedAgent {
        case .automatic: preferred = ["pi", "claude"]
        case .pi, .deepseek: preferred = ["pi"]
        case .claude: preferred = ["claude"]
        }
        if !aiMotionLaunchPath.isEmpty, Shell.check(aiMotionLaunchPath),
           selectedAgent == .automatic || preferred.contains(URL(fileURLWithPath: aiMotionLaunchPath).lastPathComponent) {
            return aiMotionLaunchPath
        }
        return preferred.compactMap(ToolPaths.locate).first ?? "/bin/true"
    }

    static let boundedMotionPrompt = """
    本任务是单段素材的讲解动效制作，严格控制分析、渲染和检查成本，按以下顺序直接完成：
    1. 复用已有字幕、分析结果、Remotion 工程、依赖和字体。首次只生成一组不超过 8 张的分析帧，不同时生成缩略图、全尺寸帧、裁切图等多套重复样本；保护区确实不清楚时，只允许针对该区域补一组不超过 4 张的图，不重新遍历全片。
    2. 选定一套符合应用内置 workspace-tutorial-motion 的方案后立即实现，不反复比较设计、换字体或做与任务无关的完善。
    3. 局部叠加优先用 Remotion 渲染动效层或受影响区间，再与原片合成；不要默认把整段高分辨率、高帧率原片放进浏览器逐帧重渲染。确需整段重渲染时，先明确技术原因；不能静默降低原片分辨率、帧率或画质。可引用或链接原片时不重复复制大文件，不重新安装已有依赖。
    4. 完整渲染前只做一次必要的字体与代表帧预检。高分辨率任务采用保守并发，避免默认拉满；字体加载超时必须针对字体修复，不能仅增大超时后原样重跑。
    5. 完成后只做一轮集中验收：视频可播放、时长一致、原声音轨保留；最多抽查 6 张实际动效进退边界和演示保护区的代表帧。复用已有可用预览，不因觉得还可以更好而重新抽帧、扫描或整片审片。
    6. 只允许在发现可指出的具体失败时修复；最多一次定向修复和一次对应重试，只复验失败项。再次失败立即简短报错并结束，不循环检查、不无限重渲染。
    通过上述验收后立即结束，说明输出位置。不得伪造成功，不得跳过渲染、声音保留或演示保护要求。
    """

    func motionSkillURL() throws -> URL { try IntegratedMotionSkill.bundledURL() }

    static func scopedMotionPrompt(skill: URL) -> String {
        """
        本任务只使用应用内置 workspace-tutorial-motion。读取 \(skill.path)，并直接复用其中引用的世界摄像机代码与动作配方；不读取或修改本机同类技能。
        优先保护电脑演示、原有缩放、鼠标、输入和点击；全屏人物口播与非全屏人物口播遵循该技能各自允许的动效范围。
        图解需要同时设计对象动作和虚拟摄像机取景，不能仅贴静态角标；摄像机不能作用于受保护的原始录屏。
        当前仅处理一个素材的讲解动效，不执行整片装配预设：不变速、不拼装、不另外加字幕、配乐或封面。
        保留原片时长、时间关系和完整声音。交付到命令指定的输出位置；工程文件仅保存在当前素材工作目录。
        """
    }

    func aiMotionArguments(source1: URL, source2: URL, brief: URL) throws -> [String] {
        let skill = try motionSkillURL()
        // pi / claude 均支持非交互模式：--print（pi）或 -p（claude 若走该路径）。
        var args: [String] = []
        if selectedAgent == .pi || selectedAgent == .deepseek || resolvedLaunchPath().hasSuffix("/pi") {
            args += ["--print", "--no-session", "--no-skills", "--skill", skill.path]
        } else {
            args += ["-p"]
        }
        let context = resolvedLaunchPath().hasSuffix("/claude")
            ? ((try? String(contentsOf: brief, encoding: .utf8)) ?? "") : brief.path
        args += ["--append-system-prompt", context]
        args += ["--append-system-prompt", try String(contentsOf: skill, encoding: .utf8)]
        args += ["--append-system-prompt", Self.scopedMotionPrompt(skill: skill)]
        args += ["--append-system-prompt", Self.boundedMotionPrompt]
        if selectedAgent == .deepseek {
            let model = deepseekMotionModel.trimmingCharacters(in: .whitespacesAndNewlines)
            args += ["--provider", "deepseek", "--model", model.isEmpty ? "deepseek-flash" : model,
                     "--thinking", "low"]
        }
        args += ["用 Remotion 为 \(source1.path) 添加动效并渲染，输出到 \(source2.path)；总时长必须与原片一致。完成后确认 \(source2.path) 存在。"]
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
        return ""
    }
}
