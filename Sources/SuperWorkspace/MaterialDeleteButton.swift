import SwiftUI

struct MaterialDeleteButton: View {
    @EnvironmentObject private var state: AppState
    let projectID: UUID
    let materialID: UUID?
    @State private var confirming = false

    private var material: Material? {
        state.projects.first(where: { $0.id == projectID })?.materials.first(where: { $0.id == materialID })
    }

    var body: some View {
        Button(role: .destructive) { confirming = true } label: {
            Label("删除素材", systemImage: "trash")
        }
        .buttonStyle(.borderless)
        .disabled(material == nil || material?.exportState == .running || state.exportingProjects.contains(projectID))
        .help(materialID == nil ? "先选择视频素材" : "从项目删除素材，保留原始文件")
        .confirmationDialog("删除这段素材？", isPresented: $confirming, titleVisibility: .visible) {
            Button("删除素材", role: .destructive) {
                if let materialID { state.removeMaterial(projectID, materialID) }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("素材及其字幕将从当前项目移除，相关后台任务会取消。原始文件保留。")
        }
    }
}
