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
        case "audio_add":
            return addAudio(call.args, project: project, state: state)
        case "audio_update":
            return updateAudio(call.args, project: project, state: state)
        case "audio_remove":
            return removeAudio(call.args, project: project, state: state)
        case "callout_add":
            return addCallout(call.args, project: project, state: state)
        case "callout_update":
            return updateCallout(call.args, project: project, state: state)
        case "callout_remove":
            return removeCallout(call.args, project: project, state: state)
        case "silence_analyze":
            return analyzeSilence(call.args, project: project)
        case "motion_html_add":
            return addHTMLMotion(call.args, project: project, state: state)
        case "motion_html_update":
            return updateHTMLMotion(call.args, project: project, state: state)
        case "motion_html_remove":
            return removeHTMLMotion(call.args, project: project, state: state)
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
        let audioClips = (project.audioClips ?? []).enumerated().map { index, clip -> JSONValue in
            .object([
                ("index", .number(Double(index + 1))),
                ("id", .string(clip.id.uuidString)),
                ("assetID", .string(clip.assetID.uuidString)),
                ("kind", .string(clip.kind.rawValue)),
                ("start", .number(rounded(clip.start))),
                ("end", .number(rounded(clip.end))),
                ("volume", .number(rounded(clip.volume))),
                ("fadeIn", .number(rounded(clip.fadeIn))),
                ("fadeOut", .number(rounded(clip.fadeOut))),
                ("duckUnderSpeech", .bool(clip.duckUnderSpeech)),
            ])
        }
        let callouts = (project.callouts ?? []).enumerated().map { index, item -> JSONValue in
            .object([
                ("index", .number(Double(index + 1))),
                ("id", .string(item.id.uuidString)),
                ("start", .number(rounded(item.start))),
                ("end", .number(rounded(item.end))),
                ("text", .string(item.text)),
                ("subtitle", .string(item.subtitle ?? "")),
                ("style", .string(item.style.rawValue)),
                ("x", .number(rounded(item.x))),
                ("y", .number(rounded(item.y))),
            ])
        }
        let htmlMotions = (project.htmlMotions ?? []).enumerated().map { index, item -> JSONValue in
            .object([
                ("index", .number(Double(index + 1))),
                ("id", .string(item.id.uuidString)),
                ("name", .string(item.name)),
                ("mode", .string(item.mode.rawValue)),
                ("start", .number(rounded(item.start))),
                ("end", .number(rounded(item.end))),
                ("file", .string(item.fileName)),
            ])
        }
        return .object([
            ("project", .object([
                ("id", .string(project.id.uuidString)),
                ("name", .string(project.name)),
                ("frozen", .bool(project.isFrozen)),
                ("totalDuration", .number(rounded(offset))),
                ("canvasWidth", project.canvasWidth.map { .number(rounded($0)) } ?? .null),
                ("canvasHeight", project.canvasHeight.map { .number(rounded($0)) } ?? .null),
            ])),
            ("clips", .array(clips)),
            ("htmlMotions", .array(htmlMotions)),
            ("audioClips", .array(audioClips)),
            ("callouts", .array(callouts)),
            ("library", .array(library)),
            ("notes", .array([
                .string("时间单位均为秒。in/out 是片段在原视频中的时间；timelineStart、audioClips 与 callouts 的 start/end 是成片时间轴秒数。"),
                .string("clip 参数可以传片段序号（1 开始）、自定义片段名称或片段 id。subtitle 的 index 从 1 开始。"),
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

    private static func addAudio(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let asset = resolveAsset(args, in: project), asset.kind == .audio else {
            return .failure("未找到素材库音频，请先导入音频素材并传入序号或 id。")
        }
        let total = AssemblyTimelineLayout(materials: project.materials).duration
        let kind: AudioClip.Kind = args["kind"]?.stringValue == "effect" ? .effect : .music
        let start = max(0, args["start"]?.numberValue ?? 0)
        let defaultEnd = kind == .music ? max(start + 1, total) : min(max(start + 1, total), start + (asset.duration ?? 2))
        let end = args["end"]?.numberValue ?? defaultEnd
        let volume = args["volume"]?.numberValue ?? (kind == .music ? 0.25 : 0.85)
        let fadeIn = args["fadeIn"]?.numberValue ?? (kind == .music ? 0.8 : 0)
        let fadeOut = args["fadeOut"]?.numberValue ?? (kind == .music ? 1.0 : 0)
        let duck = args["duckUnderSpeech"]?.boolValue ?? (kind == .music)
        let clip = AudioClip(
            assetID: asset.id, kind: kind, start: start, end: end,
            assetStart: max(0, args["assetStart"]?.numberValue ?? 0),
            volume: min(1.5, max(0, volume)),
            fadeIn: max(0, fadeIn), fadeOut: max(0, fadeOut), duckUnderSpeech: duck
        )
        guard state.addAudioClip(project.id, clip) else { return .failure("无法添加音频，请检查时间范围。") }
        return .success(.object([
            ("result", .string("audio_added")),
            ("id", .string(clip.id.uuidString)),
            ("kind", .string(kind.rawValue)),
            ("start", .number(rounded(clip.start))),
            ("end", .number(rounded(clip.end))),
            ("volume", .number(rounded(clip.volume))),
        ]))
    }

    private static func updateAudio(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let target = resolveAudioClip(args, in: project) else { return .failure("未找到音频条，请传入序号或 id。") }
        let ok = state.updateAudioClip(project.id, id: target.id) { clip in
            if let s = args["start"]?.numberValue { clip.start = max(0, s) }
            if let e = args["end"]?.numberValue { clip.end = max(clip.start + 0.05, e) }
            if let v = args["volume"]?.numberValue { clip.volume = min(1.5, max(0, v)) }
            if let fi = args["fadeIn"]?.numberValue { clip.fadeIn = max(0, fi) }
            if let fo = args["fadeOut"]?.numberValue { clip.fadeOut = max(0, fo) }
            if let duck = args["duckUnderSpeech"]?.boolValue { clip.duckUnderSpeech = duck }
        }
        guard ok else { return .failure("更新音频失败。") }
        return .success(.object([("result", .string("audio_updated")), ("id", .string(target.id.uuidString))]))
    }

    private static func removeAudio(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let target = resolveAudioClip(args, in: project) else { return .failure("未找到音频条，请传入序号或 id。") }
        guard state.removeAudioClip(project.id, id: target.id) else { return .failure("删除音频失败。") }
        return .success(.object([("result", .string("audio_removed")), ("id", .string(target.id.uuidString))]))
    }

    private static func addCallout(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let text = args["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .failure("请提供花字文案 text。")
        }
        guard let start = args["start"]?.numberValue else { return .failure("请提供花字开始时间 start（成片秒数）。") }
        let end = args["end"]?.numberValue ?? (start + 3.0)
        let style = args["style"]?.stringValue.flatMap(CalloutOverlay.Style.init(rawValue:)) ?? .callout
        let defaultY: Double = switch style {
        case .title: 0.45
        case .badge: 0.12
        case .callout: 0.22
        case .lowerThird: 0.78
        }
        let defaultX: Double = style == .lowerThird ? 0.34 : 0.5
        let item = CalloutOverlay(
            start: max(0, start),
            end: max(start + 0.2, end),
            text: text,
            subtitle: args["subtitle"]?.stringValue,
            style: style,
            x: args["x"]?.numberValue ?? defaultX,
            y: args["y"]?.numberValue ?? defaultY,
            accentHex: args["accentHex"]?.stringValue
        )
        guard state.addCallout(project.id, item) else { return .failure("添加花字失败，请检查时间范围。") }
        return .success(.object([
            ("result", .string("callout_added")),
            ("id", .string(item.id.uuidString)),
            ("style", .string(item.style.rawValue)),
            ("start", .number(rounded(item.start))),
            ("end", .number(rounded(item.end))),
            ("text", .string(item.text)),
        ]))
    }

    private static func updateCallout(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let target = resolveCallout(args, in: project) else { return .failure("未找到花字，请传入序号或 id。") }
        let ok = state.updateCallout(project.id, id: target.id) { item in
            if let t = args["text"]?.stringValue, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { item.text = t }
            if let s = args["subtitle"]?.stringValue { item.subtitle = s.isEmpty ? nil : s }
            if let start = args["start"]?.numberValue { item.start = max(0, start) }
            if let end = args["end"]?.numberValue { item.end = max(item.start + 0.1, end) }
            if let style = args["style"]?.stringValue.flatMap(CalloutOverlay.Style.init(rawValue:)) { item.style = style }
            if let x = args["x"]?.numberValue { item.x = min(0.95, max(0.05, x)) }
            if let y = args["y"]?.numberValue { item.y = min(0.92, max(0.08, y)) }
            if let hex = args["accentHex"]?.stringValue { item.accentHex = hex.isEmpty ? nil : hex }
        }
        guard ok else { return .failure("更新花字失败。") }
        return .success(.object([("result", .string("callout_updated")), ("id", .string(target.id.uuidString))]))
    }

    private static func removeCallout(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let target = resolveCallout(args, in: project) else { return .failure("未找到花字，请传入序号或 id。") }
        guard state.removeCallout(project.id, id: target.id) else { return .failure("删除花字失败。") }
        return .success(.object([("result", .string("callout_removed")), ("id", .string(target.id.uuidString))]))
    }

    private static func analyzeSilence(_ args: [String: JSONValue], project: VideoProject) -> ProjectToolOutcome {
        guard let material = resolveClip(args, in: project) else { return .failure("未找到片段。") }
        let minDuration = max(0.25, args["minDuration"]?.numberValue ?? 0.6)
        let threshold = min(0.2, max(0.005, args["threshold"]?.numberValue ?? 0.02))
        let wavURL = ProjectLayout.materialDirectory(material, in: project).appendingPathComponent("audio-16k.wav")
        guard let data = try? Data(contentsOf: wavURL, options: .mappedIfSafe), data.count > 44 else {
            return .failure("该片段尚无音频波形缓存（需先完成字幕音频提取）。")
        }
        let sampleRate = 16000
        let windowSamples = sampleRate / 20 // 50ms windows
        let totalSamples = (data.count - 44) / 2
        let startWindow = max(0, Int(material.inPoint * 20))
        let endWindow = min(totalSamples / windowSamples, Int(ceil(material.outPoint * 20)))
        var silences: [(Double, Double)] = []
        var quietStart: Double?
        data.withUnsafeBytes { raw in
            let samples = raw.baseAddress!.advanced(by: 44).assumingMemoryBound(to: Int16.self)
            for w in startWindow..<endWindow {
                let from = w * windowSamples
                let to = min(totalSamples, from + windowSamples)
                var peak: Int32 = 0
                for i in from..<to {
                    let v = abs(Int32(samples[i]))
                    if v > peak { peak = v }
                }
                let amp = Double(peak) / 32768.0
                let t = Double(w) * 0.05
                if amp < threshold {
                    if quietStart == nil { quietStart = t }
                } else if let s = quietStart {
                    if t - s >= minDuration { silences.append((s, t)) }
                    quietStart = nil
                }
            }
            if let s = quietStart {
                let endT = Double(endWindow) * 0.05
                if endT - s >= minDuration { silences.append((s, endT)) }
            }
        }
        return .success(.object([
            ("clip", .string(material.id.uuidString)),
            ("silences", .array(silences.prefix(60).map { s, e in
                .object([
                    ("start", .number(rounded(s))),
                    ("end", .number(rounded(e))),
                    ("duration", .number(rounded(e - s))),
                ])
            })),
        ]))
    }

    private static func resolveAudioClip(_ args: [String: JSONValue], in project: VideoProject) -> AudioClip? {
        let clips = project.audioClips ?? []
        if let id = args["id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
            return clips.first { $0.id == id }
        }
        if let index = args["index"]?.intValue, index >= 1, index <= clips.count {
            return clips[index - 1]
        }
        return nil
    }

    private static func resolveCallout(_ args: [String: JSONValue], in project: VideoProject) -> CalloutOverlay? {
        let items = project.callouts ?? []
        if let id = args["id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
            return items.first { $0.id == id }
        }
        if let index = args["index"]?.intValue, index >= 1, index <= items.count {
            return items[index - 1]
        }
        return nil
    }

    private static func addHTMLMotion(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let html = args["html"]?.stringValue, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("请提供完整的单文件 HTML/CSS/SVG 源码 html。")
        }
        guard let start = args["start"]?.numberValue else { return .failure("请提供动效开始时间 start（成片秒数）。") }
        let end = args["end"]?.numberValue ?? (start + 3.0)
        let name = args["name"]?.stringValue ?? "即时动效"
        let mode: HTMLMotionOverlay.Mode = args["mode"]?.stringValue == "fullscreen" ? .fullscreen : .overlay
        guard let item = state.addHTMLMotion(project.id, name: name, start: max(0, start), end: max(start + 0.2, end), mode: mode, html: html) else {
            return .failure("添加即时动效失败，请检查时间范围。")
        }
        return .success(.object([
            ("result", .string("html_motion_added")),
            ("id", .string(item.id.uuidString)),
            ("name", .string(item.name)),
            ("mode", .string(item.mode.rawValue)),
            ("start", .number(rounded(item.start))),
            ("end", .number(rounded(item.end))),
        ]))
    }

    private static func updateHTMLMotion(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let target = resolveHTMLMotion(args, in: project) else { return .failure("未找到即时动效，请传入序号或 id。") }
        let ok = state.updateHTMLMotion(project.id, id: target.id, html: args["html"]?.stringValue) { item in
            if let name = args["name"]?.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { item.name = name }
            if let start = args["start"]?.numberValue { item.start = max(0, start) }
            if let end = args["end"]?.numberValue { item.end = max(item.start + 0.1, end) }
            if let mode = args["mode"]?.stringValue.flatMap(HTMLMotionOverlay.Mode.init(rawValue:)) { item.mode = mode }
        }
        guard ok else { return .failure("更新即时动效失败。") }
        return .success(.object([("result", .string("html_motion_updated")), ("id", .string(target.id.uuidString))]))
    }

    private static func removeHTMLMotion(_ args: [String: JSONValue], project: VideoProject, state: AppState) -> ProjectToolOutcome {
        guard !project.isFrozen else { return .failure("项目已冻结，先取消冻结再修改。") }
        guard let target = resolveHTMLMotion(args, in: project) else { return .failure("未找到即时动效，请传入序号或 id。") }
        guard state.removeHTMLMotion(project.id, id: target.id) else { return .failure("删除即时动效失败。") }
        return .success(.object([("result", .string("html_motion_removed")), ("id", .string(target.id.uuidString))]))
    }

    private static func resolveHTMLMotion(_ args: [String: JSONValue], in project: VideoProject) -> HTMLMotionOverlay? {
        let items = project.htmlMotions ?? []
        if let id = args["id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
            return items.first { $0.id == id }
        }
        if let index = args["index"]?.intValue, index >= 1, index <= items.count {
            return items[index - 1]
        }
        return nil
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
