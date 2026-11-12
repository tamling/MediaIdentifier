import XCTest
@testable import MediaIdentifierCore

/// Tests that the commands the interface submits actually do something: real
/// files on disk get scanned, renamed and undone, and settings and secrets
/// survive.
final class AppCoordinatorTests: XCTestCase {

    private var root: URL!
    private var config: URL!
    private var source: URL!
    private var movies: URL!
    private var series: URL!
    private var coordinator: AppCoordinator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mediafin-coordinator-\(UUID().uuidString)")
        config = root.appendingPathComponent("config")
        source = root.appendingPathComponent("downloads")
        movies = root.appendingPathComponent("library/Movies")
        series = root.appendingPathComponent("library/Series")
        for directory in [config!, source!, movies!, series!] {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        }
        coordinator = AppCoordinator(configDirectory: config)
        // Last, after the coordinator exists: its init calls
        // Text.start from the settings it loads, which would
        // otherwise undo this.
        Text.language = .english
    }

    override func tearDownWithError() throws {
        Text.language = .german
        coordinator = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func makeFile(_ name: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? source).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not really a video".utf8).write(to: url)
        return url
    }

    private func configuredSettings() -> WebSettings {
        WebSettings(sourceFolder: source.path,
                    moviesFolder: movies.path,
                    seriesFolder: series.path,
                    // The language comes through the settings, not through a
                    // global assignment in setUp: AppCoordinator.init calls
                    // Text.start from the settings it loads, so every
                    // coordinator built afterwards would undo such an
                    // assignment. This is also the path the program really
                    // uses, which makes it worth asserting through.
                    identification: .offline,
                    conflictPolicy: .rename,
                    language: .english)
    }

    private func run(_ command: WebCommand) {
        coordinator.executeForTesting(command)
    }

    // MARK: Settings and secrets

    func testSavingSettingsPersistsThemForTheNextStart() {
        run(.saveSettings(configuredSettings()))
        XCTAssertEqual(coordinator.settings.sourceFolder, source.path)

        let restarted = AppCoordinator(configDirectory: config)
        XCTAssertEqual(restarted.settings.moviesFolder, movies.path)
        XCTAssertEqual(restarted.settings.conflictPolicy, .rename)
    }

    func testSecretsAreStoredAndOnlyReportedAsPresent() {
        run(.setSecret(.localLLMAPIKey, "sk-local-123"))
        XCTAssertEqual(coordinator.configuredSecrets, [.localLLMAPIKey])
        // The value must not surface in anything the interface can read.
        XCTAssertFalse((coordinator.snapshot.lastResult ?? "").contains("sk-local-123"))

        run(.setSecret(.localLLMAPIKey, ""))
        XCTAssertTrue(coordinator.configuredSecrets.isEmpty)
    }

    // MARK: Scanning

    func testScanFindsVideosAndProposesJellyfinNames() throws {
        _ = try makeFile("The.Matrix.1999.1080p.BluRay.x264-GRP.mkv")
        _ = try makeFile("the.last.of.us.s01e03.1080p.web.h264.mkv")
        _ = try makeFile("notes.txt")
        run(.saveSettings(configuredSettings()))
        run(.scanSourceFolder)

        let items = coordinator.items
        XCTAssertEqual(items.count, 2, "only the two videos, not the text file")
        XCTAssertEqual(coordinator.snapshot.totalItems, 2)
        XCTAssertFalse(coordinator.snapshot.busy, "the scan must finish, not stay busy")

        let paths = items.map(\.proposedRelativePath).sorted()
        XCTAssertTrue(paths.contains { $0.contains("The Matrix (1999)") }, "\(paths)")
        XCTAssertTrue(paths.contains { $0.contains("S01E03") }, "\(paths)")
    }

    func testEpisodesAndMoviesGetTheirOwnLibraryRoot() throws {
        _ = try makeFile("The.Matrix.1999.mkv")
        _ = try makeFile("the.last.of.us.s01e03.mkv")
        run(.saveSettings(configuredSettings()))
        run(.scanSourceFolder)

        for item in coordinator.items {
            let expected = item.mediaFile.parsed.kind == .episode ? series! : movies!
            XCTAssertEqual(item.outputRoot.standardizedFileURL.path,
                           expected.standardizedFileURL.path,
                           item.originalFileName)
        }
    }

    func testScanInSubfoldersAndIgnoresNonVideo() throws {
        _ = try makeFile("season1/Show.S01E01.mkv")
        _ = try makeFile("cover.jpg")
        run(.saveSettings(configuredSettings()))
        run(.scanSourceFolder)
        XCTAssertEqual(coordinator.items.count, 1)
    }

    func testScanWithoutASourceFolderSaysSoInsteadOfFailing() {
        run(.scanSourceFolder)
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("import folder"),
                      coordinator.snapshot.lastResult ?? "nil")
        XCTAssertFalse(coordinator.snapshot.busy)
    }

    func testScanOfAMissingFolderIsReportedNotCrashed() {
        var settings = configuredSettings()
        settings.sourceFolder = root.appendingPathComponent("does-not-exist").path
        run(.saveSettings(settings))
        run(.scanSourceFolder)
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("does not exist"),
                      coordinator.snapshot.lastResult ?? "nil")
    }

    func testEmptyFolderIsReportedClearly() {
        run(.saveSettings(configuredSettings()))
        run(.scanSourceFolder)
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("No video files"),
                      coordinator.snapshot.lastResult ?? "nil")
        XCTAssertTrue(coordinator.items.isEmpty)
    }

    // MARK: Renaming

    func testApplyMovesTheFilesAndReportsTheOutcome() throws {
        let original = try makeFile("The.Matrix.1999.1080p.mkv")
        run(.saveSettings(configuredSettings()))
        run(.scanSourceFolder)
        let destination = try XCTUnwrap(coordinator.items.first).primaryDestination

        run(.applyProposedRenames(accepting: nil))

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path),
                      "expected the file at \(destination.path)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path),
                       "the original must have been moved, not copied")
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("Renamed 1"),
                      coordinator.snapshot.lastResult ?? "nil")
        XCTAssertFalse(coordinator.snapshot.renaming)
        XCTAssertFalse(coordinator.snapshot.hasError)
        XCTAssertTrue(coordinator.items.isEmpty, "the plan is spent once applied")
    }

    func testApplyWithNothingScannedSaysSo() {
        run(.saveSettings(configuredSettings()))
        run(.applyProposedRenames(accepting: nil))
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("Nothing to rename"),
                      coordinator.snapshot.lastResult ?? "nil")
    }

    func testUndoPutsTheFileBack() throws {
        let original = try makeFile("The.Matrix.1999.mkv")
        run(.saveSettings(configuredSettings()))
        run(.scanSourceFolder)
        run(.applyProposedRenames(accepting: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))

        run(.undoLastRename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path),
                      "undo must restore the original location")
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("back"),
                      coordinator.snapshot.lastResult ?? "nil")
    }

    func testUndoWithNothingToUndoIsHarmless() {
        run(.undoLastRename)
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("nothing to undo"),
                      coordinator.snapshot.lastResult ?? "nil")
    }

    func testHistoryIsRecordedAndCanBeCleared() throws {
        _ = try makeFile("The.Matrix.1999.mkv")
        run(.saveSettings(configuredSettings()))
        run(.scanSourceFolder)
        run(.applyProposedRenames(accepting: nil))
        XCTAssertFalse(coordinator.logEntries.isEmpty)

        run(.clearHistory)
        XCTAssertTrue(coordinator.logEntries.isEmpty)
        XCTAssertEqual(coordinator.snapshot.done, 0)
    }

    // MARK: Connection tests

    func testTestingTheModelServerWithoutSettingsAsksForThemFirst() {
        run(.testLocalLLMConnection)
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("address"),
                      coordinator.snapshot.lastResult ?? "nil")
    }

    func testTestingAnUnreachableModelServerReportsTheReason() {
        var settings = configuredSettings()
        settings.identification = .localLLM
        // Port 1 on loopback: nothing listens, so this fails fast.
        settings.localLLMBaseURL = "http://127.0.0.1:1"
        settings.localLLMModel = "test-model"
        run(.saveSettings(settings))
        run(.testLocalLLMConnection)

        let result = coordinator.snapshot.lastResult ?? ""
        XCTAssertTrue(result.contains("could not be reached"), result)
        XCTAssertTrue(result.contains("["), "the numeric code must be shown: \(result)")
    }

    func testJellyfinTestWithoutAKeyAsksForIt() {
        var settings = configuredSettings()
        settings.jellyfinBaseURL = "http://127.0.0.1:8096"
        run(.saveSettings(settings))
        run(.testJellyfinConnection)
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("API key"),
                      coordinator.snapshot.lastResult ?? "nil")
    }

    func testStatusDescriptionsAreActionable() {
        XCTAssertTrue(AppCoordinator.describe(status: 200, service: "model server")
            .contains("works"))
        XCTAssertTrue(AppCoordinator.describe(status: 401, service: "Jellyfin")
            .contains("API key"))
        XCTAssertTrue(AppCoordinator.describe(status: 404, service: "Jellyfin")
            .contains("URL"))
    }

    // MARK: Providers

    func testOfflineIdentificationMakesNoProvider() {
        var settings = configuredSettings()
        settings.identification = .offline
        XCTAssertNil(coordinator.enrichmentProvider(settings),
                     "nothing may leave the machine in offline mode")
    }

    func testLocalLLMProviderNeedsBothAddressAndModel() {
        var settings = configuredSettings()
        settings.identification = .localLLM
        settings.localLLMBaseURL = "http://127.0.0.1:1234"
        XCTAssertNil(coordinator.localLLMProvider(settings), "a model name is required")
        settings.localLLMModel = "qwen/qwen3.6-35b-a3b"
        XCTAssertNotNil(coordinator.localLLMProvider(settings))
    }

    func testTMDbNeedsItsKeyBeforeItIsUsed() {
        var settings = configuredSettings()
        settings.identification = .tmdb
        XCTAssertNil(coordinator.enrichmentProvider(settings))
        run(.setSecret(.tmdbAPIKey, "some-key"))
        XCTAssertNotNil(coordinator.enrichmentProvider(settings))
    }

    // MARK: Converting

    func testConvertingNeedsLibraryFoldersFirst() {
        run(.findConvertible)
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("library folders"),
                      coordinator.snapshot.lastResult ?? "nil")
    }

    func testNothingTickedConvertsNothing() {
        run(.saveSettings(configuredSettings()))
        run(.convertFiles(accepting: []))
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("No files were ticked"),
                      coordinator.snapshot.lastResult ?? "nil")
        XCTAssertFalse(coordinator.snapshot.converting)
    }

    // MARK: Folder scan limits

    func testFolderScanIsSortedAndSkipsHiddenFiles() throws {
        _ = try makeFile("b.mkv")
        _ = try makeFile("a.mkv")
        _ = try makeFile(".hidden.mkv")
        let found = AppCoordinator.FolderScan.videoFiles(under: source)
        XCTAssertEqual(found.map(\.lastPathComponent), ["a.mkv", "b.mkv"])
    }

    // MARK: Files handed over one at a time (drag and drop)

    /// Sorting is pure, so these need no disk at all — which is the point of
    /// having split it out: the rules are where the mistakes are.
    func testHandedOverFilesAreSortedByWhatTheyAre() {
        let handed = [URL(fileURLWithPath: "/x/Dark.S01E01.mkv"),
                      URL(fileURLWithPath: "/x/01 - Song.flac"),
                      URL(fileURLWithPath: "/x/notes.pdf")]
        let sorted = AppCoordinator.sorting(handed, isDirectory: { _ in false },
                                            videosIn: { _ in [] }, audioIn: { _ in [] })
        XCTAssertEqual(sorted.videos.map(\.lastPathComponent), ["Dark.S01E01.mkv"])
        XCTAssertEqual(sorted.audio.map(\.lastPathComponent), ["01 - Song.flac"])
        XCTAssertEqual(sorted.ignored.map(\.lastPathComponent), ["notes.pdf"])
    }

    /// A folder is what people drop when they mean "this whole series".
    func testAFolderIsExpanded() {
        let folder = URL(fileURLWithPath: "/x/Dark")
        let sorted = AppCoordinator.sorting(
            [folder],
            isDirectory: { $0 == folder },
            videosIn: { _ in [URL(fileURLWithPath: "/x/Dark/e1.mkv"),
                              URL(fileURLWithPath: "/x/Dark/e2.mkv")] },
            audioIn: { _ in [URL(fileURLWithPath: "/x/Dark/theme.flac")] })
        XCTAssertEqual(sorted.videos.count, 2)
        XCTAssertEqual(sorted.audio.count, 1)
        XCTAssertTrue(sorted.ignored.isEmpty)
    }

    /// Dropping a file and the folder it is in, together, is one file. Two
    /// proposals for it would both be ticked and race each other into the
    /// same destination.
    func testTheSameFileHandedOverTwiceIsTakenOnce() {
        let folder = URL(fileURLWithPath: "/x/Dark")
        let file = URL(fileURLWithPath: "/x/Dark/e1.mkv")
        let sorted = AppCoordinator.sorting(
            [file, folder, file],
            isDirectory: { $0 == folder },
            videosIn: { _ in [file] }, audioIn: { _ in [] })
        XCTAssertEqual(sorted.videos, [file])
    }

    /// Adding keeps what is already listed. A drop that cleared the list
    /// would lose the twenty proposals being worked through.
    func testAddingFilesKeepsWhatIsAlreadyListed() throws {
        run(.saveSettings(configuredSettings()))
        _ = try makeFile("Dark.S01E01.1080p.mkv")
        run(.scanSourceFolder)
        XCTAssertEqual(coordinator.items.count, 1)

        // From somewhere the import folder knows nothing about.
        let elsewhere = root.appendingPathComponent("elsewhere")
        let dropped = try makeFile("Tenet.2020.1080p.mkv", in: elsewhere)
        run(.addFiles([dropped]))

        XCTAssertEqual(coordinator.items.count, 2, coordinator.snapshot.lastResult ?? "")
        XCTAssertTrue(coordinator.items.contains { $0.mediaFile.url == dropped })
    }

    /// And it does not need the import folder at all: the file somebody
    /// pointed at is the file they mean.
    func testAddingFilesWorksWithNoImportFolderSet() throws {
        var settings = configuredSettings()
        settings.sourceFolder = ""
        run(.saveSettings(settings))

        let elsewhere = root.appendingPathComponent("elsewhere")
        let dropped = try makeFile("Tenet.2020.1080p.mkv", in: elsewhere)
        run(.addFiles([dropped]))
        XCTAssertEqual(coordinator.items.count, 1, coordinator.snapshot.lastResult ?? "")
        XCTAssertFalse(coordinator.snapshot.hasError)
    }

    func testDroppingTheSameFileTwiceDoesNotListItTwice() throws {
        run(.saveSettings(configuredSettings()))
        let dropped = try makeFile("Tenet.2020.1080p.mkv")
        run(.addFiles([dropped]))
        run(.addFiles([dropped]))
        XCTAssertEqual(coordinator.items.count, 1)
        XCTAssertTrue(
            (coordinator.snapshot.lastResult ?? "").contains("already listed"),
            coordinator.snapshot.lastResult ?? "")
    }

    /// Dropping something that is not media says so rather than appearing to
    /// have worked.
    func testDroppingSomethingThatIsNotMediaSaysSo() throws {
        run(.saveSettings(configuredSettings()))
        let text = try makeFile("notes.pdf")
        run(.addFiles([text]))
        XCTAssertTrue(coordinator.items.isEmpty)
        XCTAssertTrue(coordinator.snapshot.hasError)
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("no video"),
                      coordinator.snapshot.lastResult ?? "")
    }

    /// A dropped file that would land on a proposal already listed is the
    /// collision worth warning about, so conflicts are recomputed across the
    /// whole list rather than only within what just arrived.
    func testADroppedFileCollidingWithAListedProposalIsFlagged() throws {
        run(.saveSettings(configuredSettings()))
        _ = try makeFile("Tenet.2020.1080p.mkv")
        run(.scanSourceFolder)

        // The same film by another release name: the planner resolves both to
        // one destination.
        let other = root.appendingPathComponent("elsewhere")
        let dropped = try makeFile("Tenet.2020.720p.mkv", in: other)
        run(.addFiles([dropped]))

        XCTAssertEqual(coordinator.items.count, 2)
        XCTAssertTrue(coordinator.items.allSatisfy { $0.conflict == .duplicateInBatch },
                      coordinator.items.map { "\($0.newFileName) \(String(describing: $0.conflict))" }
                        .joined(separator: ", "))
    }

}

/// Tests the watch folder: that it starts and stops with the setting, that it
/// only offers new files, and that it never renames on its own.
final class WatchFolderTests: XCTestCase {

    private var root: URL!
    private var config: URL!
    private var source: URL!
    private var movies: URL!
    private var coordinator: AppCoordinator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mediafin-watch-\(UUID().uuidString)")
        config = root.appendingPathComponent("config")
        source = root.appendingPathComponent("downloads")
        movies = root.appendingPathComponent("Movies")
        for directory in [config!, source!, movies!] {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        }
        coordinator = AppCoordinator(configDirectory: config, watchInterval: 1)
        // Last, after the coordinator exists: its init calls
        // Text.start from the settings it loads, which would
        // otherwise undo this.
        Text.language = .english
    }

    override func tearDownWithError() throws {
        Text.language = .german
        coordinator = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func settings(watching: Bool) -> WebSettings {
        WebSettings(sourceFolder: source.path, moviesFolder: movies.path,
                    identification: .offline, watchSourceFolder: watching,
                    language: .english)
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = source.appendingPathComponent(name)
        try Data("not really a video".utf8).write(to: url)
        return url
    }

    func testWatchingFollowsTheSetting() {
        XCTAssertFalse(coordinator.isWatching, "off by default")

        coordinator.executeForTesting(.saveSettings(settings(watching: true)))
        XCTAssertTrue(coordinator.isWatching)
        XCTAssertTrue(coordinator.snapshot.watchActive)

        coordinator.executeForTesting(.saveSettings(settings(watching: false)))
        XCTAssertFalse(coordinator.isWatching)
        XCTAssertFalse(coordinator.snapshot.watchActive)
    }

    func testWatchingNeedsAnImportFolder() {
        var incomplete = settings(watching: true)
        incomplete.sourceFolder = ""
        coordinator.executeForTesting(.saveSettings(incomplete))
        XCTAssertFalse(coordinator.isWatching, "there is nothing to watch")
    }

    func testANewFileIsProposedButNotRenamed() throws {
        coordinator.executeForTesting(.saveSettings(settings(watching: true)))
        let original = try makeFile("The.Matrix.1999.1080p.mkv")

        // A file is only offered once its size has been stable across two
        // polls, so that a download still being written is not picked up.
        coordinator.pollWatchFolderForTesting()
        XCTAssertTrue(coordinator.items.isEmpty, "not offered until the size has settled")
        coordinator.pollWatchFolderForTesting()

        XCTAssertEqual(coordinator.items.count, 1, "the new file should be proposed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path),
                      "watching must never move a file on its own")
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("waiting for you"),
                      coordinator.snapshot.lastResult ?? "nil")
    }

    func testTheSameFileIsNotOfferedTwice() throws {
        coordinator.executeForTesting(.saveSettings(settings(watching: true)))
        _ = try makeFile("The.Matrix.1999.mkv")

        coordinator.pollWatchFolderForTesting()   // establishes the size
        coordinator.pollWatchFolderForTesting()   // size stable → offered
        XCTAssertTrue((coordinator.snapshot.lastResult ?? "").contains("appeared"),
                      coordinator.snapshot.lastResult ?? "nil")

        // Replace the message, so a second report would be visible.
        coordinator.executeForTesting(.undoLastRename)
        // Further polls find nothing new, so they must not report anything.
        coordinator.pollWatchFolderForTesting()
        coordinator.pollWatchFolderForTesting()
        XCTAssertFalse((coordinator.snapshot.lastResult ?? "").contains("appeared"),
                       coordinator.snapshot.lastResult ?? "nil")
    }

    /// The point of the two-poll rule: a file still being written must not be
    /// picked up half-downloaded.
    func testAGrowingFileIsNotOfferedUntilItStops() throws {
        coordinator.executeForTesting(.saveSettings(settings(watching: true)))
        let url = try makeFile("The.Matrix.1999.mkv")

        coordinator.pollWatchFolderForTesting()
        try Data("still downloading…".utf8).write(to: url)   // size changed
        coordinator.pollWatchFolderForTesting()
        XCTAssertTrue(coordinator.items.isEmpty, "a growing file must not be offered")

        coordinator.pollWatchFolderForTesting()              // size now stable
        XCTAssertEqual(coordinator.items.count, 1)
    }

    func testNonVideoFilesAreIgnored() throws {
        coordinator.executeForTesting(.saveSettings(settings(watching: true)))
        _ = try makeFile("readme.txt")
        coordinator.pollWatchFolderForTesting()
        coordinator.pollWatchFolderForTesting()
        XCTAssertTrue(coordinator.items.isEmpty)
        XCTAssertFalse((coordinator.snapshot.lastResult ?? "").contains("appeared"))
    }

    func testPollingDoesNothingWhenWatchingIsOff() throws {
        coordinator.executeForTesting(.saveSettings(settings(watching: false)))
        _ = try makeFile("The.Matrix.1999.mkv")
        coordinator.pollWatchFolderForTesting()
        coordinator.pollWatchFolderForTesting()
        XCTAssertTrue(coordinator.items.isEmpty)
    }

    // MARK: The watch lamp

    /// `updateWatchState` sets this from whether the timer is really armed,
    /// and `refreshSnapshotCounts` ran after it and wrote the raw setting
    /// back — so with watching on and no import folder, nothing was polled
    /// while the status row and every lamp said "active". The sibling test
    /// asserts `isWatching` only, so it passed throughout.
    func testTheWatchLampSaysWhatIsActuallyBeingWatched() {
        var incomplete = settings(watching: true)
        incomplete.sourceFolder = ""
        coordinator.executeForTesting(.saveSettings(incomplete))
        XCTAssertFalse(coordinator.isWatching)
        XCTAssertFalse(coordinator.snapshot.watchActive,
                       "the interface claimed the import folder was being watched")

        coordinator.executeForTesting(.saveSettings(settings(watching: true)))
        XCTAssertTrue(coordinator.isWatching)
        XCTAssertTrue(coordinator.snapshot.watchActive)
    }

}
