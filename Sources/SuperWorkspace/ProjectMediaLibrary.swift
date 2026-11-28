import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum ReferenceMediaImport {
    static func copy(_ input: URL, into project: VideoProject) async throws -> ReferenceMedia {
        let scoped = input.startAccessingSecurityScopedResource()
        defer { if scoped { input.stopAccessingSecurityScopedResource() } }
        let type = try input.resourceValues(forKeys: [.contentTypeKey]).contentType
        let name = input.lastPathComponent
        var media: ReferenceMedia
        if type?.conforms(to: .image) == true, let image = CGImageSourceCreateWithURL(input as CFURL, nil),
           CGImageSourceCreateThumbnailAtIndex(image, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                          kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) != nil {
            media = ReferenceMedia(name: name, kind: .image)
        } else if type?.conforms(to: .audio) == true {
            let asset = AVURLAsset(url: input)
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            guard playable, duration.seconds.isFinite, duration.seconds > 0,
                  try await asset.loadTracks(withMediaType: .audio).first != nil else {
                throw ShellError.exitStatus(-1, "无法读取音频文件。")
            }
            media = ReferenceMedia(name: name, kind: .audio, duration: duration.seconds)
        } else {
            let asset = AVURLAsset(url: input)
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            if playable, duration.seconds.isFinite, duration.seconds > 0,
               let track = try await asset.loadTracks(withMediaType: .video).first {
                let range = try await track.load(.timeRange)
                let usable = min(duration.seconds, range.end.seconds)
                guard range.start.seconds <= 0, usable.isFinite, usable >= 1.0 / 30 else {
                    throw ShellError.exitStatus(-1, "视频画面起点或时长不受支持。")
                }
                media = ReferenceMedia(name: name, kind: .video, duration: usable)
            } else if playable, duration.seconds.isFinite, duration.seconds > 0,
                      try await asset.loadTracks(withMediaType: .audio).first != nil {
                media = ReferenceMedia(name: name, kind: .audio, duration: duration.seconds)
            } else {
                throw ShellError.exitStatus(-1, "无法读取图片、视频或音频。")
            }
        }
        let destination = ProjectLayout.reference(media, in: project)
        try await Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try files.copyItem(at: input, to: destination) }
            catch { try? files.removeItem(at: destination); throw error }
        }.value
        return media
    }
}

enum ReferenceMediaPreview {
    static func frame(_ media: ReferenceMedia, at url: URL, maxSize: Int) async -> CGImage? {
        switch media.kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSize
            ] as CFDictionary)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxSize, height: maxSize)
            let time = CMTime(seconds: (media.duration ?? 0) / 2, preferredTimescale: 600)
            return try? await generator.image(at: time).image
        case .audio:
            return nil
        }
    }
}

private struct ReferenceMediaThumbnail: View {
    @Environment(\.palette) private var palette
    let media: ReferenceMedia
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            palette.surface1
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Image(systemName: media.kind == .image ? "photo" : (media.kind == .audio ? "music.note" : "film"))
                    .font(.studio(media.kind == .audio ? .heading : .body))
                    .foregroundStyle(media.kind == .audio ? palette.success : palette.textSecondary)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusL))
        .accessibilityHidden(true)
        .task(id: url) { image = await ReferenceMediaPreview.frame(media, at: url, maxSize: 640) }
    }
}

struct ProjectMediaLibrary: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.palette) private var palette
    @ObservedObject private var settings = SettingsStore.shared
    let projectID: UUID
    @State private var importing = false
    @State private var pending = false
    @State private var notice: String?
    @State private var removing: ReferenceMedia?
    @State private var describing: ReferenceMedia?
    @State private var assigning: ReferenceMedia?
    @State private var generating: Set<UUID> = []
    @State private var descriptionFailures: Set<UUID> = []

    private var project: VideoProject? { state.projects.first { $0.id == projectID } }
    private var canDescribeMedia: Bool { settings.canDescribeMedia }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.space5) {
                HStack(spacing: Metrics.space2) {
                    Text("素材库").font(.studio(.heading))
                    Spacer()
                    Button("录制素材", systemImage: "record.circle") {
                        state.recordLibraryMedia(projectID) { media in
                            if settings.aiAutoDescribeMedia {
                                generateDescriptions(for: [media], missingOnly: true)
                            }
                        }
                    }
                    .buttonStyle(StudioButtonStyle(kind: .secondary))
                    .disabled(pending || project?.isFrozen == true)
                    .help("用粗剪面板录一段演示画面，直接存入当前项目素材库")
                    Button("导入素材", systemImage: "plus") { importing = true }
                        .buttonStyle(StudioButtonStyle(kind: .primary))
                        .disabled(pending)
                }
                if pending || notice != nil {
                    Text(pending ? "正在导入素材" : notice ?? "")
                        .font(.studio(.body)).foregroundStyle(palette.textSecondary)
                }
                if let project, !project.referenceMedia.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 225, maximum: 360), spacing: Metrics.space5)],
                              alignment: .leading, spacing: Metrics.space6) {
                        ForEach(project.referenceMedia) { media in
                            mediaTile(media, in: project)
                        }
                    }.padding(2)
                } else if !pending {
                    Text("导入图片、视频或音频，或直接录制演示片段存入素材库；默认全部视频可用，也可指定必用于某条视频。")
                        .font(.studio(.body)).foregroundStyle(palette.textSecondary)
                }
            }
            .frame(maxWidth: Metrics.contentWide, alignment: .leading)
            .padding(Metrics.space8)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(palette.textPrimary).background(palette.bgBase)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .movie, .audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importMedia(urls)
            case .failure(let error): notice = error.localizedDescription
            }
        }
        .sheet(item: $describing) { media in
            ReferenceDescriptionSheet(media: media) { description in
                state.updateProject(projectID) { project in
                    guard let index = project.referenceMedia.firstIndex(where: { $0.id == media.id }) else { return }
                    project.referenceMedia[index].description = description
                }
            }
        }
        .sheet(item: $assigning) { media in
            if let project {
                ReferenceAssignmentSheet(media: media, materials: project.materials) { selectedMediaIDs in
                    state.updateProject(projectID) { updated in
                        guard let index = updated.referenceMedia.firstIndex(where: { $0.id == media.id }) else { return }
                        updated.referenceMedia[index].requiredForMediaIDs = selectedMediaIDs.isEmpty ? nil : selectedMediaIDs
                    }
                }
            }
        }
        .sheet(item: $removing) { media in
            StudioMessageSheet(title: "移出素材库", message: "从项目中移除「\(media.name)」的副本。",
                               actionTitle: "移除", cancelTitle: "取消", destructive: true) {
                remove(media)
            }
        }
    }

    private func mediaTile(_ media: ReferenceMedia, in project: VideoProject) -> some View {
        let url = ProjectLayout.reference(media, in: project)
        let generateTitle: String = media.description.isEmpty ? "生成描述" : "重新生成描述"
        return VStack(alignment: .leading, spacing: Metrics.space2) {
            Button { NSWorkspace.shared.open(url) } label: {
                ReferenceMediaThumbnail(media: media, url: url)
            }
            .buttonStyle(StudioContentButtonStyle())
            .accessibilityLabel("打开\(media.name)")
            HStack(spacing: Metrics.space2) {
                Image(systemName: media.kind == .image ? "photo" : "film").accessibilityHidden(true)
                Text(media.name).font(.studio(.bodyMedium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if generating.contains(media.id) {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("正在生成素材描述")
                } else if descriptionFailures.contains(media.id) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(palette.textMuted)
                        .accessibilityLabel("未能生成素材描述，可重试")
                        .help("未能生成素材描述，可重试")
                }
                Menu {
                    if media.kind != .audio {
                        Button("指定必用视频…") { assigning = media }
                    }
                    Button("编辑素材说明") { describing = media }
                    Button(generateTitle) { generateDescriptions(for: [media], missingOnly: false) }
                    .disabled(!canDescribeMedia || generating.contains(media.id))
                    .help("需要开启「模型支持图片」的 AI 连接")
                    Divider()
                    Button("移出素材库", role: .destructive) { removing = media }
                        .disabled(state.exportingProjects.contains(projectID))
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(StudioMenuStyle())
                .fixedSize()
                .accessibilityLabel("\(media.name) 的操作")
            }
            if media.kind != .audio {
                let targetNames = assignmentSummary(for: media, in: project)
                Button { assigning = media } label: {
                    HStack(spacing: Metrics.space1) {
                        Image(systemName: media.hasRequiredTargets ? "pin.fill" : "sparkles")
                            .font(.studio(.micro))
                        Text(targetNames)
                            .font(.studio(.caption, weight: media.hasRequiredTargets ? .medium : .regular))
                            .lineLimit(1)
                    }
                    .foregroundStyle(media.hasRequiredTargets ? palette.ai : palette.textSecondary)
                    .padding(.horizontal, Metrics.space2)
                    .padding(.vertical, 2)
                    .background((media.hasRequiredTargets ? palette.ai.opacity(0.12) : palette.controlWell), in: Capsule())
                }
                .buttonStyle(StudioContentButtonStyle())
                .help("设置这条素材是全部视频自由可用，还是必用于指定视频")
            }
            if !media.description.isEmpty {
                Text(media.description).font(.studio(.small))
                    .foregroundStyle(palette.textSecondary).lineLimit(1)
            }
        }
    }

    private func assignmentSummary(for media: ReferenceMedia, in project: VideoProject) -> String {
        guard let ids = media.requiredForMediaIDs, !ids.isEmpty else { return "全部视频可用" }
        var seen = Set<UUID>()
        var labels: [String] = []
        for (idx, material) in project.materials.enumerated() where ids.contains(material.mediaID) {
            guard seen.insert(material.mediaID).inserted else { continue }
            labels.append(material.displayTitle(index: idx))
        }
        return labels.isEmpty ? "全部视频可用" : "必用：\(labels.joined(separator: "、"))"
    }

    private func remove(_ media: ReferenceMedia) {
        guard let project, !state.exportingProjects.contains(projectID),
              state.updateProject(projectID, { $0.referenceMedia.removeAll { $0.id == media.id } }) else { return }
        do { try FileManager.default.removeItem(at: ProjectLayout.reference(media, in: project)) }
        catch { notice = "已移出素材库，删除副本失败。\(error.localizedDescription)" }
    }

    private func importMedia(_ urls: [URL]) {
        guard let project, !urls.isEmpty else { return }
        pending = true
        notice = nil
        Task {
            defer { pending = false }
            var failures: [String] = []
            var imported: [ReferenceMedia] = []
            for url in urls {
                do {
                    let media = try await ReferenceMediaImport.copy(url, into: project)
                    if state.updateProject(projectID, { $0.referenceMedia.append(media) }) {
                        imported.append(media)
                    } else {
                        try? FileManager.default.removeItem(at: ProjectLayout.reference(media, in: project))
                    }
                } catch { failures.append(url.lastPathComponent) }
            }
            if !failures.isEmpty { notice = "无法导入 \(failures.joined(separator: "、"))" }
            if settings.aiAutoDescribeMedia { generateDescriptions(for: imported, missingOnly: true) }
        }
    }

    /// Runs one description per asset in the background and writes each result back
    /// through the same project update the editor sheet uses. A failure leaves the
    /// stored description untouched and only marks the tile.
    private func generateDescriptions(for targets: [ReferenceMedia], missingOnly: Bool) {
        guard settings.canDescribeMedia, let project, let connection = try? settings.apiConnection() else { return }
        let queue = missingOnly ? targets.filter(MediaDescription.needsDescription) : targets
        guard !queue.isEmpty else { return }
        generating.formUnion(queue.map(\.id))
        descriptionFailures.subtract(queue.map(\.id))
        Task {
            for media in queue {
                let url = ProjectLayout.reference(media, in: project)
                let description = await MediaDescription.describe(media, at: url, connection: connection)
                generating.remove(media.id)
                guard let description else {
                    descriptionFailures.insert(media.id)
                    continue
                }
                let saved = state.updateProject(projectID) { project in
                    guard let index = project.referenceMedia.firstIndex(where: { $0.id == media.id }) else { return }
                    project.referenceMedia[index].description = description
                }
                if !saved { descriptionFailures.insert(media.id) }
            }
        }
    }
}

private struct ReferenceDescriptionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let media: ReferenceMedia
    let save: (String) -> Bool
    @State private var description = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space4) {
            Text("素材说明").font(.studio(.heading))
            Text(media.name).font(.studio(.body)).foregroundStyle(palette.textSecondary).lineLimit(1)
            TextField("例如：展示完成后的界面", text: $description,
                      prompt: Text("例如：展示完成后的界面").foregroundStyle(palette.textMuted), axis: .vertical)
                .textFieldStyle(StudioTextFieldStyle()).lineLimit(2...4).focused($focused)
                .accessibilityLabel("素材说明")
            HStack {
                Button { dismiss() } label: { Text(verbatim: "取消") }
                    .buttonStyle(StudioButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    if save(description.trimmingCharacters(in: .whitespacesAndNewlines)) { dismiss() }
                } label: { Text(verbatim: "保存") }
                    .buttonStyle(StudioButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Metrics.space7).frame(width: 440)
        .foregroundStyle(palette.textPrimary).background(palette.bgBase)
        .onAppear { description = media.description; focused = true }
    }
}

private struct ReferenceAssignmentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    let media: ReferenceMedia
    let materials: [Material]
    let save: ([UUID]) -> Bool
    @State private var selected: Set<UUID> = []

    private var uniqueVideos: [(mediaID: UUID, title: String)] {
        var seen = Set<UUID>()
        var list: [(UUID, String)] = []
        for (idx, m) in materials.enumerated() where seen.insert(m.mediaID).inserted {
            list.append((m.mediaID, m.displayTitle(index: idx)))
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space4) {
            Text("指定必用视频").font(.studio(.heading))
            Text("不勾选任何视频时，这条素材默认「全部视频可用」；勾选后，对应视频在 AI 包装时必须体现这条素材。")
                .font(.studio(.small))
                .foregroundStyle(palette.textSecondary)
            if uniqueVideos.isEmpty {
                Text("当前项目还没有已录制的视频。")
                    .font(.studio(.body))
                    .foregroundStyle(palette.textSecondary)
                    .padding(.vertical, Metrics.space2)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(uniqueVideos.enumerated()), id: \.element.mediaID) { idx, video in
                        if idx > 0 {
                            Rectangle().fill(palette.hairline).frame(height: 1)
                        }
                        Toggle(video.title, isOn: Binding(
                            get: { selected.contains(video.mediaID) },
                            set: { on in
                                if on { selected.insert(video.mediaID) } else { selected.remove(video.mediaID) }
                            }
                        ))
                    }
                }
                .toggleStyle(StudioToggleStyle())
                .studioTile(cornerRadius: Metrics.radiusIsland, padding: Metrics.space2)
            }
            HStack {
                Button { dismiss() } label: { Text(verbatim: "取消") }
                    .buttonStyle(StudioButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                if !selected.isEmpty {
                    Button("恢复全部可用") { selected.removeAll() }
                        .buttonStyle(StudioButtonStyle(kind: .quiet))
                }
                Button {
                    let ordered = uniqueVideos.map(\.mediaID).filter { selected.contains($0) }
                    if save(ordered) { dismiss() }
                } label: { Text(verbatim: "保存") }
                    .buttonStyle(StudioButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Metrics.space7).frame(width: 440)
        .foregroundStyle(palette.textPrimary).background(palette.bgBase)
        .onAppear { selected = Set(media.requiredForMediaIDs ?? []) }
    }
}
