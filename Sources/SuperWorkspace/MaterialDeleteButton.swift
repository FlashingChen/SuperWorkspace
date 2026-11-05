import SwiftUI

struct MaterialActionsMenu: View {
    let projectID: UUID
    let materialID: UUID
    @State private var pendingRemoval: UUID?

    var body: some View {
        Menu {
            MaterialDeleteAction(projectID: projectID, materialID: materialID) { pendingRemoval = materialID }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多操作")
        .accessibilityLabel("素材更多操作")
        .modifier(MaterialRemovalConfirmation(projectID: projectID, materialID: $pendingRemoval))
    }
}

struct MaterialDeleteAction: View {
    @EnvironmentObject private var state: AppState
    let projectID: UUID
    let materialID: UUID
    let onRequest: () -> Void

    private var material: Material? {
        state.projects.first(where: { $0.id == projectID })?.materials.first(where: { $0.id == materialID })
    }

    var body: some View {
        Button(role: .destructive, action: onRequest) {
            Label("删除素材", systemImage: "trash")
        }
        .disabled(material == nil || material?.exportState == .running || state.exportingProjects.contains(projectID))
    }
}

struct MaterialRemovalConfirmation: ViewModifier {
    @EnvironmentObject private var state: AppState
    let projectID: UUID
    @Binding var materialID: UUID?

    func body(content: Content) -> some View {
        content.confirmationDialog("删除这段素材？", isPresented: Binding(
            get: { materialID != nil }, set: { if !$0 { materialID = nil } }),
            titleVisibility: .visible, presenting: materialID) { id in
            Button("删除素材", role: .destructive) { state.removeMaterial(projectID, id) }
            Button("取消", role: .cancel) { }
        } message: { _ in
            Text("素材及其字幕将从当前项目移除，相关后台任务会取消。原始文件保留。")
        }
    }
}
