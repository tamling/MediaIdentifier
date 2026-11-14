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
    private var scanSizes: [Int] {
        ProcessInfo.processInfo.environment["MEDIAFIN_BENCH_FULL"] == "1"
            ? [250, 500, 1_000, 2_500, 5_000]
            : [250, 500, 1_000]
    }

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
        var takenForAThousand: TimeInterval = 0
        for count in scanSizes {
            let folder = try populate(count, companions: true)
            var found = 0
            let started = Date()
            try seconds("scan \(count) videos + companions") {
                found = MediaScanner().scan(urls: [folder]).count
            }
            if count == 1_000 { takenForAThousand = Date().timeIntervalSince(started) }
            XCTAssertEqual(found, count)
            try fm.removeItem(at: folder)
        }
        XCTAssertLessThan(takenForAThousand, 30,
                          "scanning 1,000 files took \(takenForAThousand)s; it was "
                              + "40 s when companionFiles listed the folder once per "
                              + "video, and 0.5 s after")
    }

    /// Planning, which is pure computation over what the scan returned.
    func testPlanning() throws {
        let folder = try populate(1_000, companions: true)
        let files = MediaScanner().scan(urls: [folder])
        let library = root.appendingPathComponent("library")
        var planned = 0
        try seconds("plan 1000 items") {
            planned = RenamePlanner().makePlan(for: files, outputRoot: library,
                                               libraryRoot: library).count
        }
        XCTAssertEqual(planned, 1_000)
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
        let folder = try populate(1_000, companions: true)
        let library = root.appendingPathComponent("library")
        let files = MediaScanner().scan(urls: [folder])
        let plan = RenamePlanner().makePlan(for: files, outputRoot: library,
                                            libraryRoot: library)
        let log = RenameLog(url: root.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: root.appendingPathComponent("journal.json"))
        let executor = RenameExecutor(log: log, journal: journal)
        var outcome = RenameOutcome()
        let started = Date()
        try seconds("rename 1000 (+1000 subs, +1000 nfo)") {
            outcome = executor.execute(plan: plan, policy: .skip)
        }
        let renaming = Date().timeIntervalSince(started)
        XCTAssertEqual(outcome.succeeded, 2_000, "film + subtitle each")
        XCTAssertEqual(outcome.deleted, 1_000, "the release notes")
        XCTAssertLessThan(renaming, 20,
                          "renaming 1,000 files took \(renaming)s; it took 44 s when "
                              + "each of the 3,000 history entries rewrote the whole "
                              + "log, and 0.23 s after")
    }
}
