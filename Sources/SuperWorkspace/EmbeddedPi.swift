import Foundation

enum EmbeddedPi {
    static var isAvailable: Bool { runtime != nil }

    private static var runtime: (node: URL, runner: URL)? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("PiRuntime") else { return nil }
        let node = root.appendingPathComponent("node/bin/node")
        let runner = root.appendingPathComponent("run.mjs")
        guard Shell.check(node.path), FileManager.default.isReadableFile(atPath: runner.path) else { return nil }
        return (node, runner)
    }

    struct ImageAttachment: Encodable, Sendable {
        let type = "image"
        let data: Data
        let mimeType: String
    }

    /// A live progress record streamed by the bundled runner on stderr.
    /// Lines look like `SW_PROGRESS {"type":"tool","n":3,"name":"bash",...}`.
    struct Progress: Decodable, Sendable, Equatable {
        static let prefix = "SW_PROGRESS "

        let type: String
        let n: Int?
        let name: String?
        let detail: String?
        let ms: Int?
        let ok: Bool?
        let attempt: Int?
        let max: Int?
        let delayMs: Int?
        let error: String?
        let reason: String?
        let limit: Double?
        let tools: Int?
        let success: Bool?

        init?(line: String) {
            guard line.hasPrefix(Self.prefix) else { return nil }
            let json = String(line.dropFirst(Self.prefix.count))
            guard let decoded = try? JSONDecoder().decode(Progress.self, from: Data(json.utf8)) else { return nil }
            self = decoded
        }

        /// Removes progress records from a merged stdout/stderr log. A tail-cut log can start
        /// mid-record, so fragments without the prefix are recognised by their JSON shape too.
        static func stripping(from log: String) -> String {
            log.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { line in
                    if line.hasPrefix(prefix) { return false }
                    if line.contains("\"type\":\"") && line.contains("\"at\":") { return false }
                    return true
                }
                .joined(separator: "\n")
        }
    }

    /// Asks the runner to nudge the agent before the hard stop so a finished render is not lost.
    private struct WrapUp: Encodable, Sendable {
        let ratio: Double
    }

    private struct RetryPolicy: Encodable, Sendable {
        let enabled = true
        let maxRetries = 3
        let baseDelayMs = 2000
    }

    private struct Request: Encodable {
        let baseURL: String
        let model: String
        let key: String
        let system: String
        let prompt: String
        let tools: Bool
        let images: Bool
        let attachments: [ImageAttachment]
        let budgetMinutes: Int
        let budgetToolCalls: Int
        let webSearch: Bool
        let workspaceTools: Bool
        let searchKey: String
        let retry: RetryPolicy
        let wrapUpRatio: Double
    }

    static func run(_ connection: AIConnection, system: String, prompt: String, directory: URL,
                    tools: Bool, images: Bool = false, attachments: [ImageAttachment] = [], timeout: TimeInterval,
                    budgetMinutes: Int = 30, budgetToolCalls: Int = 100,
                    webSearch: Bool = false, workspaceTools: Bool = true, searchKey: String = "",
                    prepareRemotion: Bool = true,
                    onProgress: (@Sendable (Progress) -> Void)? = nil) async throws -> String {
        guard let runtime else {
            throw ShellError.exitStatus(-1, "内置 Pi 组件缺失，请重新安装应用。")
        }
        let permittedVariables: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"]
        var environment = ProcessInfo.processInfo.environment.filter { permittedVariables.contains($0.key) }
        let bundledPaths = [runtime.node.deletingLastPathComponent().path, ToolPaths.bundledMediaDirectory?.path].compactMap { $0 }
        environment["PATH"] = (bundledPaths + ToolPaths.installDirectories
            + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        if tools, prepareRemotion {
            try await RemotionRuntime.prepare(in: directory, node: runtime.node, environment: environment)
        }
        let instructions = tools ? system + "\n\n" + RemotionRuntime.instructions : system
        let request = Request(baseURL: connection.endpoint.baseURL.absoluteString, model: connection.model,
                              key: connection.key, system: instructions, prompt: prompt, tools: tools, images: images,
                              attachments: attachments, budgetMinutes: budgetMinutes, budgetToolCalls: budgetToolCalls,
                              webSearch: webSearch, workspaceTools: workspaceTools, searchKey: searchKey,
                              retry: RetryPolicy(), wrapUpRatio: 0.7)
        do {
            let log = try await Shell.run(runtime.node.path, arguments: [runtime.runner.path],
                                          workingDirectory: directory, timeout: timeout,
                                          standardInput: JSONEncoder().encode(request), environment: environment,
                                          onLine: { line in
                                              guard let progress = Progress(line: line) else { return }
                                              onProgress?(progress)
                                          })
            return Progress.stripping(from: log)
        } catch let error as ShellError {
            // Keep progress records out of user-facing errors and retry classification.
            throw ShellError.exitStatus(error.exitCode, Progress.stripping(from: error.output))
        }
    }
}
