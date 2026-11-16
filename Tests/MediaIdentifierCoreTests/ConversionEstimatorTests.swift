import XCTest
@testable import MediaIdentifierCore

final class ConversionEstimatorTests: XCTestCase {
    func testCopyKeepsSize() {
        XCTAssertEqual(ConversionEstimator.sizeFraction(options: ConversionOptions(videoCodec: .copy)), 1.0)
    }

    func testH265ShrinksAtDefaultRF() {
        let f = ConversionEstimator.sizeFraction(options: ConversionOptions(videoCodec: .h265, quality: 22))
        XCTAssertLessThan(f, 1.0)
        XCTAssertGreaterThan(f, 0.0)
    }

    func testLowerRFIsLargerThanHigherRF() {
        let big = ConversionEstimator.sizeFraction(options: ConversionOptions(quality: 18))
        let small = ConversionEstimator.sizeFraction(options: ConversionOptions(quality: 28))
        XCTAssertGreaterThan(big, small)
    }

    func testDownscaleReducesFraction() {
        let full = ConversionEstimator.sizeFraction(options: ConversionOptions(quality: 22))
        let scaled = ConversionEstimator.sizeFraction(options: ConversionOptions(quality: 22, targetHeight: 720))
        XCTAssertLessThan(scaled, full)
    }

    func testAV1MoreEfficientThanH264() {
        let av1 = ConversionEstimator.sizeFraction(options: ConversionOptions(videoCodec: .av1, quality: 22))
        let h264 = ConversionEstimator.sizeFraction(options: ConversionOptions(videoCodec: .h264, quality: 22))
        XCTAssertLessThan(av1, h264)
    }

    func testQualityLabels() {
        XCTAssertEqual(ConversionEstimator.quality(options: ConversionOptions(quality: 16)).rank, 4)
        XCTAssertEqual(ConversionEstimator.quality(options: ConversionOptions(quality: 23)).rank, 2)
        XCTAssertEqual(ConversionEstimator.quality(options: ConversionOptions(quality: 30)).rank, 0)
        XCTAssertEqual(ConversionEstimator.quality(options: ConversionOptions(videoCodec: .copy)).rank, 4)
    }

    // MARK: The source height, which the window now names out loud

    /// The fault: the resolution setting looked inert.
    ///
    /// `sizeFraction` defaults to a 1080p source and the guard is
    /// `height < assumedSourceHeight`, so "keep the source resolution",
    /// 2160p, 1440p and 1080p ALL returned the same fraction — only 720p
    /// differed. The settings window printed that number, so a user with 4K
    /// files who chose 1080p was told the downscale saved nothing, when it
    /// saves three quarters.
    func testADownscaleFromFourKActuallySaysItSaves() {
        let keep = ConversionOptions(videoCodec: .h265, quality: 21)
        let downscaled = ConversionOptions(videoCodec: .h265, quality: 21,
                                           targetHeight: 1080)

        let keepFraction = ConversionEstimator.sizeFraction(
            options: keep, assumedSourceHeight: 2160)
        let downFraction = ConversionEstimator.sizeFraction(
            options: downscaled, assumedSourceHeight: 2160)

        // A quarter of the pixels, so about a quarter of the bytes.
        XCTAssertEqual(downFraction / keepFraction, 0.25, accuracy: 0.01,
                       "1080p from a 4K source should be about a quarter")
        XCTAssertLessThan(downFraction, keepFraction,
                          "the downscale has to show as a saving at all")
    }

    /// And the reason the window prints two numbers: the same choice means
    /// different things for different sources, and nothing can probe the
    /// source while the settings are open.
    func testTheSameTargetMeansDifferentThingsForDifferentSources() {
        let options = ConversionOptions(videoCodec: .h265, quality: 21,
                                        targetHeight: 1080)

        let fromNormal = ConversionEstimator.sizeFraction(
            options: options, assumedSourceHeight: 1080)
        let fromFourK = ConversionEstimator.sizeFraction(
            options: options, assumedSourceHeight: 2160)

        XCTAssertNotEqual(fromNormal, fromFourK, accuracy: 0.001,
                          "if these are equal the window has nothing to say")
    }

    /// Upscaling is not a saving, and must not be reported as one.
    ///
    /// This test used to assert the bug. Its name said "changes nothing"
    /// and its body asserted that 2160p-from-1080p equals keep-the-source,
    /// i.e. that an upscale IS reported as the same 38 % saving — directly
    /// against the sentence above it. The guard it was built on is gone.
    func testATargetAboveTheSourceIsNotReportedAsASaving() {
        let upscale = ConversionEstimator.sizeFraction(
            options: ConversionOptions(videoCodec: .h265, quality: 21,
                                       targetHeight: 2160),
            assumedSourceHeight: 1080)
        let keep = ConversionEstimator.sizeFraction(
            options: ConversionOptions(videoCodec: .h265, quality: 21),
            assumedSourceHeight: 1080)

        XCTAssertGreaterThan(upscale, keep,
                             "four times the pixels cannot be smaller than "
                                 + "leaving the resolution alone")
        XCTAssertGreaterThan(upscale, 1.0,
                             "an upscale writes a bigger file, so the "
                                 + "estimate has to read above 100 %")
    }

    /// And the window must have two different numbers to print for it.
    ///
    /// The line collapses to one number when both probes agree, which is
    /// the window's way of saying "this choice is source-independent".
    /// That was true for "keep the source resolution" and false for 4K,
    /// where it hid the upscale.
    func testFourKIsNotSourceIndependent() {
        let options = ConversionOptions(videoCodec: .h265, quality: 21,
                                        targetHeight: 2160)

        XCTAssertNotEqual(
            ConversionEstimator.sizeFraction(options: options,
                                             assumedSourceHeight: 1080),
            ConversionEstimator.sizeFraction(options: options,
                                             assumedSourceHeight: 2160),
            accuracy: 0.001,
            "if these are equal the window prints one number for 4K and "
                + "the upscale is invisible again")
    }

    /// The words beside the number. "21" means nothing on its own, and the
    /// labels were German-only until the window had a place to put them.
    func testEveryQualityBandHasItsOwnWords() {
        let labels = [16, 20, 23, 26, 30].map {
            ConversionEstimator.quality(options: ConversionOptions(quality: $0)).label
        }
        XCTAssertEqual(Set(labels).count, labels.count, "duplicate in \(labels)")
        XCTAssertFalse(labels.contains(where: \.isEmpty))
        // Through the settings type as well, since that is the route the
        // window takes.
        var settings = WebConversionSettings()
        settings.quality = 21
        XCTAssertFalse(settings.qualityDescription.isEmpty)
    }
}
