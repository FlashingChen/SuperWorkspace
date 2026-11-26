import RecorderCore
import RecorderKit
import SwiftUI

/// Unified real-time Rough-Cut & AI Motion Inspector inside Editing Panel (`AssemblyView`).
/// Edits the selected clip's non-destructive `RecorderProject` (`roughcut.dogscproject`) live
/// and exposes the per-clip AI Motion switch right at the top.
struct ClipRoughCutInspector: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette

    let project: VideoProject
    let material: Material
    let clipIndex: Int
    let clipLocalTime: Double
    let onSeekClipLocalTime: (Double) -> Void
    var onClose: () -> Void = {}

    enum Tab: String, CaseIterable, Identifiable {
        case canvas = "画面"
        case zoom = "缩放"
        case cursor = "光标"
        case advanced = "高级"
        var id: String { rawValue }
    }

    @State private var activeTab: Tab = .canvas
    @State private var draftProject = RecorderProject()
    @State private var motionPrompt = ""
    @State private var hasCamera = false

    private var isAIMotionEnabled: Bool {
        if material.motionState == .complete {
            return material.wantsMotion && material.useOriginal != true
        }
        return material.wantsMotion && [.queued, .running].contains(material.motionState)
    }

    private var isMotionBusy: Bool {
        [.queued, .running].contains(material.motionState) || state.motionPhases[material.mediaID] != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.space3) {
                    aiMotionSwitchCard
                    tabPicker
                    switch activeTab {
                    case .canvas:
                        canvasSection
                    case .zoom:
                        zoomSection
                    case .cursor:
                        cursorSection
                    case .advanced:
                        advancedSection
                    }
                }
                .padding(Metrics.space3)
            }
        }
        .background(palette.island)
        .onAppear { reloadDraft() }
        .onChange(of: material.id) { _, _ in reloadDraft() }
        .onChange(of: material.roughCutRevision) { _, _ in reloadDraft() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Metrics.space2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(material.displayTitle(index: clipIndex))
                    .font(.studio(.smallStrong))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Text(String(format: "%.1fs · 实时无损粗剪", material.timelineDuration))
                    .font(.studio(.caption))
                    .foregroundStyle(palette.textSecondary)
            }
            Spacer(minLength: 0)
            Button("剪气口", systemImage: "waveform.path.ecg") {
                state.applySilenceCut(project.id, material.id)
            }
            .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
            .disabled(project.isFrozen == true || !material.sourceReady)
            .help("自动检测并剪除静音停顿（支持撤销）")

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
            .accessibilityLabel("关闭片段粗剪面板")
        }
        .padding(.horizontal, Metrics.space3)
        .padding(.vertical, Metrics.space2_5)
    }

    // MARK: - Per-Clip AI Motion Switch

    private var aiMotionSwitchCard: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            HStack(spacing: Metrics.space2) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.ai)
                Text("AI 动效")
                    .font(.studio(.smallStrong))
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
                Toggle("AI 动效", isOn: Binding(
                    get: { isAIMotionEnabled },
                    set: { enabled in
                        state.toggleMaterialAIMotion(
                            project.id,
                            material.id,
                            enabled: enabled,
                            prompt: motionPrompt
                        )
                    }
                ))
                .labelsHidden()
                .toggleStyle(StudioToggleStyle())
                .disabled(project.isFrozen == true || !material.sourceReady)
            }

            if isMotionBusy {
                HStack(spacing: Metrics.space2) {
                    ProgressView().controlSize(.small)
                    Text(state.motionPhases[material.mediaID] ?? "正在生成 AI 动效…")
                        .font(.studio(.caption))
                        .foregroundStyle(palette.ai)
                        .lineLimit(1)
                }
            } else if material.motionState == .complete {
                Text(isAIMotionEnabled ? "当前显示 AI 动效成片；关闭可切回实时粗剪画面。" : "已切回实时粗剪画面；开启可随时切换为 AI 动效。")
                    .font(.studio(.caption))
                    .foregroundStyle(palette.textSecondary)
            } else {
                TextField("可选：告诉 AI 想加什么动效（如：讲到重点时弹卡片）", text: $motionPrompt)
                    .textFieldStyle(StudioTextFieldStyle())
                    .font(.studio(.caption))
                if let error = material.motionError {
                    Text(error)
                        .font(.studio(.caption))
                        .foregroundStyle(palette.danger)
                        .lineLimit(2)
                }
            }
        }
        .padding(Metrics.space2_5)
        .background(palette.surface2, in: RoundedRectangle(cornerRadius: Metrics.radiusM, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.radiusM, style: .continuous)
                .strokeBorder(isAIMotionEnabled ? palette.ai.opacity(0.45) : palette.hairline, lineWidth: 1)
        }
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        HStack(spacing: Metrics.space1) {
            ForEach(Tab.allCases) { tab in
                Button(tab.rawValue) {
                    activeTab = tab
                }
                .buttonStyle(StudioButtonStyle(kind: activeTab == tab ? .primary : .quiet, size: .compact))
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Canvas & Background

    private var canvasSection: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            sectionHeader("背景预设")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Metrics.space1_5) {
                presetButton("系统壁纸", isSelected: isSystemWallpaper) {
                    commit { $0.canvas.backgroundSource = RoughCutPackageStore.defaultStyledBackground() }
                }
                presetButton("极光流光", isSelected: draftProject.canvas.backgroundSource == .dynamicFlow(.auroraFluid)) {
                    commit { $0.canvas.backgroundSource = .dynamicFlow(.auroraFluid) }
                }
                presetButton("黑曜网格", isSelected: draftProject.canvas.backgroundSource == .pattern(.obsidianGrid)) {
                    commit { $0.canvas.backgroundSource = .pattern(.obsidianGrid) }
                }
                presetButton("工程白网", isSelected: draftProject.canvas.backgroundSource == .pattern(.engineeringWhiteGrid)) {
                    commit { $0.canvas.backgroundSource = .pattern(.engineeringWhiteGrid) }
                }
                presetButton("暗夜星阵", isSelected: draftProject.canvas.backgroundSource == .pattern(.midnightDots)) {
                    commit { $0.canvas.backgroundSource = .pattern(.midnightDots) }
                }
                presetButton("无边距原画", isSelected: draftProject.canvas.padding == 0 && draftProject.canvas.cornerRadius == 0) {
                    commit {
                        $0.canvas.padding = 0
                        $0.canvas.cornerRadius = 0
                        $0.canvas.shadowStrength = 0
                    }
                }
            }

            sliderRow(
                title: "画布边距",
                valueText: "\(Int(draftProject.canvas.padding.rounded())) pt",
                value: Binding(
                    get: { draftProject.canvas.padding },
                    set: { v in commit { $0.canvas.padding = v } }
                ),
                range: 0...140
            )

            sliderRow(
                title: "画面圆角",
                valueText: "\(Int(draftProject.canvas.cornerRadius.rounded())) pt",
                value: Binding(
                    get: { draftProject.canvas.cornerRadius },
                    set: { v in commit { $0.canvas.cornerRadius = v } }
                ),
                range: 0...48
            )

            sliderRow(
                title: "阴影强度",
                valueText: "\(Int((draftProject.canvas.shadowStrength * 100).rounded()))%",
                value: Binding(
                    get: { draftProject.canvas.shadowStrength },
                    set: { v in commit { $0.canvas.shadowStrength = v } }
                ),
                range: 0...1
            )

            sectionHeader("窗口样机")
            HStack(spacing: Metrics.space1) {
                bezelButton("无", style: .none)
                bezelButton("窗口", style: .windowDark)
                bezelButton("浏览器", style: .browserDark)
            }

            if project.materials.count > 1 {
                Button("将画面与光标样式应用到全部片段", systemImage: "square.on.square") {
                    state.applyRoughCutStyleToAll(project.id, from: material.id)
                }
                .buttonStyle(StudioButtonStyle(kind: .secondary, size: .compact))
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Zoom

    private var zoomSection: some View {
        VStack(alignment: .leading, spacing: Metrics.space2_5) {
            HStack {
                sectionHeader("缩放片段（\(draftProject.zoomAnimations.count)）")
                Spacer()
                Button("在播放头添加", systemImage: "plus") {
                    let start = min(max(0, clipLocalTime), max(0, material.duration - 0.5))
                    let end = min(material.duration, start + 2.4)
                    let clip = ZoomAnimationClip(
                        startTime: start,
                        endTime: max(start + 0.4, end),
                        scale: 1.65,
                        focus: NormalizedPoint(x: 0.5, y: 0.5),
                        origin: .manual,
                        easing: .spring
                    )
                    commit {
                        $0.zoomAnimations.append(clip)
                        $0.zoomAnimations.sort { $0.startTime < $1.startTime }
                    }
                }
                .buttonStyle(StudioButtonStyle(kind: .secondary, size: .compact))
            }

            if draftProject.zoomAnimations.isEmpty {
                Text("暂无缩放片段。点击「在播放头添加」即可实时缩放。")
                    .font(.studio(.caption))
                    .foregroundStyle(palette.textSecondary)
            } else {
                ForEach(draftProject.zoomAnimations) { clip in
                    VStack(alignment: .leading, spacing: Metrics.space1_5) {
                        HStack(spacing: Metrics.space2) {
                            Button {
                                onSeekClipLocalTime(clip.startTime + 0.15)
                            } label: {
                                Text(String(format: "%.1f–%.1fs · %.2f×", clip.startTime, clip.endTime, clip.scale))
                                    .font(.studio(.caption))
                                    .monospacedDigit()
                                    .foregroundStyle(palette.textPrimary)
                            }
                            .buttonStyle(StudioContentButtonStyle())
                            Spacer()
                            Button {
                                commit { $0.zoomAnimations.removeAll { $0.id == clip.id } }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                            .accessibilityLabel("删除缩放片段")
                        }
                        StudioSlider(
                            value: Binding(
                                get: { clip.scale },
                                set: { next in
                                    commit { proj in
                                        if let idx = proj.zoomAnimations.firstIndex(where: { $0.id == clip.id }) {
                                            proj.zoomAnimations[idx].scale = next
                                        }
                                    }
                                }
                            ),
                            range: 1.15...3.0
                        )
                        .frame(height: 18)
                    }
                    .padding(Metrics.space2)
                    .background(palette.surface2, in: RoundedRectangle(cornerRadius: Metrics.radiusM, style: .continuous))
                }
            }
        }
    }

    // MARK: - Cursor

    private var cursorSection: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            Toggle("显示矢量光标", isOn: Binding(
                get: { draftProject.cursorStyle.assetID != .hidden },
                set: { visible in
                    commit { $0.cursorStyle.assetID = visible ? .automatic : .hidden }
                }
            ))
            .toggleStyle(StudioToggleStyle())

            if draftProject.cursorStyle.assetID != .hidden {
                sliderRow(
                    title: "光标大小",
                    valueText: String(format: "%.2f×", draftProject.cursorStyle.size),
                    value: Binding(
                        get: { draftProject.cursorStyle.size },
                        set: { v in commit { $0.cursorStyle.size = v } }
                    ),
                    range: 0.6...3.0
                )

                Toggle("静止时自动隐藏光标", isOn: Binding(
                    get: { draftProject.cursorStyle.hideWhenIdle },
                    set: { v in commit { $0.cursorStyle.hideWhenIdle = v } }
                ))
                .toggleStyle(StudioToggleStyle())

                Toggle("点击涟漪效果", isOn: Binding(
                    get: { draftProject.cursorStyle.showsClickEffect },
                    set: { v in commit { $0.cursorStyle.showsClickEffect = v } }
                ))
                .toggleStyle(StudioToggleStyle())
            }
        }
    }

    // MARK: - Advanced (3D, Mosaic, Camera PiP)

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            // 3D Screen Motion
            HStack {
                sectionHeader("3D 透视（\(draftProject.timeline.screenMotionClips.count)）")
                Spacer()
                Button("添加 3D", systemImage: "plus") {
                    let start = min(max(0, clipLocalTime), max(0, material.duration - 0.5))
                    let dur = min(3.0, max(0.6, material.duration - start))
                    let clip = ScreenMotionClip(
                        timing: TransitionTiming(startTime: start, duration: dur),
                        target: ScreenMotionState(scale: 1.05, rotationX: 6, rotationY: 14)
                    )
                    commit { $0.timeline.screenMotionClips.append(clip) }
                }
                .buttonStyle(StudioButtonStyle(kind: .secondary, size: .compact))
            }
            ForEach(draftProject.timeline.screenMotionClips) { clip in
                HStack {
                    Button {
                        onSeekClipLocalTime(clip.timing.startTime + 0.15)
                    } label: {
                        Text(String(format: "3D · %.1f–%.1fs", clip.timing.startTime, clip.timing.endTime))
                            .font(.studio(.caption))
                            .monospacedDigit()
                            .foregroundStyle(palette.textPrimary)
                    }
                    .buttonStyle(StudioContentButtonStyle())
                    Spacer()
                    Button {
                        commit { $0.timeline.screenMotionClips.removeAll { $0.id == clip.id } }
                    } label: {
                        Image(systemName: "trash").font(.system(size: 11))
                    }
                    .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                }
                .padding(.horizontal, Metrics.space2)
                .padding(.vertical, Metrics.space1_5)
                .background(palette.surface2, in: RoundedRectangle(cornerRadius: Metrics.radiusM, style: .continuous))
            }

            Divider().overlay(palette.hairline)

            // Mosaic / Spotlight
            HStack {
                sectionHeader("马赛克与聚光（\(draftProject.timeline.mosaicClips.count)）")
                Spacer()
                Button("添加柔化", systemImage: "plus") {
                    let start = min(max(0, clipLocalTime), max(0, material.duration - 0.5))
                    let dur = min(3.0, max(0.6, material.duration - start))
                    let clip = MosaicClip(
                        timing: OverlayTiming(startTime: start, duration: dur),
                        sourceRect: NormalizedOverlayRect(x: 0.25, y: 0.25, width: 0.5, height: 0.35),
                        style: .blur
                    )
                    commit { $0.timeline.mosaicClips.append(clip) }
                }
                .buttonStyle(StudioButtonStyle(kind: .secondary, size: .compact))
            }
            ForEach(draftProject.timeline.mosaicClips) { clip in
                HStack {
                    Button {
                        onSeekClipLocalTime(clip.timing.startTime + 0.15)
                    } label: {
                        Text(String(format: "%@ · %.1f–%.1fs", clip.style == .spotlight ? "聚光" : "柔化", clip.timing.startTime, clip.timing.endTime))
                            .font(.studio(.caption))
                            .monospacedDigit()
                            .foregroundStyle(palette.textPrimary)
                    }
                    .buttonStyle(StudioContentButtonStyle())
                    Spacer()
                    Button {
                        commit { $0.timeline.mosaicClips.removeAll { $0.id == clip.id } }
                    } label: {
                        Image(systemName: "trash").font(.system(size: 11))
                    }
                    .buttonStyle(StudioButtonStyle(kind: .quiet, size: .compact))
                }
                .padding(.horizontal, Metrics.space2)
                .padding(.vertical, Metrics.space1_5)
                .background(palette.surface2, in: RoundedRectangle(cornerRadius: Metrics.radiusM, style: .continuous))
            }

            if hasCamera {
                Divider().overlay(palette.hairline)
                sectionHeader("摄像头画中画")
                Toggle("显示摄像头", isOn: Binding(
                    get: { !draftProject.camera.isHidden },
                    set: { v in commit { $0.camera.isHidden = !v } }
                ))
                .toggleStyle(StudioToggleStyle())

                if !draftProject.camera.isHidden {
                    sliderRow(
                        title: "画中画尺寸",
                        valueText: "\(Int((draftProject.camera.size * 100).rounded()))%",
                        value: Binding(
                            get: { draftProject.camera.size },
                            set: { v in commit { $0.camera.size = v } }
                        ),
                        range: 0.12...0.45
                    )
                    sliderRow(
                        title: "圆角程度",
                        valueText: "\(Int((draftProject.camera.roundness * 100).rounded()))%",
                        value: Binding(
                            get: { draftProject.camera.roundness },
                            set: { v in commit { $0.camera.roundness = v } }
                        ),
                        range: 0...1
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private var isSystemWallpaper: Bool {
        if case .systemImage = draftProject.canvas.backgroundSource { return true }
        return false
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.studio(.smallStrong))
            .foregroundStyle(palette.textSecondary)
    }

    private func presetButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(StudioButtonStyle(kind: isSelected ? .primary : .secondary, size: .compact))
            .frame(maxWidth: .infinity)
    }

    private func bezelButton(_ title: String, style: ScreenFrameStyle) -> some View {
        Button(title) {
            commit { $0.canvas.screenFrame = style }
        }
        .buttonStyle(StudioButtonStyle(kind: draftProject.canvas.screenFrame == style ? .primary : .secondary, size: .compact))
        .frame(maxWidth: .infinity)
    }

    private func sliderRow(title: String, valueText: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.studio(.caption)).foregroundStyle(palette.textSecondary)
                Spacer()
                Text(valueText).font(.studio(.caption)).monospacedDigit().foregroundStyle(palette.textPrimary)
            }
            StudioSlider(value: value, range: range)
                .frame(height: 18)
        }
    }

    private func reloadDraft() {
        motionPrompt = material.editingPrompt ?? ""
        hasCamera = state.hasRoughCutCamera(project.id, material.id)
        if let loaded = state.loadRoughCutProject(project.id, material.id) {
            draftProject = loaded
        }
    }

    private func commit(_ mutate: (inout RecorderProject) -> Void) {
        mutate(&draftProject)
        state.updateRoughCutProject(project.id, material.id, mutate: mutate)
    }
}
