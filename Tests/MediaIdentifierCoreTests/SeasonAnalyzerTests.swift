import XCTest
@testable import MediaIdentifierCore

final class SeasonAnalyzerTests: XCTestCase {
    private func ep(_ show: String, _ season: Int, _ episode: Int, end: Int? = nil) -> MediaFile {
        MediaFile(
            url: URL(fileURLWithPath: "/tmp/\(show)-S\(season)E\(episode).mkv"),
            parsed: ParsedRelease(originalFileName: "x", title: show,
                                  season: season, episode: episode, episodeEnd: end, kind: .episode)
        )
    }
    private func movie(_ title: String, _ year: Int) -> MediaFile {
        MediaFile(url: URL(fileURLWithPath: "/tmp/\(title).mkv"),
                  parsed: ParsedRelease(originalFileName: "x", title: title, year: year, kind: .movie))
    }

    func testContiguousSeasonIsComplete() {
        let c = SeasonAnalyzer.completeSeasons(in: [ep("Show", 1, 1), ep("Show", 1, 2), ep("Show", 1, 3)])
        XCTAssertTrue(c.contains(.init(showTitle: "Show", season: 1)))
    }

    func testGapMakesSeasonIncomplete() {
        let c = SeasonAnalyzer.completeSeasons(in: [ep("Show", 1, 1), ep("Show", 1, 3)])
        XCTAssertTrue(c.isEmpty)
    }

    func testSingleEpisodeNotComplete() {
        XCTAssertTrue(SeasonAnalyzer.completeSeasons(in: [ep("Show", 1, 1)]).isEmpty)
    }

    func testMustStartAtOne() {
        // Episodes 2,3 (no 1) -> not complete.
        XCTAssertTrue(SeasonAnalyzer.completeSeasons(in: [ep("Show", 1, 2), ep("Show", 1, 3)]).isEmpty)
    }

    func testMultiEpisodeFileCoversRange() {
        // S01E01E02 + S01E03 -> 1,2,3 contiguous -> complete.
        let c = SeasonAnalyzer.completeSeasons(in: [ep("Show", 1, 1, end: 2), ep("Show", 1, 3)])
        XCTAssertTrue(c.contains(.init(showTitle: "Show", season: 1)))
    }

    func testSeasonsAndShowsAreIndependent() {
        let files = [
            ep("A", 1, 1), ep("A", 1, 2),     // complete
            ep("A", 2, 1),                    // incomplete
            ep("B", 1, 1), ep("B", 1, 3),     // gap
            movie("Film", 2020)
        ]
        let c = SeasonAnalyzer.completeSeasons(in: files)
        XCTAssertTrue(c.contains(.init(showTitle: "A", season: 1)))
        XCTAssertFalse(c.contains(.init(showTitle: "A", season: 2)))
        XCTAssertFalse(c.contains(.init(showTitle: "B", season: 1)))
        XCTAssertEqual(c.count, 1)
    }

    func testKeyIsCaseInsensitive() {
        let c = SeasonAnalyzer.completeSeasons(in: [ep("The Office", 1, 1), ep("the office", 1, 2)])
        XCTAssertTrue(c.contains(.init(showTitle: "THE OFFICE", season: 1)))
    }
}
