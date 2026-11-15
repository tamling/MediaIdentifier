import XCTest
@testable import MediaIdentifierCore

/// A title that is not empty and sanitises to nothing.
///
/// Two separate faults met here. The namer guarded `parsed.title.isEmpty`
/// and not "sanitises to empty" — and "?" and ":" both do, as does any title
/// made only of the characters this program strips. And the planner built
/// companion moves from the namer's RAW path while the item stored the
/// sanitised one, so whenever the two differed the film and its subtitle
/// were planned into two different folders.
///
/// Together: `?.2019.1080p.mkv` with a subtitle beside it produced two
/// sibling folders that look identical in a file manager, the film in one
/// and the subtitle in the other, and the preview row showed only the
/// film's path. A local model answering `{"title": ":"}` does the same to an
/// ordinary film, since the only check on its answer is "not empty".
final class NamelessTitleTests: XCTestCase {

    private var root: URL!
    private var source: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        Text.language = .german
        root = fm.temporaryDirectory
            .appendingPathComponent("mediafin-nameless-\(UUID().uuidString)")
        source = root.appendingPathComponent("Downloads")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ name: String) throws -> URL {
        let url = source.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    // MARK: The fallback

    func testATitleThatSanitisesToNothingFallsBackToTheFilesOwnName() {
        let parsed = ParsedRelease(originalFileName: "Tenet.2020.1080p.mkv",
                                   title: "?", year: 2020, kind: .movie)
        let path = JellyfinNamer().relativePath(for: parsed, fileExtension: "mkv")
        XCTAssertFalse(path.hasPrefix(" "), path)
        XCTAssertTrue(path.contains("Tenet.2020.1080p"),
                      "the film lost its name altogether: \(path)")
    }

    /// With no year either, the relative path used to lose its only
    /// component — so the destination WAS the library root, and the move
    /// onto a directory failed.
    func testATitleThatSanitisesToNothingAndNoYearStillHasAPath() {
        let parsed = ParsedRelease(originalFileName: "???.mkv", title: ":",
                                   kind: .movie)
        let path = JellyfinNamer().relativePath(for: parsed, fileExtension: "mkv")
        let sanitised = JellyfinNamer.sanitizeRelativePath(path)
        XCTAssertFalse(sanitised.isEmpty, "the path has no component at all")
        XCTAssertTrue(sanitised.contains("Unbenannt"), sanitised)
    }

    /// Not translated, because it ends up in a path: a file must not change
    /// its name because the interface language changed.
    func testTheFallbackNameDoesNotFollowTheLanguage() {
        let parsed = ParsedRelease(originalFileName: ":.mkv", title: ":",
                                   kind: .movie)
        Text.language = .german
        let german = JellyfinNamer().relativePath(for: parsed, fileExtension: "mkv")
        Text.language = .english
        let english = JellyfinNamer().relativePath(for: parsed, fileExtension: "mkv")
        Text.language = .german
        XCTAssertEqual(german, english)
    }

    func testAnEpisodeGetsTheSameFallback() {
        let parsed = ParsedRelease(originalFileName: "?.S01E02.1080p.mkv",
                                   title: "?", season: 1, episode: 2,
                                   kind: .episode)
        let path = JellyfinNamer().relativePath(for: parsed, fileExtension: "mkv")
        XCTAssertFalse(path.hasPrefix(" "), path)
        XCTAssertFalse(path.contains("/ "), path)
        XCTAssertTrue(path.contains("S01E02"), path)
    }

    // MARK: The release stays together

    func testASubtitleIsPlannedIntoTheSameFolderAsItsFilm() throws {
        let film = try write("?.2019.1080p.WEB-DL.x264.mkv")
        try write("?.2019.1080p.WEB-DL.x264.en.srt")
        // No library folder: the default, and the branch where `reconcile`
        // does not run.
        let plan = RenamePlanner().makePlan(
            for: MediaScanner().scan(urls: [film]), outputRoot: nil)
        let item = try XCTUnwrap(plan.first)
        let companion = try XCTUnwrap(item.companionMoves.first)

        XCTAssertEqual(companion.destination.deletingLastPathComponent()
                        .standardizedFileURL.path,
                       item.primaryDestination.deletingLastPathComponent()
                        .standardizedFileURL.path,
                       "the subtitle is planned into a different directory than "
                           + "its film")
    }

    func testExecutingThePlanLeavesOneFolderWithBothFilesInIt() throws {
        let film = try write("?.2019.1080p.WEB-DL.x264.mkv")
        try write("?.2019.1080p.WEB-DL.x264.en.srt")
        let plan = RenamePlanner().makePlan(
            for: MediaScanner().scan(urls: [film]), outputRoot: nil)
        let log = RenameLog(url: root.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: root.appendingPathComponent("journal.json"))

        let outcome = RenameExecutor(log: log, journal: journal)
            .execute(plan: plan, policy: .skip)

        XCTAssertEqual(outcome.succeeded, 2)
        let item = try XCTUnwrap(plan.first)
        let folder = item.primaryDestination.deletingLastPathComponent()
        let inside = try fm.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(inside.count, 2,
                       "the release did not arrive whole: \(inside)")
        XCTAssertTrue(inside.contains { $0.hasSuffix(".srt") },
                      "the film has no subtitle beside it: \(inside)")
        // And exactly one folder was made, not two that look alike.
        let siblings = try fm.contentsOfDirectory(atPath: source.path)
            .filter { !$0.hasSuffix(".mkv") && !$0.hasSuffix(".srt") }
        XCTAssertEqual(siblings.count, 1, "sibling folders: \(siblings)")
    }

    /// The ordinary case is unchanged: a real title is used as it is.
    func testARealTitleIsStillUsed() {
        let parsed = ParsedRelease(originalFileName: "Tenet.2020.1080p.mkv",
                                   title: "Tenet", year: 2020, kind: .movie)
        XCTAssertEqual(
            JellyfinNamer().relativePath(for: parsed, fileExtension: "mkv"),
            "Tenet (2020)/Tenet (2020).mkv")
    }
}
