import AppKit
import AVFoundation
import ImageIO
import QuartzCore

struct Assembly {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let size: CGSize
}

@MainActor
enum ExportService {
    static func assemble(project: VideoProject, includeSubtitles: Bool = false,
                         inserts: [AIEditing.Insert] = []) async throws -> Assembly {
        guard !project.materials.isEmpty else { throw failure("还没有素材。") }
        let composition = AVMutableComposition()
        var instructions: [AssemblyInstruction] = []
        var audioTrack: AVMutableCompositionTrack?
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
        let library = Dictionary(uniqueKeysWithValues: project.referenceMedia.map { ($0.id, $0) })
        for material in project.materials {
            try Task.checkCancellation()
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
            if let audioSource = try await asset.loadTracks(withMediaType: .audio).first {
                let audioRange = try await audioSource.load(.timeRange)
                let available = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                if available.duration > .zero {
                    // One shared audio track keeps the exported file playable everywhere:
                    // a track per clip turns every other clip into silence in single-track players.
                    let audio = audioTrack ?? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    audioTrack = audio
                    try audio?.insertTimeRange(available, of: audioSource, at: CMTimeAdd(cursor, CMTimeSubtract(available.start, start)))
                }
            }
            let fit = fittedTransform(bounds: bounds, transform: transform, canvas: renderSize)
            var cutaways: [Cutaway] = []
            // Stored plans can outlive a trim or a removed library asset: drop what no longer fits.
            for insert in AIEditing.validatedInserts(inserts, clipID: material.id, clipStart: material.inPoint,
                                                     clipEnd: end, library: library) {
                guard let reference = library[insert.assetID] else { continue }
                let url = ProjectLayout.reference(reference, in: project)
                let start = CMTime(seconds: insert.start - material.inPoint, preferredTimescale: 600)
                let duration = CMTime(seconds: insert.end - insert.start, preferredTimescale: 600)
                let cutawayRange = CMTimeRange(start: cursor + start, duration: duration)
                cutaways.append(try await cutaway(url, kind: reference.kind, range: cutawayRange,
                                                  assetStart: insert.assetStart ?? 0, canvas: renderSize, composition: composition))
            }
            let overlays: [SubtitleOverlay] = includeSubtitles ? material.visibleSubtitles.compactMap { subtitle in
                guard !subtitle.text.isEmpty, subtitle.end > subtitle.start else { return nil }
                guard let caption = SubtitleRenderer.caption(subtitle.text, canvas: renderSize) else { return nil }
                return SubtitleOverlay(start: cursor.seconds + subtitle.start, end: cursor.seconds + subtitle.end,
                                       image: caption.image, frame: caption.frame)
            } : []
            instructions.append(AssemblyInstruction(range: CMTimeRange(start: cursor, duration: range.duration),
                trackID: video.trackID, transform: fit, overlays: overlays, cutaways: cutaways))
            cursor = CMTimeAdd(cursor, range.duration)
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = AssemblyCompositor.self
        videoComposition.renderSize = canvas!
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions
        return Assembly(composition: composition, videoComposition: videoComposition, size: canvas!)
    }

    // MARK: - Fallback background

    /// A neutral fallback background: a near-black grey gradient with a soft vignette. It only
    /// makes sure an insert has a composed frame instead of bare black, a blurred copy of the
    /// picture or a stretched asset. This is not a visual spec: the final style is decided by the
    /// motion layer.
    static func backdrop(for canvas: CGSize) -> CGImage {
        let size = backdropSize(canvas)
        let context = rgbaContext(size)!
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)

        // Slight vertical gradient between two neutral near-blacks.
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 0.071, green: 0.071, blue: 0.071, alpha: 1),
            CGColor(red: 0.035, green: 0.035, blue: 0.035, alpha: 1),
        ] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: centre.x, y: size.height),
                                       end: CGPoint(x: centre.x, y: 0),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }

        // Soft vignette so the rim does not read as a flat black band.
        context.saveGState()
        context.translateBy(x: centre.x, y: centre.y)
        context.scaleBy(x: size.width / size.height, y: 1)
        if let vignette = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: 0, green: 0, blue: 0, alpha: 0),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.28),
        ] as CFArray, locations: [0, 0.5, 1]) {
            context.drawRadialGradient(vignette, startCenter: .zero, startRadius: 0, endCenter: .zero,
                                       endRadius: size.height / CGFloat(2).squareRoot(),
                                       options: [.drawsAfterEndLocation])
        }
        context.restoreGState()
        return context.makeImage()!
    }

    /// Two canvas-sized layers: the fallback background, and the picture contained in a rounded
    /// window on transparency. The compositor fades and slightly pushes the picture layer, so the
    /// layers stay separate.
    private static func stillLayers(_ image: CGImage, canvas: CGSize) -> Cutaway.Still? {
        let size = backdropSize(canvas)
        guard let foreground = stillForeground(image, size: size) else { return nil }
        return Cutaway.Still(background: backdrop(for: size), foreground: foreground)
    }

    /// Fallback framing for a still: contain the picture in a centred rounded window with a thin
    /// rim, a soft shadow and a neutral near-black backing. The margins and radii are practical
    /// defaults, not a design rule.
    private static func stillForeground(_ image: CGImage, size: CGSize) -> CGImage? {
        guard let context = rgbaContext(size) else { return nil }
        let unit = size.height / 1080
        let window = pictureWindow(in: size)
        let radius = 10 * unit
        let path = CGPath(roundedRect: window, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Soft shadow, then the window backing and the contained picture clipped to the window.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -20 * unit), blur: 50 * unit,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        context.addPath(path)
        context.setFillColor(red: 0.043, green: 0.043, blue: 0.043, alpha: 1)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.setFillColor(red: 0.043, green: 0.043, blue: 0.043, alpha: 1)
        context.fill(window)
        context.interpolationQuality = .high
        context.draw(image, in: containedRect(CGSize(width: image.width, height: image.height), in: window))
        context.restoreGState()

        context.addPath(path)
        context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.14)
        context.setLineWidth(1.5 * unit)
        context.strokePath()
        return context.makeImage()
    }

    private static func backdropSize(_ canvas: CGSize) -> CGSize {
        CGSize(width: max(2, canvas.width.rounded()), height: max(2, canvas.height.rounded()))
    }

    private static func rgbaContext(_ size: CGSize) -> CGContext? {
        CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                  bytesPerRow: Int(size.width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Centred window with a small margin on every side: a fallback layout, not a design rule.
    private static func pictureWindow(in canvas: CGSize) -> CGRect {
        let size = backdropSize(canvas)
        let marginX = size.width * 0.07
        let marginY = size.height * 0.07
        return CGRect(x: marginX, y: marginY,
                      width: size.width - 2 * marginX, height: size.height - 2 * marginY)
    }

    private static func containedRect(_ source: CGSize, in window: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return window }
        let scale = min(window.width / source.width, window.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: window.midX - size.width / 2, y: window.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private static func fittedTransform(bounds: CGRect, transform: CGAffineTransform, canvas: CGSize) -> CGAffineTransform {
        let scale = min(canvas.width / bounds.width, canvas.height / bounds.height)
        return transform
            .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (canvas.width - bounds.width * scale) / 2,
                                             y: (canvas.height - bounds.height * scale) / 2))
    }

    private static func cutaway(_ url: URL, kind: ReferenceMedia.Kind, range: CMTimeRange, assetStart: Double,
                                canvas: CGSize, composition: AVMutableComposition) async throws -> Cutaway {
        switch kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: min(8192, max(canvas.width, canvas.height))
                  ] as CFDictionary) else { throw failure("无法读取素材库图片。") }
            // A still never sits on bare black: the fallback background carries the frame, and
            // the picture sits in a rounded window the compositor animates.
            guard let staged = stillLayers(image, canvas: canvas) else { throw failure("无法生成素材画面。") }
            return Cutaway(range: range, content: .still(staged), transform: .identity)
        case .video:
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first,
                  let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw failure("无法读取素材库视频。")
            }
            let (size, transform, sourceRange) = try await source.load(.naturalSize, .preferredTransform, .timeRange)
            let bounds = CGRect(origin: .zero, size: size).applying(transform)
            let start = CMTime(seconds: assetStart, preferredTimescale: 600)
            let duration = min(sourceRange.end - start, range.duration)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
                  start >= sourceRange.start, duration > .zero else { throw failure("补充视频的画面尺寸或时间无效。") }
            try target.insertTimeRange(CMTimeRange(start: start, duration: duration), of: source, at: range.start)
            // The cutaway frame is laid over the same fallback background instead of on black.
            return Cutaway(range: CMTimeRange(start: range.start, duration: duration),
                           content: .video(target.trackID, backdrop: backdrop(for: canvas)),
                           transform: fittedTransform(bounds: bounds, transform: transform, canvas: canvas))
        }
    }

    private static func matchesExportCanvas(_ picture: URL, project: VideoProject) async -> Bool {
        guard let width = project.canvasWidth, let height = project.canvasHeight else { return true }
        guard let track = try? await AVURLAsset(url: picture).loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return false }
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        return bounds.width == width && bounds.height == height
    }

    static func export(project: VideoProject, progress: ExportProgress? = nil,
                       inserts: [AIEditing.Insert] = []) async throws -> URL {
        guard project.canExport else { throw failure("请完成素材导出；字幕未就绪时可关闭字幕导出。") }
        // 单素材、未裁剪、不烧字幕：直接复制画面与声音，避免整片重编码。
        try Task.checkCancellation()
        if inserts.isEmpty,
           project.materials.count == 1, !project.includeSubtitles,
           let material = project.materials.first,
           material.inPoint <= 0.001, abs(material.outPoint - material.duration) <= 0.001,
           await matchesExportCanvas(ProjectLayout.picture(material, in: project), project: project) {
            try Task.checkCancellation()
            let picture = ProjectLayout.picture(material, in: project)
            let output = ProjectLayout.url("export-\(UUID().uuidString).mp4", for: project)
            do {
                try FileManager.default.copyItem(at: picture, to: output)
            } catch {
                throw failure("无法复制导出画面：\(error.localizedDescription)")
            }
            if project.exportSRT == true {
                do { try srt(project.assembledSubtitles).write(to: output.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8) }
                catch { try? FileManager.default.removeItem(at: output); throw error }
            }
            progress?.fraction = 1
            return output
        }
        let assembly = try await assemble(project: project, includeSubtitles: project.includeSubtitles, inserts: inserts)
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
        guard session.status == .completed, progress?.isCancelled != true, !Task.isCancelled else {
            try? FileManager.default.removeItem(at: output)
            if progress?.isCancelled == true || Task.isCancelled { throw CancellationError() }
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
