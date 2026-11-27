import AVKit
import RecorderKit
import SwiftUI
import UniformTypeIdentifiers

struct AssemblyView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    let project: VideoProject
    @Binding var showsAIPanel: Bool
    var onOpenLibrary: () -> Void = {}
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
    @State private var previewFraction = 0.64
    @State private var dragOrigin: Double?
    @State private var restored = false
    @State private var rebuildTask: Task<Void, Never>?
    @State private var showsSubtitlesPreview = true
    @State private var showsSubtitlesSheet = false
    @State private var previewRate = 1.0
    @State private var importingMedia = false
    @State private var editingSurface: EditingSurface = .clipStudio
    @State private var showsMotionPromptPopover = false
    @State private var draftMotionPrompt = ""

    private enum EditingSurface: Equatable {
        case clipStudio
        case multiClipAssembly
    }

    private var activeSelectedMaterial: (index: Int, material: Material, timelineStart: Double)? {
        var offset = 0.0
        for (idx, m) in project.materials.enumerated() {
            if m.id == selectedMaterial {
                return (idx, m, offset)
            }
            offset += m.timelineDuration
        }
        if let idx = project.materials.firstIndex(where: { $0.sourceReady }) {
            let prior = project.materials.prefix(idx).reduce(0.0) { $0 + $1.timelineDuration }
            return (idx, project.materials[idx], prior)
        }
        return nil
    }

    private var chatAgent: AssemblyAgent { state.assemblyAgent(for: project.id) }

    // Video composition only rebuilds when picture/timing/inserts/canvas change;
    // subtitle text and timing update live on the overlay with zero black-screen flicker.
    private var previewKey: AssemblyPreviewInputs { AssemblyPreviewInputs(project: project) }

    var body: some View {
        Group {
            if project.materials.isEmpty {
                StudioWorkspace(title: "还没有素材", detail: "录制后即可预览、拼装并让 AI 协助剪辑。") {
                    StudioPreview(symbol: "film.stack", title: "等待录制素材")
                } controls: {
                    Button("录制新素材", systemImage: "record.circle") { state.record() }
                        .buttonStyle(StudioButtonStyle(kind: .primary))
                }
            } else {
                HStack(spacing: Metrics.space3) {
                    VStack(spacing: Metrics.space2) {
                        editingHeaderStrip
                        Group {
                            if editingSurface == .clipStudio, let active = activeSelectedMaterial {
                                EmbeddedRoughCutEditorView(
                                    materialID: active.material.id,
                                    packageURL: ProjectLayout.roughCutPackage(active.material, in: project),
                                    fallbackSourceURL: ProjectLayout.source(active.material, in: project),
                                    title: active.material.displayTitle(index: active.index),
                                    motionLayer: AppState.buildRoughCutMotionLayer(for: active.material, in: project),
                                    onDidSave: {
                                        state.bumpRoughCutRevision(project.id, active.material.id)
                                    }
                                )
                                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusIsland, style: .continuous))
                                .studioIsland(cornerRadius: Metrics.radiusIsland)
                            } else {
                                multiClipAssemblyWorkspace
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Right: Collapsible Floating AI Director Island
                    if showsAIPanel {
                        AssemblyChatPanel(
                            project: project,
                            agent: chatAgent,
                            focusContext: editorFocusContext,
                            onPlayPreview: { focusTime in
                                editingSurface = .multiClipAssembly
                                playFrom(focusTime)
                            },
                            onImportMedia: { importingMedia = true },
                            onOpenLibrary: onOpenLibrary,
                            onClose: {
                                withAnimation(StudioMotion.settle) {
                                    showsAIPanel = false
                                }
                            }
                        )
                        .frame(width: Metrics.chatPanel)
                        .frame(maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusIsland, style: .continuous))
                        .studioIsland(cornerRadius: Metrics.radiusIsland)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
        }
        .background(palette.stage)
        .sheet(isPresented: $showsSubtitlesSheet) {
            subtitlesSheet
        }
        .fileImporter(isPresented: $importingMedia, allowedContentTypes: [.image, .movie, .audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importReferenceMedia(urls) }
        }
        .onAppear {
            let session = state.editorSession(project.id)
            playhead = session.playhead.isFinite ? max(0, session.playhead) : 0
            zoom = min(64, max(0.5, session.zoom))
            previewFraction = min(0.80, max(0.28, session.previewHeight))
            selectedMaterial = session.selectedMaterial ?? project.materials.first(where: { $0.sourceReady })?.id
            selectedSubtitle = session.selectedSubtitle
            restored = true
            if editingSurface == .multiClipAssembly {
                schedulePreview()
            }
            Task { await state.lockCanvas(project.id) }
        }
        .onChange(of: editingSurface) { _, next in
            if next == .multiClipAssembly {
                schedulePreview()
            } else {
                stopPreview()
            }
        }
        .onChange(of: previewKey) { _, _ in
            if editingSurface == .multiClipAssembly {
                schedulePreview()
            }
        }
        .onChange(of: playhead) { _, _ in remember() }
        .onChange(of: zoom) { _, _ in remember(flush: true) }
        .onChange(of: selectedSubtitle) { _, _ in remember(flush: true) }
        .onChange(of: previewRate) { _, rate in
            if isPlaying { player.rate = Float(rate) }
        }
        .onChange(of: focusSubtitle) { _, key in
            guard let key else { return }
            focusSubtitle = nil
            showsSubtitlesSheet = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(160))
                focusedSubtitle = key
            }
        }
        .onChange(of: selectedMaterial) { _, _ in
            remember(flush: true)
        }
        .onChange(of: project.materials.map(\.id)) { _, ids in
            if let selectedMaterial, !ids.contains(selectedMaterial) {
                self.selectedMaterial = project.materials.first(where: { $0.sourceReady })?.id
                selectedSubtitle = nil
                selectedInsert = nil
            }
        }
        .onDisappear { remember(flush: true); restored = false; rebuildTask?.cancel(); stopPreview() }
    }

    // MARK: - Unified Editing Header Strip

    private var editingHeaderStrip: some View {
        HStack(spacing: Metrics.space2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metrics.space1_5) {
                    ForEach(Array(project.materials.enumerated()), id: \.element.id) { idx, material in
                        let isSelected = activeSelectedMaterial?.material.id == material.id
                        Button {
                            selectedMaterial = material.id
                            editingSurface = .clipStudio
                        } label: {
                            HStack(spacing: 5) {
                                Text(String(format: "%02d", idx + 1))
                                    .font(.studio(.micro, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(isSelected ? palette.onAccent.opacity(0.85) : palette.textSecondary)
                                Text(material.displayTitle(index: idx))
                                    .lineLimit(1)
                                if material.wantsMotion && material.useOriginal != true && material.motionState == .complete {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(isSelected ? palette.onAccent : palette.ai)
                                }
                            }
                        }
                        .buttonStyle(StudioButtonStyle(kind: isSelected && editingSurface == .clipStudio ? .primary : .secondary, size: .compact))
                        .disabled(!material.sourceReady)
                    }
                }
            }

            if let active = activeSelectedMaterial {
                let material = active.material
                let isAIMotionOn: Bool = {
                    if material.motionState == .complete {
                        return material.wantsMotion && material.useOriginal != true
                    }
                    return material.wantsMotion && [.queued, .running].contains(material.motionState)
                }()
                let isBusy = [.queued, .running].contains(material.motionState)
                    || state.motionPhases[material.mediaID] != nil

                Divider().frame(height: 18).overlay(palette.hairline)

                HStack(spacing: Metrics.space1_5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isAIMotionOn ? palette.ai : palette.textSecondary)
                    Text("AI 动效")
                        .font(.studio(.caption))
                        .foregroundStyle(palette.textPrimary)
                    if isBusy {
                        ProgressView().controlSize(.mini)
                    }
                    Toggle("AI 动效", isOn: Binding(
                        get: { isAIMotionOn },
                        set: { enabled in
                            if enabled && material.motionState != .complete {
                                draftMotionPrompt = material.editingPrompt ?? ""
                                showsMotionPromptPopover = true
                            } else {
                                state.toggleMaterialAIMotion(project.id, material.id, enabled: enabled)
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(StudioToggleStyle())
                    .disabled(project.isFrozen == true || !material.sourceReady)
                    .popover(isPresented: $showsMotionPromptPopover, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: Metrics.space2_5) {
                            Text("为当前片段生成 AI 动效")
                                .font(.studio(.smallStrong))
                                .foregroundStyle(palette.textPrimary)
                            TextField("可选提示词：例如讲到重点时加入关键数据卡片", text: $draftMotionPrompt, axis: .vertical)
                                .textFieldStyle(StudioTextFieldStyle())
                                .lineLimit(2...4)
                            HStack {
                                Button("取消") { showsMotionPromptPopover = false }
                                    .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                                Spacer()
                                Button("开始生成", systemImage: "sparkles") {
                                    showsMotionPromptPopover = false
                                    state.toggleMaterialAIMotion(
                                        project.id,
                                        material.id,
                                        enabled: true,
                                        prompt: draftMotionPrompt
                                    )
                                }
                                .buttonStyle(StudioButtonStyle(kind: .primary, size: .compact))
                            }
                        }
                        .padding(Metrics.space3)
                        .frame(width: 300)
                        .background(palette.island)
                    }
                }
                .padding(.horizontal, Metrics.space2)
                .padding(.vertical, 3)
                .background(palette.surface2, in: Capsule())

                Button("字幕", systemImage: "captions.bubble") {
                    showsSubtitlesSheet = true
                }
                .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                .help("编辑与复核项目字幕")

                if project.materials.count > 1, editingSurface == .clipStudio {
                    Button("样式同步全部", systemImage: "square.on.square") {
                        state.applyRoughCutStyleToAll(project.id, from: material.id)
                    }
                    .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                    .help("将当前片段的画面背景与光标样式同步到项目全部片段")
                }
            }

            Divider().frame(height: 18).overlay(palette.hairline)

            HStack(spacing: 2) {
                Button("单段编辑") { editingSurface = .clipStudio }
                    .buttonStyle(StudioButtonStyle(kind: editingSurface == .clipStudio ? .primary : .quiet, size: .compact))
                Button("多段拼装") { editingSurface = .multiClipAssembly }
                    .buttonStyle(StudioButtonStyle(kind: editingSurface == .multiClipAssembly ? .primary : .quiet, size: .compact))
            }
        }
        .padding(.horizontal, Metrics.space2_5)
        .padding(.vertical, Metrics.space1_5)
        .studioIsland(cornerRadius: Metrics.radiusIsland)
    }

    private var multiClipAssemblyWorkspace: some View {
        GeometryReader { geometry in
            let minTimeline: CGFloat = 236
            let previewHeight = min(max(240, geometry.size.height * previewFraction),
                                    max(240, geometry.size.height - minTimeline - 12))
            VStack(spacing: 0) {
                VStack(spacing: Metrics.space2_5) {
                    previewStage
                    floatingTransportPill
                }
                .padding(.top, Metrics.space1)
                .frame(height: previewHeight)

                Rectangle().fill(Color.clear).frame(height: 12)
                    .overlay {
                        Capsule()
                            .fill(palette.surface3)
                            .frame(width: 36, height: 3)
                    }
                    .contentShape(Rectangle())
                    .onHover { ($0 ? NSCursor.resizeUpDown : NSCursor.arrow).set() }
                    .gesture(DragGesture().onChanged { value in
                        if dragOrigin == nil { dragOrigin = previewHeight }
                        previewFraction = min(0.80, max(0.32, ((dragOrigin ?? previewHeight) + value.translation.height) / max(1, geometry.size.height)))
                    }.onEnded { _ in dragOrigin = nil; remember(flush: true) })
                    .accessibilityLabel("预览区域高度")
                    .accessibilityAdjustableAction { direction in
                        previewFraction = min(0.80, max(0.32, previewFraction + (direction == .increment ? 0.05 : -0.05)))
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
                    showsSubtitlesPreview: $showsSubtitlesPreview,
                    previewRate: $previewRate,
                    editingCaption: focusedSubtitle != nil || showsSubtitlesSheet,
                    onSeek: seek,
                    onPlay: togglePlayback,
                    onMove: { state.reorderMaterial(project.id, source: $0, target: $1, after: $2) },
                    onOpenSubtitles: { showsSubtitlesSheet = true },
                    zoom: $zoom
                )
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusIsland, style: .continuous))
                .studioIsland(cornerRadius: Metrics.radiusIsland)
            }
        }
    }

    // MARK: - Preview Stage

    private var canvasAspect: CGFloat {
        if let w = project.canvasWidth, let h = project.canvasHeight, w > 0, h > 0 {
            return CGFloat(w / h)
        }
        return 16.0 / 9.0
    }

    private var previewStage: some View {
        ZStack {
            RadialGradient(
                colors: [palette.stageLight, .clear],
                center: .center,
                startRadius: 20,
                endRadius: 420
            )
            ZStack {
                VideoSurface(player: player, controlsStyle: .none)
                ForEach(activeHTMLMotions) { item in
                    HTMLMotionPreviewLayer(
                        url: ProjectLayout.htmlMotion(item, in: project),
                        revision: item.revision,
                        localTime: max(0, playhead - item.start),
                        duration: max(0.05, item.end - item.start)
                    )
                    .allowsHitTesting(false)
                }
                if showsSubtitlesPreview, let caption = activeSubtitleText {
                    VStack {
                        Spacer()
                        Text(caption)
                            .font(.studio(.bodyLargeMedium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Metrics.space3)
                            .padding(.vertical, Metrics.space1_5)
                            .background(Color.black.opacity(0.76), in: RoundedRectangle(cornerRadius: Metrics.radiusS, style: .continuous))
                            .padding(.horizontal, Metrics.space4)
                            .padding(.bottom, Metrics.space4)
                    }
                    .allowsHitTesting(false)
                }
                // Explicit top tap-capture layer so AVPlayerView never swallows clicks.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if player.currentItem != nil { togglePlayback() }
                    }
            }
            .background(palette.mediaGround)
            .aspectRatio(canvasAspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusL, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.radiusL, style: .continuous)
                    .strokeBorder(palette.islandOutline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: palette.shadowSoft, radius: 22, y: 10)
            .padding(.horizontal, Metrics.space3)

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
                    Text(previewError)
                        .font(.studio(.small))
                        .foregroundStyle(palette.textPrimary)
                        .multilineTextAlignment(.center)
                    Button("重试预览") { schedulePreview() }
                        .buttonStyle(StudioButtonStyle(kind: .primary, size: .compact))
                }
                .padding(Metrics.space5)
                .frame(maxWidth: 360)
                .studioIsland(cornerRadius: Metrics.radiusL)
                .padding(Metrics.space4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canvasRatioLabel: String {
        guard let w = project.canvasWidth, let h = project.canvasHeight else { return "跟随" }
        if Int(w) == 1920 && Int(h) == 1080 { return "16:9" }
        if Int(w) == 1080 && Int(h) == 1920 { return "9:16" }
        if Int(w) == 1080 && Int(h) == 1080 { return "1:1" }
        return "\(Int(w))×\(Int(h))"
    }

    private var totalTimelineDuration: Double {
        AssemblyTimelineLayout(materials: project.materials).duration
    }

    /// DogSC-style floating transport capsule beneath the video monitor.
    private var floatingTransportPill: some View {
        HStack(spacing: Metrics.space2) {
            Menu {
                Button("横屏 16:9（1920 × 1080）") { state.setCanvas(project.id, width: 1920, height: 1080) }
                Button("竖屏 9:16（1080 × 1920）") { state.setCanvas(project.id, width: 1080, height: 1920) }
                Button("方形 1:1（1080 × 1080）") { state.setCanvas(project.id, width: 1080, height: 1080) }
                Divider()
                Button("跟随素材") { state.setCanvas(project.id, width: nil, height: nil) }
            } label: {
                Text(canvasRatioLabel)
                    .font(.studio(.caption, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
            }
            .menuStyle(StudioMenuStyle(surface: .pill, compact: true))
            .fixedSize()
            .disabled(project.isFrozen)
            .help("切换成片画幅")
            .accessibilityLabel("成片画幅：\(canvasRatioLabel)")

            Button {
                showsSubtitlesPreview.toggle()
            } label: {
                Text(showsSubtitlesPreview ? "字幕 开" : "字幕 关")
                    .font(.studio(.caption, weight: .medium))
                    .foregroundStyle(showsSubtitlesPreview ? palette.textPrimary : palette.textMuted)
                    .padding(.horizontal, Metrics.space2)
                    .frame(height: 24)
                    .background(showsSubtitlesPreview ? palette.selectionWash : palette.controlWell, in: Capsule())
            }
            .buttonStyle(StudioContentButtonStyle(cornerRadius: 999))
            .help("切换预览字幕显示")

            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button(String(format: "%.2g×", rate)) { previewRate = rate }
                }
            } label: {
                Text(String(format: "%.2g×", previewRate))
                    .font(.studio(.caption, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(palette.textSecondary)
            }
            .menuStyle(StudioMenuStyle(surface: .pill, compact: true))
            .fixedSize()
            .help("预览播放倍速")
            .accessibilityLabel("预览倍速：\(String(format: "%.2g×", previewRate))")

            Rectangle()
                .fill(palette.hairline)
                .frame(width: 1, height: 14)

            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.studio(.caption, weight: .bold))
                    .foregroundStyle(palette.onAccent)
                    .frame(width: 26, height: 26)
                    .background(palette.accent, in: Circle())
            }
            .buttonStyle(StudioContentButtonStyle(cornerRadius: 999))
            .disabled(player.currentItem == nil)
            .accessibilityLabel(isPlaying ? "暂停预览" : "播放预览")

            HStack(spacing: Metrics.space1) {
                Text(AssemblyTimelineLayout.timecode(playhead))
                    .foregroundStyle(palette.textPrimary)
                Text("/")
                    .foregroundStyle(palette.textMuted)
                Text(AssemblyTimelineLayout.timecode(totalTimelineDuration))
                    .foregroundStyle(palette.textMuted)
            }
            .font(.studio(.timecode, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, Metrics.space1)
        }
        .padding(.horizontal, Metrics.space3)
        .frame(height: 38)
        .studioIsland(cornerRadius: 999)
    }

    private var activeHTMLMotions: [HTMLMotionOverlay] {
        (project.htmlMotions ?? []).filter { playhead >= $0.start && playhead < $0.end }
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

    // MARK: - Lightweight Subtitles Sheet

    private var subtitlesSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.space2) {
                Text("全片字幕").font(.studio(.subhead))
                Spacer()
                Button {
                    showsSubtitlesPreview.toggle()
                } label: {
                    Label(showsSubtitlesPreview ? "预览显示中" : "预览已隐藏",
                          systemImage: showsSubtitlesPreview ? "eye" : "eye.slash")
                }
                .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
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
                Button { showsSubtitlesSheet = false } label: { Text(verbatim: "完成") }
                    .buttonStyle(StudioButtonStyle(kind: .primary, size: .compact))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Metrics.space5)
            .frame(height: Metrics.header)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.space3) {
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
                                HStack(alignment: .top, spacing: Metrics.space3) {
                                    HStack(spacing: Metrics.space1) {
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
                                    }
                                    .frame(width: 66, alignment: .leading)

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
                                            focusedSubtitle = key
                                        } label: {
                                            Text(subtitle.text.isEmpty ? "（空字幕）" : subtitle.text)
                                                .font(.studio(.body))
                                                .foregroundStyle(isPlayingHere ? palette.textPrimary : palette.textSecondary)
                                                .multilineTextAlignment(.leading)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.vertical, Metrics.space1)
                                        }
                                        .buttonStyle(StudioContentButtonStyle())
                                    }

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
                                .padding(Metrics.space2)
                                .background(
                                    isSelected ? palette.surface1
                                    : (isPlayingHere ? palette.accent.opacity(Metrics.opacitySelected) : .clear),
                                    in: RoundedRectangle(cornerRadius: Metrics.radiusS)
                                )
                                .id(key)
                            }
                            if material.transcriptState == .complete && material.subtitles.isEmpty {
                                Text("未检测到语音").font(.studio(.small)).foregroundStyle(palette.textSecondary)
                            }
                        }
                    }
                    .padding(Metrics.space5)
                }
                .onAppear {
                    if let selectedSubtitle { proxy.scrollTo(selectedSubtitle, anchor: .center) }
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 580, minHeight: 460, idealHeight: 540)
        .background(palette.bgBase)
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
            if count > 0 { state.showToast("已导入 \(count) 项素材到素材库") }
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
        let sub = material.subtitles[index]
        let start = globalStart(material, sub.start)
        let span = max(0, (sub.end - sub.start) / material.playbackSpeed)
        seek(start + min(0.02, span * 0.25))
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

    private func playFrom(_ time: Double?) {
        guard player.currentItem != nil else { return }
        if let time, time.isFinite {
            let duration = AssemblyTimelineLayout(materials: project.materials).duration
            let target = min(max(0, duration - 0.05), max(0, time))
            playhead = target
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                Task { @MainActor in
                    player.rate = Float(previewRate)
                    isPlaying = true
                }
            }
        } else if !isPlaying {
            togglePlayback()
        }
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
            let library = Dictionary(uniqueKeysWithValues: project.referenceMedia.map { ($0.id, $0) })
            let inserts = project.materials.flatMap { material in
                AIEditing.validatedInserts(material.inserts ?? [], clipID: material.id,
                                           clipStart: material.inPoint, clipEnd: material.outPoint, library: library)
            }
            let assembly = try await ExportService.assemble(project: project, includeSubtitles: false, inserts: inserts)
            try Task.checkCancellation()
            let item = AVPlayerItem(asset: assembly.composition)
            item.videoComposition = assembly.videoComposition
            item.audioMix = assembly.audioMix
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
        let roughCutRevision: Int?
    }
    let clips: [ClipSignature]
    let audioClips: [AudioClip]?
    let callouts: [CalloutOverlay]?
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
                inserts: $0.inserts,
                roughCutRevision: $0.roughCutRevision
            )
        }
        audioClips = project.audioClips
        callouts = project.callouts
        width = project.canvasWidth
        height = project.canvasHeight
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
