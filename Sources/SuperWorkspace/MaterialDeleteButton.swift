import SwiftUI

struct MaterialActionsMenu: View {
    let projectID: UUID
    let materialID: UUID
    @State private var pendingRemoval: UUID?

    var body: some View {
        Menu {
            MaterialProcessingActions(projectID: projectID, materialID: materialID)
            Divider()
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

struct MaterialProcessingActions: View {
    @EnvironmentObject private var state: AppState
    let projectID: UUID
    let materialID: UUID
    private var material: Material? {
        state.projects.first(where: { $0.id == projectID })?.materials.first(where: { $0.id == materialID })
    }
    var body: some View {
        if let material {
            if material.wantsMotion {
                Button(material.useOriginal == true ? "使用动效" : "使用原片") {
                    state.setUseOriginal(projectID, materialID, material.useOriginal != true)
                }
                .disabled(material.useOriginal == true && material.motionState != .complete)
                if [.queued, .running].contains(material.motionState) {
                    Button("取消动效") { state.cancelProcessing(projectID, materialID, motion: true) }
                } else if material.motionState == .failed {
                    Button("重试动效") { state.enqueueMotion(projectID, materialID) }
                }
            }
            if material.transcriptState == .running {
                Button("取消字幕处理") { state.cancelProcessing(projectID, materialID, motion: false) }
            } else if material.exportState == .complete {
                Button(material.transcriptState == .complete ? "重新识别字幕" : "识别字幕") { state.transcribe(projectID, materialID) }
            }
        }
    }
}

struct MaterialTaskStatus: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    let projectID: UUID
    let material: Material
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if material.wantsMotion && material.motionState != .complete {
                HStack {
                    if material.motionState == .running { ProgressView().controlSize(.small) }
                    Text(material.motionLabel ?? "原片可用")
                    Spacer()
                    if [.running, .queued].contains(material.motionState) {
                        Button("取消") { state.cancelProcessing(projectID, material.id, motion: true) }
                    } else if material.motionState == .failed {
                        Button("重试") { state.enqueueMotion(projectID, material.id) }
                    }
                }
                if let error = material.motionError { Text(error).foregroundStyle(palette.danger).textSelection(.enabled) }
            }
            if material.transcriptState == .running {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(state.taskPhases[material.mediaID] ?? "处理字幕中")
                    Spacer()
                    Button("取消") { state.cancelProcessing(projectID, material.id, motion: false) }
                }
            } else if material.transcriptState == .failed || material.transcriptState == .idle {
                Text(material.transcriptError ?? "字幕未生成").foregroundStyle(palette.textSecondary).textSelection(.enabled)
                HStack {
                    Button("识别字幕") { state.transcribe(projectID, material.id) }.disabled(!material.sourceReady)
                    SettingsLink { Text("字幕设置") }
                }
            }
        }.font(.caption).buttonStyle(.borderless)
    }
}
