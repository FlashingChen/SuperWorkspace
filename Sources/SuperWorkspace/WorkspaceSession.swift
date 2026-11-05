import Foundation

struct EditorSession: Codable {
    var stage: WorkStage = .record
    var playhead = 0.0
    var zoom = 1.0
    var previewHeight = 0.66
    var selectedMaterial: UUID?
    var selectedSubtitle: String?
}

struct WorkspaceSession: Codable {
    var selectedProject: UUID?
    var editors: [UUID: EditorSession] = [:]

    static var url: URL { ProjectLayout.projectsRoot.appendingPathComponent("workspace-state.json") }
    static func load() -> WorkspaceSession {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return value
    }
    func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
}
