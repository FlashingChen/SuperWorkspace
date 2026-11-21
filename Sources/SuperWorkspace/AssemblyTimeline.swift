import AVFoundation
import SwiftUI

struct InsertSelection: Equatable, Hashable {
    let materialID: UUID
    let index: Int
}

struct AssemblyTimelineLayout {
    struct Clip: Identifiable {
        let id: UUID
        let index: Int
        let start: Double
        let duration: Double
        var end: Double { start + duration }
    }
    let clips: [Clip]
    let duration: Double

    init(materials: [Material]) {
        var cursor = 0.0
        clips = materials.enumerated().map { index, material in
            let duration = material.duration.isFinite ? max(0, (material.outPoint - material.inPoint) / material.playbackSpeed) : 0
            defer { cursor += duration }
            return Clip(id: material.id, index: index, start: cursor, duration: duration)
        }
        duration = cursor
    }

    func time(at x: Double, scale: Double) -> Double {
        guard x.isFinite, scale.isFinite, scale > 0 else { return 0 }
        return min(duration, max(0, x / scale))
    }

    func clip(at time: Double) -> Clip? {
        clips.first { time >= $0.start && time < $0.end }
    }

    /// Where a source-time caption lands on the assembled timeline.
    static func globalStart(materialID: UUID, in materials: [Material], sourceTime: Double) -> Double {
        guard let index = materials.firstIndex(where: { $0.id == materialID }) else { return 0 }
        let offset = materials[..<index].reduce(0.0) { $0 + $1.timelineDuration }
        let material = materials[index]
        return offset + max(0, sourceTime - material.inPoint) / material.playbackSpeed
    }

    static func tickInterval(scale: Double) -> Double {
        [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600].first { $0 * scale >= 64 } ?? 3600
    }

    static func timecode(_ seconds: Double) -> String {
        let frames = max(0, Int((seconds.isFinite ? seconds : 0) * 30))
        return String(format: "%02d:%02d:%02d", frames / 1800, (frames / 30) % 60, frames % 30)
    }
}

struct AssemblyTimeline: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var state: AppState
    let project: VideoProject
    let playhead: Double
    let isPlaying: Bool
    let canPlay: Bool
    @Binding var selectedMaterial: UUID?
    @Binding var selectedSubtitle: String?
    @Binding var selectedInsert: InsertSelection?
    @Binding var focusSubtitle: String?
    @Binding var showsLibrary: Bool
    @Binding var showsSubtitlesPreview: Bool
    @Binding var previewRate: Double
    /// A caption field owns the keyboard, so a window-wide delete shortcut must stand down.
    let editingCaption: Bool
    let onSeek: (Double) -> Void
    let onPlay: () -> Void
    let onMove: (UUID, UUID, Bool) -> Void
    @Binding var zoom: Double
    @State private var dropTarget: UUID?
    @State private var insertTrackTargeted = false
    @State private var pendingRemoval: UUID?
    @State private var fittedDuration = 0.0
    @State private var draft: RangeDraft?
    @State private var snapGuideTime: Double?

    private var displayProject: VideoProject {
        var copy = project
        if let draft, let index = copy.materials.firstIndex(where: { $0.id == draft.materialID }) {
            switch draft.target {
            case .clip:
                copy.materials[index].trimStart = draft.range.lowerBound
                copy.materials[index].trimEnd = draft.range.upperBound
            case .subtitle(let subtitle):
                if copy.materials[index].subtitles.indices.contains(subtitle) {
                    copy.materials[index].subtitles[subtitle].start = draft.range.lowerBound
                    copy.materials[index].subtitles[subtitle].end = draft.range.upperBound
                }
            case .insert(let insertIndex):
                if var inserts = copy.materials[index].inserts, inserts.indices.contains(insertIndex) {
                    let existing = inserts[insertIndex]
                    inserts[insertIndex] = AIEditing.Insert(
                        clipID: existing.clipID, assetID: existing.assetID,
                        start: draft.range.lowerBound, end: draft.range.upperBound,
                        assetStart: existing.assetStart
                    )
                    copy.materials[index].inserts = inserts
                }
            }
        }
        return copy
    }

    private var layout: AssemblyTimelineLayout { .init(materials: displayProject.materials) }
    private var hasInserts: Bool {
        displayProject.materials.contains { !($0.inserts ?? []).isEmpty }
    }
    private var insertTrackHeight: CGFloat { hasInserts || insertTrackTargeted ? 30 : 22 }
    private let gutter: CGFloat = 76

    var body: some View {
        VStack(spacing: 0) {
            controls
            Rectangle().fill(palette.surface2).frame(height: 1)
            GeometryReader { geometry in
                let viewport = max(1, geometry.size.width - gutter - 24)
                let scale = min(600, max(0.05, viewport / max(1, fittedDuration > 0 ? fittedDuration : layout.duration)) * zoom)
                let width = max(viewport, layout.duration * scale + 32)
                HStack(spacing: 0) {
                    VStack(spacing: Metrics.space2) {
                        Color.clear.frame(height: 28)
                        trackLabel("插图", symbol: "photo").frame(height: insertTrackHeight)
                        trackLabel("字幕", symbol: "captions.bubble").frame(height: 32)
                        trackLabel("视频", symbol: "film").frame(height: 76)
                        Spacer(minLength: 0)
                    }
                    .frame(width: gutter)
                    .background(palette.bgSidebar)
                    ScrollView(.horizontal) {
                        ZStack(alignment: .topLeading) {
                            grid(width: width, height: geometry.size.height - 16, scale: scale)
                            VStack(alignment: .leading, spacing: Metrics.space2) {
                                ruler(width: width, scale: scale)
                                insertTrack(width: width, scale: scale)
                                subtitleTrack(width: width, scale: scale)
                                videoTrack(width: width, scale: scale)
                                Spacer(minLength: 10)
                            }
                            if let snapGuideTime {
                                Rectangle()
                                    .fill(palette.accent)
                                    .frame(width: 1, height: max(160, geometry.size.height - 18))
                                    .offset(x: min(layout.duration, max(0, snapGuideTime)) * scale)
                                    .allowsHitTesting(false)
                            }
                            playheadView(height: max(160, geometry.size.height - 18))
                                .offset(x: min(layout.duration, max(0, playhead)) * scale - 9)
                                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("assemblyTimeline"))
                                    .onChanged { onSeek(layout.time(at: $0.location.x, scale: scale)) })
                        }
                        .frame(width: width, height: max(190, geometry.size.height - 16), alignment: .topLeading)
                        .coordinateSpace(name: "assemblyTimeline")
                        .padding(.horizontal, Metrics.space3)
                    }
                    .scrollIndicators(.visible)
                }
            }
        }
        .background(palette.bgDeep)
        .frame(minHeight: 240, idealHeight: 280, maxHeight: 420)
        .onAppear { fittedDuration = max(1, layout.duration) }
        .onExitCommand { draft = nil; snapGuideTime = nil }
        .modifier(MaterialRemovalConfirmation(projectID: project.id, materialID: $pendingRemoval))
    }

    private var controls: some View {
        HStack(spacing: Metrics.space1_5) {
            Button { showsLibrary.toggle() } label: {
                Label("素材库", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(StudioSelectionStyle(selected: showsLibrary))
            .frame(height: Metrics.controlCompact)
            .help(showsLibrary ? "收起素材库抽屉" : "打开素材库抽屉")
            .accessibilityLabel(showsLibrary ? "收起素材库" : "打开素材库")

            Rectangle().fill(palette.surface2).frame(width: 1, height: 16).padding(.horizontal, Metrics.space1)

            Button(action: splitAtPlayhead) { Image(systemName: "scissors") }
                .help(splitHelp).accessibilityLabel("分割")
                .keyboardShortcut("b", modifiers: .command).disabled(!canSplit)
            Button { addSubtitleAtPlayhead() } label: { Image(systemName: "text.badge.plus") }
                .help("在播放头处新增字幕").accessibilityLabel("新增字幕")
                .accessibilityIdentifier("assembly.subtitles.add").disabled(!canAddSubtitle)
            Button { deleteSelectedItem() } label: { Image(systemName: "trash") }
                .help(deleteHelp).accessibilityLabel("删除选中项")
                .accessibilityIdentifier("assembly.subtitles.delete")
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!canDeleteSelectedItem || editingCaption)
            Button { state.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .help("撤销").accessibilityLabel("撤销").disabled(!state.canUndo)
            Button { state.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .help("重做").accessibilityLabel("重做").disabled(!state.canRedo)

            Spacer()

            Button { onSeek(playhead - 1 / 30) } label: { Image(systemName: "backward.end") }
                .help("上一帧").accessibilityLabel("上一帧").disabled(!canPlay)
            Button(action: onPlay) { Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 20) }
                .help(isPlaying ? "暂停（空格）" : "播放（空格）")
                .accessibilityLabel(isPlaying ? "暂停时间线" : "播放时间线")
                .keyboardShortcut(.space, modifiers: []).disabled(!canPlay)
            Button { onSeek(playhead + 1 / 30) } label: { Image(systemName: "forward.end") }
                .help("下一帧").accessibilityLabel("下一帧").disabled(!canPlay)
            Text(AssemblyTimelineLayout.timecode(playhead))
                .foregroundStyle(palette.textPrimary)
                .accessibilityIdentifier("assembly.playhead.timecode")
            Text("/ \(AssemblyTimelineLayout.timecode(layout.duration))").foregroundStyle(palette.textMuted)

            Menu {
                ForEach([1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button(rateLabel(rate)) { previewRate = rate }
                }
            } label: {
                Text(rateLabel(previewRate))
                    .font(.studio(.caption, weight: .medium))
                    .monospacedDigit()
            }
            .menuStyle(StudioMenuStyle())
            .fixedSize()
            .help("预览播放倍速（仅影响试看，不改变导出）")
            .accessibilityLabel("预览倍速 \(rateLabel(previewRate))")

            Button { showsSubtitlesPreview.toggle() } label: {
                Image(systemName: showsSubtitlesPreview ? "captions.bubble.fill" : "captions.bubble")
                    .foregroundStyle(showsSubtitlesPreview ? palette.accent : palette.textMuted)
            }
            .help(showsSubtitlesPreview ? "隐藏预览字幕" : "显示预览字幕")
            .accessibilityLabel(showsSubtitlesPreview ? "隐藏预览字幕" : "显示预览字幕")

            Spacer()

            Button { zoom = max(0.5, zoom / 1.4) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .accessibilityLabel("缩小时间线")
            StudioSlider(value: Binding(get: { log2(zoom) }, set: { zoom = pow(2, $0) }), range: -1...6).frame(width: 84).accessibilityLabel("时间线缩放")
            Button { zoom = min(64, zoom * 1.4) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
                .accessibilityLabel("放大时间线")
            Button { zoom = 1; fittedDuration = max(1, layout.duration) } label: { Text(verbatim: "适应") }
                .keyboardShortcut("0", modifiers: .command)
                .help("完整显示时间线")
        }
        .font(.studio(.timecode))
        .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
        .padding(.horizontal, Metrics.space4).frame(height: 44)
    }

    private func rateLabel(_ rate: Double) -> String {
        rate == floor(rate) ? "\(Int(rate))x" : String(format: "%.2gx", rate)
    }

    private func trackLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.studio(.caption))
            .foregroundStyle(palette.textSecondary).frame(maxWidth: .infinity)
    }

    private func grid(width: CGFloat, height: CGFloat, scale: Double) -> some View {
        Canvas { context, size in
            let interval = AssemblyTimelineLayout.tickInterval(scale: scale)
            var path = Path()
            for index in 0...min(2000, Int(layout.duration / interval) + 1) {
                let x = Double(index) * interval * scale
                path.move(to: CGPoint(x: x, y: 28))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(path, with: .color(palette.surface2.opacity(0.35)), lineWidth: 1)
        }.frame(width: width, height: height).allowsHitTesting(false)
    }

    private func ruler(width: CGFloat, scale: Double) -> some View {
        Canvas { context, size in
            let interval = AssemblyTimelineLayout.tickInterval(scale: scale)
            for index in 0...min(10000, Int(layout.duration / (interval / 5)) + 1) {
                let time = Double(index) * interval / 5
                let x = time * scale
                let major = index % 5 == 0
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height - (major ? 9 : 4)))
                tick.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(tick, with: .color(palette.surface3), lineWidth: 1)
                if major {
                    context.draw(Text(durationLabel(time)).font(.studio(.timecode)).foregroundStyle(palette.textSecondary),
                        at: CGPoint(x: x + 4, y: 8), anchor: .leading)
                }
            }
        }
        .frame(width: width, height: 28).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { onSeek(layout.time(at: $0.location.x, scale: scale)) })
        .accessibilityLabel("时间标尺，点击或拖动定位")
        .accessibilityIdentifier("assembly.timeline.ruler")
    }

    private func insertTrack(width: CGFloat, scale: Double) -> some View {
        let library = Dictionary(uniqueKeysWithValues: project.referenceMedia.map { ($0.id, $0) })
        return ZStack(alignment: .leading) {
            (insertTrackTargeted ? palette.ai.opacity(0.16) : palette.surface1.opacity(0.25))
            if !hasInserts {
                Text("拖入左侧素材库图片/视频，或让 AI 剪辑插入")
                    .font(.studio(.micro))
                    .foregroundStyle(palette.textMuted)
                    .padding(.leading, Metrics.space2)
                    .allowsHitTesting(false)
            }
            ForEach(layout.clips) { clip in
                let material = displayProject.materials[clip.index]
                let inserts = material.inserts ?? []
                ForEach(Array(inserts.enumerated()), id: \.offset) { index, insert in
                    if insert.end > material.inPoint && insert.start < material.outPoint {
                        insertBlock(insert, index: index, material: material, clip: clip,
                                    assetName: library[insert.assetID]?.name ?? "补充画面", scale: scale)
                    }
                }
            }
        }
        .frame(width: width, height: insertTrackHeight)
        .clipped()
        .dropDestination(for: String.self) { values, location in
            guard let raw = values.first, raw.hasPrefix("asset:"),
                  let assetID = UUID(uuidString: String(raw.dropFirst(6))) else { return false }
            let targetTime = layout.time(at: location.x, scale: scale)
            return insertAsset(assetID, atTimelineTime: targetTime)
        } isTargeted: { insertTrackTargeted = $0 }
    }

    private func insertAsset(_ assetID: UUID, atTimelineTime time: Double) -> Bool {
        guard let clip = layout.clip(at: time) ?? layout.clips.last else { return false }
        let material = project.materials[clip.index]
        let sourceTime = material.inPoint + (time - clip.start) * material.playbackSpeed
        let end = min(material.outPoint, sourceTime + 2.5 * material.playbackSpeed)
        guard state.addInsert(project.id, material.id, assetID: assetID, start: sourceTime, end: end) else {
            state.showToast("当前位置无法插入补充画面，可能与已有插图重叠。")
            return false
        }
        selectedMaterial = material.id
        selectedSubtitle = nil
        return true
    }

    private func insertBlock(_ insert: AIEditing.Insert, index: Int, material: Material,
                             clip: AssemblyTimelineLayout.Clip, assetName: String, scale: Double) -> some View {
        let selection = InsertSelection(materialID: clip.id, index: index)
        let selected = selectedInsert == selection
        let rate = material.playbackSpeed
        let visibleStart = max(material.inPoint, insert.start)
        let visibleEnd = min(material.outPoint, insert.end)
        let start = clip.start + (visibleStart - material.inPoint) / rate
        let blockWidth = CGFloat(max(selected ? 24 : 4, ((visibleEnd - visibleStart) / rate) * scale - 2))
        let shape = RoundedRectangle(cornerRadius: Metrics.radiusXS)

        return HStack(spacing: Metrics.space1) {
            Image(systemName: "photo").font(.studio(.micro)).accessibilityHidden(true)
            Text(assetName).font(.studio(.caption)).lineLimit(1)
        }
        .padding(.horizontal, selected ? Metrics.space3 : Metrics.space1_5)
        .frame(width: blockWidth, height: insertTrackHeight - 2, alignment: .leading)
        .foregroundStyle(palette.textPrimary)
        .background(palette.ai.opacity(selected ? 0.42 : 0.22))
        .clipShape(shape)
        .overlay(shape.strokeBorder(selected ? palette.ai : palette.ai.opacity(0.45), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedMaterial = clip.id
            selectedSubtitle = nil
            selectedInsert = selection
        }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("assemblyTimeline"))
            .onChanged { value in
                resize(materialID: clip.id, target: .insert(index), edge: .move, translation: value.translation.width, scale: scale)
            }
            .onEnded { _ in commitRange() })
        .overlay {
            if selected && blockWidth >= 22 {
                rangeGrips(materialID: clip.id, target: .insert(index), height: insertTrackHeight - 2, color: palette.ai, scale: scale)
            }
        }
        .contextMenu {
            Button("定位到插图开头") {
                selectedMaterial = clip.id
                selectedInsert = selection
                onSeek(start)
            }
            Divider()
            Button("删除补充画面", role: .destructive) {
                if state.removeInsert(project.id, clip.id, index: index) {
                    selectedInsert = nil
                }
            }
        }
        .zIndex(selected ? 2 : 0)
        .offset(x: start * scale)
    }

    private func subtitleTrack(width: CGFloat, scale: Double) -> some View {
        let severities = reviewSeverities
        return ZStack(alignment: .leading) {
            palette.surface1.opacity(0.35)
            ForEach(layout.clips) { clip in
                let material = displayProject.materials[clip.index]
                ForEach(Array(material.subtitles.enumerated()).filter { $0.element.end > material.inPoint && $0.element.start < material.outPoint }, id: \.offset) { index, subtitle in
                    subtitleBlock(subtitle, index: index, material: material, clip: clip, scale: scale,
                                  severity: severities[SubtitleKey.make(clip.id, index)])
                }
            }
        }.frame(width: width, height: 32).clipped()
    }

    private var reviewSeverities: [String: SubtitleReviewIssue.Severity] {
        var result: [String: SubtitleReviewIssue.Severity] = [:]
        for item in SubtitleReviewer.resolvedIssues(state.subtitleReviews[project.id], in: project) {
            let key = SubtitleKey.make(item.materialID, item.index)
            if let existing = result[key], existing >= item.issue.severity { continue }
            result[key] = item.issue.severity
        }
        return result
    }

    private func subtitleBlock(_ subtitle: TranscriptSegment, index: Int, material: Material,
                               clip: AssemblyTimelineLayout.Clip, scale: Double,
                               severity: SubtitleReviewIssue.Severity?) -> some View {
        let key = SubtitleKey.make(clip.id, index)
        let selected = selectedSubtitle == key
        let rate = material.playbackSpeed
        let visibleStart = max(material.inPoint, subtitle.start)
        let visibleEnd = min(material.outPoint, subtitle.end)
        let start = clip.start + (visibleStart - material.inPoint) / rate
        let width = CGFloat(max(selected ? 24 : 2, ((visibleEnd - visibleStart) / rate) * scale - 2))
        let shape = RoundedRectangle(cornerRadius: Metrics.radiusXS)
        let borderColor = selected ? palette.warning : palette.warning.opacity(0.35)
        let label = Text(subtitle.text).font(.studio(.caption)).lineLimit(1)
        let block = label
            .padding(.horizontal, selected ? Metrics.space3 : Metrics.space2)
            .frame(width: width, height: 30, alignment: .leading)
            .foregroundStyle(palette.textPrimary)
            .background(palette.warning.opacity(selected ? 0.38 : 0.18))
            .clipShape(shape)
            .overlay(shape.strokeBorder(borderColor, lineWidth: selected ? 2 : 1))
        let drag = DragGesture(minimumDistance: 4, coordinateSpace: .named("assemblyTimeline"))
            .onChanged { value in
                resize(materialID: clip.id, target: .subtitle(index), edge: .move, translation: value.translation.width, scale: scale)
            }
            .onEnded { _ in commitRange() }

        return block
            .contentShape(Rectangle())
            .onTapGesture {
                selectedMaterial = clip.id
                selectedSubtitle = key
                selectedInsert = nil
                onSeek(start)
            }
            .gesture(drag)
            .overlay {
                if selected && width >= 22 && material.transcriptState != .running {
                    rangeGrips(materialID: clip.id, target: .subtitle(index), height: 30, color: palette.warning, scale: scale)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let severity {
                    Circle()
                        .fill(severity == .error ? palette.danger
                              : severity == .warning ? palette.warning : palette.textMuted)
                        .frame(width: 5, height: 5).padding(Metrics.space1)
                        .accessibilityHidden(true)
                }
            }
            .contextMenu {
                Button("定位到字幕开头") {
                    selectedMaterial = clip.id
                    selectedSubtitle = key
                    onSeek(start)
                }
                Button("在播放头处分割字幕") { _ = splitSubtitle(clip.id, index: index) }
                    .disabled(!canSplitSubtitle(clip.id, index: index))
                Button("与下一条合并") { mergeSubtitle(clip.id, index: index) }
                    .disabled(!canMergeSubtitle(clip.id, index: index))
                Divider()
                Button("删除字幕", role: .destructive) {
                    if state.deleteSubtitle(project.id, clip.id, index: index) { selectedSubtitle = nil }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("字幕：\(subtitle.text)，\(durationLabel(start))")
            .accessibilityAddTraits(.isButton)
            .zIndex(selected ? 2 : 0)
            .offset(x: start * scale)
    }

    private func videoTrack(width: CGFloat, scale: Double) -> some View {
        ZStack(alignment: .leading) {
            palette.surface1.opacity(0.35)
            ForEach(layout.clips) { clip in
                let material = displayProject.materials[clip.index]
                let clipWidth = max(selectedMaterial == clip.id ? 24 : 2, clip.duration * scale - 2)
                let audioURL = ProjectLayout.materialDirectory(material, in: project).appendingPathComponent("audio-16k.wav")
                ZStack(alignment: .bottom) {
                    TimelineFilmstrip(url: material.exportState == .complete ? ProjectLayout.picture(material, in: project) : nil,
                        duration: project.materials[clip.index].outPoint - project.materials[clip.index].inPoint,
                        start: project.materials[clip.index].inPoint)
                    TimelineWaveform(url: audioURL, inPoint: material.inPoint, outPoint: material.outPoint)
                        .frame(height: 22)
                        .allowsHitTesting(false)
                }
                .frame(width: clipWidth, height: 74)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: Metrics.space1) {
                        Text("\(material.displayTitle(index: clip.index)) · \(durationLabel(clip.duration))")
                            .font(.studio(.micro)).lineLimit(1)
                        if abs(material.playbackSpeed - 1.0) > 0.005 {
                            Text(rateLabel(material.playbackSpeed))
                                .font(.studio(.micro, weight: .semibold))
                                .foregroundStyle(palette.warning)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, Metrics.space1_5).padding(.vertical, Metrics.space0_5)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: Metrics.radiusXS))
                    .padding(.leading, Metrics.space3).padding(.top, Metrics.space1_5)
                }
                .overlay(alignment: .topTrailing) {
                    if let badge = motionBadge(for: material) {
                        Text(badge.text)
                            .font(.studio(.micro, weight: .medium))
                            .foregroundStyle(badge.color)
                            .padding(.horizontal, Metrics.space1_5).padding(.vertical, Metrics.space0_5)
                            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: Metrics.radiusXS))
                            .padding(.trailing, Metrics.space3).padding(.top, Metrics.space1_5)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusS))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radiusS).strokeBorder(
                    dropTarget == clip.id || selectedMaterial == clip.id ? palette.accent : palette.surface3, lineWidth: selectedMaterial == clip.id ? 2 : 1))
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedMaterial = clip.id
                    selectedSubtitle = nil
                    selectedInsert = nil
                }
                .draggable(clip.id.uuidString)
                .dropDestination(for: String.self) { values, location in
                    guard let value = values.first else { return false }
                    if value.hasPrefix("asset:"), let assetID = UUID(uuidString: String(value.dropFirst(6))) {
                        let dropTime = clip.start + location.x / max(0.05, scale)
                        return insertAsset(assetID, atTimelineTime: dropTime)
                    }
                    guard let source = UUID(uuidString: value),
                          source != clip.id, project.materials.contains(where: { $0.id == source }) else { return false }
                    selectedMaterial = source
                    onMove(source, clip.id, location.x > clipWidth / 2)
                    return true
                } isTargeted: { dropTarget = $0 ? clip.id : nil }
                .contextMenu {
                    Button("在播放头处分割") { selectedMaterial = clip.id; splitAtPlayhead(materialID: clip.id) }
                        .disabled(!canSplit(materialID: clip.id))
                    Menu("片段倍速") {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { speed in
                            Button(rateLabel(speed)) { state.setMaterialSpeed(project.id, clip.id, speed: speed) }
                        }
                    }
                    if material.inPoint > 0 || material.outPoint < material.duration {
                        Button("恢复完整素材") { _ = state.setTrim(project.id, clip.id, start: 0, end: material.duration) }
                    }
                    MaterialProcessingActions(projectID: project.id, materialID: clip.id)
                    Button("向前移动") { if clip.index > 0 { onMove(clip.id, layout.clips[clip.index - 1].id, false) } }.disabled(clip.index == 0)
                    Button("向后移动") { if clip.index + 1 < layout.clips.count { onMove(clip.id, layout.clips[clip.index + 1].id, true) } }.disabled(clip.index + 1 == layout.clips.count)
                    Divider()
                    MaterialDeleteAction(projectID: project.id, materialID: clip.id) { pendingRemoval = clip.id }
                }
                .overlay {
                    if selectedMaterial == clip.id && clipWidth >= 22 && material.sourceReady {
                        rangeGrips(materialID: clip.id, target: .clip, height: 74, color: palette.accent, scale: scale)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(material.displayTitle(index: clip.index))，时长 \(durationLabel(clip.duration))，可拖动排序")
                .offset(x: clip.start * scale)
            }
        }.frame(width: width, height: 76).clipped()
    }

    private func motionBadge(for material: Material) -> (text: String, color: Color)? {
        guard material.wantsMotion else { return nil }
        switch material.motionState {
        case .complete: return material.useOriginal == true ? ("原片", palette.textSecondary) : ("动效", palette.ai)
        case .running: return ("渲染中", palette.ai)
        case .queued: return ("排队中", palette.textSecondary)
        case .failed: return ("动效失败", palette.danger)
        case .idle: return nil
        }
    }

    private func rangeGrips(materialID: UUID, target: RangeTarget, height: Double, color: Color, scale: Double) -> some View {
        HStack(spacing: 0) {
            grip(materialID: materialID, target: target, edge: .start, height: height, color: color, scale: scale)
            Spacer(minLength: 0).allowsHitTesting(false)
            grip(materialID: materialID, target: target, edge: .end, height: height, color: color, scale: scale)
        }
    }

    private func grip(materialID: UUID, target: RangeTarget, edge: TimelineRangeEdit.Edge, height: Double, color: Color, scale: Double) -> some View {
        let targetPrefix: String
        let idSegment: String
        let material = displayProject.materials.first { $0.id == materialID }
        let value: Double
        switch target {
        case .clip:
            targetPrefix = "素材"
            idSegment = "clip.\(materialID).video"
            value = edge == .start ? material?.inPoint ?? 0 : material?.outPoint ?? 0
        case .subtitle(let subtitle):
            targetPrefix = "字幕"
            idSegment = "subtitle.\(materialID).\(subtitle)"
            if let material, material.subtitles.indices.contains(subtitle) {
                value = edge == .start ? material.subtitles[subtitle].start : material.subtitles[subtitle].end
            } else { value = 0 }
        case .insert(let insertIndex):
            targetPrefix = "插图"
            idSegment = "insert.\(materialID).\(insertIndex)"
            if let material, let inserts = material.inserts, inserts.indices.contains(insertIndex) {
                value = edge == .start ? inserts[insertIndex].start : inserts[insertIndex].end
            } else { value = 0 }
        }
        let label = targetPrefix + (edge == .start ? "开始边缘" : "结束边缘")
        return Capsule().fill(color).frame(width: 4, height: min(20, height * 0.55))
            .frame(width: 12, height: height).background(color.opacity(0.12))
            .contentShape(Rectangle())
            .onHover { ($0 ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("assemblyTimeline"))
                .onChanged { resize(materialID: materialID, target: target, edge: edge, translation: $0.translation.width, scale: scale) }
                .onEnded { _ in commitRange() })
            .accessibilityLabel(label)
            .accessibilityValue(AssemblyTimelineLayout.timecode(value))
            .accessibilityIdentifier("assembly.\(idSegment).\(edge == .start ? "start" : "end")")
            .accessibilityAdjustableAction { direction in
                resize(materialID: materialID, target: target, edge: edge,
                       translation: (direction == .increment ? 1 : -1) * scale / 30, scale: scale, snap: false)
                commitRange()
            }
    }

    private func resize(materialID: UUID, target: RangeTarget, edge: TimelineRangeEdit.Edge, translation: Double, scale: Double, snap: Bool = true) {
        guard scale > 0, let material = project.materials.first(where: { $0.id == materialID }), material.sourceReady else { return }
        let rate = material.playbackSpeed
        selectedMaterial = materialID
        let start: Double, end: Double, lower: Double, upper: Double
        switch target {
        case .clip:
            selectedSubtitle = nil; selectedInsert = nil
            start = material.inPoint; end = material.outPoint; lower = 0; upper = material.duration
        case .subtitle(let subtitle):
            selectedSubtitle = "\(materialID)-\(subtitle)"; selectedInsert = nil
            guard material.transcriptState != .running, material.subtitles.indices.contains(subtitle) else { return }
            start = material.subtitles[subtitle].start; end = material.subtitles[subtitle].end
            lower = max(material.inPoint, subtitle == 0 ? 0 : material.subtitles[subtitle - 1].end)
            upper = min(material.outPoint, subtitle + 1 == material.subtitles.count ? material.duration : material.subtitles[subtitle + 1].start)
        case .insert(let insertIndex):
            selectedSubtitle = nil; selectedInsert = InsertSelection(materialID: materialID, index: insertIndex)
            let inserts = material.inserts ?? []
            guard inserts.indices.contains(insertIndex) else { return }
            start = inserts[insertIndex].start; end = inserts[insertIndex].end
            lower = max(material.inPoint, insertIndex == 0 ? material.inPoint : inserts[insertIndex - 1].end)
            upper = min(material.outPoint, insertIndex + 1 == inserts.count ? material.outPoint : inserts[insertIndex + 1].start)
        }
        let clipStart = AssemblyTimelineLayout(materials: project.materials).clips.first(where: { $0.id == materialID })?.start ?? 0
        let sourcePlayhead = material.inPoint + (playhead - clipStart) * rate
        let snaps = snap && !NSEvent.modifierFlags.contains(.option) ? [lower, upper, sourcePlayhead] : []
        let sourceDelta = (translation / scale) * rate
        let range = TimelineRangeEdit.range(start: start, end: end, edge: edge, delta: sourceDelta,
                                            lower: lower, upper: upper, snapPoints: snaps, snapDistance: (6 / scale) * rate)
        if !snaps.isEmpty {
            let activeEdgeValue = edge == .end ? range.upperBound : range.lowerBound
            if let snapped = snaps.first(where: { abs($0 - activeEdgeValue) < 0.000_5 }) {
                snapGuideTime = clipStart + (snapped - material.inPoint) / rate
            } else {
                snapGuideTime = nil
            }
        } else {
            snapGuideTime = nil
        }
        draft = RangeDraft(materialID: materialID, target: target, range: range)
    }

    private func commitRange() {
        snapGuideTime = nil
        guard let change = draft else { return }
        draft = nil
        let saved: Bool
        switch change.target {
        case .clip:
            saved = state.setTrim(project.id, change.materialID, start: change.range.lowerBound, end: change.range.upperBound)
        case .subtitle(let index):
            saved = state.setSubtitleTiming(project.id, change.materialID, index: index, start: change.range.lowerBound, end: change.range.upperBound)
        case .insert(let index):
            saved = state.updateInsert(project.id, change.materialID, index: index, start: change.range.lowerBound, end: change.range.upperBound)
        }
        if !saved { state.showToast("未能应用拖动，请检查范围后重试。") }
    }

    private var splitHelp: String {
        if let selection = selectedSubtitle.flatMap(SubtitleKey.parse),
           canSplitSubtitle(selection.materialID, index: selection.index) {
            return "在播放头处分割这条字幕（⌘B）"
        }
        return "在播放头处分割素材（⌘B）"
    }

    private var canSplit: Bool {
        if let selection = selectedSubtitle.flatMap(SubtitleKey.parse),
           canSplitSubtitle(selection.materialID, index: selection.index) { return true }
        return canSplit(materialID: selectedMaterial)
    }

    private func canSplit(materialID: UUID?) -> Bool {
        let clips = AssemblyTimelineLayout(materials: project.materials).clips
        guard let clip = clips.first(where: { materialID == nil ? playhead >= $0.start && playhead < $0.end : $0.id == materialID }),
              project.materials[clip.index].sourceReady else { return false }
        let rate = project.materials[clip.index].playbackSpeed
        let leftSource = (playhead - clip.start) * rate
        let rightSource = (clip.end - playhead) * rate
        return leftSource >= TimelineRangeEdit.frame - 0.000_001 && rightSource >= TimelineRangeEdit.frame - 0.000_001
    }

    private func splitAtPlayhead() {
        if let selection = selectedSubtitle.flatMap(SubtitleKey.parse),
           canSplitSubtitle(selection.materialID, index: selection.index) {
            if !splitSubtitle(selection.materialID, index: selection.index) {
                state.showToast("这条字幕无法按时间切分，先调整文字或时间。")
            }
            return
        }
        splitAtPlayhead(materialID: selectedMaterial)
    }

    private func splitAtPlayhead(materialID: UUID?) {
        let clips = AssemblyTimelineLayout(materials: project.materials).clips
        guard let clip = clips.first(where: { materialID == nil ? playhead >= $0.start && playhead < $0.end : $0.id == materialID }) else { return }
        let material = project.materials[clip.index]
        let sourceAt = material.inPoint + (playhead - clip.start) * material.playbackSpeed
        guard let right = state.splitMaterial(project.id, clip.id, at: sourceAt) else { return }
        selectedMaterial = right; selectedSubtitle = nil; selectedInsert = nil
    }

    private func subtitleContext(_ materialID: UUID) -> (clip: AssemblyTimelineLayout.Clip, material: Material)? {
        let layout = AssemblyTimelineLayout(materials: project.materials)
        guard let clip = layout.clips.first(where: { $0.id == materialID }) else { return nil }
        return (clip, project.materials[clip.index])
    }

    private func canSplitSubtitle(_ materialID: UUID, index: Int) -> Bool {
        guard let (clip, material) = subtitleContext(materialID),
              material.transcriptState != .running,
              material.subtitles.indices.contains(index),
              playhead >= clip.start, playhead < clip.end else { return false }
        let subtitle = material.subtitles[index]
        let time = material.inPoint + (playhead - clip.start) * material.playbackSpeed
        return subtitle.end > material.inPoint && subtitle.start < material.outPoint
            && time - subtitle.start >= TimelineRangeEdit.frame - 0.000_001
            && subtitle.end - time >= TimelineRangeEdit.frame - 0.000_001
    }

    @discardableResult
    private func splitSubtitle(_ materialID: UUID, index: Int) -> Bool {
        guard let (clip, material) = subtitleContext(materialID) else { return false }
        let time = material.inPoint + (playhead - clip.start) * material.playbackSpeed
        guard state.splitSubtitle(project.id, materialID, index: index, at: time) else { return false }
        selectedMaterial = materialID
        selectedSubtitle = SubtitleKey.make(materialID, index)
        return true
    }

    private func canMergeSubtitle(_ materialID: UUID, index: Int) -> Bool {
        guard let (_, material) = subtitleContext(materialID), material.transcriptState != .running,
              index + 1 < material.subtitles.count else { return false }
        let next = material.subtitles[index + 1]
        return next.end > material.inPoint && next.start < material.outPoint
    }

    private func mergeSubtitle(_ materialID: UUID, index: Int) {
        state.mergeSubtitle(project.id, materialID, index: index)
    }

    private var canAddSubtitle: Bool {
        guard let clip = layout.clip(at: playhead), project.materials[clip.index].sourceReady else { return false }
        return project.materials[clip.index].transcriptState == .complete
    }

    private func addSubtitleAtPlayhead() {
        guard let clip = layout.clip(at: playhead) else { return }
        let material = project.materials[clip.index]
        let sourceTime = material.inPoint + (playhead - clip.start) * material.playbackSpeed
        guard let index = state.insertSubtitle(project.id, material.id, at: sourceTime) else {
            state.showToast("这里没有可用的字幕空位，先移动或删除已有字幕。")
            return
        }
        selectedMaterial = material.id
        let key = SubtitleKey.make(material.id, index)
        selectedSubtitle = key
        selectedInsert = nil
        focusSubtitle = key
    }

    private var canDeleteSelectedItem: Bool {
        if let selectedInsert,
           let material = project.materials.first(where: { $0.id == selectedInsert.materialID }),
           (material.inserts ?? []).indices.contains(selectedInsert.index) {
            return true
        }
        guard let selection = selectedSubtitle.flatMap(SubtitleKey.parse),
              let material = project.materials.first(where: { $0.id == selection.materialID }) else { return false }
        return material.transcriptState != .running && material.subtitles.indices.contains(selection.index)
    }

    private var deleteHelp: String {
        selectedInsert != nil ? "删除选中的补充画面（⌘⌫）" : "删除选中的字幕（⌘⌫）"
    }

    private func deleteSelectedItem() {
        if let selectedInsert {
            if state.removeInsert(project.id, selectedInsert.materialID, index: selectedInsert.index) {
                self.selectedInsert = nil
            }
            return
        }
        guard let selection = selectedSubtitle.flatMap(SubtitleKey.parse) else { return }
        if state.deleteSubtitle(project.id, selection.materialID, index: selection.index) {
            selectedSubtitle = nil
        } else {
            state.showToast("未能删除这条字幕。")
        }
    }

    private enum RangeTarget {
        case clip
        case subtitle(Int)
        case insert(Int)
    }

    private struct RangeDraft {
        let materialID: UUID
        let target: RangeTarget
        let range: ClosedRange<Double>
    }

    private func playheadView(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill").font(.studio(.small)).frame(height: 16)
            Rectangle().frame(width: 1, height: max(0, height - 16))
        }
        .foregroundStyle(palette.accent)
        .frame(width: 18, height: height)
        .contentShape(Rectangle())
        .accessibilityLabel("播放头")
        .accessibilityValue(AssemblyTimelineLayout.timecode(playhead))
        .accessibilityAdjustableAction { direction in
            onSeek(playhead + (direction == .increment ? 1 / 30 : -1 / 30))
        }
    }
}

private struct TimelineWaveform: View {
    @Environment(\.palette) private var palette
    let url: URL
    let inPoint: Double
    let outPoint: Double
    @State private var peaks: [Float] = []

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty, size.width > 4 else { return }
            let barWidth = size.width / CGFloat(peaks.count)
            let baseline = size.height
            var path = Path()
            for (index, peak) in peaks.enumerated() {
                let height = max(1, CGFloat(peak) * (size.height - 2))
                let x = CGFloat(index) * barWidth + barWidth * 0.5
                path.move(to: CGPoint(x: x, y: baseline))
                path.addLine(to: CGPoint(x: x, y: baseline - height))
            }
            context.stroke(path, with: .color(palette.accent.opacity(0.65)), lineWidth: max(1, min(2, barWidth * 0.65)))
        }
        .background(LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom))
        .task(id: "\(url.path):\(Int(inPoint * 10)):\(Int(outPoint * 10))") {
            peaks = await Self.computePeaks(url: url, inPoint: inPoint, outPoint: outPoint, buckets: 120)
        }
    }

    private static func computePeaks(url: URL, inPoint: Double, outPoint: Double, buckets: Int) async -> [Float] {
        await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  data.count > 44 else { return [] }
            let sampleRate = 16000.0
            let headerBytes = 44
            let totalSamples = (data.count - headerBytes) / 2
            guard totalSamples > 0 else { return [] }
            let startSample = min(totalSamples - 1, max(0, Int(inPoint * sampleRate)))
            let endSample = min(totalSamples, max(startSample + 1, Int(outPoint * sampleRate)))
            let span = endSample - startSample
            let count = min(buckets, max(1, span))
            var result = [Float](repeating: 0, count: count)
            let step = max(1, span / count)
            let strideSamples = max(1, step / 24)
            data.withUnsafeBytes { raw in
                let samples = raw.baseAddress!.advanced(by: headerBytes).assumingMemoryBound(to: Int16.self)
                for bucket in 0..<count {
                    let from = startSample + bucket * step
                    let to = min(endSample, from + step)
                    var peak: Int32 = 0
                    var i = from
                    while i < to {
                        let v = abs(Int32(samples[i]))
                        if v > peak { peak = v }
                        i += strideSamples
                    }
                    result[bucket] = min(1, Float(peak) / 32768.0)
                }
            }
            return result
        }.value
    }
}

private struct TimelineFilmstrip: View {
    @Environment(\.palette) private var palette
    let url: URL?
    let duration: Double
    var start: Double = 0
    @State private var frames: [NSImage] = []
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if frames.isEmpty {
                    palette.mediaGround.overlay { Image(systemName: "film").foregroundStyle(.white.opacity(0.5)) }
                } else {
                    ForEach(frames.indices, id: \.self) { index in
                        Image(nsImage: frames[index]).resizable().scaledToFill()
                            .frame(width: geometry.size.width / CGFloat(frames.count), height: geometry.size.height).clipped()
                    }
                }
            }
        }
        .task(id: "\(url?.path ?? ""): \(start):\(duration)") {
            frames = []
            guard let url, duration > 0 else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 140)
            let count = min(12, max(1, Int(ceil(duration / 3))))
            var images: [NSImage] = []
            for index in 0..<count {
                guard !Task.isCancelled else { return }
                if let frame = try? await generator.image(at: CMTime(seconds: start + duration * (Double(index) + 0.1) / Double(count), preferredTimescale: 600)) {
                    images.append(NSImage(cgImage: frame.image, size: .zero))
                }
            }
            if !Task.isCancelled { frames = images }
        }
    }
}
