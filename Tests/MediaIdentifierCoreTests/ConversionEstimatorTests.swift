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
}
