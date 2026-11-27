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

/// One read-only AI-generated motion overlay/shot displayed over the original recording
/// inside the Rough Cutting Panel after AI motion has been generated.
/// Clicking a clip opens an AI refinement prompt popover to ask AI to modify that animation.
public struct RoughCutMotionClip: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case overlay
        case shot
        case full
    }

    public let id: String
    /// Raw manifest target ID (e.g. `"O2Run"`, `"Act1"`) used for shot-level AI refinement.
    public let targetID: String
    public let title: String
    public let kind: Kind
    public let start: Double
    public let end: Double
    public let mediaPath: String
    public let x: Double?
    public let y: Double?
    public let width: Double?
    public let height: Double?

    public init(
        id: String,
        targetID: String = "",
        title: String,
        kind: Kind,
        start: Double,
        end: Double,
        mediaPath: String,
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil
    ) {
        self.id = id
        self.targetID = targetID
        self.title = title
        self.kind = kind
        self.start = start
        self.end = end
        self.mediaPath = mediaPath
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var duration: Double { max(0, end - start) }
    public var mediaURL: URL { URL(fileURLWithPath: mediaPath) }

    public func contains(time: Double) -> Bool {
        time >= start && time <= end && end > start
    }
}

public struct RoughCutMotionLayerContext: Codable, Equatable, Sendable {
    public let materialID: UUID
    public let clips: [RoughCutMotionClip]
    public let canvasWidth: Double?
    public let canvasHeight: Double?

    public init(
        materialID: UUID,
        clips: [RoughCutMotionClip],
        canvasWidth: Double? = nil,
        canvasHeight: Double? = nil
    ) {
        self.materialID = materialID
        self.clips = clips
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
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

/// Manages the read-only AI Motion overlay layer inside the Rough Cutting Panel.
/// Active only when resuming a material that already has AI motion outputs.
/// Supports click-to-prompt AI shot refinement with live hot-reload on completion.
@MainActor
public final class RoughCutMotionLayerStore: ObservableObject {
    public static let shared = RoughCutMotionLayerStore()

    @Published public private(set) var context: RoughCutMotionLayerContext?
    @Published public var isLayerVisible: Bool = true {
        didSet {
            if !isLayerVisible {
                currentFrameImage = nil
                currentActiveClip = nil
                lastEvaluatedKey = nil
            }
        }
    }
    @Published public var selectedClipID: String?
    @Published public var promptClipID: String?
    @Published public var refiningClipID: String?
    @Published public var refiningStatusMessage: String?
    @Published public var refiningErrorMessage: String?
    @Published public private(set) var currentFrameImage: NSImage?
    @Published public private(set) var currentActiveClip: RoughCutMotionClip?

    /// Host callback invoked when the user submits an AI refinement prompt for a specific motion clip.
    public var onRequestRefinement: ((RoughCutMotionClip, String) -> Void)?

    private let decoder = MotionFrameDecoder()
    private var lastEvaluatedKey: String?
    private var lastOutputTime: Double = 0
    private var frameTask: Task<Void, Never>?

    private init() {}

    public var hasMotionLayer: Bool {
        guard let context else { return false }
        return !context.clips.isEmpty
    }

    public func load(_ next: RoughCutMotionLayerContext?) {
        frameTask?.cancel()
        frameTask = nil
        lastEvaluatedKey = nil
        currentFrameImage = nil
        currentActiveClip = nil
        context = next
        isLayerVisible = true
        selectedClipID = nil
        promptClipID = nil
        refiningClipID = nil
        refiningStatusMessage = nil
        refiningErrorMessage = nil
        let decoder = self.decoder
        Task { await decoder.reset() }
    }

    /// Hot-reloads updated AI motion clips after a background refinement completes
    /// while keeping the Rough Cutting Panel open.
    public func reloadAfterRefinement(_ next: RoughCutMotionLayerContext?) {
        frameTask?.cancel()
        frameTask = nil
        lastEvaluatedKey = nil
        currentFrameImage = nil
        currentActiveClip = nil
        context = next
        refiningClipID = nil
        refiningStatusMessage = nil
        refiningErrorMessage = nil
        let decoder = self.decoder
        let timeToRefresh = lastOutputTime
        Task {
            await decoder.reset()
            await MainActor.run {
                self.updateFrame(at: timeToRefresh)
            }
        }
    }

    public func clear() {
        onRequestRefinement = nil
        load(nil)
    }

    public func activeClip(at outputTime: Double) -> RoughCutMotionClip? {
        guard let context, isLayerVisible else { return nil }
        // Prefer transparent overlays over fullscreen shots/full track if overlapping.
        let matching = context.clips.filter { $0.contains(time: outputTime) }
        return matching.first(where: { $0.kind == .overlay }) ?? matching.first
    }

    public func submitRefinement(for clip: RoughCutMotionClip, instruction: String) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        refiningClipID = clip.id
        refiningStatusMessage = "已派发 AI 修改「\(clip.title)」…"
        refiningErrorMessage = nil
        promptClipID = nil
        onRequestRefinement?(clip, trimmed)
    }

    public func updateRefinementProgress(_ message: String?) {
        guard refiningClipID != nil else { return }
        refiningStatusMessage = message
    }

    public func failRefinement(_ errorMessage: String) {
        refiningClipID = nil
        refiningStatusMessage = nil
        refiningErrorMessage = errorMessage
    }

    public func updateFrame(at outputTime: Double) {
        lastOutputTime = outputTime
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
        let cacheKey = "\(clip.id)#\(clip.mediaPath)#\(quantized)"
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

/// Read-only real-time AI Motion overlay rendered directly on top of the Rough Cutting Panel canvas.
/// The underlying recorded video stays untouched underneath.
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
                    } else {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
        .onAppear { store.updateFrame(at: outputTime) }
        .onChange(of: outputTime) { _, next in store.updateFrame(at: next) }
        .onChange(of: store.context) { _, _ in store.updateFrame(at: outputTime) }
        .onChange(of: store.isLayerVisible) { _, _ in store.updateFrame(at: outputTime) }
    }
}

/// First-class native AI Motion timeline track lane at the same peer level as Zoom / 3D / Overlay.
/// Strictly read-only: clicking any clip jumps the playhead and opens a popover to ask AI to modify that animation.
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
                if motionLayerStore.refiningClipID != nil {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.trailing, 6)
                        .help(motionLayerStore.refiningStatusMessage ?? "正在修改动效…")
                } else {
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
                    .help(motionLayerStore.isLayerVisible ? "暂时隐藏 AI 动效覆盖层" : "显示 AI 动效覆盖层")
                    .accessibilityLabel(motionLayerStore.isLayerVisible ? "隐藏 AI 动效覆盖层" : "显示 AI 动效覆盖层")
                    .padding(.trailing, 6)
                }
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
                let isRefining = motionLayerStore.refiningClipID == clip.id
                let isPromptOpen = Binding<Bool>(
                    get: { motionLayerStore.promptClipID == clip.id },
                    set: { open in
                        if !open, motionLayerStore.promptClipID == clip.id {
                            motionLayerStore.promptClipID = nil
                        }
                    }
                )

                Button {
                    motionLayerStore.selectedClipID = clip.id
                    if playbackTime < clip.start || playbackTime > clip.end {
                        seekTimeline(to: clip.start + min(0.25, clip.duration * 0.25))
                    }
                    motionLayerStore.promptClipID = clip.id
                } label: {
                    aiMotionClipBar(
                        clip: clip,
                        barWidth: clipWidth,
                        isSelected: isSelected,
                        isVisible: layerVisible,
                        isRefining: isRefining
                    )
                }
                .buttonStyle(EditorToolbarPressButtonStyle())
                .offset(x: startX)
                .popover(isPresented: isPromptOpen, arrowEdge: .top) {
                    AIMotionRefinePopover(
                        clip: clip,
                        store: motionLayerStore,
                        tint: aiMotionTint
                    )
                }
            }
        }
        .frame(width: width, height: aiMotionTimelineHeight, alignment: .leading)
    }

    private func aiMotionClipBar(
        clip: RoughCutMotionClip,
        barWidth: CGFloat,
        isSelected: Bool,
        isVisible: Bool,
        isRefining: Bool
    ) -> some View {
        let fillOpacity: Double = isVisible ? (isSelected ? 0.30 : 0.18) : 0.08
        let strokeOpacity: Double = isVisible ? (isSelected ? 0.92 : 0.48) : 0.22
        return HStack(spacing: 4) {
            if isRefining {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: clip.kind == .overlay ? "sparkles" : "film")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isVisible ? aiMotionTint : EditorTheme.secondaryText.opacity(0.6))
            }
            if barWidth >= 46 {
                Text(clip.title)
                    .font(.appUI(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isVisible ? EditorTheme.primaryText : EditorTheme.secondaryText)
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
        .opacity(isVisible ? 1.0 : 0.55)
        .help("\(clip.title) (\(String(format: "%.1f–%.1fs", clip.start, clip.end))) · 点击让 AI 修改这段动画")
    }
}

/// Popover opened when clicking a read-only AI motion clip on the Rough Cutting Panel timeline.
/// Lets the user describe how AI should revise that specific animation segment.
private struct AIMotionRefinePopover: View {
    let clip: RoughCutMotionClip
    @ObservedObject var store: RoughCutMotionLayerStore
    let tint: Color

    @State private var instruction = ""

    private var isRefiningAny: Bool {
        store.refiningClipID != nil
    }

    private var kindBadge: String {
        switch clip.kind {
        case .overlay: return "透明覆盖层"
        case .shot: return "全屏动效"
        case .full: return "AI 动效层"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                Text(clip.title)
                    .font(.appUI(size: 13, weight: .semibold))
                    .foregroundStyle(EditorTheme.primaryText)
                Text(kindBadge)
                    .font(.appUI(size: 10, weight: .medium))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.16), in: Capsule())
                Spacer(minLength: 8)
                Text(String(format: "%.1f–%.1fs", clip.start, clip.end))
                    .font(.appUI(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(EditorTheme.secondaryText)
            }

            Text("此动效为只读覆盖层，底层原画面完整保留。直接告诉 AI 如何修改这段动画：")
                .font(.appUI(size: 11))
                .foregroundStyle(EditorTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if isRefiningAny {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(store.refiningStatusMessage ?? "AI 正在重新生成该段动画…")
                        .font(.appUI(size: 12))
                        .foregroundStyle(tint)
                }
                .padding(.vertical, 4)
            } else {
                TextEditor(text: $instruction)
                    .font(.appUI(size: 12))
                    .foregroundStyle(EditorTheme.primaryText)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 76)
                    .background(EditorTheme.controlWell, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(EditorTheme.hairline, lineWidth: 1)
                    }
                    .overlay(alignment: .topLeading) {
                        if instruction.isEmpty {
                            Text("例如：把标题字号放大、节奏加快一点、换成更明亮的配色")
                                .font(.appUI(size: 12))
                                .foregroundStyle(EditorTheme.secondaryText.opacity(0.65))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .allowsHitTesting(false)
                        }
                    }

                if let error = store.refiningErrorMessage {
                    Text(error)
                        .font(.appUI(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("取消") {
                        store.promptClipID = nil
                    }
                    .buttonStyle(EditorToolbarPressButtonStyle())
                    .font(.appUI(size: 12, weight: .medium))
                    .foregroundStyle(EditorTheme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(EditorTheme.controlWell, in: Capsule())

                    Spacer()

                    Button {
                        store.submitRefinement(for: clip, instruction: instruction)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11, weight: .semibold))
                            Text("让 AI 修改动画")
                        }
                    }
                    .buttonStyle(EditorPrimaryPillButtonStyle())
                    .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(EditorTheme.panelSurface)
    }
}
