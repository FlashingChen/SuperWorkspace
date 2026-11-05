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

    private var previewKey: String {
        project.materials.map { "\($0.id):\($0.exportState):\($0.motionState)" }.joined(separator: ",")
    }
    var body: some View {
        VStack(spacing: 0) {
            if project.materials.isEmpty {
                StudioWorkspace(title: "拼装你的作品。", detail: "录制完成的素材，会按顺序拼接在这里。") {
                    StudioPreview(symbol: "film.stack", title: "等待录制素材")
                } controls: {
                    Button("去录制", systemImage: "record.circle") { state.stage = .record }
                        .buttonStyle(StudioButtonStyle(kind: .primary))
                }
            } else {
                VSplitView {
                HStack(alignment: .top, spacing: 20) {
                    ZStack(alignment: .bottom) {
                        VideoSurface(player: player, controlsStyle: .none)
                        if let subtitle = project.assembledSubtitles.first(where: { playhead >= $0.start && playhead < $0.end }) {
                            Text(subtitle.text).font(.title3.weight(.medium)).foregroundStyle(.white)
                                .padding(8).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                                .padding(.horizontal, 40).padding(.bottom, 24).allowsHitTesting(false)
                        }
                        if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Text("字幕").font(.system(size: 17, weight: .medium))
                            Spacer()
                            Button("AI 校正") {
                                for material in project.materials { state.correctSubtitles(project.id, material.id) }
                            }
                            .font(.caption).buttonStyle(.borderless)
                            .disabled(project.materials.contains { $0.transcriptState == .running }
                                || !project.materials.contains { $0.transcriptState == .complete && !$0.subtitles.isEmpty })
                        }
                        subtitleStrip
                    }
                    .frame(width: 260)
                }
                .padding(20)
                .frame(minHeight: 220, maxHeight: .infinity)
                AssemblyTimeline(project: project, playhead: playhead, isPlaying: isPlaying,
                    canPlay: player.currentItem != nil && !loading,
                    selectedMaterial: $selectedMaterial, selectedSubtitle: $selectedSubtitle,
                    onSeek: seek, onPlay: togglePlayback,
                    onMove: { state.reorderMaterial(project.id, source: $0, target: $1, after: $2) },
                    onRetryMotion: { state.enqueueMotion(project.id, $0) })
                }
                if let previewError {
                    Text(previewError).font(.callout).foregroundStyle(palette.danger).padding(12)
                }
                if !project.canExport {
                    HStack {
                        Image(systemName: "clock")
                        Text("素材、动效和字幕全部完成后即可导出。")
                        Spacer()
                    }.font(.caption).foregroundStyle(palette.textSecondary).padding(12)
                }
            }
        }
        .background(palette.bgBase)
        .task(id: previewKey) { await preparePreview() }
        .onChange(of: project.materials.map(\.id)) { _, ids in
            if let selectedMaterial, !ids.contains(selectedMaterial) {
                self.selectedMaterial = nil
                selectedSubtitle = nil
            }
        }
        .onDisappear { stopPreview() }
    }
    private var subtitleStrip: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(project.materials) { material in
                    if let warning = material.transcriptWarning {
                        Text(warning).font(.caption).foregroundStyle(palette.warning)
                    }
                    if material.transcriptState == .complete {
                        ForEach(Array(material.subtitles.enumerated()), id: \.offset) { index, subtitle in
                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    let offset = project.materials.prefix { $0.id != material.id }.reduce(0) { $0 + $1.duration }
                                    selectedSubtitle = "\(material.id)-\(index)"
                                    seek(offset + subtitle.start)
                                } label: { Text(durationLabel(globalStart(material, subtitle.start))).font(.caption.monospacedDigit()) }
                                    .buttonStyle(.plain).foregroundStyle(palette.textSecondary)
                                TextField("字幕", text: Binding(
                                    get: { state.projects.first(where: { $0.id == project.id })?.materials.first(where: { $0.id == material.id })?.subtitles[safe: index]?.text ?? subtitle.text },
                                    set: { state.editSubtitle(projectID: project.id, materialID: material.id, index: index, text: $0) }
                                ), axis: .vertical).textFieldStyle(.plain).lineLimit(2...3)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedSubtitle == "\(material.id)-\(index)" ? palette.surface1 : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .id("\(material.id)-\(index)")
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(material.transcriptState == .failed ? "字幕识别失败" : material.transcriptState == .running ? "处理字幕中…" : "等待字幕")
                            if let error = material.transcriptError { Text(error).font(.caption).lineLimit(2).foregroundStyle(palette.danger) }
                            if material.exportState == .complete && material.transcriptState != .running {
                                Button("识别字幕") { state.transcribe(project.id, material.id) }
                            }
                        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .onChange(of: selectedSubtitle) { _, value in
            if let value { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(value, anchor: .center) } }
        }
        }
    }
    private func seek(_ time: Double) {
        let duration = AssemblyTimelineLayout(materials: project.materials).duration
        let target = min(duration, max(0, time))
        player.pause()
        isPlaying = false
        playhead = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    private func togglePlayback() {
        if player.rate > 0 { player.pause(); isPlaying = false }
        else {
            if playhead >= AssemblyTimelineLayout(materials: project.materials).duration - 0.05 { seek(0) }
            player.play()
            isPlaying = true
        }
    }
    private func globalStart(_ material: Material, _ start: Double) -> Double {
        project.materials.prefix { $0.id != material.id }.reduce(start) { $0 + $1.duration }
    }
    private func preparePreview() async {
        stopPreview()
        previewError = nil
        guard !project.materials.isEmpty, project.materials.allSatisfy(\.isReady) else {
            previewError = "等待素材及动效处理完成。"
            return
        }
        loading = true
        defer { loading = false }
        do {
            let assembly = try await ExportService.assemble(project: project)
            try Task.checkCancellation()
            let item = AVPlayerItem(asset: assembly.composition)
            item.videoComposition = assembly.videoComposition
            player.replaceCurrentItem(with: item)
            seek(playhead)
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
        player.pause()
        isPlaying = false
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        player.replaceCurrentItem(with: nil)
    }
}
private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
