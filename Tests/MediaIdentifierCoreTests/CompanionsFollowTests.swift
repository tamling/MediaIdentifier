import XCTest
@testable import MediaIdentifierCore

/// A release has to arrive whole or not at all.
///
/// Every move used to be resolved on its own, which pulled releases apart
/// in two different ways, both of them silent and both of them leaving the
/// library looking tidy.
final class CompanionsFollowTests: XCTestCase {

    private var root: URL!
    private var source: URL!
    private var library: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        Text.language = .german
        root = fm.temporaryDirectory
            .appendingPathComponent("mediafin-companions-\(UUID().uuidString)")
        source = root.appendingPathComponent("Downloads")
        library = root.appendingPathComponent("Filme")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ name: String, in directory: URL? = nil,
                       contents: String = "x") throws -> URL {
        let url = (directory ?? source).appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeExecutor() -> (RenameExecutor, RenameLog) {
        let log = RenameLog(url: root.appendingPathComponent("log.json"))
        let journal = RenameJournal(url: root.appendingPathComponent("journal.json"))
        return (RenameExecutor(log: log, journal: journal), log)
    }

    private func planFilmWithSubtitle() throws -> [RenameItem] {
        let film = try write("Tenet.2020.1080p.BluRay.x264-GROUP.mkv")
        try write("Tenet.2020.1080p.BluRay.x264-GROUP.en.srt")
        return RenamePlanner().makePlan(for: [MediaScanner().mediaFile(for: film)],
                                        outputRoot: library, libraryRoot: library)
    }

    // MARK: The "rename" policy

    /// The bug. The film hits an existing "Tenet (2020).mkv" and becomes
    /// "Tenet (2020) (1).mkv"; the subtitle found its own name free and kept
    /// it — landing beside the film that was already there, while the rip
    /// that had just arrived had no subtitles at all.
    func testASubtitleFollowsAFilmThePolicyRenamed() throws {
        let plan = try planFilmWithSubtitle()
        let item = try XCTUnwrap(plan.first)
        let folder = item.primaryDestination.deletingLastPathComponent()
        // The library already has this film, and a subtitle for it.
        try write(item.primaryDestination.lastPathComponent, in: folder,
                  contents: "the one that was already here")
        let (executor, _) = makeExecutor()

        let outcome = executor.execute(plan: plan, policy: .rename)

        let landed = try XCTUnwrap(outcome.landed[item.id])
        XCTAssertNotEqual(landed, item.primaryDestination,
                          "the policy did not rename anything, so nothing is proved")
        // The subtitle must sit beside the file that actually arrived.
        let beside = landed.deletingPathExtension().lastPathComponent
        let names = try fm.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertTrue(names.contains("\(beside).en.srt"),
                      "the subtitle is not beside the film it belongs to: \(names)")
        XCTAssertFalse(names.contains("Tenet (2020).en.srt"),
                       "the subtitle landed beside the film that was already there")
        XCTAssertEqual(try Data(contentsOf: landed), Data("x".utf8),
                       "the wrong file was treated as the new one")
    }

    /// The rebuilt name keeps whatever followed the stem — the language tag
    /// is the whole reason a subtitle is findable at all.
    func testTheLanguageTagSurvivesTheRebuild() {
        let planned = URL(fileURLWithPath: "/lib/Tenet (2020)/Tenet (2020).mkv")
        let actual = URL(fileURLWithPath: "/lib/Tenet (2020)/Tenet (2020) (1).mkv")
        let move = PlannedMove(
            source: URL(fileURLWithPath: "/dl/x.srt"),
            destination: URL(fileURLWithPath: "/lib/Tenet (2020)/Tenet (2020).en.forced.srt"),
            companionRole: .subtitle)
        let followed = RenameExecutor.following(move, primaryPlanned: planned,
                                                primaryActual: actual)
        XCTAssertEqual(followed.destination.lastPathComponent,
                       "Tenet (2020) (1).en.forced.srt")
    }

    /// Nothing to follow: the policy left the name alone, so the companion
    /// must be left alone too rather than rebuilt into something else.
    func testAnUnrenamedPrimaryChangesNothing() {
        let planned = URL(fileURLWithPath: "/lib/A/A.mkv")
        let move = PlannedMove(source: URL(fileURLWithPath: "/dl/a.srt"),
                               destination: URL(fileURLWithPath: "/lib/A/A.en.srt"))
        XCTAssertEqual(
            RenameExecutor.following(move, primaryPlanned: planned,
                                     primaryActual: planned).destination,
            move.destination)
    }

    /// A companion name that does not start with the planned stem is left
    /// alone rather than guessed at.
    func testAnUnrelatedNameIsNotRewritten() {
        let planned = URL(fileURLWithPath: "/lib/A/A.mkv")
        let actual = URL(fileURLWithPath: "/lib/A/A (1).mkv")
        let move = PlannedMove(source: URL(fileURLWithPath: "/dl/cover.jpg"),
                               destination: URL(fileURLWithPath: "/lib/A/folder.jpg"))
        XCTAssertEqual(
            RenameExecutor.following(move, primaryPlanned: planned,
                                     primaryActual: actual).destination,
            move.destination)
    }

    // MARK: The "skip" policy

    /// The same shape, the other way round: the film stayed in Downloads
    /// because something was already at its destination, and its subtitle
    /// walked into the library on its own and sat beside a stranger.
    func testCompanionsStayWithAFilmThatWasSkipped() throws {
        let plan = try planFilmWithSubtitle()
        let item = try XCTUnwrap(plan.first)
        let folder = item.primaryDestination.deletingLastPathComponent()
        try write(item.primaryDestination.lastPathComponent, in: folder,
                  contents: "already here")
        let subtitle = source.appendingPathComponent(
            "Tenet.2020.1080p.BluRay.x264-GROUP.en.srt")
        let (executor, log) = makeExecutor()

        let outcome = executor.execute(plan: plan, policy: .skip)

        XCTAssertEqual(outcome.succeeded, 0)
        XCTAssertEqual(outcome.skipped, 2, "film and subtitle should both be skipped")
        XCTAssertTrue(fm.fileExists(atPath: subtitle.path),
                      "the subtitle left without its film")
        XCTAssertFalse(fm.fileExists(atPath: folder.appendingPathComponent(
            "Tenet (2020).en.srt").path),
            "the subtitle landed beside a film it does not belong to")
        XCTAssertTrue(log.entries.contains {
            $0.status == .skipped
                && ($0.errorDescription?.contains("nicht umbenannt") ?? false)
        }, "nothing in the history says why the subtitle stayed")
    }

    // MARK: One file, two films

    /// A prefix rule alone made "Film.Extended.en.srt" a companion of both
    /// "Film.mkv" and "Film.Extended.mkv", so the same subtitle was planned
    /// into two places: the first move took it and the second failed with
    /// "no such file". The longer name wins.
    func testASubtitleBelongsToTheLongerNameOnly() throws {
        let short = try write("Film.2019.1080p.mkv")
        let long = try write("Film.2019.1080p.Extended.mkv")
        try write("Film.2019.1080p.Extended.en.srt")
        try write("Film.2019.1080p.en.srt")

        let scanner = MediaScanner()
        let shortCompanions = scanner.mediaFile(for: short).companions
            .map(\.url.lastPathComponent).sorted()
        let longCompanions = scanner.mediaFile(for: long).companions
            .map(\.url.lastPathComponent).sorted()

        XCTAssertEqual(shortCompanions, ["Film.2019.1080p.en.srt"],
                       "the extended cut's subtitle was taken by the short cut too")
        XCTAssertEqual(longCompanions, ["Film.2019.1080p.Extended.en.srt"])
    }

    /// The extended cut's own file must not be swallowed as a companion of
    /// the shorter name either — it is a film in its own right.
    func testTheLongerFilmIsNotACompanionOfTheShorterOne() throws {
        let short = try write("Film.2019.1080p.mkv")
        try write("Film.2019.1080p.Extended.mkv")
        let companions = MediaScanner().mediaFile(for: short).companions
        XCTAssertTrue(companions.isEmpty,
                      "a film became a companion: \(companions.map(\.url.lastPathComponent))")
    }

    /// The backstop, exercised directly: if one source ever reaches the
    /// executor as two items' companion again, the second is refused rather
    /// than failing after the first has taken the file.
    func testAFileClaimedTwiceIsRefusedTheSecondTime() throws {
        let filmA = try write("A.2019.mkv")
        let filmB = try write("B.2019.mkv")
        let shared = try write("shared.en.srt")
        let planner = RenamePlanner()
        let scanner = MediaScanner()
        var a = try XCTUnwrap(planner.makePlan(for: [scanner.mediaFile(for: filmA)],
                                               outputRoot: library,
                                               libraryRoot: library).first)
        var b = try XCTUnwrap(planner.makePlan(for: [scanner.mediaFile(for: filmB)],
                                               outputRoot: library,
                                               libraryRoot: library).first)
        // Hand both the same companion, as the prefix rule used to.
        a.companionMoves = [PlannedMove(
            source: shared,
            destination: a.primaryDestination.deletingLastPathComponent()
                .appendingPathComponent("A (2019).en.srt"),
            companionRole: .subtitle)]
        b.companionMoves = [PlannedMove(
            source: shared,
            destination: b.primaryDestination.deletingLastPathComponent()
                .appendingPathComponent("B (2019).en.srt"),
            companionRole: .subtitle)]
        let (executor, log) = makeExecutor()

        let outcome = executor.execute(plan: [a, b], policy: .skip)

        XCTAssertEqual(outcome.failed, 0,
                       "the second claim failed instead of being refused")
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertTrue(log.entries.contains {
            $0.status == .skipped
                && ($0.errorDescription?.contains("mehreren Dateien") ?? false)
        }, "nothing said the file belongs to more than one")
    }

    // MARK: Nothing else moved

    /// The ordinary case still works: no conflict, everything travels.
    func testWithNoConflictTheWholeReleaseStillTravels() throws {
        let plan = try planFilmWithSubtitle()
        let item = try XCTUnwrap(plan.first)
        let (executor, _) = makeExecutor()

        let outcome = executor.execute(plan: plan, policy: .skip)

        XCTAssertEqual(outcome.succeeded, 2)
        XCTAssertEqual(outcome.skipped, 0)
        XCTAssertTrue(fm.fileExists(atPath: item.primaryDestination.path))
        XCTAssertTrue(fm.fileExists(atPath: item.primaryDestination
            .deletingLastPathComponent()
            .appendingPathComponent("Tenet (2020).en.srt").path))
    }
}
