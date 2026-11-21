import SwiftUI

/// Full project management actions shared across the header menu, library cards, and context menus.
struct ProjectActionItems: View {
    @EnvironmentObject private var state: AppState
    let project: VideoProject
    var onRename: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    private var busy: Bool {
        state.hasActiveJobs(project.id)
    }

    var body: some View {
        if let onRename {
            Button("重命名项目", systemImage: "pencil", action: onRename)
        }
        Button("在 Finder 中显示", systemImage: "folder") {
            state.revealProjectInFinder(project.id)
        }
        Button("打包导出", systemImage: "shippingbox") {
            state.exportBundle(project.id)
        }
        .disabled(state.exportingProjects.contains(project.id) || state.bundlingProjects.contains(project.id))

        Divider()

        if project.isFrozen {
            Button("取消冻结", systemImage: "sun.max") { state.unfreeze(project.id) }
                .disabled(state.unfreezingProjects.contains(project.id) || state.hasActiveJobs(project.id))
        } else {
            Button("冻结项目", systemImage: "snowflake") { state.freeze(project.id) }
                .disabled(!state.canFreeze(project.id))
        }

        if let onDelete {
            Divider()
            Button("删除项目", systemImage: "trash", role: .destructive, action: onDelete)
                .disabled(busy)
        }
    }
}

struct ProjectActionsMenu: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    let project: VideoProject
    @State private var showRename = false
    @State private var showDelete = false

    var body: some View {
        Menu {
            ProjectActionItems(
                project: project,
                onRename: { showRename = true },
                onDelete: { showDelete = true }
            )
        } label: {
            Image(systemName: "ellipsis")
                .font(.studio(.small, weight: .semibold))
                .foregroundStyle(palette.textSecondary)
        }
        .menuStyle(StudioMenuStyle())
        .fixedSize()
        .help("项目管理")
        .accessibilityLabel("项目管理")
        .sheet(isPresented: $showRename) {
            RenameProjectSheet(project: project).environmentObject(state)
        }
        .sheet(isPresented: $showDelete) {
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

/// Inline footer row for library cards: quick archive/freeze plus full management menu.
struct ProjectActionsRow: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    let project: VideoProject
    @State private var showRename = false
    @State private var showDelete = false

    private var bundling: Bool { state.bundlingProjects.contains(project.id) }
    private var freezing: Bool { state.freezingProjects.contains(project.id) }
    private var unfreezing: Bool { state.unfreezingProjects.contains(project.id) }

    var body: some View {
        HStack(spacing: Metrics.space1) {
            Button {
                state.exportBundle(project.id)
            } label: {
                Label(bundling ? "打包中" : "打包导出", systemImage: "shippingbox")
            }
            .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
            .disabled(bundling || freezing || unfreezing || state.exportingProjects.contains(project.id))
            .help("把源素材、动效与成片压缩为一个 ZIP")

            if project.isFrozen {
                Button("取消冻结") { state.unfreeze(project.id) }
                    .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                    .disabled(unfreezing || state.hasActiveJobs(project.id))
                    .help("重建项目运行时会用到的依赖")
            } else {
                Button(freezing ? "冻结中" : "冻结") { state.freeze(project.id) }
                    .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                    .disabled(!state.canFreeze(project.id))
                    .help(state.canFreeze(project.id) ? "清理运行时会用到的依赖，保留素材、动效与成片" : "导出成片后可冻结项目")
            }

            Spacer(minLength: 0)

            Menu {
                ProjectActionItems(
                    project: project,
                    onRename: { showRename = true },
                    onDelete: { showDelete = true }
                )
            } label: {
                Image(systemName: "ellipsis")
                    .font(.studio(.small, weight: .semibold))
                    .foregroundStyle(palette.textSecondary)
            }
            .menuStyle(StudioMenuStyle())
            .fixedSize()
            .help("更多项目操作")
            .accessibilityLabel("更多项目操作")
        }
        .sheet(isPresented: $showRename) {
            RenameProjectSheet(project: project).environmentObject(state)
        }
        .sheet(isPresented: $showDelete) {
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

struct RenameProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @EnvironmentObject private var state: AppState
    let project: VideoProject
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space5) {
            Text("重命名项目")
                .font(.studio(.heading))
            TextField("项目名称", text: $draft)
                .textFieldStyle(StudioTextFieldStyle())
                .font(.studio(.body))
                .focused($focused)
                .onSubmit(save)
            HStack(spacing: Metrics.space2) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(StudioButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .buttonStyle(StudioButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || draft.trimmingCharacters(in: .whitespacesAndNewlines) == project.name)
            }
        }
        .foregroundStyle(palette.textPrimary)
        .padding(Metrics.space6)
        .frame(width: 400)
        .background(palette.island)
        .onAppear {
            draft = project.name
            focused = true
        }
    }

    private func save() {
        if state.renameProject(project.id, name: draft) {
            dismiss()
        }
    }
}
