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
        onLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collector = LineCollector(onLine: onLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            collector.feed(data)
        }

        try process.run()
        let startedAt = Date()
        do {
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
    static func locate(_ name: String) -> String? {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return candidates.first { Shell.check($0) }
    }

    static var ffmpeg: String? { locate("ffmpeg") }
    static var whisperCLI: String? { locate("whisper-cli") }
}
