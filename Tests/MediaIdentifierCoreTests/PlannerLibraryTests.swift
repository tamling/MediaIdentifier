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

    func testMovieMovesToLibrary() {
        let plan = planner.makePlan(for: [movie()], libraryRoot: library)
        XCTAssertTrue(plan[0].primaryDestination.path.hasPrefix("/Library/"))
        XCTAssertEqual(plan[0].proposedRelativePath, "Interstellar (2014)/Interstellar (2014).mkv")
    }

    func testCompleteSeasonMovesToLibrary() {
        let plan = planner.makePlan(for: [ep("Show", 1, 1), ep("Show", 1, 2)], libraryRoot: library)
        for item in plan {
            XCTAssertEqual(item.outputRoot, library, "complete-season episodes go to the library")
        }
    }

    func testIncompleteSeasonStaysInPlace() {
        // Episode 1 only -> not a complete season -> renamed in place.
        let file = ep("Solo", 1, 1)
        let plan = planner.makePlan(for: [file], libraryRoot: library)
        XCTAssertEqual(plan[0].outputRoot, file.url.deletingLastPathComponent())
        XCTAssertFalse(plan[0].primaryDestination.path.hasPrefix("/Library/"))
    }

    func testNoLibraryKeepsInPlace() {
        let file = movie()
        let plan = planner.makePlan(for: [file])
        XCTAssertEqual(plan[0].outputRoot, file.url.deletingLastPathComponent())
    }
}
