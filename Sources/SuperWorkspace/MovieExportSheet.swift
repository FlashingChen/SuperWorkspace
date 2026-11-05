import SwiftUI

struct MovieExportSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let project: VideoProject
    @State private var burnIn = true
    @State private var separateSRT = false
    @State private var canvas = "current"

    private var configured: VideoProject {
        var copy = state.projects.first(where: { $0.id == project.id }) ?? project
        copy.includeSubtitles = burnIn
        copy.exportSRT = separateSRT
        switch canvas {
        case "landscape": copy.canvasWidth = 1920; copy.canvasHeight = 1080
        case "portrait": copy.canvasWidth = 1080; copy.canvasHeight = 1920
        case "square": copy.canvasWidth = 1080; copy.canvasHeight = 1080
        case "source": copy.canvasWidth = nil; copy.canvasHeight = nil
        default: break
        }
        return copy
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(verbatim: "导出成片").font(.system(size: 22, weight: .semibold))
            Form {
                Picker("画幅", selection: $canvas) {
                    if let width = project.canvasWidth, let height = project.canvasHeight {
                        Text("当前 · \(Int(width)) × \(Int(height))").tag("current")
                    } else { Text("原始素材").tag("current") }
                    Text("横屏 · 1920 × 1080").tag("landscape")
                    Text("竖屏 · 1080 × 1920").tag("portrait")
                    Text("方形 · 1080 × 1080").tag("square")
                    Text("跟随原始素材").tag("source")
                }
                Toggle("嵌入样式字幕", isOn: $burnIn)
                Toggle("另存 SRT 字幕文件", isOn: $separateSRT)
                    .help("SRT 保存文字与时间码；画面中的字幕样式通过嵌入字幕保留。")
            }
            if !configured.canExport {
                Text(configured.materials.contains(where: { !$0.isReady }) ? "请先完成素材导出或移除失败素材。" : "字幕仍在处理，可等待完成，或关闭字幕选项后导出视频。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button { dismiss() } label: { Text(verbatim: "取消") }.keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    let output = configured
                    guard output.canExport else { return }
                    if state.updateProject(project.id, { saved in
                        saved.includeSubtitles = output.includeSubtitles; saved.exportSRT = output.exportSRT
                        saved.canvasWidth = output.canvasWidth; saved.canvasHeight = output.canvasHeight
                    }) {
                        state.export()
                        dismiss()
                    }
                } label: { Text(verbatim: "导出成片") }
                    .buttonStyle(StudioButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                    .disabled(!configured.canExport || state.exportingProjects.contains(project.id))
            }
        }
        .padding(28).frame(width: 460)
        .onAppear { burnIn = project.includeSubtitles; separateSRT = project.exportSRT ?? false }
    }
}
