import XCTest
@testable import MediaIdentifierCore

final class PlannerLibraryTests: XCTestCase {
    private let library = URL(fileURLWithPath: "/Library")
    private let planner = RenamePlanner()

    private func ep(_ show: String, _ s: Int, _ e: Int) -> MediaFile {
        MediaFile(url: URL(fileURLWithPath: "/downloads/\(show).S\(s)E\(e).1080p.mkv"),
                  parsed: ParsedRelease(originalFileName: "x", title: show,
                                        season: s, episode: e, kind: .episode))
    }
    private func movie() -> MediaFile {
        MediaFile(url: URL(fileURLWithPath: "/downloads/Interstellar.2014.mkv"),
                  parsed: ParsedRelease(originalFileName: "x", title: "Interstellar", year: 2014, kind: .movie))
    }

    func testAMovieGoesToTheRootItIsGiven() {
        let plan = planner.makePlan(for: [movie()], outputRoot: library)
        XCTAssertTrue(plan[0].primaryDestination.path.hasPrefix("/Library/"))
        XCTAssertEqual(plan[0].proposedRelativePath,
                       "Interstellar (2014)/Interstellar (2014).mkv")
    }

    /// Every episode, not only the ones whose season is complete.
    ///
    /// There was a rule here: an episode moved into the library only once
    /// its season was contiguous from episode 1 with at least two present,
    /// and a partial season was renamed where it lay. It was documented, it
    /// had its own analyser, and seven tests covered the analyser while
    /// `testIncompleteSeasonStaysInPlace` covered the planner — and none of
    /// it ran in the program, which passed `libraryRoot: nil` and chose the
    /// roots itself. Asked about it, the answer was to take the rule out
    /// rather than switch it on: for a series that arrives weekly it would
    /// hold every episode in the import folder until the season ended.
    func testEveryEpisodeGoesToTheRootIncludingALoneOne() {
        let lone = planner.makePlan(for: [ep("Solo", 1, 1)], outputRoot: library)
        XCTAssertEqual(lone[0].outputRoot, library,
                       "a single episode was held back")
        XCTAssertTrue(lone[0].primaryDestination.path.hasPrefix("/Library/"))

        let whole = planner.makePlan(for: [ep("Show", 1, 1), ep("Show", 1, 2)],
                                     outputRoot: library)
        for item in whole {
            XCTAssertEqual(item.outputRoot, library)
        }
        XCTAssertEqual(whole.count, 2)
    }

    /// And a gap in the middle changes nothing either, which is the case the
    /// removed rule cared about most.
    func testAGapInTheSeasonChangesNothing() {
        let plan = planner.makePlan(for: [ep("Show", 1, 1), ep("Show", 1, 5)],
                                    outputRoot: library)
        XCTAssertEqual(plan.count, 2)
        for item in plan { XCTAssertEqual(item.outputRoot, library) }
    }

    func testNoRootKeepsThingsInPlace() {
        let file = movie()
        let plan = planner.makePlan(for: [file])
        XCTAssertEqual(plan[0].outputRoot, file.url.deletingLastPathComponent())
    }
}
