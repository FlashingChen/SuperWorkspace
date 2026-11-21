import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct AssemblyView: View {
    enum SideTab: String, Hashable {
        case ai = "AI 剪辑"
        case subtitles = "字幕"
        case properties = "属性"
    }

    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    let project: VideoProject
    @State private var player = AVPlayer()
    @State private var previewError: String?
    @State private var playhead = 0.0
    @State private var observer: Any?
    @State private var loading = false
    @State private var isPlaying = false
    @State private var selectedMaterial: UUID?
    @State private var selectedSubtitle: String?
    @State private var selectedInsert: InsertSelection?
    @State private var focusSubtitle: String?
    @FocusState private var focusedSubtitle: String?
    @State private var zoom = 1.0
    @State private var previewFraction = 0.62
    @State private var dragOrigin: Double?
    @State private var restored = false
    @State private var rebuildTask: Task<Void, Never>?
    @State private var sideTab: SideTab = .ai
    @State private var showsLibrary = false
    @State private var showsSubtitlesPreview = true
    @State private var previewRate = 1.0
    @State private var importingMedia = false

    private var chatAgent: AssemblyAgent { state.assemblyAgent(for: project.id) }

    // Video composition only rebuilds when picture/timing/inserts/canvas change;
    // subtitle text and timing update live on the overlay with zero black-screen flicker.
    private var previewKey: AssemblyPreviewInputs { AssemblyPreviewInputs(project: project) }

    var body: some View {
        VStack(spacing: 0) {
            if project.materials.isEmpty {
                StudioWorkspace(title: "还没有素材", detail: "录制后即可预览、裁剪、添加插图和校对字幕。") {
                    StudioPreview(symbol: "film.stack", title: "等待录制素材")
                } controls: {
                    Button("录制新素材", systemImage: "record.circle") { state.record() }
                        .buttonStyle(StudioButtonStyle(kind: .primary))
                }
            } else {
                GeometryReader { geometry in
                    let height = min(max(220, geometry.size.height * previewFraction), max(220, geometry.size.height - 246))
                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: Metrics.space3) {
                            if showsLibrary {
                                libraryDrawer
                                    .frame(width: Metrics.libraryDrawer)
                                    .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusL))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: Metrics.radiusL)
                                            .strokeBorder(palette.surface2, lineWidth: 1)
                                    }
                            }
                            previewStage
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            rightPanel
                                .frame(width: Metrics.inspector)
                                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusL))
                                .overlay {
                                    RoundedRectangle(cornerRadius: Metrics.radiusL)
                                        .strokeBorder(palette.surface2, lineWidth: 1)
                                }
                        }
                        .padding(Metrics.space3)
                        .frame(height: height)

                        Rectangle().fill(palette.surface2).frame(height: 6)
                            .overlay { Capsule().fill(palette.surface3).frame(width: 32, height: 2) }
                            .contentShape(Rectangle())
                            .onHover { ($0 ? NSCursor.resizeUpDown : NSCursor.arrow).set() }
                            .gesture(DragGesture().onChanged { value in
                                if dragOrigin == nil { dragOrigin = height }
                                previewFraction = min(0.82, max(0.24, ((dragOrigin ?? height) + value.translation.height) / max(1, geometry.size.height)))
                            }.onEnded { _ in dragOrigin = nil; remember(flush: true) })
                            .accessibilityLabel("预览区域高度")
                            .accessibilityAdjustableAction { direction in
                                previewFraction = min(0.82, max(0.24, previewFraction + (direction == .increment ? 0.05 : -0.05)))
                            }

                        AssemblyTimeline(
                            project: project,
                            playhead: playhead,
                            isPlaying: isPlaying,
                            canPlay: player.currentItem != nil,
                            selectedMaterial: $selectedMaterial,
                            selectedSubtitle: $selectedSubtitle,
                            selectedInsert: $selectedInsert,
                            focusSubtitle: $focusSubtitle,
                            showsLibrary: $showsLibrary,
                            showsSubtitlesPreview: $showsSubtitlesPreview,
                            previewRate: $previewRate,
                            editingCaption: focusedSubtitle != nil,
                            onSeek: seek,
                            onPlay: togglePlayback,
                            onMove: { state.reorderMaterial(project.id, source: $0, target: $1, after: $2) },
                            zoom: $zoom
                        )
                    }
                }
            }
        }
        .background(palette.bgBase)
        .fileImporter(isPresented: $importingMedia, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importReferenceMedia(urls) }
        }
        .onAppear {
            let session = state.editorSession(project.id)
            playhead = session.playhead.isFinite ? max(0, session.playhead) : 0
            zoom = min(64, max(0.5, session.zoom))
            previewFraction = min(0.82, max(0.24, session.previewHeight))
            selectedMaterial = session.selectedMaterial
            selectedSubtitle = session.selectedSubtitle
            restored = true
            schedulePreview()
            Task { await state.lockCanvas(project.id) }
        }
        .onChange(of: previewKey) { _, _ in schedulePreview() }
        .onChange(of: playhead) { _, _ in remember() }
        .onChange(of: zoom) { _, _ in remember(flush: true) }
        .onChange(of: selectedSubtitle) { _, value in
            remember(flush: true)
            if value != nil, sideTab == .properties { sideTab = .subtitles }
        }
        .onChange(of: selectedInsert) { _, value in
            if value != nil { sideTab = .properties }
        }
        .onChange(of: previewRate) { _, rate in
            if isPlaying { player.rate = Float(rate) }
        }
        .onChange(of: focusSubtitle) { _, key in
            guard let key else { return }
            focusSubtitle = nil
            sideTab = .subtitles
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                focusedSubtitle = key
            }
        }
        .onChange(of: selectedMaterial) { _, _ in remember(flush: true) }
        .onChange(of: project.materials.map(\.id)) { _, ids in
            if let selectedMaterial, !ids.contains(selectedMaterial) {
                self.selectedMaterial = nil
                selectedSubtitle = nil
                selectedInsert = nil
            }
        }
        .onDisappear { remember(flush: true); restored = false; rebuildTask?.cancel(); stopPreview() }
    }

    // MARK: - Preview Stage

    private var previewStage: some View {
        ZStack {
            VideoSurface(player: player, controlsStyle: .none)
                .contentShape(Rectangle())
                .onTapGesture {
                    if player.currentItem != nil { togglePlayback() }
                }
            if showsSubtitlesPreview, let caption = activeSubtitleText {
                VStack {
                    Spacer()
                    Text(caption)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Metrics.space3)
                        .padding(.vertical, Metrics.space1_5)
                        .background(Color.black.opacity(0.68), in: RoundedRectangle(cornerRadius: Metrics.radiusS))
                        .padding(.horizontal, Metrics.space6)
                        .padding(.bottom, Metrics.space5)
                }
                .allowsHitTesting(false)
            }
            if loading {
                VStack {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                            .padding(Metrics.space2)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(Metrics.space3)
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            if let previewError {
                VStack(spacing: Metrics.space3) {
                    Text(previewError).multilineTextAlignment(.center)
                    Button("重试预览") { schedulePreview() }
                        .buttonStyle(StudioButtonStyle())
                }
                .foregroundStyle(.white)
                .padding(Metrics.space6)
            }
        }
        .background(palette.mediaGround)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusL))
    }

    private var activeSubtitleText: String? {
        let layout = AssemblyTimelineLayout(materials: project.materials)
        guard let clip = layout.clip(at: playhead) else { return nil }
        let material = project.materials[clip.index]
        let sourceTime = material.inPoint + (playhead - clip.start) * material.playbackSpeed
        return material.subtitles.first(where: {
            $0.end > material.inPoint && $0.start < material.outPoint
                && sourceTime >= $0.start && sourceTime < $0.end
        })?.text
    }

    private var activeSubtitleKey: String? {
        let layout = AssemblyTimelineLayout(materials: project.materials)
        guard let clip = layout.clip(at: playhead) else { return nil }
        let material = project.materials[clip.index]
        let sourceTime = material.inPoint + (playhead - clip.start) * material.playbackSpeed
        guard let index = material.subtitles.firstIndex(where: {
            $0.end > material.inPoint && $0.start < material.outPoint
                && sourceTime >= $0.start && sourceTime < $0.end
        }) else { return nil }
        return SubtitleKey.make(material.id, index)
    }

    // MARK: - Left Resource Drawer

    private var libraryDrawer: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.space2) {
                Text("素材库").font(.studio(.smallStrong))
                Spacer()
                Button { importingMedia = true } label: {
                    Label("导入", systemImage: "plus")
                }
                .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                .disabled(project.isFrozen)
            }
            .padding(.horizontal, Metrics.space3)
            .frame(height: Metrics.row)
            Divider()
            if project.referenceMedia.isEmpty {
                VStack(spacing: Metrics.space2) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(palette.textMuted)
                    Text("导入图片或视频，拖入时间线插图轨，或让 AI 剪辑自动调用。")
                        .font(.studio(.caption))
                        .foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(Metrics.space4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: Metrics.space2) {
                        ForEach(project.referenceMedia) { media in
                            libraryRow(media)
                        }
                    }
                    .padding(Metrics.space2)
                }
            }
            Divider()
            Button { state.record() } label: {
                Label("补录新片段", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(StudioButtonStyle(kind: .secondary, size: .compact))
            .disabled(project.isFrozen)
            .padding(Metrics.space2)
        }
        .background(palette.bgSidebar)
    }

    private func libraryRow(_ media: ReferenceMedia) -> some View {
        HStack(spacing: Metrics.space2) {
            Image(systemName: media.kind == .image ? "photo" : "film")
                .font(.studio(.small))
                .foregroundStyle(palette.ai)
                .frame(width: 22, height: 22)
                .background(palette.surface1, in: RoundedRectangle(cornerRadius: Metrics.radiusXS))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.space0_5) {
                Text(media.name).font(.studio(.caption)).lineLimit(1)
                if !media.description.isEmpty {
                    Text(media.description).font(.studio(.micro)).foregroundStyle(palette.textMuted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button { insertLibraryMediaAtPlayhead(media) } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
            .help("在播放头处插入 2.5 秒")
            .accessibilityLabel("插入 \(media.name)")
            .disabled(project.isFrozen)
        }
        .padding(Metrics.space1_5)
        .background(palette.surface1.opacity(0.65), in: RoundedRectangle(cornerRadius: Metrics.radiusS))
        .contentShape(Rectangle())
        .draggable("asset:\(media.id.uuidString)")
    }

    private func insertLibraryMediaAtPlayhead(_ media: ReferenceMedia) {
        guard let (material, sourceTime) = materialAtPlayhead() else {
            state.showToast("请先将播放头定位到片段内。")
            return
        }
        let end = min(material.outPoint, sourceTime + 2.5 * material.playbackSpeed)
        if state.addInsert(project.id, material.id, assetID: media.id, start: sourceTime, end: end) {
            selectedMaterial = material.id
            state.showToast("已插入「\(media.name)」")
        } else {
            state.showToast("当前位置无法插入，可能与已有补充画面重叠。")
        }
    }

    private func importReferenceMedia(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            var count = 0
            for url in urls {
                if let media = try? await ReferenceMediaImport.copy(url, into: project),
                   state.updateProject(project.id, { $0.referenceMedia.append(media) }) {
                    count += 1
                }
            }
            if count > 0 { state.showToast("已导入 \(count) 项素材") }
        }
    }

    // MARK: - Right Panel (Fixed-width 3-tab inspector)

    private var rightPanel: some View {
        VStack(spacing: 0) {
            StudioChoice(
                title: "右侧面板",
                selection: $sideTab,
                options: [(.ai, "AI 剪辑"), (.subtitles, "字幕"), (.properties, "属性")]
            )
            .padding(Metrics.space2)
            Divider()
            switch sideTab {
            case .ai:
                AssemblyChatPanel(
                    project: project,
                    agent: chatAgent,
                    focusContext: editorFocusContext
                )
            case .subtitles:
                subtitlesInspector
            case .properties:
                propertiesInspector
            }
        }
        .background(palette.bgBase)
    }

    private var editorFocusContext: String {
        var parts = ["播放头 \(AssemblyTimelineLayout.timecode(playhead))"]
        if let material = activeOrSelectedMaterial,
           let index = project.materials.firstIndex(where: { $0.id == material.id }) {
            parts.append("选中「\(material.displayTitle(index: index))」(素材\(index + 1))")
        }
        if let sel = selectedSubtitle.flatMap(SubtitleKey.parse) {
            parts.append("字幕第 \(sel.index + 1) 条")
        }
        return parts.joined(separator: " · ")
    }

    private var activeOrSelectedMaterial: Material? {
        if let selectedMaterial, let found = project.materials.first(where: { $0.id == selectedMaterial }) {
            return found
        }
        return materialAtPlayhead()?.material ?? project.materials.first
    }

    // MARK: - Properties Tab

    private var propertiesInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.space4) {
                if let sel = selectedInsert,
                   let material = project.materials.first(where: { $0.id == sel.materialID }),
                   let inserts = material.inserts, inserts.indices.contains(sel.index) {
                    let insert = inserts[sel.index]
                    let assetName = project.referenceMedia.first(where: { $0.id == insert.assetID })?.name ?? "补充画面"
                    VStack(alignment: .leading, spacing: Metrics.space3) {
                        HStack {
                            Label("补充画面", systemImage: "photo").font(.studio(.smallStrong))
                            Spacer()
                            Button("删除", role: .destructive) {
                                if state.removeInsert(project.id, material.id, index: sel.index) {
                                    selectedInsert = nil
                                }
                            }
                            .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                        }
                        Text(assetName).font(.studio(.bodyMedium))
                        Text("原片区间：\(durationLabel(insert.start)) – \(durationLabel(insert.end))")
                            .font(.studio(.small)).foregroundStyle(palette.textSecondary)
                        Button("定位到插图开头") {
                            seek(globalStart(material, insert.start))
                        }
                        .buttonStyle(StudioButtonStyle(kind: .secondary, size: .compact))
                    }
                    Divider()
                }

                if let material = activeOrSelectedMaterial,
                   let index = project.materials.firstIndex(where: { $0.id == material.id }) {
                    HStack {
                        Text("片段设置").font(.studio(.smallStrong))
                        Spacer()
                        Menu { MaterialProcessingActions(projectID: project.id, materialID: material.id) } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(StudioMenuStyle()).fixedSize().accessibilityLabel("素材处理操作")
                    }

                    VStack(alignment: .leading, spacing: Metrics.space1_5) {
                        Text("片段名称").font(.studio(.caption)).foregroundStyle(palette.textSecondary)
                        TextField("素材 \(index + 1)", text: Binding(
                            get: { state.projects.first(where: { $0.id == project.id })?.materials.first(where: { $0.id == material.id })?.title ?? "" },
                            set: { state.renameMaterial(project.id, material.id, title: $0) }
                        ))
                        .textFieldStyle(StudioTextFieldStyle())
                    }

                    VStack(alignment: .leading, spacing: Metrics.space1_5) {
                        HStack {
                            Text("片段倍速").font(.studio(.caption)).foregroundStyle(palette.textSecondary)
                            Spacer()
                            Text(String(format: "%.2gx", material.playbackSpeed))
                                .font(.studio(.timecode)).foregroundStyle(palette.textPrimary)
                        }
                        StudioChoice(
                            title: "片段倍速",
                            selection: Binding(
                                get: { material.playbackSpeed },
                                set: { state.setMaterialSpeed(project.id, material.id, speed: $0) }
                            ),
                            options: [(0.75, "0.75x"), (1.0, "1x"), (1.25, "1.25x"), (1.5, "1.5x"), (2.0, "2x")]
                        )
                    }

                    if material.wantsMotion {
                        VStack(alignment: .leading, spacing: Metrics.space1_5) {
                            Text("画面版本").font(.studio(.caption)).foregroundStyle(palette.textSecondary)
                            StudioChoice(title: "画面版本", selection: Binding(
                                get: { material.useOriginal ?? false },
                                set: { state.setUseOriginal(project.id, material.id, $0) }),
                                options: [(true, "原片"), (false, material.motionState == .complete ? "动效" : "动效处理中")])
                            if material.motionState != .complete {
                                Text(material.motionError
                                    ?? state.motionPhases[material.mediaID]
                                    ?? material.motionLabel ?? "使用原片预览")
                                    .font(.studio(.small)).foregroundStyle(palette.textSecondary)
                            }
                        }
                    }

                    let inserts = material.inserts ?? []
                    if !inserts.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: Metrics.space2) {
                            Text("本段补充画面（\(inserts.count)）").font(.studio(.caption)).foregroundStyle(palette.textSecondary)
                            ForEach(Array(inserts.enumerated()), id: \.offset) { idx, insert in
                                let name = project.referenceMedia.first(where: { $0.id == insert.assetID })?.name ?? "补充画面"
                                HStack(spacing: Metrics.space2) {
                                    Button {
                                        selectedInsert = InsertSelection(materialID: material.id, index: idx)
                                        seek(globalStart(material, insert.start))
                                    } label: {
                                        HStack {
                                            Text(name).font(.studio(.small)).lineLimit(1)
                                            Spacer()
                                            Text(durationLabel(globalStart(material, insert.start)))
                                                .font(.studio(.timecode)).foregroundStyle(palette.textMuted)
                                        }
                                    }
                                    .buttonStyle(StudioContentButtonStyle())
                                    Button {
                                        _ = state.removeInsert(project.id, material.id, index: idx)
                                        if selectedInsert == InsertSelection(materialID: material.id, index: idx) {
                                            selectedInsert = nil
                                        }
                                    } label: { Image(systemName: "trash") }
                                    .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                                }
                            }
                        }
                    }
                } else {
                    Text("在时间线上点选任意片段或补充画面即可查看和调整属性。")
                        .font(.studio(.small)).foregroundStyle(palette.textSecondary)
                }
            }
            .padding(Metrics.space3)
        }
    }

    // MARK: - Subtitles Tab (Reading mode + click-to-edit + live highlight)

    private var subtitlesInspector: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.space3) {
                    HStack(spacing: Metrics.space1_5) {
                        Text("字幕列表").font(.studio(.smallStrong))
                        Spacer()
                        Menu {
                            Button("AI 复核并重组断句") { state.reviewSubtitles(project.id) }
                                .disabled(state.reviewingProjects.contains(project.id) || !hasReviewableSubtitles)
                            Button("AI 逐句校正文字（保留时间）") {
                                for material in project.materials { state.correctSubtitles(project.id, material.id) }
                            }
                            .disabled(project.materials.contains { $0.transcriptState == .running }
                                || !project.materials.contains { $0.transcriptState == .complete && !$0.subtitles.isEmpty })
                        } label: {
                            Label(state.reviewingProjects.contains(project.id) ? "校对中" : "AI 校对", systemImage: "sparkles")
                                .font(.studio(.small, weight: .medium))
                        }
                        .menuStyle(StudioMenuStyle())
                        .fixedSize()
                        .accessibilityIdentifier("assembly.subtitles.review")
                    }

                    SubtitleReviewPanel(project: project,
                                        onSelect: { materialID, index in selectSubtitle(materialID, index) },
                                        onDelete: { materialID, index in deleteSubtitle(materialID, index) })

                    let severities = reviewSeverities
                    let currentPlayingKey = activeSubtitleKey
                    ForEach(Array(project.materials.enumerated()), id: \.element.id) { number, material in
                        if project.materials.count > 1 {
                            Text(material.displayTitle(index: number))
                                .font(.studio(.caption, weight: .medium))
                                .foregroundStyle(palette.textMuted)
                                .padding(.top, Metrics.space1)
                        }
                        if let warning = material.transcriptWarning {
                            Text(warning).font(.studio(.small)).foregroundStyle(palette.warning)
                        }
                        if material.transcriptState == .running || material.transcriptState != .complete {
                            MaterialTaskStatus(projectID: project.id, material: material)
                        }
                        ForEach(Array(material.subtitles.enumerated()).filter { $0.element.end > material.inPoint && $0.element.start < material.outPoint }, id: \.offset) { index, subtitle in
                            let key = SubtitleKey.make(material.id, index)
                            let isSelected = selectedSubtitle == key
                            let isPlayingHere = currentPlayingKey == key
                            VStack(alignment: .leading, spacing: Metrics.space1_5) {
                                HStack(spacing: Metrics.space1_5) {
                                    if let severity = severities[key] {
                                        Circle().fill(severityColor(severity)).frame(width: 5, height: 5)
                                            .accessibilityLabel("复核：\(severityLabel(severity))")
                                    }
                                    Button {
                                        selectSubtitle(material.id, index)
                                    } label: {
                                        Text(durationLabel(globalStart(material, subtitle.start)))
                                            .font(.studio(.timecode))
                                            .foregroundStyle(isPlayingHere ? palette.accent : palette.textMuted)
                                    }
                                    .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                                    Spacer(minLength: 0)
                                    if isSelected {
                                        Menu {
                                            Button("在播放头处分割字幕") { splitSubtitle(material, index: index) }
                                                .disabled(!canSplitSubtitle(material, index: index))
                                            Button("与下一条合并") { _ = state.mergeSubtitle(project.id, material.id, index: index) }
                                                .disabled(!canMergeSubtitle(material, index: index))
                                            Divider()
                                            Button("删除字幕", role: .destructive) { deleteSubtitle(material, index: index) }
                                        } label: { Image(systemName: "ellipsis") }
                                        .menuStyle(StudioMenuStyle()).fixedSize().accessibilityLabel("字幕操作")
                                    }
                                }
                                if isSelected || focusedSubtitle == key {
                                    TextField("字幕", text: Binding(
                                        get: { state.projects.first(where: { $0.id == project.id })?.materials.first(where: { $0.id == material.id })?.subtitles[safe: index]?.text ?? subtitle.text },
                                        set: { state.editSubtitle(projectID: project.id, materialID: material.id, index: index, text: $0) }
                                    ), axis: .vertical)
                                    .textFieldStyle(StudioTextFieldStyle())
                                    .lineLimit(1...4)
                                    .disabled(material.transcriptState == .running)
                                    .focused($focusedSubtitle, equals: key)
                                } else {
                                    Button {
                                        selectSubtitle(material.id, index)
                                        focusSubtitle = key
                                    } label: {
                                        Text(subtitle.text.isEmpty ? "（空字幕）" : subtitle.text)
                                            .font(.studio(.body))
                                            .foregroundStyle(isPlayingHere ? palette.textPrimary : palette.textSecondary)
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(StudioContentButtonStyle())
                                }
                            }
                            .padding(Metrics.space2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                isSelected ? palette.surface1
                                : (isPlayingHere ? palette.accent.opacity(Metrics.opacitySelected) : .clear),
                                in: RoundedRectangle(cornerRadius: Metrics.radiusS)
                            )
                            .contextMenu {
                                Button("在播放头处分割字幕") { splitSubtitle(material, index: index) }
                                    .disabled(!canSplitSubtitle(material, index: index))
                                Button("与下一条合并") { _ = state.mergeSubtitle(project.id, material.id, index: index) }
                                    .disabled(!canMergeSubtitle(material, index: index))
                                Divider()
                                Button("删除字幕", role: .destructive) { deleteSubtitle(material, index: index) }
                            }
                            .id(key)
                        }
                        if material.transcriptState == .complete && material.subtitles.isEmpty {
                            Text("未检测到语音").font(.studio(.small)).foregroundStyle(palette.textSecondary)
                        }
                    }
                }
                .padding(Metrics.space3)
            }
            .onChange(of: selectedSubtitle) { _, value in
                if let value { proxy.scrollTo(value, anchor: .center) }
            }
            .onChange(of: activeSubtitleKey) { _, value in
                if isPlaying, let value, focusedSubtitle == nil {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(value, anchor: .center) }
                }
            }
        }
    }

    // MARK: - Subtitle & Playback Helpers

    private var reviewSeverities: [String: SubtitleReviewIssue.Severity] {
        var result: [String: SubtitleReviewIssue.Severity] = [:]
        for item in state.resolvedSubtitleIssues(project.id) {
            let key = SubtitleKey.make(item.materialID, item.index)
            if let existing = result[key], existing >= item.issue.severity { continue }
            result[key] = item.issue.severity
        }
        return result
    }

    private var hasReviewableSubtitles: Bool {
        project.materials.contains { $0.transcriptState != .running && !$0.subtitles.isEmpty }
    }

    private func severityColor(_ severity: SubtitleReviewIssue.Severity) -> Color {
        switch severity {
        case .error: return palette.danger
        case .warning: return palette.warning
        case .note: return palette.textMuted
        }
    }

    private func severityLabel(_ severity: SubtitleReviewIssue.Severity) -> String {
        switch severity {
        case .error: return "错误"
        case .warning: return "待确认"
        case .note: return "提示"
        }
    }

    private func selectSubtitle(_ materialID: UUID, _ index: Int) {
        guard let material = project.materials.first(where: { $0.id == materialID }),
              material.subtitles.indices.contains(index) else { return }
        selectedMaterial = materialID
        selectedSubtitle = SubtitleKey.make(materialID, index)
        selectedInsert = nil
        seek(globalStart(material, material.subtitles[index].start))
    }

    private func materialAtPlayhead() -> (material: Material, sourceTime: Double)? {
        let layout = AssemblyTimelineLayout(materials: project.materials)
        guard let clip = layout.clip(at: playhead) else { return nil }
        let material = project.materials[clip.index]
        return (material, material.inPoint + (playhead - clip.start) * material.playbackSpeed)
    }

    private func sourceTime(of material: Material) -> Double? {
        let layout = AssemblyTimelineLayout(materials: project.materials)
        guard let clip = layout.clip(at: playhead), clip.id == material.id else { return nil }
        return material.inPoint + (playhead - clip.start) * material.playbackSpeed
    }

    private func canSplitSubtitle(_ material: Material, index: Int) -> Bool {
        guard material.transcriptState != .running, material.subtitles.indices.contains(index),
              let time = sourceTime(of: material) else { return false }
        let subtitle = material.subtitles[index]
        return subtitle.end > material.inPoint && subtitle.start < material.outPoint
            && time - subtitle.start >= TimelineRangeEdit.frame - 0.000_001
            && subtitle.end - time >= TimelineRangeEdit.frame - 0.000_001
    }

    private func splitSubtitle(_ material: Material, index: Int) {
        guard let time = sourceTime(of: material) else { return }
        guard state.splitSubtitle(project.id, material.id, index: index, at: time) else {
            state.showToast("这条字幕无法按时间切分，先调整文字或时间。")
            return
        }
        selectedSubtitle = SubtitleKey.make(material.id, index)
    }

    private func canMergeSubtitle(_ material: Material, index: Int) -> Bool {
        guard material.transcriptState != .running, index + 1 < material.subtitles.count else { return false }
        let next = material.subtitles[index + 1]
        return next.end > material.inPoint && next.start < material.outPoint
    }

    private func deleteSubtitle(_ materialID: UUID, _ index: Int) {
        guard let material = project.materials.first(where: { $0.id == materialID }) else { return }
        deleteSubtitle(material, index: index)
    }

    private func deleteSubtitle(_ material: Material, index: Int) {
        guard state.deleteSubtitle(project.id, material.id, index: index) else { return }
        if let selection = selectedSubtitle.flatMap(SubtitleKey.parse), selection.materialID == material.id {
            selectedSubtitle = nil
        }
    }

    private func remember(flush: Bool = false) {
        guard restored else { return }
        var session = state.editorSession(project.id)
        session.playhead = playhead
        session.zoom = zoom
        session.previewHeight = previewFraction
        session.selectedMaterial = selectedMaterial
        session.selectedSubtitle = selectedSubtitle
        state.rememberEditor(project.id, session, flush: flush)
    }

    private func seek(_ time: Double) {
        let duration = AssemblyTimelineLayout(materials: project.materials).duration
        let target = min(duration, max(0, time.isFinite ? time : 0))
        player.pause(); isPlaying = false; playhead = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func togglePlayback() {
        if player.rate > 0 { player.pause(); isPlaying = false }
        else {
            if playhead >= AssemblyTimelineLayout(materials: project.materials).duration - 0.05 { seek(0) }
            player.rate = Float(previewRate); isPlaying = true
        }
    }

    private func globalStart(_ material: Material, _ start: Double) -> Double {
        AssemblyTimelineLayout.globalStart(materialID: material.id, in: project.materials, sourceTime: start)
    }

    private func schedulePreview() {
        guard restored else { return }
        rebuildTask?.cancel()
        rebuildTask = Task {
            do { try await Task.sleep(for: .milliseconds(180)); try Task.checkCancellation() } catch { return }
            await preparePreview()
        }
    }

    private func preparePreview() async {
        let wasPlaying = isPlaying
        let savedPlayhead = playhead
        previewError = nil
        guard !project.materials.isEmpty, project.materials.allSatisfy(\.isReady) else {
            stopPreview()
            previewError = "素材导出未完成，请返回录制页查看或移除失败素材。"
            return
        }
        loading = true
        defer { loading = false }
        do {
            // Stored inserts belong to the picture, so preview renders them;
            // captions render live in SwiftUI overlay for zero-flicker editing.
            let library = Dictionary(uniqueKeysWithValues: project.referenceMedia.map { ($0.id, $0) })
            let inserts = project.materials.flatMap { material in
                AIEditing.validatedInserts(material.inserts ?? [], clipID: material.id,
                                           clipStart: material.inPoint, clipEnd: material.outPoint, library: library)
            }
            let assembly = try await ExportService.assemble(project: project, includeSubtitles: false, inserts: inserts)
            try Task.checkCancellation()
            let item = AVPlayerItem(asset: assembly.composition)
            item.videoComposition = assembly.videoComposition
            if let observer { player.removeTimeObserver(observer); self.observer = nil }
            player.replaceCurrentItem(with: item)
            let duration = AssemblyTimelineLayout(materials: project.materials).duration
            let clamped = min(duration, max(0, savedPlayhead.isFinite ? savedPlayhead : 0))
            playhead = clamped
            await player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.rate = Float(previewRate); isPlaying = true }
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { time in
                Task { @MainActor in
                    playhead = time.seconds.isFinite ? time.seconds : 0
                    isPlaying = player.rate > 0
                }
            }
        } catch is CancellationError { }
        catch { previewError = error.localizedDescription }
    }

    private func stopPreview() {
        player.pause(); isPlaying = false
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        player.replaceCurrentItem(with: nil)
    }
}

struct AssemblyPreviewInputs: Equatable {
    struct ClipSignature: Equatable {
        let id: UUID
        let mediaID: UUID
        let exportState: JobState
        let motionState: JobState
        let useOriginal: Bool?
        let inPoint: Double
        let outPoint: Double
        let playbackSpeed: Double
        let inserts: [AIEditing.Insert]?
    }
    let clips: [ClipSignature]
    let width: Double?
    let height: Double?
    init(project: VideoProject) {
        clips = project.materials.map {
            ClipSignature(
                id: $0.id,
                mediaID: $0.mediaID,
                exportState: $0.exportState,
                motionState: $0.motionState,
                useOriginal: $0.useOriginal,
                inPoint: $0.inPoint,
                outPoint: $0.outPoint,
                playbackSpeed: $0.playbackSpeed,
                inserts: $0.inserts
            )
        }
        width = project.canvasWidth
        height = project.canvasHeight
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
