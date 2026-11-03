import XCTest
@testable import MediaIdentifierCore

/// Tests FFmpeg discovery. The converter used to default to a Homebrew-only
/// path, so FFmpeg could never be found on Linux or an Intel Mac.
final class FFmpegLocatorTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ffmpeg-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    private func makeExecutable(_ name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return url.path
    }

    func testFindsNothingWhenNoCandidateExists() {
        let missing = [directory.appendingPathComponent("nope").path]
        XCTAssertNil(FFmpegLocator.locate(candidates: missing))
    }

    func testPrefersTheEarlierCandidate() throws {
        let first = try makeExecutable("first")
        let second = try makeExecutable("second")
        XCTAssertEqual(FFmpegLocator.locate(candidates: [first, second]), first)
        XCTAssertEqual(FFmpegLocator.locate(candidates: [second, first]), second)
    }

    func testSkipsAFileThatIsNotExecutable() throws {
        let plain = directory.appendingPathComponent("plain")
        try Data("not executable".utf8).write(to: plain)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: plain.path)
        let real = try makeExecutable("real")
        XCTAssertEqual(FFmpegLocator.locate(candidates: [plain.path, real]), real)
    }

    /// Linux comes first, because that is where a media server usually runs
    /// and where the old default could never work.
    func testCandidateListCoversTheUsualInstalls() {
        XCTAssertEqual(FFmpegLocator.candidatePaths.first, "/usr/bin/ffmpeg")
        XCTAssertTrue(FFmpegLocator.candidatePaths.contains("/usr/local/bin/ffmpeg"))
        XCTAssertTrue(FFmpegLocator.candidatePaths.contains("/opt/homebrew/bin/ffmpeg"))
        XCTAssertTrue(FFmpegLocator.candidatePaths.allSatisfy { $0.hasPrefix("/") },
                      "absolute paths only, so PATH cannot redirect the converter")
    }

    func testDefaultPathIsNeverEmpty() {
        XCTAssertFalse(FFmpegLocator.defaultPath.isEmpty)
        XCTAssertTrue(FFmpegLocator.defaultPath.hasPrefix("/"))
    }

    func testAConfiguredPathWins() throws {
        let custom = try makeExecutable("my-ffmpeg")
        XCTAssertEqual(FFmpegLocator.resolve(configured: custom), custom)
        XCTAssertEqual(FFmpegLocator.resolve(configured: "  \(custom)  "), custom)
    }

    func testABlankConfiguredPathFallsBack() {
        XCTAssertEqual(FFmpegLocator.resolve(configured: ""), FFmpegLocator.defaultPath)
        XCTAssertEqual(FFmpegLocator.resolve(configured: "   "), FFmpegLocator.defaultPath)
        XCTAssertEqual(FFmpegLocator.resolve(configured: nil), FFmpegLocator.defaultPath)
    }

    func testTheNotFoundMessageNamesBothPlatforms() {
        let message = FFmpegConverter.ConverterError.ffmpegNotFound.errorDescription ?? ""
        XCTAssertTrue(message.contains("apt install ffmpeg"), message)
        XCTAssertTrue(message.contains("brew install ffmpeg"), message)
    }
}
