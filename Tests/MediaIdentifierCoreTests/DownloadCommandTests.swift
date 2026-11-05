import XCTest
@testable import MediaIdentifierCore

/// The yt-dlp command line and the progress parser.
///
/// Unlike the first version of the SSH work, the samples below are not what
/// the tool is *believed* to print: they were captured from yt-dlp 2026.10.26
/// downloading a real file over HTTP. Several of these assertions exist
/// because the documented behaviour and the measured behaviour differ.
final class DownloadCommandTests: XCTestCase {

    private let tools = DownloadTools(ytDlp: "/usr/local/bin/yt-dlp",
                                      ffmpeg: "/usr/bin/ffmpeg")
    /// A real folder: the builder checks that the import folder exists,
    /// because a path on an unmounted drive is the case that actually
    /// happens. (It used to check that the path was absolute, which
    /// URL(fileURLWithPath:) guarantees — a guard that could not fail.)
    private var importFolder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        importFolder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mediafin-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: importFolder,
                                                withIntermediateDirectories: true)
        // Last, after the coordinator exists: its init calls
        // Text.start from the settings it loads, which would
        // otherwise undo this.
        Text.language = .english
    }

    override func tearDownWithError() throws {
        Text.language = .german
        if let importFolder { try? FileManager.default.removeItem(at: importFolder) }
        try super.tearDownWithError()
    }

    private func build(_ url: String = "https://example.com/watch?v=abc")
        throws -> DownloadCommand.Invocation {
        try DownloadCommand.download(url: url, into: importFolder, tools: tools)
    }

    // MARK: What the arguments must contain

    /// The one that cost a measurement. `--print` implies `--quiet`, and
    /// `--quiet` turns the progress printer into a no-op — so a template
    /// without `--progress` emits nothing and is discarded in silence.
    func testProgressIsForcedBecausePrintingTurnsItOff() throws {
        let arguments = try build().arguments
        XCTAssertTrue(arguments.contains("--progress"),
                      "without this, --print-to-file silences the progress template")
        XCTAssertTrue(arguments.contains("--newline"),
                      "without this the output is one growing carriage-return blob")
    }

    /// Without the "?", an unknown duration is treated as a failure of the
    /// filter, and every direct link is refused — silently, with exit 0.
    func testTheDurationFilterToleratesAnUnknownDuration() throws {
        let arguments = try build()
        let filter = try XCTUnwrap(arguments.arguments.firstIndex(of: "--match-filters")
            .map { arguments.arguments[$0 + 1] })
        XCTAssertTrue(filter.contains("duration<?"),
                      "a filter without ? refuses every direct link: \(filter)")
        XCTAssertTrue(filter.contains("!is_live"))
    }

    /// It makes a successful download exit 101.
    func testMaxDownloadsIsNotUsed() throws {
        XCTAssertFalse(try build().arguments.contains("--max-downloads"))
    }

    /// A config file in the import folder is reachable by anything that can
    /// write there, and a config file may carry --exec, which runs through
    /// a shell. Demonstrated against the real binary.
    func testNothingOnDiskCanGiveTheProcessInstructions() throws {
        let arguments = try build().arguments
        for flag in ["--ignore-config", "--no-config-locations", "--no-plugin-dirs"] {
            XCTAssertTrue(arguments.contains(flag), "missing \(flag)")
        }
        XCTAssertFalse(arguments.contains("--exec"), "--exec runs through a shell")
        XCTAssertFalse(arguments.contains("--enable-file-urls"))
    }

    /// Everything of ours must precede the separator, or yt-dlp reads it as
    /// a URL instead of an option.
    func testTheURLComesLastAndBehindASeparator() throws {
        let arguments = try build("https://example.com/v/1").arguments
        XCTAssertEqual(arguments.last, "https://example.com/v/1")
        XCTAssertEqual(arguments[arguments.count - 2], "--")
        let separator = try XCTUnwrap(arguments.firstIndex(of: "--"))
        XCTAssertEqual(separator, arguments.count - 2,
                       "an option after -- is silently demoted to a URL")
    }

    /// The output template must be flat. sanitize_filename neutralises a
    /// slash inside one component; a field used as a directory is another
    /// matter, and a site title of ".." would then climb out.
    func testTheOutputTemplateHasNoDirectorySeparator() throws {
        let arguments = try build().arguments
        let template = try XCTUnwrap(arguments.firstIndex(of: "-o")
            .map { arguments[$0 + 1] })
        XCTAssertFalse(template.contains("/"), template)
    }

    /// A growing .part in the import folder would be scanned and proposed.
    func testPartialFilesLandInAHiddenStagingFolder() throws {
        let invocation = try build()
        XCTAssertEqual(invocation.stagingDirectory.lastPathComponent,
                       DownloadCommand.stagingFolderName)
        XCTAssertTrue(DownloadCommand.stagingFolderName.hasPrefix("."),
                      "the scanner skips hidden files; this one must be hidden")
        XCTAssertTrue(invocation.arguments.contains("temp:"
            + invocation.stagingDirectory.path))
        XCTAssertTrue(invocation.statusFile.path.hasPrefix(
            invocation.stagingDirectory.path), "the status file is not in the scanned folder")
    }

    /// "after_move:" is required: a bare filepath defaults to WHEN=video,
    /// which implies --simulate and downloads nothing.
    func testTheFinalPathIsAskedForAfterTheMove() throws {
        let arguments = try build().arguments
        let index = try XCTUnwrap(arguments.firstIndex(of: "--print-to-file"))
        XCTAssertEqual(arguments[index + 1], "after_move:filepath")
    }

    // MARK: What must be refused

    func testOnlyWebAddressesAreAccepted() {
        for bad in ["file:///etc/passwd", "data:text/plain;base64,aGk=",
                    "ftp://example.com/x.mp4", "/home/me/video.mp4", ""] {
            XCTAssertThrowsError(try DownloadCommand.validatedURL(bad), bad)
        }
        for good in ["http://127.0.0.1:18080/a.mp4", "https://example.com/watch?v=1",
                     "HTTPS://Example.COM/x"] {
            XCTAssertNoThrow(try DownloadCommand.validatedURL(good), good)
        }
    }

    func testAnAddressWithAControlCharacterIsRefused() {
        XCTAssertThrowsError(try DownloadCommand.validatedURL("https://example.com/a\nb"))
    }

    /// ffmpeg missing is a refusal, not a downgrade: without it yt-dlp
    /// quietly picks a pre-muxed stream and returns a worse file with
    /// exit 0.
    func testAMissingToolIsNamedWithWhatToInstall() {
        let none = DownloadTools(ytDlp: nil, ffmpeg: nil)
        XCTAssertEqual(none.missing(), ["yt-dlp", "ffmpeg"])

        let noFFmpeg = DownloadTools(ytDlp: "/usr/bin/yt-dlp", ffmpeg: nil)
        XCTAssertEqual(noFFmpeg.missing(), ["ffmpeg"])
        XCTAssertThrowsError(try DownloadCommand.download(
            url: "https://example.com/x", into: importFolder, tools: noFFmpeg)) { error in
            XCTAssertTrue("\(error)".contains("ffmpeg"), "\(error)")
        }
    }

    /// A library path on a drive that is no longer mounted: the folder is
    /// configured, looks fine in the form, and is not there.
    func testAnImportFolderThatIsNotThereStopsTheDownload() {
        XCTAssertThrowsError(try DownloadCommand.download(
            url: "https://example.com/x",
            into: URL(fileURLWithPath: "/mnt/nas-not-mounted/downloads"), tools: tools))
    }

    /// And a file where a folder should be.
    func testAFileWhereTheImportFolderShouldBeIsRefused() throws {
        let file = importFolder.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: file)
        XCTAssertThrowsError(try DownloadCommand.download(
            url: "https://example.com/x", into: file, tools: tools))
    }

    func testToolsAreLookedUpByAbsolutePath() {
        for path in DownloadTools.searchPaths {
            XCTAssertTrue(path.hasPrefix("/"), path)
        }
    }

    // MARK: Reading the progress

    /// Captured from a real run, tab-separated as the template produces.
    private func line(_ status: String, _ downloaded: String, _ total: String,
                      _ speed: String, _ eta: String) -> String {
        "\(DownloadCommand.progressMarker)\t\(status)\t\(downloaded)\t\(total)\t"
            + "\(speed)\t\(eta)"
    }

    func testAProgressLineIsRead() {
        let progress = VideoDownloader.parseProgress(
            line("downloading", "261120", "2772636", "409176.2354416249", "6"))
        XCTAssertEqual(progress?.fraction ?? 0, 0.0942, accuracy: 0.001)
        XCTAssertEqual(progress?.downloadedBytes, 261_120)
        XCTAssertEqual(progress?.totalBytes, 2_772_636)
        XCTAssertEqual(progress?.secondsRemaining, 6)
        XCTAssertFalse(progress?.isFinished ?? true)
    }

    /// yt-dlp's own chatter shares the stream, because --print-to-file does
    /// not imply --quiet. A line without the marker is not progress.
    func testTheToolsOwnChatterIsNotMistakenForProgress() {
        XCTAssertNil(VideoDownloader.parseProgress(
            "[download] Destination: /mnt/downloads/Sample.mp4"))
        XCTAssertNil(VideoDownloader.parseProgress("[generic] Extracting URL: http://x/y"))
        XCTAssertNil(VideoDownloader.parseProgress(
            "[download] 1.8% of 1.14GiB at 1.04MiB/s ETA 18:23"))
        XCTAssertNil(VideoDownloader.parseProgress(""))
    }

    /// Several updates arrive in one read; the last is the current state.
    func testTheLastRecordInAChunkWins() {
        let chunk = [
            "[download] Destination: /mnt/downloads/Sample.mp4",
            line("downloading", "1024", "2772636", "387457.5", "7"),
            line("downloading", "261120", "2772636", "409176.2", "6"),
            line("downloading", "2772636", "2772636", "409452.0", "0"),
        ].joined(separator: "\n")
        XCTAssertEqual(VideoDownloader.parseProgress(chunk)?.downloadedBytes, 2_772_636)
    }

    /// Without a Content-Length there is no total, and a bar would be a
    /// guess. nil, not zero — a caller showing 0 % reports progress that
    /// was never measured.
    func testAnUnknownTotalGivesNoFractionRatherThanZero() {
        let progress = VideoDownloader.parseProgress(
            line("downloading", "1048576", "NA", "409176.2", "NA"))
        XCTAssertNil(progress?.fraction)
        XCTAssertEqual(progress?.downloadedBytes, 1_048_576)
        XCTAssertNil(progress?.totalBytes)
        XCTAssertNil(progress?.secondsRemaining)
    }

    /// Every numeric field can be NA, including the byte count — that is
    /// what an already-downloaded file reports.
    func testARecordWhereEverythingIsUnknownStillParses() {
        let progress = VideoDownloader.parseProgress(
            line("finished", "NA", "2772636", "NA", "NA"))
        XCTAssertNotNil(progress)
        XCTAssertTrue(progress?.isFinished ?? false)
        XCTAssertNil(progress?.downloadedBytes)
    }

    /// yt-dlp prefixes "1: " to each line when several progress lines are
    /// active. Keying on the marker rather than the start of the line is
    /// what makes that harmless.
    func testALinePrefixedByYtDlpIsStillRead() {
        let progress = VideoDownloader.parseProgress(
            "1: " + line("downloading", "512", "1024", "100.0", "2"))
        XCTAssertEqual(progress?.fraction ?? 0, 0.5, accuracy: 0.001)
    }

    func testAFinishedRecordReadsAsComplete() {
        let progress = VideoDownloader.parseProgress(
            line("finished", "2772636", "2772636", "409190.3", "NA"))
        XCTAssertEqual(progress?.fraction, 1)
        XCTAssertTrue(progress?.isFinished ?? false)
    }

    // MARK: Error wording

    func testTheCommonFailuresSayWhatToDo() {
        XCTAssertTrue(VideoDownloader.explain("ERROR: Unsupported URL: http://x/y")
            .contains("nichts anfangen"))
        XCTAssertTrue(VideoDownloader.explain("ERROR: unable to download: HTTP Error 404")
            .contains("404"))
        XCTAssertTrue(VideoDownloader.explain(
            "ERROR: [Errno -2] Name or service not known").contains("auflösen"))
        // Anything unrecognised comes through unchanged.
        XCTAssertEqual(VideoDownloader.explain("  something else  "), "something else")
    }

    // MARK: Clearing the staging folder

    /// The other half of the rule: a partial young enough to be resumed is
    /// not thrown away, because discarding one turns a cancelled download of
    /// twenty gigabytes into twenty gigabytes to fetch again.
    func testARecentPartialIsKeptForAResume() throws {
        let staging = importFolder.appendingPathComponent("staging-rule-check")
        try FileManager.default.createDirectory(at: staging,
                                                withIntermediateDirectories: true)
        let recent = staging.appendingPathComponent("in-flight.mkv.part")
        try Data(repeating: 0, count: 16).write(to: recent)

        VideoDownloader.sweepStaging(staging,
                                     keeping: staging.appendingPathComponent("path.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    /// And the first half: nothing ever deleted these, and the folder is
    /// hidden, so a few cancelled downloads of large files sat in the import
    /// folder for good.
    func testAPartialTooOldToBeWantedIsSweptAway() throws {
        let staging = importFolder.appendingPathComponent("staging-age-check")
        try FileManager.default.createDirectory(at: staging,
                                                withIntermediateDirectories: true)
        let abandoned = staging.appendingPathComponent("abandoned.mkv.part")
        try Data(repeating: 0, count: 16).write(to: abandoned)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 3600)],
            ofItemAtPath: abandoned.path)

        VideoDownloader.sweepStaging(staging,
                                     keeping: staging.appendingPathComponent("path.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
    }

    /// The path file is this run's result and is read right after the sweep.
    func testTheSweepNeverTakesThePathFile() throws {
        let staging = importFolder.appendingPathComponent("staging-keep-check")
        try FileManager.default.createDirectory(at: staging,
                                                withIntermediateDirectories: true)
        let keep = staging.appendingPathComponent("last-download-path.txt")
        try Data("x".utf8).write(to: keep)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-99 * 24 * 3600)],
            ofItemAtPath: keep.path)

        VideoDownloader.sweepStaging(staging, keeping: keep)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
    }

    /// The sweep must not take a partial that belongs to a different URL:
    /// only the names this run produced, which all begin with the final
    /// file's stem.
    func testFinishingOneDownloadDoesNotDeleteAnotherPartial() throws {
        let staging = importFolder.appendingPathComponent("leftover-rule-check")
        try FileManager.default.createDirectory(at: staging,
                                                withIntermediateDirectories: true)
        let mine = staging.appendingPathComponent("ID_Title.f399.mp4.part")
        let other = staging.appendingPathComponent("OTHER_Film.mkv.part")
        try Data("a".utf8).write(to: mine)
        try Data("b".utf8).write(to: other)

        VideoDownloader.sweepLeftovers(
            of: staging.appendingPathComponent("ID_Title.mkv"), in: staging)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mine.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path),
                      "a partial from another download was destroyed")
    }

    // MARK: One answer about ffmpeg

    /// The locators disagreed: this one looked in four directories and
    /// `FFmpegLocator` in six, in a different order. On a snap or flatpak
    /// install the traffic light said ffmpeg was found while the download
    /// refused for want of it, and where both found one they could be
    /// different binaries.
    func testFFmpegComesFromTheOneLocatorEveryoneElseUses() {
        let located = DownloadTools.locate()
        XCTAssertEqual(located.ffmpeg, FFmpegLocator.locate(),
                       "the download and the rest of the program disagree about ffmpeg")
    }

    /// A user who sets ffmpeg for conversion means that ffmpeg.
    func testAConfiguredFFmpegPathIsUsedForTheDownloadToo() {
        // /bin/sh is executable on both platforms, so this is asserted
        // rather than skipped. `XCTSkipUnless` would be the natural way to
        // guard it and is inverted under swift-corelibs-xctest — it skips
        // when the condition holds — which is how five injection tests came
        // to skip themselves while reporting success.
        let shell = "/bin/sh"
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: shell))
        XCTAssertEqual(DownloadTools.locate(configuredFFmpeg: shell).ffmpeg, shell)
    }

    /// A configured path that is not there must read as missing, or
    /// `missing()` would report ffmpeg present and yt-dlp would be handed a
    /// path to nothing.
    func testAConfiguredPathThatIsNotThereCountsAsMissing() {
        let located = DownloadTools.locate(configuredFFmpeg: "/nowhere/ffmpeg")
        XCTAssertNil(located.ffmpeg)
        XCTAssertTrue(located.missing().contains("ffmpeg"))
    }
}
