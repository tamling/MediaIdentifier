import XCTest
@testable import MediaIdentifierCore

/// Telling the two kinds of `.nfo` apart.
///
/// Both halves matter equally. Classifying a sidecar as a release note
/// destroys everything the user ever corrected by hand; classifying every
/// release note as a sidecar quietly turns the whole feature off, and a
/// guard that refuses everything looks exactly like a guard that works.
/// So each test here has its opposite somewhere below it.
final class NfoContentTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        Text.language = .german
        root = fm.temporaryDirectory
            .appendingPathComponent("mediafin-nfo-kind-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func file(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        try file(name, Array(text.utf8))
    }

    // MARK: Jellyfin's own metadata

    func testAnEpisodeSidecarIsRecognised() throws {
        let url = try file("Fargo - S05E10 - Bisquik.nfo", """
            <?xml version="1.0" encoding="utf-8" standalone="yes"?>
            <episodedetails>
              <title>Bisquik</title>
              <plot>Everything the user corrected by hand lives in here.</plot>
            </episodedetails>
            """)
        XCTAssertEqual(NfoContent.kind(of: url), .metadataSidecar)
    }

    func testEveryRootElementJellyfinWritesIsRecognised() throws {
        for element in ["movie", "episodedetails", "tvshow", "season",
                        "musicvideo", "artist", "album"] {
            // Without the declaration, so the element itself is what is
            // being tested and not `<?xml`.
            let url = try file("\(element).nfo", "<\(element)>\n  <title>X</title>\n")
            XCTAssertEqual(NfoContent.kind(of: url), .metadataSidecar, element)
        }
    }

    /// Case is not a property of XML this program may rely on.
    func testTheElementIsRecognisedWhateverItsCase() throws {
        let url = try file("a.nfo", "<MOVIE>\n<Title>X</Title>\n</MOVIE>")
        XCTAssertEqual(NfoContent.kind(of: url), .metadataSidecar)
    }

    /// A byte-order mark, a comment and a stylesheet instruction in front of
    /// the root element: all three are legal, and all three used to be
    /// enough to hide it from a test that only looked at the first line.
    func testAMarkAndACommentInFrontOfTheElementChangeNothing() throws {
        let url = try file("b.nfo", [0xEF, 0xBB, 0xBF]
            + Array("<!-- written by Jellyfin -->\n<movie>\n</movie>".utf8))
        XCTAssertEqual(NfoContent.kind(of: url), .metadataSidecar)
    }

    /// UTF-16 is unusual here but legal, and its ASCII characters each carry
    /// a NUL that a naive byte search would trip over.
    func testAUTF16SidecarIsStillRecognised() throws {
        var bytes: [UInt8] = [0xFF, 0xFE]
        for byte in Array("<movie><title>X</title></movie>".utf8) {
            bytes.append(byte); bytes.append(0)
        }
        let url = try file("c.nfo", bytes)
        XCTAssertEqual(NfoContent.kind(of: url), .metadataSidecar)
    }

    /// Kodi's other format, which Jellyfin also reads: no XML at all, just
    /// the address of the entry. It is the one hint the user gave about what
    /// this film is, and it is three dozen bytes, so it looks like nothing.
    func testAUrlOnlySidecarIsRecognised() throws {
        for text in ["https://www.themoviedb.org/movie/603\n",
                     "http://www.imdb.com/title/tt0133093/\n",
                     "\u{FEFF}  https://www.themoviedb.org/tv/1396\n"] {
            let url = try file("url.nfo", text)
            XCTAssertEqual(NfoContent.kind(of: url), .metadataSidecar, text)
        }
    }

    // MARK: The group's own file

    /// The positive control. Without it the guard could pass every test
    /// above by refusing to delete anything at all, which would turn the
    /// feature off without a single test going red.
    func testAGenuineReleaseNoteIsRecognised() throws {
        let url = try file("Dark.S01E01.GERMAN.1080p.WEB-DL.nfo", """
            ╔══════════════════════════════════════════════════════════╗
            ║  D A R K   S01E01                       GERMAN 1080p     ║
            ╠══════════════════════════════════════════════════════════╣
            ║  Source .......: WEB-DL                                  ║
            ║  Video ........: x264 @ 8000 kbps                        ║
            ║  Audio ........: DD5.1 German                            ║
            ║  Runtime ......: 51 min                                  ║
            ╚══════════════════════════════════════════════════════════╝
                       greetings to everyone keeping the scene alive
            """)
        XCTAssertEqual(NfoContent.kind(of: url), .releaseNote)
    }

    /// Release notes are frequently CP437, which is not valid UTF-8. The
    /// decision must not depend on the file decoding as text at all.
    func testACP437NoteThatIsNotValidUTF8IsStillRecognised() throws {
        // 0xC9 0xCD 0xBB are the box-drawing corners; as UTF-8 this is an
        // illegal sequence, and String(data:encoding:.utf8) returns nil.
        // Built by appending rather than as one `+` chain: a chain of array
        // literals that long defeats the 6.0.3 type checker outright.
        let rule = [UInt8](repeating: 0xCD, count: 40)
        var bytes: [UInt8] = [0xC9]
        bytes += rule
        bytes += [0xBB, 0x0A]
        bytes += Array("  RELEASE: Tenet.2020.1080p.BluRay.x264-GROUP\n".utf8)
        bytes += [0xC8]
        bytes += rule
        bytes += [0xBC, 0x0A]
        let url = try file("tenet.nfo", bytes)
        XCTAssertNil(String(data: Data(bytes), encoding: .utf8),
                     "the fixture is supposed to be undecodable as UTF-8")
        XCTAssertEqual(NfoContent.kind(of: url), .releaseNote)
    }

    func testAPlainTextNoteIsRecognised() throws {
        let url = try file("notes.nfo", "ripped from the retail disc, enjoy\n")
        XCTAssertEqual(NfoContent.kind(of: url), .releaseNote)
    }

    // MARK: Neither

    /// A file this program cannot read is not thereby rubbish. Deleting on
    /// "I could not tell" is how the sidecar got deleted in the first place.
    func testAnEmptyFileIsNotDeletable() throws {
        let url = try file("empty.nfo", [])
        XCTAssertEqual(NfoContent.kind(of: url), .undecidable)
    }

    func testAFileThatIsNotThereIsNotDeletable() {
        XCTAssertEqual(
            NfoContent.kind(of: root.appendingPathComponent("absent.nfo")),
            .undecidable)
    }

    func testADirectoryIsNotDeletable() throws {
        let url = root.appendingPathComponent("Extras.nfo")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertEqual(NfoContent.kind(of: url), .undecidable)
    }

    /// Mode 000 while running as root is not a test — root ignores the mode
    /// bits and CI runs as root, so this would be a check that cannot fail.
    /// A file where a directory has to be opened binds root as well.
    func testAnUnreadablePathIsNotDeletable() throws {
        let blocker = try file("blocker", "not a directory")
        let url = blocker.appendingPathComponent("inside.nfo")
        XCTAssertEqual(NfoContent.kind(of: url), .undecidable)
    }

    // MARK: The bound on what is read

    /// Only the head of the file is read: nothing stops a 2 GB file from
    /// being named `.nfo`, and the answer is in the first line anyway.
    func testOnlyTheHeadOfTheFileIsRead() throws {
        let padding = String(repeating: "A", count: NfoContent.sampleSize * 2)
        let url = try file("late.nfo", padding + "\n<movie></movie>\n")
        XCTAssertEqual(NfoContent.kind(of: url), .releaseNote,
                       "the whole file was read; the bound does not hold")
    }

    func testTheDecisionOverBytesNeedsNoDisk() {
        XCTAssertEqual(NfoContent.kind(ofSample: Data("<movie>".utf8)),
                       .metadataSidecar)
        XCTAssertEqual(NfoContent.kind(ofSample: Data("art\n".utf8)), .releaseNote)
    }
}
