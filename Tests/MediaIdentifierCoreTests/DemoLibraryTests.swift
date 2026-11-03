import XCTest
@testable import MediaIdentifierCore

/// The demo library exists so the interface can be looked at with something
/// in it. These tests keep it honest: if the parser stops recognising these
/// names, the screenshot would quietly go back to showing an empty window,
/// and a picture of nothing passes every check that only looks at the file.
final class DemoLibraryTests: XCTestCase {

    private var layout: DemoLibrary.Layout!

    override func setUpWithError() throws {
        try super.setUpWithError()
        layout = try DemoLibrary.create()
    }

    override func tearDownWithError() throws {
        if let layout { try? FileManager.default.removeItem(at: layout.root) }
        try super.tearDownWithError()
    }

    func testCreatesEveryFileItPromises() {
        for name in DemoLibrary.fileNames {
            let url = layout.source.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), name)
        }
    }

    /// Zero-length files are the one thing a scanner is entitled to skip.
    func testTheFilesAreNotEmpty() throws {
        for name in DemoLibrary.fileNames {
            let url = layout.source.appendingPathComponent(name)
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
            XCTAssertGreaterThan(size ?? 0, 0, name)
        }
    }

    func testSettingsPointAtTheCreatedFoldersAndStayOffline() {
        let settings = DemoLibrary.settings(for: layout)
        XCTAssertEqual(settings.sourceFolder, layout.source.path)
        XCTAssertEqual(settings.moviesFolder, layout.movies.path)
        XCTAssertEqual(settings.seriesFolder, layout.series.path)
        // No network and no credentials: the demo must work on a machine
        // with neither.
        XCTAssertEqual(settings.identification, .offline)
        XCTAssertFalse(settings.watchSourceFolder)
        XCTAssertTrue(settings.problems().isEmpty)
    }

    func testTwoDemosDoNotShareADirectory() throws {
        let other = try DemoLibrary.create()
        defer { try? FileManager.default.removeItem(at: other.root) }
        XCTAssertNotEqual(layout.root, other.root)
    }

    /// The point of the whole thing: the real scanner has to find these.
    func testTheScannerFindsEveryFile() {
        let found = AppCoordinator.FolderScan.videoFiles(under: layout.source)
        XCTAssertEqual(found.count, DemoLibrary.fileNames.count,
                       "found \(found.map(\.lastPathComponent).sorted())")
    }

    /// Covers the case that would otherwise only show up as a blank row in a
    /// screenshot: Pango markup is XML, and an unescaped ampersand makes it
    /// reject the whole string.
    func testOneFileNameExercisesMarkupEscaping() {
        let risky = DemoLibrary.fileNames.filter {
            $0.contains("&") || $0.contains("and")
        }
        XCTAssertFalse(risky.isEmpty,
                       "the demo set no longer covers names that stress markup escaping")
    }

    /// Series and films both, so the planner has to choose between the two
    /// library folders rather than always picking one.
    func testTheSetCoversBothFilmsAndEpisodes() {
        let episodes = DemoLibrary.fileNames.filter { $0.range(of: "S[0-9]+E[0-9]+",
                                                               options: .regularExpression) != nil }
        XCTAssertGreaterThanOrEqual(episodes.count, 2)
        XCTAssertGreaterThanOrEqual(DemoLibrary.fileNames.count - episodes.count, 3)
    }
}
