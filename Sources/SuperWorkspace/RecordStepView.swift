import AVKit
import SwiftUI

struct MaterialThumbnail: View {
    let url: URL?
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Color.black
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "video").font(.largeTitle).foregroundStyle(.secondary) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: url) {
            image = nil
            guard let url else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 360)
            if let result = try? await generator.image(at: .zero) {
                image = NSImage(cgImage: result.image, size: .zero)
            }
        }
    }
}

struct RecordStepView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    let project: VideoProject
    @State private var preview: URL?
    var body: some View {
        Group {
            if project.materials.isEmpty {
                StudioWorkspace(title: "开始创作。", detail: "录下屏幕里的想法，让每一段内容成为作品。") {
                    StudioPreview(symbol: "macwindow", title: "录制完成后，在这里查看素材")
                } controls: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("录制素材").font(.system(size: 18, weight: .medium))
                        Text("录制与粗剪在同一界面完成，导出后自动添加到项目。")
                            .font(.system(size: 13)).foregroundStyle(palette.textSecondary).lineSpacing(5)
                    }
                    Button { state.record() } label: {
                        Label("录制新素材", systemImage: "record.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(StudioButtonStyle(kind: .primary))
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 36) {
                        HStack(alignment: .firstTextBaseline) {
                            WorkspaceHeading(title: "录制素材。", detail: "每一段录制，都在这里准备就绪。")
                            Spacer(minLength: 24)
                            Button("录制新素材", systemImage: "plus") { state.record() }
                                .buttonStyle(StudioButtonStyle(kind: .primary))
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 20)], spacing: 24) {
                            ForEach(Array(project.materials.enumerated()), id: \.element.id) { index, material in
                                VStack(alignment: .leading, spacing: 10) {
                                    Button {
                                        preview = ProjectLayout.picture(material, in: project)
                                    } label: {
                                        MaterialThumbnail(url: material.exportState == .complete ? ProjectLayout.picture(material, in: project) : nil)
                                            .aspectRatio(16 / 9, contentMode: .fit)
                                            .overlay(alignment: .topLeading) {
                                                if let label = material.motionLabel {
                                                    Text(label).font(.caption.weight(.medium)).padding(.horizontal, 9).padding(.vertical, 5)
                                                        .foregroundStyle(palette.ai).background(palette.bgDeep, in: Capsule()).padding(8)
                                                }
                                            }
                                    }.buttonStyle(.plain).disabled(material.exportState != .complete)
                                    .overlay(alignment: .topTrailing) {
                                        MaterialActionsMenu(projectID: project.id, materialID: material.id)
                                            .foregroundStyle(.white)
                                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                                            .padding(8)
                                    }
                                    HStack {
                                        Text("素材 \(index + 1)").font(.headline)
                                        Spacer()
                                        Text(material.exportState == .running ? "正在导出…" : durationLabel(material.duration))
                                            .font(.caption.monospacedDigit()).foregroundStyle(palette.textSecondary)
                                    }
                                    if let error = material.exportError ?? material.motionError ?? material.transcriptError {
                                        Text(error).font(.caption).foregroundStyle(palette.danger).textSelection(.enabled)
                                    }
                                    if let warning = material.transcriptWarning {
                                        Text(warning).font(.caption).foregroundStyle(palette.warning).textSelection(.enabled)
                                    }
                                    HStack {
                                        if material.motionState == .failed {
                                            Button("重试动效") { state.enqueueMotion(project.id, material.id) }
                                        }
                                        if material.transcriptState == .failed || material.transcriptWarning != nil {
                                            Button("重试字幕") { state.transcribe(project.id, material.id) }
                                        } else if material.transcriptState == .running {
                                            Label("识别字幕中", systemImage: "waveform").font(.caption).foregroundStyle(palette.textSecondary)
                                        }
                                    }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 1100, alignment: .leading)
                    .padding(40)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(palette.bgBase)
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let preview {
                PreviewSheet(url: preview) { self.preview = nil }
            }
        }
    }
}

struct PreviewSheet: View {
    let url: URL
    let close: () -> Void
    @State private var player = AVPlayer()
    var body: some View {
        VStack {
            VideoSurface(player: player).frame(minWidth: 700, minHeight: 400)
            Button("关闭", action: close).buttonStyle(StudioButtonStyle()).keyboardShortcut(.cancelAction).padding(12)
        }.onAppear { player.replaceCurrentItem(with: AVPlayerItem(url: url)) }
            .onDisappear { player.pause() }
    }
}

struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    var controlsStyle: AVPlayerViewControlsStyle = .inline
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = controlsStyle
        return view
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
        nsView.controlsStyle = controlsStyle
    }
}
func durationLabel(_ time: Double) -> String {
    guard time.isFinite else { return "00:00" }
    let seconds = max(0, Int(time))
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
