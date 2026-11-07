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
                        HStack {
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
                                MaterialCard(projectID: project.id, material: material, number: index + 1,
                                             picture: ProjectLayout.picture(material, in: project)) {
                                    preview = ProjectLayout.picture(material, in: project)
                                } onEdit: {
                                    openTimeline(for: material)
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

    private func openTimeline(for material: Material) {
        var session = state.editorSession(project.id)
        session.selectedMaterial = material.id
        session.playhead = project.materials.prefix { $0.id != material.id }.reduce(0) { $0 + $1.timelineDuration }
        state.rememberEditor(project.id, session, flush: true)
        state.stage = .assemble
    }
}

private struct MaterialCard: View {
    @Environment(\.palette) private var palette
    let projectID: UUID
    let material: Material
    let number: Int
    let picture: URL
    let onPreview: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            Button(action: onPreview) {
                palette.mediaGround
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        MaterialThumbnail(url: material.exportState == .complete ? picture : nil)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusL))
            }
            .buttonStyle(StudioContentButtonStyle())
            .disabled(material.exportState != .complete)
            .accessibilityLabel("预览素材 \(number)")

            HStack(spacing: Metrics.space2) {
                Text("素材 \(number)").font(.studio(.bodyLargeMedium)).lineLimit(1)
                Spacer(minLength: Metrics.space2)
                MaterialCardStatus(material: material)
                Text(material.exportState == .complete ? durationLabel(material.duration) : "—")
                    .font(.studio(.timecode)).foregroundStyle(palette.textSecondary)
                MaterialActionsMenu(projectID: projectID, material: material, onEdit: onEdit)
            }
            .frame(height: Metrics.row)
        }
    }
}

private struct MaterialCardStatus: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    @State private var showsDetails = false
    let material: Material

    private var status: (symbol: String, title: String, color: Color)? {
        if material.exportState == .failed { return ("exclamationmark.circle", "导出失败", palette.danger) }
        if material.motionState == .failed { return ("exclamationmark.circle", "动效失败", palette.danger) }
        if material.transcriptState == .failed { return ("exclamationmark.circle", "字幕失败", palette.danger) }
        if material.transcriptWarning != nil { return ("exclamationmark.triangle", "字幕需复查", palette.warning) }
        if material.exportState == .running { return ("hourglass", "正在导出", palette.textSecondary) }
        if material.motionState == .running { return ("hourglass", "添加动效中", palette.ai) }
        if material.transcriptState == .running {
            return ("hourglass", state.taskPhases[material.mediaID] ?? "处理字幕中", palette.textSecondary)
        }
        if material.motionState == .queued { return ("hourglass", "动效排队中", palette.ai) }
        return nil
    }

    private var messages: [String] {
        [material.exportError, material.motionError, material.transcriptError, material.transcriptWarning].compactMap { $0 }
    }

    var body: some View {
        if let status {
            Button { showsDetails = true } label: {
                Image(systemName: status.symbol).foregroundStyle(status.color)
            }
            .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
            .help(status.title)
            .accessibilityLabel(status.title)
            .accessibilityHint("查看处理详情")
            .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: Metrics.space2) {
                    Text(status.title).font(.studio(.smallStrong))
                    if !messages.isEmpty {
                        ViewThatFits(in: .vertical) {
                            diagnostics.fixedSize(horizontal: false, vertical: true)
                            ScrollView { diagnostics }
                        }
                    }
                }
                .foregroundStyle(palette.textPrimary)
                .padding(Metrics.space4)
                .frame(width: 320)
                .frame(maxHeight: 220)
                .background(palette.bgBase)
            }
        } else if material.wantsMotion, material.motionState == .complete {
            Image(systemName: "wand.and.stars")
                .font(.studio(.small))
                .foregroundStyle(palette.ai)
                .help("动效已完成")
                .accessibilityLabel("动效已完成")
        }
    }

    private var diagnostics: some View {
        Text(messages.joined(separator: "\n\n"))
            .font(.studio(.small)).foregroundStyle(palette.textSecondary)
            .textSelection(.enabled)
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
