import SwiftUI

struct MovieExportSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let project: VideoProject
    @State private var burnIn = true
    @State private var separateSRT = false
    @ObservedObject private var settings = SettingsStore.shared
    @State private var aiEditing = false
    @State private var canvas = "current"

    private var configured: VideoProject {
        var copy = state.projects.first(where: { $0.id == project.id }) ?? project
        copy.includeSubtitles = burnIn
        copy.exportSRT = separateSRT
        copy.exportWithAIEditing = aiEditing
        switch canvas {
        case "landscape": copy.canvasWidth = 1920; copy.canvasHeight = 1080
        case "portrait": copy.canvasWidth = 1080; copy.canvasHeight = 1920
        case "square": copy.canvasWidth = 1080; copy.canvasHeight = 1080
        case "source": copy.canvasWidth = nil; copy.canvasHeight = nil
        default: break
        }
        return copy
    }
    private var needsAIConnection: Bool { aiEditing && !settings.hasAIConnection }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space6) {
            Text(verbatim: "导出成片").font(.studio(.heading))
            VStack(alignment: .leading, spacing: Metrics.space3) {
                Text("画幅").font(.studio(.bodyMedium))
                HStack(spacing: Metrics.space2_5) {
                    canvasOption("current", title: "当前画幅", dimensions: currentDimensions)
                    canvasOption("source", title: "原始素材", dimensions: "跟随素材")
                }
                HStack(spacing: Metrics.space2_5) {
                    canvasOption("landscape", title: "横屏", dimensions: "1920 × 1080", ratio: 16.0 / 9.0)
                    canvasOption("portrait", title: "竖屏", dimensions: "1080 × 1920", ratio: 9.0 / 16.0)
                    canvasOption("square", title: "方形", dimensions: "1080 × 1080", ratio: 1)
                }
            }
            VStack(spacing: 0) {
                Toggle("嵌入样式字幕", isOn: $burnIn)
                Rectangle().fill(palette.surface2).frame(height: 1)
                Toggle("另存 SRT 字幕文件", isOn: $separateSRT)
                    .help("SRT 保存文字与时间码；画面中的字幕样式通过嵌入字幕保留。")
            }
            .toggleStyle(StudioToggleStyle())
            Toggle("AI 剪辑", isOn: $aiEditing)
                .help("参考片段字幕和粗剪后的提示词，并从素材库选用补充画面。")
                .toggleStyle(StudioToggleStyle())
            if needsAIConnection {
                Text("请先在设置中连接 AI，或关闭 AI 选项后导出。")
                    .font(.studio(.small)).foregroundStyle(palette.textSecondary)
            }
            if !configured.canExport {
                Text(configured.materials.contains(where: { !$0.isReady }) ? "请先完成素材导出或移除失败素材。" : "字幕仍在处理，可等待完成，或关闭字幕选项后导出视频。")
                    .font(.studio(.small)).foregroundStyle(palette.textSecondary)
            }
            HStack {
                Button { dismiss() } label: { Text(verbatim: "取消") }
                    .buttonStyle(StudioButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    let output = configured
                    guard output.canExport, !needsAIConnection else { return }
                    if state.updateProject(project.id, { saved in
                        saved.includeSubtitles = output.includeSubtitles; saved.exportSRT = output.exportSRT
                        saved.canvasWidth = output.canvasWidth; saved.canvasHeight = output.canvasHeight
                        saved.exportWithAIEditing = output.exportWithAIEditing
                    }) {
                        state.export(projectID: project.id)
                        dismiss()
                    }
                } label: { Label { Text(verbatim: "导出成片") } icon: { Image(systemName: "arrow.up.right") } }
                    .buttonStyle(StudioButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(needsAIConnection || !configured.canExport || state.exportingProjects.contains(project.id))
            }
        }
        .padding(Metrics.space7).frame(width: 520)
        .foregroundStyle(palette.textPrimary)
        .background(palette.bgBase)
        .onAppear {
            burnIn = project.includeSubtitles
            separateSRT = project.exportSRT ?? false
            aiEditing = project.exportWithAIEditing ?? false
        }
    }

    private var currentDimensions: String {
        if let width = project.canvasWidth, let height = project.canvasHeight {
            return "\(Int(width)) × \(Int(height))"
        }
        return "跟随素材"
    }

    private func canvasOption(_ value: String, title: String, dimensions: String, ratio: CGFloat? = nil) -> some View {
        let selected = canvas == value
        return Button { canvas = value } label: {
            VStack(alignment: .leading, spacing: Metrics.space3) {
                if let ratio {
                    HStack {
                        RoundedRectangle(cornerRadius: Metrics.radiusXS)
                            .strokeBorder(selected ? palette.accent : palette.textSecondary, lineWidth: 1.5)
                            .frame(width: ratio >= 1 ? 28 : 28 * ratio, height: ratio >= 1 ? 28 / ratio : 28)
                            .frame(width: 30, height: 30)
                            .accessibilityHidden(true)
                        Spacer(minLength: 0)
                        selectionMark(selected)
                    }
                }
                HStack(alignment: .top, spacing: Metrics.space1) {
                    VStack(alignment: .leading, spacing: Metrics.space1_5) {
                        Text(title).font(.studio(.bodyMedium))
                        Text(dimensions).font(.studio(.caption)).monospacedDigit()
                            .foregroundStyle(palette.textSecondary)
                    }
                    if ratio == nil {
                        Spacer(minLength: 0)
                        selectionMark(selected)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Metrics.space3)
        }
        .buttonStyle(StudioSelectionStyle(selected: selected))
        .accessibilityLabel("\(title)，\(dimensions)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func selectionMark(_ selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(selected ? palette.accent : palette.surface3)
            .accessibilityHidden(true)
    }
}
