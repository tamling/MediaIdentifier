import XCTest
@testable import MediaIdentifierCore

/// The history is bounded and its writes are coalesced.
///
/// It used to keep every entry ever written and rewrite the whole file,
/// pretty-printed, on every single append — so the program got measurably
/// slower the longer it was used, and one run was quadratic in bytes
/// written. Measured: 2,000 appends took 18.0 seconds to produce a 357 KB
/// file, which is roughly 360 MB written.
///
/// Both changes alter behaviour, so both are pinned here.
final class HistoryBoundsTests: XCTestCase {

    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        Text.language = .german
        root = fm.temporaryDirectory
            .appendingPathComponent("mediafin-history-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    private func makeLog() -> RenameLog {
        RenameLog(url: root.appendingPathComponent("rename-log.json"))
    }

    // MARK: The bound

    func testTheNewestEntriesAreTheOnesKept() {
        let log = makeLog()
        let total = RenameLog.maximumEntries + 500
        for index in 0..<total {
            log.append(RenameLogEntry(oldName: "a\(index).mkv",
                                      newName: "b\(index).mkv", status: .success))
        }
        XCTAssertEqual(log.entries.count, RenameLog.maximumEntries)
        // The last one written is still there; the first is not.
        XCTAssertEqual(log.entries.last?.oldName, "a\(total - 1).mkv")
        XCTAssertEqual(log.entries.first?.oldName,
                       "a\(total - RenameLog.maximumEntries).mkv")
    }

    /// A batch append is bounded too, not only the one-at-a-time path.
    func testABatchIsBoundedAsWell() {
        let log = makeLog()
        log.append(contentsOf: (0..<(RenameLog.maximumEntries + 100)).map {
            RenameLogEntry(oldName: "a\($0).mkv", newName: "b.mkv", status: .success)
        })
        XCTAssertEqual(log.entries.count, RenameLog.maximumEntries)
    }

    /// And the file on disk is bounded, not just the array — the file was
    /// the thing that was growing for ever.
    func testTheFileIsBoundedToo() throws {
        let log = makeLog()
        for index in 0..<(RenameLog.maximumEntries + 300) {
            log.append(RenameLogEntry(oldName: "a\(index).mkv",
                                      newName: "b.mkv", status: .success))
        }
        log.flush()
        let reopened = RenameLog(url: log.url)
        XCTAssertEqual(reopened.entries.count, RenameLog.maximumEntries)
    }

    // MARK: The coalesced write

    /// The array updates at once. The window reads it twice a second and
    /// must not go blind while a run is going on.
    func testAnAppendIsVisibleImmediatelyInMemory() {
        let log = makeLog()
        log.append(RenameLogEntry(oldName: "a.mkv", newName: "b.mkv", status: .success))
        XCTAssertEqual(log.entries.count, 1)
    }

    /// The write that follows must actually happen without anybody asking.
    /// A trailing write that never fires is data loss dressed as speed.
    func testTheTrailingWriteHappensOnItsOwn() throws {
        let log = makeLog()
        // Two appends in quick succession: the first writes, the second is
        // inside the interval and has to be picked up by the trailing write.
        log.append(RenameLogEntry(oldName: "first.mkv", newName: "b.mkv",
                                  status: .success))
        log.append(RenameLogEntry(oldName: "second.mkv", newName: "b.mkv",
                                  status: .success))

        let deadline = Date().addingTimeInterval(5)
        var onDisk = 0
        while Date() < deadline {
            onDisk = RenameLog(url: log.url).entries.count
            if onDisk == 2 { break }
            usleep(20_000)
        }
        XCTAssertEqual(onDisk, 2,
                       "the second append never reached the disk on its own")
    }

    /// Clearing is immediate: the user asked for it and then looks.
    func testClearingIsWrittenAtOnce() throws {
        let log = makeLog()
        log.append(RenameLogEntry(oldName: "a.mkv", newName: "b.mkv", status: .success))
        log.flush()
        XCTAssertEqual(RenameLog(url: log.url).entries.count, 1)

        log.clear()
        XCTAssertEqual(RenameLog(url: log.url).entries.count, 0,
                       "a cleared history was still on disk")
    }

    /// flush() is what a caller about to exit uses, and what the benchmark
    /// uses before measuring the file.
    func testFlushWritesWhateverIsWaiting() throws {
        let log = makeLog()
        for index in 0..<50 {
            log.append(RenameLogEntry(oldName: "a\(index).mkv", newName: "b.mkv",
                                      status: .success))
        }
        log.flush()
        XCTAssertEqual(RenameLog(url: log.url).entries.count, 50)
    }

    /// Flushing with nothing waiting must not rewrite the file, and must
    /// not throw anything away.
    func testFlushingTwiceIsHarmless() throws {
        let log = makeLog()
        log.append(RenameLogEntry(oldName: "a.mkv", newName: "b.mkv", status: .success))
        log.flush()
        log.flush()
        XCTAssertEqual(RenameLog(url: log.url).entries.count, 1)
    }

    // MARK: What the scan change must not have broken

    /// The scan reads each folder once now and shares the listing. The
    /// companion rules have to come out identical, so this compares the
    /// shared path against the single-file path that computes its own
    /// listing.
    func testTheSharedListingFindsExactlyWhatTheSingleFilePathFinds() throws {
        let folder = root.appendingPathComponent("downloads")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = [
            "Film.2019.1080p.mkv", "Film.2019.1080p.en.srt", "Film.2019.1080p.nfo",
            "Film.2019.1080p-poster.jpg", "Film.2019.1080p-sample.mkv",
            "Film.2019.1080p.Extended.mkv", "Film.2019.1080p.Extended.en.srt",
            "Andere.2020.720p.mkv", "Andere.2020.720p.de.forced.srt",
            "liesmich.txt", "Film.2019.1080p.de.sub",
        ]
        for name in names {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        try fm.createDirectory(at: folder.appendingPathComponent("Film.2019.1080p.dir"),
                               withIntermediateDirectories: true)

        let scanner = MediaScanner()
        let shared = scanner.scan(urls: [folder])
        XCTAssertFalse(shared.isEmpty)
        for file in shared {
            let alone = scanner.mediaFile(for: file.url)
            XCTAssertEqual(
                file.companions.map { "\($0.url.lastPathComponent)|\($0.role.rawValue)|"
                    + ($0.languageTag ?? "-") },
                alone.companions.map { "\($0.url.lastPathComponent)|\($0.role.rawValue)|"
                    + ($0.languageTag ?? "-") },
                "the shared listing disagrees for \(file.url.lastPathComponent)")
        }
    }

    /// A directory whose name looks like a companion must not become one.
    /// Directories used to be filtered with a stat per entry per video;
    /// they are filtered once now, and that must still happen.
    func testADirectoryIsNeverACompanion() throws {
        let folder = root.appendingPathComponent("dirs")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let film = folder.appendingPathComponent("Film.2019.1080p.mkv")
        try Data("x".utf8).write(to: film)
        try fm.createDirectory(at: folder.appendingPathComponent("Film.2019.1080p.nfo"),
                               withIntermediateDirectories: true)

        let companions = MediaScanner().mediaFile(for: film).companions
        XCTAssertTrue(companions.isEmpty,
                      "a directory was taken for a companion: "
                          + "\(companions.map(\.url.lastPathComponent))")
    }
}
