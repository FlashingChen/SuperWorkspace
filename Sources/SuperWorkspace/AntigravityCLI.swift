import AppKit
import Darwin
import Foundation

/// Adapter for Google Antigravity CLI (`agy`) using its official headless NDJSON
/// streaming protocol (`--input-format stream-json --output-format stream-json`)
/// and `agy models` catalog discovery. Never reads or proxies local credentials.
enum AntigravityCLI {
    struct Model: Identifiable, Equatable, Sendable {
        let slug: String
        let name: String
        var id: String { slug }
    }

    enum AccountState: Equatable, Sendable {
        case unknown
        case checking
        case signedIn
        case signedOut
        case signingIn
    }

    struct StreamUpdate: Equatable, Sendable {
        var event: String = ""
        var conversationID: String?
        var state: String?
        var stepIndex: Int?
        var toolName: String?
        var toolDetail: String?
        var finishedTool: Bool = false
        var textDelta: String?
        var responseText: String?
        var status: String?
        var error: String?
    }

    struct StreamDecoder: Sendable {
        private var steps: [Int: String] = [:]

        mutating func consume(_ event: [String: Any]) -> StreamUpdate {
            var update = StreamUpdate()
            update.event = event["event"] as? String ?? ""
            update.conversationID = event["conversation_id"] as? String
            switch update.event {
            case "init":
                break
            case "step_update":
                guard let step = event["step_update"] as? [String: Any] else { return update }
                let state = step["state"] as? String
                update.state = state
                update.stepIndex = step["step_index"] as? Int
                update.conversationID = step["conversation_id"] as? String ?? update.conversationID
                if step["step_type"] as? String == "tool" {
                    update.toolName = step["tool_name"] as? String
                    let info = step["tool_info"] as? [String: Any]
                    if let params = info?["parameters"] as? [String: Any] {
                        update.toolDetail = Self.compactDetail(from: params)
                    }
                    if state == "DONE" { update.finishedTool = true }
                } else if step["step_type"] as? String == "agent_response", let index = update.stepIndex {
                    if let delta = step["text_delta"] as? String, !delta.isEmpty {
                        steps[index, default: ""] += delta
                        update.textDelta = delta
                    }
                }
            case "result":
                guard let result = event["result"] as? [String: Any] else { return update }
                update.conversationID = result["conversation_id"] as? String ?? update.conversationID
                update.status = (result["status"] as? String)?.uppercased() ?? "ERROR"
                if let response = result["response"] as? String {
                    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { update.responseText = trimmed }
                }
                if update.responseText == nil {
                    let assembled = steps.keys.sorted()
                        .compactMap { steps[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n\n")
                    if !assembled.isEmpty { update.responseText = assembled }
                }
                if update.status != "SUCCESS" {
                    update.error = result["error"] as? String
                        ?? (result["error"] as? [String: Any])?["message"] as? String
                        ?? "Antigravity CLI 返回失败（\(update.status ?? "ERROR")）。"
                }
                steps = [:]
            case "error":
                update.status = "ERROR"
                update.error = event["message"] as? String
                    ?? event["error"] as? String
                    ?? (event["error"] as? [String: Any])?["message"] as? String
                    ?? "Antigravity CLI 执行出错。"
            default:
                break
            }
            return update
        }

        private static func compactDetail(from parameters: [String: Any]) -> String? {
            for key in ["CommandLine", "command", "Path", "path", "TargetFile", "Query", "query"] {
                if let value = parameters[key] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return String(trimmed.prefix(120)) }
                }
            }
            return nil
        }
    }

    // MARK: - Discovery & Sign-In

    static var searchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let userDirs = [
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
        ]
        let envDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        var result: [String] = []
        for dir in envDirs + ToolPaths.installDirectories + userDirs where !dir.isEmpty && !result.contains(dir) {
            result.append(dir)
        }
        return result
    }

    static func locate(customPath: String = "") -> String? {
        let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           URL(fileURLWithPath: trimmed).lastPathComponent == "agy",
           Shell.check(trimmed) {
            return trimmed
        }
        for directory in searchDirectories {
            let candidate = "\(directory)/agy"
            if Shell.check(candidate) { return candidate }
        }
        return nil
    }

    /// Parses `agy models` output (`slug\tDisplay Name` or multi-space separated).
    static func models(from output: String) -> [Model] {
        var seen = Set<String>()
        return output.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            let separator = line.range(of: "\t")
                ?? line.range(of: #"\s{2,}"#, options: .regularExpression)
            guard let separator else { return nil }
            let slug = String(line[..<separator.lowerBound])
            let name = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            guard slug.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/-]*$"#, options: .regularExpression) != nil,
                  !name.isEmpty,
                  slug.lowercased() != "model",
                  seen.insert(slug).inserted else { return nil }
            return Model(slug: slug, name: name)
        }
    }

    /// Checks saved login state and fetches available models via `agy models`.
    static func discoverModels(executable: String, timeout: TimeInterval = 30) async -> (AccountState, [Model]) {
        do {
            let output = try await Shell.run(executable, arguments: ["models"], timeout: timeout)
            let catalog = models(from: output)
            if !catalog.isEmpty {
                return (.signedIn, catalog)
            }
            return (looksSignedOut(output) ? .signedOut : .unknown, [])
        } catch let error as ShellError {
            return (looksSignedOut(error.output) ? .signedOut : .unknown, [])
        } catch {
            return (.unknown, [])
        }
    }

    static func looksSignedOut(_ output: String) -> Bool {
        let lower = output.lowercased()
        let signals = ["not authenticated", "unauthenticated", "sign in", "login", "log in", "unauthorized", "authenticate"]
        return signals.contains { lower.contains($0) }
    }

    /// Opens macOS Terminal so the user can authenticate natively inside `agy`.
    @MainActor
    static func openTerminalSignIn(executable: String) {
        let escaped = executable.replacingOccurrences(of: "'", with: "'\\''")
        let script = "tell application \"Terminal\" to do script \"'\(escaped)'\"\ntell application \"Terminal\" to activate"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    // MARK: - Headless Motion Execution

    static func motionArguments(model: String, extraArgs: [String] = []) -> [String] {
        var arguments = [
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--dangerously-skip-permissions",
        ]
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedModel.isEmpty {
            arguments += ["--model", trimmedModel]
        }
        arguments += extraArgs
        return arguments
    }

    static func runMotion(
        executable: String,
        model: String,
        extraArgs: [String] = [],
        system: String,
        prompt: String,
        directory: URL,
        timeout: TimeInterval,
        prepareRemotion: Bool = true,
        onProgress: (@Sendable (EmbeddedPi.Progress) -> Void)? = nil
    ) async throws -> String {
        var environment = ProcessInfo.processInfo.environment
        let node = EmbeddedPi.bundledNode ?? ToolPaths.locate("node").map { URL(fileURLWithPath: $0) }
        var pathEntries: [String] = []
        if let node {
            let piEnv = EmbeddedPi.runtimeEnvironment(node: node)
            if let swBin = piEnv["SUPERWORKSPACE_BIN"] { environment["SUPERWORKSPACE_BIN"] = swBin }
            if let piPath = piEnv["PATH"] {
                pathEntries.append(contentsOf: piPath.split(separator: ":").map(String.init))
            }
            if prepareRemotion {
                try await RemotionRuntime.prepare(in: directory, node: node, environment: piEnv)
            }
        }
        let executableDir = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        for dir in [executableDir] + searchDirectories where !dir.isEmpty && !pathEntries.contains(dir) {
            pathEntries.append(dir)
        }
        environment["PATH"] = pathEntries.joined(separator: ":")

        let fullSystem = prepareRemotion ? system + "\n\n" + RemotionRuntime.instructions : system
        let combinedPrompt = fullSystem + "\n\n" + prompt

        return try await runStreamTurn(
            executable: executable,
            arguments: motionArguments(model: model, extraArgs: extraArgs),
            prompt: combinedPrompt,
            workingDirectory: directory,
            environment: environment,
            timeout: timeout,
            onProgress: onProgress
        )
    }

    /// Executes one headless turn over `agy --input-format stream-json --output-format stream-json`.
    /// Keeps `stdout` NDJSON cleanly separated from `stderr` diagnostics and closes `stdin` once
    /// the `result` event arrives.
    static func runStreamTurn(
        executable: String,
        arguments: [String],
        prompt: String,
        workingDirectory: URL,
        environment: [String: String],
        timeout: TimeInterval,
        onProgress: (@Sendable (EmbeddedPi.Progress) -> Void)? = nil
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let state = StreamRunState(onProgress: onProgress)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            state.ingestStdout(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            state.ingestStderr(data)
        }

        try process.run()
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        var payload = try JSONSerialization.data(withJSONObject: [
            "event": "user",
            "message": ["content": prompt],
        ])
        payload.append(0x0A)

        let startedAt = Date()
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: payload)
            var closedInput = false
            var resultSeenAt: Date?
            while process.isRunning {
                try Task.checkCancellation()
                if Date().timeIntervalSince(startedAt) >= timeout {
                    throw ShellError.exitStatus(-1, "Antigravity CLI 任务超时，请重试。")
                }
                if state.hasResult {
                    if !closedInput {
                        try? stdinPipe.fileHandleForWriting.close()
                        closedInput = true
                        resultSeenAt = Date()
                    } else if let seen = resultSeenAt, Date().timeIntervalSince(seen) >= 2.0 {
                        process.terminate()
                        break
                    }
                }
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch {
            if process.isRunning { process.terminate() }
            try? stdinPipe.fileHandleForWriting.close()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        try? stdinPipe.fileHandleForWriting.close()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let trailingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !trailingOut.isEmpty { state.ingestStdout(trailingOut) }
        let trailingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !trailingErr.isEmpty { state.ingestStderr(trailingErr) }
        state.finish()

        let outcome = state.outcome()
        if let error = outcome.error {
            throw ShellError.exitStatus(process.terminationStatus == 0 ? -1 : process.terminationStatus, error)
        }
        if outcome.status == "SUCCESS" {
            return outcome.response
        }
        if process.terminationStatus != 0 {
            let detail = outcome.diagnostics.isEmpty ? "Antigravity CLI 异常退出。" : outcome.diagnostics
            throw ShellError.exitStatus(process.terminationStatus, String(detail.suffix(2000)))
        }
        if !outcome.response.isEmpty {
            return outcome.response
        }
        let fallback = outcome.diagnostics.isEmpty ? "Antigravity CLI 未返回结果。" : outcome.diagnostics
        throw ShellError.exitStatus(-1, String(fallback.suffix(2000)))
    }
}

private final class StreamRunState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "superworkspace.antigravity.stream")
    private let onProgress: (@Sendable (EmbeddedPi.Progress) -> Void)?
    private var stdoutBuffer = Data()
    private var decoder = AntigravityCLI.StreamDecoder()
    private var diagnostics = ""
    private var statusValue: String?
    private var responseValue = ""
    private var errorValue: String?
    private var toolCount = 0

    init(onProgress: (@Sendable (EmbeddedPi.Progress) -> Void)?) {
        self.onProgress = onProgress
    }

    var hasResult: Bool {
        queue.sync { statusValue != nil || errorValue != nil }
    }

    func ingestStdout(_ data: Data) {
        queue.async {
            self.stdoutBuffer.append(data)
            self.drainLines(flushRemaining: false)
        }
    }

    func ingestStderr(_ data: Data) {
        queue.async {
            let text = String(decoding: data, as: UTF8.self)
            self.diagnostics = String((self.diagnostics + text).suffix(16_000))
        }
    }

    func finish() {
        queue.sync {
            self.drainLines(flushRemaining: true)
        }
    }

    func outcome() -> (status: String?, response: String, error: String?, diagnostics: String) {
        queue.sync {
            (statusValue, responseValue, errorValue, diagnostics.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func drainLines(flushRemaining: Bool) {
        if flushRemaining, !stdoutBuffer.isEmpty, stdoutBuffer.last != 0x0A {
            stdoutBuffer.append(0x0A)
        }
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newline]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            guard !lineData.isEmpty else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                let text = String(decoding: lineData, as: UTF8.self)
                diagnostics = String((diagnostics + text + "\n").suffix(16_000))
                continue
            }
            let update = decoder.consume(json)
            handle(update)
        }
    }

    private func handle(_ update: AntigravityCLI.StreamUpdate) {
        if update.event == "init" {
            emit(type: "start")
        }
        if let toolName = update.toolName, !toolName.isEmpty {
            if update.finishedTool {
                emit(type: "tool_end", name: toolName, ok: true)
            } else {
                toolCount += 1
                emit(type: "tool", n: toolCount, name: toolName, detail: update.toolDetail)
            }
        }
        if let text = update.responseText, !text.isEmpty {
            responseValue = text
        }
        if let status = update.status {
            statusValue = status
            if status == "SUCCESS" {
                emit(type: "done", tools: toolCount)
            }
        }
        if let error = update.error, !error.isEmpty {
            errorValue = error
        }
    }

    private func emit(type: String, n: Int? = nil, name: String? = nil, detail: String? = nil, ok: Bool? = nil, tools: Int? = nil) {
        guard let onProgress else { return }
        var object: [String: Any] = ["type": type]
        if let n { object["n"] = n }
        if let name { object["name"] = name }
        if let detail { object["detail"] = detail }
        if let ok { object["ok"] = ok }
        if let tools { object["tools"] = tools }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let progress = try? JSONDecoder().decode(EmbeddedPi.Progress.self, from: data) else { return }
        onProgress(progress)
    }
}
