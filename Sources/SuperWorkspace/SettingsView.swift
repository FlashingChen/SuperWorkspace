import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.palette) private var palette
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("reduceMotion") private var reduceMotion = false
    @ObservedObject private var settings = SettingsStore.shared
    @State private var choosingModel = false
    @State private var working = false
    @State private var result: String?
    @State private var failed = false
    @State private var selectedTab = "appearance"

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("设置").font(.system(size: 24, weight: .medium))
            StudioChoice(title: "设置分类", selection: $selectedTab,
                options: [("appearance", "外观"), ("motion", "AI 动效"), ("subtitles", "字幕")])
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if selectedTab == "appearance" { appearanceSettings }
                    else if selectedTab == "motion" { motionSettings }
                    else { subtitleSettings }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(2)
            }
        }
        .padding(28).frame(width: 660, height: 620)
        .foregroundStyle(palette.textPrimary).background(palette.bgBase)
        .buttonStyle(StudioButtonStyle())
        .toggleStyle(StudioToggleStyle())
        .textFieldStyle(StudioTextFieldStyle())
        .disclosureGroupStyle(StudioDisclosureStyle())
        .fileImporter(isPresented: $choosingModel, allowedContentTypes: [.data]) { selection in
            do {
                let url = try selection.get()
                guard url.pathExtension.lowercased() == "bin" else {
                    failed = true; result = "请选择 whisper.cpp 的 GGML .bin 模型。"; return
                }
                settings.whisperModelPath = url.path
                settings.objectWillChange.send()
                failed = false; result = nil
            } catch { failed = true; result = error.localizedDescription }
        }
    }
    private var appearanceSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingLabel("外观")
            StudioChoice(title: "外观", selection: $appearanceMode,
                options: [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")])
            Toggle("减少动态效果", isOn: $reduceMotion)
        }
    }

    private var motionSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingLabel("动效执行器")
            StudioChoice(title: "动效执行器", selection: $settings.aiMotionAgent,
                options: MotionAgent.allCases.map { ($0.rawValue, $0.label) })
            LabeledContent("执行器", value: settings.resolvedLaunchPath() == "/bin/true" ? "未找到，请先安装并登录 Pi 或 Claude" : "已找到")
            if settings.selectedAgent == .deepseek { field("DeepSeek 模型", text: $settings.deepseekMotionModel) }
            LabeledContent("动效风格", value: "内置教程动效")
            DisclosureGroup("高级配置") {
                field("执行文件", text: $settings.aiMotionLaunchPath, prompt: "留空自动寻找")
                VStack(alignment: .leading, spacing: 8) {
                    settingLabel("追加参数（每行一个）")
                    TextField("追加参数", text: $settings.aiMotionExtraArgs, axis: .vertical)
                        .lineLimit(3...6)
                }
                Text("支持 {source1}、{source2}、{brief} 和 {workdir}。")
                    .font(.caption).foregroundStyle(palette.textSecondary)
            }
            Text("动效处理期间可以使用原片。完成后可在时间线中对比并选择。")
                .font(.caption).foregroundStyle(palette.textSecondary)
        }
    }

    private var subtitleSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            LabeledContent("ffmpeg", value: ToolPaths.ffmpeg == nil ? "未安装" : "已找到")
            LabeledContent("whisper.cpp", value: ToolPaths.whisperCLI == nil ? "未安装" : "已找到")
            HStack {
                LabeledContent("语音模型", value: settings.whisperModel().isEmpty ? "未选择" : URL(fileURLWithPath: settings.whisperModel()).lastPathComponent)
                Button("选择模型…") { choosingModel = true }
            }
            if ToolPaths.ffmpeg == nil || ToolPaths.whisperCLI == nil {
                Button("安装字幕工具") { installTools() }.disabled(working || ToolPaths.locate("brew") == nil)
                if ToolPaths.locate("brew") == nil {
                    Text("安装 Homebrew 后即可在这里安装字幕工具。录制和无字幕导出仍可使用。")
                        .font(.caption).foregroundStyle(palette.textSecondary)
                }
            }
            HStack {
                Button("测试字幕识别") { testTranscription() }.disabled(working || !settings.missingSubtitleTools.isEmpty)
                if working { ProgressView().controlSize(.small) }
            }
            if let result {
                Text(result).font(.caption).foregroundStyle(failed ? palette.danger : palette.textSecondary).textSelection(.enabled)
            }
            Rectangle().fill(palette.surface2).frame(height: 1)
            settingLabel("识别语言")
            StudioChoice(title: "识别语言", selection: $settings.whisperLanguage,
                options: [("zh", "中文"), ("en", "English"), ("auto", "自动检测")])
            Toggle("AI 校正字幕", isOn: $settings.transcriptAICorrection)
            if settings.transcriptAICorrection {
                Text(settings.resolvedLaunchPath() == "/bin/true" ? "未配置 AI 执行器，当前仅使用本地字幕。" : "校正会将字幕和提取的画面文字发送给已配置的模型服务。")
                    .font(.caption).foregroundStyle(palette.textSecondary)
            }
            DisclosureGroup("高级配置") {
                field("模型路径", text: $settings.whisperModelPath)
                field("语言代码", text: $settings.whisperLanguage)
            }
        }
    }

    private func settingLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .medium))
    }

    private func field(_ title: String, text: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: 8) {
            settingLabel(title)
            TextField(title, text: text, prompt: Text(prompt))
        }
    }

    private func installTools() {
        guard let brew = ToolPaths.locate("brew") else { return }
        working = true; failed = false; result = "正在安装字幕工具…"
        Task {
            defer { working = false; settings.objectWillChange.send() }
            do {
                try await Shell.run(brew, arguments: ["install", "ffmpeg", "whisper-cpp"], timeout: 900)
                result = "工具已安装，请选择语音模型并测试识别。"
            } catch { failed = true; result = "安装未完成：\(error.localizedDescription)" }
        }
    }
    private func testTranscription() {
        guard let ffmpeg = ToolPaths.ffmpeg, let whisper = ToolPaths.whisperCLI else { return }
        working = true; failed = false; result = "正在加载模型并测试识别…"
        Task {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { working = false; try? FileManager.default.removeItem(at: directory) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let audio = directory.appendingPathComponent("test.wav")
                try await Shell.run(ffmpeg, arguments: ["-y", "-f", "lavfi", "-i", "anullsrc=r=16000:cl=mono", "-t", "1", audio.path], timeout: 15)
                try await Shell.run(whisper, arguments: ["-m", settings.whisperModel(), "-f", audio.path, "-l", settings.whisperLanguage, "-nt"], timeout: 120)
                result = "测试通过，字幕工具和模型可用。"
            } catch { failed = true; result = "测试未通过：\(error.localizedDescription)" }
        }
    }
}

struct CapabilityReadinessView: View {
    @ObservedObject private var settings = SettingsStore.shared
    var body: some View {
        if !settings.missingSubtitleTools.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("字幕待配置：\(settings.missingSubtitleTools.joined(separator: "、"))")
                    .font(.system(size: 12))
                SettingsLink { Text("配置字幕") }.buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact)).font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
        }
    }
}

enum AppearanceResolver {
    static func scheme(for mode: String) -> ColorScheme? {
        switch mode {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}
