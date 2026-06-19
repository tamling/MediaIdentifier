import XCTest
@testable import MediaIdentifierCore

final class ConversionTests: XCTestCase {

    // FR16 / FR17 — H.265 with VideoToolbox hardware acceleration.
    func testHardwareHEVCArguments() {
        let input = URL(fileURLWithPath: "/tmp/in.mkv")
        let output = URL(fileURLWithPath: "/tmp/out.mkv")
        let options = ConversionOptions(videoCodec: .h265, useHardwareAcceleration: true)
        let args = FFmpegArgumentBuilder.arguments(input: input, output: output, options: options)

        XCTAssertTrue(args.contains("hevc_videotoolbox"))
        XCTAssertTrue(args.contains("/tmp/in.mkv"))
        XCTAssertEqual(args.last, "/tmp/out.mkv")
    }

    // FR16 — software fallback, scaling and stream pruning.
    func testSoftwareScaleAndStrip() {
        let input = URL(fileURLWithPath: "/tmp/in.mkv")
        let output = URL(fileURLWithPath: "/tmp/out.mkv")
        let options = ConversionOptions(
            videoCodec: .h265,
            useHardwareAcceleration: false,
            targetHeight: 720,
            audioCodec: "aac",
            keepOnlyFirstAudio: true,
            stripSubtitles: true
        )
        let args = FFmpegArgumentBuilder.arguments(input: input, output: output, options: options)

        XCTAssertTrue(args.contains("libx265"))
        XCTAssertTrue(args.contains("scale=-2:720"))
        XCTAssertTrue(args.contains("-sn"))
        XCTAssertTrue(args.contains("aac"))
        XCTAssertTrue(zipContains(args, "-map", "0:a:0?"))
    }

    private func zipContains(_ array: [String], _ a: String, _ b: String) -> Bool {
        for i in array.indices.dropLast() where array[i] == a && array[i + 1] == b {
            return true
        }
        return false
    }
}
