import SwiftUI

@main
struct SuperWorkspaceApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("appearanceMode") private var appearanceMode = "dark"

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
        .defaultSize(width: 1280, height: 820)
        .defaultPosition(.center)
        .windowStyle(.hiddenTitleBar)
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
    @AppStorage("assemblyAIOpen") private var assemblyAIOpen = true
    @State private var libraryQuery = ""
    @State private var showNew = false
    @State private var showExport = false
    @State private var showLibrary = false

    var body: some View {
        VStack(spacing: 0) {
            workspaceHeader
            VStack(spacing: Metrics.space3) {
                if let project = state.currentProject, project.isFrozen {
                    frozenNotice(project)
                }
                Group {
                    if let project = state.currentProject {
                        VStack(spacing: Metrics.space3) {
                            Group {
                                switch state.stage {
                                case .record: RecordStepView(project: project)
                                case .assemble:
                                    AssemblyView(
                                        project: project,
                                        showsAIPanel: $assemblyAIOpen,
                                        onOpenLibrary: { showLibrary = true }
                                    )
                                case .library: ProjectMediaLibrary(projectID: project.id)
                                }
                            }
                            .id(project.id)
                            ExportResultBar(project: project)
                        }
                    } else {
                        ProjectLibraryView(searchQuery: $libraryQuery, onCreate: { showNew = true })
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(Metrics.space3)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background {
            Button("新建项目") { showNew = true }
                .keyboardShortcut("n", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            state.shutdownAssemblyAgents()
            state.saveSession()
        }
        .tint(palette.accent)
        .foregroundStyle(palette.textPrimary)
        .background(palette.stage)
        .sheet(isPresented: $showNew) { NewProjectSheet().environmentObject(state) }
        .sheet(isPresented: $showExport) {
            if let project = state.currentProject { MovieExportSheet(project: project).environmentObject(state) }
        }
        .sheet(isPresented: $showLibrary) {
            if let project = state.currentProject {
                VStack(spacing: 0) {
                    ProjectMediaLibrary(projectID: project.id)
                        .environmentObject(state)
                    Rectangle().fill(palette.hairline).frame(height: 1)
                    HStack {
                        Spacer()
                        Button { showLibrary = false } label: { Text(verbatim: "完成") }
                            .buttonStyle(StudioButtonStyle(kind: .primary, size: .compact))
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(.horizontal, Metrics.space5)
                    .frame(height: Metrics.bar + 4)
                    .background(palette.island)
                }
                .frame(minWidth: 720, idealWidth: 840, minHeight: 480, idealHeight: 560)
                .background(palette.island)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let toast = state.toast {
                Text(toast)
                    .font(.studio(.small, weight: .medium))
                    .padding(.horizontal, Metrics.space4)
                    .padding(.vertical, Metrics.space2_5)
                    .studioIsland(cornerRadius: Metrics.radiusL)
                    .padding(Metrics.space6)
            }
        }
        .overlay(alignment: .top) {
            budgetBanner.padding(.top, Metrics.header + Metrics.space4)
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
            .studioIsland(cornerRadius: Metrics.radiusIsland)
            .padding(.horizontal, Metrics.space6)
        }
    }

    /// Unified DogSC-style chrome bar integrated directly with the macOS titlebar traffic lights.
    private var workspaceHeader: some View {
        ZStack {
            HStack(spacing: Metrics.space2_5) {
                // Left: Brand / Project Switcher (cleared past traffic lights)
                if let project = state.currentProject {
                    projectSwitcherMenu(current: project)
                    let activeCount = activeBackgroundJobCount(for: project)
                    if activeCount > 0 {
                        Button { state.stage = .record } label: {
                            HStack(spacing: Metrics.space1_5) {
                                ProgressView().controlSize(.mini)
                                Text("\(activeCount) 项处理中").monospacedDigit()
                            }
                            .font(.studio(.caption, weight: .medium))
                            .foregroundStyle(palette.ai)
                            .padding(.horizontal, Metrics.space2_5)
                            .frame(height: 24)
                            .background(palette.ai.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(StudioContentButtonStyle(cornerRadius: 999))
                        .help("查看后台动效与字幕任务")
                    } else {
                        HStack(spacing: Metrics.space1_5) {
                            Circle().fill(palette.success).frame(width: 6, height: 6)
                            Text("已保存")
                        }
                        .font(.studio(.caption))
                        .foregroundStyle(palette.textSecondary)
                        .padding(.horizontal, Metrics.space2_5)
                        .frame(height: 24)
                        .background(palette.cardFill, in: Capsule())
                    }
                } else {
                    HStack(spacing: Metrics.space2) {
                        Image(nsImage: WorkspaceBrand.image(size: 20))
                            .resizable().frame(width: 20, height: 20).accessibilityHidden(true)
                        Text("SuperWorkspace")
                            .font(.studio(.bodyMedium, weight: .semibold))
                            .foregroundStyle(palette.textPrimary)
                    }
                }

                Spacer(minLength: Metrics.space2)

                // Right: Contextual Actions
                HStack(spacing: Metrics.space2) {
                    if let project = state.currentProject {
                        Button { showLibrary = true } label: {
                            Label(project.referenceMedia.isEmpty ? "素材库" : "素材库 (\(project.referenceMedia.count))",
                                  systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(StudioButtonStyle(kind: .secondary, size: .compact))
                        .help("管理图片、视频等补充素材")

                        if state.stage == .assemble {
                            Button {
                                withAnimation(StudioMotion.settle) {
                                    assemblyAIOpen.toggle()
                                }
                            } label: {
                                Label("AI 导演", systemImage: "sparkles")
                                    .font(.studio(.small, weight: .medium))
                                    .foregroundStyle(assemblyAIOpen ? palette.textPrimary : palette.textSecondary)
                                    .padding(.horizontal, Metrics.space3)
                                    .frame(height: Metrics.controlCompact)
                                    .background(assemblyAIOpen ? palette.selectionWash : palette.controlWell, in: Capsule())
                                    .overlay {
                                        Capsule().strokeBorder(palette.islandOutline, lineWidth: 1)
                                    }
                            }
                            .buttonStyle(StudioContentButtonStyle(cornerRadius: 999))
                            .help(assemblyAIOpen ? "收起 AI 剪辑导演" : "展开 AI 剪辑导演")
                            .accessibilityLabel(assemblyAIOpen ? "收起 AI 剪辑导演" : "展开 AI 剪辑导演")
                        }

                        ProjectActionsMenu(project: project)

                        SettingsLink {
                            Image(systemName: "gearshape")
                        }
                        .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                        .accessibilityLabel("设置")
                        .help("设置")

                        if state.stage == .assemble {
                            Button { showExport = true } label: {
                                Label { Text(verbatim: state.exportingProjects.contains(project.id) ? "正在导出" : "导出") } icon: { Image(systemName: "arrow.up.to.line") }
                            }
                            .buttonStyle(StudioButtonStyle(kind: .primary, size: .compact))
                            .disabled(project.materials.isEmpty || project.isFrozen || state.exportingProjects.contains(project.id))
                            .help(project.isFrozen ? "项目已冻结，取消冻结后再导出成片" : "导出成片")
                        }
                    } else {
                        SettingsLink {
                            Label("设置", systemImage: "gearshape")
                        }
                        .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                        .accessibilityLabel("设置")

                        Button { showNew = true } label: {
                            Label("新建项目", systemImage: "plus")
                        }
                        .buttonStyle(StudioButtonStyle(kind: .primary, size: .compact))
                    }
                }
            }

            // Center: Capsule Stage Switcher (in project) or Search Pill (in library)
            if state.currentProject != nil {
                HStack(spacing: Metrics.space0_5) {
                    stageSegment(stage: .record, title: "素材")
                    stageSegment(stage: .assemble, title: "拼装")
                }
                .padding(3)
                .background(palette.controlWell, in: Capsule())
            } else if !state.projects.isEmpty {
                StudioSearchField(placeholder: "搜索项目…", text: $libraryQuery)
                    .frame(width: 280)
            }
        }
        .padding(.leading, 80)
        .padding(.trailing, Metrics.space4)
        .frame(height: Metrics.header)
        .background(palette.island)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.hairline).frame(height: 1)
        }
    }

    private func stageSegment(stage: WorkStage, title: String) -> some View {
        let selected = state.stage == stage
        return Button {
            withAnimation(StudioMotion.interactive) {
                state.stage = stage
            }
        } label: {
            Text(title)
                .font(.studio(.small, weight: selected ? .semibold : .medium))
                .padding(.horizontal, Metrics.space4)
                .frame(height: Metrics.controlCompact)
        }
        .buttonStyle(StudioSelectionStyle(selected: selected, cornerRadius: 999))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func projectSwitcherMenu(current: VideoProject) -> some View {
        Menu {
            Button {
                state.selectedProjectID = nil
            } label: {
                Label("返回项目库", systemImage: "square.grid.2x2")
            }
            Button {
                showNew = true
            } label: {
                Label("新建项目", systemImage: "plus")
            }
            if !state.projects.isEmpty {
                Divider()
                ForEach(state.projects) { project in
                    Button {
                        state.select(project.id)
                    } label: {
                        if project.id == current.id {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Label(project.name, systemImage: project.isFrozen ? "snowflake" : "film")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Metrics.space1_5) {
                Image(systemName: "square.grid.2x2")
                    .font(.studio(.caption, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                Text(current.name)
                    .font(.studio(.small, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: 190, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.studio(.micro, weight: .semibold))
                    .foregroundStyle(palette.textMuted)
            }
        }
        .menuStyle(StudioMenuStyle(surface: .pill))
        .fixedSize()
        .help("切换项目或返回项目库")
        .accessibilityLabel("当前项目：\(current.name)")
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

    private func frozenNotice(_ project: VideoProject) -> some View {
        HStack(spacing: Metrics.space2) {
            Image(systemName: "snowflake")
                .foregroundStyle(palette.textSecondary)
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
                    .buttonStyle(StudioButtonStyle(kind: .secondary, size: .compact))
                    .disabled(state.hasActiveJobs(project.id))
            }
        }
        .padding(.horizontal, Metrics.space4)
        .frame(height: Metrics.bar)
        .studioIsland(cornerRadius: Metrics.radiusL, shadow: false)
    }
}

struct ProjectLibraryView: View {
    enum Filter: String, CaseIterable {
        case all = "全部"
        case active = "进行中"
        case frozen = "已冻结"
    }

    enum SortOrder: String, CaseIterable {
        case updated = "最近修改"
        case created = "创建时间"
        case name = "名称"
    }

    @Environment(\.palette) private var palette
    @EnvironmentObject private var state: AppState
    @Binding var searchQuery: String
    @State private var filter: Filter = .all
    @State private var sortOrder: SortOrder = .updated
    @State private var renamingProject: VideoProject?
    @State private var deletingProject: VideoProject?
    let onCreate: () -> Void

    private var filteredProjects: [VideoProject] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = state.projects.filter { project in
            let matchesFilter: Bool = switch filter {
            case .all: true
            case .active: !project.isFrozen
            case .frozen: project.isFrozen
            }
            let matchesQuery = query.isEmpty || project.name.localizedCaseInsensitiveContains(query)
            return matchesFilter && matchesQuery
        }
        switch sortOrder {
        case .updated: return matching.sorted { $0.updatedAt > $1.updatedAt }
        case .created: return matching.sorted { $0.createdAt > $1.createdAt }
        case .name: return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        Group {
            if state.projects.isEmpty {
                StudioWorkspace(title: "新建第一个项目", detail: "录制屏幕演示与讲解，自动识别字幕并按顺序拼装成片。") {
                    StudioPreview(symbol: "macwindow", title: "你的作品，从这里开始")
                } controls: {
                    Button("新建项目", systemImage: "plus", action: onCreate)
                        .buttonStyle(StudioButtonStyle(kind: .primary))
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.space5) {
                        HStack(spacing: Metrics.space3) {
                            HStack(alignment: .firstTextBaseline, spacing: Metrics.space2_5) {
                                Text("项目库").font(.studio(.heading))
                                Text("\(filteredProjects.count) 个项目")
                                    .font(.studio(.small))
                                    .foregroundStyle(palette.textMuted)
                                    .monospacedDigit()
                            }
                            Spacer()
                            Menu {
                                ForEach(SortOrder.allCases, id: \.self) { order in
                                    Button {
                                        sortOrder = order
                                    } label: {
                                        if sortOrder == order {
                                            Label(order.rawValue, systemImage: "checkmark")
                                        } else {
                                            Text(order.rawValue)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: Metrics.space1) {
                                    Image(systemName: "arrow.up.arrow.down")
                                        .font(.studio(.micro))
                                    Text(sortOrder.rawValue)
                                        .font(.studio(.caption, weight: .medium))
                                }
                                .foregroundStyle(palette.textSecondary)
                            }
                            .menuStyle(StudioMenuStyle(surface: .pill, compact: true))
                            .fixedSize()
                            .help("排序方式")
                            .accessibilityLabel("排序方式：\(sortOrder.rawValue)")

                            HStack(spacing: Metrics.space0_5) {
                                ForEach(Filter.allCases, id: \.self) { item in
                                    Button {
                                        withAnimation(StudioMotion.interactive) { filter = item }
                                    } label: {
                                        Text(item.rawValue)
                                            .font(.studio(.caption, weight: filter == item ? .semibold : .medium))
                                            .padding(.horizontal, Metrics.space2_5)
                                            .frame(height: 24)
                                    }
                                    .buttonStyle(StudioSelectionStyle(selected: filter == item, cornerRadius: 999))
                                    .accessibilityAddTraits(filter == item ? .isSelected : [])
                                }
                            }
                            .padding(3)
                            .background(palette.controlWell, in: Capsule())
                        }

                        if filteredProjects.isEmpty {
                            VStack(spacing: Metrics.space3) {
                                Text("没有匹配的项目")
                                    .font(.studio(.bodyMedium))
                                    .foregroundStyle(palette.textPrimary)
                                Text("试试更换搜索关键词或切换到「全部」视图。")
                                    .font(.studio(.small))
                                    .foregroundStyle(palette.textSecondary)
                                Button("清除筛选") {
                                    searchQuery = ""
                                    filter = .all
                                }
                                .buttonStyle(StudioButtonStyle(kind: .secondary, size: .compact))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Metrics.space11)
                            .studioIsland(cornerRadius: Metrics.radiusIsland)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 290, maximum: 420), spacing: Metrics.space4)],
                                alignment: .leading,
                                spacing: Metrics.space4
                            ) {
                                ForEach(filteredProjects) { project in
                                    projectCard(project)
                                }
                                if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && filter != .frozen {
                                    newProjectCard
                                }
                            }
                        }
                    }
                    .frame(maxWidth: Metrics.contentWide, alignment: .leading)
                    .padding(.horizontal, Metrics.space6)
                    .padding(.vertical, Metrics.space5)
                    .frame(maxWidth: .infinity)
                }
                .background(palette.stage)
                .sheet(item: $renamingProject) { project in
                    RenameProjectSheet(project: project).environmentObject(state)
                }
                .sheet(item: $deletingProject) { project in
                    StudioMessageSheet(
                        title: "删除「\(project.name)」？",
                        message: "项目文件夹（包含录制素材、字幕、动效与成片）将移至废纸篓，可从废纸篓恢复。",
                        actionTitle: "移至废纸篓",
                        cancelTitle: "取消",
                        destructive: true
                    ) {
                        state.deleteProject(project.id)
                    }
                }
            }
        }
    }

    private func projectCard(_ project: VideoProject) -> some View {
        let totalDuration = project.materials.reduce(0) { $0 + $1.timelineDuration }
        return VStack(alignment: .leading, spacing: Metrics.space2_5) {
            Button { state.select(project.id) } label: {
                VStack(alignment: .leading, spacing: Metrics.space2_5) {
                    ZStack(alignment: .bottomTrailing) {
                        MaterialThumbnail(url: project.materials.first.map { ProjectLayout.picture($0, in: project) })
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        if totalDuration > 0 {
                            Text(durationLabel(totalDuration))
                                .font(.studio(.timecode, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, Metrics.space2)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.75), in: Capsule())
                                .padding(Metrics.space2)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if project.isFrozen {
                            Label("已冻结", systemImage: "snowflake")
                                .font(.studio(.micro, weight: .medium))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, Metrics.space2)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.75), in: Capsule())
                                .padding(Metrics.space2)
                        }
                    }

                    VStack(alignment: .leading, spacing: Metrics.space1) {
                        HStack(alignment: .firstTextBaseline, spacing: Metrics.space2) {
                            Text(project.name)
                                .font(.studio(.bodyMedium))
                                .foregroundStyle(palette.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: Metrics.space1)
                            Text(project.updatedAt, style: .date)
                                .font(.studio(.caption))
                                .foregroundStyle(palette.textMuted)
                        }
                        HStack(spacing: Metrics.space1_5) {
                            Text("\(project.materials.count) 段素材")
                                .monospacedDigit()
                            if project.lastExportName != nil {
                                Text("· 已导出成片")
                                    .foregroundStyle(palette.success)
                            }
                        }
                        .font(.studio(.caption))
                        .foregroundStyle(palette.textSecondary)
                    }
                    .padding(.horizontal, Metrics.space1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(StudioContentButtonStyle())

            ProjectActionsRow(project: project)
                .padding(.horizontal, Metrics.space1)
        }
        .padding(Metrics.space2_5)
        .studioIsland(cornerRadius: Metrics.radiusIsland)
        .contextMenu {
            ProjectActionItems(
                project: project,
                onRename: { renamingProject = project },
                onDelete: { deletingProject = project }
            )
        }
    }

    private var newProjectCard: some View {
        Button(action: onCreate) {
            VStack(spacing: Metrics.space2_5) {
                Image(systemName: "plus")
                    .font(.studio(.title, weight: .medium))
                    .foregroundStyle(palette.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(palette.controlWell, in: Circle())
                Text("新建项目")
                    .font(.studio(.bodyMedium))
                    .foregroundStyle(palette.textPrimary)
                Text("⌘N")
                    .font(.studio(.caption))
                    .foregroundStyle(palette.textMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 210)
            .background(palette.cardFill, in: RoundedRectangle(cornerRadius: Metrics.radiusIsland, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.radiusIsland, style: .continuous)
                    .strokeBorder(palette.islandOutline, style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
            }
        }
        .buttonStyle(StudioContentButtonStyle(cornerRadius: Metrics.radiusIsland))
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
                window.titlebarSeparatorStyle = .none
                if !window.styleMask.contains(.fullSizeContentView) {
                    window.styleMask.insert(.fullSizeContentView)
                }
                if window.screen == nil || !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
                    window.center()
                }
            }
        }
    }
}
