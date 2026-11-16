import XCTest
@testable import MediaIdentifierCore

/// Which folder a "show me where this goes" click should open.
final class FolderRevealTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("mediafin-reveal-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    /// The case the button exists for: the destination folder is not there
    /// yet, because the rename has not happened. Opening the path itself
    /// would open nothing.
    func testAnUnmadeDestinationFallsBackToTheDeepestFolderThatExists() throws {
        let destination = root
            .appendingPathComponent("Fargo/Season 05/Fargo - S05E10.mkv")
        XCTAssertEqual(
            FolderReveal.nearestExistingDirectory(for: destination)?
                .standardizedFileURL.path,
            root.standardizedFileURL.path)
    }

    /// Half of it exists: then that half is the answer, not the root.
    func testItStopsAtTheDeepestFolderThatExists() throws {
        let series = root.appendingPathComponent("Fargo")
        try fm.createDirectory(at: series, withIntermediateDirectories: true)
        let destination = series
            .appendingPathComponent("Season 05/Fargo - S05E10.mkv")
        XCTAssertEqual(
            FolderReveal.nearestExistingDirectory(for: destination)?
                .standardizedFileURL.path,
            series.standardizedFileURL.path)
    }

    /// After the rename the whole path is there, and a file's own folder is
    /// what a file manager should open — not the file.
    func testAFileResolvesToTheFolderHoldingIt() throws {
        let folder = root.appendingPathComponent("Fargo/Season 05")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Fargo - S05E10.mkv")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(
            FolderReveal.nearestExistingDirectory(for: file)?
                .standardizedFileURL.path,
            folder.standardizedFileURL.path)
    }

    func testAFolderThatExistsIsItsOwnAnswer() throws {
        XCTAssertEqual(
            FolderReveal.nearestExistingDirectory(for: root)?
                .standardizedFileURL.path,
            root.standardizedFileURL.path)
    }

    /// Nothing of the path exists at all — a destination under a drive that
    /// is not mounted. The root is still a directory, so it answers rather
    /// than returning nothing and leaving the caller to guess.
    func testAPathWithNothingOnItFallsBackToTheRoot() {
        let nowhere = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/a/b.mkv")
        XCTAssertEqual(
            FolderReveal.nearestExistingDirectory(for: nowhere)?.path, "/")
    }

    /// It has to come back. A loop that never shortens the path would hang
    /// the window, which is worse than opening the wrong folder.
    func testItTerminatesOnTheRootItself() {
        XCTAssertEqual(
            FolderReveal.nearestExistingDirectory(for: URL(fileURLWithPath: "/"))?.path,
            "/")
    }
}
