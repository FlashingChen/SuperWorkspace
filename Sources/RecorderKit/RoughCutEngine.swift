import AppKit
import AVFoundation
import CoreImage
import Foundation
import RecorderCore

/// Disk representation of a clip's non-destructive rough-cut package (`roughcut.dogscproject`).
public struct RoughCutLoadedPackage: Sendable {
    public let packageURL: URL
    public let project: RecorderProject
    public let screenURL: URL?
    public let cameraURL: URL?
    public let microphoneURL: URL?
    public let pointerEvents: [PointerEventRecord]
}

/// Manages loading, saving, archiving, and bootstrapping `.dogscproject` packages
/// stored inside each SuperWorkspace material directory (`materials/<mediaID>/roughcut.dogscproject`).
public enum RoughCutPackageStore {
    public static func load(at packageURL: URL) -> RoughCutLoadedPackage? {
        guard FileManager.default.fileExists(atPath: packageURL.appendingPathComponent("project.json").path),
              let loaded = try? ProjectStore.loadProject(at: packageURL) else {
            return nil
        }
        let session = loaded.session
        let screenURL = ProjectStore.resolve(
            relativePath: loaded.project.media?.screen.relativePath,
            session: session
        )
        let cameraURL = ProjectStore.resolve(
            relativePath: loaded.project.media?.camera?.relativePath,
            session: session
        )
        let microphoneURL = ProjectStore.resolve(
            relativePath: loaded.project.media?.microphone?.relativePath,
            session: session
        )
        let pointerEvents: [PointerEventRecord]
        if ProjectStore.resolve(
            relativePath: loaded.project.media?.pointerEvents?.relativePath,
            session: session
        ) != nil {
            pointerEvents = (try? ProjectStore.loadPointerEvents(session: session)) ?? []
        } else {
            pointerEvents = []
        }
        return RoughCutLoadedPackage(
            packageURL: packageURL,
            project: loaded.project,
            screenURL: screenURL,
            cameraURL: cameraURL,
            microphoneURL: microphoneURL,
            pointerEvents: pointerEvents
        )
    }

    public static func save(_ project: RecorderProject, at packageURL: URL) throws {
        let session = RecordingSession(packageURL: packageURL)
        try ProjectStore.saveProject(project, session: session)
    }

    /// Ensures a valid `.dogscproject` package exists for any material (including legacy materials
    /// that only have `source.mp4`). Uses APFS clone / hardlink / copy without modifying `fallbackSourceURL`.
    @discardableResult
    public static func ensurePackage(
        at packageURL: URL,
        fallbackSourceURL: URL,
        title: String
    ) throws -> RoughCutLoadedPackage {
        if let existing = load(at: packageURL) {
            return existing
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
        project.canvas.padding = 0
        project.canvas.cornerRadius = 0
        project.canvas.shadowStrength = 0
        project.cursorStyle.assetID = .hidden
        project.media = ProjectMediaManifest(
            screen: ProjectMediaReference(relativePath: "media/\(session.screenRecordingURL.lastPathComponent)")
        )
        try ProjectStore.saveProject(project, session: session)
        return RoughCutLoadedPackage(
            packageURL: packageURL,
            project: project,
            screenURL: session.screenRecordingURL,
            cameraURL: nil,
            microphoneURL: nil,
            pointerEvents: []
        )
    }

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

    public static func archivePackage(from sourceURL: URL, to destinationURL: URL) throws {
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

    @MainActor
    public static func defaultStyledBackground() -> BackgroundSource {
        SystemWallpaperLibrary.currentBackgroundSource() ?? .dynamicFlow(.auroraFluid)
    }
}

/// Real-time, stateless Core Image compositor that evaluates a `RecorderProject`
/// (background/wallpaper, padding, corners, shadow, bezel, Auto-Zoom, vector cursor,
/// 3D screen motion, camera PiP, mosaic) inside SuperWorkspace's unified `AssemblyCompositor`.
public final class RoughCutFrameCompositor: @unchecked Sendable {
    private let project: RecorderProject
    private let outputDuration: Double
    private let frameRate: Int
    private let wallpaperImage: CIImage?
    private let cursorSources: [CursorAssetID: CursorRenderSource]
    private let cursorMetricsByAssetID: [CursorAssetID: CursorAssetMetrics]
    private let pointerTrack: ProjectPointerTrack?
    private let zoomTrack: ZoomAnimationTrack
    private let screenMotionTrack: ScreenMotionTrack
    private let cameraMotionTrack: CameraMotionTrack
    private let stickerTrack: StickerTransitionTrack

    public init(
        project: RecorderProject,
        packageURL: URL?,
        pointerEvents: [PointerEventRecord],
        outputDuration: Double,
        frameRate: Int = 60
    ) {
        self.project = project
        self.outputDuration = max(outputDuration, 0.001)
        self.frameRate = max(frameRate, 1)

        var resolvedWallpaper: CIImage?
        switch project.canvas.backgroundSource {
        case let .systemImage(path):
            resolvedWallpaper = CIImage(contentsOf: URL(fileURLWithPath: path))
        case let .projectImage(relativePath):
            if let packageURL {
                let url = packageURL.appendingPathComponent(relativePath)
                resolvedWallpaper = CIImage(contentsOf: url)
            }
        default:
            resolvedWallpaper = nil
        }
        self.wallpaperImage = resolvedWallpaper

        let sources: [CursorAssetID: CursorRenderSource] = Dictionary(
            uniqueKeysWithValues: CursorAssetLibrary.renderAssets.compactMap { asset in
                guard asset.id != .automatic, let source = asset.renderSource() else { return nil }
                return (asset.id, source)
            }
        )
        self.cursorSources = sources
        self.cursorMetricsByAssetID = sources.mapValues(\.metrics)
        if let map = try? TimelineMap(sourceSequence: project.timeline.sourceSequence, fullSourceDuration: self.outputDuration) {
            self.pointerTrack = ProjectPointerTrack(timelineMap: map, sourceEvents: pointerEvents)
        } else {
            self.pointerTrack = nil
        }
        self.zoomTrack = ZoomAnimationTrack(project.zoomAnimations, outputDuration: self.outputDuration)
        self.screenMotionTrack = ScreenMotionTrack(project.timeline.screenMotionClips)
        self.cameraMotionTrack = CameraMotionTrack(project.timeline.cameraMotionClips)
        self.stickerTrack = StickerTransitionTrack(project.timeline.stickerClips)
    }

    /// Evaluates the full `RecorderCore` frame scene at `sourceTime` and composites it into `canvasSize`.
    public func render(
        screenFrame: CIImage,
        cameraFrame: CIImage? = nil,
        at sourceTime: Double,
        canvasSize: CGSize
    ) -> CIImage? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let normalizedScreen = screenFrame.transformed(
            by: CGAffineTransform(
                translationX: -screenFrame.extent.minX,
                y: -screenFrame.extent.minY
            )
        )
        let normalizedCamera = cameraFrame.map { cam in
            cam.transformed(
                by: CGAffineTransform(
                    translationX: -cam.extent.minX,
                    y: -cam.extent.minY
                )
            )
        }
        let aspectRatio = normalizedScreen.extent.width / max(normalizedScreen.extent.height, 1)
        let clampedTime = min(max(sourceTime, 0), outputDuration)
        let renderPlan = FrameSceneEvaluator.renderPlan(
            project: project,
            presentationTime: clampedTime,
            outputDuration: outputDuration,
            frameRate: frameRate,
            canvasSize: CompositionSize(width: canvasSize.width, height: canvasSize.height),
            sourceAspectRatio: aspectRatio,
            cameraSourceSize: normalizedCamera.map {
                CompositionSize(width: $0.extent.width, height: $0.extent.height)
            },
            pointerTrack: pointerTrack,
            cursorMetrics: cursorSources[project.cursorStyle.assetID]?.metrics,
            cursorMetricsByAssetID: cursorMetricsByAssetID,
            zoomTrack: zoomTrack,
            screenMotionTrack: screenMotionTrack,
            cameraMotionTrack: cameraMotionTrack,
            stickerTrack: stickerTrack
        )
        let cursorSource = renderPlan.scene.cursor.flatMap { cursorSources[$0.assetID] }
        let resources = SharedFrameRenderResources(
            screen: normalizedScreen,
            camera: normalizedCamera,
            wallpaper: wallpaperImage,
            cursor: cursorSource?.image,
            stickers: [:]
        )
        return SharedFrameCompositor.composite(
            renderPlan,
            resources: resources,
            extent: CGRect(origin: .zero, size: canvasSize)
        )
    }
}

/// Runs silence detection on an audio/video file and returns suggested keep ranges
/// for one-click silence cutting inside the unified Editing Panel.
public enum RoughCutSilenceAnalyzer {
    public struct KeepRange: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public var duration: Double { max(0, end - start) }
    }

    public static func detectSpeechRanges(in url: URL) async throws -> [KeepRange] {
        let asset = AVURLAsset(url: url)
        let durationCM = try await asset.load(.duration)
        let total = durationCM.seconds.isFinite ? max(0, durationCM.seconds) : 0
        guard total > 0.2 else { return [] }
        let silences = try await SilenceDetector.analyze(
            audioURL: url,
            totalDuration: total
        )
        guard !silences.isEmpty else {
            return [KeepRange(start: 0, end: total)]
        }
        var keep: [KeepRange] = []
        var cursor = 0.0
        for gap in silences.sorted(by: { $0.start < $1.start }) {
            let cutStart = min(total, max(cursor, gap.start))
            let cutEnd = min(total, max(cutStart, gap.end))
            guard cutEnd - cutStart >= 0.2 else { continue }
            if cutStart - cursor >= 0.15 {
                keep.append(KeepRange(start: cursor, end: cutStart))
            }
            cursor = cutEnd
        }
        if total - cursor >= 0.15 {
            keep.append(KeepRange(start: cursor, end: total))
        }
        return keep
    }
}
