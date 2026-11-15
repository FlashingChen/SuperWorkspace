import Foundation

/// One request from the bundled agent: `{"id":1,"tool":"clip_trim","args":{...}}`.
struct ProjectToolCall: Decodable, Sendable {
    let id: Int
    let tool: String
    let args: [String: JSONValue]

    init(id: Int, tool: String, args: [String: JSONValue] = [:]) {
        self.id = id
        self.tool = tool
        self.args = args
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        tool = try container.decode(String.self, forKey: .tool)
        args = try container.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
    }

    private enum CodingKeys: String, CodingKey { case id, tool, args }
}

enum ProjectToolOutcome: Sendable {
    case success(JSONValue)
    case failure(String)
}

/// Serves project operations to the agent over a private Unix-domain socket.
/// The agent runs in its own process, so this is the only way it can reach the
/// live `AppState` (and therefore validation and undo). The socket sits in a
/// mode-0700 temporary directory.
final class ProjectToolBridge: @unchecked Sendable {
    let path: String
    private let directory: URL
    private let queue = DispatchQueue(label: "superworkspace.agent.bridge")
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false

    init() {
        // A Unix socket path is limited to ~104 bytes, so keep it short.
        let token = String(UUID().uuidString.prefix(8))
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("sw-agent-\(token)", isDirectory: true)
        directory = root
        path = root.appendingPathComponent("bridge.sock").path
    }

    func start(handler: @escaping @MainActor (ProjectToolCall) -> ProjectToolOutcome) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeError.socket(errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw BridgeError.pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw BridgeError.socket(code)
        }
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw BridgeError.socket(code)
        }
        stateLock.lock()
        listenFD = fd
        running = true
        stateLock.unlock()
        queue.async { [weak self] in self?.acceptLoop(handler) }
    }

    func stop() {
        stateLock.lock()
        running = false
        let fd = listenFD
        listenFD = -1
        stateLock.unlock()
        if fd >= 0 { close(fd) }
        try? FileManager.default.removeItem(at: directory)
    }

    private func acceptLoop(_ handler: @escaping @MainActor (ProjectToolCall) -> ProjectToolOutcome) {
        while true {
            stateLock.lock()
            let fd = listenFD
            let active = running
            stateLock.unlock()
            guard active, fd >= 0 else { break }
            let connection = accept(fd, nil, nil)
            if connection < 0 {
                if errno == EINTR { continue }
                break
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.serve(connection, handler: handler)
            }
        }
    }

    private func serve(_ fd: Int32, handler: @escaping @MainActor (ProjectToolCall) -> ProjectToolOutcome) {
        defer { close(fd) }
        let response: ProjectToolResponse
        if let line = Self.readMessage(fd), let call = try? JSONDecoder().decode(ProjectToolCall.self, from: line) {
            let box = OutcomeBox()
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                box.value = handler(call)
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 120) == .timedOut {
                response = ProjectToolResponse(id: call.id, outcome: .failure("项目操作超时"))
            } else {
                response = ProjectToolResponse(id: call.id, outcome: box.value)
            }
        } else {
            response = ProjectToolResponse(id: 0, outcome: .failure("无法解析项目操作请求"))
        }
        guard let data = try? JSONEncoder().encode(response) else { return }
        var payload = data
        payload.append(0x0A)
        payload.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = write(fd, base.advanced(by: written), buffer.count - written)
                if count <= 0 { break }
                written += count
            }
        }
    }

    private static func readMessage(_ fd: Int32) -> Data? {
        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &scratch, scratch.count)
            if count <= 0 { break }
            buffer.append(contentsOf: scratch[0..<count])
            if buffer.contains(0x0A) { break }
            if buffer.count > 1_048_576 { break }
        }
        guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
        return buffer[..<newline]
    }
}

private final class OutcomeBox: @unchecked Sendable {
    var value: ProjectToolOutcome = .failure("项目操作未完成")
}

private struct ProjectToolResponse: Encodable {
    let id: Int
    let ok: Bool
    let result: JSONValue?
    let error: String?

    init(id: Int, outcome: ProjectToolOutcome) {
        self.id = id
        switch outcome {
        case let .success(value):
            ok = true
            result = value
            error = nil
        case let .failure(message):
            ok = false
            result = nil
            error = message
        }
    }
}

enum BridgeError: LocalizedError {
    case socket(Int32)
    case pathTooLong

    var errorDescription: String? {
        switch self {
        case let .socket(code): return "无法启动项目操作通道（errno \(code)）。"
        case .pathTooLong: return "项目操作通道地址过长。"
        }
    }
}
