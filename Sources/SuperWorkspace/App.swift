import SwiftUI

@main
struct SuperWorkspaceApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("appearanceMode") private var appearanceMode = "system"

    init() {
        AcceptanceHarness.runIfRequested()
    }

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
            CommandGroup(after: .help) {
                Link("快速入门", destination: URL(string: "https://github.com/FlashingChen/SuperWorkspace/blob/main/docs/QUICKSTART.md")!)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销") { appState.undo() }.keyboardShortcut("z").disabled(!appState.canUndo)
                Button("重做") { appState.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!appState.canRedo)
            }
        }
        Settings {
            ThemedContent { SettingsView().background(WindowConfigurator(configuresChrome: false)) }
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
    @State private var showLibrary = false

    var body: some View {
        HStack(spacing: 0) {
            CompactProjectPanel(expanded: $projectPanelExpanded, onCreate: { showNew = true })
            VStack(spacing: 0) {
                workspaceHeader
                if let project = state.currentProject, project.isFrozen {
                    frozenNotice(project)
                }
                Group {
                    if let project = state.currentProject {
                        VStack(spacing: 0) {
                            Group {
                                switch state.stage {
                                case .record: RecordStepView(project: project)
                                case .assemble: AssemblyView(project: project, onOpenLibrary: { showLibrary = true })
                                case .library: ProjectMediaLibrary(projectID: project.id)
                                }
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
        .onChange(of: state.stage) { _, next in
            if next == .assemble { projectPanelExpanded = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            state.shutdownAssemblyAgents()
            state.saveSession()
        }
        .tint(palette.accent)
        .foregroundStyle(palette.textPrimary)
        .background(palette.bgBase)
        .sheet(isPresented: $showNew) { NewProjectSheet().environmentObject(state) }
        .sheet(isPresented: $showExport) {
            if let project = state.currentProject { MovieExportSheet(project: project).environmentObject(state) }
        }
        .sheet(isPresented: $showLibrary) {
            if let project = state.currentProject {
                VStack(spacing: 0) {
                    ProjectMediaLibrary(projectID: project.id)
                        .environmentObject(state)
                    Divider()
                    HStack {
                        Spacer()
                        Button { showLibrary = false } label: { Text(verbatim: "完成") }
                            .buttonStyle(StudioButtonStyle(kind: .primary, size: .compact))
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(.horizontal, Metrics.space5)
                    .frame(height: Metrics.bar)
                    .background(palette.bgBase)
                }
                .frame(minWidth: 720, idealWidth: 820, minHeight: 480, idealHeight: 560)
                .background(palette.bgBase)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let toast = state.toast {
                Text(toast).font(.studio(.body)).padding(.horizontal, Metrics.space4).padding(.vertical, Metrics.space3)
                    .background(palette.surface1, in: RoundedRectangle(cornerRadius: Metrics.radiusL))
                    .shadow(color: .black.opacity(0.12), radius: Metrics.space4, y: Metrics.space1_5)
                    .padding(Metrics.space6)
            }
        }
        .overlay(alignment: .top) {
            budgetBanner.padding(.top, Metrics.header + Metrics.space2)
        }
        .sheet(isPresented: Binding(get: { state.error != nil }, set: { if !$0 { state.error = nil } })) {
            StudioMessageSheet(title: "操作未完成", message: state.error ?? "", actionTitle: "确定") {
                state.error = nil
            }
        }
    }

    private var pendingBudgets: [(project: VideoProject, material: Material, hold: MotionBudgetHold)] {
        var result: [(VideoProject, Material, MotionBudgetHold)] = []
        for project in state.projects {
            for material in project.materials {
                if let hold = state.motionBudgetHolds[material.mediaID] { result.append((project, material, hold)) }
            }
        }
        return result
    }

    @ViewBuilder private var budgetBanner: some View {
        let pending = pendingBudgets
        if let first = pending.first {
            HStack(spacing: Metrics.space3) {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(palette.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Metrics.space1) {
                    Text("动效已到 \(first.hold.limit) 分钟上限")
                        .font(.studio(.bodyMedium))
                    Text("继续会保留当前进度；\(max(1, first.hold.waitSeconds / 60)) 分钟内未选择将自动停止。"
                        + (pending.count > 1 ? "另有 \(pending.count - 1) 个任务在拼装页等待继续。" : ""))
                        .font(.studio(.small))
                        .foregroundStyle(palette.textSecondary)
                }
                Spacer(minLength: Metrics.space4)
                if first.hold.canExtend {
                    Button("继续 \(first.hold.extendMinutes) 分钟") {
                        state.continueMotion(first.project.id, first.material.id)
                    }
                    .buttonStyle(StudioButtonStyle(kind: .primary, size: .compact))
                }
                Button("停止") { state.cancelProcessing(first.project.id, first.material.id, motion: true) }
                    .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
            }
            .padding(Metrics.space3)
            .frame(maxWidth: 620)
            .background(palette.surface1, in: RoundedRectangle(cornerRadius: Metrics.radiusL))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.radiusL)
                    .strokeBorder(palette.borderStrong, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: Metrics.space3, y: Metrics.space1_5)
            .padding(.horizontal, Metrics.space6)
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: Metrics.space3) {
            Text(state.currentProject?.name ?? "项目库")
                .font(.studio(.bodyMedium))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)

            Spacer(minLength: Metrics.space2)

            HStack(spacing: Metrics.space2) {
                ForEach(Array([WorkStage.record, .assemble].enumerated()), id: \.element) { index, stage in
                    if index > 0 {
                        Image(systemName: "arrow.right")
                            .font(.studio(.small, weight: .light))
                            .foregroundStyle(palette.textMuted).accessibilityHidden(true)
                    }
                    Button { state.stage = stage } label: {
                        HStack(spacing: Metrics.space1_5) {
                            Text("\(index + 1)").monospacedDigit()
                            Text(stage.rawValue)
                        }
                        .font(.studio(.small, weight: .medium))
                        .padding(.horizontal, Metrics.space4)
                        .frame(height: Metrics.controlCompact)
                    }
                    .buttonStyle(StudioSelectionStyle(selected: state.currentProject != nil && state.stage == stage, cornerRadius: Metrics.controlCompact / 2))
                    .accessibilityAddTraits(state.currentProject != nil && state.stage == stage ? .isSelected : [])
                    .disabled(state.currentProject == nil)
                }
            }

            Spacer(minLength: Metrics.space2)

            HStack(spacing: Metrics.space2) {
                if let project = state.currentProject {
                    let activeCount = activeBackgroundJobCount(for: project)
                    if activeCount > 0 {
                        Button { state.stage = .record } label: {
                            HStack(spacing: Metrics.space1_5) {
                                ProgressView().controlSize(.mini)
                                Text("\(activeCount) 项处理中")
                            }
                        }
                        .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                        .help("查看后台动效与字幕任务")
                    }
                    Button { showLibrary = true } label: {
                        Label(project.referenceMedia.isEmpty ? "素材库" : "素材库 (\(project.referenceMedia.count))",
                              systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                    .help("管理图片、视频等补充素材")
                    if state.stage == .assemble {
                        canvasMenu(for: project)
                    }
                    ProjectActionsMenu(project: project)
                    if state.stage == .assemble {
                        Button { showExport = true } label: {
                            Label { Text(verbatim: state.exportingProjects.contains(project.id) ? "正在导出" : "导出成片") } icon: { Image(systemName: "arrow.up.right") }
                        }
                        .buttonStyle(StudioButtonStyle(kind: .primary, size: .compact))
                        .disabled(project.materials.isEmpty || project.isFrozen || state.exportingProjects.contains(project.id))
                        .help(project.isFrozen ? "项目已冻结，取消冻结后再导出成片" : "导出成片")
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.space4)
        .frame(height: Metrics.header)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.surface2.opacity(0.6)).frame(height: 1)
        }
    }

    private func activeBackgroundJobCount(for project: VideoProject) -> Int {
        var seen: Set<UUID> = []
        var count = 0
        for material in project.materials where seen.insert(material.mediaID).inserted {
            if material.exportState == .running || material.transcriptState == .running
                || (material.wantsMotion && [.queued, .running].contains(material.motionState)) {
                count += 1
            }
        }
        return count
    }

    private func canvasLabel(for project: VideoProject) -> String {
        guard let w = project.canvasWidth, let h = project.canvasHeight else { return "跟随素材" }
        if Int(w) == 1920 && Int(h) == 1080 { return "16:9" }
        if Int(w) == 1080 && Int(h) == 1920 { return "9:16" }
        if Int(w) == 1080 && Int(h) == 1080 { return "1:1" }
        return "\(Int(w))×\(Int(h))"
    }

    private func canvasMenu(for project: VideoProject) -> some View {
        Menu {
            Button("横屏 16:9（1920 × 1080）") { state.setCanvas(project.id, width: 1920, height: 1080) }
            Button("竖屏 9:16（1080 × 1920）") { state.setCanvas(project.id, width: 1080, height: 1920) }
            Button("方形 1:1（1080 × 1080）") { state.setCanvas(project.id, width: 1080, height: 1080) }
            Divider()
            Button("跟随素材") { state.setCanvas(project.id, width: nil, height: nil) }
        } label: {
            Label(canvasLabel(for: project), systemImage: "aspectratio")
                .font(.studio(.small, weight: .medium))
                .padding(.horizontal, Metrics.space2)
                .frame(height: Metrics.controlCompact)
        }
        .menuStyle(StudioMenuStyle())
        .fixedSize()
        .disabled(project.isFrozen)
        .help("切换成片画幅")
        .accessibilityLabel("成片画幅：\(canvasLabel(for: project))")
    }

    private func frozenNotice(_ project: VideoProject) -> some View {
        HStack(spacing: Metrics.space2) {
            Image(systemName: "snowflake")
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            Text(state.unfreezingProjects.contains(project.id)
                 ? "正在重建项目依赖…"
                 : "项目已冻结，运行时依赖已清理。")
                .font(.studio(.small))
                .foregroundStyle(palette.textSecondary)
            Spacer()
            if state.unfreezingProjects.contains(project.id) {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("正在取消冻结")
            } else {
                Button("取消冻结") { state.unfreeze(project.id) }
                    .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                    .disabled(state.hasActiveJobs(project.id))
            }
        }
        .padding(.horizontal, Metrics.space5)
        .frame(height: Metrics.bar)
        .background(palette.surface1)
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
                    Text("第一期视频").font(.studio(.subhead))
                    Text("录制素材，再按顺序拼装成片。")
                        .font(.studio(.body)).foregroundStyle(palette.textSecondary)
                    Button("新建项目", systemImage: "plus", action: onCreate)
                        .buttonStyle(StudioButtonStyle(kind: .primary))
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.space10) {
                        WorkspaceHeading(title: "作品集。", detail: "每一期视频，都从这里开始。")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.inspector), spacing: Metrics.space7)], alignment: .leading, spacing: Metrics.space8) {
                            ForEach(state.projects) { project in
                                VStack(alignment: .leading, spacing: Metrics.space3) {
                                    Button { state.select(project.id) } label: {
                                        VStack(alignment: .leading, spacing: Metrics.space3) {
                                            MaterialThumbnail(url: project.materials.first.map { ProjectLayout.picture($0, in: project) })
                                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                            HStack(alignment: .firstTextBaseline) {
                                                Text(project.name).font(.studio(.bodyLargeMedium)).lineLimit(1)
                                                if project.isFrozen {
                                                    Image(systemName: "snowflake")
                                                        .font(.studio(.caption))
                                                        .foregroundStyle(palette.accent)
                                                        .accessibilityLabel("已冻结")
                                                }
                                                Spacer()
                                                Text(project.updatedAt, style: .date)
                                                    .font(.studio(.caption)).foregroundStyle(palette.textMuted)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(StudioContentButtonStyle())
                                    ProjectActionsRow(project: project)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 1100, alignment: .leading)
                    .padding(Metrics.space11)
                    .frame(maxWidth: .infinity)
                }
                .background(palette.bgBase)
            }
        }
    }
}

struct WindowConfigurator: NSViewRepresentable {
    var configuresChrome = true

    func makeNSView(context: Context) -> RegistrationView {
        let view = RegistrationView()
        view.configuresChrome = configuresChrome
        return view
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {}

    final class RegistrationView: NSView {
        var configuresChrome = true

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            WorkspaceRecordingTransition.shared.register(window)
            guard configuresChrome else { return }
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                NSApplication.shared.applicationIconImage = WorkspaceBrand.image(size: 1024)
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                if window.screen == nil || !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
                    window.center()
                }
            }
        }
    }
}
