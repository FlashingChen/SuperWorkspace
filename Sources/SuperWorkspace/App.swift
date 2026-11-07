import SwiftUI

@main
struct SuperWorkspaceApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("appearanceMode") private var appearanceMode = "system"

    var body: some Scene {
        WindowGroup {
            ThemedContent {
                RootView().environmentObject(appState).background(WindowConfigurator())
                    .buttonStyle(StudioButtonStyle())
                    .toggleStyle(StudioToggleStyle())
                    .textFieldStyle(StudioTextFieldStyle())
                    .menuStyle(StudioMenuStyle())
            }
            .frame(minWidth: 1100, minHeight: 700)
            .preferredColorScheme(AppearanceResolver.scheme(for: appearanceMode))
        }
        .defaultSize(width: 1240, height: 800)
        .defaultPosition(.center)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { appState.undo() }.keyboardShortcut("z").disabled(!appState.canUndo)
                Button("重做") { appState.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!appState.canRedo)
            }
        }
        Settings {
            ThemedContent { SettingsView() }
                .preferredColorScheme(AppearanceResolver.scheme(for: appearanceMode))
        }
    }
}

struct RootView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var state: AppState
    @AppStorage("projectPanelExpanded") private var projectPanelExpanded = true
    @State private var showNew = false
    @State private var showExport = false

    var body: some View {
        HStack(spacing: 0) {
            CompactProjectPanel(expanded: $projectPanelExpanded, onCreate: { showNew = true })
            VStack(spacing: 0) {
                workspaceHeader
                Group {
                    if let project = state.currentProject {
                        VStack(spacing: 0) {
                            Group {
                                if state.stage == .record { RecordStepView(project: project) }
                                else { AssemblyView(project: project) }
                            }
                            .id(project.id)
                            ExportResultBar(project: project)
                        }
                    } else {
                        ProjectLibraryView(onCreate: { showNew = true })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in state.saveSession() }
        .tint(palette.accent)
        .foregroundStyle(palette.textPrimary)
        .background(palette.bgBase)
        .sheet(isPresented: $showNew) { NewProjectSheet().environmentObject(state) }
        .sheet(isPresented: $showExport) {
            if let project = state.currentProject { MovieExportSheet(project: project).environmentObject(state) }
        }
        .overlay(alignment: .bottomTrailing) {
            if let toast = state.toast {
                Text(toast).font(.system(size: 13)).padding(.horizontal, 18).padding(.vertical, 12)
                    .background(palette.surface1, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
                    .padding(24)
            }
        }
        .sheet(isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            StudioMessageSheet(title: "操作未完成", message: state.error ?? "", actionTitle: "确定") {
                state.error = nil
            }
        }
    }

    private var workspaceHeader: some View {
        ZStack {
            HStack(spacing: 10) {
                ForEach(Array(WorkStage.allCases.enumerated()), id: \.element) { index, stage in
                    if index > 0 {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 14, weight: .light))
                            .foregroundStyle(palette.textMuted).accessibilityHidden(true)
                    }
                    Button { state.stage = stage } label: {
                        HStack(spacing: 8) {
                            Text("\(index + 1)").monospacedDigit()
                            Text(stage.rawValue)
                        }
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 24).frame(height: 36)
                    }
                    .buttonStyle(StudioSelectionStyle(selected: state.currentProject != nil && state.stage == stage, cornerRadius: 18))
                    .accessibilityAddTraits(state.currentProject != nil && state.stage == stage ? .isSelected : [])
                    .disabled(state.currentProject == nil)
                }
            }
            HStack {
                Text(state.currentProject?.name ?? "项目库")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1).frame(maxWidth: 180, alignment: .leading)
                Spacer()
                if let project = state.currentProject, state.stage == .assemble {
                    Button { showExport = true } label: {
                        Label(state.exportingProjects.contains(project.id) ? "正在导出" : "导出成片", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(StudioButtonStyle(kind: .primary))
                    .disabled(project.materials.isEmpty || state.exportingProjects.contains(project.id))
                }

            }
        }
        .padding(.horizontal, 24).frame(height: 80)
    }

}

struct ProjectLibraryView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var state: AppState
    let onCreate: () -> Void

    var body: some View {
        Group {
            if state.projects.isEmpty {
                StudioWorkspace(title: "开始创作。", detail: "新建一个项目，录下屏幕里的想法。") {
                    StudioPreview(symbol: "macwindow", title: "你的作品，从这里开始")
                } controls: {
                    Text("第一期视频").font(.system(size: 18, weight: .medium))
                    Text("录制素材，再按顺序拼装成片。")
                        .font(.system(size: 13)).foregroundStyle(palette.textSecondary)
                    Button("新建项目", systemImage: "plus", action: onCreate)
                        .buttonStyle(StudioButtonStyle(kind: .primary))
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 40) {
                        WorkspaceHeading(title: "作品集。", detail: "每一期视频，都从这里开始。")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 28)], alignment: .leading, spacing: 32) {
                            ForEach(state.projects) { project in
                                Button { state.select(project.id) } label: {
                                    VStack(alignment: .leading, spacing: 14) {
                                        MaterialThumbnail(url: project.materials.first.map { ProjectLayout.picture($0, in: project) })
                                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(project.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                                            Spacer()
                                            Text(project.updatedAt, style: .date)
                                                .font(.system(size: 11)).foregroundStyle(palette.textMuted)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(StudioContentButtonStyle())
                            }
                        }
                    }
                    .frame(maxWidth: 1100, alignment: .leading)
                    .padding(44)
                    .frame(maxWidth: .infinity)
                }
                .background(palette.bgBase)
            }
        }
    }
}

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            NSApplication.shared.applicationIconImage = WorkspaceBrand.image(size: 1024)
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            if window.screen == nil || !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
                window.center()
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
