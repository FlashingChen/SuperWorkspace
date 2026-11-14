import AVFoundation
import CoreImage

struct SubtitleOverlay: @unchecked Sendable {
    let start: Double
    let end: Double
    let image: CGImage
    let frame: CGRect
}

struct Cutaway: @unchecked Sendable {
    /// A still carries its own fallback background plus the picture layer, so the compositor can
    /// animate the two layers independently instead of pasting one flat card on black.
    struct Still {
        let background: CGImage
        let foreground: CGImage
    }
    enum Content {
        case still(Still)
        /// A video cutaway keeps the fallback background behind its picture so a contained frame
        /// never sits on black.
        case video(CMPersistentTrackID, backdrop: CGImage)
    }
    let range: CMTimeRange
    let content: Content
    let transform: CGAffineTransform
}

final class AssemblyInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let transform: CGAffineTransform
    let overlays: [SubtitleOverlay]
    let cutaways: [Cutaway]
    init(range: CMTimeRange, trackID: CMPersistentTrackID, transform: CGAffineTransform,
         overlays: [SubtitleOverlay], cutaways: [Cutaway] = []) {
        timeRange = range
        self.trackID = trackID
        self.transform = transform
        self.overlays = overlays
        self.cutaways = cutaways
        requiredSourceTrackIDs = [NSNumber(value: trackID)] + cutaways.compactMap {
            if case .video(let id, _) = $0.content { return NSNumber(value: id) }
            return nil
        }
    }
}

final class AssemblyCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    /// Audio often outlasts video by a few milliseconds, so the last composition request can
    /// land past the final video frame. Reuse the previous picture instead of failing the export.
    private let lastFrameLock = NSLock()
    private var lastFrames: [CMPersistentTrackID: CVPixelBuffer] = [:]
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    /// Slow push-in on the fallback background, gentle scale and fade on the picture: a placed
    /// still reads as an animated card rather than a static slide.
    private static func stillFrame(_ still: Cutaway.Still, at time: CMTime, range: CMTimeRange, canvas: CGSize) -> CIImage {
        let duration = max(range.duration.seconds, 0.001)
        let elapsed = max(0, min(duration, (time - range.start).seconds))
        let progress = elapsed / duration
        let bounds = CGRect(origin: .zero, size: canvas)

        let drift = 1.0 + 0.035 * progress
        let background = CIImage(cgImage: still.background)
            .transformed(by: CGAffineTransform(translationX: -canvas.width * (drift - 1) / 2,
                                               y: -canvas.height * (drift - 1) / 2))
            .transformed(by: CGAffineTransform(scaleX: drift, y: drift))
            .cropped(to: bounds)

        let zoom = 1.0 + 0.05 * progress
        let fadeIn = min(1, elapsed / 0.35)
        let fadeOut = min(1, max(0, (duration - elapsed) / 0.30))
        let opacity = min(fadeIn, fadeOut)
        let picture = CIImage(cgImage: still.foreground)
            .transformed(by: CGAffineTransform(translationX: -canvas.width * (zoom - 1) / 2,
                                               y: -canvas.height * (zoom - 1) / 2))
            .transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))
            .cropped(to: bounds)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
            ])
        return picture.composited(over: background)
    }

    private func cachedFrame(_ trackID: CMPersistentTrackID) -> CVPixelBuffer? {
        lastFrameLock.lock()
        defer { lastFrameLock.unlock() }
        return lastFrames[trackID]
    }

    private func rememberFrame(_ buffer: CVPixelBuffer, for trackID: CMPersistentTrackID) {
        lastFrameLock.lock()
        lastFrames[trackID] = buffer
        lastFrameLock.unlock()
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? AssemblyInstruction else {
                request.finish(with: NSError(domain: "Assembly", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法读取拼装画面。"]))
                return
            }
            let bounds = CGRect(origin: .zero, size: request.renderContext.size)
            var source = request.sourceFrame(byTrackID: instruction.trackID)
            if let source { rememberFrame(source, for: instruction.trackID) }
            else { source = cachedFrame(instruction.trackID) }
            guard let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "Assembly", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建导出画面。"]))
                return
            }
            var image: CIImage
            if let source {
                image = CIImage(cvPixelBuffer: source).transformed(by: instruction.transform)
            } else {
                // Nothing decoded yet: keep the export running with an empty frame.
                image = CIImage(color: .black)
            }
            image = image.composited(over: CIImage(color: .black).cropped(to: bounds))
            if let cutaway = instruction.cutaways.first(where: { $0.range.containsTime(request.compositionTime) }) {
                let overlay: CIImage
                switch cutaway.content {
                case .still(let still):
                    overlay = Self.stillFrame(still, at: request.compositionTime, range: cutaway.range, canvas: bounds.size)
                case .video(let id, let backdrop):
                    let frame = request.sourceFrame(byTrackID: id) ?? cachedFrame(id)
                    if let frame { rememberFrame(frame, for: id) }
                    let background = CIImage(cgImage: backdrop).cropped(to: bounds)
                    overlay = frame.map { CIImage(cvPixelBuffer: $0).transformed(by: cutaway.transform) }
                        .map { $0.composited(over: background) } ?? background
                }
                image = overlay.composited(over: image)
            }
            let time = request.compositionTime.seconds
            for overlay in instruction.overlays where time >= overlay.start && time < overlay.end {
                let text = CIImage(cgImage: overlay.image)
                    .transformed(by: CGAffineTransform(scaleX: overlay.frame.width / CGFloat(overlay.image.width), y: overlay.frame.height / CGFloat(overlay.image.height)))
                    .transformed(by: CGAffineTransform(translationX: overlay.frame.minX, y: overlay.frame.minY))
                image = text.composited(over: image)
            }
            context.render(image, to: output, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            request.finish(withComposedVideoFrame: output)
        }
    }
    func cancelAllPendingVideoCompositionRequests() {}
}
