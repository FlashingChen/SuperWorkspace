import Foundation

/// Runs one long-lived Pi agent for a project's assembly chat. The agent lives in
/// a child process (bundled Node) and reaches the live project through
/// `ProjectToolBridge`; context, tool-call loops and retries stay in Pi.
@MainActor
final class AssemblyAgent: ObservableObject {
    struct Message: Identifiable, Codable, Equatable, Sendable {
        enum Role: String, Codable, Sendable { case user, assistant, notice }
        var id = UUID()
        var role: Role
        var text: String
        var createdAt = Date()
    }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var streaming = ""
    @Published private(set) var activity: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isReady = false
    @Published private(set) var failure: String?

    private let projectID: UUID
    private weak var state: AppState?
    private var process: Process?
    private var input: FileHandle?
    private var bridge: ProjectToolBridge?
    private var output = LineBuffer()
    private var errors = LineBuffer()
    private var lastErrorLine: String?
    private var started = false
    private var nextPromptID = 1
    private var pendingText: String?

    init(projectID: UUID, state: AppState) {
        self.projectID = projectID
        self.state = state
        loadHistory()
    }

    var canSend: Bool { isReady && !isBusy }

    // MARK: - Lifecycle

    func startIfNeeded() {
        guard !started else { return }
        started = true
        failure = nil
        guard let state, let project = state.projects.first(where: { $0.id == projectID }) else {
            failure = "项目不存在或已被删除。"
            return
        }
        guard SettingsStore.shared.selectedAgent == .api else {
            failure = "AI 对话需要使用内置 Pi。请在设置里选择「内置 Pi」并填写连接信息。"
            return
        }
        guard let connection = try? SettingsStore.shared.apiConnection() else {
            failure = "请先在设置里连接 AI（基础地址、模型与密钥）。"
            return
        }
        guard let runtime = EmbeddedPi.chatRuntime else {
            failure = "内置 Pi 组件缺失，请重新安装应用。"
            return
        }

        let bridge = ProjectToolBridge()
        let targetProject = projectID
        do {
            try bridge.start { [weak state] call in
                guard let state else { return .failure("应用状态已释放。") }
                return ProjectTools.execute(call, projectID: targetProject, state: state)
            }
        } catch {
            failure = error.localizedDescription
            return
        }
        self.bridge = bridge

        let process = Process()
        process.executableURL = runtime.node
        process.arguments = [runtime.script.path]
        process.currentDirectoryURL = ProjectLayout.directory(for: project)
        var environment = EmbeddedPi.runtimeEnvironment(node: runtime.node)
        environment["SW_BRIDGE_PATH"] = bridge.path
        environment["SW_PROJECT_ID"] = projectID.uuidString
        process.environment = environment

        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        input = stdinPipe.fileHandleForWriting

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingest(data, error: false) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingest(data, error: true) }
        }
        process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            Task { @MainActor in self?.terminated(code: code) }
        }

        do {
            try process.run()
            self.process = process
        } catch {
            failure = "无法启动 AI 进程：\(error.localizedDescription)"
            bridge.stop()
            self.bridge = nil
            return
        }

        sendLine([
            "type": "init",
            "baseURL": connection.endpoint.baseURL.absoluteString,
            "model": connection.model,
            "key": connection.key,
            "images": SettingsStore.shared.aiAPIImages,
            "system": Self.systemPrompt(project: project),
        ])
    }

    func stop() {
        sendLine(["type": "shutdown"])
        process?.terminate()
        process = nil
        input = nil
        bridge?.stop()
        bridge = nil
        started = false
        isReady = false
        isBusy = false
        streaming = ""
        activity = nil
    }

    func abort() {
        guard isBusy else { return }
        sendLine(["type": "abort"])
        isBusy = false
        streaming = ""
        activity = nil
        append(.init(role: .notice, text: "已停止当前操作。"))
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        startIfNeeded()
        guard failure == nil else { return }
        guard isReady else {
            pendingText = trimmed
            return
        }
        deliver(trimmed)
    }

    private func deliver(_ text: String) {
        messages.append(.init(role: .user, text: text))
        persist()
        isBusy = true
        streaming = ""
        activity = nil
        failure = nil
        sendLine(["type": "prompt", "id": nextPromptID, "text": text])
        nextPromptID += 1
    }

    // MARK: - Events

    private func ingest(_ data: Data, error: Bool) {
        let lines = error ? errors.feed(data) : output.feed(data)
        if error {
            if let last = lines.last(where: { !$0.isEmpty }) { lastErrorLine = String(last.prefix(400)) }
            return
        }
        for line in lines where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            apply(type: type, event: event)
        }
    }

    private func apply(type: String, event: [String: Any]) {
        switch type {
        case "ready":
            isReady = true
            failure = nil
            activity = nil
            if let pending = pendingText {
                pendingText = nil
                deliver(pending)
            }
        case "delta":
            if let delta = event["text"] as? String { streaming += delta }
        case "tool":
            if let name = event["name"] as? String { activity = Self.toolLabel(name, detail: event["detail"] as? String) }
        case "tool_end":
            if let name = event["name"] as? String {
                let ok = event["ok"] as? Bool ?? false
                activity = Self.toolLabel(name, detail: nil) + (ok ? "完成" : "未通过")
            }
        case "notice":
            if let text = event["text"] as? String { activity = text }
        case "done":
            let text = (event["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let final = (text?.isEmpty == false ? text : nil) ?? streaming.trimmingCharacters(in: .whitespacesAndNewlines)
            if !final.isEmpty { append(.init(role: .assistant, text: final)) }
            finishTurn()
        case "error":
            let message = (event["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let message, !message.isEmpty { append(.init(role: .notice, text: message)) }
            finishTurn()
        default:
            break
        }
    }

    private func finishTurn() {
        isBusy = false
        streaming = ""
        activity = nil
        persist()
    }

    private func terminated(code: Int32) {
        guard started else { return }
        started = false
        isReady = false
        isBusy = false
        streaming = ""
        activity = nil
        bridge?.stop()
        bridge = nil
        process = nil
        input = nil
        if code != 0, failure == nil {
            failure = lastErrorLine.map { "AI 进程已退出：\($0)" } ?? "AI 进程已退出（\(code)）。再发一条消息会自动重连。"
        }
        lastErrorLine = nil
    }

    // MARK: - Plumbing

    private func append(_ message: Message) {
        messages.append(message)
        persist()
    }

    private func sendLine(_ payload: [String: Any]) {
        guard let input,
              let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var line = data
        line.append(0x0A)
        try? input.write(contentsOf: line)
    }

    private func historyURL() -> URL? {
        guard let state, let project = state.projects.first(where: { $0.id == projectID }) else { return nil }
        return ProjectLayout.url("assembly-chat.json", for: project)
    }

    private func loadHistory() {
        guard let url = historyURL(), let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([Message].self, from: data) else { return }
        messages = Array(saved.suffix(200))
    }

    private func persist() {
        guard let url = historyURL(), let data = try? JSONEncoder().encode(Array(messages.suffix(200))) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func toolLabel(_ name: String, detail: String?) -> String {
        let label: String
        switch name {
        case "project_read": label = "读取项目"
        case "clip_trim": label = "裁剪片段"
        case "clip_split": label = "分割片段"
        case "clip_move": label = "移动片段"
        case "clip_remove": label = "删除片段"
        case "subtitle_update": label = "修改字幕"
        case "subtitle_insert": label = "新增字幕"
        case "subtitle_delete": label = "删除字幕"
        case "subtitle_merge": label = "合并字幕"
        case "subtitle_split": label = "分割字幕"
        case "subtitle_move": label = "调整字幕时间"
        case "canvas_set": label = "设置画幅"
        case "insert_add": label = "添加补充画面"
        case "insert_remove": label = "移除补充画面"
        case "motion_regenerate": label = "重做动效"
        case "job_status": label = "查询任务"
        default: label = name.isEmpty ? "处理中" : name
        }
        guard let detail, !detail.isEmpty else { return label }
        return "\(label)：\(detail)"
    }

    private static func systemPrompt(project: VideoProject) -> String {
        """
        你是这个视频项目里的剪辑助手，直接操作项目，不要泛泛而谈。

        工作方式：
        - 动手前先调用 project_read 看当前状态。不要凭空猜片段、字幕序号或时间。
        - 用户说「素材一」「第一段」时指 clips 里 index 为 1 的片段；说「第 12 秒」时先判断是成片时间（timelineStart）还是原视频时间（in/out），不确定就按成片时间理解并在回复里说明。
        - 每次修改只调用需要的工具，看返回值确认成功；失败就换一种做法或直接告诉用户原因。
        - 动效重做（motion_regenerate）是后台渲染，耗时几分钟到几十分钟。调用后告诉用户已开始，可以用 job_status 查询；不要假装已经完成。
        - 所有修改都可以被用户撤销，所以可以大胆执行明确的指令；但删除片段、删除字幕这类破坏性操作要先确认一次。
        - 不要自己读写 project.json、transcript.json 或任何项目数据文件，那些由应用维护；需要通过工具。
        - 回复用简体中文，简短直接：做了什么、影响哪个片段/时间段、下一步是什么。不要复述工具参数。

        当前项目：\(project.name)，共 \(project.materials.count) 个片段。
        """
    }
}

/// Splits streamed bytes into lines without blocking the main actor.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func feed(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line.trimmingCharacters(in: .newlines))
            }
        }
        return lines
    }
}
