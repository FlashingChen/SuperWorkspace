import XCTest
import AVFoundation
import AudioWriterBridge

final class AudioWriterBridgeTests: XCTestCase {
    private func format() throws -> CMAudioFormatDescription {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var result: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &result
        ), noErr)
        return try XCTUnwrap(result)
    }

    func testInvalidSettingsThrowInsteadOfAborting() throws {
        let hint = try format()
        var error: NSError?
        XCTAssertNil(makeAudioWriterInput(settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: -1,
            AVNumberOfChannelsKey: 0,
        ], formatHint: hint, error: &error))
        XCTAssertNotNil(error)
    }

    func testSupportedMonoSettingsCreateInput() throws {
        let input = try XCTUnwrap(makeAudioWriterInput(settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ], formatHint: format(), error: nil))
        XCTAssertEqual(input.mediaType, .audio)
    }
}
