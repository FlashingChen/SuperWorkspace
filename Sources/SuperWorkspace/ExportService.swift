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
        for material in project.materials {
            guard material.isReady else { throw failure("素材或动效尚未完成。") }
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
            let range = CMTimeRange(start: .zero, duration: duration)
            guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw failure("无法创建视频轨道。") }
            try video.insertTimeRange(range, of: source, at: cursor)
            if let audioSource = try await asset.loadTracks(withMediaType: .audio).first,
               let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let audioRange = try await audioSource.load(.timeRange)
                let available = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                if available.duration > .zero { try audio.insertTimeRange(available, of: audioSource, at: CMTimeAdd(cursor, available.start)) }
            }
            let scale = min(renderSize.width / abs(bounds.width), renderSize.height / abs(bounds.height))
            let fit = transform
                .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (renderSize.width - abs(bounds.width) * scale) / 2, y: (renderSize.height - abs(bounds.height) * scale) / 2))
            let overlays: [SubtitleOverlay] = includeSubtitles ? material.subtitles.compactMap { subtitle in
                guard !subtitle.text.isEmpty, subtitle.end > subtitle.start else { return nil }
                let fontSize = max(18, renderSize.height * 0.035)
                let size = CGSize(width: renderSize.width * 0.86, height: fontSize * 3)
                guard let image = subtitleImage(subtitle.text, size: size, fontSize: fontSize) else { return nil }
                return SubtitleOverlay(start: cursor.seconds + subtitle.start, end: cursor.seconds + subtitle.end, image: image,
                    frame: CGRect(x: renderSize.width * 0.07, y: renderSize.height * 0.06, width: size.width, height: size.height))
            } : []
            instructions.append(AssemblyInstruction(range: CMTimeRange(start: cursor, duration: duration),
                trackID: video.trackID, transform: fit, overlays: overlays))
            cursor = CMTimeAdd(cursor, duration)
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = AssemblyCompositor.self
        videoComposition.renderSize = canvas!
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions
        return Assembly(composition: composition, videoComposition: videoComposition, size: canvas!)
    }

    static func export(project: VideoProject) async throws -> URL {
        guard project.canExport else { throw failure("请等待素材、动效和字幕处理完成。") }
        let assembly = try await assemble(project: project, includeSubtitles: true)
        guard let session = AVAssetExportSession(asset: assembly.composition, presetName: AVAssetExportPresetHighestQuality) else { throw failure("无法创建导出任务。") }
        let output = ProjectLayout.url("export-\(UUID().uuidString).mp4", for: project)
        session.outputURL = output
        session.outputFileType = .mp4
        session.videoComposition = assembly.videoComposition
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw session.error ?? failure("视频导出未完成。")
        }
        return output
    }
    private static func subtitleImage(_ text: String, size: CGSize, fontSize: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 2, y: 2)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let shadow = NSShadow()
        shadow.shadowColor = .black
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white, .paragraphStyle: paragraph, .shadow: shadow,
        ]).draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Assembly", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
