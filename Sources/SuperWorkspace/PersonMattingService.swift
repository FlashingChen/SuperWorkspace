import AVFoundation
import CoreImage
import Foundation
import Vision

/// On-demand local macOS Vision person matting (`VNGeneratePersonSegmentationRequest`).
/// Generates a grayscale luma matte video (`white = person foreground`, `black = background`)
/// for a requested `[start, end]` time slice of a source video so the host Remotion adapter
/// (`sw-motion.mjs`) can composite text-behind-person and cutout-presenter-over-stage shots
/// without matting the entire recording upfront.
enum PersonMattingService {
    enum Quality: String, Sendable {
        case balanced
        case accurate

        var vnLevel: VNGeneratePersonSegmentationRequest.QualityLevel {
            switch self {
            case .balanced: return .balanced
            case .accurate: return .accurate
            }
        }
    }

    struct Result: Codable, Sendable, Equatable {
        let outputPath: String
        let width: Int
        let height: Int
        let frames: Int
        let start: Double
        let end: Double
        let elapsedSeconds: Double
    }

    enum MattingError: LocalizedError {
        case invalidRange(Double, Double)
        case unreadableVideo(String)
        case writerSetupFailed(String)
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidRange(let s, let e):
                return "抠像时间范围无效（start=\(s), end=\(e)）。"
            case .unreadableVideo(let path):
                return "无法读取待抠像视频：\(path)"
            case .writerSetupFailed(let reason):
                return "无法初始化抠像遮罩写入器：\(reason)"
            case .encodingFailed(let reason):
                return "抠像遮罩编码失败：\(reason)"
            }
        }
    }

    /// Generates a grayscale alpha matte video for `sourceURL` within `[start, end]`.
    static func generateMask(
        sourceURL: URL,
        start: Double,
        end: Double,
        outputURL: URL,
        quality: Quality = .balanced
    ) async throws -> Result {
        guard start.isFinite, end.isFinite, start >= 0, end > start else {
            throw MattingError.invalidRange(start, end)
        }
        let startedAt = Date()
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MattingError.unreadableVideo(sourceURL.path)
        }
        let (naturalSize, preferredTransform, duration, nominalFPS) = try await track.load(
            .naturalSize, .preferredTransform, .timeRange, .nominalFrameRate
        )
        let transformed = naturalSize.applying(preferredTransform)
        let width = max(2, Int(abs(transformed.width).rounded()) & ~1)
        let height = max(2, Int(abs(transformed.height).rounded()) & ~1)
        let clampedStart = min(start, max(0, duration.end.seconds))
        let clampedEnd = min(end, duration.end.seconds)
        guard clampedEnd > clampedStart + 1.0 / 120.0 else {
            throw MattingError.invalidRange(clampedStart, clampedEnd)
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: clampedStart, preferredTimescale: 600),
            end: CMTime(seconds: clampedEnd, preferredTimescale: 600)
        )
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw MattingError.unreadableVideo(sourceURL.path)
        }
        reader.add(readerOutput)

        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let bitrate = max(2_000_000, width * height * 4)
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: max(24, Int(nominalFPS.rounded())),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        guard writer.canAdd(writerInput) else {
            throw MattingError.writerSetupFailed("AVAssetWriter cannot add video input")
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw MattingError.unreadableVideo(reader.error?.localizedDescription ?? sourceURL.path)
        }
        guard writer.startWriting() else {
            throw MattingError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality.vnLevel
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let startTime = CMTime(seconds: clampedStart, preferredTimescale: 600)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var frameCount = 0
        var lastPTS = CMTime.invalid

        func cleanupAfterFailure() {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
        }

        do {
            while let sample = readerOutput.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let srcBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                var pts = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), startTime)
                if pts < .zero { pts = .zero }
                if lastPTS.isValid, pts <= lastPTS {
                    pts = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 600))
                }

                let outBuffer: CVPixelBuffer = try autoreleasepool {
                    let handler = VNImageRequestHandler(cvPixelBuffer: srcBuffer, options: [:])
                    try handler.perform([request])

                    guard let pool = adaptor.pixelBufferPool else {
                        throw MattingError.encodingFailed("Missing pixelBufferPool")
                    }
                    var outBufferOpt: CVPixelBuffer?
                    let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outBufferOpt)
                    guard status == kCVReturnSuccess, let buffer = outBufferOpt else {
                        throw MattingError.encodingFailed("Failed to allocate pixel buffer (\(status))")
                    }

                    if let maskBuffer = request.results?.first?.pixelBuffer {
                        var maskImage = CIImage(cvPixelBuffer: maskBuffer)
                        if !preferredTransform.isIdentity {
                            let rot = CGAffineTransform(
                                a: preferredTransform.a,
                                b: -preferredTransform.b,
                                c: -preferredTransform.c,
                                d: preferredTransform.d,
                                tx: 0,
                                ty: 0
                            )
                            let oriented = maskImage.transformed(by: rot)
                            maskImage = oriented.transformed(
                                by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY)
                            )
                        }
                        let scaleX = CGFloat(width) / max(1, maskImage.extent.width)
                        let scaleY = CGFloat(height) / max(1, maskImage.extent.height)
                        maskImage = maskImage
                            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                            .clampedToExtent()
                            .applyingGaussianBlur(sigma: 1.0)
                            .cropped(to: bounds)
                        ciContext.render(maskImage, to: buffer, bounds: bounds, colorSpace: colorSpace)
                    } else {
                        let black = CIImage(color: .black).cropped(to: bounds)
                        ciContext.render(black, to: buffer, bounds: bounds, colorSpace: colorSpace)
                    }
                    return buffer
                }

                while !writerInput.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard adaptor.append(outBuffer, withPresentationTime: pts) else {
                    throw MattingError.encodingFailed(writer.error?.localizedDescription ?? "append failed")
                }
                lastPTS = pts
                frameCount += 1
            }

            if reader.status == .failed {
                throw MattingError.unreadableVideo(reader.error?.localizedDescription ?? sourceURL.path)
            }
            guard frameCount > 0 else {
                throw MattingError.encodingFailed("No video frames decoded in [\(clampedStart), \(clampedEnd)]")
            }
        } catch {
            cleanupAfterFailure()
            throw error
        }

        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw MattingError.encodingFailed(writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)")
        }
        let elapsed = (Date().timeIntervalSince(startedAt) * 10).rounded() / 10
        return Result(
            outputPath: outputURL.path,
            width: width,
            height: height,
            frames: frameCount,
            start: clampedStart,
            end: clampedEnd,
            elapsedSeconds: elapsed
        )
    }
}
