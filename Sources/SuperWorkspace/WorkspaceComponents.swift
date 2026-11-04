import AVKit
import SwiftUI

struct StudioButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    var kind: Kind = .secondary
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(kind == .primary ? palette.bgBase : palette.textPrimary)
            .padding(.horizontal, kind == .quiet ? 8 : 18)
            .frame(minHeight: 38)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(palette.surface2, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : 0.38)
            .onHover { hovering = $0 }
    }

    private func background(pressed: Bool) -> Color {
        if kind == .primary { return palette.textPrimary.opacity(pressed ? 0.75 : (hovering ? 0.88 : 1)) }
        return (hovering || pressed) ? palette.surface1 : .clear
    }
}

struct StudioPreview: View {
    var url: URL?
    var symbol = "play.rectangle"
    var title = "尚未添加视频"
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color(hex: 0x191a1c)
            if let player {
                VideoSurface(player: player)
            } else {
                VStack(spacing: 18) {
                    Image(systemName: symbol)
                        .font(.system(size: 38, weight: .ultraLight))
                        .foregroundStyle(Color.white.opacity(0.48))
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.65))
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: url) {
            player?.pause()
            player = url.map { AVPlayer(url: $0) }
        }
        .onDisappear { player?.pause() }
    }
}

struct StudioNotice: View {
    @Environment(\.palette) private var palette
    var message: String
    var isError = false

    var body: some View {
        Label(message, systemImage: isError ? "exclamationmark.circle" : "info.circle")
            .font(.system(size: 12))
            .foregroundStyle(isError ? palette.danger : palette.textSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Media and action columns share the same composition throughout the workflow.
struct StudioWorkspace<Media: View, Controls: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    let detail: String
    @ViewBuilder var media: () -> Media
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: geometry.size.height < 640 ? 28 : 40) {
                    WorkspaceHeading(title: title, detail: detail)
                    HStack(alignment: .top, spacing: 36) {
                        media().frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 24, content: controls)
                            .frame(width: geometry.size.width < 1000 ? 200 : 224, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
                .frame(maxWidth: 1000, alignment: .leading)
                .padding(.horizontal, 44)
                .padding(.top, geometry.size.height < 640 ? 24 : 52)
                .padding(.bottom, geometry.size.height < 640 ? 24 : 44)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .background(palette.bgBase)
    }
}

struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @EnvironmentObject private var appState: AppState
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("新建项目")
                .font(.system(size: 24, weight: .medium))
            TextField("项目名称", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(12)
                .background(palette.surface1, in: RoundedRectangle(cornerRadius: 8))
                .focused($focused)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(StudioButtonStyle(kind: .quiet))
                    .keyboardShortcut(.cancelAction)
                Button("创建项目", action: create)
                    .buttonStyle(StudioButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .foregroundStyle(palette.textPrimary)
        .padding(32)
        .frame(width: 420)
        .background(palette.bgBase)
        .onAppear { focused = true }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.createProject(name: trimmed.isEmpty ? "未命名项目" : trimmed)
        dismiss()
    }
}
