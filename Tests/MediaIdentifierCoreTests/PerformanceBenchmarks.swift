import XCTest
@testable import MediaIdentifierCore

/// What the slow parts actually cost, measured rather than reasoned about.
///
/// Every number here was produced on a real toolchain in this repository;
/// the ceilings are deliberately loose — several times the measured value —
/// because the point is to catch an algorithm going quadratic again, not to
/// fail when a runner is busy.
///
/// Run on its own with:
///     swift test -c release --filter PerformanceBenchmarks
final class PerformanceBenchmarks: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        Text.language = .german
        root = fm.temporaryDirectory
            .appendingPathComponent("mediafin-bench-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func populate(_ count: Int, companions: Bool) throws -> URL {
        let folder = root.appendingPathComponent("downloads")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<count {
            let stem = String(format: "Show.S%02dE%02d.1080p.WEB.H264-GRP",
                              index / 100 + 1, index % 100 + 1)
            try Data("x".utf8).write(to: folder.appendingPathComponent(stem + ".mkv"))
            if companions {
                try Data("x".utf8).write(
                    to: folder.appendingPathComponent(stem + ".en.srt"))
                try Data("x".utf8).write(
                    to: folder.appendingPathComponent(stem + ".nfo"))
            }
        }
        return folder
    }

    private func seconds(_ label: String, _ work: () throws -> Void) rethrows {
        let started = Date()
        try work()
        let took = Date().timeIntervalSince(started)
        // Not String(format: "%s"): that is C varargs, a Swift String
        // passed to it prints nothing, and the first run of this file
        // produced six timings with no labels.
        let padded = label.padding(toLength: max(label.count, 34),
                                   withPad: " ", startingAt: 0)
        print("BENCH \(padded) \(String(format: "%7.3f", took)) s")
    }

    /// Sizes to measure. The default is what CI runs; set
    /// MEDIAFIN_BENCH_FULL=1 for the whole curve up to the 5,000-file
    /// ceiling the program enforces, which takes about ten seconds.
    private static var full: Bool {
        ProcessInfo.processInfo.environment["MEDIAFIN_BENCH_FULL"] == "1"
    }

    /// Sizes to measure.
    ///
    /// CI stops at 500 on purpose. Most of the time here goes on creating
    /// the files, not on measuring, and 500 is already enough to catch the
    /// regression: the old code took 10.4 s for 500 files against 0.25 s
    /// now, so the ceiling below has forty times the room it needs. The
    /// whole curve to the 5,000-file ceiling is behind
    /// MEDIAFIN_BENCH_FULL=1 and takes about ten seconds.
    private var scanSizes: [Int] {
        Self.full ? [250, 500, 1_000, 2_500, 5_000] : [250, 500]
    }

    /// How many files the rename and planning benchmarks use.
    private var workloadSize: Int { Self.full ? 1_000 : 500 }

    /// The scan, which was quadratic twice over.
    ///
    /// `companionFiles` listed the whole directory once per video, and then
    /// asked the filesystem whether each entry was a directory — for every
    /// video. 1,000 videos in a folder of 3,000 entries meant 1,000
    /// listings and three million stat calls.
    ///
    /// Measured here before and after: 250 files 2.78 s → 0.09 s, 500
    /// 10.37 s → 0.25 s, 1,000 40.03 s → 0.51 s.
    ///
    /// The ceiling below is sixty times the measured value, so a busy
    /// runner cannot fail it — but a return to quadratic took 40 s and
    /// would.
    func testScanningAFlatFolderIsNotQuadratic() throws {
        var scanned: TimeInterval = 0
        var written: TimeInterval = 0
        for count in scanSizes {
            let before = Date()
            let folder = try populate(count, companions: true)
            let writing = Date().timeIntervalSince(before)
            var found = 0
            let started = Date()
            try seconds("scan \(count) videos + companions") {
                found = MediaScanner().scan(urls: [folder]).count
            }
            if count == 500 {
                scanned = Date().timeIntervalSince(started)
                written = writing
            }
            XCTAssertEqual(found, count)
            try fm.removeItem(at: folder)
        }
        // A loose backstop, in seconds, and deliberately loose: the
        // structural test below is the one that catches the regression
        // exactly. Two attempts at a clock ceiling here both flaked — 5 s
        // failed on the macOS runner at 5.9 s, and "eight times the cost of
        // writing the files" failed there too, because the ratio of reading
        // to writing is about 11 on that machine and 0.3 in this container.
        // A number that varies by thirty times between two machines is not
        // measuring the code.
        print("BENCH write 1,500 files                    "
              + String(format: "%.3f s", written))
        XCTAssertLessThan(
            scanned, 30,
            "scanning 500 files took \(scanned)s, which is slow on any machine "
                + "(writing the 1,500 files took \(written)s). It was 10.4 s here "
                + "when companionFiles listed the folder once per video.")
    }

    /// The regression itself, counted rather than timed.
    ///
    /// `companionFiles` used to list the whole directory once per video and
    /// then ask the filesystem whether each entry was a directory — for
    /// every video. That is not a slow version of the right algorithm, it is
    /// a different algorithm, and the number of listings says so exactly: it
    /// was one per video, it is one per directory.
    ///
    /// This replaces a ceiling in seconds, which measured the runner. Two of
    /// them flaked on the macOS runner before this test existed.
    func testAFolderIsListedOncePerFolderAndNotOncePerVideo() throws {
        let count = 200
        let folder = try populate(count, companions: true)
        let counting = CountingFileManager()
        let found = MediaScanner(fileManager: counting).scan(urls: [folder]).count

        XCTAssertEqual(found, count)
        print("BENCH listings for \(count) videos            \(counting.listings)")
        XCTAssertLessThanOrEqual(
            counting.listings, 4,
            "the folder was listed \(counting.listings) times for \(count) videos; "
                + "companionFiles used to list it once per video, which is where "
                + "the 40 seconds for 1,000 files came from")
        // The stat per entry cannot be counted the same way —
        // `fileExists(atPath:isDirectory:)` is in an extension on Linux and
        // a subclass may not override it. The listing count is the shape
        // that matters: the per-entry lookup was always one per entry, and
        // what made it quadratic was doing the whole listing again for
        // every video.
    }

    /// Planning, which is pure computation over what the scan returned.
    func testPlanning() throws {
        let folder = try populate(workloadSize, companions: true)
        let files = MediaScanner().scan(urls: [folder])
        let library = root.appendingPathComponent("library")
        var planned = 0
        try seconds("plan \(workloadSize) items") {
            planned = RenamePlanner().makePlan(for: files, outputRoot: library,
                                               libraryRoot: library).count
        }
        XCTAssertEqual(planned, workloadSize)
    }

    /// The history. Suspect: every append re-encodes and rewrites the whole
    /// file, pretty-printed, so N appends write O(N²) bytes.
    func testAppendingToTheHistory() throws {
        let log = RenameLog(url: root.appendingPathComponent("log.json"))
        let started = Date()
        try seconds("2000 history appends") {
            for index in 0..<2_000 {
                log.append(RenameLogEntry(oldName: "a\(index).mkv",
                                          newName: "b\(index).mkv",
                                          status: .success))
            }
        }
        let appending = Date().timeIntervalSince(started)
        // The write is coalesced now, so the file is read after a flush —
        // otherwise this measured the 176 bytes of an empty file and called
        // it a result.
        log.flush()
        let size = (try? fm.attributesOfItem(atPath: log.url.path))?[.size] as? Int
        print("BENCH history file size: \(size ?? 0) bytes")
        XCTAssertLessThan(appending, 10,
                          "2,000 history appends took \(appending)s; they took 18 s "
                              + "when every append rewrote the whole file, and 0.005 s "
                              + "after")
    }

    /// The whole run, end to end, which is what the user waits for.
    func testRenamingAThousandFiles() throws {
        let folder = try populate(workloadSize, companions: true)
        let library = root.appendingPathComponent("library")
        let files = MediaScanner().scan(urls: [folder])
        let plan = RenamePlanner().makePlan(for: files, outputRoot: library,
                                            libraryRoot: library)
        let log = RenameLog(url: root.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: root.appendingPathComponent("journal.json"))
        let executor = RenameExecutor(log: log, journal: journal)
        var outcome = RenameOutcome()
        let started = Date()
        try seconds("rename \(workloadSize) (+subs, +nfo)") {
            outcome = executor.execute(plan: plan, policy: .skip)
        }
        let renaming = Date().timeIntervalSince(started)
        XCTAssertEqual(outcome.succeeded, workloadSize * 2, "film + subtitle each")
        XCTAssertEqual(outcome.deleted, workloadSize, "the release notes")
        XCTAssertLessThan(renaming, 5,
                          "renaming \(workloadSize) files took \(renaming)s; 1,000 took "
                              + "44 s when each history entry rewrote the whole log, "
                              + "and 0.23 s after")
    }

    /// Counts what the scanner asks the filesystem for.
    ///
    /// Only the path-based `contentsOfDirectory`, which is what the
    /// scanner uses and the one overload Linux lets a subclass override —
    /// the URL-based one and `fileExists(atPath:isDirectory:)` are declared
    /// in extensions there. `enumerator` is not counted: it is one call for
    /// the whole walk either way, which is not where the regression was.
    private final class CountingFileManager: FileManager, @unchecked Sendable {
        private let lock = NSLock()
        private var _listings = 0
        var listings: Int { lock.lock(); defer { lock.unlock() }; return _listings }

        override func contentsOfDirectory(atPath path: String) throws -> [String] {
            lock.lock(); _listings += 1; lock.unlock()
            return try super.contentsOfDirectory(atPath: path)
        }

    }
}
