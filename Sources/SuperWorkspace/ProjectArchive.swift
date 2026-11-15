import Foundation

/// One project becomes one ZIP with the source cut, the motion cut and the finished
/// film. The cuts are composed with the same AVFoundation implementation as export,
/// so they follow the project's order, canvas and clip ranges.
@MainActor
enum ProjectArchive {
    static let sourceFileName = "source.mp4"
    static let motionFileName = "motion.mp4"
    static let filmFileName = "film.mp4"

    struct Layout: Equatable {
        let sources: [Material]
        let motions: [Material]
    }

    static func layout(of project: VideoProject) -> Layout {
        Layout(sources: project.materials.filter(\.sourceReady),
               motions: project.materials.filter { $0.sourceReady && $0.wantsMotion && $0.motionState == .complete })
    }

    /// The finished film of the last export, when it is still in the project folder.
    static func film(for project: VideoProject) -> URL? {
        guard let name = project.lastExportName, name == URL(fileURLWithPath: name).lastPathComponent else { return nil }
        let url = ProjectLayout.url(name, for: project)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func folderName(for project: VideoProject) -> String {
        let trimmed = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "未命名项目" : trimmed
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }

    static func export(project: VideoProject, to destination: URL, progress: ExportProgress? = nil) async throws -> URL {
        let files = FileManager.default
        let layout = layout(of: project)
        guard !layout.sources.isEmpty else { throw failure("项目还没有可导出的素材。") }
        guard project.materials.allSatisfy(\.sourceReady) else {
            throw failure("有素材尚未完成导出，请先完成或移除失败的素材。")
        }
        guard let film = film(for: project) else { throw failure("还没有成片，请先导出成片。") }

        let staging = files.temporaryDirectory.appendingPathComponent("SuperWorkspaceBundle-\(UUID().uuidString)", isDirectory: true)
        let folder = staging.appendingPathComponent(folderName(for: project), isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }

        progress?.begin("拼接源素材")
        let source = try await cut(layout.sources, of: project, source: true, progress: progress)
        try files.moveItem(at: source, to: folder.appendingPathComponent(sourceFileName))
        try Task.checkCancellation()

        if !layout.motions.isEmpty {
            progress?.begin("拼接动效")
            let motion = try await cut(layout.motions, of: project, source: false, progress: progress)
            try files.moveItem(at: motion, to: folder.appendingPathComponent(motionFileName))
            try Task.checkCancellation()
        }

        progress?.begin("复制成片")
        try files.copyItem(at: film, to: folder.appendingPathComponent(filmFileName))
        try Task.checkCancellation()

        progress?.begin("压缩项目")
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        do {
            try await Shell.run("/usr/bin/ditto", arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent",
                                                             folder.path, destination.path], timeout: 3600)
        } catch {
            try? files.removeItem(at: destination)
            throw error
        }
        try Task.checkCancellation()
        progress?.phase = "项目已导出"
        return destination
    }

    /// Reuses the export pipeline on a copy whose ranges are the whole recording and
    /// whose picture is either the original source or the motion result.
    private static func cut(_ materials: [Material], of project: VideoProject,
                            source: Bool, progress: ExportProgress?) async throws -> URL {
        var copy = project
        copy.materials = materials.map { material in
            var item = material
            item.trimStart = nil
            item.trimEnd = nil
            item.inserts = nil
            item.useOriginal = source
            if !source {
                item.wantsMotion = true
                item.motionState = .complete
            }
            return item
        }
        copy.includeSubtitles = false
        copy.exportSRT = false
        copy.exportWithAIEditing = false
        return try await ExportService.export(project: copy, progress: progress)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ProjectArchive", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
