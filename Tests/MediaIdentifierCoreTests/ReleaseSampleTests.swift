import XCTest
@testable import MediaIdentifierCore

/// The thirty-second excerpt a scene release ships beside the film.
///
/// The bug this suite exists for is not clutter. The sample is a video
/// file, so the folder scan proposed it as a film of its own; its name
/// parses to the same episode as the real file, so both rows wanted the
/// same destination; the pair was refused as a duplicate — and neither
/// file was renamed. A release with a sample beside it did nothing at all.
final class ReleaseSampleTests: XCTestCase {

    private var root: URL!
    private var library: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        Text.language = .german
        root = fm.temporaryDirectory
            .appendingPathComponent("mediafin-sample-\(UUID().uuidString)")
        library = root.appendingPathComponent("Serien")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    // MARK: Recognising one

    func testTheFormsAReleaseActuallyUsesAreRecognised() {
        for name in ["Fargo.S05E10.1080p.WEB.H264-GROUP-sample.mkv",
                     "Fargo.S05E10.1080p.WEB.H264-GROUP.sample.mkv",
                     "Fargo.S05E10.1080p.WEB.H264-GROUP_sample.mkv",
                     "Fargo S05E10 1080p sample.mkv",
                     "sample.mkv",
                     "Sample.avi",
                     "samples.mkv",
                     "Release.Folder/Sample/whatever.mkv",
                     "Release.Folder/samples/anything-at-all.mkv"] {
            XCTAssertTrue(
                VideoFileTypes.isSample(URL(fileURLWithPath: "/x/" + name)), name)
        }
    }

    /// The mistake that matters. Calling a sample a film puts a duplicate in
    /// the library; calling a film a sample makes it vanish from the list
    /// with nothing said — and both of these are real films.
    func testRealFilmsWithSampleInTheirNameAreNotSamples() {
        for name in ["Free.Samples.2012.1080p.BluRay.x264-GROUP.mkv",
                     "Sample.People.2000.720p.WEB-DL.mkv",
                     "Sample People (2000)/Sample People (2000).mkv",
                     "The.Sample.Collector.2019.1080p.mkv",
                     "Samples.of.Life.S01E02.mkv"] {
            XCTAssertFalse(
                VideoFileTypes.isSample(URL(fileURLWithPath: "/x/" + name)), name)
        }
    }

    /// It used to be a bare `contains`, which also made a subtitle whose
    /// name ended in "sample" a sample rather than a subtitle.
    func testTheRoleIsStillRightForEverythingElse() {
        func role(_ name: String) -> CompanionFile.Role {
            VideoFileTypes.role(for: URL(fileURLWithPath: "/x/" + name))
        }
        XCTAssertEqual(role("Free.Samples.2012.en.srt"), .subtitle)
        XCTAssertEqual(role("Free.Samples.2012.nfo"), .nfo)
        XCTAssertEqual(role("Free.Samples.2012-poster.jpg"), .image)
        XCTAssertEqual(role("Fargo.S05E10-sample.mkv"), .sample)
    }

    // MARK: The bug, end to end

    /// One row, not two, and the one that is there is the film.
    func testAReleaseWithASampleBesideItProducesOneProposalForTheFilm() throws {
        try write("Downloads/Fargo.S05E10.1080p.WEB.H264-GROUP.mkv")
        try write("Downloads/Fargo.S05E10.1080p.WEB.H264-GROUP-sample.mkv")

        let found = MediaScanner().scan(urls: [root.appendingPathComponent("Downloads")])
        XCTAssertEqual(found.count, 1, "the sample was proposed as a film of its own")
        XCTAssertEqual(found.first?.url.lastPathComponent,
                       "Fargo.S05E10.1080p.WEB.H264-GROUP.mkv")
    }

    /// The consequence, stated on its own: with two rows wanting one name
    /// the pair was refused and nothing moved.
    func testTheFilmIsNoLongerRefusedAsADuplicateOfItsOwnSample() throws {
        try write("Downloads/Fargo.S05E10.1080p.WEB.H264-GROUP.mkv")
        try write("Downloads/Fargo.S05E10.1080p.WEB.H264-GROUP-sample.mkv")

        let found = MediaScanner().scan(urls: [root.appendingPathComponent("Downloads")])
        let plan = RenamePlanner().makePlan(for: found, outputRoot: library)
        XCTAssertEqual(plan.count, 1)
        XCTAssertNil(plan.first?.conflict,
                     "the film still collides with something")
    }

    /// FolderScan is what the window's Scan button and the unattended run
    /// both use, so the rule has to hold there too and not only in the
    /// scanner.
    func testTheFolderScanSkipsSamplesAsWell() throws {
        try write("Downloads/Tenet.2020.1080p.BluRay.x264-GROUP.mkv")
        try write("Downloads/Tenet.2020.1080p.BluRay.x264-GROUP-sample.mkv")
        try write("Downloads/Sample/sample.mkv")

        let urls = AppCoordinator.FolderScan.videoFiles(
            under: root.appendingPathComponent("Downloads"))
        XCTAssertEqual(urls.map(\.lastPathComponent),
                       ["Tenet.2020.1080p.BluRay.x264-GROUP.mkv"])
    }

    /// Nobody is looking at an unattended run, so a sample picked up by the
    /// watcher would collide with the real file in the dark.
    func testTheWatcherSkipsSamplesToo() throws {
        let folder = root.appendingPathComponent("Watched")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("Watched/Dark.S01E01.1080p-GROUP.mkv")
        try write("Watched/Dark.S01E01.1080p-GROUP-sample.mkv")

        let scanner = WatchFolderScanner()
        // Twice: the watcher only reports a file whose size was the same
        // last time round, so one poll reports nothing by design.
        _ = scanner.poll(directory: folder)
        let stable = scanner.poll(directory: folder)
        XCTAssertEqual(stable.map(\.lastPathComponent),
                       ["Dark.S01E01.1080p-GROUP.mkv"])
    }

    // MARK: Where it ends up

    /// Not moved and not deleted. It is a video file, and leaving it where
    /// it is keeps it out of the library without destroying anything.
    func testTheSampleIsNeitherMovedNorDeleted() throws {
        let film = try write("Downloads/Fargo.S05E10.1080p.WEB.H264-GROUP.mkv")
        let sample = try write("Downloads/Fargo.S05E10.1080p.WEB.H264-GROUP-sample.mkv")

        let file = MediaScanner().mediaFile(for: film)
        // Still collected, so the row can say where it stays.
        XCTAssertEqual(file.companions.filter { $0.role == .sample }.count, 1)

        let plan = RenamePlanner().makePlan(for: [file], outputRoot: library)
        let item = try XCTUnwrap(plan.first)
        XCTAssertFalse(item.allMoves.contains { $0.source == sample },
                       "the sample is still planned to move")
        XCTAssertFalse(item.companionDeletions.contains(sample),
                       "the sample is on the deletion list, which is for notes")

        let log = RenameLog(url: root.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: root.appendingPathComponent("journal.json"))
        let outcome = RenameExecutor(log: log, journal: journal)
            .execute(plan: plan, policy: .skip)

        XCTAssertEqual(outcome.succeeded, 1, "only the film moved")
        XCTAssertTrue(fm.fileExists(atPath: sample.path), "the sample was destroyed")
        XCTAssertTrue(fm.fileExists(atPath: item.primaryDestination.path))
        XCTAssertFalse(
            fm.fileExists(atPath: item.primaryDestination
                .deletingLastPathComponent()
                .appendingPathComponent("Fargo - S05E10.-sample.mkv").path),
            "the old mangled name is back in the library")
    }

    /// A sample handed over directly is honoured: then somebody meant that
    /// file, and silently ignoring it would be the window doing nothing with
    /// no explanation, which is the complaint this program keeps earning.
    func testASampleHandedOverDirectlyIsStillAccepted() throws {
        let sample = try write("Downloads/Fargo.S05E10-sample.mkv")
        let found = MediaScanner().scan(urls: [sample])
        XCTAssertEqual(found.count, 1,
                       "a file pointed at directly was ignored without a word")
    }
}
