import XCTest
@testable import MediaIdentifierCore

final class ConversionTests: XCTestCase {
    private let input = URL(fileURLWithPath: "/tmp/in.mkv")
    private let output = URL(fileURLWithPath: "/tmp/out.mkv")

    private func args(_ options: ConversionOptions) -> [String] {
        FFmpegArgumentBuilder.arguments(input: input, output: output, options: options)
    }

    private func adjacent(_ a: [String], _ x: String, _ y: String) -> Bool {
        for i in a.indices.dropLast() where a[i] == x && a[i+1] == y { return true }
        return false
    }

    // FR-1 — default path: software x265, Constant Quality, slow, 10-bit, passthru.
    func testDefaultIsConstantQualityX265() {
        let a = args(ConversionOptions())
        XCTAssertTrue(a.contains("libx265"))
        XCTAssertTrue(adjacent(a, "-crf", "21"))
        XCTAssertTrue(adjacent(a, "-preset", "slow"))
        XCTAssertTrue(adjacent(a, "-pix_fmt", "yuv420p10le"))   // main10
        XCTAssertTrue(adjacent(a, "-tag:v", "hvc1"))
        XCTAssertTrue(adjacent(a, "-c:a", "copy"))              // Auto-Passthru
    }

    // FR-1 — Constant Quality must never use two-pass / ABR.
    func testNoTwoPassOrAverageBitrate() {
        let a = args(ConversionOptions())
        XCTAssertFalse(a.contains("-b:v"))
        XCTAssertFalse(a.contains("-pass"))
    }

    // FR-1 configurable RF + 8-bit.
    func testConfigurableQualityAndBitDepth() {
        let a = args(ConversionOptions(quality: 24, preset: .slower, tenBit: false))
        XCTAssertTrue(adjacent(a, "-crf", "24"))
        XCTAssertTrue(adjacent(a, "-preset", "slower"))
        XCTAssertTrue(adjacent(a, "-pix_fmt", "yuv420p"))
    }

    // FR17 — VideoToolbox hardware path.
    func testHardwareHEVC() {
        let a = args(ConversionOptions(useHardwareAcceleration: true))
        XCTAssertTrue(a.contains("hevc_videotoolbox"))
        XCTAssertTrue(a.contains("-q:v"))
        XCTAssertFalse(a.contains("libx265"))
    }

    // FR-1 — optional SVT-AV1 with numeric preset.
    func testAV1() {
        let a = args(ConversionOptions(videoCodec: .av1, preset: .slow))
        XCTAssertTrue(a.contains("libsvtav1"))
        XCTAssertTrue(adjacent(a, "-crf", "21"))
        XCTAssertTrue(adjacent(a, "-preset", "4"))  // slow -> SVT level 4
    }

    // FR-1 — efficient audio (Opus) and FR16 stream pruning + scaling.
    func testOpusAudioScaleAndPrune() {
        let a = args(ConversionOptions(
            targetHeight: 720, audioMode: .opus, audioBitrate: 128,
            keepOnlyFirstAudio: true, stripSubtitles: true
        ))
        XCTAssertTrue(a.contains("libopus"))
        XCTAssertTrue(adjacent(a, "-b:a", "128k"))
        XCTAssertTrue(adjacent(a, "-vf", "scale=-2:720"))
        XCTAssertTrue(a.contains("-sn"))
        XCTAssertTrue(adjacent(a, "-map", "0:a:0?"))
    }

    func testCopyVideo() {
        let a = args(ConversionOptions(videoCodec: .copy))
        XCTAssertTrue(adjacent(a, "-c:v", "copy"))
        XCTAssertEqual(a.last, "/tmp/out.mkv")
    }

    // FFmpeg progress: Duration line is parsed into seconds.
    func testParseDuration() {
        XCTAssertEqual(FFmpegConverter.parseDuration("  Duration: 01:02:03.50, start: 0"), 3723.5)
        XCTAssertEqual(FFmpegConverter.parseDuration("Duration: 00:00:42.00,"), 42.0)
        XCTAssertNil(FFmpegConverter.parseDuration("no duration here"))
    }

    func testH264HardwareAndSoftwarePaths() {
        XCTAssertTrue(args(ConversionOptions(videoCodec: .h264, useHardwareAcceleration: true))
            .contains("h264_videotoolbox"))
        XCTAssertTrue(args(ConversionOptions(videoCodec: .h264, useHardwareAcceleration: false))
            .contains("libx264"))
    }
}
