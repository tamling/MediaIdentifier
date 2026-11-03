import XCTest
@testable import MediaIdentifierCore

/// Tests the conversion output rules. These decide what happens to someone's
/// media, so they are pinned down rather than left to the UI.
final class ConversionPlanTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conversion-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func source(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    private func touch(_ url: URL) throws {
        try Data("x".utf8).write(to: url)
    }

    // MARK: Where the output goes

    func testOutputGoesBesideTheOriginalWithACodecMarker() {
        let destination = ConversionOutput.destination(
            for: source("The Matrix (1999).mkv"),
            options: ConversionOptions(videoCodec: .h265)
        )
        XCTAssertEqual(destination.deletingLastPathComponent().path, directory.path,
                       "the output must sit beside the original")
        XCTAssertEqual(destination.lastPathComponent, "The Matrix (1999).x265.mkv")
    }

    func testTheMarkerNamesTheCodec() {
        func name(_ codec: ConversionOptions.VideoCodec) -> String {
            ConversionOutput.destination(for: source("A.mkv"),
                                         options: ConversionOptions(videoCodec: codec))
                .lastPathComponent
        }
        XCTAssertEqual(name(.h265), "A.x265.mkv")
        XCTAssertEqual(name(.h264), "A.x264.mkv")
        XCTAssertEqual(name(.av1), "A.av1.mkv")
        XCTAssertEqual(name(.copy), "A.remux.mkv")
    }

    /// Matroska holds anything the source did, so a conversion cannot fail
    /// because the container will not carry a stream.
    func testOutputIsAlwaysMatroska() {
        for extension_ in ["avi", "mp4", "wmv", "ts"] {
            let destination = ConversionOutput.destination(
                for: source("A.\(extension_)"), options: ConversionOptions()
            )
            XCTAssertEqual(destination.pathExtension, "mkv")
        }
    }

    /// The original must never be the destination: nothing is overwritten.
    func testTheOriginalIsNeverTheDestination() throws {
        let original = source("A.mkv")
        try touch(original)
        let destination = ConversionOutput.destination(for: original,
                                                       options: ConversionOptions())
        XCTAssertNotEqual(destination.path, original.path)
    }

    func testAnExistingOutputIsNotOverwritten() throws {
        let original = source("A.mkv")
        try touch(source("A.x265.mkv"))
        let second = ConversionOutput.destination(for: original, options: ConversionOptions())
        XCTAssertEqual(second.lastPathComponent, "A.x265 (2).mkv")

        try touch(second)
        let third = ConversionOutput.destination(for: original, options: ConversionOptions())
        XCTAssertEqual(third.lastPathComponent, "A.x265 (3).mkv")
    }

    // MARK: Not re-encoding our own output

    func testOwnOutputIsRecognised() {
        XCTAssertTrue(ConversionOutput.isConvertedOutput(source("A.x265.mkv")))
        XCTAssertTrue(ConversionOutput.isConvertedOutput(source("A.av1.mkv")))
        XCTAssertTrue(ConversionOutput.isConvertedOutput(source("A.x265 (2).mkv")))
        XCTAssertFalse(ConversionOutput.isConvertedOutput(source("A.mkv")))
        XCTAssertFalse(ConversionOutput.isConvertedOutput(source("The Matrix (1999).mkv")))
    }

    /// A release name that merely mentions x265 is not our output.
    func testAReleaseNameMentioningTheCodecIsNotMistakenForOurOutput() {
        XCTAssertFalse(ConversionOutput.isConvertedOutput(
            source("The.Matrix.1999.1080p.BluRay.x265-GRP.mkv")
        ))
    }

    // MARK: Settings

    func testConversionDefaultsFavourQualityPerByte() {
        let settings = WebConversionSettings()
        XCTAssertEqual(settings.videoCodec, .h265)
        XCTAssertEqual(settings.preset, .slow)
        XCTAssertEqual(settings.audioMode, .passthrough, "audio is kept untouched by default")
        XCTAssertNil(settings.targetHeight, "the source resolution is kept by default")
        XCTAssertFalse(settings.stripSubtitles)
    }

    func testQualityIsClamped() {
        XCTAssertEqual(WebConversionSettings(quality: -5).quality, 0)
        XCTAssertEqual(WebConversionSettings(quality: 99).quality, 51)
    }

    func testFormDecoding() {
        let settings = WebConversionSettings.fromForm([
            "videoCodec": "av1", "quality": "26", "preset": "veryslow",
            "targetHeight": "1080", "audioMode": "opus",
            "conversionFormPresent": "1", "stripSubtitles": "1",
            "ffmpegPath": " /usr/bin/ffmpeg ",
        ], current: WebConversionSettings())
        XCTAssertEqual(settings.videoCodec, .av1)
        XCTAssertEqual(settings.quality, 26)
        XCTAssertEqual(settings.preset, .veryslow)
        XCTAssertEqual(settings.targetHeight, 1080)
        XCTAssertEqual(settings.audioMode, .opus)
        XCTAssertTrue(settings.stripSubtitles)
        XCTAssertEqual(settings.ffmpegPath, "/usr/bin/ffmpeg")
    }

    func testAnEmptyHeightMeansKeepTheSourceResolution() {
        var current = WebConversionSettings()
        current.targetHeight = 720
        let settings = WebConversionSettings.fromForm(["targetHeight": ""], current: current)
        XCTAssertNil(settings.targetHeight)
    }

    func testUncheckedSubtitleBoxIsDistinguishedFromAbsentForm() {
        var current = WebConversionSettings()
        current.stripSubtitles = true
        XCTAssertFalse(
            WebConversionSettings.fromForm(["conversionFormPresent": "1"], current: current)
                .stripSubtitles
        )
        XCTAssertTrue(
            WebConversionSettings.fromForm([:], current: current).stripSubtitles,
            "a form that does not carry the field must not change it"
        )
    }

    func testValidation() {
        var settings = WebConversionSettings()
        XCTAssertTrue(settings.problems().isEmpty)

        settings.targetHeight = 10
        XCTAssertEqual(settings.problems().first?.field, "targetHeight")

        settings = WebConversionSettings(ffmpegPath: "ffmpeg")
        XCTAssertEqual(settings.problems().first?.field, "ffmpegPath")
        XCTAssertTrue(WebConversionSettings(ffmpegPath: "/usr/bin/ffmpeg").problems().isEmpty)
    }

    func testSizeEstimateIsReported() {
        let h265 = WebConversionSettings(videoCodec: .h265, quality: 21)
        let h264 = WebConversionSettings(videoCodec: .h264, quality: 21)
        XCTAssertLessThan(h265.estimatedSizePercent, h264.estimatedSizePercent,
                          "H.265 should be estimated smaller than H.264")
        XCTAssertGreaterThan(h265.estimatedSizePercent, 0)
    }

    // MARK: Candidates

    func testCandidateShowsAReadableSize() {
        let candidate = ConversionCandidate(source: source("A.mkv"),
                                            byteSize: 4_300_000_000)
        XCTAssertEqual(candidate.fileName, "A.mkv")
        XCTAssertTrue(candidate.readableSize.contains("GB"), candidate.readableSize)
    }

    // MARK: Settings file compatibility

    /// A settings file written before conversion settings existed must still
    /// load, rather than throwing and resetting everything to defaults.
    func testOlderSettingsFileStillLoads() throws {
        let json = """
        {"sourceFolder":"/mnt/downloads","moviesFolder":"/mnt/Movies",
         "seriesFolder":"","identification":"local-llm","localLLMBaseURL":"http://host:1234",
         "localLLMModel":"m","jellyfinBaseURL":"","conflictPolicy":"rename",
         "watchSourceFolder":true}
        """
        let settings = try JSONDecoder().decode(WebSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.sourceFolder, "/mnt/downloads")
        XCTAssertEqual(settings.identification, .localLLM)
        XCTAssertTrue(settings.watchSourceFolder)
        XCTAssertEqual(settings.conversion, WebConversionSettings(),
                       "the new field falls back to its defaults")
    }

    func testAFileMissingMostFieldsStillLoads() throws {
        let settings = try JSONDecoder().decode(WebSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, WebSettings())
    }
}
