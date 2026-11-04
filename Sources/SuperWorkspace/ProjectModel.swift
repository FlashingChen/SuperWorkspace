import Foundation

enum WorkStage: String, CaseIterable { case record = "录制", assemble = "拼装" }
enum JobState: String, Codable { case idle, queued, running, complete, failed }

struct Material: Identifiable, Codable, Equatable {
    var id = UUID()
    var createdAt = Date()
    var duration: Double = 0
    var wantsMotion = false
    var exportState: JobState = .running
    var motionState: JobState = .idle
    var transcriptState: JobState = .idle
    var exportError: String?
    var motionError: String?
    var transcriptError: String?
    var subtitles: [TranscriptSegment] = []
    var sourceName = "source.mp4"

    var isReady: Bool {
        duration.isFinite && duration > 0 && exportState == .complete && (!wantsMotion || motionState == .complete)
    }
    var motionLabel: String? {
        guard wantsMotion else { return nil }
        switch motionState {
        case .idle, .queued: return "动效排队中"
        case .running: return "添加动效中"
        case .complete: return "动效已完成"
        case .failed: return "动效失败"
        }
    }
}

struct VideoProject: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var updatedAt = Date()
    var materials: [Material] = []

    enum CodingKeys: String, CodingKey { case id, name, createdAt, updatedAt, materials }
    init(name: String) { self.name = name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        materials = try c.decodeIfPresent([Material].self, forKey: .materials) ?? []
    }
    var canExport: Bool {
        !materials.isEmpty && materials.allSatisfy { $0.isReady && $0.transcriptState == .complete }
    }
    var assembledSubtitles: [TranscriptSegment] {
        var offset = 0.0
        return materials.flatMap { material -> [TranscriptSegment] in
            defer { offset += material.duration }
            return material.subtitles.map { TranscriptSegment(start: $0.start + offset, end: $0.end + offset, text: $0.text) }
        }
    }
}

enum ProjectLayout {
    static var projectsRoot: URL {
        if let override = ProcessInfo.processInfo.environment["SUPERWORKSPACE_TEST_ROOT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SuperWorkspace", isDirectory: true)
    }
    static func directory(for project: VideoProject) -> URL {
        projectsRoot.appendingPathComponent(project.id.uuidString, isDirectory: true)
    }
    static func url(_ name: String, for project: VideoProject) -> URL { directory(for: project).appendingPathComponent(name) }
    static func materialDirectory(_ material: Material, in project: VideoProject) -> URL {
        directory(for: project).appendingPathComponent("materials/\(material.id.uuidString)", isDirectory: true)
    }
    static func source(_ material: Material, in project: VideoProject) -> URL {
        materialDirectory(material, in: project).appendingPathComponent(material.sourceName).standardizedFileURL
    }
    static func motion(_ material: Material, in project: VideoProject) -> URL {
        materialDirectory(material, in: project).appendingPathComponent("motion.mp4")
    }
    static func picture(_ material: Material, in project: VideoProject) -> URL {
        material.wantsMotion && material.motionState == .complete ? motion(material, in: project) : source(material, in: project)
    }
    static func save(_ project: VideoProject) throws {
        try FileManager.default.createDirectory(at: directory(for: project), withIntermediateDirectories: true)
        try JSONEncoder().encode(project).write(to: url("project.json", for: project), options: .atomic)
    }
    static func loadAll() -> [VideoProject] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil) else { return [] }
        return items.compactMap { dir -> VideoProject? in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("project.json")),
                  var project = try? JSONDecoder().decode(VideoProject.self, from: data) else { return nil }
            // Preserve a legacy single-source project without moving its files.
            if project.materials.isEmpty, fm.fileExists(atPath: url("source1.mp4", for: project).path) {
                var material = Material()
                material.sourceName = fm.fileExists(atPath: url("source2.mp4", for: project).path) ? "../../source2.mp4" : "../../source1.mp4"
                material.exportState = .complete
                if let transcript = try? Data(contentsOf: url("transcript.json", for: project)),
                   let subtitles = try? JSONDecoder().decode([TranscriptSegment].self, from: transcript) {
                    material.subtitles = subtitles
                    material.transcriptState = .complete
                }
                project.materials = [material]
            }
            return project
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
}
