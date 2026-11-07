import SwiftUI

struct CompactProjectPanel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    @Binding var expanded: Bool
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if expanded {
                    Button { state.selectedProjectID = nil } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: WorkspaceBrand.image(size: 24))
                                .resizable().frame(width: 24, height: 24).accessibilityHidden(true)
                            Text("SuperWorkspace").font(.system(size: 12, weight: .semibold))
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
            .frame(maxWidth: .infinity).frame(height: 80)

            Button(action: onCreate) {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                    if expanded {
                        Text("新建项目")
                        Spacer(minLength: 0)
                        Text("⌘N").font(.system(size: 10)).foregroundStyle(palette.textMuted)
                    }
                }.frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            }
            .buttonStyle(StudioButtonStyle(kind: .quiet))
            .keyboardShortcut("n", modifiers: .command)
            .accessibilityLabel("新建项目").help("新建项目")

            Button { state.selectedProjectID = nil } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2")
                    if expanded { Text("项目库"); Spacer(minLength: 0) }
                }.frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
                    .padding(.horizontal, 8).frame(height: 36)
                    .background(state.currentProject == nil ? palette.surface2.opacity(0.55) : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(StudioContentButtonStyle())
            .accessibilityLabel("项目库").help("项目库")
            .accessibilityAddTraits(state.currentProject == nil ? .isSelected : [])
            .padding(.top, 4)

            if expanded {
                Text("最近项目").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textMuted)
                    .padding(.horizontal, 8).padding(.top, 28).padding(.bottom, 10)
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(state.projects) { project in
                            let selected = state.selectedProjectID == project.id
                            Button { state.select(project.id) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "film")
                                        .font(.system(size: 12)).foregroundStyle(palette.textMuted)
                                        .accessibilityHidden(true)
                                    Text(project.name)
                                        .font(.system(size: 13, weight: selected ? .medium : .regular))
                                        .foregroundStyle(selected ? palette.textPrimary : palette.textSecondary)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8).frame(height: 34)
                                .background(selected ? palette.surface2.opacity(0.55) : .clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(StudioContentButtonStyle())
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .help(project.name)
                        }
                        if state.projects.isEmpty {
                            Text("还没有项目").font(.system(size: 12)).foregroundStyle(palette.textMuted)
                                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            Spacer(minLength: 16)
            SettingsLink {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                    if expanded { Text("设置"); Spacer(minLength: 0) }
                }.frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            }
            .buttonStyle(StudioButtonStyle(kind: .quiet))
            .accessibilityLabel("设置").help("设置")
            .padding(.bottom, 16)
        }
        .padding(.horizontal, expanded ? 14 : 8)
        .frame(width: expanded ? 220 : 56, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(palette.textPrimary)
        .background(palette.bgSidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(palette.surface2.opacity(0.5)).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("项目导航")
    }
}
