import Foundation

/// Synchronous CLI client invoked via `SuperWorkspace cli <subcommand> ...`.
/// Connects to the running app over `control.sock` and prints JSON to stdout.
enum AutomationCLI {
    static func runIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "cli" else { return }
        let subargs = Array(args.dropFirst())
        do {
            let request = try parseRequest(subargs)
            let response = try send(request, socketPath: AutomationServer.socketPath)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(response), let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            exit(response.ok ? 0 : 1)
        } catch {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let failure = AutomationResponse.failure(error.localizedDescription)
            if let data = try? encoder.encode(failure), let text = String(data: data, encoding: .utf8) {
                print(text)
            } else {
                fputs("error: \(error.localizedDescription)\n", stderr)
            }
            exit(1)
        }
    }

    static func parseRequest(_ args: [String]) throws -> AutomationRequest {
        guard let first = args.first else {
            throw CLIError.usage
        }
        let rest = Array(args.dropFirst())
        switch first {
        case "status":
            return AutomationRequest(command: "status")
        case "windows":
            return AutomationRequest(command: "windows")
        case "project":
            return AutomationRequest(command: "project")
        case "resize":
            let flags = parseFlags(rest)
            var payload: [String: JSONValue] = [:]
            if let id = flags["window"].flatMap(Double.init) { payload["windowID"] = .number(id) }
            if let w = flags["width"].flatMap(Double.init) { payload["width"] = .number(w) }
            if let h = flags["height"].flatMap(Double.init) { payload["height"] = .number(h) }
            if let x = flags["x"].flatMap(Double.init) { payload["x"] = .number(x) }
            if let y = flags["y"].flatMap(Double.init) { payload["y"] = .number(y) }
            return AutomationRequest(command: "resize", args: payload)
        case "input":
            guard let action = rest.first else { throw CLIError.usage }
            let flags = parseFlags(Array(rest.dropFirst()))
            var payload: [String: JSONValue] = [:]
            switch action {
            case "move":
                if let x = flags["x"].flatMap(Double.init) { payload["x"] = .number(x) }
                if let y = flags["y"].flatMap(Double.init) { payload["y"] = .number(y) }
                if let d = flags["duration"].flatMap(Double.init) { payload["duration"] = .number(d) }
                return AutomationRequest(command: "input_move", args: payload)
            case "click":
                if let x = flags["x"].flatMap(Double.init) { payload["x"] = .number(x) }
                if let y = flags["y"].flatMap(Double.init) { payload["y"] = .number(y) }
                return AutomationRequest(command: "input_click", args: payload)
            case "key":
                if let code = flags["code"].flatMap(Double.init) { payload["keyCode"] = .number(code) }
                if flags["cmd"] != nil { payload["command"] = .bool(true) }
                if flags["shift"] != nil { payload["shift"] = .bool(true) }
                return AutomationRequest(command: "input_key", args: payload)
            case "paste":
                if let text = flags["text"] { payload["text"] = .string(text) }
                return AutomationRequest(command: "input_paste", args: payload)
            default:
                throw CLIError.usage
            }
        case "export":
            let flags = parseFlags(rest)
            var payload: [String: JSONValue] = [:]
            if let sub = flags["subtitles"] {
                payload["includeSubtitles"] = .bool(sub != "off" && sub != "false" && sub != "0")
            }
            if flags["srt"] != nil {
                payload["exportSRT"] = .bool(true)
            }
            return AutomationRequest(command: "export", args: payload)
        case "record":
            guard let action = rest.first else { throw CLIError.usage }
            let flags = parseFlags(Array(rest.dropFirst()))
            if action == "start" {
                var payload: [String: JSONValue] = [:]
                if let id = flags["window"].flatMap(Double.init) { payload["windowID"] = .number(id) }
                if let app = flags["app"] { payload["appName"] = .string(app) }
                if let display = flags["display"].flatMap(Double.init) { payload["displayID"] = .number(display) }
                if let audio = flags["system-audio"] {
                    payload["systemAudio"] = .bool(audio != "off" && audio != "false" && audio != "0")
                }
                if let fps = flags["fps"].flatMap(Double.init) { payload["fps"] = .number(fps) }
                if let project = flags["project"] { payload["projectName"] = .string(project) }
                return AutomationRequest(command: "record_start", args: payload)
            } else if action == "stop" {
                var payload: [String: JSONValue] = [:]
                if flags["motion"] != nil { payload["wantsMotion"] = .bool(true) }
                if flags["raw"] != nil { payload["styled"] = .bool(false) }
                if flags["styled"] != nil { payload["styled"] = .bool(true) }
                if let prompt = flags["prompt"] { payload["editingPrompt"] = .string(prompt) }
                return AutomationRequest(command: "record_stop", args: payload)
            }
            throw CLIError.usage
        default:
            throw CLIError.usage
        }
    }

    private static func parseFlags(_ args: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var i = 0
        while i < args.count {
            let token = args[i]
            if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    result[key] = args[i + 1]
                    i += 2
                } else {
                    result[key] = "true"
                    i += 1
                }
            } else {
                i += 1
            }
        }
        return result
    }

    static func send(_ request: AutomationRequest, socketPath: String) throws -> AutomationResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError.socketFailed("socket() failed") }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw CLIError.socketFailed("socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { dest in
            dest.copyBytes(from: bytes)
        }
        let connected = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                connect(fd, sock, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw CLIError.appNotRunning
        }

        var payload = try JSONEncoder().encode(request)
        payload.append(UInt8(ascii: "\n"))
        try payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < payload.count {
                let n = write(fd, base.advanced(by: written), payload.count - written)
                guard n > 0 else { throw CLIError.socketFailed("write() failed") }
                written += n
            }
        }

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            responseData.append(buffer, count: n)
            if buffer[0..<n].contains(UInt8(ascii: "\n")) { break }
        }
        guard !responseData.isEmpty else {
            throw CLIError.socketFailed("empty response")
        }
        return try JSONDecoder().decode(AutomationResponse.self, from: responseData)
    }

    enum CLIError: LocalizedError {
        case usage
        case appNotRunning
        case socketFailed(String)

        var errorDescription: String? {
            switch self {
            case .usage:
                "用法: SuperWorkspace cli <status|windows|resize|record start|record stop|project|export>"
            case .appNotRunning:
                "SuperWorkspace 未运行或控制接口未就绪，请先启动 SuperWorkspace.app。"
            case let .socketFailed(msg):
                "本地控制通信失败：\(msg)"
            }
        }
    }
}
