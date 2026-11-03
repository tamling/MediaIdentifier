import XCTest
@testable import MediaIdentifierCore

/// Conversion settings reach FFmpeg as command-line arguments, so a value that
/// slips past validation does not produce a wrong picture — it produces a
/// failed encode with a message the user cannot act on. These tests cover the
/// two ways a value used to get in: through the settings file, which bypassed
/// the initialiser's clamping, and through a form field that was not a number.
final class ConversionSettingsValidationTests: XCTestCase {

    private func decode(_ json: String) throws -> WebConversionSettings {
        try JSONDecoder().decode(WebConversionSettings.self, from: Data(json.utf8))
    }

    // MARK: Loading from disk

    /// The synthesised Codable conformance assigned stored properties
    /// directly, so the clamp in the initialiser never ran for a file.
    func testQualityFromTheFileIsClamped() throws {
        XCTAssertEqual(try decode(#"{"quality":999}"#).quality, 51)
        XCTAssertEqual(try decode(#"{"quality":-5}"#).quality, 0)
        XCTAssertEqual(try decode(#"{"quality":21}"#).quality, 21)
    }

    func testImplausibleHeightFromTheFileBecomesKeepSourceResolution() throws {
        XCTAssertNil(try decode(#"{"targetHeight":99999}"#).targetHeight)
        XCTAssertNil(try decode(#"{"targetHeight":1}"#).targetHeight)
        XCTAssertEqual(try decode(#"{"targetHeight":1080}"#).targetHeight, 1080)
    }

    func testADamagedFieldFallsBackWithoutLosingTheOthers() throws {
        let settings = try decode(#"{"quality":"loud","preset":"slow","targetHeight":720}"#)
        XCTAssertEqual(settings.quality, WebConversionSettings().quality)
        XCTAssertEqual(settings.preset, .slow)
        XCTAssertEqual(settings.targetHeight, 720)
    }

    func testRoundTripIsLossless() throws {
        let original = WebConversionSettings(videoCodec: .av1, quality: 30, preset: .fast,
                                             targetHeight: 1080, audioMode: .opus,
                                             stripSubtitles: true, ffmpegPath: "/usr/bin/ffmpeg")
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(WebConversionSettings.self, from: data), original)
    }

    /// The transient "that was not a number" marker describes one submission,
    /// so it must not survive a save and come back as a permanent complaint.
    func testTheUnreadableMarkerIsNeverWrittenToDisk() throws {
        var settings = WebConversionSettings()
        settings.targetHeightWasUnreadable = true

        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        XCTAssertFalse(json.contains("targetHeightWasUnreadable"))

        let reloaded = try decode(json)
        XCTAssertFalse(reloaded.targetHeightWasUnreadable)
        XCTAssertTrue(reloaded.problems().isEmpty)
    }

    // MARK: Submitted from the form

    func testEmptyHeightMeansKeepTheSourceResolution() {
        var current = WebConversionSettings()
        current.targetHeight = 720
        let settings = WebConversionSettings.fromForm(["targetHeight": " "], current: current)
        XCTAssertNil(settings.targetHeight)
        XCTAssertTrue(settings.problems().isEmpty)
    }

    /// Used to be accepted silently as "keep the source resolution", so the
    /// save succeeded and no downscaling ever happened.
    func testANonNumericHeightIsReportedRatherThanIgnored() {
        var current = WebConversionSettings()
        current.targetHeight = 720
        let settings = WebConversionSettings.fromForm(["targetHeight": "1080p"], current: current)

        XCTAssertTrue(settings.targetHeightWasUnreadable)
        XCTAssertEqual(settings.problems().map(\.field), ["targetHeight"])
        XCTAssertEqual(settings.targetHeight, 720,
                       "the previous value should stand until a valid one replaces it")
    }

    func testAValidHeightClearsAnEarlierComplaint() {
        var current = WebConversionSettings()
        current.targetHeightWasUnreadable = true
        let settings = WebConversionSettings.fromForm(["targetHeight": "1080"], current: current)

        XCTAssertFalse(settings.targetHeightWasUnreadable)
        XCTAssertEqual(settings.targetHeight, 1080)
        XCTAssertTrue(settings.problems().isEmpty)
    }

    /// Direct assignment skips the initialiser, which is how the form path
    /// works, so out-of-range values still have to be caught by problems().
    func testOutOfRangeHeightFromTheFormIsStillReported() {
        let settings = WebConversionSettings.fromForm(["targetHeight": "40000"],
                                                      current: WebConversionSettings())
        XCTAssertEqual(settings.problems().map(\.field), ["targetHeight"])
    }

    func testQualityFromTheFormIsClamped() {
        let high = WebConversionSettings.fromForm(["quality": "999"],
                                                  current: WebConversionSettings())
        XCTAssertEqual(high.quality, 51)
        let low = WebConversionSettings.fromForm(["quality": "-3"],
                                                 current: WebConversionSettings())
        XCTAssertEqual(low.quality, 0)
    }
}
