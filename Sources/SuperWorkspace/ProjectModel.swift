import Foundation

enum WorkStage: String, Codable { case record = "录制", assemble = "拼装", library = "素材库" }
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
    var editingPrompt: String?
    /// Cutaways chosen while this recording was exported; source time of this material.
    var inserts: [AIEditing.Insert]?
    /// The recorder's "AI 剪辑" choice, kept so the choice survives restarts.
    var wantsAIEditing: Bool?
    var aiEditWarning: String?
    var transcriptError: String?
    var transcriptWarning: String?
    var subtitleLayoutVersion: Int?
    var subtitles: [TranscriptSegment] = []
    var sourceName = "source.mp4"
    var storageID: UUID?
    var mediaID: UUID { storageID ?? id }
    var useOriginal: Bool?
    var trimStart: Double?
    var trimEnd: Double?

    var sourceReady: Bool { duration.isFinite && duration > 0 && exportState == .complete }
    var inPoint: Double { min(max(0, trimStart ?? 0), max(0, duration)) }
    var outPoint: Double { min(duration, max(inPoint, trimEnd ?? duration)) }
    var timelineDuration: Double { sourceReady ? max(0, outPoint - inPoint) : 0 }
    var visibleSubtitles: [TranscriptSegment] {
        subtitles.compactMap {
            let start = max(inPoint, $0.start), end = min(outPoint, $0.end)
            return end > start ? TranscriptSegment(start: start - inPoint, end: end - inPoint, text: $0.text) : nil
        }
    }

    var isReady: Bool {
        sourceReady && timelineDuration > 0
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

struct ReferenceMedia: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case image, video }
    var id = UUID()
    let name: String
    let kind: Kind
    var description = ""
    var duration: Double?
}

struct VideoProject: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var updatedAt = Date()
    var materials: [Material] = []
    var includeSubtitles = true
    var referenceMedia: [ReferenceMedia] = []
    var exportWithAIEditing: Bool?
    var exportSRT: Bool?
    var lastExportSRTName: String?
    var canvasWidth: Double?
    var canvasHeight: Double?
    var lastExportName: String?

    enum CodingKeys: String, CodingKey { case id, name, createdAt, updatedAt, materials, includeSubtitles, canvasWidth, canvasHeight, lastExportName, exportSRT, lastExportSRTName, referenceMedia, exportWithAIEditing }
    init(name: String) { self.name = name }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        materials = try c.decodeIfPresent([Material].self, forKey: .materials) ?? []
        referenceMedia = try c.decodeIfPresent([ReferenceMedia].self, forKey: .referenceMedia) ?? []
        exportWithAIEditing = try c.decodeIfPresent(Bool.self, forKey: .exportWithAIEditing)
        includeSubtitles = try c.decodeIfPresent(Bool.self, forKey: .includeSubtitles) ?? true
        canvasWidth = try c.decodeIfPresent(Double.self, forKey: .canvasWidth)
        canvasHeight = try c.decodeIfPresent(Double.self, forKey: .canvasHeight)
        exportSRT = try c.decodeIfPresent(Bool.self, forKey: .exportSRT)
        lastExportSRTName = try c.decodeIfPresent(String.self, forKey: .lastExportSRTName)
        lastExportName = try c.decodeIfPresent(String.self, forKey: .lastExportName)
    }
    var canExport: Bool {
        !materials.isEmpty && materials.allSatisfy { $0.isReady && (!(includeSubtitles || exportSRT == true) || $0.transcriptState == .complete) }
    }
    var assembledSubtitles: [TranscriptSegment] {
        var offset = 0.0
        return materials.flatMap { material -> [TranscriptSegment] in
            defer { offset += material.timelineDuration }
            return material.visibleSubtitles.map { TranscriptSegment(start: $0.start + offset, end: $0.end + offset, text: $0.text) }
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
    /// Derived review output lives beside the project data so reopening a project keeps it.
    static func subtitleReview(for project: VideoProject) -> URL { url("subtitle-review.json", for: project) }
    static func reference(_ media: ReferenceMedia, in project: VideoProject) -> URL {
        let file = url("library", for: project).appendingPathComponent(media.id.uuidString)
        let ext = URL(fileURLWithPath: media.name).pathExtension
        return ext.isEmpty ? file : file.appendingPathExtension(ext)
    }
    static func materialDirectory(_ material: Material, in project: VideoProject) -> URL {
        directory(for: project).appendingPathComponent("materials/\(material.mediaID.uuidString)", isDirectory: true)
    }
    static func source(_ material: Material, in project: VideoProject) -> URL {
        materialDirectory(material, in: project).appendingPathComponent(material.sourceName).standardizedFileURL
    }
    static func motion(_ material: Material, in project: VideoProject) -> URL {
        materialDirectory(material, in: project).appendingPathComponent("motion.mp4")
    }
    static func picture(_ material: Material, in project: VideoProject) -> URL {
        material.wantsMotion && material.useOriginal != true && material.motionState == .complete ? motion(material, in: project) : source(material, in: project)
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
