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
                    CapabilityReadinessView()
                    Button { state.record() } label: {
                        Label("录制新素材", systemImage: "record.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(StudioButtonStyle(kind: .primary))
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("素材").font(.system(size: 22, weight: .semibold))
                            Text("\(project.materials.count) 段 · \(durationLabel(project.materials.reduce(0) { $0 + $1.timelineDuration }))")
                                .font(.system(size: 12)).foregroundStyle(palette.textSecondary)
                            Spacer(minLength: 24)
                            Button("录制新素材", systemImage: "plus") { state.record() }
                                .buttonStyle(StudioButtonStyle(kind: .primary))
                        }
                        CapabilityReadinessView()
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 20)], alignment: .leading, spacing: 24) {
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
                                    }.buttonStyle(StudioContentButtonStyle()).disabled(material.exportState != .complete)
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
                                    if let error = material.exportError { Text(error).font(.caption).foregroundStyle(palette.danger).textSelection(.enabled) }
                                    MaterialTaskStatus(projectID: project.id, material: material)
                                    if let warning = material.transcriptWarning { Text(warning).font(.caption).foregroundStyle(palette.warning).textSelection(.enabled) }
                                    if material.sourceReady {
                                        Button("在时间线中编辑") {
                                            var session = state.editorSession(project.id)
                                            session.selectedMaterial = material.id
                                            session.playhead = project.materials.prefix { $0.id != material.id }.reduce(0) { $0 + $1.timelineDuration }
                                            state.rememberEditor(project.id, session, flush: true)
                                            state.stage = .assemble
                                        }.buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact)).font(.caption)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
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
