import SwiftUI

/// The assembly-page chat window. Talks to one `AssemblyAgent` per project and
/// shows streaming text plus the current project operation.
struct AssemblyChatPanel: View {
    @Environment(\.palette) private var palette
    let project: VideoProject
    @ObservedObject var agent: AssemblyAgent
    let onClose: () -> Void

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private let examples = [
        "素材一 12 到 18 秒的动画不好看，重做一下",
        "把素材二前 3 秒剪掉",
        "第 1 段第 2 条字幕改成「我们继续」",
        "把素材三移到最前面",
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
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                composerFocused = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: Metrics.space2) {
            Image(systemName: "sparkles")
                .font(.studio(.small, weight: .semibold))
                .foregroundStyle(palette.ai)
                .accessibilityHidden(true)
            Text("AI 剪辑助手").font(.studio(.subhead))
            Spacer()
            Text(status).font(.studio(.small)).foregroundStyle(statusColor)
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                .accessibilityLabel("关闭 AI 面板")
        }
        .padding(.horizontal, Metrics.space3)
        .frame(height: Metrics.bar)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.space3) {
                    if agent.messages.isEmpty { introduction }
                    ForEach(agent.messages) { message in
                        bubble(message).id(message.id)
                    }
                    if !agent.streaming.isEmpty {
                        assistantBubble(agent.streaming).id("streaming")
                    }
                    if let activity = agent.activity {
                        HStack(spacing: Metrics.space2) {
                            ProgressView().controlSize(.mini)
                            Text(activity).font(.studio(.small)).foregroundStyle(palette.textSecondary).lineLimit(2)
                        }
                        .padding(.leading, Metrics.space1)
                    }
                    if let failure = agent.failure {
                        Text(failure)
                            .font(.studio(.small))
                            .foregroundStyle(palette.warning)
                            .padding(Metrics.space2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(palette.surface1, in: RoundedRectangle(cornerRadius: Metrics.radiusS))
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
            Text("直接说想改什么，它会定位片段、动手修改，改动都能撤销。")
                .font(.studio(.small))
                .foregroundStyle(palette.textSecondary)
            ForEach(examples, id: \.self) { example in
                Button {
                    draft = example
                    composerFocused = true
                } label: {
                    Text(example)
                        .font(.studio(.small))
                        .multilineTextAlignment(.leading)
                        .padding(Metrics.space2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
            }
        }
        .padding(.bottom, Metrics.space2)
    }

    @ViewBuilder
    private func bubble(_ message: AssemblyAgent.Message) -> some View {
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
            assistantBubble(message.text)
        case .notice:
            Text(message.text)
                .font(.studio(.small))
                .foregroundStyle(palette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func assistantBubble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Metrics.space2) {
            Text("AI")
                .font(.studio(.small, weight: .semibold))
                .foregroundStyle(palette.ai)
                .padding(.top, Metrics.space1)
            Text(text)
                .font(.studio(.body))
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, Metrics.space3).padding(.vertical, Metrics.space2)
                .background(palette.surface1, in: RoundedRectangle(cornerRadius: Metrics.radiusM))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var composer: some View {
        VStack(spacing: Metrics.space2) {
            HStack(alignment: .bottom, spacing: Metrics.space2) {
                TextField("说要改什么…", text: $draft, axis: .vertical)
                    .textFieldStyle(StudioTextFieldStyle())
                    .lineLimit(1...4)
                    .focused($composerFocused)
                    .onSubmit(send)
                    .disabled(agent.failure != nil && !agent.isReady)
                Button(action: agent.isBusy ? { agent.abort() } : send) {
                    Image(systemName: agent.isBusy ? "stop.fill" : "arrow.up")
                }
                .buttonStyle(StudioButtonStyle(kind: .primary, size: .compact))
                .disabled(!agent.isBusy && (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !agent.canSend))
                .accessibilityLabel(agent.isBusy ? "停止" : "发送")
            }
            Text("修改会立即应用，可用⌘Z撤销")
                .font(.studio(.small))
                .foregroundStyle(palette.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Metrics.space3)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !agent.isBusy else { return }
        draft = ""
        agent.send(text)
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
        if agent.isReady { return "在线" }
        if agent.failure != nil { return "未连接" }
        return "连接中"
    }

    private var statusColor: Color {
        agent.failure != nil ? palette.warning : (agent.isReady ? palette.success : palette.textMuted)
    }
}
