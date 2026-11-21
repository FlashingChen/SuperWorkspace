import SwiftUI

/// The assembly-page AI director panel. Claude-style plain-prose responses,
/// live elapsed activity indicator, and per-turn result cards with play & undo.
struct AssemblyChatPanel: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    let project: VideoProject
    @ObservedObject var agent: AssemblyAgent
    var focusContext: String? = nil
    var onPlayPreview: (() -> Void)? = nil
    var onImportMedia: (() -> Void)? = nil
    var onOpenLibrary: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private struct QuickAction: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let prompt: String
    }

    private let quickActions: [QuickAction] = [
        .init(
            symbol: "scissors",
            title: "智能精剪停顿与空白",
            prompt: "帮我分析各片段的静音停顿，把超过 0.8 秒的多余空白和明显口误剪掉，让节奏紧凑自然。"
        ),
        .init(
            symbol: "textformat.size",
            title: "在开头做一个大标题花字",
            prompt: "根据项目主题和开场字幕，在成片开头前 3 秒叠加一个大标题花字（title 样式）。"
        ),
        .init(
            symbol: "gauge.with.needle",
            title: "把当前片段加速到 1.5 倍",
            prompt: "把当前选中的片段加速到 1.5 倍速。"
        ),
        .init(
            symbol: "music.note",
            title: "为全片配背景音乐",
            prompt: "如果素材库里有音频素材，帮我铺成全片背景音乐，开启人声避让和首尾淡入淡出；如果没有音频，提醒我先导入。"
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            Divider()
            composer
        }
        .background(palette.bgBase)
        .onAppear {
            agent.startIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: Metrics.space2) {
            Image(systemName: "sparkles")
                .font(.studio(.small, weight: .semibold))
                .foregroundStyle(palette.ai)
                .accessibilityHidden(true)
            Text("AI 剪辑导演").font(.studio(.smallStrong))
            Spacer()
            HStack(spacing: Metrics.space1) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(status).font(.studio(.caption)).foregroundStyle(palette.textSecondary)
            }
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                    .accessibilityLabel("关闭 AI 面板")
            }
        }
        .padding(.horizontal, Metrics.space3)
        .frame(height: 40)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.space4) {
                    if agent.messages.isEmpty { introduction }
                    ForEach(agent.messages) { message in
                        messageRow(message).id(message.id)
                    }
                    if !agent.streaming.isEmpty {
                        assistantProse(agent.streaming, edits: nil, editSteps: nil).id("streaming")
                    }
                    if agent.isBusy {
                        liveActivityRow.id("activity")
                    }
                    if let failure = agent.failure {
                        Text(failure)
                            .font(.studio(.small))
                            .foregroundStyle(palette.warning)
                            .padding(Metrics.space2_5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(palette.surface1, in: RoundedRectangle(cornerRadius: Metrics.radiusM))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(Metrics.space3)
            }
            .onChange(of: agent.messages.count) { _, _ in scroll(proxy) }
            .onChange(of: agent.streaming) { _, _ in scroll(proxy) }
            .onChange(of: agent.activity) { _, _ in scroll(proxy) }
            .onAppear { scroll(proxy, animated: false) }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            Text("直接说想改什么——剪停顿、调倍速、加花字、配音乐、插素材库画面或重做动效，改动会实时长在时间线上。")
                .font(.studio(.small))
                .foregroundStyle(palette.textSecondary)
                .lineSpacing(3)
            VStack(spacing: Metrics.space1_5) {
                ForEach(quickActions) { action in
                    Button {
                        agent.send(action.prompt, contextNote: focusContext)
                    } label: {
                        HStack(spacing: Metrics.space2) {
                            Image(systemName: action.symbol)
                                .font(.studio(.small))
                                .foregroundStyle(palette.ai)
                                .frame(width: 18)
                            Text(action.title)
                                .font(.studio(.small))
                                .foregroundStyle(palette.textPrimary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.studio(.micro))
                                .foregroundStyle(palette.textMuted)
                        }
                        .padding(.horizontal, Metrics.space2_5)
                        .padding(.vertical, Metrics.space2)
                        .background(palette.surface1.opacity(0.65), in: RoundedRectangle(cornerRadius: Metrics.radiusM))
                        .overlay {
                            RoundedRectangle(cornerRadius: Metrics.radiusM)
                                .strokeBorder(palette.surface2, lineWidth: 1)
                        }
                    }
                    .buttonStyle(StudioContentButtonStyle())
                    .disabled(agent.isBusy)
                }
            }
        }
        .padding(.bottom, Metrics.space2)
    }

    private var liveActivityRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = agent.turnStartedAt.map { max(0, Int(context.date.timeIntervalSince($0))) } ?? 0
            HStack(spacing: Metrics.space2) {
                ProgressView().controlSize(.mini)
                Text(agent.activity ?? "思考中…")
                    .font(.studio(.small))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if elapsed > 0 {
                    Text("\(elapsed)s")
                        .font(.studio(.timecode))
                        .foregroundStyle(palette.textMuted)
                }
            }
            .padding(.horizontal, Metrics.space2_5)
            .padding(.vertical, Metrics.space2)
            .background(palette.surface1.opacity(0.55), in: RoundedRectangle(cornerRadius: Metrics.radiusM))
        }
    }

    @ViewBuilder
    private func messageRow(_ message: AssemblyAgent.Message) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: Metrics.space6)
                Text(message.text)
                    .font(.studio(.body))
                    .foregroundStyle(palette.textPrimary)
                    .padding(.horizontal, Metrics.space3).padding(.vertical, Metrics.space2)
                    .background(palette.surface2, in: RoundedRectangle(cornerRadius: Metrics.radiusM))
                    .textSelection(.enabled)
            }
        case .assistant:
            assistantProse(message.text, edits: message.edits, editSteps: message.editSteps)
        case .notice:
            Text(message.text)
                .font(.studio(.small))
                .foregroundStyle(palette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func assistantProse(_ text: String, edits: [String]?, editSteps: Int?) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space2_5) {
            if !text.isEmpty {
                Text(text)
                    .font(.studio(.body))
                    .foregroundStyle(palette.textPrimary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if let edits, !edits.isEmpty {
                resultCard(edits: edits, steps: editSteps ?? edits.count)
            }
        }
    }

    private func resultCard(edits: [String], steps: Int) -> some View {
        let summary = summarizedEdits(edits)
        return VStack(alignment: .leading, spacing: Metrics.space2) {
            HStack(spacing: Metrics.space1_5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.studio(.small))
                    .foregroundStyle(palette.success)
                Text("已应用 \(steps) 项修改")
                    .font(.studio(.caption, weight: .semibold))
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
            }
            Text(summary)
                .font(.studio(.caption))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(3)
            HStack(spacing: Metrics.space2) {
                if let onPlayPreview {
                    Button {
                        onPlayPreview()
                    } label: {
                        Label("播放看看", systemImage: "play.fill")
                    }
                    .buttonStyle(StudioButtonStyle(kind: .secondary, size: .compact))
                }
                Button {
                    for _ in 0..<steps { state.undo() }
                } label: {
                    Label("撤销本轮", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                .disabled(!state.canUndo)
            }
        }
        .padding(Metrics.space2_5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface1, in: RoundedRectangle(cornerRadius: Metrics.radiusM))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.radiusM)
                .strokeBorder(palette.surface2, lineWidth: 1)
        }
    }

    private func summarizedEdits(_ edits: [String]) -> String {
        var counts: [(String, Int)] = []
        for edit in edits {
            if let idx = counts.firstIndex(where: { $0.0 == edit }) {
                counts[idx].1 += 1
            } else {
                counts.append((edit, 1))
            }
        }
        return counts.map { $1 > 1 ? "\($0) ×\($1)" : $0 }.joined(separator: " · ")
    }

    private var composer: some View {
        VStack(spacing: Metrics.space2) {
            if let focusContext, !focusContext.isEmpty {
                HStack(spacing: Metrics.space1_5) {
                    Image(systemName: "scope")
                        .font(.studio(.micro))
                        .foregroundStyle(palette.accent)
                        .accessibilityHidden(true)
                    Text(focusContext)
                        .font(.studio(.caption))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            HStack(alignment: .bottom, spacing: Metrics.space1_5) {
                if onImportMedia != nil || onOpenLibrary != nil {
                    Menu {
                        if let onImportMedia {
                            Button("导入图片、视频或音频", systemImage: "plus.rectangle.on.folder", action: onImportMedia)
                        }
                        if let onOpenLibrary {
                            Button("查看项目素材库（\(project.referenceMedia.count)）", systemImage: "photo.on.rectangle", action: onOpenLibrary)
                        }
                    } label: {
                        Image(systemName: "paperclip")
                            .frame(width: Metrics.controlCompact, height: Metrics.controlCompact)
                    }
                    .menuStyle(StudioMenuStyle())
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("添加或查看素材库（图片/视频/音乐）")
                    .accessibilityLabel("素材库附件")
                }
                TextField("说要改什么…", text: $draft, axis: .vertical)
                    .textFieldStyle(StudioTextFieldStyle())
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .onSubmit(send)
                Button(action: agent.isBusy ? { agent.abort() } : send) {
                    Image(systemName: agent.isBusy ? "stop.fill" : "arrow.up")
                }
                .buttonStyle(StudioButtonStyle(kind: .primary, size: .compact))
                .disabled(!agent.isBusy && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(agent.isBusy ? "停止" : "发送")
            }
            Text("支持花字、音乐/音效、倍速、插图、剪停顿与字幕，均可 ⌘Z 撤销")
                .font(.studio(.micro))
                .foregroundStyle(palette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Metrics.space3)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !agent.isBusy else { return }
        draft = ""
        agent.send(text, contextNote: focusContext)
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    private var status: String {
        if agent.isBusy { return "处理中" }
        if agent.isReady { return "就绪" }
        if agent.failure != nil { return "未连接" }
        return "连接中"
    }

    private var statusColor: Color {
        agent.failure != nil ? palette.warning : (agent.isReady ? palette.success : palette.textMuted)
    }
}
