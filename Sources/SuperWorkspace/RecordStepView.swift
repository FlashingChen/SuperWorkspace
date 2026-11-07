import AVKit
import SwiftUI

struct MaterialThumbnail: View {
    @Environment(\.palette) private var palette
    let url: URL?
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            palette.mediaGround
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "video").font(.largeTitle).foregroundStyle(Color.white.opacity(0.5)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusL))
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
                    VStack(alignment: .leading, spacing: Metrics.space2_5) {
                        Text("录制素材").font(.studio(.subhead))
                        Text("录制与粗剪在同一界面完成，导出后自动添加到项目。")
                            .font(.studio(.body)).foregroundStyle(palette.textSecondary).lineSpacing(Metrics.space1_5)
                    }
                    CapabilityReadinessView()
                    Button { state.record() } label: {
                        Label("录制新素材", systemImage: "record.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(StudioButtonStyle(kind: .primary))
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.space5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("素材").font(.studio(.heading))
                            Text("\(project.materials.count) 段 · \(durationLabel(project.materials.reduce(0) { $0 + $1.timelineDuration }))")
                                .font(.studio(.small)).foregroundStyle(palette.textSecondary)
                            Spacer(minLength: Metrics.space6)
                            Button("录制新素材", systemImage: "plus") { state.record() }
                                .buttonStyle(StudioButtonStyle(kind: .primary))
                        }
                        CapabilityReadinessView()
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: Metrics.space5)], alignment: .leading, spacing: Metrics.space6) {
                            ForEach(Array(project.materials.enumerated()), id: \.element.id) { index, material in
                                VStack(alignment: .leading, spacing: Metrics.space2_5) {
                                    Button {
                                        preview = ProjectLayout.picture(material, in: project)
                                    } label: {
                                        MaterialThumbnail(url: material.exportState == .complete ? ProjectLayout.picture(material, in: project) : nil)
                                            .aspectRatio(16 / 9, contentMode: .fit)
                                            .overlay(alignment: .topLeading) {
                                                if let label = material.motionLabel {
                                                    Text(label).font(.studio(.small, weight: .medium)).padding(.horizontal, Metrics.space2_5).padding(.vertical, Metrics.space1_5)
                                                        .foregroundStyle(palette.ai).background(palette.bgDeep, in: Capsule()).padding(Metrics.space2)
                                                }
                                            }
                                    }.buttonStyle(StudioContentButtonStyle()).disabled(material.exportState != .complete)
                                    .overlay(alignment: .topTrailing) {
                                        MaterialActionsMenu(projectID: project.id, materialID: material.id)
                                            .foregroundStyle(.white)
                                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: Metrics.radiusS))
                                            .padding(Metrics.space2)
                                    }
                                    HStack {
                                        Text("素材 \(index + 1)").font(.studio(.bodyLargeMedium))
                                        Spacer()
                                        Text(material.exportState == .running ? "正在导出…" : durationLabel(material.duration))
                                            .font(.studio(.small).monospacedDigit()).foregroundStyle(palette.textSecondary)
                                    }
                                    if let error = material.exportError { Text(error).font(.studio(.small)).foregroundStyle(palette.danger).textSelection(.enabled) }
                                    MaterialTaskStatus(projectID: project.id, material: material)
                                    if let warning = material.transcriptWarning { Text(warning).font(.studio(.small)).foregroundStyle(palette.warning).textSelection(.enabled) }
                                    if material.sourceReady {
                                        Button("在时间线中编辑") {
                                            var session = state.editorSession(project.id)
                                            session.selectedMaterial = material.id
                                            session.playhead = project.materials.prefix { $0.id != material.id }.reduce(0) { $0 + $1.timelineDuration }
                                            state.rememberEditor(project.id, session, flush: true)
                                            state.stage = .assemble
                                        }.buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact)).font(.studio(.small))
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: Metrics.contentWide, alignment: .leading)
                    .padding(Metrics.space8)
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
            StudioPlayer(player: player).frame(minWidth: 700, minHeight: 400)
            Button("关闭", action: close).buttonStyle(StudioButtonStyle()).keyboardShortcut(.cancelAction).padding(Metrics.space3)
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
