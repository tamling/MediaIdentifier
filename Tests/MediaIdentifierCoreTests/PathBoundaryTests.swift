import XCTest
@testable import MediaIdentifierCore

/// The boundary where a string becomes a path.
///
/// `sanitizeRelativePath` had three passing traversal tests and no call site
/// in `Sources` at all — it was called by the form of a web interface that
/// no longer exists. The defence was green in CI and absent from the
/// program, which is this project's recurring failure: a check that cannot
/// run looks exactly like a check that passes.
///
/// So this suite does not test the sanitiser. It tests `RenameItem`, which
/// is what the rest of the program actually uses, with values a producer
/// could plausibly hand it.
final class PathBoundaryTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/library", isDirectory: true)

    override func setUp() {
        super.setUp()
        Text.language = .german
    }

    private func item(_ relative: String) -> RenameItem {
        RenameItem(
            mediaFile: MediaFile(
                url: URL(fileURLWithPath: "/downloads/x.mkv"),
                parsed: ParsedRelease(originalFileName: "x.mkv", title: "X")),
            outputRoot: root,
            proposedRelativePath: relative)
    }

    /// The whole point: whatever goes in, the destination is under the root.
    private func assertInsideTheRoot(_ relative: String,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        let destination = item(relative).primaryDestination
            .standardizedFileURL.path
        XCTAssertTrue(destination.hasPrefix("/library/") || destination == "/library",
                      "\(relative.debugDescription) escaped to \(destination)",
                      file: file, line: line)
    }

    // MARK: Climbing out

    func testEveryWayOutOfTheRootIsClosed() {
        for relative in ["../../etc/passwd",
                         "..",
                         "../",
                         "./../../root/.ssh/authorized_keys",
                         "Show/../../../Season 01/ep.mkv",
                         "/etc/passwd",
                         "//etc/passwd",
                         "/",
                         "....//....//etc/passwd",
                         "a/./../../b.mkv"] {
            assertInsideTheRoot(relative)
        }
    }

    /// `..` as a component is dropped rather than escaped — the file lands
    /// somewhere sane rather than nowhere.
    func testTraversalComponentsAreDroppedAndTheRestSurvives() {
        let destination = item("Fargo/../Season 05/Fargo - S05E10.mkv")
            .primaryDestination.standardizedFileURL.path
        XCTAssertEqual(destination, "/library/Fargo/Season 05/Fargo - S05E10.mkv")
    }

    /// The row and the destination must never disagree. Reading the path
    /// back has to show what the file will actually be called, or the
    /// preview is a lie and "already filed" detection breaks.
    ///
    /// Against a literal, not against the other accessor. This test used to
    /// assert `primaryDestination.path == root.appending(proposedRelativePath)`,
    /// and `primaryDestination` IS `outputRoot.appending(storedRelativePath)`
    /// while `proposedRelativePath` IS `storedRelativePath` — so both sides
    /// reduced to the same expression and the assertion held for every
    /// possible implementation of the sanitiser, including one that does
    /// nothing. The same shape as the defence it was written to replace.
    func testTheStoredPathIsTheSanitisedOneAndTheDestinationMatchesIt() {
        var subject = item("Show/../Season 01/ep.mkv")
        XCTAssertEqual(subject.proposedRelativePath, "Show/Season 01/ep.mkv")
        XCTAssertEqual(subject.primaryDestination.path,
                       "/library/Show/Season 01/ep.mkv")

        // And after an edit, too — that is what the setter is for.
        subject.proposedRelativePath = "../../somewhere/else.mkv"
        XCTAssertEqual(subject.proposedRelativePath, "somewhere/else.mkv")
        XCTAssertEqual(subject.primaryDestination.path,
                       "/library/somewhere/else.mkv")
    }

    /// The setter has no caller in the program: nothing under Sources
    /// assigns `proposedRelativePath`, because editing a destination by hand
    /// was a feature of the web front end. It is still worth sanitising —
    /// the next editor will use it — and it is worth saying out loud that
    /// the test above is the only thing exercising it, so that nobody reads
    /// the coverage as proof the program is protected here. What protects
    /// the program is the sanitising in `init`, which the first half of that
    /// test covers.
    func testTheInitIsWhatTheProgramActuallyReliesOn() {
        // Built the way the planner builds it, with a path that needs
        // cleaning, and never assigned afterwards.
        XCTAssertEqual(item("../../etc/passwd").primaryDestination.path,
                       "/library/etc/passwd")
    }

    /// An ordinary path is left exactly as it is. A sanitiser that mangles
    /// the normal case gets switched off by whoever notices.
    func testAnOrdinaryPathIsUntouched() {
        for relative in ["Interstellar (2014)/Interstellar (2014).mkv",
                         "The Last of Us/Season 01/The Last of Us - S01E01.mkv",
                         "AC-DC/Back in Black (1980)/01 - Hells Bells.flac",
                         "Fargo - S05E10-E11.mkv"] {
            XCTAssertEqual(item(relative).proposedRelativePath, relative,
                           "a legitimate path was rewritten")
        }
    }

    // MARK: The length nobody bounded

    /// A model or TMDb can answer with anything; the only check on the title
    /// used to be "not empty". ext4 stops at 255 BYTES per component.
    func testEveryComponentFitsOnTheFilesystem() {
        let long = String(repeating: "a", count: 2_000)
        let subject = item("\(long)/\(long)/\(long).mkv")
        for component in subject.proposedRelativePath.split(separator: "/") {
            XCTAssertLessThanOrEqual(component.utf8.count, 255,
                                     "a component of \(component.utf8.count) bytes")
        }
    }

    /// Counted in bytes, not characters: a Japanese title is three bytes a
    /// character, so 120 characters is 360 bytes and the rename fails.
    func testAJapaneseTitleIsCountedInBytes() {
        let long = String(repeating: "映", count: 300)
        let cleaned = JellyfinNamer.sanitize(long)
        XCTAssertLessThanOrEqual(cleaned.utf8.count,
                                 JellyfinNamer.componentByteLimit)
        XCTAssertFalse(cleaned.isEmpty, "it cut the whole title away")
    }

    /// And never through the middle of a character.
    func testCuttingNeverSplitsAGrapheme() {
        for text in [String(repeating: "👨‍👩‍👧‍👦", count: 40),
                     String(repeating: "🇩🇪", count: 60),
                     String(repeating: "é", count: 300)] {
            let cut = JellyfinNamer.truncating(text, toBytes: 200)
            XCTAssertEqual(cut, String(cut), "the cut produced invalid text")
            XCTAssertLessThanOrEqual(cut.utf8.count, 200)
            XCTAssertTrue(text.hasPrefix(cut), "the cut changed what came before it")
        }
    }

    /// The film-folder case, which is the one that half-succeeded: the stem
    /// is used for the folder AND for the file, and the file carries the
    /// extension as well — so a stem that fits as a folder need not fit as a
    /// file. The budget is 200, which leaves the slack for that.
    func testALongTitleFitsAsBothAFolderAndAFile() {
        let parsed = ParsedRelease(
            originalFileName: "x.mkv",
            title: String(repeating: "Lange Titelwörter ", count: 40),
            year: 2014,
            kind: .movie)
        let relative = JellyfinNamer().relativePath(for: parsed, fileExtension: "mkv")
        let components = relative.split(separator: "/")
        XCTAssertEqual(components.count, 2, "expected Folder/File.mkv")
        for component in components {
            XCTAssertLessThanOrEqual(component.utf8.count, 255, String(component))
        }
    }

    // MARK: Control characters

    func testControlCharactersNeverReachAFileName() {
        for raw in ["Film\nmit Umbruch", "Film\u{1b}[31mrot", "Film\tTab",
                    "Film\u{7f}DEL", "Film\u{0}NUL", "\r\nFilm"] {
            let cleaned = JellyfinNamer.sanitize(raw)
            XCTAssertFalse(cleaned.unicodeScalars.contains { $0.value < 0x20 },
                           cleaned.debugDescription)
            XCTAssertFalse(cleaned.unicodeScalars.contains { $0.value == 0x7F },
                           cleaned.debugDescription)
        }
    }

    /// The same rule in both namers, which is the point of there being one
    /// implementation: the video path was the one without a length limit and
    /// without a control-character filter.
    func testBothNamersObeyTheSameRule() {
        let raw = "Künstler\nmit Umbruch " + String(repeating: "x", count: 400)
        let video = JellyfinNamer.sanitize(raw)
        let music = MusicNamer.clean(raw) ?? ""
        for cleaned in [video, music] {
            XCTAssertLessThanOrEqual(cleaned.utf8.count,
                                     JellyfinNamer.componentByteLimit, cleaned)
            XCTAssertFalse(cleaned.contains("\n"))
        }
    }

    // MARK: The property test

    /// Ten thousand hostile titles, and three invariants that must hold for
    /// every one of them. This is the fuzzer for the part of the program
    /// that needs one, and it runs without touching a disk.
    func testHostileTitlesAlwaysProduceAUsablePathInsideTheRoot() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("ab/\\:*?\"<>|. \n\t\u{0}\u{7f}é映👨‍👩‍👧‍👦-()[]~$'`&;")

        for iteration in 0..<10_000 {
            let length = Int.random(in: 0...60, using: &generator)
            let title = String((0..<length).map { _ in
                alphabet.randomElement(using: &generator)!
            })
            let parsed = ParsedRelease(
                originalFileName: title + ".mkv",
                title: title,
                year: Bool.random(using: &generator)
                    ? Int.random(in: 1900...2030, using: &generator) : nil,
                season: Bool.random(using: &generator)
                    ? Int.random(in: 0...99, using: &generator) : nil,
                episode: Int.random(in: 0...99, using: &generator),
                kind: Bool.random(using: &generator) ? .episode : .movie)

            let relative = JellyfinNamer().relativePath(for: parsed,
                                                        fileExtension: "mkv")
            let subject = RenameItem(
                mediaFile: MediaFile(url: URL(fileURLWithPath: "/downloads/x.mkv"),
                                     parsed: parsed),
                outputRoot: root,
                proposedRelativePath: relative)
            let destination = subject.primaryDestination.standardizedFileURL.path
            let context = "iteration \(iteration), title \(title.debugDescription)"

            // 1. It cannot leave the library.
            XCTAssertTrue(destination.hasPrefix("/library/"),
                          "escaped to \(destination) — \(context)")

            // 2. Every component is a name a filesystem will take.
            for component in subject.proposedRelativePath.split(separator: "/") {
                XCTAssertLessThanOrEqual(component.utf8.count, 255, context)
                XCTAssertNotEqual(component, ".", context)
                XCTAssertNotEqual(component, "..", context)
                XCTAssertFalse(component.hasSuffix(" "), context)
                XCTAssertFalse(component.hasSuffix("."), context)
                XCTAssertFalse(component.unicodeScalars.contains { $0.value < 0x20 },
                               context)
            }

            // 3. Something is always proposed. A title made entirely of
            //    characters that get stripped must still land somewhere
            //    rather than producing an empty path that appends to the
            //    root itself.
            XCTAssertFalse(subject.proposedRelativePath.isEmpty,
                           "nothing was proposed at all — \(context)")
        }
    }
}
