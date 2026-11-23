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
    private var activeOutputURL: URL?
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
        let runID = RecordingRunID()
        try await screenRecorder.start(runID: runID, configuration: config, outputURL: outputURL)

        activeRunID = runID
        activeOutputURL = outputURL
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

    public func stop() async throws -> HeadlessRecordStopResult {
        guard let runID = activeRunID, let expectedURL = activeOutputURL else {
            throw HeadlessRecorderError.notRecording
        }
        defer {
            activeRunID = nil
            activeOutputURL = nil
            activeTargetLabel = nil
            startedAt = nil
            pointerStarted = false
        }

        let events = pointerStarted ? pointerRecorder.stop() : []
        let finalURL = try await screenRecorder.stop(runID: runID) ?? expectedURL
        guard FileManager.default.fileExists(atPath: finalURL.path) else {
            throw HeadlessRecorderError.recordingEmpty
        }

        let asset = AVURLAsset(url: finalURL)
        let durationCM = try await asset.load(.duration)
        let duration = durationCM.seconds.isFinite ? max(0, durationCM.seconds) : 0
        guard duration > 0 else {
            throw HeadlessRecorderError.recordingEmpty
        }

        let autoZoomCount: Int
        if !events.isEmpty,
           let finalized = try? RecordingPointerFinalization.prepare(
               events: events,
               startOffset: 0,
               sourceStartTime: 0,
               createsAutomaticZooms: true,
               easing: .spring,
               transitionDuration: 0.45
           ) {
            autoZoomCount = finalized.automaticZoomAnimations.count
        } else {
            autoZoomCount = 0
        }

        return HeadlessRecordStopResult(
            outputPath: finalURL.path,
            duration: duration,
            pointerEventCount: events.count,
            autoZoomCount: autoZoomCount,
            warning: screenRecorder.lastStopWarning
        )
    }
}
