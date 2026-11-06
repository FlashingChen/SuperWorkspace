import SwiftUI

struct CompactProjectPanel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    @Binding var expanded: Bool
    let onCreate: () -> Void

    var body: some View {
        Group {
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Button { expanded = false } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                            .accessibilityLabel("收起项目列表").help("收起项目列表")
                        Button { state.selectedProjectID = nil } label: {
                            Text("我的项目").font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                        .accessibilityLabel("查看所有项目")
                    }
                    Button(action: onCreate) {
                        HStack {
                            Image(systemName: "plus")
                            Text("新建项目")
                            Spacer(minLength: 0)
                            Text("⌘N").font(.system(size: 10)).foregroundStyle(palette.textMuted)
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(StudioButtonStyle())
                    .keyboardShortcut("n", modifiers: .command)

                    if state.projects.isEmpty {
                        Text("还没有项目").font(.system(size: 12)).foregroundStyle(palette.textSecondary)
                            .padding(.vertical, 12).padding(.horizontal, 8)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(state.projects) { project in
                                    let selected = state.selectedProjectID == project.id
                                    Button { state.select(project.id) } label: {
                                        HStack(spacing: 8) {
                                            Text(project.name).font(.system(size: 12, weight: selected ? .semibold : .regular))
                                                .lineLimit(1).truncationMode(.middle)
                                            Spacer(minLength: 0)
                                            if selected {
                                                Circle().fill(palette.accent).frame(width: 5, height: 5)
                                                    .accessibilityHidden(true)
                                            }
                                        }
                                        .padding(.horizontal, 8).frame(height: 36)
                                        .background(selected ? palette.surface1 : .clear, in: RoundedRectangle(cornerRadius: 6))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(StudioContentButtonStyle())
                                    .accessibilityAddTraits(selected ? .isSelected : [])
                                    .help(project.name)
                                    Rectangle().fill(palette.surface2.opacity(0.6)).frame(height: 1)
                                        .padding(.horizontal, 8)
                                }
                            }
                        }
                        .frame(height: min(CGFloat(state.projects.count) * 37, 296))
                    }
                    Button { state.selectedProjectID = nil } label: {
                        HStack {
                            Text("所有项目")
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.system(size: 10))
                        }.frame(maxWidth: .infinity)
                    }
                    .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                }
                .padding(12).frame(width: 200)
                .foregroundStyle(palette.textPrimary)
                .background(palette.bgSidebar, in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 8) {
                    Button { expanded = true } label: { Image(systemName: "sidebar.left") }
                        .accessibilityLabel("展开项目列表").help("展开项目列表")
                    Button(action: onCreate) { Image(systemName: "plus") }
                        .accessibilityLabel("新建项目").help("新建项目")
                        .keyboardShortcut("n", modifiers: .command)
                }
                .buttonStyle(StudioButtonStyle(kind: .quiet))
                .padding(4).background(palette.bgSidebar, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("项目导航")
    }
}
