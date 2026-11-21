import CryptoKit
import Foundation

enum RemotionRuntime {
    static let instructions = """
    工作目录已预置 `src/sw-kit/`（含 WorldCamera、StageFrame、MediaCard、PhoneMockup、defaultTheme、ease/pop）与宿主工具 `sw-motion.mjs`。
    直接从 `./sw-kit` 导入基础组件（`WorldCamera` 自动读取画布宽高，直接传 `keys` 即可），不要重复从零编写相机、缓动或工程配置；优先组织为 2–4 个连续长分幕（每幕 7–15 秒，大世界画布 + 明显幅度运镜），不要切碎成 3–4 秒小卡片。
    把所有全屏分幕（shots）与局部透明叠层（overlays）登记到 `motion-manifest.json`（含 id、composition、start、end、files 及 overlay 的 x/y/width/height）。
    预检统一运行 `node sw-motion.mjs inspect`（直接输出 JPEG Contact Sheet，不要手写 sheet.sh）；最终交付统一运行 `node sw-motion.mjs render`（按分镜 files 哈希命中 `.sw-cache/`、并发渲染、ProRes 4444 透明叠层与硬件编码合成，返回 `ok: true` 后直接交付，不要再二次抽帧重渲）。
    """

    static func prepare(in workDirectory: URL, node: URL, environment: [String: String]) async throws {
        let files = FileManager.default
        guard let seed = seedDirectory(),
              let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw ShellError.exitStatus(-1, "内置 Remotion 配置缺失，请重新安装应用。")
        }

        let modules = workDirectory.appendingPathComponent("node_modules")
        if !files.fileExists(atPath: modules.path) {
            let lock = seed.appendingPathComponent("package-lock.json")
            let manifest = seed.appendingPathComponent("package.json")
            let projectManifest = workDirectory.appendingPathComponent(manifest.lastPathComponent)
            var shouldLink = true
            if files.fileExists(atPath: projectManifest.path),
               try Data(contentsOf: projectManifest) != Data(contentsOf: manifest) {
                shouldLink = false
            }
            if shouldLink {
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

        try installScaffold(from: seed, into: workDirectory)
    }

    /// Seeds the shared kit (`src/sw-kit/`), host adapter (`sw-motion.mjs`), and default config
    /// files into a material workspace without overwriting existing authored code in `src/`.
    static func installScaffold(from seed: URL, into workDirectory: URL) throws {
        let files = FileManager.default
        let srcDir = workDirectory.appendingPathComponent("src")
        try files.createDirectory(at: srcDir, withIntermediateDirectories: true)

        // Sync sw-motion.mjs (host-managed adapter; always refresh to current version).
        let adapterSeed = seed.appendingPathComponent("sw-motion.mjs")
        if files.fileExists(atPath: adapterSeed.path) {
            let dest = workDirectory.appendingPathComponent("sw-motion.mjs")
            try? files.removeItem(at: dest)
            try files.copyItem(at: adapterSeed, to: dest)
        }

        // Sync src/sw-kit/ (host-managed shared primitives; refresh while keeping user src/ intact).
        let kitSeed = seed.appendingPathComponent("kit")
        if files.fileExists(atPath: kitSeed.path) {
            let kitDest = srcDir.appendingPathComponent("sw-kit")
            try? files.removeItem(at: kitDest)
            try files.copyItem(at: kitSeed, to: kitDest)
        }

        // Seed boilerplate config files only if absent so custom workspace configs are preserved.
        let scaffoldSeed = seed.appendingPathComponent("scaffold")
        let seeds: [(String, URL)] = [
            ("tsconfig.json", workDirectory.appendingPathComponent("tsconfig.json")),
            ("remotion.config.ts", workDirectory.appendingPathComponent("remotion.config.ts")),
            ("index.ts", srcDir.appendingPathComponent("index.ts")),
        ]
        for (name, dest) in seeds {
            let source = scaffoldSeed.appendingPathComponent(name)
            guard files.fileExists(atPath: source.path), !files.fileExists(atPath: dest.path) else { continue }
            try files.copyItem(at: source, to: dest)
        }
    }

    static func seedDirectory() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("RemotionRuntime"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return nil
    }
}
