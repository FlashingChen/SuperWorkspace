import AppKit
import AVKit
import SwiftUI

struct StudioPlayer: View {
    @Environment(\.palette) private var palette
    let player: AVPlayer
    @State private var position = 0.0
    @State private var duration = 0.0
    @State private var playing = false
    @State private var observer: Any?

    var body: some View {
        VStack(spacing: 0) {
            VideoSurface(player: player, controlsStyle: .none)
            HStack(spacing: Metrics.space2_5) {
                Button {
                    if player.rate > 0 { player.pause(); playing = false }
                    else {
                        if position >= duration { player.seek(to: .zero) }
                        player.play(); playing = true
                    }
                } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                .accessibilityLabel(playing ? "暂停预览" : "播放预览")
                Text(durationLabel(position)).monospacedDigit()
                StudioSlider(value: Binding(get: { position }, set: { value in
                    position = value
                    player.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }), range: 0...max(0.01, duration))
                .accessibilityLabel("预览播放位置").disabled(duration <= 0)
                Text(durationLabel(duration)).monospacedDigit().foregroundStyle(palette.textSecondary)
            }
            .font(.studio(.timecode)).buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
            .padding(.horizontal, Metrics.space2_5).frame(height: Metrics.control).background(palette.bgBase)
        }
        .onAppear {
            guard observer == nil else { return }
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { time in
                Task { @MainActor in
                    position = time.seconds.isFinite ? max(0, time.seconds) : 0
                    let seconds = player.currentItem?.duration.seconds ?? 0
                    duration = seconds.isFinite ? max(0, seconds) : 0
                    playing = player.rate > 0
                }
            }
        }
        .onDisappear {
            player.pause()
            if let observer { player.removeTimeObserver(observer); self.observer = nil }
        }
    }
}

struct StudioSheetSurface<Content: View>: View {
    @Environment(\.palette) private var palette
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .buttonStyle(StudioButtonStyle())
            .toggleStyle(StudioToggleStyle())
            .foregroundStyle(palette.textPrimary)
            .background(palette.bgBase)
    }
}

struct StudioMessageSheet: View {
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    let title: String
    let message: String
    let actionTitle: String
    var cancelTitle: String? = nil
    var destructive = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space6) {
            Text(title).font(.studio(.heading))
            Text(message).font(.studio(.body)).foregroundStyle(palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack {
                if let cancelTitle {
                    Button(cancelTitle) { dismiss() }
                        .buttonStyle(StudioButtonStyle()).keyboardShortcut(.cancelAction)
                }
                Spacer()
                if destructive {
                    Button(actionTitle, role: .destructive) { action(); dismiss() }
                        .buttonStyle(StudioButtonStyle(kind: .destructive))
                } else {
                    Button(actionTitle) { action(); dismiss() }
                        .buttonStyle(StudioButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Metrics.space7).frame(width: 440)
        .foregroundStyle(palette.textPrimary).background(palette.bgBase)
    }
}

/// Thumbnail and navigation labels own their geometry; this adds interaction feedback.
struct StudioContentButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovering ? palette.surface1 : .clear, in: RoundedRectangle(cornerRadius: Metrics.radiusM))
            .opacity(isEnabled ? (configuration.isPressed ? Metrics.opacityPressed : 1) : Metrics.opacityDisabled)
            .onHover { hovering = $0 }
    }
}

struct StudioChoice<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: Metrics.space2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .font(.studio(.small, weight: .medium))
                        .padding(.horizontal, Metrics.space2_5).frame(maxWidth: .infinity, minHeight: Metrics.choice)
                }
                .buttonStyle(StudioSelectionStyle(selected: selection == option.0))
                .accessibilityAddTraits(selection == option.0 ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

struct StudioTextFieldStyle: TextFieldStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .focused($focused)
            .font(.studio(.body))
            .padding(Metrics.space2_5)
            .foregroundStyle(palette.textPrimary)
            .tint(palette.accent)
            .background(palette.surface1, in: RoundedRectangle(cornerRadius: Metrics.radiusM))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.radiusM)
                    .strokeBorder(focused ? palette.accent : palette.borderStrong, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : Metrics.opacityDisabled)
    }
}

struct StudioDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack {
                    configuration.label
                    Spacer()
                    Image(systemName: configuration.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.studio(.micro, weight: .semibold)).accessibilityHidden(true)
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(StudioButtonStyle(kind: .quiet))
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已收起")
            if configuration.isExpanded { configuration.content }
        }
    }
}

struct StudioMenuStyle: MenuStyle {
    @Environment(\.palette) private var palette
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        Menu(configuration)
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(Metrics.space1_5)
            .frame(minWidth: Metrics.controlCompact, minHeight: Metrics.controlCompact)
            .background(hovering ? palette.surface1 : .clear, in: RoundedRectangle(cornerRadius: Metrics.radiusM))
            .onHover { hovering = $0 }
    }
}

/// Native tracking, keyboard and accessibility with workspace-drawn slider surfaces.
struct StudioSlider: NSViewRepresentable {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @Binding var value: Double
    let range: ClosedRange<Double>

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        slider.cell = StudioSliderCell()
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isEnabled = isEnabled
        if let cell = slider.cell as? StudioSliderCell {
            cell.trackColor = NSColor(palette.surface3)
            cell.fillColor = NSColor(palette.accent)
            cell.knobColor = NSColor(palette.textPrimary)
        }
        slider.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    @MainActor final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func changed(_ sender: NSSlider) { value.wrappedValue = sender.doubleValue }
    }
}

private final class StudioSliderCell: NSSliderCell {
    var trackColor = NSColor.separatorColor
    var fillColor = NSColor.controlAccentColor
    var knobColor = NSColor.labelColor

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        trackColor.withAlphaComponent(isEnabled ? 1 : 0.38).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let fraction = CGFloat((doubleValue - minValue) / max(0.001, maxValue - minValue))
        let fill = NSRect(x: track.minX, y: track.minY, width: track.width * min(1, max(0, fraction)), height: track.height)
        fillColor.withAlphaComponent(isEnabled ? 1 : 0.38).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let knob = NSRect(x: knobRect.midX - 5, y: knobRect.midY - 5, width: 10, height: 10)
        knobColor.withAlphaComponent(isEnabled ? 1 : 0.38).setFill()
        NSBezierPath(ovalIn: knob).fill()
    }
}
