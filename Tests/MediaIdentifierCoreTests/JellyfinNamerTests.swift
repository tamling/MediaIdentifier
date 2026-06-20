import XCTest
@testable import MediaIdentifierCore

final class JellyfinNamerTests: XCTestCase {

    // FR7 — movie naming with a folder.
    func testMovieWithFolder() {
        let namer = JellyfinNamer(options: NamingOptions(useMovieFolders: true))
        let parsed = ParsedRelease(originalFileName: "x", title: "Interstellar", year: 2014, kind: .movie)
        XCTAssertEqual(
            namer.relativePath(for: parsed, fileExtension: "mkv"),
            "Interstellar (2014)/Interstellar (2014).mkv"
        )
    }

    // FR7 — movie naming without a folder.
    func testMovieWithoutFolder() {
        let namer = JellyfinNamer(options: NamingOptions(useMovieFolders: false))
        let parsed = ParsedRelease(originalFileName: "x", title: "Interstellar", year: 2014, kind: .movie)
        XCTAssertEqual(namer.relativePath(for: parsed, fileExtension: "mkv"), "Interstellar (2014).mkv")
    }

    // FR7 — episode naming.
    func testEpisodePath() {
        let namer = JellyfinNamer()
        let parsed = ParsedRelease(
            originalFileName: "x", title: "The Last of Us",
            season: 1, episode: 1, kind: .episode
        )
        XCTAssertEqual(
            namer.relativePath(for: parsed, fileExtension: "mkv"),
            "The Last of Us/Season 01/The Last of Us - S01E01.mkv"
        )
    }

    func testMultiEpisodePath() {
        let namer = JellyfinNamer()
        let parsed = ParsedRelease(
            originalFileName: "x", title: "Show",
            season: 1, episode: 1, episodeEnd: 2, kind: .episode
        )
        XCTAssertEqual(
            namer.relativePath(for: parsed, fileExtension: "mkv"),
            "Show/Season 01/Show - S01E01-E02.mkv"
        )
    }

    func testSeriesYearOption() {
        let namer = JellyfinNamer(options: NamingOptions(includeSeriesYear: true))
        let parsed = ParsedRelease(
            originalFileName: "x", title: "The Last of Us", year: 2023,
            season: 1, episode: 1, kind: .episode
        )
        XCTAssertEqual(
            namer.relativePath(for: parsed, fileExtension: "mkv"),
            "The Last of Us (2023)/Season 01/The Last of Us - S01E01.mkv"
        )
    }

    func testSanitizeIllegalCharacters() {
        XCTAssertEqual(JellyfinNamer.sanitize("Title: Subtitle"), "Title Subtitle")
        XCTAssertEqual(JellyfinNamer.sanitize("A/B\\C"), "A B C")
    }

    // Security: a manually edited path must not escape the output root.
    func testSanitizeRelativePathBlocksTraversal() {
        XCTAssertEqual(
            JellyfinNamer.sanitizeRelativePath("../../etc/passwd"),
            "etc/passwd"
        )
        XCTAssertEqual(
            JellyfinNamer.sanitizeRelativePath("/Movies/Film (2020).mkv"),
            "Movies/Film (2020).mkv"
        )
        XCTAssertEqual(
            JellyfinNamer.sanitizeRelativePath("Show/../../../Season 01/ep.mkv"),
            "Show/Season 01/ep.mkv"
        )
    }
}
