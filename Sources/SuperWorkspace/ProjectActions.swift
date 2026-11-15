import SwiftUI

/// Freeze and bundle actions, shared by the project library, the sidebar and the header.
struct ProjectActionItems: View {
    @EnvironmentObject private var state: AppState
    let project: VideoProject

    var body: some View {
        Button("打包导出", systemImage: "shippingbox") { state.exportBundle(project.id) }
            .disabled(state.exportingProjects.contains(project.id) || state.bundlingProjects.contains(project.id))
        Divider()
        if project.isFrozen {
            Button("取消冻结", systemImage: "sun.max") { state.unfreeze(project.id) }
                .disabled(state.unfreezingProjects.contains(project.id) || state.hasActiveJobs(project.id))
        } else {
            Button("冻结项目", systemImage: "snowflake") { state.freeze(project.id) }
                .disabled(!state.canFreeze(project.id))
        }
    }
}

struct ProjectActionsMenu: View {
    let project: VideoProject

    var body: some View {
        Menu {
            ProjectActionItems(project: project)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(StudioMenuStyle())
        .fixedSize()
        .accessibilityLabel("项目操作")
    }
}

/// Inline variant for library cards: the two actions a finished project needs.
struct ProjectActionsRow: View {
    @EnvironmentObject private var state: AppState
    let project: VideoProject

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

            Spacer(minLength: 0)

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
        }
    }
}
