import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

public struct RecordableWindowInfo: Identifiable, Equatable, Sendable {
    public let id: UInt32
    public let title: String
    public let applicationName: String
    public let width: Int
    public let height: Int

    public init(id: UInt32, title: String, applicationName: String, width: Int, height: Int) {
        self.id = id
        self.title = title
        self.applicationName = applicationName
        self.width = width
        self.height = height
    }
}

@MainActor
public final class WorkspaceRecorder {
    public static let shared = WorkspaceRecorder()
    private var model: AppModel?
    private var activationObserver: AnyCancellable?
    private var phaseObserver: AnyCancellable?
    private var permissionTask: Task<Void, Never>?
    private var jobs: [UUID: VideoExporter] = [:]
    private var observers: [UUID: AnyCancellable] = [:]
    private var onStart: ((UUID, Bool, String?, Bool) throws -> URL)?
    private var onFinish: ((UUID, Result<URL, Error>) -> Void)?
    private var onReturn: ((NSRect?) -> Void)?
    private var archivePackageURL: ((UUID) -> URL?)?
    private var returnsAfterEditorClose = false
    private var isReturning = false
    private(set) var isResumeMode = false
    private(set) var isLibraryMode = false
    public var returnActionStyle: @MainActor (AnyView) -> AnyView = { $0 }
    public var exportSheetStyle: @MainActor (AnyView) -> AnyView = { $0 }
    public var exportPromptField: @MainActor (Binding<String>) -> AnyView = { _ in AnyView(EmptyView()) }
    public var exportPrimaryActionStyle: @MainActor (AnyView) -> AnyView = { $0 }
    public var hasOpenSession: Bool { model != nil }

    public func present(
        onPresent: (NSRect?) -> Void,
        onReturn: @escaping (NSRect?) -> Void,
        onStart: @escaping (UUID, Bool, String?, Bool) throws -> URL,
        archivePackageURL: ((UUID) -> URL?)? = nil,
        onFinish: @escaping (UUID, Result<URL, Error>) -> Void
    ) {
        if let model {
            model.resumeRequiredPermissionOnboardingAfterActivation()
            WindowCoordinator.bringCurrentWindowFront()
            return
        }
        self.isResumeMode = false
        self.isLibraryMode = false
        self.onStart = onStart
        self.archivePackageURL = archivePackageURL
        self.onFinish = onFinish
        self.onReturn = onReturn
        RoughCutMotionLayerStore.shared.clear()
        WorkspaceInputPolicy.registerDefaults()
        let model = AppModel()
        self.model = model
        WindowCoordinator.install(model: model)
        model.beginRequiredPermissionOnboardingIfNeeded()
        onPresent(WindowCoordinator.presentIntegratedSession())
        phaseObserver = model.$phase.dropFirst().receive(on: DispatchQueue.main).sink { [weak self, weak model] phase in
            guard let self, let model, self.model === model else { return }
            if phase == .editor { self.returnsAfterEditorClose = false }
            if phase == .setup, model.phase == .setup, self.returnsAfterEditorClose {
                self.finishSession()
            }
        }
        activationObserver = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak model] _ in
                MainActor.assumeIsolated { model?.resumeRequiredPermissionOnboardingAfterActivation() }
            }
        permissionTask = Task { @MainActor [weak self, weak model] in
            while !Task.isCancelled, let self, let model, self.model === model {
                if model.phase == .setup {
                    await model.verifyRequiredRecordingPermissions()
                    if model.hasRequiredRecordingPermissions, NSApp.isActive {
                        model.finishRequiredPermissionOnboarding()
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    /// Opens the Rough Cutting recorder to capture a standalone demo clip directly into the project's media library.
    public func presentForLibrary(
        onPresent: (NSRect?) -> Void,
        onReturn: @escaping (NSRect?) -> Void,
        onStart: @escaping (UUID) throws -> URL,
        onFinish: @escaping (UUID, Result<URL, Error>) -> Void
    ) {
        present(
            onPresent: onPresent,
            onReturn: onReturn,
            onStart: { id, _, _, _ in try onStart(id) },
            archivePackageURL: nil,
            onFinish: onFinish
        )
        self.isLibraryMode = true
    }

    /// Resumes an existing SuperWorkspace material directly inside the Rough Cutting Panel.
    /// If the material has AI motion outputs, `motionLayer` activates the overlaid AI Motion Layer.
    public func resume(
        packageURL: URL,
        fallbackSourceURL: URL,
        title: String,
        motionLayer: RoughCutMotionLayerContext?,
        onPresent: (NSRect?) -> Void,
        onReturn: @escaping (NSRect?) -> Void,
        onStart: @escaping (UUID, Bool, String?, Bool) throws -> URL,
        onFinish: @escaping (UUID, Result<URL, Error>) -> Void
    ) throws {
        if model != nil {
            WindowCoordinator.bringCurrentWindowFront()
            return
        }
        let resolvedPackageURL = try RoughCutPackageHelper.ensurePackage(
            at: packageURL,
            fallbackSourceURL: fallbackSourceURL,
            title: title
        )
        self.isResumeMode = true
        self.isLibraryMode = false
        self.onStart = onStart
        self.archivePackageURL = nil
        self.onFinish = onFinish
        self.onReturn = onReturn
        self.returnsAfterEditorClose = false
        RoughCutMotionLayerStore.shared.load(motionLayer)
        WorkspaceInputPolicy.registerDefaults()

        let model = AppModel(workspace: ProjectWorkspace(), purpose: .editing)
        self.model = model
        WindowCoordinator.install(model: model)
        WindowCoordinator.prepareExternalProjectPresentation()
        var enteredEditor = false
        phaseObserver = model.$phase.dropFirst().receive(on: DispatchQueue.main).sink { [weak self, weak model] phase in
            guard let self, let model, self.model === model else { return }
            if phase == .editor {
                enteredEditor = true
                self.returnsAfterEditorClose = false
            }
            if phase == .setup, model.phase == .setup, enteredEditor || self.returnsAfterEditorClose {
                self.finishSession()
            }
        }
        model.requestOpenProject(at: resolvedPackageURL)
        onPresent(nil)
    }

    public func bringToFront() {
        WindowCoordinator.bringCurrentWindowFront()
    }

    /// Headless window enumeration shared by GUI and future CLI / Agent automation.
    public func listRecordableWindows() async throws -> [RecordableWindowInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows.compactMap { window in
            guard window.isOnScreen, window.frame.width >= 80, window.frame.height >= 80 else { return nil }
            let appName = window.owningApplication?.applicationName ?? ""
            let title = window.title ?? ""
            guard !appName.isEmpty || !title.isEmpty else { return nil }
            return RecordableWindowInfo(
                id: window.windowID,
                title: title,
                applicationName: appName,
                width: Int(window.frame.width),
                height: Int(window.frame.height)
            )
        }
    }

    func requestWorkspaceReturn() {
        guard let model, !isReturning, !AppDialogPresenter.isPresenting else { return }
        if let editor = WindowCoordinator.activeEditorModel {
            guard !editor.isMediaExchangeRunning, !editor.exporter.isExporting else { return }
            if editor === model {
                editor.requestCloseProject { [weak self, weak model] in
                    guard let self, let model, self.model === model else { return }
                    self.returnsAfterEditorClose = true
                }
            } else if model.phase == .setup {
                isReturning = true
                Task { @MainActor in
                    let closed = await WindowCoordinator.closeRecordingProjectEditorForReplacement()
                    isReturning = false
                    if closed, self.model === model, model.phase == .setup { finishSession() }
                }
            }
        } else if model.phase == .setup, model.currentSession == nil, model.recordingRuns.active == nil {
            finishSession()
        }
    }

    private func finishSession() {
        let origin = WindowCoordinator.integratedRecorderFrame
        let retiredModel = model
        let restore = onReturn
        model = nil
        onReturn = nil
        onStart = nil
        archivePackageURL = nil
        onFinish = nil
        isResumeMode = false
        returnsAfterEditorClose = false
        phaseObserver = nil
        activationObserver = nil
        permissionTask?.cancel()
        permissionTask = nil
        RoughCutMotionLayerStore.shared.clear()
        WindowCoordinator.shutdown()
        // An export job keeps its own immutable request and completion callback.
        retiredModel?.shutdownForApplicationTermination()
        restore?(origin)
    }

    func submit(wantsMotion: Bool, editingPrompt: String?, wantsAIEditing: Bool,
                makeRequest: (URL) throws -> EditorExportRequest) throws {
        let id = UUID()
        guard let onStart, let onFinish else { throw CocoaError(.fileWriteUnknown) }
        // Validate before adding a persistent material or hiding the editor.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).mp4")
        _ = try makeRequest(temporary)
        let output = try onStart(id, wantsMotion, wantsMotion || wantsAIEditing ? editingPrompt : nil, wantsAIEditing)
        if let activeEditor = WindowCoordinator.activeEditorModel,
           let session = activeEditor.currentSession {
            try? ProjectStore.saveProject(activeEditor.project, session: session)
            if !isResumeMode, let archiveDest = archivePackageURL?(id) {
                try? RoughCutPackageHelper.archivePackage(from: session.packageURL, to: archiveDest)
            }
        }
        let request: EditorExportRequest
        do { request = try makeRequest(output) }
        catch { onFinish(id, .failure(error)); throw error }
        let exporter = VideoExporter()
        jobs[id] = exporter
        observers[id] = exporter.$isExporting.dropFirst().receive(on: DispatchQueue.main).sink { [weak self, weak exporter] running in
            guard !running, let self, let exporter else { return }
            if let url = exporter.lastExportURL {
                onFinish(id, .success(url))
            } else {
                onFinish(id, .failure(NSError(domain: "RecorderExport", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: exporter.errorMessage ?? "素材导出未完成，请重新打开录制工程后导出。"])))
            }
            self.observers[id] = nil
            self.jobs[id] = nil
        }
        exporter.export(request: request)
        finishSession()
    }
}

struct WorkspaceReturnButton: View {
    var body: some View {
        WorkspaceRecorder.shared.returnActionStyle(AnyView(
            Button("返回工作台", systemImage: "arrow.uturn.backward") {
                WorkspaceRecorder.shared.requestWorkspaceReturn()
            }
            .accessibilityLabel("返回工作台")
            .accessibilityIdentifier("workspace.return")
        ))
        .fixedSize()
    }
}

struct IntegratedExportSheet: View {
    let wallpaperURLResolver: EditorSessionContext.WallpaperURLResolver
    let projectAssetURLResolver: EditorSessionContext.ProjectAssetURLResolver
    let projectDisplayName: String
    let exportScope: EditorExportScope
    @ObservedObject var exporter: VideoExporter
    @ObservedObject var editorStore: EditorStore
    @ObservedObject var mediaSession: EditorMediaSession
    @ObservedObject var playbackController: EditorPlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var wantsMotion = false
    @State private var editingPrompt = ""
    @State private var wantsAIEditing = false
    @State private var error: String?

    var body: some View {
        let base = WorkspaceRecorder.shared.exportSheetStyle(AnyView(content))
            .background(SheetAutoSizeFitter(trigger: "\(wantsMotion)-\(error ?? "")-\(WorkspaceRecorder.shared.isLibraryMode)"))
        if #available(macOS 15.0, *) {
            base.presentationSizing(.fitted)
        } else {
            base
        }
    }

    private var content: some View {
        let isResume = WorkspaceRecorder.shared.isResumeMode
        let isLibrary = WorkspaceRecorder.shared.isLibraryMode
        return VStack(alignment: .leading, spacing: 20) {
            Text(isLibrary ? "保存到素材库" : (isResume ? "保存粗剪修改" : "完成录制")).font(.title2.weight(.semibold))
            if isLibrary {
                Text("导出后直接存入当前项目素材库，可在素材库中指定必用于哪条视频。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isResume ? "准备重新 AI 包装" : "准备 AI 包装", isOn: $wantsMotion)
                    if wantsMotion {
                        Text("导出后先完成字幕；回到工作台确认素材齐备后，点击「开始 AI 包装」才会启动。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        WorkspaceRecorder.shared.exportPromptField($editingPrompt)
                    }
                }
            }
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                WorkspaceRecorder.shared.exportPrimaryActionStyle(AnyView(
                    Button(isLibrary ? "存入素材库" : (isResume ? "保存并更新" : "确定")) { submit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(mediaSession.prepared == nil)
                ))
            }
        }
        .padding(28)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func submit() {
        _ = editorStore.prepareForExternalAction(.export)
        guard let media = mediaSession.prepared else { return }
        do {
            let prompt = editingPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let isLibrary = WorkspaceRecorder.shared.isLibraryMode
            let enablePackaging = !isLibrary && wantsMotion
            try WorkspaceRecorder.shared.submit(wantsMotion: enablePackaging, editingPrompt: prompt.isEmpty ? nil : prompt, wantsAIEditing: false) { output in
                let project = editorStore.project
                return try EditorExportRequestBuilder.make(
                    editorSessionID: editorStore.sessionID, mediaGeneration: media.generation,
                    project: project, preparedMedia: media,
                    wallpaperURL: wallpaperURLResolver(project.canvas.backgroundSource),
                    stickerURLs: Dictionary(uniqueKeysWithValues: Set(project.timeline.stickerClips.map(\.relativePath)).compactMap { path in
                        projectAssetURLResolver(path).map { (path, $0) }
                    }), outputURL: output, outputKind: .video, outputRange: exportScope.outputRange)
            }
            playbackController.pause()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Resizes the hosting macOS sheet window smoothly whenever dynamic content expands/collapses.
private struct SheetAutoSizeFitter: NSViewRepresentable {
    let trigger: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window, let contentView = window.contentView else { return }
            contentView.layoutSubtreeIfNeeded()
            let fitted = contentView.fittingSize
            guard fitted.width > 100, fitted.height > 80 else { return }
            let target = NSSize(width: max(400, ceil(fitted.width)), height: ceil(fitted.height))
            let current = window.contentRect(forFrameRect: window.frame).size
            guard abs(current.height - target.height) > 1 || abs(current.width - target.width) > 1 else { return }
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: target))
            frame.origin.x = window.frame.midX - frame.width / 2
            frame.origin.y = window.frame.midY - frame.height / 2
            window.setFrame(frame, display: true, animate: true)
        }
    }
}

// Updates belong to the host application, never the embedded recorder.
@MainActor
final class AppUpdateController: ObservableObject {
    static let shared = AppUpdateController()
    @Published var isReady = false
    @Published var automaticallyChecksForUpdates = false
    var isFormalRelease: Bool { false }
    var currentVersionDescription: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    var availabilityDescription: String { "录制组件随应用更新。" }
    func startIfEligible() {}
    func checkForUpdates() {}
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {}
}
