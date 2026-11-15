import Foundation

/// Freezing a finished project removes the runtime files its material workspaces can
/// rebuild on demand. Pictures, motion results, transcripts, library copies and
/// exported films stay on disk; only the Remotion dependency layer and its renders go.
enum ProjectFreeze {
    /// Entries inside a material workspace that `RemotionRuntime.prepare` restores.
    static let runtimeEntries = ["node_modules", "package.json", "package-lock.json",
                                 ".remotion", "out", "motion-pending.mp4"]

    /// One directory per recording, even when several timeline clips share it.
    static func workspaces(for project: VideoProject) -> [URL] {
        var seen = Set<String>()
        return project.materials.compactMap { material in
            let directory = ProjectLayout.materialDirectory(material, in: project).standardizedFileURL
            return seen.insert(directory.path).inserted ? directory : nil
        }
    }

    @discardableResult
    static func freeze(_ project: VideoProject) throws -> Int64 {
        let files = FileManager.default
        var reclaimed: Int64 = 0
        for workspace in workspaces(for: project) {
            for entry in runtimeEntries {
                let url = workspace.appendingPathComponent(entry)
                let isLink = (try? files.destinationOfSymbolicLink(atPath: url.path)) != nil
                guard isLink || files.fileExists(atPath: url.path) else { continue }
                reclaimed += size(of: url)
                try files.removeItem(at: url)
            }
        }
        return reclaimed
    }

    /// Material workspaces that held a Remotion edit keep their `src/` and `motion.mp4`,
    /// so they are the ones that need the dependency layer back.
    static func workspacesNeedingRebuild(_ project: VideoProject) -> [URL] {
        let files = FileManager.default
        return workspaces(for: project).filter { workspace in
            files.fileExists(atPath: workspace.appendingPathComponent("src").path)
                || files.fileExists(atPath: workspace.appendingPathComponent("motion.mp4").path)
        }
    }

    static func rebuild(_ project: VideoProject) async throws {
        let workspaces = workspacesNeedingRebuild(project)
        guard !workspaces.isEmpty else { return }
        guard let node = EmbeddedPi.bundledNode else {
            throw ShellError.exitStatus(-1, "内置 Remotion 组件缺失，请重新安装应用。")
        }
        let environment = EmbeddedPi.runtimeEnvironment(node: node)
        for workspace in workspaces {
            try Task.checkCancellation()
            try await RemotionRuntime.prepare(in: workspace, node: node, environment: environment)
        }
    }

    /// A symbolic link counts as zero: its target lives in the shared cache.
    private static func size(of url: URL) -> Int64 {
        let files = FileManager.default
        if (try? files.destinationOfSymbolicLink(atPath: url.path)) != nil { return 0 }
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var total: Int64 = 0
        if let enumerator = files.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let child as URL in enumerator {
                guard (try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }
}
