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
                HStack(alignment: .top, spacing: 28) {
                    ZStack(alignment: .bottom) {
                        VideoSurface(player: player)
                        if let subtitle = project.assembledSubtitles.first(where: { playhead >= $0.start && playhead < $0.end }) {
                            Text(subtitle.text).font(.title3.weight(.medium)).foregroundStyle(.white)
                                .padding(8).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                                .padding(.horizontal, 40).padding(.bottom, 56).allowsHitTesting(false)
                        }
                        if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 20) {
                        Text("字幕").font(.system(size: 17, weight: .medium))
                        subtitleStrip
                    }
                    .frame(width: 260)
                }
                .padding(28)
                .frame(maxHeight: .infinity)
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
                materialStrip
            }
        }
        .background(palette.bgBase)
        .task(id: previewKey) { await preparePreview() }
        .onDisappear { stopPreview() }
    }
    private var subtitleStrip: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(project.materials) { material in
                    if material.transcriptState == .complete {
                        ForEach(Array(material.subtitles.enumerated()), id: \.offset) { index, subtitle in
                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    let offset = project.materials.prefix { $0.id != material.id }.reduce(0) { $0 + $1.duration }
                                    player.seek(to: CMTime(seconds: offset + subtitle.start, preferredTimescale: 600))
                                } label: { Text(durationLabel(globalStart(material, subtitle.start))).font(.caption.monospacedDigit()) }
                                    .buttonStyle(.plain).foregroundStyle(palette.textSecondary)
                                TextField("字幕", text: Binding(
                                    get: { state.projects.first(where: { $0.id == project.id })?.materials.first(where: { $0.id == material.id })?.subtitles[safe: index]?.text ?? subtitle.text },
                                    set: { state.editSubtitle(projectID: project.id, materialID: material.id, index: index, text: $0) }
                                ), axis: .vertical).textFieldStyle(.plain).lineLimit(2...3)
                            }
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(material.transcriptState == .failed ? "字幕识别失败" : "等待字幕")
                            if let error = material.transcriptError { Text(error).font(.caption).lineLimit(2).foregroundStyle(palette.danger) }
                            if material.exportState == .complete && material.transcriptState != .running {
                                Button("识别字幕") { state.transcribe(project.id, material.id) }
                            }
                        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
    private var materialStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(Array(project.materials.enumerated()), id: \.element.id) { index, material in
                    VStack(spacing: 6) {
                        MaterialThumbnail(url: material.exportState == .complete ? ProjectLayout.picture(material, in: project) : nil)
                            .frame(width: 136, height: 76)
                        HStack {
                            Text("\(index + 1)").font(.caption.monospacedDigit())
                            Spacer()
                            Button { state.moveMaterial(project.id, index: index, by: -1) } label: { Image(systemName: "chevron.left") }
                                .disabled(index == 0).accessibilityLabel("向前移动素材")
                            Button { state.moveMaterial(project.id, index: index, by: 1) } label: { Image(systemName: "chevron.right") }
                                .disabled(index == project.materials.count - 1).accessibilityLabel("向后移动素材")
                        }.buttonStyle(.borderless)
                        if material.motionState == .failed {
                            Button("重试动效") { state.enqueueMotion(project.id, material.id) }.font(.caption)
                        }
                    }.frame(width: 136)
                }
            }.padding(16)
        }.background(palette.bgSidebar).frame(height: 150)
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
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { time in
                Task { @MainActor in playhead = time.seconds.isFinite ? time.seconds : 0 }
            }
        } catch is CancellationError { }
        catch { previewError = error.localizedDescription }
    }
    private func stopPreview() {
        player.pause()
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        player.replaceCurrentItem(with: nil)
    }
}
private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
