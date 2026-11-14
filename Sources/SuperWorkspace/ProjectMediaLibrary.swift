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
        } else {
            let asset = AVURLAsset(url: input)
            let (playable, duration) = try await asset.load(.isPlayable, .duration)
            guard playable, duration.seconds.isFinite, duration.seconds > 0,
                  let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ShellError.exitStatus(-1, "无法读取图片或视频。")
            }
            let range = try await track.load(.timeRange)
            let usable = min(duration.seconds, range.end.seconds)
            guard range.start.seconds <= 0, usable.isFinite, usable >= 1.0 / 30 else {
                throw ShellError.exitStatus(-1, "视频画面起点或时长不受支持。")
            }
            media = ReferenceMedia(name: name, kind: .video, duration: usable)
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
                Image(systemName: media.kind == .image ? "photo" : "film")
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
    @State private var generating: Set<UUID> = []
    @State private var descriptionFailures: Set<UUID> = []

    private var project: VideoProject? { state.projects.first { $0.id == projectID } }
    private var canDescribeMedia: Bool { settings.canDescribeMedia }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.space5) {
                HStack {
                    Text("素材库").font(.studio(.heading))
                    Spacer()
                    Button("添加素材", systemImage: "plus") { importing = true }
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
                    Text("导入图片或视频，供 AI 剪辑时选用。")
                        .font(.studio(.body)).foregroundStyle(palette.textSecondary)
                }
            }
            .frame(maxWidth: Metrics.contentWide, alignment: .leading)
            .padding(Metrics.space8)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(palette.textPrimary).background(palette.bgBase)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true) { result in
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
            if !media.description.isEmpty {
                Text(media.description).font(.studio(.small))
                    .foregroundStyle(palette.textSecondary).lineLimit(1)
            }
        }
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
