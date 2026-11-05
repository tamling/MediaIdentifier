import XCTest
@testable import MediaIdentifierCore

/// The download, against a real yt-dlp and a real HTTP server.
///
/// Everything else about this feature is tested by reading an argument
/// array, which proves the flags are what was intended and nothing about
/// whether they work. These run the actual binary against a file served
/// from 127.0.0.1 — no internet — and check that it arrives, that progress
/// really comes through a pipe, and that the things the flags are supposed
/// to prevent are prevented.
///
/// The progress assertion is the important one. The equivalent test for
/// sftp is what revealed that its documented progress format does not exist
/// when stdout is a pipe.
///
/// Skipped unless `MEDIAFIN_HTTP_TEST_URL` is set; the CI job fails if they
/// were skipped, because a skipped test reports success.
final class VideoDownloadIntegrationTests: XCTestCase {

    private var url: String!
    private var fixture: String!
    private var root: URL!
    private var importFolder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        Text.language = .english
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["MEDIAFIN_HTTP_TEST_URL"], !url.isEmpty else {
            throw XCTSkip("no local HTTP server; set MEDIAFIN_HTTP_TEST_URL")
        }
        self.url = url
        fixture = environment["MEDIAFIN_HTTP_TEST_FILE"] ?? ""

        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mediafin-dlint-\(UUID().uuidString)")
        importFolder = root.appendingPathComponent("import")
        try FileManager.default.createDirectory(at: importFolder,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        Text.language = .german
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func contents(of folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted() ?? []
    }

    /// Collects progress across the reader thread.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var updates: [VideoDownloader.Progress] = []
        func record(_ progress: VideoDownloader.Progress) {
            lock.lock(); updates.append(progress); lock.unlock()
        }
        var all: [VideoDownloader.Progress] {
            lock.lock(); defer { lock.unlock() }; return updates
        }
    }

    // MARK: It works at all

    func testTheFileArrivesInTheImportFolder() throws {
        let seen = Recorder()
        let arrival = try VideoDownloader().download(url, into: importFolder,
                                                     progress: { seen.record($0) })
        let file = arrival.file
        XCTAssertFalse(arrival.wasAlreadyThere,
                       "a fresh folder reported the file as already present")

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "yt-dlp reported \(file.path), which is not there")
        XCTAssertTrue(file.path.hasPrefix(importFolder.path),
                      "the file landed outside the import folder: \(file.path)")

        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        XCTAssertGreaterThan(size, 10_000, "what arrived is too small to be the video")
    }

    /// The assertion that would have caught the sftp mistake: progress is
    /// not assumed, it is observed.
    func testProgressReallyArrivesThroughAPipe() throws {
        let seen = Recorder()
        _ = try VideoDownloader().download(url, into: importFolder,
                                           progress: { seen.record($0) })

        let updates = seen.all
        // The sender always reports completion at the end, so more than one
        // is the proof that the parser read something the tool printed.
        XCTAssertGreaterThan(updates.count, 1,
                             "no progress was parsed; the output format is not what the "
                                 + "parser expects")
        let measured = updates.compactMap(\.downloadedBytes)
        XCTAssertFalse(measured.isEmpty, "no byte counts were parsed")
        XCTAssertEqual(measured, measured.sorted(),
                       "the byte count went backwards: \(measured)")
        XCTAssertTrue(updates.contains { $0.isFinished },
                      "no finished record was parsed")
    }

    /// A growing file in the import folder would be scanned and proposed
    /// while it was still being written.
    func testNoPartialFileIsLeftInTheImportFolder() throws {
        _ = try VideoDownloader().download(url, into: importFolder)

        let visible = contents(of: importFolder)
        XCTAssertFalse(visible.contains { $0.hasSuffix(".part") },
                       "a partial file was left behind: \(visible)")
        // The staging folder is hidden and emptied of its parts.
        let staging = importFolder.appendingPathComponent(
            DownloadCommand.stagingFolderName)
        let leftovers = contents(of: staging).filter { $0.hasSuffix(".part") }
        XCTAssertTrue(leftovers.isEmpty, "staging still holds \(leftovers)")
    }

    // MARK: What the flags are supposed to prevent

    /// The demonstrated one. `-P home:` makes a yt-dlp.conf in the import
    /// folder a config file, anything that can write a download there can
    /// write one, and a config file may carry --exec, which runs through a
    /// shell. --ignore-config is what stops it.
    func testAConfigFileInTheImportFolderCannotRunACommand() throws {
        let marker = root.appendingPathComponent("PWNED")
        try "--exec 'touch \(marker.path)'\n"
            .write(to: importFolder.appendingPathComponent("yt-dlp.conf"),
                   atomically: true, encoding: .utf8)

        _ = try? VideoDownloader().download(url, into: importFolder)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "a config file in the import folder ran a command")
    }

    /// yt-dlp installs data: and ftp: handlers unconditionally; only our own
    /// check keeps them out, and it must run before the process does.
    func testOnlyWebAddressesAreFetched() {
        for bad in ["file:///etc/passwd", "data:text/plain;base64,aGk=",
                    "ftp://127.0.0.1/x.mp4"] {
            XCTAssertThrowsError(
                try VideoDownloader().download(bad, into: importFolder), bad)
        }
        XCTAssertTrue(contents(of: importFolder).isEmpty,
                      "something was fetched for an address that should have been refused")
    }

    /// An address that resolves to nothing must fail loudly rather than
    /// leaving the interface waiting.
    func testAMissingPageFails() {
        let missing = url.replacingOccurrences(of: "Sample.Video.2024.1080p.mp4",
                                               with: "nothing-here.mp4")
        XCTAssertThrowsError(try VideoDownloader().download(missing, into: importFolder)) {
            error in
            XCTAssertFalse("\(error)".isEmpty)
        }
    }

    /// `--no-overwrites` makes a second attempt a silent success: yt-dlp
    /// exits 0 and prints the path of the file that is already there, which
    /// is indistinguishable from a real download by the exit code or by the
    /// path file. Measured here rather than assumed, because the whole
    /// point of the flag is that nothing visible happens.
    func testASecondAttemptSaysTheFileWasAlreadyThere() throws {
        let first = try VideoDownloader().download(url, into: importFolder)
        XCTAssertFalse(first.wasAlreadyThere)

        let second = try VideoDownloader().download(url, into: importFolder)
        XCTAssertEqual(second.file.lastPathComponent, first.file.lastPathComponent)
        XCTAssertTrue(second.wasAlreadyThere,
                      "a download that fetched nothing was reported as a download")
    }

    /// Nothing ever deleted these, and the folder is hidden, so a few
    /// cancelled downloads of large files sat in the import folder for good.
    func testStaleLeftoversInStagingAreSweptAway() throws {
        let staging = importFolder.appendingPathComponent(
            DownloadCommand.stagingFolderName)
        try FileManager.default.createDirectory(at: staging,
                                                withIntermediateDirectories: true)
        let old = staging.appendingPathComponent("abandoned.mkv.part")
        try Data(repeating: 0, count: 2048).write(to: old)
        // Older than the week a resumable part is kept for.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)],
            ofItemAtPath: old.path)

        _ = try VideoDownloader().download(url, into: importFolder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path),
                       "an abandoned partial file was kept for ever")
    }
}
