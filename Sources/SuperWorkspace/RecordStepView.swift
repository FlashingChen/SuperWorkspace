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
            else { Image(systemName: "video").font(.title2).foregroundStyle(Color.white.opacity(0.4)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusM + 2, style: .continuous))
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
                StudioWorkspace(title: "录制第一段素材", detail: "录制与粗剪在同一界面完成，导出后自动识别字幕并添加到项目。") {
                    StudioPreview(symbol: "macwindow", title: "录制完成后，在这里查看素材")
                } controls: {
                    CapabilityReadinessView()
                    Button { state.record() } label: {
                        HStack(spacing: Metrics.space2) {
                            Circle().fill(palette.brand).frame(width: 8, height: 8)
                            Text("录制新素材")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(StudioButtonStyle(kind: .primary))
                    .disabled(project.isFrozen)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.space5) {
                        HStack(spacing: Metrics.space3) {
                            HStack(alignment: .firstTextBaseline, spacing: Metrics.space2_5) {
                                Text("项目素材").font(.studio(.heading))
                                Text(summaryLabel)
                                    .font(.studio(.small))
                                    .foregroundStyle(palette.textSecondary)
                                    .monospacedDigit()
                            }
                            Spacer(minLength: Metrics.space4)
                            Button { state.record() } label: {
                                HStack(spacing: Metrics.space2) {
                                    Circle().fill(palette.brand).frame(width: 8, height: 8)
                                    Text("录制新素材")
                                }
                            }
                            .buttonStyle(StudioButtonStyle(kind: .secondary))
                            .disabled(project.isFrozen)
                            Button {
                                withAnimation(StudioMotion.interactive) {
                                    state.stage = .assemble
                                }
                            } label: {
                                HStack(spacing: Metrics.space1_5) {
                                    Text("进入拼装")
                                    Image(systemName: "arrow.right")
                                }
                            }
                            .buttonStyle(StudioButtonStyle(kind: .primary))
                        }
                        CapabilityReadinessView()
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: Metrics.space4)],
                            alignment: .leading,
                            spacing: Metrics.space4
                        ) {
                            ForEach(Array(project.materials.enumerated()), id: \.element.id) { index, material in
                                MaterialCard(
                                    projectID: project.id,
                                    material: material,
                                    number: index + 1,
                                    picture: ProjectLayout.picture(material, in: project)
                                ) {
                                    preview = ProjectLayout.picture(material, in: project)
                                } onEdit: {
                                    openTimeline(for: material)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: Metrics.contentWide, alignment: .leading)
                    .padding(.horizontal, Metrics.space6)
                    .padding(.vertical, Metrics.space5)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(palette.stage)
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            if let preview {
                PreviewSheet(url: preview) { self.preview = nil }
            }
        }
    }

    private var summaryLabel: String {
        let total = durationLabel(project.materials.reduce(0) { $0 + $1.timelineDuration })
        let motionReady = project.materials.filter { $0.wantsMotion && $0.motionState == .complete }.count
        let motionActive = project.materials.filter { $0.wantsMotion && [.queued, .running].contains($0.motionState) }.count
        var parts = ["\(project.materials.count) 段", total]
        if motionReady > 0 { parts.append("\(motionReady) 段已包装") }
        if motionActive > 0 { parts.append("\(motionActive) 段包装中") }
        return parts.joined(separator: " · ")
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
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    let projectID: UUID
    let material: Material
    let number: Int
    let picture: URL
    let onPreview: () -> Void
    let onEdit: () -> Void
    @State private var renaming = false
    @State private var draftTitle = ""

    private var statusSummary: (text: String, color: Color, spinning: Bool)? {
        if material.exportState == .running { return ("正在导出视频…", palette.textSecondary, true) }
        if material.exportState == .failed { return ("视频导出失败", palette.danger, false) }
        if material.wantsMotion {
            switch material.motionState {
            case .running:
                return (state.motionPhases[material.mediaID] ?? "AI 包装中…", palette.ai, true)
            case .queued:
                return (state.motionPhases[material.mediaID] ?? "AI 包装排队中", palette.ai, false)
            case .failed:
                return ("AI 包装失败", palette.danger, false)
            case .complete:
                if material.transcriptState == .running {
                    return ("AI 包装就绪 · \(state.taskPhases[material.mediaID] ?? "识别字幕中")", palette.ai, true)
                }
                return (material.useOriginal == true ? "已切回原片" : "AI 包装就绪", material.useOriginal == true ? palette.textSecondary : palette.success, false)
            case .idle:
                if material.transcriptState == .running {
                    return ("待开始包装 · \(state.taskPhases[material.mediaID] ?? "识别字幕中")", palette.ai, true)
                }
                return ("待开始包装", palette.ai, false)
            }
        }
        if material.transcriptState == .running {
            return (state.taskPhases[material.mediaID] ?? "处理字幕中…", palette.textSecondary, true)
        }
        if material.transcriptState == .failed { return ("字幕失败", palette.danger, false) }
        return nil
    }

    private var awaitingPackagingStart: Bool {
        material.exportState == .complete && material.wantsMotion && material.motionState == .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space2_5) {
            ZStack {
                Button(action: onPreview) {
                    ZStack {
                        palette.mediaGround
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .overlay {
                                MaterialThumbnail(url: material.exportState == .complete ? picture : nil)
                                    .saturation(awaitingPackagingStart ? 0.15 : 1.0)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusM + 2, style: .continuous))
                    }
                    .overlay(alignment: .topLeading) {
                        Text(String(format: "%02d", number))
                            .font(.studio(.micro, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.white.opacity(0.9))
                            .padding(.horizontal, Metrics.space2)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.72), in: Capsule())
                            .padding(Metrics.space2)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Text(material.exportState == .complete ? durationLabel(material.timelineDuration) : "—")
                            .font(.studio(.timecode, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, Metrics.space2)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.76), in: Capsule())
                            .padding(Metrics.space2)
                    }
                }
                .buttonStyle(StudioContentButtonStyle())
                .disabled(material.exportState != .complete)
                .accessibilityLabel("预览 \(material.displayTitle(index: number - 1))")

                if awaitingPackagingStart {
                    RoundedRectangle(cornerRadius: Metrics.radiusM + 2, style: .continuous)
                        .fill(Color.black.opacity(0.52))
                        .allowsHitTesting(false)
                    Button {
                        state.enqueueMotion(projectID, material.id)
                    } label: {
                        Label("开始 AI 包装", systemImage: "sparkles")
                    }
                    .buttonStyle(StudioButtonStyle(kind: .primary))
                    .help("结合字幕与素材库自动生成动效与画面包装")
                }
            }

            VStack(alignment: .leading, spacing: Metrics.space2) {
                HStack(spacing: Metrics.space2) {
                    Button {
                        draftTitle = material.title ?? ""
                        renaming = true
                    } label: {
                        Text(material.displayTitle(index: number - 1))
                            .font(.studio(.bodyMedium))
                            .foregroundStyle(palette.textPrimary)
                            .lineLimit(1)
                    }
                    .buttonStyle(StudioContentButtonStyle())
                    .help("点击重命名片段")
                    .popover(isPresented: $renaming, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: Metrics.space3) {
                            Text("重命名片段").font(.studio(.smallStrong))
                            TextField("素材 \(number)", text: $draftTitle)
                                .textFieldStyle(StudioTextFieldStyle())
                                .onSubmit {
                                    state.renameMaterial(projectID, material.id, title: draftTitle)
                                    renaming = false
                                }
                            HStack {
                                Spacer()
                                Button { renaming = false } label: { Text(verbatim: "取消") }
                                    .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                                Button {
                                    state.renameMaterial(projectID, material.id, title: draftTitle)
                                    renaming = false
                                } label: { Text(verbatim: "保存") }
                                .buttonStyle(StudioButtonStyle(kind: .primary, size: .compact))
                            }
                        }
                        .padding(Metrics.space4)
                        .frame(width: 240)
                        .background(palette.island)
                    }
                    Spacer(minLength: Metrics.space2)
                    MaterialCardStatus(material: material)
                    MaterialActionsMenu(projectID: projectID, material: material, onEdit: onEdit)
                }

                HStack(spacing: Metrics.space2) {
                    if let summary = statusSummary {
                        HStack(spacing: Metrics.space1_5) {
                            if summary.spinning {
                                ProgressView().controlSize(.mini)
                            }
                            Text(summary.text)
                                .font(.studio(.caption, weight: .medium))
                                .foregroundStyle(summary.color)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, Metrics.space2)
                        .padding(.vertical, 3)
                        .background(summary.color.opacity(0.14), in: Capsule())
                    } else {
                        Text("原片就绪")
                            .font(.studio(.caption))
                            .foregroundStyle(palette.textSecondary)
                            .padding(.horizontal, Metrics.space2)
                            .padding(.vertical, 3)
                            .background(palette.controlWell, in: Capsule())
                    }
                    Spacer(minLength: Metrics.space1)
                    if material.wantsMotion && material.motionState == .failed {
                        Button("重试包装") { state.enqueueMotion(projectID, material.id) }
                            .buttonStyle(StudioButtonStyle(kind: .secondary, size: .compact))
                            .fixedSize()
                    } else if material.exportState == .complete {
                        HStack(spacing: Metrics.space1_5) {
                            if material.wantsMotion && material.motionState == .complete {
                                Button(material.useOriginal == true ? "启用包装" : "原片") {
                                    state.setUseOriginal(projectID, material.id, material.useOriginal != true)
                                }
                                .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                                .fixedSize()
                                .help(material.useOriginal == true ? "启用 AI 包装版本" : "临时切回未包装原片")
                            }
                            Button("粗剪") { state.resumeRoughCut(projectID, material.id) }
                                .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                                .fixedSize()
                                .help("在粗剪面板（Rough Cutting Panel）重新打开此视频")
                            Button("时间线", action: onEdit)
                                .buttonStyle(StudioButtonStyle(kind: .secondary, size: .compact))
                                .fixedSize()
                                .help("在时间线编辑字幕与拼装")
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.space1)
        }
        .padding(Metrics.space2_5)
        .studioIsland(cornerRadius: Metrics.radiusIsland)
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
        if material.motionState == .running || state.motionPhases[material.mediaID] != nil {
            return ("hourglass", state.motionPhases[material.mediaID] ?? "添加动效中", palette.ai)
        }
        if let phase = state.taskPhases[material.mediaID] {
            return ("hourglass", phase, palette.textSecondary)
        }
        if material.transcriptState == .running {
            return ("hourglass", "处理字幕中", palette.textSecondary)
        }
        if material.motionState == .queued { return ("hourglass", "动效排队中", palette.ai) }
        return nil
    }

    private var messages: [String] {
        [material.exportError, material.motionError, material.transcriptError, material.transcriptWarning,
         material.aiEditWarning].compactMap { $0 }
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
                .background(palette.island)
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
    @Environment(\.palette) private var palette
    let url: URL
    let close: () -> Void
    @State private var player = AVPlayer()
    var body: some View {
        VStack(spacing: 0) {
            StudioPlayer(player: player).frame(minWidth: 720, minHeight: 420)
            HStack {
                Spacer()
                Button("关闭", action: close)
                    .buttonStyle(StudioButtonStyle(kind: .secondary, size: .compact))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Metrics.space4)
            .padding(.vertical, Metrics.space3)
            .background(palette.island)
        }
        .background(palette.island)
        .onAppear { player.replaceCurrentItem(with: AVPlayerItem(url: url)) }
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
        view.allowsVideoFrameAnalysis = controlsStyle != .none
        return view
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
        nsView.controlsStyle = controlsStyle
        nsView.allowsVideoFrameAnalysis = controlsStyle != .none
    }
}

func durationLabel(_ time: Double) -> String {
    guard time.isFinite else { return "00:00" }
    let seconds = max(0, Int(time))
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
}
