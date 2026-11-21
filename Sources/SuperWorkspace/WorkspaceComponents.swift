import AVKit
import SwiftUI

struct StudioButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, destructive }
    enum Size { case regular, compact }
    enum Shape { case capsule, rounded }
    var kind: Kind = .secondary
    var size: Size = .regular
    var shape: Shape = .capsule
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let radius: CGFloat = shape == .capsule
            ? 999
            : (size == .compact ? Metrics.radiusS : Metrics.radiusM)
        configuration.label
            .font(.studio(size == .compact ? .small : .bodyMedium, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: size == .compact ? Metrics.controlCompact : 0,
                   minHeight: size == .compact ? Metrics.controlCompact : Metrics.control)
            .background(background(pressed: configuration.isPressed),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(palette.islandOutline, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? 1 : Metrics.opacityDisabled)
            .animation(StudioMotion.hover, value: hovering)
            .onHover { hovering = $0 }
    }

    private var horizontalPadding: CGFloat {
        switch (size, kind) {
        case (.compact, .quiet): Metrics.space2
        case (.compact, _): Metrics.space3
        case (.regular, .quiet): Metrics.space2_5
        case (.regular, _): Metrics.space4
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: palette.onAccent
        case .destructive: Color.white
        case .secondary, .quiet: palette.textPrimary
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary:
            return palette.accent.opacity(pressed ? Metrics.opacityPressed : (hovering ? 0.88 : 1))
        case .destructive:
            return palette.danger.opacity(pressed ? Metrics.opacityPressed : (hovering ? 0.88 : 1))
        case .secondary:
            if pressed { return palette.selectionWash }
            return hovering ? palette.selectionWash.opacity(0.75) : palette.controlWell
        case .quiet:
            if pressed { return palette.selectionWash }
            return hovering ? palette.hoverWash : .clear
        }
    }
}

/// Selectable choices use neutral elevation washes instead of heavy wireframes.
struct StudioSelectionStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    let selected: Bool
    var cornerRadius: CGFloat = Metrics.radiusM

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .foregroundStyle(selected ? palette.onAccent : (hovering ? palette.textPrimary : palette.textSecondary))
            .background(
                selected
                    ? palette.accent
                    : (configuration.isPressed ? palette.selectionWash : (hovering ? palette.hoverWash : palette.controlWell)),
                in: shape
            )
            .clipShape(shape)
            .opacity(isEnabled ? (configuration.isPressed && selected ? Metrics.opacityPressed : 1) : Metrics.opacityDisabled)
            .animation(StudioMotion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

struct StudioToggleStyle: ToggleStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(StudioMotion.interactive) {
                configuration.isOn.toggle()
            }
        } label: {
            HStack(spacing: Metrics.space4) {
                configuration.label.font(.studio(.body))
                Spacer()
                Capsule()
                    .fill(configuration.isOn ? palette.accent : palette.surface3)
                    .frame(width: 34, height: 20)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(configuration.isOn ? palette.onAccent : palette.textPrimary)
                            .frame(width: 14, height: 14)
                            .padding(3)
                    }
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Metrics.toggleRow)
            .padding(.horizontal, Metrics.space2)
            .background(hovering ? palette.hoverWash : .clear,
                        in: RoundedRectangle(cornerRadius: Metrics.radiusS, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.textPrimary)
        .opacity(isEnabled ? 1 : Metrics.opacityDisabled)
        .animation(StudioMotion.hover, value: hovering)
        .onHover { hovering = $0 }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

struct StudioPreview: View {
    @Environment(\.palette) private var palette
    var url: URL?
    var symbol = "play.rectangle"
    var title = "尚未添加视频"
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            palette.mediaGround
            if let player {
                StudioPlayer(player: player)
            } else {
                VStack(spacing: Metrics.space3) {
                    Image(systemName: symbol)
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(Color.white.opacity(0.42))
                        .accessibilityHidden(true)
                    Text(title)
                        .font(.studio(.small))
                        .foregroundStyle(Color.white.opacity(0.62))
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusL, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.radiusL, style: .continuous)
                .strokeBorder(palette.islandOutline, lineWidth: 1)
        }
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
            .font(.studio(.small))
            .foregroundStyle(isError ? palette.danger : palette.textSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Centered stage empty-state / onboarding surface inside a floating studio island.
struct StudioWorkspace<Media: View, Controls: View>: View {
    @Environment(\.palette) private var palette
    let title: String
    let detail: String
    @ViewBuilder var media: () -> Media
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        ScrollView {
            VStack(spacing: Metrics.space5) {
                VStack(alignment: .leading, spacing: Metrics.space5) {
                    HStack(alignment: .top, spacing: Metrics.space6) {
                        media()
                            .frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: Metrics.space4) {
                            WorkspaceHeading(title: title, detail: detail)
                            controls()
                        }
                        .frame(width: 248, alignment: .leading)
                    }
                }
                .padding(Metrics.space5)
                .studioIsland(cornerRadius: Metrics.radiusFloating)
                .frame(maxWidth: 880)
            }
            .padding(.horizontal, Metrics.space7)
            .padding(.vertical, Metrics.space8)
            .frame(maxWidth: .infinity, minHeight: 520, alignment: .center)
        }
        .background(palette.stage)
    }
}

struct NewProjectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @EnvironmentObject private var appState: AppState
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space5) {
            VStack(alignment: .leading, spacing: Metrics.space1) {
                Text("新建项目")
                    .font(.studio(.heading))
                Text("每个项目独立管理录制素材、字幕、动效与成片。")
                    .font(.studio(.small))
                    .foregroundStyle(palette.textSecondary)
            }
            TextField("项目名称", text: $name)
                .textFieldStyle(StudioTextFieldStyle())
                .font(.studio(.body))
                .focused($focused)
                .onSubmit(create)
            HStack(spacing: Metrics.space2) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(StudioButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button("创建项目", action: create)
                    .buttonStyle(StudioButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .foregroundStyle(palette.textPrimary)
        .padding(Metrics.space6)
        .frame(width: 420)
        .background(palette.island)
        .onAppear { focused = true }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.createProject(name: trimmed.isEmpty ? "未命名项目" : trimmed)
        dismiss()
    }
}
