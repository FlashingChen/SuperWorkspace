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
        var edits: [String]? = nil
        var editSteps: Int? = nil
        var focusTime: Double? = nil
        var postTurnUndoRevision: Int? = nil
        var isUndone: Bool? = nil
        var createdAt = Date()
    }

    @Published private(set) var messages: [Message] = []
    @Published private(set) var streaming = ""
    @Published private(set) var activity: String?
    @Published private(set) var turnStartedAt: Date?
    @Published private(set) var isBusy = false
    @Published private(set) var isReady = false
    @Published private(set) var failure: String?

    private var turnEdits: [String] = []
    private var turnFocusTime: Double?
    private var turnStartUndoPushCount = 0
    private var lastTurnUndoRevision: Int?
    private var needsStateRefresh = false

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
    private var secret = ""

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
            started = false
            return
        }
        guard let connection = try? SettingsStore.shared.apiConnection() else {
            failure = "AI 对话需要内置 Pi 连接。请先在设置里填写 API 基础地址、模型与密钥。"
            started = false
            return
        }
        secret = connection.key
        guard let runtime = EmbeddedPi.chatRuntime else {
            failure = "内置 Pi 组件缺失，请重新安装应用。"
            started = false
            return
        }

        let bridge = ProjectToolBridge()
        let targetProject = projectID
        do {
            try bridge.start { [weak self, weak state] call in
                guard let state else { return .failure("应用状态已释放。") }
                let outcome = ProjectTools.execute(call, projectID: targetProject, state: state)
                self?.recordToolFocus(call: call, outcome: outcome, projectID: targetProject, state: state)
                return outcome
            }
        } catch {
            failure = error.localizedDescription
            bridge.stop()
            self.bridge = nil
            started = false
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
            started = false
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

    private var pendingContextNote: String?

    func send(_ text: String, contextNote: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        startIfNeeded()
        // A configuration failure is reported by startIfNeeded; a crashed child is
        // restarted there and the message waits until the new session is ready.
        guard started else { return }
        guard isReady else {
            pendingText = trimmed
            pendingContextNote = contextNote
            return
        }
        deliver(trimmed, contextNote: contextNote)
    }

    func canUndoTurn(messageID: UUID) -> Bool {
        guard let state, state.canUndo, !isBusy,
              let latest = messages.last(where: { $0.role == .assistant && !($0.edits ?? []).isEmpty }),
              latest.id == messageID,
              latest.isUndone != true,
              let steps = latest.editSteps, steps > 0,
              let expectedRev = latest.postTurnUndoRevision else { return false }
        return state.undoRevision == expectedRev
    }

    func undoTurn(messageID: UUID) {
        guard canUndoTurn(messageID: messageID),
              let state,
              let idx = messages.firstIndex(where: { $0.id == messageID }),
              let steps = messages[idx].editSteps, steps > 0 else { return }
        for _ in 0..<steps { state.undo() }
        messages[idx].isUndone = true
        needsStateRefresh = true
        lastTurnUndoRevision = state.undoRevision
        persist()
    }

    private func deliver(_ text: String, contextNote: String? = nil) {
        messages.append(.init(role: .user, text: text))
        persist()
        isBusy = true
        turnStartedAt = Date()
        turnEdits = []
        turnFocusTime = nil
        turnStartUndoPushCount = state?.undoPushCount(for: projectID) ?? 0
        streaming = ""
        activity = nil
        failure = nil
        var prefixParts: [String] = []
        if let contextNote, !contextNote.isEmpty { prefixParts.append(contextNote) }
        let currentRev = state?.undoRevision
        if needsStateRefresh || (lastTurnUndoRevision != nil && currentRev != lastTurnUndoRevision) {
            prefixParts.append("重要：项目在上一轮之后发生了手动修改或撤销，先前对话中记住的时长、倍速、花字、动效或字幕状态已过期；请先调用 project_read 获取最新状态再回答或操作。")
            needsStateRefresh = false
        }
        let payload = prefixParts.isEmpty ? text : "[\(prefixParts.joined(separator: " | "))]\n\(text)"
        sendLine(["type": "prompt", "id": nextPromptID, "text": payload])
        nextPromptID += 1
    }

    private func recordToolFocus(call: ProjectToolCall, outcome: ProjectToolOutcome, projectID: UUID, state: AppState) {
        guard Self.isMutatingTool(call.tool), case .success(let value) = outcome else { return }
        var candidate: Double?
        if case .object(let dict) = value {
            if let t = dict["timelineStart"]?.numberValue {
                candidate = t
            } else if ["motion_html_add", "motion_html_update", "callout_add", "callout_update", "audio_add", "audio_update"].contains(call.tool),
                      let s = dict["start"]?.numberValue {
                candidate = s
            } else if let clipIDString = dict["clip"]?.stringValue, let clipUUID = UUID(uuidString: clipIDString),
                      let project = state.projects.first(where: { $0.id == projectID }) {
                let layout = AssemblyTimelineLayout(materials: project.materials)
                if let clip = layout.clips.first(where: { $0.id == clipUUID }) {
                    if let sourceStart = dict["start"]?.numberValue {
                        let mat = project.materials[clip.index]
                        candidate = clip.start + max(0, sourceStart - mat.inPoint) / mat.playbackSpeed
                    } else {
                        candidate = clip.start
                    }
                }
            }
        }
        if let candidate, candidate.isFinite {
            if let existing = turnFocusTime {
                turnFocusTime = min(existing, candidate)
            } else {
                turnFocusTime = candidate
            }
        }
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
                let context = pendingContextNote
                pendingText = nil
                pendingContextNote = nil
                deliver(pending, contextNote: context)
            }
        case "delta":
            if let delta = event["text"] as? String { streaming += delta }
        case "tool":
            if let name = event["name"] as? String { activity = Self.toolLabel(name, detail: event["detail"] as? String) }
        case "tool_end":
            if let name = event["name"] as? String {
                let ok = event["ok"] as? Bool ?? false
                let label = Self.toolLabel(name, detail: nil)
                activity = label + (ok ? "完成" : "未通过")
                if ok && Self.isMutatingTool(name) {
                    turnEdits.append(label)
                }
            }
        case "notice":
            if let text = event["text"] as? String { activity = sanitize(text) }
        case "done":
            let text = (event["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let final = (text?.isEmpty == false ? text : nil) ?? streaming.trimmingCharacters(in: .whitespacesAndNewlines)
            let edits = turnEdits.isEmpty ? nil : turnEdits
            let actualSteps = max(0, (state?.undoPushCount(for: projectID) ?? turnStartUndoPushCount) - turnStartUndoPushCount)
            let steps = actualSteps > 0 ? actualSteps : nil
            let focus = turnFocusTime
            let postRev = actualSteps > 0 ? state?.undoRevision : nil
            if !final.isEmpty || edits != nil {
                append(.init(role: .assistant, text: final, edits: edits, editSteps: steps, focusTime: focus, postTurnUndoRevision: postRev))
            }
            finishTurn()
        case "error":
            let message = (event["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let message, !message.isEmpty { append(.init(role: .notice, text: sanitize(message))) }
            finishTurn()
        default:
            break
        }
    }

    private func finishTurn() {
        isBusy = false
        turnStartedAt = nil
        turnEdits = []
        turnFocusTime = nil
        lastTurnUndoRevision = state?.undoRevision
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
            failure = lastErrorLine.map { sanitize("AI 进程已退出：\($0)") } ?? "AI 进程已退出（\(code)）。再发一条消息会自动重连。"
        }
        lastErrorLine = nil
    }

    // MARK: - Plumbing

    private func append(_ message: Message) {
        messages.append(message)
        persist()
    }

    private func sanitize(_ text: String) -> String {
        guard !secret.isEmpty else { return text }
        return text.replacingOccurrences(of: secret, with: "[redacted]")
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
        case "clip_speed": label = "调整倍速"
        case "clip_rename": label = "重命名片段"
        case "subtitle_update": label = "修改字幕"
        case "subtitle_insert": label = "新增字幕"
        case "subtitle_delete": label = "删除字幕"
        case "subtitle_merge": label = "合并字幕"
        case "subtitle_split": label = "分割字幕"
        case "subtitle_move": label = "调整字幕时间"
        case "canvas_set": label = "设置画幅"
        case "insert_add": label = "添加补充画面"
        case "insert_update": label = "调整补充画面"
        case "insert_remove": label = "移除补充画面"
        case "audio_add": label = "添加音乐/音效"
        case "audio_update": label = "调整音乐/音效"
        case "audio_remove": label = "移除音乐/音效"
        case "callout_add": label = "添加花字标注"
        case "callout_update": label = "调整花字标注"
        case "callout_remove": label = "移除花字标注"
        case "silence_analyze": label = "分析静音停顿"
        case "motion_html_add": label = "生成即时动效"
        case "motion_html_update": label = "更新即时动效"
        case "motion_html_remove": label = "移除即时动效"
        case "motion_regenerate": label = "重做 Remotion 动效"
        case "job_status": label = "查询任务"
        default: label = name.isEmpty ? "处理中" : name
        }
        guard let detail, !detail.isEmpty else { return label }
        return "\(label)：\(detail)"
    }

    static func isMutatingTool(_ name: String) -> Bool {
        [
            "clip_trim", "clip_split", "clip_move", "clip_remove", "clip_speed", "clip_rename",
            "subtitle_update", "subtitle_insert", "subtitle_delete", "subtitle_merge", "subtitle_split", "subtitle_move",
            "canvas_set",
            "insert_add", "insert_update", "insert_remove",
            "audio_add", "audio_update", "audio_remove",
            "callout_add", "callout_update", "callout_remove",
            "motion_html_add", "motion_html_update", "motion_html_remove",
            "motion_regenerate",
        ].contains(name)
    }

    private static func systemPrompt(project: VideoProject) -> String {
        """
        你是这个视频项目里的全权剪辑导演，直接操作项目轨道，不要泛泛而谈。

        你能直接做的事：
        - 结构与节奏：裁剪片段（clip_trim）、切分片段（clip_split）、排序（clip_move）、调速（clip_speed，局部加速先切分再调速）、重命名（clip_rename）、扫描静音停顿（silence_analyze）并自动剪掉多余空白。
        - 视觉包装：
          * 即时动效（motion_html_add/update/remove）：**优先用于片头动画、章节转场、动态流程图、界面高亮框/箭头、步骤进度条、自定义酷炫花字**——直接写单文件 HTML/CSS/SVG，秒级生效、实时预览、可强制覆盖在任何片段和任何时间点（overlay 透明叠加，fullscreen 满屏覆盖）。
          * 快捷花字（callout_add/update/remove）：4 种内置 Studio 风格静态标注（大标题/角标/重点气泡/下三分之一信息条）。
          * 补充画面（insert_add/update/remove）、画幅切换（canvas_set）、后台重做或定向微调 Remotion 动效（motion_regenerate：当片段有 motionManifest 且用户指出某一秒或某分镜有问题时，传 shotID 或 atTime 做分镜级后台增量微调，未改动分镜会命中缓存）。
        - 声音与字幕：添加背景音乐或音效（audio_add/update/remove，音乐自动支持淡入淡出与人声避让）、增删改合分字幕（subtitle_*）。

        工作方式：
        - 动手前先调用 project_read 看当前状态。不要凭空猜片段、字幕序号或时间。
        - 如果用户消息开头附带了「编辑器焦点」信息（如当前播放头、当前选中的片段或字幕），用户说「这里」「这段」「这条」时优先按该焦点理解。
        - 用户说「素材一」「第一段」或片段名称时，对应 project_read 返回的 clips；说「第 12 秒」时先判断是成片时间（timelineStart）还是原视频时间（in/out），不确定就按成片时间理解并在回复里说明。
        - 每次修改只调用需要的工具，看返回值确认成功；失败就换一种做法或直接告诉用户原因。
        - 动效重做/定向微调（motion_regenerate）在后台执行，不阻塞当前对话与剪辑。调用后告诉用户已派发（若是分镜微调可说明目标分镜），可用 job_status 查询进度；不要假装已经完成。
        - 所有修改都可以被用户撤销，所以可以大胆执行明确的指令；但删除整个片段这类破坏性操作要先确认一次。
        - 不要自己读写 project.json、transcript.json 或任何项目数据文件，那些由应用维护；必须通过工具。
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
