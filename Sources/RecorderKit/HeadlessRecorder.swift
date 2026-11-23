import AppKit
import ApplicationServices
import AVFoundation
import CoreMedia
import Foundation
import RecorderCore
import ScreenCaptureKit

public struct HeadlessWindowInfo: Identifiable, Codable, Equatable, Sendable {
    public let id: UInt32
    public let pid: Int32
    public let title: String
    public let applicationName: String
    public let bundleIdentifier: String?
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(
        id: UInt32,
        pid: Int32,
        title: String,
        applicationName: String,
        bundleIdentifier: String?,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) {
        self.id = id
        self.pid = pid
        self.title = title
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct HeadlessRecorderStatus: Codable, Equatable, Sendable {
    public let isRecording: Bool
    public let hasScreenRecordingPermission: Bool
    public let hasAccessibilityPermission: Bool
    public let activeTarget: String?
    public let elapsedSeconds: Double?
}

public struct HeadlessRecordStartRequest: Codable, Equatable, Sendable {
    public let windowID: UInt32?
    public let appName: String?
    public let displayID: UInt32?
    public let systemAudio: Bool
    public let fps: Int

    public init(
        windowID: UInt32? = nil,
        appName: String? = nil,
        displayID: UInt32? = nil,
        systemAudio: Bool = true,
        fps: Int = 60
    ) {
        self.windowID = windowID
        self.appName = appName
        self.displayID = displayID
        self.systemAudio = systemAudio
        self.fps = fps
    }
}

public struct HeadlessRecordStartResult: Codable, Equatable, Sendable {
    public let targetKind: String
    public let targetTitle: String
    public let width: Int
    public let height: Int
    public let outputPath: String
}

public struct HeadlessRecordStopResult: Codable, Equatable, Sendable {
    public let outputPath: String
    public let duration: Double
    public let pointerEventCount: Int
    public let autoZoomCount: Int
    public let warning: String?
}

public enum HeadlessRecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case missingScreenRecordingPermission
    case missingAccessibilityPermission
    case targetNotFound(String)
    case recordingEmpty

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording: "已有进行中的无头录制任务。"
        case .notRecording: "当前没有正在进行的无头录制任务。"
        case .missingScreenRecordingPermission: "缺少屏幕录制权限，请在系统设置中授权 SuperWorkspace 后重试。"
        case .missingAccessibilityPermission: "缺少辅助功能权限，无法调整其他应用窗口尺寸。"
        case let .targetNotFound(desc): "找不到指定的录制目标：\(desc)"
        case .recordingEmpty: "录制结束但未生成有效视频文件。"
        }
    }
}

/// Headless ScreenCaptureKit + pointer telemetry controller shared by local CLI
/// and AI agent automation without opening GUI setup panels.
@MainActor
public final class HeadlessRecorder {
    public static let shared = HeadlessRecorder()

    private let screenRecorder = ScreenRecorder()
    private let pointerRecorder = PointerEventRecorder()
    private var activeRunID: RecordingRunID?
    private var activeRawURL: URL?
    private var activeOutputURL: URL?
    private var activeConfiguration: CaptureConfiguration?
    private var activeTargetLabel: String?
    private var startedAt: Date?
    private var pointerStarted = false

    private init() {}

    public func status() -> HeadlessRecorderStatus {
        HeadlessRecorderStatus(
            isRecording: activeRunID != nil,
            hasScreenRecordingPermission: CGPreflightScreenCaptureAccess(),
            hasAccessibilityPermission: AXIsProcessTrusted(),
            activeTarget: activeTargetLabel,
            elapsedSeconds: startedAt.map { max(0, Date().timeIntervalSince($0)) }
        )
    }

    private static let excludedBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
    ]

    private static func isRecordableAppWindow(_ window: SCWindow) -> Bool {
        guard window.isOnScreen,
              window.windowLayer == 0,
              window.frame.width >= 80,
              window.frame.height >= 80 else { return false }
        let bundleID = window.owningApplication?.bundleIdentifier ?? ""
        if !bundleID.isEmpty {
            if bundleID == Bundle.main.bundleIdentifier { return false }
            if excludedBundleIDs.contains(bundleID) { return false }
        }
        let appName = window.owningApplication?.applicationName ?? ""
        let title = window.title ?? ""
        return !appName.isEmpty || !title.isEmpty
    }

    public func listWindows() async throws -> [HeadlessWindowInfo] {
        guard CGPreflightScreenCaptureAccess() else {
            throw HeadlessRecorderError.missingScreenRecordingPermission
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows.compactMap { window in
            guard Self.isRecordableAppWindow(window) else { return nil }
            let appName = window.owningApplication?.applicationName ?? ""
            let title = window.title ?? ""
            return HeadlessWindowInfo(
                id: window.windowID,
                pid: window.owningApplication?.processID ?? 0,
                title: title,
                applicationName: appName,
                bundleIdentifier: window.owningApplication?.bundleIdentifier,
                x: Int(window.frame.origin.x.rounded()),
                y: Int(window.frame.origin.y.rounded()),
                width: Int(window.frame.width.rounded()),
                height: Int(window.frame.height.rounded())
            )
        }
    }

    public func resizeWindow(windowID: UInt32, x: Double?, y: Double?, width: Double, height: Double) async throws {
        guard AXIsProcessTrusted() else {
            throw HeadlessRecorderError.missingAccessibilityPermission
        }
        let windows = try await listWindows()
        guard let target = windows.first(where: { $0.id == windowID }), target.pid > 0 else {
            throw HeadlessRecorderError.targetNotFound("windowID=\(windowID)")
        }
        let appElement = AXUIElementCreateApplication(target.pid)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawWindows) == .success,
              let axWindows = rawWindows as? [AXUIElement], !axWindows.isEmpty else {
            throw HeadlessRecorderError.targetNotFound("AX windows for pid=\(target.pid)")
        }

        let matched = axWindows.first { element in
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String, !target.title.isEmpty, title == target.title {
                return true
            }
            return false
        } ?? axWindows[0]

        var size = CGSize(width: max(200, width), height: max(200, height))
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(matched, kAXSizeAttribute as CFString, sizeVal)
        }
        if let x, let y {
            var pos = CGPoint(x: x, y: y)
            if let posVal = AXValueCreate(.cgPoint, &pos) {
                AXUIElementSetAttributeValue(matched, kAXPositionAttribute as CFString, posVal)
            }
        }
        AXUIElementPerformAction(matched, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
    }

    public func moveMouse(to x: Double, y: Double, smooth: Bool = true, duration: Double = 0.35) async throws {
        guard AXIsProcessTrusted() else {
            throw HeadlessRecorderError.missingAccessibilityPermission
        }
        let target = CGPoint(x: x, y: y)
        let current = CGEvent(source: nil)?.location ?? target
        if smooth, duration > 0.02 {
            let steps = max(8, Int(duration * 60))
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let e = t * t * (3 - 2 * t)
                let pt = CGPoint(x: current.x + (target.x - current.x) * e, y: current.y + (target.y - current.y) * e)
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(max(4, Int((duration / Double(steps)) * 1000))))
            }
        } else {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    public func clickMouse(at x: Double, y: Double, smooth: Bool = true) async throws {
        try await moveMouse(to: x, y: y, smooth: smooth)
        let pt = CGPoint(x: x, y: y)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(60))
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    public func pressKey(keyCode: UInt16, command: Bool = false, shift: Bool = false) async throws {
        guard AXIsProcessTrusted() else {
            throw HeadlessRecorderError.missingAccessibilityPermission
        }
        var flags: CGEventFlags = []
        if command { flags.insert(.maskCommand) }
        if shift { flags.insert(.maskShift) }
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        try await Task.sleep(for: .milliseconds(40))
        if let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }

    public func pasteText(_ text: String) async throws {
        guard AXIsProcessTrusted() else {
            throw HeadlessRecorderError.missingAccessibilityPermission
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        try await Task.sleep(for: .milliseconds(80))
        try await pressKey(keyCode: 9, command: true) // Cmd+V
    }

    public func typeText(_ text: String, interval: Double = 0.12) async throws {
        guard AXIsProcessTrusted() else {
            throw HeadlessRecorderError.missingAccessibilityPermission
        }
        let stepMs = max(25, Int(interval * 1000))
        for ch in text {
            if let mapped = Self.asciiKeyMapping[ch] {
                try await pressKey(keyCode: mapped.code, command: false, shift: mapped.shift)
            } else {
                var utf16 = Array(String(ch).utf16)
                if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) {
                    down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                    down.post(tap: .cghidEventTap)
                }
                try await Task.sleep(for: .milliseconds(30))
                if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                    up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
                    up.post(tap: .cghidEventTap)
                }
            }
            try await Task.sleep(for: .milliseconds(stepMs))
        }
    }

    private static let asciiKeyMapping: [Character: (code: UInt16, shift: Bool)] = [
        "a": (0, false), "b": (11, false), "c": (8, false), "d": (2, false), "e": (14, false),
        "f": (3, false), "g": (5, false), "h": (4, false), "i": (34, false), "j": (38, false),
        "k": (40, false), "l": (37, false), "m": (46, false), "n": (45, false), "o": (31, false),
        "p": (35, false), "q": (12, false), "r": (15, false), "s": (1, false), "t": (17, false),
        "u": (32, false), "v": (9, false), "w": (13, false), "x": (7, false), "y": (16, false),
        "z": (6, false),
        "A": (0, true), "B": (11, true), "C": (8, true), "D": (2, true), "E": (14, true),
        "F": (3, true), "G": (5, true), "H": (4, true), "I": (34, true), "J": (38, true),
        "K": (40, true), "L": (37, true), "M": (46, true), "N": (45, true), "O": (31, true),
        "P": (35, true), "Q": (12, true), "R": (15, true), "S": (1, true), "T": (17, true),
        "U": (32, true), "V": (9, true), "W": (13, true), "X": (7, true), "Y": (16, true),
        "Z": (6, true),
        "0": (29, false), "1": (18, false), "2": (19, false), "3": (20, false), "4": (21, false),
        "5": (23, false), "6": (22, false), "7": (26, false), "8": (28, false), "9": (25, false),
        " ": (49, false), "-": (27, false), "_": (27, true), "=": (24, false), "+": (24, true),
        ".": (47, false), ",": (43, false), "/": (44, false), ":": (41, true), ";": (41, false),
        "\n": (36, false),
    ]

    public func dragMouse(from x0: Double, y0: Double, to x1: Double, y1: Double, duration: Double = 0.45) async throws {
        guard AXIsProcessTrusted() else {
            throw HeadlessRecorderError.missingAccessibilityPermission
        }
        try await moveMouse(to: x0, y: y0, smooth: true, duration: 0.35)
        let start = CGPoint(x: x0, y: y0)
        let end = CGPoint(x: x1, y: y1)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(60))
        let steps = max(12, Int(max(0.1, duration) * 60))
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let e = t * t * (3 - 2 * t)
            let pt = CGPoint(x: start.x + (end.x - start.x) * e, y: start.y + (end.y - start.y) * e)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(max(4, Int((duration / Double(steps)) * 1000))))
        }
        try await Task.sleep(for: .milliseconds(40))
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    public func captureScreenshot(to outputURL: URL) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw HeadlessRecorderError.missingScreenRecordingPermission
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw HeadlessRecorderError.targetNotFound("display")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw HeadlessRecorderError.recordingEmpty
        }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: outputURL, options: .atomic)
    }

    public func start(request: HeadlessRecordStartRequest, outputURL: URL) async throws -> HeadlessRecordStartResult {
        guard activeRunID == nil else { throw HeadlessRecorderError.alreadyRecording }
        guard CGPreflightScreenCaptureAccess() else {
            throw HeadlessRecorderError.missingScreenRecordingPermission
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var config = CaptureConfiguration()
        config.captureFrameRate = request.fps <= 30 ? .fps30 : .fps60
        config.captureCodec = .h264
        config.recordsSystemAudio = request.systemAudio
        config.recordsMicrophone = false
        config.recordsCamera = false

        let targetKind: String
        let targetTitle: String
        let captureFrame: CGRect

        if let windowID = request.windowID {
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw HeadlessRecorderError.targetNotFound("windowID=\(windowID)")
            }
            config.source = .window
            config.windowID = window.windowID
            config.windowName = window.title
            config.selectedApplicationBundleIdentifier = window.owningApplication?.bundleIdentifier
            config.selectedApplicationName = window.owningApplication?.applicationName
            targetKind = "window"
            targetTitle = [window.owningApplication?.applicationName, window.title]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
            captureFrame = window.frame
        } else if let appName = request.appName, !appName.isEmpty {
            guard let window = content.windows.first(where: {
                Self.isRecordableAppWindow($0) &&
                ($0.owningApplication?.applicationName.localizedCaseInsensitiveContains(appName) == true)
            }) else {
                if appName.localizedCaseInsensitiveContains("SuperWorkspace") {
                    throw HeadlessRecorderError.targetNotFound("无法以单窗口模式录制 SuperWorkspace 自身，请改用 --display 录制整块屏幕")
                }
                throw HeadlessRecorderError.targetNotFound("app=\(appName)")
            }
            config.source = .window
            config.windowID = window.windowID
            config.windowName = window.title
            config.selectedApplicationBundleIdentifier = window.owningApplication?.bundleIdentifier
            config.selectedApplicationName = window.owningApplication?.applicationName
            targetKind = "window"
            targetTitle = [window.owningApplication?.applicationName, window.title]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
            captureFrame = window.frame
        } else {
            let display = request.displayID.flatMap { id in
                content.displays.first(where: { $0.displayID == id })
            } ?? content.displays.first
            guard let display else {
                throw HeadlessRecorderError.targetNotFound("display")
            }
            config.source = .display
            config.displayID = display.displayID
            targetKind = "display"
            targetTitle = "Display \(display.displayID)"
            captureFrame = CGRect(x: 0, y: 0, width: display.width, height: display.height)
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let rawURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("headless-raw-\(UUID().uuidString.prefix(8)).mp4")
        let runID = RecordingRunID()
        try await screenRecorder.start(runID: runID, configuration: config, outputURL: rawURL)

        activeRunID = runID
        activeRawURL = rawURL
        activeOutputURL = outputURL
        activeConfiguration = config
        activeTargetLabel = targetTitle
        startedAt = Date()
        pointerStarted = false

        if AXIsProcessTrusted() {
            let mainHeight = NSScreen.screens.first?.frame.height ?? captureFrame.height
            let appKitFrame = CGRect(
                x: captureFrame.origin.x,
                y: mainHeight - captureFrame.origin.y - captureFrame.height,
                width: captureFrame.width,
                height: captureFrame.height
            )
            let frameSource: PointerCaptureFrameSource = .fixed(appKitFrame)
            pointerStarted = (await pointerRecorder.start(frameSource: frameSource)) != nil
        }

        return HeadlessRecordStartResult(
            targetKind: targetKind,
            targetTitle: targetTitle,
            width: Int(captureFrame.width.rounded()),
            height: Int(captureFrame.height.rounded()),
            outputPath: outputURL.path
        )
    }

    public func stop(styled: Bool = true) async throws -> HeadlessRecordStopResult {
        guard let runID = activeRunID, let rawExpectedURL = activeRawURL, let finalDestination = activeOutputURL else {
            throw HeadlessRecorderError.notRecording
        }
        let savedConfig = activeConfiguration
        defer {
            activeRunID = nil
            activeRawURL = nil
            activeOutputURL = nil
            activeConfiguration = nil
            activeTargetLabel = nil
            startedAt = nil
            pointerStarted = false
        }

        let rawEvents = pointerStarted ? pointerRecorder.stop() : []
        let rawURL = try await screenRecorder.stop(runID: runID) ?? rawExpectedURL
        guard FileManager.default.fileExists(atPath: rawURL.path) else {
            throw HeadlessRecorderError.recordingEmpty
        }

        let rawAsset = AVURLAsset(url: rawURL)
        let rawDurationCM = try await rawAsset.load(.duration)
        let rawDuration = rawDurationCM.seconds.isFinite ? max(0, rawDurationCM.seconds) : 0
        guard rawDuration > 0 else {
            throw HeadlessRecorderError.recordingEmpty
        }

        let finalizedPointer = try? RecordingPointerFinalization.prepare(
            events: rawEvents,
            startOffset: 0,
            sourceStartTime: 0,
            createsAutomaticZooms: true,
            easing: .spring,
            transitionDuration: 0.45
        )
        let normalizedEvents = finalizedPointer?.events ?? rawEvents
        let autoZooms = (finalizedPointer?.automaticZoomAnimations ?? []).compactMap { zoom -> ZoomAnimationClip? in
            let start = max(0, min(zoom.startTime, rawDuration))
            let end = max(start, min(zoom.endTime, rawDuration))
            guard end - start >= 0.25 else { return nil }
            var copy = zoom
            copy.startTime = start
            copy.endTime = end
            return copy
        }

        let outputURL: URL
        if styled {
            outputURL = try await renderStyledRoughCut(
                rawURL: rawURL,
                outputURL: finalDestination,
                configuration: savedConfig ?? CaptureConfiguration(),
                pointerEvents: normalizedEvents,
                zoomAnimations: autoZooms
            )
            try? FileManager.default.removeItem(at: rawURL)
        } else {
            try? FileManager.default.removeItem(at: finalDestination)
            try FileManager.default.moveItem(at: rawURL, to: finalDestination)
            outputURL = finalDestination
        }

        let finalAsset = AVURLAsset(url: outputURL)
        let finalDuration = (try? await finalAsset.load(.duration).seconds) ?? rawDuration

        return HeadlessRecordStopResult(
            outputPath: outputURL.path,
            duration: finalDuration.isFinite && finalDuration > 0 ? finalDuration : rawDuration,
            pointerEventCount: normalizedEvents.count,
            autoZoomCount: autoZooms.count,
            warning: screenRecorder.lastStopWarning
        )
    }

    private func renderStyledRoughCut(
        rawURL: URL,
        outputURL: URL,
        configuration: CaptureConfiguration,
        pointerEvents: [PointerEventRecord],
        zoomAnimations: [ZoomAnimationClip]
    ) async throws -> URL {
        var project = EditorStylePresetStore.applyingLastUsedStyle(to: RecorderProject())
        project.capture = configuration
        project.media = ProjectMediaManifest(
            screen: ProjectMediaReference(relativePath: rawURL.lastPathComponent)
        )
        project.zoomAnimations = zoomAnimations
        project.exportSettings.frameRate = configuration.captureFrameRate
        let resolvedWallpaperURL = Self.resolveStyledBackground(for: &project)

        let sessionID = EditorSessionID()
        let mediaSession = EditorMediaSession()
        let mediaRequest = EditorMediaRequest(
            editorSessionID: sessionID,
            sourceURL: rawURL,
            cameraURL: nil,
            microphoneURL: nil,
            sourceSequence: project.timeline.sourceSequence,
            mediaManifest: project.media,
            pointerEvents: pointerEvents
        )
        await mediaSession.prepare(mediaRequest)
        guard let prepared = mediaSession.prepared else {
            throw HeadlessRecorderError.recordingEmpty
        }
        let exportRequest = try EditorExportRequestBuilder.make(
            editorSessionID: sessionID,
            mediaGeneration: prepared.generation,
            project: project,
            preparedMedia: prepared,
            wallpaperURL: resolvedWallpaperURL,
            stickerURLs: [:],
            outputURL: outputURL,
            outputKind: .video,
            outputRange: nil
        )
        let exporter = VideoExporter()
        exporter.export(request: exportRequest)
        while exporter.isExporting {
            try await Task.sleep(for: .milliseconds(100))
        }
        if let exported = exporter.lastExportURL {
            return exported
        }
        throw VideoExporterError.exportFailed(exporter.errorMessage ?? "无头粗剪渲染失败。")
    }

    private static func resolveStyledBackground(for project: inout RecorderProject) -> URL? {
        func wallpaperURLIfValid(_ source: BackgroundSource) -> URL? {
            switch source {
            case let .systemImage(path), let .systemVideo(path):
                let url = URL(fileURLWithPath: path)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            case .dynamicFlow:
                return nil
            case .pattern, .projectImage, .projectVideo:
                return nil
            }
        }

        switch project.canvas.backgroundSource {
        case .systemImage, .systemVideo:
            if let url = wallpaperURLIfValid(project.canvas.backgroundSource) {
                return url
            }
        case .dynamicFlow:
            return nil
        case .pattern, .projectImage, .projectVideo:
            break
        }

        if let desktop = SystemWallpaperLibrary.currentBackgroundSource(),
           let url = wallpaperURLIfValid(desktop) {
            project.canvas.backgroundSource = desktop
            return url
        }

        project.canvas.backgroundSource = .dynamicFlow(.auroraFluid)
        return nil
    }
}
