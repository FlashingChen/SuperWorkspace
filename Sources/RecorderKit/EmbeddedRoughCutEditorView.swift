import Combine
import Foundation
import RecorderCore
import SwiftUI

/// Owns an embedded DogSC `AppModel` + `EditorSessionContextProvider` so SuperWorkspace's
/// Editing Panel (`AssemblyView`) can embed the complete DogSC studio UI (stage preview with
/// direct manipulation, 6-tab Inspector, multi-track timeline with Zoom/3D/Camera/Overlay/AI Motion)
/// directly inside the main window without spawning a separate NSWindow.
@MainActor
final class EmbeddedRoughCutEditorController: ObservableObject {
    let model: AppModel
    let contextProvider: EditorSessionContextProvider
    @Published private(set) var isReady = false
    @Published private(set) var loadError: String?

    private var phaseSub: AnyCancellable?
    private var projectSub: AnyCancellable?
    private var activePackageURL: URL?
    private var onDidSave: (() -> Void)?

    init() {
        WorkspaceInputPolicy.registerDefaults()
        let appModel = AppModel(workspace: ProjectWorkspace(), purpose: .editing)
        self.model = appModel
        self.contextProvider = EditorSessionContextProvider(model: appModel)

        phaseSub = appModel.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak appModel] phase in
                guard let self, let appModel else { return }
                self.isReady = (phase == .editor && appModel.recordingURL != nil)
                if phase == .setup, let message = appModel.errorMessage {
                    self.loadError = message
                }
            }

        projectSub = appModel.workspace.document.$project
            .dropFirst()
            .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main)
            .sink { [weak self, weak appModel] project in
                guard let self, let appModel,
                      appModel.phase == .editor,
                      let session = appModel.currentSession else { return }
                try? ProjectStore.saveProject(project, session: session)
                self.onDidSave?()
            }
    }

    func open(
        packageURL: URL,
        fallbackSourceURL: URL,
        title: String,
        motionLayer: RoughCutMotionLayerContext?,
        onDidSave: @escaping () -> Void
    ) {
        self.onDidSave = onDidSave
        RoughCutMotionLayerStore.shared.load(motionLayer)

        let standardized = packageURL.standardizedFileURL
        if activePackageURL == standardized, model.phase == .editor {
            return
        }

        flushNow()
        loadError = nil
        isReady = false

        do {
            _ = try RoughCutPackageStore.ensurePackage(
                at: packageURL,
                fallbackSourceURL: fallbackSourceURL,
                title: title
            )
            activePackageURL = standardized
            model.openEmbeddedProject(at: packageURL)
        } catch {
            loadError = "无法加载素材工程：\(error.localizedDescription)"
        }
    }

    func updateMotionLayer(_ motionLayer: RoughCutMotionLayerContext?) {
        RoughCutMotionLayerStore.shared.load(motionLayer)
    }

    func flushNow() {
        guard model.phase == .editor, let session = model.currentSession else { return }
        try? ProjectStore.saveProject(model.project, session: session)
        onDidSave?()
    }

    func shutdown() {
        flushNow()
        phaseSub = nil
        projectSub = nil
        activePackageURL = nil
        RoughCutMotionLayerStore.shared.clear()
        model.shutdownForApplicationTermination()
    }
}

/// Complete DogSC studio UI embedded seamlessly inside SuperWorkspace's Editing Panel.
public struct EmbeddedRoughCutEditorView: View {
    let materialID: UUID
    let packageURL: URL
    let fallbackSourceURL: URL
    let title: String
    let motionLayer: RoughCutMotionLayerContext?
    let onDidSave: () -> Void

    @StateObject private var controller = EmbeddedRoughCutEditorController()

    public init(
        materialID: UUID,
        packageURL: URL,
        fallbackSourceURL: URL,
        title: String,
        motionLayer: RoughCutMotionLayerContext?,
        onDidSave: @escaping () -> Void
    ) {
        self.materialID = materialID
        self.packageURL = packageURL
        self.fallbackSourceURL = fallbackSourceURL
        self.title = title
        self.motionLayer = motionLayer
        self.onDidSave = onDidSave
    }

    public var body: some View {
        ZStack {
            if controller.isReady {
                EditorView(context: controller.contextProvider.context, isEmbedded: true)
                    .id(controller.contextProvider.context.id)
            } else if let error = controller.loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22))
                        .foregroundStyle(EditorTheme.secondaryText)
                    Text(error)
                        .font(.appUI(size: 13))
                        .foregroundStyle(EditorTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(EditorTheme.backgroundDeep)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.regular)
                    Text("正在加载编辑画布…")
                        .font(.appUI(size: 12))
                        .foregroundStyle(EditorTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(EditorTheme.backgroundDeep)
            }
        }
        .onAppear {
            controller.open(
                packageURL: packageURL,
                fallbackSourceURL: fallbackSourceURL,
                title: title,
                motionLayer: motionLayer,
                onDidSave: onDidSave
            )
        }
        .onChange(of: materialID) { _, _ in
            controller.open(
                packageURL: packageURL,
                fallbackSourceURL: fallbackSourceURL,
                title: title,
                motionLayer: motionLayer,
                onDidSave: onDidSave
            )
        }
        .onChange(of: motionLayer) { _, next in
            controller.updateMotionLayer(next)
        }
        .onDisappear {
            controller.shutdown()
        }
    }
}
