import XCTest
@testable import MediaIdentifierCore

final class FolderSelectionTests: XCTestCase {

    /// The music folder follows the same rule as the other three, and for
    /// the same reason: an unmounted drive comes up as a blank chooser.
    func testTheMusicFolderFollowsTheSameRule() {
        let picked = FolderSelection.applying(source: "", movies: "", series: "",
                                              music: "/mnt/media/Hoerbuecher",
                                              to: configured())
        XCTAssertEqual(picked.musicFolder, "/mnt/media/Hoerbuecher")

        let blank = FolderSelection.applying(source: "", movies: "", series: "",
                                             music: "", to: configured())
        XCTAssertEqual(blank.musicFolder, "/mnt/media/Music",
                       "a chooser that shows nothing has not been cleared")
    }

    private func configured() -> WebSettings {
        var settings = WebSettings()
        settings.sourceFolder = "/mnt/downloads"
        settings.moviesFolder = "/mnt/media/Movies"
        settings.seriesFolder = "/mnt/media/Series"
        settings.musicFolder = "/mnt/media/Music"
        settings.localLLMBaseURL = "http://192.168.3.116:1234"
        settings.localLLMModel = "qwen3.6"
        settings.watchSourceFolder = true
        return settings
    }

    func testAChosenFolderReplacesTheStoredOne() {
        let updated = FolderSelection.applying(source: "/srv/incoming", movies: "", series: "",
                                               music: "", to: configured())
        XCTAssertEqual(updated.sourceFolder, "/srv/incoming")
    }

    /// The case this exists for: an unmounted drive makes the chooser come up
    /// blank, and saving must not read that as "the user cleared it".
    func testAnEmptySelectionKeepsTheStoredFolder() {
        let updated = FolderSelection.applying(source: "", movies: "", series: "",
                                               music: "", to: configured())
        XCTAssertEqual(updated.sourceFolder, "/mnt/downloads")
        XCTAssertEqual(updated.moviesFolder, "/mnt/media/Movies")
        XCTAssertEqual(updated.seriesFolder, "/mnt/media/Series")
    }

    func testWhitespaceCountsAsEmpty() {
        let updated = FolderSelection.applying(source: "   ", movies: "\n", series: "\t",
                                               music: "", to: configured())
        XCTAssertEqual(updated.sourceFolder, "/mnt/downloads")
        XCTAssertEqual(updated.moviesFolder, "/mnt/media/Movies")
        XCTAssertEqual(updated.seriesFolder, "/mnt/media/Series")
    }

    func testSurroundingWhitespaceIsTrimmedFromAChosenPath() {
        let updated = FolderSelection.applying(source: "  /srv/incoming  ", movies: "",
                                               series: "", music: "", to: configured())
        XCTAssertEqual(updated.sourceFolder, "/srv/incoming")
    }

    /// One blank chooser must not take the other two down with it.
    func testEachFolderIsDecidedOnItsOwn() {
        let updated = FolderSelection.applying(source: "", movies: "/new/Movies", series: "",
                                               music: "", to: configured())
        XCTAssertEqual(updated.sourceFolder, "/mnt/downloads")
        XCTAssertEqual(updated.moviesFolder, "/new/Movies")
        XCTAssertEqual(updated.seriesFolder, "/mnt/media/Series")
    }

    /// The window shows three folders; the settings hold a good deal more.
    /// Saving from the window must not reset what the web interface owns.
    func testEverythingElseIsCarriedOver() {
        let original = configured()
        let updated = FolderSelection.applying(source: "/srv/incoming", movies: "", series: "",
                                               music: "", to: original)

        XCTAssertEqual(updated.localLLMBaseURL, original.localLLMBaseURL)
        XCTAssertEqual(updated.localLLMModel, original.localLLMModel)
        XCTAssertEqual(updated.identification, original.identification)
        XCTAssertEqual(updated.jellyfinBaseURL, original.jellyfinBaseURL)
        XCTAssertEqual(updated.conflictPolicy, original.conflictPolicy)
        XCTAssertEqual(updated.watchSourceFolder, original.watchSourceFolder)
        XCTAssertEqual(updated.conversion, original.conversion)
    }

    /// Starting from nothing, a first selection must still land.
    func testFirstSelectionOnEmptySettings() {
        let updated = FolderSelection.applying(source: "/srv/incoming", movies: "/srv/Movies",
                                               series: "/srv/Series", music: "", to: WebSettings())
        XCTAssertEqual(updated.sourceFolder, "/srv/incoming")
        XCTAssertEqual(updated.moviesFolder, "/srv/Movies")
        XCTAssertEqual(updated.seriesFolder, "/srv/Series")
    }

    func testNothingChosenAndNothingStoredStaysEmpty() {
        let updated = FolderSelection.applying(source: "", movies: "", series: "",
                                               music: "", to: WebSettings())
        XCTAssertEqual(updated, WebSettings())
    }
}
