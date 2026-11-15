import XCTest
@testable import SuperWorkspace

@MainActor
final class ProjectToolBridgeTests: XCTestCase {
    private struct Reply: Decodable, Sendable {
        let ok: Bool
        let result: JSONValue?
        let error: String?
    }

    func testBridgeAnswersOneCallPerConnection() async throws {
        let bridge = ProjectToolBridge()
        try bridge.start { call in
            .success(.object([("echo", .string(call.tool)), ("id", .number(Double(call.id)))]))
        }
        defer { bridge.stop() }

        let response = await Self.request(path: bridge.path, tool: "project_read")
        let reply = try XCTUnwrap(response)
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.result?["echo"]?.stringValue, "project_read")
        XCTAssertEqual(reply.result?["id"]?.intValue, 7)
    }

    func testBridgeReportsToolFailure() async throws {
        let bridge = ProjectToolBridge()
        try bridge.start { _ in .failure("not allowed") }
        defer { bridge.stop() }

        let response = await Self.request(path: bridge.path, tool: "clip_trim")
        let reply = try XCTUnwrap(response)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.error, "not allowed")
    }

    /// The bridge answers on a background thread and calls its handler on the main actor, so the
    /// request must not run on the main actor itself. A GCD continuation keeps that off-main jump
    /// explicit and avoids the region-based isolation checker bug that `Task.detached` trips on
    /// the release runner's toolchain.
    private nonisolated static func request(path: String, tool: String) async -> Reply? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: call(path: path, tool: tool))
            }
        }
    }

    private nonisolated static func call(path: String, tool: String) -> Reply? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        guard connected == 0 else { return nil }
        let request = #"{"id":7,"tool":"\#(tool)","args":{}}"# + "\n"
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var data = Data()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &scratch, scratch.count)
            if count <= 0 { break }
            data.append(contentsOf: scratch[0..<count])
            if data.contains(0x0A) { break }
        }
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        return try? JSONDecoder().decode(Reply.self, from: data[..<newline])
    }
}
