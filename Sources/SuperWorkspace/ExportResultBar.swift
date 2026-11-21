import SwiftUI
import AppKit

struct ExportResultBar: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    let project: VideoProject
    var body: some View {
        if let progress = state.exportProgress[project.id] {
            ExportProgressBar(progress: progress)
        } else if let url = state.lastExports[project.id] {
            HStack(spacing: Metrics.space3) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.success)
                Text("最近导出已就绪").font(.studio(.small, weight: .medium))
                Spacer()
                Button("播放成片", systemImage: "play.fill") { NSWorkspace.shared.open(url) }
                if let name = project.lastExportSRTName, name == URL(fileURLWithPath: name).lastPathComponent {
                    Button("SRT 字幕") { NSWorkspace.shared.activateFileViewerSelecting([ProjectLayout.url(name, for: project)]) }
                }
                Button("在 Finder 中显示", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .buttonStyle(StudioButtonStyle(kind: .secondary, size: .compact))
            .font(.studio(.small))
            .padding(.horizontal, Metrics.space4)
            .frame(height: Metrics.bar)
            .studioIsland(cornerRadius: Metrics.radiusL, shadow: false)
        }
    }
}

private struct ExportProgressBar: View {
    @ObservedObject var progress: ExportProgress
    var body: some View {
        HStack(spacing: Metrics.space3) {
            Text(progress.isCancelled ? "正在取消" : progress.phase)
            ProgressView(value: progress.fraction).frame(maxWidth: 240)
            if progress.fraction > 0 {
                Text(progress.fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
            }
            Spacer()
            Button("取消导出") { progress.cancel() }.disabled(progress.isCancelled)
        }
        .buttonStyle(StudioButtonStyle(kind: .secondary, size: .compact))
        .font(.studio(.small))
        .padding(.horizontal, Metrics.space4)
        .frame(height: Metrics.bar)
        .studioIsland(cornerRadius: Metrics.radiusL, shadow: false)
    }
}
