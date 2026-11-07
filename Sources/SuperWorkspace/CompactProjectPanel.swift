import SwiftUI

struct CompactProjectPanel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    @Binding var expanded: Bool
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.space1) {
                if expanded {
                    Button { state.selectedProjectID = nil } label: {
                        HStack(spacing: Metrics.space2) {
                            Image(nsImage: WorkspaceBrand.image(size: 24))
                                .resizable().frame(width: 24, height: 24).accessibilityHidden(true)
                            Text("SuperWorkspace").font(.studio(.smallStrong))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(StudioContentButtonStyle())
                    .accessibilityLabel("返回项目库")
                }
                Button { expanded.toggle() } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                    .accessibilityLabel(expanded ? "收起侧栏" : "展开侧栏")
                    .help(expanded ? "收起侧栏" : "展开侧栏")
            }
            .frame(maxWidth: .infinity).frame(height: Metrics.header)

            Button(action: onCreate) {
                HStack(spacing: Metrics.space2_5) {
                    Image(systemName: "plus")
                    if expanded {
                        Text("新建项目")
                        Spacer(minLength: 0)
                        Text("⌘N").font(.studio(.micro)).foregroundStyle(palette.textMuted)
                    }
                }.frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            }
            .buttonStyle(StudioButtonStyle(kind: .quiet))
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityLabel("新建项目").help("新建项目")

            Button { state.selectedProjectID = nil } label: {
                HStack(spacing: Metrics.space2_5) {
                    Image(systemName: "square.grid.2x2")
                    if expanded { Text("项目库"); Spacer(minLength: 0) }
                }.frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
                    .padding(.horizontal, Metrics.space2).frame(height: Metrics.choice)
                    .background(state.currentProject == nil ? palette.surface2.opacity(0.55) : .clear,
                                in: RoundedRectangle(cornerRadius: Metrics.radiusM))
            }
            .buttonStyle(StudioContentButtonStyle())
            .accessibilityLabel("项目库").help("项目库")
            .accessibilityAddTraits(state.currentProject == nil ? .isSelected : [])
            .padding(.top, Metrics.space1)

            if expanded {
                Text("最近项目").font(.studio(.caption))
                    .foregroundStyle(palette.textMuted)
                    .padding(.horizontal, Metrics.space2).padding(.top, Metrics.space7).padding(.bottom, Metrics.space2_5)
                ScrollView {
                    LazyVStack(spacing: Metrics.space0_5) {
                        ForEach(state.projects) { project in
                            let selected = state.selectedProjectID == project.id
                            Button { state.select(project.id) } label: {
                                HStack(spacing: Metrics.space2_5) {
                                    Image(systemName: "film")
                                        .font(.system(size: 12)).foregroundStyle(palette.textMuted)
                                        .accessibilityHidden(true)
                                    Text(project.name)
                                        .font(.studio(selected ? .bodyMedium : .body))
                                        .foregroundStyle(selected ? palette.textPrimary : palette.textSecondary)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, Metrics.space2).frame(height: Metrics.row)
                                .background(selected ? palette.surface2.opacity(0.55) : .clear,
                                            in: RoundedRectangle(cornerRadius: Metrics.radiusM))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(StudioContentButtonStyle())
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .help(project.name)
                        }
                        if state.projects.isEmpty {
                            Text("还没有项目").font(.studio(.small)).foregroundStyle(palette.textMuted)
                                .padding(Metrics.space2).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            Spacer(minLength: Metrics.space4)
            SettingsLink {
                HStack(spacing: Metrics.space2_5) {
                    Image(systemName: "slider.horizontal.3")
                    if expanded { Text("设置"); Spacer(minLength: 0) }
                }.frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            }
            .buttonStyle(StudioButtonStyle(kind: .quiet))
            .accessibilityLabel("设置").help("设置")
            .padding(.bottom, Metrics.space4)
        }
        .padding(.horizontal, expanded ? Metrics.space3 : Metrics.space2)
        .frame(width: expanded ? Metrics.sidebar : Metrics.sidebarRail, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(palette.textPrimary)
        .background(palette.bgSidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(palette.surface2.opacity(0.5)).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("项目导航")
    }
}
