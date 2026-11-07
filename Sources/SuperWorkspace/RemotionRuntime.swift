import CryptoKit
import Foundation

enum RemotionRuntime {
    static let instructions = """
    在当前素材工作目录运行 npx --no-install remotion，复用已准备的清单、依赖和浏览器。已有工程继续沿用其依赖。
    调用应用自带的 FFmpeg 编码 H.264 时，使用 h264_videotoolbox，必要时加 -allow_sw 1。可复制原音轨时直接复制。
    """

    static func prepare(in workDirectory: URL, node: URL, environment: [String: String]) async throws {
        let files = FileManager.default
        let modules = workDirectory.appendingPathComponent("node_modules")
        guard !files.fileExists(atPath: modules.path) else { return }
        guard let seed = Bundle.main.resourceURL?.appendingPathComponent("RemotionRuntime"),
              let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ShellError.exitStatus(-1, "内置 Remotion 配置缺失，请重新安装应用。")
        }

        let lock = seed.appendingPathComponent("package-lock.json")
        let manifest = seed.appendingPathComponent("package.json")
        let projectManifest = workDirectory.appendingPathComponent(manifest.lastPathComponent)
        if files.fileExists(atPath: projectManifest.path),
           try Data(contentsOf: projectManifest) != Data(contentsOf: manifest) { return }
        let digest = SHA256.hash(data: try Data(contentsOf: lock)).map { String(format: "%02x", $0) }.joined()
        let cacheRoot = support.appendingPathComponent("SuperWorkspace/Remotion")
        let cache = cacheRoot.appendingPathComponent(digest)
        let cachedModules = cache.appendingPathComponent("node_modules")
        if !files.fileExists(atPath: cachedModules.path) {
            try files.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            let stage = cacheRoot.appendingPathComponent(UUID().uuidString)
            try files.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? files.removeItem(at: stage) }
            try files.copyItem(at: lock, to: stage.appendingPathComponent(lock.lastPathComponent))
            try files.copyItem(at: manifest, to: stage.appendingPathComponent(manifest.lastPathComponent))
            let npm = node.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("lib/node_modules/npm/bin/npm-cli.js")
            try await Shell.run(node.path, arguments: [npm.path, "ci", "--ignore-scripts", "--no-audit", "--no-fund"],
                                workingDirectory: stage, timeout: 600, environment: environment)
            try await Shell.run(node.path, arguments: [npm.path, "exec", "--", "remotion", "browser", "ensure"],
                                workingDirectory: stage, timeout: 600, environment: environment)
            try Task.checkCancellation()
            do { try files.moveItem(at: stage, to: cache) }
            catch {
                // Another process may have prepared the same version while this one downloaded.
                guard files.fileExists(atPath: cachedModules.path) else { throw error }
            }
        }

        try Task.checkCancellation()
        if !files.fileExists(atPath: projectManifest.path) {
            do { try files.copyItem(at: manifest, to: projectManifest) }
            catch { guard files.fileExists(atPath: projectManifest.path) else { throw error } }
        }
        if !files.fileExists(atPath: modules.path),
           let previous = try? files.destinationOfSymbolicLink(atPath: modules.path),
           previous.hasPrefix(cacheRoot.path + "/") {
            try files.removeItem(at: modules)
        }
        do { try files.createSymbolicLink(at: modules, withDestinationURL: cachedModules) }
        catch { guard files.fileExists(atPath: modules.path) else { throw error } }
    }
}
