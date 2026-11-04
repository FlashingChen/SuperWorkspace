import AVFoundation
import CoreImage

struct SubtitleOverlay: @unchecked Sendable {
    let start: Double
    let end: Double
    let image: CGImage
    let frame: CGRect
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
    init(range: CMTimeRange, trackID: CMPersistentTrackID, transform: CGAffineTransform, overlays: [SubtitleOverlay]) {
        timeRange = range
        self.trackID = trackID
        self.transform = transform
        self.overlays = overlays
        requiredSourceTrackIDs = [NSNumber(value: trackID)]
    }
}

final class AssemblyCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false])
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    }
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? AssemblyInstruction,
                  let input = request.sourceFrame(byTrackID: instruction.trackID),
                  let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: NSError(domain: "Assembly", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法读取拼装画面。 "]))
                return
            }
            let bounds = CGRect(origin: .zero, size: request.renderContext.size)
            var image = CIImage(cvPixelBuffer: input).transformed(by: instruction.transform)
                .composited(over: CIImage(color: .black).cropped(to: bounds))
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
