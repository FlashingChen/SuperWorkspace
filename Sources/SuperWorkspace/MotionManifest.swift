import Foundation

/// Declarative manifest written by the Remotion motion agent and consumed by both
/// the host adapter (`sw-motion.mjs`) and the assembly agent for shot-level refinement.
struct MotionManifest: Codable, Sendable, Equatable {
    struct Shot: Codable, Sendable, Equatable {
        let id: String
        let composition: String
        let start: Double
        let end: Double
        let files: [String]?
    }

    struct Overlay: Codable, Sendable, Equatable {
        let id: String
        let composition: String
        let start: Double
        let end: Double
        let x: Double?
        let y: Double?
        let width: Double?
        let height: Double?
        let files: [String]?
    }

    enum TargetKind: String, Sendable, Equatable {
        case shot
        case overlay
    }

    struct Target: Sendable, Equatable {
        let kind: TargetKind
        let id: String
        let composition: String
        let start: Double
        let end: Double
        let files: [String]
    }

    static let filename = "motion-manifest.json"

    let version: Int?
    let fps: Int?
    let width: Int?
    let height: Int?
    let shots: [Shot]
    let overlays: [Overlay]

    init(
        version: Int? = 1,
        fps: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        shots: [Shot] = [],
        overlays: [Overlay] = []
    ) {
        self.version = version
        self.fps = fps
        self.width = width
        self.height = height
        self.shots = shots
        self.overlays = overlays
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        fps = try c.decodeIfPresent(Int.self, forKey: .fps)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        shots = try c.decodeIfPresent([Shot].self, forKey: .shots) ?? []
        overlays = try c.decodeIfPresent([Overlay].self, forKey: .overlays) ?? []
    }

    static func load(in directory: URL) -> MotionManifest? {
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(MotionManifest.self, from: data)
    }

    var allTargets: [Target] {
        let shotTargets = shots.map {
            Target(kind: .shot, id: $0.id, composition: $0.composition, start: $0.start, end: $0.end, files: $0.files ?? [])
        }
        let overlayTargets = overlays.map {
            Target(kind: .overlay, id: $0.id, composition: $0.composition, start: $0.start, end: $0.end, files: $0.files ?? [])
        }
        return (shotTargets + overlayTargets).sorted { $0.start < $1.start }
    }

    func target(id rawID: String) -> Target? {
        let query = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return nil }
        return allTargets.first {
            $0.id.lowercased() == query || $0.composition.lowercased() == query
        }
    }

    /// Finds targets covering `seconds`. If none strictly contains `seconds`, falls back to the
    /// nearest target within `tolerance` seconds.
    func targets(at seconds: Double, tolerance: Double = 0.5) -> [Target] {
        guard seconds.isFinite else { return [] }
        let direct = allTargets.filter { seconds >= $0.start - 0.02 && seconds <= $0.end + 0.02 }
        if !direct.isEmpty { return direct }
        let nearest = allTargets.min { a, b in
            let da = min(abs(seconds - a.start), abs(seconds - a.end))
            let db = min(abs(seconds - b.start), abs(seconds - b.end))
            return da < db
        }
        guard let nearest else { return [] }
        let dist = min(abs(seconds - nearest.start), abs(seconds - nearest.end))
        return dist <= tolerance ? [nearest] : []
    }

    func summaryJSON() -> JSONValue {
        .object([
            ("shots", .array(shots.map { s in
                .object([
                    ("id", .string(s.id)),
                    ("composition", .string(s.composition)),
                    ("start", .number(s.start)),
                    ("end", .number(s.end)),
                ])
            })),
            ("overlays", .array(overlays.map { o in
                .object([
                    ("id", .string(o.id)),
                    ("composition", .string(o.composition)),
                    ("start", .number(o.start)),
                    ("end", .number(o.end)),
                ])
            })),
        ])
    }

    static func refinementBrief(target: Target, instruction: String) -> String {
        let kindLabel = target.kind == .shot ? "全屏分镜" : "局部透明叠层"
        let range = String(format: "%.2fs–%.2fs", target.start, target.end)
        let filesNote = target.files.isEmpty
            ? "仅修改 \(target.composition) 对应的源码文件"
            : "仅修改 \(target.files.joined(separator: "、"))"
        return """
        【定向分镜微调】只调整\(kindLabel)「\(target.id)」（composition: \(target.composition)，区间 \(range)），不要改动其它分镜。
        修改要求：\(instruction)
        执行步骤：
        1. \(filesNote)，保持 motion-manifest.json 中其它分镜不变。
        2. 运行 `node sw-motion.mjs inspect --shots \(target.id)` 检查修改后的画面与安全区。
        3. 运行 `node sw-motion.mjs render`：宿主会自动复用 .sw-cache/ 中未改动分镜的缓存，只重渲「\(target.id)」并无损重拼输出。
        """
    }
}
