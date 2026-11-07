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

    private struct Request: Encodable {
        let baseURL: String
        let model: String
        let key: String
        let system: String
        let prompt: String
        let tools: Bool
        let images: Bool
    }

    static func run(_ connection: AIConnection, system: String, prompt: String, directory: URL,
                    tools: Bool, images: Bool = false, timeout: TimeInterval) async throws -> String {
        guard let runtime else {
            throw ShellError.exitStatus(-1, "内置 Pi 组件缺失，请重新安装应用。")
        }
        let request = Request(baseURL: connection.endpoint.baseURL.absoluteString, model: connection.model,
                              key: connection.key, system: system, prompt: prompt, tools: tools, images: images)
        let permittedVariables: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"]
        var environment = ProcessInfo.processInfo.environment.filter { permittedVariables.contains($0.key) }
        environment["PATH"] = ([runtime.node.deletingLastPathComponent().path] + ToolPaths.installDirectories
            + ["/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        return try await Shell.run(runtime.node.path, arguments: [runtime.runner.path],
                                   workingDirectory: directory, timeout: timeout,
                                   standardInput: JSONEncoder().encode(request), environment: environment)
    }
}
