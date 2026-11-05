import AppKit
import AVFoundation
import QuartzCore

struct Assembly {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let size: CGSize
}

@MainActor
enum ExportService {
    static func assemble(project: VideoProject, includeSubtitles: Bool = false) async throws -> Assembly {
        guard !project.materials.isEmpty else { throw failure("还没有素材。") }
        let composition = AVMutableComposition()
        var instructions: [AssemblyInstruction] = []
        var cursor = CMTime.zero
        var canvas: CGSize?
        if let width = project.canvasWidth, let height = project.canvasHeight,
           width.isFinite, height.isFinite, width >= 2, height >= 2 {
            canvas = CGSize(width: (width / 2).rounded(.down) * 2, height: (height / 2).rounded(.down) * 2)
        }
        // Use capture order, independently of editorial ordering, until the canvas is saved.
        if canvas == nil, let first = project.materials.filter(\.isReady).min(by: { $0.createdAt < $1.createdAt }),
           let track = try await AVURLAsset(url: ProjectLayout.source(first, in: project)).loadTracks(withMediaType: .video).first {
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let bounds = CGRect(origin: .zero, size: natural).applying(transform)
            if bounds.width.isFinite, bounds.height.isFinite, abs(bounds.width) >= 2, abs(bounds.height) >= 2 {
                canvas = CGSize(width: (abs(bounds.width) / 2).rounded(.down) * 2, height: (abs(bounds.height) / 2).rounded(.down) * 2)
            }
        }
        for material in project.materials {
            guard material.isReady else { throw failure("素材尚未完成，请先完成录制导出或移除失败素材。") }
            let asset = AVURLAsset(url: ProjectLayout.picture(material, in: project))
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw failure("素材没有视频轨道。") }
            let duration = try await asset.load(.duration)
            guard duration.seconds.isFinite, duration.seconds > 0 else { throw failure("素材时长无效。") }
            let size = try await source.load(.naturalSize)
            let transform = try await source.load(.preferredTransform)
            let bounds = CGRect(origin: .zero, size: size).applying(transform)
            guard bounds.width.isFinite, bounds.height.isFinite, abs(bounds.width) > 0, abs(bounds.height) > 0 else {
                throw failure("素材画面尺寸无效。")
            }
            if canvas == nil {
                canvas = CGSize(width: max(2, (abs(bounds.width) / 2).rounded(.down) * 2), height: max(2, (abs(bounds.height) / 2).rounded(.down) * 2))
            }
            let renderSize = canvas!
            let start = CMTime(seconds: material.inPoint, preferredTimescale: 600)
            let end = min(duration.seconds, material.outPoint)
            guard end > material.inPoint else { throw failure("素材裁剪范围无效。") }
            let range = CMTimeRange(start: start, duration: CMTime(seconds: end - material.inPoint, preferredTimescale: 600))
            guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw failure("无法创建视频轨道。") }
            try video.insertTimeRange(range, of: source, at: cursor)
            if let audioSource = try await asset.loadTracks(withMediaType: .audio).first,
               let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let audioRange = try await audioSource.load(.timeRange)
                let available = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                if available.duration > .zero { try audio.insertTimeRange(available, of: audioSource, at: CMTimeAdd(cursor, CMTimeSubtract(available.start, start))) }
            }
            let scale = min(renderSize.width / abs(bounds.width), renderSize.height / abs(bounds.height))
            let fit = transform
                .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (renderSize.width - abs(bounds.width) * scale) / 2, y: (renderSize.height - abs(bounds.height) * scale) / 2))
            let overlays: [SubtitleOverlay] = includeSubtitles ? material.visibleSubtitles.compactMap { subtitle in
                guard !subtitle.text.isEmpty, subtitle.end > subtitle.start else { return nil }
                guard let caption = SubtitleRenderer.caption(subtitle.text, canvas: renderSize) else { return nil }
                return SubtitleOverlay(start: cursor.seconds + subtitle.start, end: cursor.seconds + subtitle.end,
                                       image: caption.image, frame: caption.frame)
            } : []
            instructions.append(AssemblyInstruction(range: CMTimeRange(start: cursor, duration: range.duration),
                trackID: video.trackID, transform: fit, overlays: overlays))
            cursor = CMTimeAdd(cursor, range.duration)
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = AssemblyCompositor.self
        videoComposition.renderSize = canvas!
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions
        return Assembly(composition: composition, videoComposition: videoComposition, size: canvas!)
    }

    static func export(project: VideoProject, progress: ExportProgress? = nil) async throws -> URL {
        guard project.canExport else { throw failure("请完成素材导出；字幕未就绪时可关闭字幕导出。") }
        let assembly = try await assemble(project: project, includeSubtitles: project.includeSubtitles)
        guard let session = AVAssetExportSession(asset: assembly.composition, presetName: AVAssetExportPresetHighestQuality) else { throw failure("无法创建导出任务。") }
        guard progress?.isCancelled != true else { throw CancellationError() }
        progress?.session = session
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                progress?.fraction = Double(session.progress)
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
        defer { monitor.cancel(); progress?.session = nil }
        let output = ProjectLayout.url("export-\(UUID().uuidString).mp4", for: project)
        session.outputURL = output
        session.outputFileType = .mp4
        session.videoComposition = assembly.videoComposition
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            if progress?.isCancelled == true { throw CancellationError() }
            throw session.error ?? failure("视频导出未完成，请重试。")
        }
        if project.exportSRT == true {
            do { try srt(project.assembledSubtitles).write(to: output.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8) }
            catch { try? FileManager.default.removeItem(at: output); throw error }
        }
        progress?.fraction = 1
        return output
    }
    static func srt(_ subtitles: [TranscriptSegment]) -> String {
        let entries = subtitles.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return entries.enumerated().map { index, subtitle in
            "\(index + 1)\n\(srtTime(subtitle.start)) --> \(srtTime(subtitle.end))\n\(subtitle.text.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n\n", with: "\n"))\n"
        }.joined(separator: "\n")
    }
    private static func srtTime(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000, (milliseconds / 60_000) % 60,
                      (milliseconds / 1000) % 60, milliseconds % 1000)
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Assembly", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
