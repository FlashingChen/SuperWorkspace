import AVKit
import SwiftUI

struct AssemblyView: View {
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
    @State private var zoom = 1.0
    @State private var previewFraction = 0.66
    @State private var dragOrigin: Double?
    @State private var restored = false
    @State private var rebuildTask: Task<Void, Never>?

    // Rendering and caption changes share the same compositor as export.
    private var previewKey: AssemblyPreviewInputs { AssemblyPreviewInputs(project: project) }
    var body: some View {
        VStack(spacing: 0) {
            if project.materials.isEmpty {
                StudioWorkspace(title: "还没有素材", detail: "录制后即可预览、裁剪和校对字幕。") {
                    StudioPreview(symbol: "film.stack", title: "等待录制素材")
                } controls: {
                    Button("录制新素材", systemImage: "record.circle") { state.record() }
                        .buttonStyle(StudioButtonStyle(kind: .primary))
                }
            } else {
                GeometryReader { geometry in
                    let height = min(max(220, geometry.size.height * previewFraction), max(220, geometry.size.height - 238))
                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: Metrics.space4) {
                            ZStack {
                                VideoSurface(player: player, controlsStyle: .none)
                                if loading { ProgressView() }
                                if let previewError {
                                    VStack(spacing: Metrics.space3) {
                                        Text(previewError).multilineTextAlignment(.center)
                                        Button("重试预览") { schedulePreview() }
                                            .buttonStyle(StudioButtonStyle())
                                    }.foregroundStyle(.white).padding(Metrics.space6)
                                }
                            }
                            .background(palette.mediaGround).clipShape(RoundedRectangle(cornerRadius: Metrics.radiusL))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            inspector.frame(width: Metrics.inspector)
                        }
                        .padding(Metrics.space4).frame(height: height)
                        Rectangle().fill(palette.surface2).frame(height: 6)
                            .overlay { Capsule().fill(palette.surface3).frame(width: 32, height: 2) }
                            .contentShape(Rectangle())
                            .gesture(DragGesture().onChanged { value in
                                if dragOrigin == nil { dragOrigin = height }
                                previewFraction = min(0.85, max(0.2, ((dragOrigin ?? height) + value.translation.height) / max(1, geometry.size.height)))
                            }.onEnded { _ in dragOrigin = nil; remember(flush: true) })
                            .accessibilityLabel("预览区域高度")
                            .accessibilityAdjustableAction { direction in
                                previewFraction = min(0.85, max(0.2, previewFraction + (direction == .increment ? 0.05 : -0.05)))
                            }
                        AssemblyTimeline(project: project, playhead: playhead, isPlaying: isPlaying,
                            canPlay: player.currentItem != nil && !loading,
                            selectedMaterial: $selectedMaterial, selectedSubtitle: $selectedSubtitle,
                            onSeek: seek, onPlay: togglePlayback,
                            onMove: { state.reorderMaterial(project.id, source: $0, target: $1, after: $2) },
                            zoom: $zoom)
                    }
                }
            }
        }
        .background(palette.bgBase)
        .onAppear {
            let session = state.editorSession(project.id)
            playhead = session.playhead.isFinite ? max(0, session.playhead) : 0
            zoom = min(64, max(0.5, session.zoom))
            previewFraction = min(0.85, max(0.2, session.previewHeight))
            selectedMaterial = session.selectedMaterial
            selectedSubtitle = session.selectedSubtitle
            restored = true
            schedulePreview()
            Task { await state.lockCanvas(project.id) }
        }
        .onChange(of: previewKey) { _, _ in schedulePreview() }
        .onChange(of: playhead) { _, _ in remember() }
        .onChange(of: zoom) { _, _ in remember(flush: true) }
        .onChange(of: selectedSubtitle) { _, _ in remember(flush: true) }
        .onChange(of: selectedMaterial) { _, _ in remember(flush: true) }
        .onChange(of: project.materials.map(\.id)) { _, ids in
            if let selectedMaterial, !ids.contains(selectedMaterial) { self.selectedMaterial = nil; selectedSubtitle = nil }
        }
        .onDisappear { remember(flush: true); restored = false; rebuildTask?.cancel(); stopPreview() }
    }

    private var inspector: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.space4) {
                    if let material = project.materials.first(where: { $0.id == selectedMaterial }) {
                        HStack {
                            Text("素材 \((project.materials.firstIndex(where: { $0.id == material.id }) ?? 0) + 1)")
                                .font(.studio(.bodyLargeMedium))
                            Spacer()
                            Menu { MaterialProcessingActions(projectID: project.id, materialID: material.id) } label: {
                                Image(systemName: "ellipsis")
                            }.menuStyle(StudioMenuStyle()).fixedSize().accessibilityLabel("素材处理操作")
                        }
                        if material.wantsMotion {
                            StudioChoice(title: "画面版本", selection: Binding(
                                get: { material.useOriginal ?? false },
                                set: { state.setUseOriginal(project.id, material.id, $0) }),
                                options: [(true, "原片"), (false, material.motionState == .complete ? "动效" : "动效处理中")])
                            if material.motionState != .complete { Text(material.motionError ?? material.motionLabel ?? "使用原片预览").font(.studio(.small)).foregroundStyle(palette.textSecondary) }
                        }
                        Divider()
                    }
                    HStack {
                        Text("字幕").font(.studio(.subhead))
                        Spacer()
                        Button("AI 校正") { for material in project.materials { state.correctSubtitles(project.id, material.id) } }
                            .font(.studio(.small)).buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                            .disabled(project.materials.contains { $0.transcriptState == .running }
                                || !project.materials.contains { $0.transcriptState == .complete && !$0.subtitles.isEmpty })
                    }
                    ForEach(Array(project.materials.enumerated()), id: \.element.id) { number, material in
                        if project.materials.count > 1 { Text("素材 \(number + 1)").font(.studio(.small)).foregroundStyle(palette.textMuted) }
                        if let warning = material.transcriptWarning { Text(warning).font(.studio(.small)).foregroundStyle(palette.warning) }
                        if material.transcriptState == .running || material.transcriptState != .complete {
                            MaterialTaskStatus(projectID: project.id, material: material)
                        }
                        ForEach(Array(material.subtitles.enumerated()).filter { $0.element.end > material.inPoint && $0.element.start < material.outPoint }, id: \.offset) { index, subtitle in
                            let key = "\(material.id)-\(index)"
                            VStack(alignment: .leading, spacing: Metrics.space2) {
                                Button {
                                    selectedMaterial = material.id
                                    selectedSubtitle = key
                                    seek(globalStart(material, subtitle.start))
                                } label: { Text(durationLabel(globalStart(material, subtitle.start))).font(.studio(.small).monospacedDigit()) }
                                    .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact)).foregroundStyle(palette.textSecondary)
                                TextField("字幕", text: Binding(
                                    get: { state.projects.first(where: { $0.id == project.id })?.materials.first(where: { $0.id == material.id })?.subtitles[safe: index]?.text ?? subtitle.text },
                                    set: { state.editSubtitle(projectID: project.id, materialID: material.id, index: index, text: $0) }
                                ), axis: .vertical).textFieldStyle(StudioTextFieldStyle()).lineLimit(2...4)
                                    .disabled(material.transcriptState == .running)
                                    .onTapGesture { selectedMaterial = material.id; selectedSubtitle = key }

                            }
                            .padding(Metrics.space2).frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedSubtitle == key ? palette.surface1 : .clear, in: RoundedRectangle(cornerRadius: Metrics.radiusS))
                            .id(key)
                        }
                        if material.transcriptState == .complete && material.subtitles.isEmpty {
                            Text("未检测到语音").font(.studio(.small)).foregroundStyle(palette.textSecondary)
                        }
                    }
                }
            }
            .onChange(of: selectedSubtitle) { _, value in
                if let value { proxy.scrollTo(value, anchor: .center) }
            }
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
            player.play(); isPlaying = true
        }
    }
    private func globalStart(_ material: Material, _ start: Double) -> Double {
        project.materials.prefix { $0.id != material.id }.reduce(max(0, start - material.inPoint)) { $0 + $1.timelineDuration }
    }
    private func schedulePreview() {
        guard restored else { return }
        rebuildTask?.cancel()
        rebuildTask = Task {
            do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation() } catch { return }
            await preparePreview()
        }
    }
    private func preparePreview() async {
        let wasPlaying = isPlaying
        stopPreview(); previewError = nil
        guard !project.materials.isEmpty, project.materials.allSatisfy(\.isReady) else {
            previewError = "素材导出未完成，请返回素材页查看或移除失败素材。"; return
        }
        loading = true
        defer { loading = false }
        do {
            let assembly = try await ExportService.assemble(project: project, includeSubtitles: true)
            try Task.checkCancellation()
            let item = AVPlayerItem(asset: assembly.composition)
            item.videoComposition = assembly.videoComposition
            player.replaceCurrentItem(with: item)
            seek(playhead)
            if wasPlaying { player.play(); isPlaying = true }
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { time in
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
    let materials: [Material]
    let width: Double?
    let height: Double?
    init(project: VideoProject) {
        materials = project.materials
        width = project.canvasWidth
        height = project.canvasHeight
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
