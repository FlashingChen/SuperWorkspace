import Foundation

/// Shell helpers for long-running external tools (agent CLI, whisper, ffmpeg).
enum Shell {
    /// Runs a command, streaming stdout/stderr lines to `onLine`. Returns full combined log.
    @discardableResult
    static func run(
        _ launchPath: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval? = nil,
        standardInput: Data? = nil,
        environment: [String: String]? = nil,
        onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        let process = Process()
        let executable = URL(fileURLWithPath: launchPath)
        process.executableURL = executable
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        // Finder launches can omit Homebrew and the selected tool's bin directory.
        // An absolute executable path still needs PATH for shebangs and child tools.
        var environment = environment ?? ProcessInfo.processInfo.environment
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let fallback = [executable.deletingLastPathComponent().path] + ToolPaths.installDirectories
        for directory in fallback where !directories.contains(directory) {
            directories.append(directory)
        }
        environment["PATH"] = directories.joined(separator: ":")
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let input = standardInput.map { _ in Pipe() }
        process.standardInput = input

        let collector = LineCollector(onLine: onLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            collector.feed(data)
        }

        try process.run()
        let startedAt = Date()
        do {
            if let input, let standardInput {
                defer { try? input.fileHandleForWriting.close() }
                try input.fileHandleForWriting.write(contentsOf: standardInput)
            }
            while process.isRunning {
                try Task.checkCancellation()
                if let timeout, Date().timeIntervalSince(startedAt) >= timeout {
                    throw ShellError.exitStatus(-1, "任务超时，请重试。")
                }
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch {
            if process.isRunning { process.terminate() }
            pipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        if !rest.isEmpty { collector.feed(rest) }
        collector.finish()

        let log = collector.log
        if process.terminationStatus != 0 {
            throw ShellError.exitStatus(process.terminationStatus, String(log.suffix(2000)))
        }
        return log
    }

    static func check(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

/// Splits streamed bytes into lines on a private serial queue.
private final class LineCollector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "shell.lines")
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void
    private(set) var log = ""

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        queue.async {
            self.buffer.append(data)
            while let idx = self.buffer.firstIndex(of: 0x0A) {
                let lineData = self.buffer[self.buffer.startIndex..<idx]
                self.buffer.removeSubrange(self.buffer.startIndex...idx)
                let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
                self.log += line + "\n"
                self.onLine(line)
            }
        }
    }

    func finish() {
        queue.sync {
            if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                log += line
                onLine(line)
            }
            buffer.removeAll()
        }
    }
}

enum ShellError: LocalizedError {
    case exitStatus(Int32, String)

    var errorDescription: String? {
        switch self {
        case let .exitStatus(code, log):
            return "命令退出码 \(code)\n\(log)"
        }
    }
}

enum ToolPaths {
    static let installDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    static var bundledMediaDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("MediaRuntime/bin")
    }

    static func locate(_ name: String) -> String? {
        let candidates = installDirectories.map { "\($0)/\(name)" }
        return candidates.first { Shell.check($0) }
    }

    private static func locateMediaTool(_ name: String) -> String? {
        if let path = bundledMediaDirectory?.appendingPathComponent(name).path, Shell.check(path) {
            return path
        }
        return locate(name)
    }

    static var ffmpeg: String? { locateMediaTool("ffmpeg") }
    static var whisperCLI: String? { locateMediaTool("whisper-cli") }
}
