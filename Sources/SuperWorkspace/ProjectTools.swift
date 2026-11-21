import Foundation

/// Operations the in-app agent can perform on the live project. Every write goes
/// through `AppState`, so it is validated, persisted, and undoable like a direct
/// edit. The agent reads the project through `project_read` rather than touching
/// `project.json` (the app owns that file).
@MainActor
enum ProjectTools {
    static func execute(_ call: ProjectToolCall, projectID: UUID, state: AppState) -> ProjectToolOutcome {
        guard let project = state.projects.first(where: { $0.id == projectID }) else {
            return .failure("项目不存在或已被删除。")
        }
        let readOnly = call.tool == "project_read" || call.tool == "job_status"
        guard readOnly || state.exportingProjects.contains(projectID) == false else {
            return .failure("项目正在导出成片，等导出结束再修改。")
        }
        switch call.tool {
        case "project_read":
            return .success(snapshot(project, state: state))
        case "clip_trim":
            return trim(call.args, project: project, state: state)
        case "clip_split":
            return split(call.args, project: project, state: state)
        case "clip_move":
            return move(call.args, project: project, state: state)
        case "clip_remove":
            return remove(call.args, project: project, state: state)
        case "clip_speed":
            return setSpeed(call.args, project: project, state: state)
        case "clip_rename":
            return rename(call.args, project: project, state: state)
        case "subtitle_update":
            return updateSubtitle(call.args, project: project, state: state)
        case "subtitle_insert":
            return insertSubtitle(call.args, project: project, state: state)
        case "subtitle_delete":
            return deleteSubtitle(call.args, project: project, state: state)
        case "subtitle_merge":
            return mergeSubtitle(call.args, project: project, state: state)
        case "subtitle_split":
            return splitSubtitle(call.args, project: project, state: state)
        case "subtitle_move":
            return moveSubtitle(call.args, project: project, state: state)
        case "canvas_set":
            return setCanvas(call.args, project: project, state: state)
        case "insert_add":
            return addInsert(call.args, project: project, state: state)
        case "insert_update":
            return updateInsert(call.args, project: project, state: state)
        case "insert_remove":
            return removeInsert(call.args, project: project, state: state)
        case "motion_regenerate":
            return regenerateMotion(call.args, project: project, state: state)
        case "job_status":
            return jobStatus(call.args, project: project, state: state)
        default:
            return .failure("没有名为 \(call.tool) 的操作。可用的操作见系统说明。")
        }
    }

    // MARK: - Read

    static func snapshot(_ project: VideoProject, state: AppState) -> JSONValue {
        var offset = 0.0
        let clips = project.materials.enumerated().map { index, material -> JSONValue in
            let timelineStart = offset
            offset += material.timelineDuration
            let rate = material.playbackSpeed
            let subtitles = material.subtitles.enumerated().map { subtitleIndex, subtitle -> JSONValue in
                let localStart = (max(material.inPoint, subtitle.start) - material.inPoint) / rate
                let localEnd = (min(material.outPoint, subtitle.end) - material.inPoint) / rate
                return .object([
                    ("index", .number(Double(subtitleIndex + 1))),
                    ("start", .number(rounded(subtitle.start))),
                    ("end", .number(rounded(subtitle.end))),
                    ("timelineStart", .number(rounded(timelineStart + localStart))),
                    ("timelineEnd", .number(rounded(timelineStart + localEnd))),
                    ("text", .string(subtitle.text)),
                ])
            }
            let inserts = (material.inserts ?? []).enumerated().map { insertIndex, insert -> JSONValue in
                .object([
                    ("index", .number(Double(insertIndex + 1))),
                    ("assetID", .string(insert.assetID.uuidString)),
                    ("start", .number(rounded(insert.start))),
                    ("end", .number(rounded(insert.end))),
                    ("assetStart", .number(rounded(insert.assetStart ?? 0))),
                ])
            }
            let motion = state.motionPhases[material.mediaID]
            return .object([
                ("index", .number(Double(index + 1))),
                ("id", .string(material.id.uuidString)),
                ("title", .string(material.displayTitle(index: index))),
                ("label", .string("素材\(chineseNumeral(index + 1))")),
                ("sourceDuration", .number(rounded(material.duration))),
                ("in", .number(rounded(material.inPoint))),
                ("out", .number(rounded(material.outPoint))),
                ("speed", .number(rounded(rate))),
                ("timelineStart", .number(rounded(timelineStart))),
                ("timelineDuration", .number(rounded(material.timelineDuration))),
                ("readiness", .string(material.sourceReady ? "ready" : "processing")),
                ("motionState", .string(material.motionState.rawValue)),
                ("motionPhase", .string(motion ?? "")),
                ("motionError", .string(material.motionError ?? "")),
                ("showsOriginal", .bool(material.useOriginal ?? false)),
                ("editingPrompt", .string(material.editingPrompt ?? "")),
                ("subtitles", .array(subtitles)),
                ("inserts", .array(inserts)),
            ])
        }
        let library = project.referenceMedia.enumerated().map { index, media -> JSONValue in
            .object([
                ("index", .number(Double(index + 1))),
                ("id", .string(media.id.uuidString)),
                ("name", .string(media.name)),
                ("kind", .string(media.kind.rawValue)),
                ("description", .string(media.description)),
                ("duration", media.duration.map { .number(rounded($0)) } ?? .null),
            ])
        }
        return .object([
            ("project", .object([
                ("id", .string(project.id.uuidString)),
                ("name", .string(project.name)),
                ("frozen", .bool(project.isFrozen)),
                ("canvasWidth", project.canvasWidth.map { .number(rounded($0)) } ?? .null),
                ("canvasHeight", project.canvasHeight.map { .number(rounded($0)) } ?? .null),
            ])),
            ("clips", .array(clips)),
            ("library", .array(library)),
            ("notes", .array([
                .string("时间单位均为秒。in/out 是片段在原视频中的时间；timelineStart 是成片时间轴上的起点。"),
                .string("clip 参数可以传片段序号（1 开始）或片段 id。subtitle 的 index 从 1 开始。"),
            ])),
        ])
    }

    // MARK: - Clips

    private static func trim(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard let material = resolveClip(args, in: project) else { return .failure("未找到片段，请传片段序号或 id。") }
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        let start = args["start"]?.numberValue ?? material.inPoint
        let end = args["end"]?.numberValue ?? material.outPoint
        guard state.setTrim(project.id, material.id, start: start, end: end) else {
            return .failure("裁剪范围不合法：需落在 0–\(rounded(material.duration)) 秒内，且不短于一帧。")
        }
        return .success(changed("已裁剪", material: current(material.id, projectID: project.id, state: state)))
    }

    private static func split(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard let material = resolveClip(args, in: project) else { return .failure("未找到片段，请传片段序号或 id。") }
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let at = args["at"]?.numberValue else { return .failure("请在 at 里给出分割点（原视频秒数）。") }
        guard let right = state.splitMaterial(project.id, material.id, at: at) else {
            return .failure("无法在该位置分割：分割点需在 \(rounded(material.inPoint))–\(rounded(material.outPoint)) 秒之间，两侧各不短于一帧。")
        }
        return .success(.object([
            ("leftID", .string(material.id.uuidString)),
            ("rightID", .string(right.uuidString)),
        ]))
    }

    private static func move(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard let material = resolveClip(args, in: project) else { return .failure("未找到片段，请传片段序号或 id。") }
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let position = args["position"]?.intValue else { return .failure("请在 position 里给出目标位置（1 开始）。") }
        guard state.moveMaterialTo(project.id, material.id, position: position) else {
            return .failure("目标位置超出范围：当前共 \(project.materials.count) 个片段。")
        }
        return .success(changed("已移动", material: current(material.id, projectID: project.id, state: state)))
    }

    private static func remove(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard let material = resolveClip(args, in: project) else { return .failure("未找到片段，请传片段序号或 id。") }
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard state.removeMaterial(project.id, material.id) else {
            return .failure("该片段正在导出或不允许删除。")
        }
        return .success(.object([("removed", .string(material.id.uuidString))]))
    }

    // MARK: - Subtitles

    private static func updateSubtitle(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard let material = resolveClip(args, in: project) else { return .failure("未找到片段。") }
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard material.transcriptState != .running else { return .failure("这个片段正在识别字幕，等它完成再改。") }
        guard let index = subtitleIndex(args, in: material) else { return .failure("字幕序号超出范围。") }
        guard let text = args["text"]?.stringValue else { return .failure("请在 text 里给出新字幕。") }
        state.editSubtitle(projectID: project.id, materialID: material.id, index: index, text: text)
        return .success(subtitleResult(material, index: index, state: state, projectID: project.id))
    }

    private static func insertSubtitle(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard let material = resolveClip(args, in: project) else { return .failure("未找到片段。") }
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard material.transcriptState == .complete else { return .failure("字幕还没处理完成，暂时不能新增。") }
        guard let at = args["at"]?.numberValue else { return .failure("请在 at 里给出插入位置（原视频秒数）。") }
        guard let index = state.insertSubtitle(project.id, material.id, at: at) else {
            return .failure("该时间点没有可用空位，先移动或删除已有字幕。")
        }
        if let text = args["text"]?.stringValue, !text.isEmpty {
            state.editSubtitle(projectID: project.id, materialID: material.id, index: index, text: text)
        }
        return .success(subtitleResult(material, index: index, state: state, projectID: project.id))
    }

    private static func deleteSubtitle(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard let material = resolveClip(args, in: project) else { return .failure("未找到片段。") }
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let index = subtitleIndex(args, in: material) else { return .failure("字幕序号超出范围。") }
        guard state.deleteSubtitle(project.id, material.id, index: index) else { return .failure("无法删除这条字幕。") }
        return .success(.object([("deleted", .number(Double(index + 1)))]))
    }

    private static func mergeSubtitle(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard let material = resolveClip(args, in: project) else { return .failure("未找到片段。") }
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let index = subtitleIndex(args, in: material), index + 1 < material.subtitles.count else {
            return .failure("需要给出与前一条合并的下一条字幕序号。")
        }
        guard state.mergeSubtitle(project.id, material.id, index: index) else { return .failure("无法与下一条字幕合并。") }
        return .success(subtitleResult(material, index: index, state: state, projectID: project.id))
    }

    private static func splitSubtitle(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard let material = resolveClip(args, in: project) else { return .failure("未找到片段。") }
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let index = subtitleIndex(args, in: material) else { return .failure("字幕序号超出范围。") }
        guard let at = args["at"]?.numberValue else { return .failure("请在 at 里给出分割时间（原视频秒数）。") }
        guard state.splitSubtitle(project.id, material.id, index: index, at: at) else {
            return .failure("分割点需落在该条字幕中间，且两侧各不短于一帧。")
        }
        return .success(subtitleResult(material, index: index, state: state, projectID: project.id))
    }

    private static func moveSubtitle(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard let material = resolveClip(args, in: project) else { return .failure("未找到片段。") }
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let index = subtitleIndex(args, in: material) else { return .failure("字幕序号超出范围。") }
        guard let start = args["start"]?.numberValue, let end = args["end"]?.numberValue else {
            return .failure("请给出新的 start 和 end（原视频秒数）。")
        }
        guard state.setSubtitleTiming(project.id, material.id, index: index, start: start, end: end) else {
            return .failure("字幕时间不合法：需在素材范围内、不短于一帧，且不与相邻字幕重叠。")
        }
        return .success(subtitleResult(material, index: index, state: state, projectID: project.id))
    }

    // MARK: - Canvas, inserts, motion

    private static func setCanvas(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        let width = args["width"]?.numberValue
        let height = args["height"]?.numberValue
        if (width == nil) != (height == nil) { return .failure("width 与 height 需要同时给出，或同时留空表示自动。") }
        state.setCanvas(project.id, width: width, height: height)
        let updated = state.projects.first { $0.id == project.id }
        return .success(.object([
            ("canvasWidth", updated?.canvasWidth.map { .number(rounded($0)) } ?? .null),
            ("canvasHeight", updated?.canvasHeight.map { .number(rounded($0)) } ?? .null),
        ]))
    }

    private static func addInsert(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard let material = resolveClip(args, in: project) else { return .failure("未找到片段。") }
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let asset = resolveAsset(args, in: project) else { return .failure("未找到素材库素材，请传素材序号或 id。") }
        guard let start = args["start"]?.numberValue, let end = args["end"]?.numberValue else {
            return .failure("请给出补充画面的 start 和 end（原视频秒数）。")
        }
        let insert = AIEditing.Insert(clipID: material.id, assetID: asset.id, start: start, end: end,
                                      assetStart: args["assetStart"]?.numberValue ?? 0)
        let library = Dictionary(uniqueKeysWithValues: project.referenceMedia.map { ($0.id, $0) })
        let combined = (material.inserts ?? []) + [insert]
        let validated = AIEditing.validatedInserts(combined, clipID: material.id, clipStart: material.inPoint,
                                                   clipEnd: material.outPoint, library: library)
        guard validated.contains(insert) else {
            return .failure("补充画面不合法：需落在 \(rounded(material.inPoint))–\(rounded(material.outPoint)) 秒内，不短于一帧，且不与已有补充画面重叠。")
        }
        guard state.setInserts(project.id, material.id, validated) else { return .failure("保存补充画面失败。") }
        return .success(.object([
            ("clip", .string(material.id.uuidString)),
            ("inserts", .array(validated.enumerated().map { index, value in
                .object([
                    ("index", .number(Double(index + 1))),
                    ("assetID", .string(value.assetID.uuidString)),
                    ("start", .number(rounded(value.start))),
                    ("end", .number(rounded(value.end))),
                ])
            })),
        ]))
    }

    private static func setSpeed(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard let material = resolveClip(args, in: project) else { return .failure("未找到片段。") }
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let speed = args["speed"]?.numberValue, speed.isFinite, speed >= 0.5, speed <= 4.0 else {
            return .failure("倍速需在 0.5 到 4.0 之间。")
        }
        guard state.setMaterialSpeed(project.id, material.id, speed: speed) else {
            return .failure("无法调整倍速。")
        }
        let updated = current(material.id, projectID: project.id, state: state)
        return .success(.object([
            ("result", .string("speed")),
            ("clip", .string(material.id.uuidString)),
            ("speed", .number(rounded(updated?.playbackSpeed ?? speed))),
            ("timelineDuration", .number(rounded(updated?.timelineDuration ?? material.timelineDuration))),
        ]))
    }

    private static func rename(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard let material = resolveClip(args, in: project) else { return .failure("未找到片段。") }
        guard let title = args["title"]?.stringValue else { return .failure("请提供新的片段名称。") }
        guard state.renameMaterial(project.id, material.id, title: title) else { return .failure("无法重命名片段。") }
        let index = project.materials.firstIndex { $0.id == material.id } ?? 0
        let updated = current(material.id, projectID: project.id, state: state)
        return .success(.object([
            ("result", .string("renamed")),
            ("clip", .string(material.id.uuidString)),
            ("title", .string(updated?.displayTitle(index: index) ?? title)),
        ]))
    }

    private static func updateInsert(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard let material = resolveClip(args, in: project) else { return .failure("未找到片段。") }
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let index = args["index"]?.intValue, index >= 1, index <= (material.inserts ?? []).count else {
            return .failure("补充画面序号超出范围。")
        }
        let existing = (material.inserts ?? [])[index - 1]
        let start = args["start"]?.numberValue ?? existing.start
        let end = args["end"]?.numberValue ?? existing.end
        guard state.updateInsert(project.id, material.id, index: index - 1, start: start, end: end) else {
            return .failure("补充画面时间不合法或与已有补充画面重叠。")
        }
        return .success(.object([
            ("clip", .string(material.id.uuidString)),
            ("index", .number(Double(index))),
            ("start", .number(rounded(start))),
            ("end", .number(rounded(end))),
        ]))
    }

    private static func removeInsert(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard let material = resolveClip(args, in: project) else { return .failure("未找到片段。") }
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let index = args["index"]?.intValue, index >= 1, index <= (material.inserts ?? []).count else {
            return .failure("补充画面序号超出范围。")
        }
        var inserts = material.inserts ?? []
        inserts.remove(at: index - 1)
        guard state.setInserts(project.id, material.id, inserts) else { return .failure("保存补充画面失败。") }
        return .success(.object([("clip", .string(material.id.uuidString)),
                                 ("inserts", .number(Double(inserts.count)))]))
    }

    private static func regenerateMotion(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard let material = resolveClip(args, in: project) else { return .failure("未找到片段。") }
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard material.sourceReady else { return .failure("素材还没导出完成，暂时不能重做动效。") }
        guard material.motionState != .queued, material.motionState != .running else {
            return .failure("这个片段的动效已经在处理中，等它完成再改。")
        }
        let instruction = args["instruction"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        state.regenerateMotion(project.id, material.id, instruction: instruction)
        return .success(.object([
            ("clip", .string(material.id.uuidString)),
            ("state", .string("queued")),
            ("note", .string("动效已进入后台队列，渲染需要几分钟到几十分钟；完成后预览会自动更新。可以先用 job_status 查询进度。")),
        ]))
    }

    private static func jobStatus(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        return .success(.object([
            ("clips", .array(project.materials.map { material in
                .object([
                    ("id", .string(material.id.uuidString)),
                    ("motionState", .string(material.motionState.rawValue)),
                    ("motionPhase", .string(state.motionPhases[material.mediaID] ?? "")),
                    ("motionError", .string(material.motionError ?? "")),
                ])
            })),
            ("exporting", .bool(state.exportingProjects.contains(project.id))),
        ]))
    }

    // MARK: - Helpers

    private static func resolveClip(_ args: [String: JSONValue], in project: VideoProject) -> Material? {
        guard let value = args["clip"] else { return nil }
        if let number = value.intValue, number >= 1, number <= project.materials.count {
            return project.materials[number - 1]
        }
        if let text = value.stringValue {
            if let uuid = UUID(uuidString: text) {
                return project.materials.first { $0.id == uuid || $0.mediaID == uuid }
            }
            if let byTitle = project.materials.first(where: { $0.title?.trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                return byTitle
            }
            let digits = text.filter(\.isNumber)
            if let index = Int(digits), index >= 1, index <= project.materials.count {
                return project.materials[index - 1]
            }
        }
        return nil
    }

    private static func resolveAsset(_ args: [String: JSONValue], in project: VideoProject) -> ReferenceMedia? {
        guard let value = args["asset"] ?? args["assetID"] else { return nil }
        if let number = value.intValue, number >= 1, number <= project.referenceMedia.count {
            return project.referenceMedia[number - 1]
        }
        if let text = value.stringValue, let uuid = UUID(uuidString: text) {
            return project.referenceMedia.first { $0.id == uuid }
        }
        return nil
    }

    private static func subtitleIndex(_ args: [String: JSONValue], in material: Material) -> Int? {
        guard let value = args["index"]?.intValue, value >= 1, value <= material.subtitles.count else { return nil }
        return value - 1
    }

    private static func subtitleResult(_ material: Material, index: Int, state: AppState, projectID: UUID) -> JSONValue {
        let updated = current(material.id, projectID: projectID, state: state) ?? material
        guard updated.subtitles.indices.contains(index) else { return .object([("clip", .string(material.id.uuidString))]) }
        let subtitle = updated.subtitles[index]
        return .object([
            ("clip", .string(material.id.uuidString)),
            ("index", .number(Double(index + 1))),
            ("start", .number(rounded(subtitle.start))),
            ("end", .number(rounded(subtitle.end))),
            ("text", .string(subtitle.text)),
            ("subtitleCount", .number(Double(updated.subtitles.count))),
        ])
    }

    private static func current(_ id: UUID, projectID: UUID, state: AppState) -> Material? {
        state.projects.first { $0.id == projectID }?.materials.first { $0.id == id }
    }

    private static func changed(_ action: String, material: Material?) -> JSONValue {
        guard let material else { return .object([("result", .string(action))]) }
        return .object([
            ("result", .string(action)),
            ("clip", .string(material.id.uuidString)),
            ("in", .number(rounded(material.inPoint))),
            ("out", .number(rounded(material.outPoint))),
            ("timelineDuration", .number(rounded(material.timelineDuration))),
        ])
    }

    private static func rounded(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value * 1000).rounded() / 1000
    }

    private static func chineseNumeral(_ number: Int) -> String {
        let digits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        if number < 10 { return digits[max(0, number)] }
        if number == 10 { return "十" }
        if number < 20 { return "十" + digits[number - 10] }
        let tens = number / 10, ones = number % 10
        return digits[tens] + "十" + (ones == 0 ? "" : digits[ones])
    }
}
