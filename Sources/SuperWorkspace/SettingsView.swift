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
    @State private var apiURL = ""
    @State private var apiModel = ""
    @State private var apiKey = ""
    @State private var hasSavedKey = false
    @State private var testingAPI = false
    @State private var apiStatus: String?
    @State private var apiFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space6) {
            Text("设置").font(.studio(.title))
            StudioChoice(title: "设置分类", selection: $selectedTab,
                options: [("appearance", "外观"), ("motion", "AI 动效"), ("subtitles", "字幕")])
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.space6) {
                    if selectedTab == "appearance" { appearanceSettings }
                    else if selectedTab == "motion" { motionSettings }
                    else { subtitleSettings }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(Metrics.space0_5)
            }
        }
        .padding(Metrics.space7).frame(width: 660, height: 620)
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
        VStack(alignment: .leading, spacing: Metrics.space4) {
            settingLabel("外观")
            StudioChoice(title: "外观", selection: $appearanceMode,
                options: [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")])
            Toggle("减少动态效果", isOn: $reduceMotion)
        }
    }

    private var motionSettings: some View {
        VStack(alignment: .leading, spacing: Metrics.space4) {
            settingLabel("AI 连接")
            StudioChoice(title: "AI 连接", selection: Binding(
                get: { settings.selectedAgent.rawValue }, set: { settings.aiMotionAgent = $0 }),
                options: MotionAgent.allCases.map { ($0.rawValue, $0.label) })
            if settings.selectedAgent == .api { apiSettings }
            else { cliSettings }
        }
    }

    private var cliSettings: some View {
        VStack(alignment: .leading, spacing: Metrics.space4) {
            LabeledContent("执行器", value: settings.resolvedLaunchPath() == "/bin/true" ? "未找到 Claude CLI" : "已找到")
            LabeledContent("动效风格", value: "内置教程动效")
            DisclosureGroup("高级配置") {
                field("执行文件", text: $settings.aiMotionLaunchPath, prompt: "留空自动寻找")
                VStack(alignment: .leading, spacing: Metrics.space2) {
                    settingLabel("追加参数（每行一个）")
                    TextField("追加参数", text: $settings.aiMotionExtraArgs, axis: .vertical)
                        .lineLimit(3...6)
                }
                Text("支持 {source1}、{source2}、{brief} 和 {workdir}。")
                    .font(.studio(.small)).foregroundStyle(palette.textSecondary)
            }
            Text("动效处理期间可以使用原片。完成后可在时间线中对比并选择。")
                .font(.studio(.small)).foregroundStyle(palette.textSecondary)
        }
    }

    private var apiSettings: some View {
        VStack(alignment: .leading, spacing: Metrics.space4) {
            Group {
                field("API 地址", text: $apiURL, prompt: "OpenAI 兼容接口的基础地址")
                field("模型", text: $apiModel, prompt: "服务提供的模型 ID")
                VStack(alignment: .leading, spacing: Metrics.space2) {
                    settingLabel("API 密钥")
                    SecureField("API 密钥", text: $apiKey,
                                prompt: Text(hasSavedKey ? "已存入钥匙串，留空保留" : "输入密钥"))
                }
                Toggle("模型支持图片", isOn: $settings.aiAPIImages)
                Toggle("为素材库素材自动生成描述", isOn: Binding(
                    get: { settings.aiAutoDescribeMedia },
                    set: { settings.aiAutoDescribeMedia = $0; settings.objectWillChange.send() }))
                    .disabled(!settings.canDescribeMedia)
                HStack(spacing: Metrics.space3) {
                    settingLabel("单条动效时长上限")
                    Menu("\(settings.motionTimeLimitMinutes) 分钟") {
                        ForEach([20, 30, 40, 60, 90, 120], id: \.self) { minutes in
                            Button("\(minutes) 分钟") {
                                settings.motionTimeLimitMinutes = minutes
                                settings.objectWillChange.send()
                            }
                        }
                    }
                    .menuStyle(StudioMenuStyle())
                    .fixedSize()
                    Spacer()
                }
                Text("超过上限会中止该条动效，已完成的镜头不会被采用。")
                    .font(.studio(.small)).foregroundStyle(palette.textSecondary)
                HStack(spacing: Metrics.space3) {
                    settingLabel("同时处理条数")
                    Menu("\(settings.motionConcurrency) 条") {
                        ForEach([1, 2, 3], id: \.self) { count in
                            Button("\(count) 条") {
                                settings.motionConcurrency = count
                                settings.objectWillChange.send()
                            }
                        }
                    }
                    .menuStyle(StudioMenuStyle())
                    .fixedSize()
                    Spacer()
                }
                Text("动效渲染吃满 CPU，并行会互相抢核心；素材多时再调高。")
                    .font(.studio(.small)).foregroundStyle(palette.textSecondary)
                if !settings.canDescribeMedia {
                    Text("需要开启「模型支持图片」，并保存可用的 API 连接。")
                        .font(.studio(.small)).foregroundStyle(palette.textSecondary)
                } else if settings.aiAutoDescribeMedia {
                    Text("导入素材时会发送一张截图，用于生成一句中文描述。")
                        .font(.studio(.small)).foregroundStyle(palette.textSecondary)
                }
            }
            .disabled(testingAPI)

            HStack(spacing: Metrics.space2) {
                Button("测试连接") { testAPI() }.disabled(testingAPI)
                Button("保存") {
                    updateAPIStatus {
                        try settings.saveAPI(baseURL: apiURL, model: apiModel, key: apiKey)
                        apiKey = ""
                        refreshAPIKey()
                        return "已保存"
                    }
                }
                .buttonStyle(StudioButtonStyle(kind: .primary))
                .disabled(testingAPI)
                if testingAPI { ProgressView().controlSize(.small) }
                Spacer()
                if hasSavedKey {
                    Button("移除密钥") {
                        updateAPIStatus {
                            try AIKeychain.remove(AIEndpoint(apiURL))
                            refreshAPIKey()
                            settings.objectWillChange.send()
                            return "已移除密钥"
                        }
                    }
                    .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                    .disabled(testingAPI)
                }
            }
            if let apiStatus {
                Text(apiStatus).font(.studio(.small))
                    .foregroundStyle(apiFailed ? palette.danger : palette.textSecondary)
            }
            Text("用于字幕校正、素材描述和 Remotion 动效。动效在本机渲染。")
                .font(.studio(.small)).foregroundStyle(palette.textSecondary)
        }
        .onAppear {
            apiURL = settings.aiAPIBaseURL
            apiModel = settings.aiAPIModel
            refreshAPIKey()
        }
        .onChange(of: apiURL) { _, _ in refreshAPIKey() }
        .onDisappear { apiKey = ""; apiStatus = nil }
    }

    private func refreshAPIKey() {
        hasSavedKey = (try? AIEndpoint(apiURL)).flatMap { try? AIKeychain.read($0) } != nil
    }

    private func updateAPIStatus(_ action: () throws -> String) {
        do { apiStatus = try action(); apiFailed = false }
        catch { apiStatus = error.localizedDescription; apiFailed = true }
    }

    private func testAPI() {
        do {
            let connection = try settings.apiConnection(baseURL: apiURL, model: apiModel, key: apiKey)
            testingAPI = true
            apiStatus = nil
            Task {
                defer { testingAPI = false }
                do {
                    _ = try await EmbeddedPi.run(connection, system: "Reply with OK only.", prompt: "Connection test",
                                                 directory: FileManager.default.temporaryDirectory, tools: false, timeout: 30)
                    apiStatus = "连接成功"
                    apiFailed = false
                } catch {
                    apiStatus = error.localizedDescription
                    apiFailed = true
                }
            }
        } catch {
            apiStatus = error.localizedDescription
            apiFailed = true
        }
    }

    private var subtitleSettings: some View {
        VStack(alignment: .leading, spacing: Metrics.space4) {
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
                        .font(.studio(.small)).foregroundStyle(palette.textSecondary)
                }
            }
            HStack {
                Button("测试字幕识别") { testTranscription() }.disabled(working || !settings.missingSubtitleTools.isEmpty)
                if working { ProgressView().controlSize(.small) }
            }
            if let result {
                Text(result).font(.studio(.small)).foregroundStyle(failed ? palette.danger : palette.textSecondary).textSelection(.enabled)
            }
            Rectangle().fill(palette.surface2).frame(height: 1)
            settingLabel("识别语言")
            StudioChoice(title: "识别语言", selection: $settings.whisperLanguage,
                options: [("zh", "中文"), ("en", "English"), ("auto", "自动检测")])
            Toggle("AI 校正字幕", isOn: $settings.transcriptAICorrection)
            if settings.transcriptAICorrection {
                Text(!settings.hasAIConnection ? "未配置 AI 连接，当前仅使用本地字幕。" : "校正会将字幕和提取的画面文字发送给已配置的模型服务。")
                    .font(.studio(.small)).foregroundStyle(palette.textSecondary)
            }
            Toggle("AI 复核字幕", isOn: $settings.transcriptAIReview)
            if settings.transcriptAIReview {
                Text(!settings.hasAIConnection ? "未配置 AI 连接，复核只做时长、重叠与边界检查。" : "复核会按素材重建整条字幕轨：改错字、重新断句、调整时间。字幕长短与断句由模型按语义决定，整次可一步撤销。")
                    .font(.studio(.small)).foregroundStyle(palette.textSecondary)
            }
            DisclosureGroup("高级配置") {
                field("模型路径", text: $settings.whisperModelPath)
                field("语言代码", text: $settings.whisperLanguage)
            }
        }
    }

    private func settingLabel(_ title: String) -> some View {
        Text(title).font(.studio(.bodyMedium))
    }

    private func field(_ title: String, text: Binding<String>, prompt: String = "") -> some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
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
    @Environment(\.palette) private var palette
    @ObservedObject private var settings = SettingsStore.shared
    var body: some View {
        if !settings.missingSubtitleTools.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.space2) {
                Text("字幕待配置：\(settings.missingSubtitleTools.joined(separator: "、"))")
                    .font(.studio(.small))
                SettingsLink { Text("配置字幕") }.buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact)).font(.studio(.small))
            }
            .foregroundStyle(palette.textSecondary)
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
