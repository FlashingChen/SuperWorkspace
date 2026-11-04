import SwiftUI

@main
struct SuperWorkspaceApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("appearanceMode") private var appearanceMode = "system"

    var body: some Scene {
        WindowGroup {
            ThemedContent {
                RootView().environmentObject(appState).background(WindowConfigurator())
            }
            .frame(minWidth: 1100, minHeight: 700)
            .preferredColorScheme(AppearanceResolver.scheme(for: appearanceMode))
        }
        .defaultSize(width: 1240, height: 800)
        .defaultPosition(.center)
        .windowToolbarStyle(.unified)
        Settings { ThemedContent { SettingsView() } }
    }
}

struct RootView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var state: AppState
    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var showNew = false

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            SidebarView(onCreate: { showNew = true })
                .navigationSplitViewColumnWidth(min: 200, ideal: 218, max: 260)
        } detail: {
            if let project = state.currentProject {
                VStack(spacing: 0) {
                    HStack(spacing: 24) {
                        Text(project.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(palette.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 20)
                        HStack(spacing: 4) {
                            ForEach(WorkStage.allCases, id: \.self) { stage in
                                Button { state.stage = stage } label: {
                                    Label(stage.rawValue, systemImage: stage == .record ? "record.circle" : "square.stack")
                                        .font(.system(size: 12, weight: state.stage == stage ? .semibold : .regular))
                                        .foregroundStyle(state.stage == stage ? palette.textPrimary : palette.textSecondary)
                                        .padding(.horizontal, 16)
                                        .frame(height: 34)
                                        .background(state.stage == stage ? palette.surface1 : .clear, in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(state.stage == stage ? .isSelected : [])
                            }
                        }
                        if state.stage == .assemble {
                            Button { state.export() } label: {
                                Label {
                                    Text(verbatim: state.exportingProjects.contains(project.id) ? "正在导出" : "导出成片")
                                } icon: { Image(systemName: "arrow.up.right") }
                            }
                            .buttonStyle(StudioButtonStyle(kind: .primary))
                            .disabled(!project.canExport || state.exportingProjects.contains(project.id))
                        }
                    }
                    .padding(.horizontal, 36)
                    .frame(height: 76)
                    Rectangle().fill(palette.surface2.opacity(0.7)).frame(height: 1)
                    Group {
                        if state.stage == .record { RecordStepView(project: project) }
                        else { AssemblyView(project: project) }
                    }
                    .id(project.id)
                }
            } else {
                ProjectLibraryView(onCreate: { showNew = true })
            }
        }
        .tint(palette.accent)
        .foregroundStyle(palette.textPrimary)
        .background(palette.bgBase)
        .sheet(isPresented: $showNew) { NewProjectSheet().environmentObject(state) }
        .overlay(alignment: .bottomTrailing) {
            if let toast = state.toast {
                Text(toast).font(.system(size: 13)).padding(.horizontal, 18).padding(.vertical, 12)
                    .background(palette.surface1, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
                    .padding(24)
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            Button("确定") { state.error = nil }
        } message: { Text(state.error ?? "") }
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
                                .buttonStyle(.plain)
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

struct SidebarView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject private var appState: AppState
    var onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: WorkspaceBrand.image(size: 32))
                    .resizable()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                Text("SuperWorkspace")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.3)
            }
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 22)
            .frame(height: 76)

            Button(action: onCreate) {
                HStack {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium))
                    Text("新建项目")
                    Spacer()
                    Text("⌘N").font(.system(size: 11)).foregroundStyle(palette.textMuted)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(StudioButtonStyle())
            .keyboardShortcut("n", modifiers: .command)
            .padding(.horizontal, 18)
            .padding(.bottom, 34)

            Button { appState.selectedProjectID = nil } label: {
                Label("所有项目", systemImage: "square.grid.2x2")
                    .font(.system(size: 13, weight: appState.currentProject == nil ? .medium : .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(StudioButtonStyle(kind: .quiet))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 18)
            .padding(.bottom, 24)

            Text(verbatim: "项目")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.textMuted)
                .padding(.horizontal, 26)
                .padding(.bottom, 12)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(appState.projects) { project in
                        let selected = appState.currentProject?.id == project.id
                        Button { appState.select(project.id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "film")
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.textSecondary)
                                Text(project.name)
                                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if selected {
                                    Circle().fill(palette.textSecondary).frame(width: 4, height: 4)
                                }
                            }
                            .foregroundStyle(palette.textPrimary)
                            .padding(.horizontal, 12)
                            .frame(height: 42)
                            .background(selected ? palette.bgBase : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                    if appState.projects.isEmpty {
                        Text("项目会保存在这里")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.textMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.horizontal, 14)
            }
            Spacer(minLength: 24)
            SettingsLink {
                Label { Text(verbatim: "设置") } icon: { Image(systemName: "slider.horizontal.3") }
                    .font(.system(size: 12))
                    .foregroundStyle(palette.textSecondary)
            }
            .buttonStyle(StudioButtonStyle(kind: .quiet))
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
        }
        .background(palette.bgSidebar)
    }
}
