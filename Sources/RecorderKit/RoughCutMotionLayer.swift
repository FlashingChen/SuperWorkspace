import AppKit
import AVFoundation
import CoreImage
import Foundation
import RecorderCore
import StudioTheme
import SwiftUI

/// Helper for archiving and creating `.dogscproject` rough-cut packages
/// stored inside each SuperWorkspace material directory (`roughcut.dogscproject`).
public enum RoughCutPackageHelper {
    /// Ensures a valid `.dogscproject` package exists at `packageURL`.
    /// If missing (e.g. legacy material with only `source.mp4`), wraps `fallbackSourceURL`
    /// into a minimal valid package so it can be opened directly in the Rough Cutting Panel.
    @discardableResult
    public static func ensurePackage(
        at packageURL: URL,
        fallbackSourceURL: URL,
        title: String
    ) throws -> URL {
        let projectJSON = packageURL.appendingPathComponent("project.json")
        if FileManager.default.fileExists(atPath: projectJSON.path) {
            return packageURL
        }
        guard FileManager.default.fileExists(atPath: fallbackSourceURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fm = FileManager.default
        let mediaDir = packageURL.appendingPathComponent("media", isDirectory: true)
        let eventsDir = packageURL.appendingPathComponent("events", isDirectory: true)
        let recoveryDir = packageURL.appendingPathComponent("recovery", isDirectory: true)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: recoveryDir, withIntermediateDirectories: true)

        let session = RecordingSession(packageURL: packageURL)
        if fm.fileExists(atPath: session.screenRecordingURL.path) {
            try fm.removeItem(at: session.screenRecordingURL)
        }
        try fm.copyItem(at: fallbackSourceURL, to: session.screenRecordingURL)

        var project = RecorderProject()
        project.title = title.isEmpty ? "未命名素材" : title
        project.media = ProjectMediaManifest(
            screen: ProjectMediaReference(relativePath: "media/\(session.screenRecordingURL.lastPathComponent)")
        )
        try ProjectStore.saveProject(project, session: session)
        return packageURL
    }

    /// Saves a full non-destructive rough-cut package from a headless recording
    /// (preserving raw screen video, pointer events, auto-zooms, and canvas style).
    static func saveHeadlessPackage(
        at packageURL: URL,
        rawScreenURL: URL,
        project: RecorderProject,
        pointerEvents: [PointerEventRecord]
    ) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: packageURL.path) {
            try fm.removeItem(at: packageURL)
        }
        let mediaDir = packageURL.appendingPathComponent("media", isDirectory: true)
        let eventsDir = packageURL.appendingPathComponent("events", isDirectory: true)
        let recoveryDir = packageURL.appendingPathComponent("recovery", isDirectory: true)
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: recoveryDir, withIntermediateDirectories: true)

        let session = RecordingSession(packageURL: packageURL)
        try fm.copyItem(at: rawScreenURL, to: session.screenRecordingURL)

        var archived = project
        archived.media = ProjectMediaManifest(
            screen: ProjectMediaReference(relativePath: "media/\(session.screenRecordingURL.lastPathComponent)"),
            pointerEvents: pointerEvents.isEmpty
                ? nil
                : ProjectMediaReference(relativePath: "events/\(session.pointerEventsURL.lastPathComponent)")
        )
        if !pointerEvents.isEmpty {
            try ProjectStore.savePointerEvents(pointerEvents, session: session)
        }
        try ProjectStore.saveProject(archived, session: session)
    }

    /// Copies an existing `.dogscproject` package to an archive destination inside a material directory.
    static func archivePackage(from sourceURL: URL, to destinationURL: URL) throws {
        let src = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let dst = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        guard src != dst else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) {
            try fm.removeItem(at: dst)
        }
        try fm.copyItem(at: src, to: dst)
    }
}

/// One AI-generated motion segment (transparent overlay, fullscreen shot, or full motion track)
/// displayed and editable in the Rough Cutting Panel after AI motion has been generated.
public struct RoughCutMotionClip: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case overlay
        case shot
        case full
    }

    public var id: String
    public var title: String
    public var kind: Kind
    public var start: Double
    public var end: Double
    public var mediaPath: String
    public var x: Double?
    public var y: Double?
    public var width: Double?
    public var height: Double?
    public var isEnabled: Bool
    public var opacity: Double

    public init(
        id: String,
        title: String,
        kind: Kind,
        start: Double,
        end: Double,
        mediaPath: String,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil,
        isEnabled: Bool = true,
        opacity: Double = 1.0
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.start = start
        self.end = end
        self.mediaPath = mediaPath
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isEnabled = isEnabled
        self.opacity = opacity
    }

    public var duration: Double { max(0, end - start) }
    public var mediaURL: URL { URL(fileURLWithPath: mediaPath) }

    public func contains(time: Double) -> Bool {
        isEnabled && time >= start && time <= end && end > start
    }
}

public struct RoughCutMotionLayerContext: Codable, Equatable, Sendable {
    public let materialID: UUID
    public var clips: [RoughCutMotionClip]
    public var isLayerVisible: Bool
    public var canvasWidth: Double?
    public var canvasHeight: Double?
    public var persistencePath: String?

    public init(
        materialID: UUID,
        clips: [RoughCutMotionClip],
        isLayerVisible: Bool = true,
        canvasWidth: Double? = nil,
        canvasHeight: Double? = nil,
        persistencePath: String? = nil
    ) {
        self.materialID = materialID
        self.clips = clips
        self.isLayerVisible = isLayerVisible
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.persistencePath = persistencePath
    }
}

private actor MotionFrameDecoder {
    private var assets: [String: AVURLAsset] = [:]

    func reset() {
        assets.removeAll()
    }

    func decodeFrame(mediaPath: String, at seconds: Double) async throws -> CGImage {
        let asset: AVURLAsset
        if let existing = assets[mediaPath] {
            asset = existing
        } else {
            let created = AVURLAsset(url: URL(fileURLWithPath: mediaPath))
            assets[mediaPath] = created
            asset = created
        }
        return try await Self.extractImage(from: asset, at: seconds)
    }

    private nonisolated static func extractImage(from asset: AVURLAsset, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        let cmTime = CMTime(seconds: seconds, preferredTimescale: 600)
        let (cgImage, _) = try await generator.image(at: cmTime)
        return cgImage
    }
}

/// Manages the active AI Motion Layer inside the Rough Cutting Panel.
/// Only active when resuming a material that already has AI motion outputs.
@MainActor
public final class RoughCutMotionLayerStore: ObservableObject {
    public static let shared = RoughCutMotionLayerStore()

    @Published public private(set) var context: RoughCutMotionLayerContext?
    @Published public var selectedClipID: String?
    @Published public private(set) var currentFrameImage: NSImage?
    @Published public private(set) var currentActiveClip: RoughCutMotionClip?

    private let decoder = MotionFrameDecoder()
    private var lastEvaluatedKey: String?
    private var frameTask: Task<Void, Never>?

    private init() {}

    public var hasMotionLayer: Bool {
        guard let context else { return false }
        return !context.clips.isEmpty
    }

    public var isLayerVisible: Bool {
        get { context?.isLayerVisible ?? false }
        set {
            guard context != nil else { return }
            context?.isLayerVisible = newValue
            if !newValue {
                currentFrameImage = nil
                currentActiveClip = nil
            }
            persist()
        }
    }

    public var selectedClip: RoughCutMotionClip? {
        guard let id = selectedClipID else { return nil }
        return context?.clips.first { $0.id == id }
    }

    public func load(_ next: RoughCutMotionLayerContext?) {
        frameTask?.cancel()
        frameTask = nil
        lastEvaluatedKey = nil
        currentFrameImage = nil
        currentActiveClip = nil
        context = next
        selectedClipID = next?.clips.first?.id
        let decoder = self.decoder
        Task { await decoder.reset() }
    }

    public func clear() {
        load(nil)
    }

    public func activeClip(at outputTime: Double) -> RoughCutMotionClip? {
        guard let context, context.isLayerVisible else { return nil }
        // Prefer transparent overlays over fullscreen shots/full track if overlapping.
        let matching = context.clips.filter { $0.contains(time: outputTime) }
        return matching.first(where: { $0.kind == .overlay }) ?? matching.first
    }

    public func toggleClipEnabled(_ id: String) {
        mutateClip(id) { $0.isEnabled.toggle() }
    }

    public func setClipOpacity(_ id: String, opacity: Double) {
        mutateClip(id) { $0.opacity = min(max(opacity, 0.05), 1.0) }
    }

    public func nudgeClip(_ id: String, delta: Double, maxDuration: Double) {
        mutateClip(id) { clip in
            let span = clip.end - clip.start
            let nextStart = min(max(0, clip.start + delta), max(0, maxDuration - span))
            clip.start = nextStart
            clip.end = nextStart + span
        }
    }

    public func setClipRange(_ id: String, start: Double, end: Double) {
        mutateClip(id) { clip in
            clip.start = max(0, start)
            clip.end = max(clip.start + 0.05, end)
        }
    }

    private func mutateClip(_ id: String, _ transform: (inout RoughCutMotionClip) -> Void) {
        guard var current = context,
              let idx = current.clips.firstIndex(where: { $0.id == id }) else { return }
        transform(&current.clips[idx])
        context = current
        lastEvaluatedKey = nil
        persist()
    }

    private func persist() {
        guard let current = context, let path = current.persistencePath else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(current) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    public func updateFrame(at outputTime: Double) {
        guard let clip = activeClip(at: outputTime) else {
            if currentFrameImage != nil || currentActiveClip != nil {
                currentFrameImage = nil
                currentActiveClip = nil
                lastEvaluatedKey = nil
            }
            return
        }
        let localTime = clip.kind == .full ? outputTime : max(0, outputTime - clip.start)
        let quantized = Int((localTime * 24).rounded())
        let cacheKey = "\(clip.id)#\(quantized)"
        guard cacheKey != lastEvaluatedKey else { return }
        lastEvaluatedKey = cacheKey
        currentActiveClip = clip

        let mediaPath = clip.mediaPath
        let decodeSeconds = Double(quantized) / 24.0
        let decoder = self.decoder
        frameTask?.cancel()
        frameTask = Task { [weak self] in
            do {
                let cgImage = try await decoder.decodeFrame(mediaPath: mediaPath, at: decodeSeconds)
                guard !Task.isCancelled else { return }
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                await MainActor.run {
                    guard let self, self.lastEvaluatedKey == cacheKey else { return }
                    self.currentFrameImage = nsImage
                }
            } catch {
                // Keep last valid frame on transient scrub cancellation.
            }
        }
    }
}

/// Real-time AI Motion overlay rendered directly on top of the Rough Cutting Panel canvas.
struct RoughCutMotionOverlayView: View {
    @ObservedObject var store: RoughCutMotionLayerStore
    let outputTime: TimeInterval

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if store.hasMotionLayer,
                   store.isLayerVisible,
                   let clip = store.currentActiveClip,
                   let image = store.currentFrameImage {
                    if clip.kind == .overlay,
                       let x = clip.x, let y = clip.y,
                       let w = clip.width, let h = clip.height,
                       w > 0, h > 0 {
                        let refW = max(1, store.context?.canvasWidth ?? 1920)
                        let refH = max(1, store.context?.canvasHeight ?? 1080)
                        let rectW = w <= 1.0 ? w * geo.size.width : geo.size.width * min(1, w / refW)
                        let rectH = h <= 1.0 ? h * geo.size.height : geo.size.height * min(1, h / refH)
                        let rectX = x <= 1.0 ? x * geo.size.width : geo.size.width * (x / refW)
                        let rectY = y <= 1.0 ? y * geo.size.height : geo.size.height * (y / refH)
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: rectW, height: rectH)
                            .position(x: rectX + rectW / 2, y: rectY + rectH / 2)
                            .opacity(clip.opacity)
                    } else {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .opacity(clip.opacity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
        .onAppear { store.updateFrame(at: outputTime) }
        .onChange(of: outputTime) { _, next in store.updateFrame(at: next) }
        .onChange(of: store.context) { _, _ in store.updateFrame(at: outputTime) }
    }
}

/// First-class native AI Motion timeline track lane at the same peer level as Zoom / 3D / Overlay.
/// Appears inside `EditorTimelineView` ONLY when resuming a material that already has AI motion outputs.
extension EditorTimelineView {
    var aiMotionTint: Color {
        StudioTokens.adaptive(light: StudioTokens.Light.aiNS, dark: StudioTokens.Dark.aiNS)
    }

    var aiMotionTrackLabel: some View {
        HStack(spacing: 4) {
            EditorTimelineLaneLabel(
                title: "AI 动效",
                symbol: "sparkles",
                tint: aiMotionTint,
                horizontalInset: layout.value(regular: 12, compact: 6),
                collapsed: timelineLabelsCollapsed
            )
            if !timelineLabelsCollapsed {
                Button {
                    motionLayerStore.isLayerVisible.toggle()
                } label: {
                    Image(systemName: motionLayerStore.isLayerVisible ? "eye" : "eye.slash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(
                            motionLayerStore.isLayerVisible
                                ? EditorTheme.primaryText.opacity(0.72)
                                : EditorTheme.secondaryText.opacity(0.45)
                        )
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(EditorToolbarPressButtonStyle())
                .help(motionLayerStore.isLayerVisible ? "隐藏 AI 动效层" : "显示 AI 动效层")
                .accessibilityLabel(motionLayerStore.isLayerVisible ? "隐藏 AI 动效层" : "显示 AI 动效层")
                .padding(.trailing, 6)
            }
        }
        .frame(height: aiMotionTimelineHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI 动效轨道")
    }

    func aiMotionTimeline(width: CGFloat, duration: TimeInterval) -> some View {
        let clips = motionLayerStore.context?.clips ?? []
        let safeDuration = max(duration, 0.001)
        let layerVisible = motionLayerStore.isLayerVisible

        return ZStack(alignment: .leading) {
            timelineLaneSurface(
                tint: aiMotionTint,
                isFocused: focusedTimelineLane == .aiMotion
            )
            ForEach(clips) { clip in
                let startX = CGFloat(clip.start / safeDuration) * width
                let clipWidth = max(
                    CGFloat((clip.end - clip.start) / safeDuration) * width,
                    22
                )
                let isSelected = motionLayerStore.selectedClipID == clip.id
                let isActive = layerVisible && clip.isEnabled

                aiMotionClipBar(
                    clip: clip,
                    barWidth: clipWidth,
                    isSelected: isSelected,
                    isActive: isActive
                )
                .offset(x: startX)
                .onTapGesture {
                    motionLayerStore.selectedClipID = clip.id
                    if playbackTime < clip.start || playbackTime > clip.end {
                        seekTimeline(to: clip.start + min(0.25, clip.duration * 0.25))
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            if aiMotionDragOrigin == nil {
                                aiMotionDragOrigin = (clip.id, clip.start, clip.end)
                                motionLayerStore.selectedClipID = clip.id
                            }
                            guard let origin = aiMotionDragOrigin, origin.id == clip.id else { return }
                            let deltaSeconds = Double(value.translation.width / max(width, 1)) * safeDuration
                            let span = origin.end - origin.start
                            let nextStart = min(max(0, origin.start + deltaSeconds), max(0, safeDuration - span))
                            motionLayerStore.setClipRange(clip.id, start: nextStart, end: nextStart + span)
                        }
                        .onEnded { _ in
                            aiMotionDragOrigin = nil
                        }
                )
                .contextMenu {
                    Button(clip.isEnabled ? "停用此动效" : "启用此动效") {
                        motionLayerStore.toggleClipEnabled(clip.id)
                    }
                    Button("前移 0.1 秒") {
                        motionLayerStore.nudgeClip(clip.id, delta: -0.1, maxDuration: safeDuration)
                    }
                    Button("后移 0.1 秒") {
                        motionLayerStore.nudgeClip(clip.id, delta: 0.1, maxDuration: safeDuration)
                    }
                    Menu("不透明度（\(Int((clip.opacity * 100).rounded()))%）") {
                        ForEach([1.0, 0.85, 0.7, 0.5, 0.3], id: \.self) { level in
                            Button("\(Int((level * 100).rounded()))%") {
                                motionLayerStore.setClipOpacity(clip.id, opacity: level)
                            }
                        }
                    }
                    Divider()
                    Button(layerVisible ? "隐藏整个 AI 动效层" : "显示整个 AI 动效层") {
                        motionLayerStore.isLayerVisible.toggle()
                    }
                }
            }
        }
        .frame(width: width, height: aiMotionTimelineHeight, alignment: .leading)
    }

    private func aiMotionClipBar(
        clip: RoughCutMotionClip,
        barWidth: CGFloat,
        isSelected: Bool,
        isActive: Bool
    ) -> some View {
        let fillOpacity: Double = isActive ? (isSelected ? 0.30 : 0.18) : 0.08
        let strokeOpacity: Double = isActive ? (isSelected ? 0.92 : 0.48) : 0.22
        return HStack(spacing: 4) {
            Image(systemName: clip.kind == .overlay ? "sparkles" : "film")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isActive ? aiMotionTint : EditorTheme.secondaryText.opacity(0.6))
            if barWidth >= 46 {
                Text(clip.title)
                    .font(.appUI(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isActive ? EditorTheme.primaryText : EditorTheme.secondaryText)
                    .lineLimit(1)
            }
            if barWidth >= 110 {
                Text(String(format: "%.1fs", clip.duration))
                    .font(.appUI(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(EditorTheme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, barWidth >= 40 ? 7 : 4)
        .frame(width: barWidth, height: zoomBarHeight, alignment: .leading)
        .background(
            aiMotionTint.opacity(fillOpacity),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(aiMotionTint.opacity(strokeOpacity), lineWidth: isSelected ? 1.5 : 1)
        }
        .opacity(isActive ? 1.0 : 0.55)
        .help("\(clip.title) (\(String(format: "%.1f–%.1fs", clip.start, clip.end))) · 拖动调整时间，右键更多选项")
    }
}
