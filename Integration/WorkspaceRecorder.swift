import AppKit
import Combine
import SwiftUI

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
    private var returnsAfterEditorClose = false
    private var isReturning = false
    public var returnActionStyle: @MainActor (AnyView) -> AnyView = { $0 }
    public var exportSheetStyle: @MainActor (AnyView) -> AnyView = { $0 }
    public var exportPromptField: @MainActor (Binding<String>) -> AnyView = { _ in AnyView(EmptyView()) }
    public var exportPrimaryActionStyle: @MainActor (AnyView) -> AnyView = { $0 }
    public var hasOpenSession: Bool { model != nil }

    public func present(
        onPresent: (NSRect?) -> Void,
        onReturn: @escaping (NSRect?) -> Void,
        onStart: @escaping (UUID, Bool, String?, Bool) throws -> URL,
        onFinish: @escaping (UUID, Result<URL, Error>) -> Void
    ) {
        if let model {
            model.resumeRequiredPermissionOnboardingAfterActivation()
            WindowCoordinator.bringCurrentWindowFront()
            return
        }
        self.onStart = onStart
        self.onFinish = onFinish
        self.onReturn = onReturn
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

    public func bringToFront() {
        WindowCoordinator.bringCurrentWindowFront()
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
        onFinish = nil
        returnsAfterEditorClose = false
        phaseObserver = nil
        activationObserver = nil
        permissionTask?.cancel()
        permissionTask = nil
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
        WorkspaceRecorder.shared.exportSheetStyle(AnyView(content))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("完成录制").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                Toggle("添加 AI 动效", isOn: $wantsMotion)
                if wantsMotion || wantsAIEditing {
                    WorkspaceRecorder.shared.exportPromptField($editingPrompt)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("AI 剪辑", isOn: $wantsAIEditing)
                    .help("从素材库选用补充画面，随本段素材保存，导出成片时使用。")
                Text("按素材库内容插入画面")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                WorkspaceRecorder.shared.exportPrimaryActionStyle(AnyView(
                    Button("确定") { submit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(mediaSession.prepared == nil)
                ))
            }
        }
        .padding(28).frame(width: 360)
    }

    private func submit() {
        _ = editorStore.prepareForExternalAction(.export)
        guard let media = mediaSession.prepared else { return }
        do {
            let prompt = editingPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            try WorkspaceRecorder.shared.submit(wantsMotion: wantsMotion, editingPrompt: prompt.isEmpty ? nil : prompt, wantsAIEditing: wantsAIEditing) { output in
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
