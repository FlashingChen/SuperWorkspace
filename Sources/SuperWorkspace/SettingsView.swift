import SwiftUI

/// 设置：外观与 AI / 字幕工具配置。
struct SettingsView: View {
    @Environment(\.palette) private var palette
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("reduceMotion") private var reduceMotion = false
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        TabView {
            Form {
                Picker("外观", selection: $appearanceMode) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
                Toggle("减少动态效果", isOn: $reduceMotion)
            }
            .formStyle(.grouped)
            .tabItem { Label("外观", systemImage: "paintpalette") }

            Form {
                Picker("动效 Agent", selection: $settings.aiMotionAgent) {
                    ForEach(MotionAgent.allCases) { agent in Text(agent.label).tag(agent.rawValue) }
                }
                if settings.selectedAgent == .deepseek {
                    TextField("DeepSeek 模型", text: $settings.deepseekMotionModel)
                    Text("使用 Pi 已配置的 DeepSeek 凭据。只做一轮集中检查，失败时定向修复。")
                        .font(.caption).foregroundStyle(palette.textSecondary)
                }
                LabeledContent("动效风格", value: "内置教程动效")
                TextField("AI agent 可执行文件", text: $settings.aiMotionLaunchPath, prompt: Text("留空自动寻找 pi / claude"))
                TextField("追加参数（每行一个）", text: $settings.aiMotionExtraArgs, axis: .vertical)
                    .lineLimit(3...6)
                Text("每段素材自动派发。追加参数支持 {source1}、{source2}、{brief} 和 {workdir}。")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.textMuted)
            }
            .formStyle(.grouped)
            .tabItem { Label("AI 动效", systemImage: "sparkles") }

            Form {
                TextField("whisper 模型路径（ggml .bin）", text: $settings.whisperModelPath, prompt: Text("留空自动查找应用支持目录"))
                TextField("识别语言", text: $settings.whisperLanguage, prompt: Text("zh / en / auto"))
                HStack {
                    Text("检测到 ffmpeg：\(ToolPaths.ffmpeg ?? "未找到")")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textMuted)
                }
                HStack {
                    Text("检测到 whisper-cli：\(ToolPaths.whisperCLI ?? "未找到")")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.textMuted)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("字幕", systemImage: "externaldrive") }
        }
        .frame(width: 560, height: 440)
    }
}

/// 按设置解析外观。
enum AppearanceResolver {
    static func scheme(for mode: String) -> ColorScheme? {
        switch mode {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}
