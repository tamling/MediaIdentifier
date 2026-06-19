import XCTest
@testable import MediaIdentifierCore

final class ReleaseNameParserTests: XCTestCase {
    private let parser = ReleaseNameParser()

    // FR2 — full release breakdown.
    func testParsesFullEpisodeRelease() {
        let r = parser.parse(fileName: "The.Last.of.Us.S01E01.1080p.WEB-DL.x264-GROUP.mkv")
        XCTAssertEqual(r.title, "The Last of Us")
        XCTAssertEqual(r.kind, .episode)
        XCTAssertEqual(r.season, 1)
        XCTAssertEqual(r.episode, 1)
        XCTAssertEqual(r.resolution, "1080p")
        XCTAssertEqual(r.codec, "x264")
        XCTAssertEqual(r.releaseGroup, "GROUP")
    }

    // FR4 / FR5 — movie title + year.
    func testParsesMovieTitleAndYear() {
        let r = parser.parse(fileName: "Interstellar.2014.2160p.BluRay.x265-GROUP.mkv")
        XCTAssertEqual(r.title, "Interstellar")
        XCTAssertEqual(r.year, 2014)
        XCTAssertEqual(r.kind, .movie)
        XCTAssertEqual(r.resolution, "2160p")
        XCTAssertEqual(r.source, "BluRay")
        XCTAssertEqual(r.releaseGroup, "GROUP")
    }

    // FR4 — title only.
    func testTitleFromBareEpisode() {
        let r = parser.parse(fileName: "The.Last.of.Us.S01E01")
        XCTAssertEqual(r.title, "The Last of Us")
        XCTAssertEqual(r.season, 1)
        XCTAssertEqual(r.episode, 1)
    }

    // FR6 — season/episode formats.
    func testSeasonEpisodeFormats() {
        XCTAssertEqual(parser.parse(fileName: "Show.S03E12.mkv").season, 3)
        XCTAssertEqual(parser.parse(fileName: "Show.S03E12.mkv").episode, 12)

        let alt = parser.parse(fileName: "Show.1x05.mkv")
        XCTAssertEqual(alt.season, 1)
        XCTAssertEqual(alt.episode, 5)

        let wordy = parser.parse(fileName: "Show Episode 07.mkv")
        XCTAssertEqual(wordy.episode, 7)
        XCTAssertEqual(wordy.season, 1)
    }

    // FR6 — multi-episode files.
    func testMultiEpisode() {
        let r = parser.parse(fileName: "Show.S01E01E02.1080p.mkv")
        XCTAssertEqual(r.season, 1)
        XCTAssertEqual(r.episode, 1)
        XCTAssertEqual(r.episodeEnd, 2)
    }

    // FR5 — disambiguate a title that contains a number from the release year.
    func testYearDisambiguation() {
        let r = parser.parse(fileName: "Blade.Runner.2049.2017.1080p.BluRay.mkv")
        XCTAssertEqual(r.title, "Blade Runner 2049")
        XCTAssertEqual(r.year, 2017)
    }

    func testYearAsTitle() {
        let r = parser.parse(fileName: "2012.2009.1080p.BluRay.x264.mkv")
        XCTAssertEqual(r.title, "2012")
        XCTAssertEqual(r.year, 2009)
    }

    func testHyphenatedTitlePreserved() {
        let r = parser.parse(fileName: "Spider-Man.Homecoming.2017.1080p.mkv")
        XCTAssertEqual(r.title, "Spider-Man Homecoming")
        XCTAssertEqual(r.year, 2017)
    }

    func testMovieWithoutYear() {
        let r = parser.parse(fileName: "Some.Movie.1080p.BluRay.x264.mkv")
        XCTAssertEqual(r.title, "Some Movie")
        XCTAssertNil(r.year)
    }

    func testDoesNotMistakeTitleLetterForEpisode() {
        let r = parser.parse(fileName: "Se7en.1995.1080p.BluRay.mkv")
        XCTAssertEqual(r.kind, .movie)
        XCTAssertEqual(r.year, 1995)
        XCTAssertEqual(r.title, "Se7en")
    }
}
