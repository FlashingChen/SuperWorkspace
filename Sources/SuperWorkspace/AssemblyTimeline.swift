import AVFoundation
import SwiftUI

struct AssemblyTimelineLayout {
    struct Clip: Identifiable {
        let id: UUID
        let index: Int
        let start: Double
        let duration: Double
        var end: Double { start + duration }
    }
    let clips: [Clip]
    let duration: Double

    init(materials: [Material]) {
        var cursor = 0.0
        clips = materials.enumerated().map { index, material in
            let duration = material.duration.isFinite ? max(0, material.duration) : 0
            defer { cursor += duration }
            return Clip(id: material.id, index: index, start: cursor, duration: duration)
        }
        duration = cursor
    }

    func time(at x: Double, scale: Double) -> Double {
        guard x.isFinite, scale.isFinite, scale > 0 else { return 0 }
        return min(duration, max(0, x / scale))
    }

    static func tickInterval(scale: Double) -> Double {
        [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600].first { $0 * scale >= 64 } ?? 3600
    }

    static func timecode(_ seconds: Double) -> String {
        let frames = max(0, Int((seconds.isFinite ? seconds : 0) * 30))
        return String(format: "%02d:%02d:%02d", frames / 1800, (frames / 30) % 60, frames % 30)
    }
}

struct AssemblyTimeline: View {
    @Environment(\.palette) private var palette
    let project: VideoProject
    let playhead: Double
    let isPlaying: Bool
    let canPlay: Bool
    @Binding var selectedMaterial: UUID?
    @Binding var selectedSubtitle: String?
    let onSeek: (Double) -> Void
    let onPlay: () -> Void
    let onMove: (UUID, UUID, Bool) -> Void
    let onRetryMotion: (UUID) -> Void
    @State private var zoom = 1.0
    @State private var dropTarget: UUID?
    private var layout: AssemblyTimelineLayout { .init(materials: project.materials) }
    private let gutter: CGFloat = 76

    var body: some View {
        VStack(spacing: 0) {
            controls
            Rectangle().fill(palette.surface2).frame(height: 1)
            GeometryReader { geometry in
                let viewport = max(1, geometry.size.width - gutter - 24)
                let scale = max(0.05, viewport / max(1, layout.duration)) * zoom
                let width = max(viewport, layout.duration * scale + 32)
                HStack(spacing: 0) {
                    VStack(spacing: 12) {
                        Color.clear.frame(height: 28)
                        trackLabel("字幕", symbol: "captions.bubble").frame(height: 34)
                        trackLabel("视频", symbol: "film").frame(height: 72)
                        Spacer(minLength: 0)
                    }
                    .frame(width: gutter)
                    .background(palette.bgSidebar)
                    ScrollView(.horizontal) {
                        ZStack(alignment: .topLeading) {
                            grid(width: width, height: geometry.size.height - 16, scale: scale)
                            VStack(alignment: .leading, spacing: 12) {
                                ruler(width: width, scale: scale)
                                subtitleTrack(width: width, scale: scale)
                                videoTrack(width: width, scale: scale)
                                Spacer(minLength: 12)
                            }
                            playheadView(height: max(160, geometry.size.height - 18))
                                .offset(x: min(layout.duration, max(0, playhead)) * scale - 9)
                                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("assemblyTimeline"))
                                    .onChanged { onSeek(layout.time(at: $0.location.x, scale: scale)) })
                        }
                        .frame(width: width, height: max(190, geometry.size.height - 16), alignment: .topLeading)
                        .coordinateSpace(name: "assemblyTimeline")
                        .padding(.horizontal, 12)
                    }
                    .scrollIndicators(.visible)
                }
            }
        }
        .background(palette.bgDeep)
        .frame(minHeight: 230, idealHeight: 270, maxHeight: 400)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Text("时间线").font(.system(size: 12, weight: .semibold))
            Text("\(project.materials.count) 段素材").font(.caption).foregroundStyle(palette.textSecondary)
            MaterialDeleteButton(projectID: project.id, materialID: selectedMaterial)
            Spacer()
            Button { onSeek(playhead - 1 / 30) } label: { Image(systemName: "backward.end") }
                .help("上一帧").accessibilityLabel("上一帧").disabled(!canPlay)
            Button(action: onPlay) { Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 20) }
                .help(isPlaying ? "暂停" : "播放")
                .accessibilityLabel(isPlaying ? "暂停时间线" : "播放时间线")
                .keyboardShortcut(.space, modifiers: []).disabled(!canPlay)
            Button { onSeek(playhead + 1 / 30) } label: { Image(systemName: "forward.end") }
                .help("下一帧").accessibilityLabel("下一帧").disabled(!canPlay)
            Text(AssemblyTimelineLayout.timecode(playhead))
                .foregroundStyle(palette.textPrimary)
                .accessibilityIdentifier("assembly.playhead.timecode")
            Text("/ \(AssemblyTimelineLayout.timecode(layout.duration))").foregroundStyle(palette.textMuted)
            Spacer()
            Button { zoom = max(0.5, zoom / 1.4) } label: { Image(systemName: "minus.magnifyingglass") }
                .accessibilityLabel("缩小时间线")
            Slider(value: $zoom, in: 0.5...8).frame(width: 90).accessibilityLabel("时间线缩放")
            Button { zoom = min(8, zoom * 1.4) } label: { Image(systemName: "plus.magnifyingglass") }
                .accessibilityLabel("放大时间线")
            Button("适应") { zoom = 1 }.help("完整显示时间线")
        }
        .font(.system(size: 11, design: .monospaced))
        .buttonStyle(.borderless)
        .padding(.horizontal, 18).frame(height: 44)
    }

    private func trackLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 11))
            .foregroundStyle(palette.textSecondary).frame(maxWidth: .infinity)
    }

    private func grid(width: CGFloat, height: CGFloat, scale: Double) -> some View {
        Canvas { context, size in
            let interval = AssemblyTimelineLayout.tickInterval(scale: scale)
            var path = Path()
            for index in 0...min(2000, Int(layout.duration / interval) + 1) {
                let x = Double(index) * interval * scale
                path.move(to: CGPoint(x: x, y: 28))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(path, with: .color(palette.surface2.opacity(0.35)), lineWidth: 1)
        }.frame(width: width, height: height).allowsHitTesting(false)
    }

    private func ruler(width: CGFloat, scale: Double) -> some View {
        Canvas { context, size in
            let interval = AssemblyTimelineLayout.tickInterval(scale: scale)
            for index in 0...min(10000, Int(layout.duration / (interval / 5)) + 1) {
                let time = Double(index) * interval / 5
                let x = time * scale
                let major = index % 5 == 0
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height - (major ? 9 : 4)))
                tick.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(tick, with: .color(palette.textMuted.opacity(0.6)), lineWidth: 1)
                if major {
                    context.draw(Text(durationLabel(time)).font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.textSecondary),
                        at: CGPoint(x: x + 4, y: 8), anchor: .leading)
                }
            }
        }
        .frame(width: width, height: 28).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { onSeek(layout.time(at: $0.location.x, scale: scale)) })
        .accessibilityLabel("时间标尺，点击或拖动定位")
        .accessibilityIdentifier("assembly.timeline.ruler")
    }

    private func subtitleTrack(width: CGFloat, scale: Double) -> some View {
        ZStack(alignment: .leading) {
            palette.surface1.opacity(0.35)
            ForEach(layout.clips) { clip in
                let material = project.materials[clip.index]
                ForEach(Array(material.subtitles.enumerated()), id: \.offset) { index, subtitle in
                    let key = "\(clip.id)-\(index)"
                    Button {
                        selectedMaterial = clip.id
                        selectedSubtitle = key
                        onSeek(clip.start + subtitle.start)
                    } label: {
                        Text(subtitle.text).font(.system(size: 11)).lineLimit(1)
                            .padding(.horizontal, 7)
                            .frame(width: max(2, (subtitle.end - subtitle.start) * scale - 2), height: 32, alignment: .leading)
                            .foregroundStyle(palette.textPrimary)
                            .background(palette.warning.opacity(selectedSubtitle == key ? 0.38 : 0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.warning.opacity(selectedSubtitle == key ? 0.9 : 0.35)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("字幕：\(subtitle.text)，\(durationLabel(clip.start + subtitle.start))")
                    .offset(x: (clip.start + subtitle.start) * scale)
                }
            }
        }.frame(width: width, height: 34).clipped()
    }

    private func videoTrack(width: CGFloat, scale: Double) -> some View {
        ZStack(alignment: .leading) {
            palette.surface1.opacity(0.35)
            ForEach(layout.clips) { clip in
                let material = project.materials[clip.index]
                let clipWidth = max(2, clip.duration * scale - 2)
                TimelineFilmstrip(url: material.exportState == .complete ? ProjectLayout.picture(material, in: project) : nil,
                    duration: clip.duration)
                    .frame(width: clipWidth, height: 70)
                    .overlay(alignment: .topLeading) {
                        Text("素材 \(clip.index + 1) · \(durationLabel(clip.duration))")
                            .font(.system(size: 10, weight: .medium)).lineLimit(1)
                            .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3)).padding(5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                        dropTarget == clip.id || selectedMaterial == clip.id ? palette.accent : palette.surface3, lineWidth: selectedMaterial == clip.id ? 2 : 1))
                    .contentShape(Rectangle())
                    .onTapGesture { selectedMaterial = clip.id; onSeek(clip.start) }
                    .draggable(clip.id.uuidString)
                    .dropDestination(for: String.self) { values, location in
                        guard let value = values.first, let source = UUID(uuidString: value),
                              source != clip.id, project.materials.contains(where: { $0.id == source }) else { return false }
                        selectedMaterial = source
                        onMove(source, clip.id, location.x > clipWidth / 2)
                        return true
                    } isTargeted: { dropTarget = $0 ? clip.id : nil }
                    .contextMenu {
                        if material.motionState == .failed {
                            Button("重试动效") { onRetryMotion(clip.id) }
                        }
                        Button("向前移动") { if clip.index > 0 { onMove(clip.id, layout.clips[clip.index - 1].id, false) } }.disabled(clip.index == 0)
                        Button("向后移动") { if clip.index + 1 < layout.clips.count { onMove(clip.id, layout.clips[clip.index + 1].id, true) } }.disabled(clip.index + 1 == layout.clips.count)
                    }
                    .accessibilityLabel("素材 \(clip.index + 1)，时长 \(durationLabel(clip.duration))，可拖动排序")
                    .offset(x: clip.start * scale)
            }
        }.frame(width: width, height: 72).clipped()
    }

    private func playheadView(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 12)).frame(height: 16)
            Rectangle().frame(width: 1, height: max(0, height - 16))
        }
        .foregroundStyle(palette.accent)
        .frame(width: 18, height: height)
        .contentShape(Rectangle())
        .accessibilityLabel("播放头")
        .accessibilityValue(AssemblyTimelineLayout.timecode(playhead))
        .accessibilityAdjustableAction { direction in
            onSeek(playhead + (direction == .increment ? 1 / 30 : -1 / 30))
        }
    }
}

private struct TimelineFilmstrip: View {
    let url: URL?
    let duration: Double
    @State private var frames: [NSImage] = []
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if frames.isEmpty {
                    Color.black.opacity(0.7).overlay { Image(systemName: "film").foregroundStyle(.white.opacity(0.5)) }
                } else {
                    ForEach(frames.indices, id: \.self) { index in
                        Image(nsImage: frames[index]).resizable().scaledToFill()
                            .frame(width: geometry.size.width / CGFloat(frames.count), height: geometry.size.height).clipped()
                    }
                }
            }
        }
        .task(id: url) {
            frames = []
            guard let url, duration > 0 else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 140)
            let count = min(12, max(1, Int(ceil(duration / 3))))
            var images: [NSImage] = []
            for index in 0..<count {
                guard !Task.isCancelled else { return }
                if let frame = try? await generator.image(at: CMTime(seconds: duration * (Double(index) + 0.1) / Double(count), preferredTimescale: 600)) {
                    images.append(NSImage(cgImage: frame.image, size: .zero))
                }
            }
            if !Task.isCancelled { frames = images }
        }
    }
}
