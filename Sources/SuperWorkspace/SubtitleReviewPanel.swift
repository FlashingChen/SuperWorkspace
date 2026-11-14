import SwiftUI

/// Results of the assembly-stage caption review. Confirmed text fixes are already applied by the
/// time this panel appears; the list is a quiet report, not a queue of suggestions.
struct SubtitleReviewPanel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    let project: VideoProject
    let onSelect: (UUID, Int) -> Void
    let onDelete: (UUID, Int) -> Void
    @State private var showsApplied = false

    private var review: SubtitleReview? { state.subtitleReviews[project.id] }
    private var issues: [ResolvedSubtitleIssue] { state.resolvedSubtitleIssues(project.id) }
    private var applied: [AppliedSubtitleFix] {
        guard let review else { return [] }
        return review.applied.filter { fix in
            guard let material = project.materials.first(where: { $0.id == fix.materialID }),
                  let index = material.subtitles.firstIndex(where: {
                      abs($0.start - fix.start) < 0.02 && $0.text == fix.after
                  }) else { return false }
            return material.subtitles[index].end > material.inPoint
                && material.subtitles[index].start < material.outPoint
        }
    }
    private var reviewing: Bool { state.reviewingProjects.contains(project.id) }

    var body: some View {
        if reviewing {
            HStack(spacing: Metrics.space2) {
                ProgressView().controlSize(.small)
                Text(state.reviewPhases[project.id] ?? "复核字幕")
                    .font(.studio(.small)).foregroundStyle(palette.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
                Button("取消") { state.cancelSubtitleReview(project.id) }
                    .font(.studio(.small)).buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else if let review {
            summary(review)
        }
    }

    @ViewBuilder
    private func summary(_ review: SubtitleReview) -> some View {
        if let rebuild = review.rebuild {
            rebuildSummary(review, rebuild)
        } else {
            localSummary(review)
        }
    }

    private func rebuildSummary(_ review: SubtitleReview, _ rebuild: RebuildSummary) -> some View {
        let clean = rebuild.failed == 0 && rebuild.skipped == 0
        return VStack(alignment: .leading, spacing: Metrics.space2) {
            HStack(spacing: Metrics.space2) {
                Image(systemName: rebuild.materials > 0 ? "checkmark.seal" : "sparkle.magnifyingglass")
                    .font(.studio(.small))
                    .foregroundStyle(clean ? palette.success : palette.ai)
                Text(rebuild.materials > 0 ? "AI 已重组字幕" : "复核完成")
                    .font(.studio(.smallStrong))
                Spacer(minLength: 0)
                Button("清除") { state.clearSubtitleReview(project.id) }
                    .font(.studio(.small)).buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                    .help("清除本次复核结果")
            }
            if rebuild.materials > 0 {
                Text("\(rebuild.materials) 个素材：\(rebuild.before) → \(rebuild.after) 条字幕")
                    .font(.studio(.caption)).foregroundStyle(palette.textSecondary)
            }
            if let note = review.note {
                Text(note).font(.studio(.caption)).foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("检查了 \(review.checkedLines) 条字幕")
                .font(.studio(.micro)).foregroundStyle(palette.textMuted)
        }
        .padding(Metrics.space2)
        .background(palette.surface1.opacity(0.55), in: RoundedRectangle(cornerRadius: Metrics.radiusM))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.radiusM).strokeBorder(palette.surface2, lineWidth: 1)
        }
    }

    private func localSummary(_ review: SubtitleReview) -> some View {
        let fixed = applied.count
        let remaining = issues.count
        return VStack(alignment: .leading, spacing: Metrics.space2) {
            HStack(spacing: Metrics.space2) {
                Image(systemName: remaining == 0 ? "checkmark.seal" : "sparkle.magnifyingglass")
                    .font(.studio(.small))
                    .foregroundStyle(remaining == 0 ? palette.success : palette.ai)
                Text(title(fixed: fixed, remaining: remaining))
                    .font(.studio(.smallStrong))
                Spacer(minLength: 0)
                Button("清除") { state.clearSubtitleReview(project.id) }
                    .font(.studio(.small)).buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                    .help("清除本次复核结果")
            }
            if let note = review.note {
                Text(note).font(.studio(.caption)).foregroundStyle(palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if fixed > 0 {
                Button { showsApplied.toggle() } label: {
                    HStack(spacing: Metrics.space1) {
                        Image(systemName: showsApplied ? "chevron.down" : "chevron.right")
                            .font(.studio(.micro))
                        Text(showsApplied ? "收起已修正的 \(fixed) 处" : "查看已修正的 \(fixed) 处")
                    }
                }
                .font(.studio(.small)).buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                .accessibilityIdentifier("assembly.review.applied")
                if showsApplied {
                    VStack(alignment: .leading, spacing: Metrics.space1) {
                        ForEach(applied) { fix in appliedRow(fix) }
                    }
                }
            }
            if remaining > 0 {
                if fixed > 0 {
                    Text("需要留意").font(.studio(.smallStrong)).padding(.top, Metrics.space1)
                }
                VStack(alignment: .leading, spacing: Metrics.space1) {
                    ForEach(Array(issues.prefix(30))) { item in row(item) }
                }
                if issues.count > 30 {
                    Text("还有 \(issues.count - 30) 处。")
                        .font(.studio(.micro)).foregroundStyle(palette.textMuted)
                }
            }
            Text("检查了 \(review.checkedLines) 条字幕")
                .font(.studio(.micro)).foregroundStyle(palette.textMuted)
        }
        .padding(Metrics.space2)
        .background(palette.surface1.opacity(0.55), in: RoundedRectangle(cornerRadius: Metrics.radiusM))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.radiusM).strokeBorder(palette.surface2, lineWidth: 1)
        }
    }

    private func title(fixed: Int, remaining: Int) -> String {
        if fixed > 0, remaining > 0 { return "已自动修正 \(fixed) 处，\(remaining) 处需要留意" }
        if fixed > 0 { return "已自动修正 \(fixed) 处" }
        if remaining > 0 { return "\(remaining) 处需要留意" }
        return "未发现明显问题"
    }

    private func appliedRow(_ fix: AppliedSubtitleFix) -> some View {
        Button {
            guard let index = currentIndex(for: fix) else { return }
            onSelect(fix.materialID, index)
        } label: {
            VStack(alignment: .leading, spacing: Metrics.space0_5) {
                Text(timecode(fix))
                    .font(.studio(.timecode))
                    .foregroundStyle(palette.textMuted)
                HStack(alignment: .firstTextBaseline, spacing: Metrics.space1) {
                    Text(fix.before)
                        .strikethrough()
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(2)
                    Image(systemName: "arrow.right")
                        .font(.studio(.micro))
                        .foregroundStyle(palette.textMuted)
                    Text(fix.after)
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(2)
                }
                .font(.studio(.caption))
                .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(StudioContentButtonStyle())
        .accessibilityLabel("已修正，\(fix.before) 改为 \(fix.after)")
    }

    private func row(_ item: ResolvedSubtitleIssue) -> some View {
        HStack(alignment: .top, spacing: Metrics.space2) {
            Circle().fill(color(item.issue.severity))
                .frame(width: 5, height: 5).padding(.top, 5)
                .accessibilityHidden(true)
            Button { onSelect(item.materialID, item.index) } label: {
                VStack(alignment: .leading, spacing: Metrics.space0_5) {
                    HStack(spacing: Metrics.space2) {
                        Text(item.issue.kind.label)
                            .font(.studio(.micro, weight: .medium))
                            .foregroundStyle(color(item.issue.severity))
                        Text(timecode(item))
                            .font(.studio(.timecode))
                            .foregroundStyle(palette.textMuted)
                    }
                    Text(item.issue.message)
                        .font(.studio(.caption))
                        .foregroundStyle(palette.textSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(StudioContentButtonStyle())
            .accessibilityLabel("\(severityLabel(item.issue.severity))，\(item.issue.kind.label)：\(item.issue.message)")
        }
        .contextMenu {
            Button("删除这条字幕", role: .destructive) {
                onDelete(item.materialID, item.index)
            }
            Button("忽略此条") { state.dismissSubtitleReviewIssue(project.id, item.issue.id) }
        }
    }

    private func currentIndex(for fix: AppliedSubtitleFix) -> Int? {
        guard let material = project.materials.first(where: { $0.id == fix.materialID }) else { return nil }
        return material.subtitles.firstIndex { abs($0.start - fix.start) < 0.02 && $0.text == fix.after }
    }

    private func timecode(_ fix: AppliedSubtitleFix) -> String {
        timecode(materialID: fix.materialID, start: fix.start)
    }

    private func timecode(_ item: ResolvedSubtitleIssue) -> String {
        timecode(materialID: item.materialID, start: item.issue.start)
    }

    private func timecode(materialID: UUID, start: Double) -> String {
        guard let material = project.materials.first(where: { $0.id == materialID }) else { return "" }
        let global = AssemblyTimelineLayout.globalStart(materialID: material.id, in: project.materials,
                                                       sourceTime: start)
        return AssemblyTimelineLayout.timecode(global)
    }

    private func severityLabel(_ severity: SubtitleReviewIssue.Severity) -> String {
        switch severity {
        case .error: return "错误"
        case .warning: return "待确认"
        case .note: return "提示"
        }
    }

    private func color(_ severity: SubtitleReviewIssue.Severity) -> Color {
        switch severity {
        case .error: return palette.danger
        case .warning: return palette.warning
        case .note: return palette.textMuted
        }
    }
}
