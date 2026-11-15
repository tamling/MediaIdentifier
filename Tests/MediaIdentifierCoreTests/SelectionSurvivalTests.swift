import XCTest
@testable import MediaIdentifierCore

/// The user's exclusions, and what used to happen to them.
///
/// The tick state lived nowhere but the GtkCheckButton. Nothing in the
/// program submitted `.setAccepted` or `.setAllAccepted` — both commands had
/// been without a sender since the web front end was removed — so
/// `isAccepted` could never become false, and `refreshList` destroys every
/// row whenever the id list changes and re-seeds each box from it.
///
/// A drop, a watch poll or a scheduled scan while the window was open
/// therefore re-ticked everything, and the next press of Umbenennen moved
/// the files the user had taken out on purpose. The counts row said
/// "20 proposals · 20 ticked" throughout, so nothing on screen ever
/// contradicted itself.
final class SelectionSurvivalTests: XCTestCase {

    private var root: URL!
    private var config: URL!
    private var source: URL!
    private var library: URL!
    private var coordinator: AppCoordinator!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = fm.temporaryDirectory
            .appendingPathComponent("mediafin-selection-\(UUID().uuidString)")
        config = root.appendingPathComponent("config")
        source = root.appendingPathComponent("downloads")
        library = root.appendingPathComponent("films")
        for url in [config, source, library] {
            try fm.createDirectory(at: url!, withIntermediateDirectories: true)
        }
        coordinator = AppCoordinator(configDirectory: config, lampInterval: 0)
        Text.language = .german
    }

    override func tearDownWithError() throws {
        coordinator = nil
        if let root { try? fm.removeItem(at: root) }
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeFile(_ name: String) throws -> URL {
        let url = source.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func configured() -> WebSettings {
        var settings = WebSettings(sourceFolder: source.path)
        settings.moviesFolder = library.path
        settings.identification = .offline
        return settings
    }

    private func scan() { coordinator.executeForTesting(.scanSourceFolder) }

    private func untick(_ fileName: String) throws {
        let item = try XCTUnwrap(coordinator.items.first {
            $0.mediaFile.url.lastPathComponent == fileName
        }, "\(fileName) is not in the list")
        coordinator.executeForTesting(.setAccepted(item.id, false))
    }

    private func excluded() -> [String] {
        coordinator.items.filter { !$0.isAccepted }
            .map(\.mediaFile.url.lastPathComponent).sorted()
    }

    private func importFolder() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: source.path)) ?? [])
            .filter { $0.hasSuffix(".mkv") }.sorted()
    }

    // MARK: The exclusion reaches the engine at all

    func testUntickingOneFileIsRecordedAndCounted() throws {
        for name in ["Alpha.2001.1080p.mkv", "Bravo.2002.1080p.mkv"] {
            try makeFile(name)
        }
        coordinator.executeForTesting(.saveSettings(configured()))
        scan()
        XCTAssertEqual(coordinator.snapshot.ready, 2)

        try untick("Alpha.2001.1080p.mkv")

        XCTAssertEqual(excluded(), ["Alpha.2001.1080p.mkv"])
        XCTAssertEqual(coordinator.snapshot.ready, 1,
                       "the counts row still says everything is ticked")
    }

    // MARK: It survives the list being rebuilt

    /// A second scan builds new items with new ids, so the exclusion cannot
    /// be carried by id — it is kept by path.
    func testAnExclusionSurvivesARescan() throws {
        for name in ["Alpha.2001.1080p.mkv", "Bravo.2002.1080p.mkv",
                     "Charlie.2003.1080p.mkv"] {
            try makeFile(name)
        }
        coordinator.executeForTesting(.saveSettings(configured()))
        scan()
        try untick("Bravo.2002.1080p.mkv")

        scan()

        XCTAssertEqual(excluded(), ["Bravo.2002.1080p.mkv"],
                       "the rescan re-ticked the file the user took out")
        XCTAssertEqual(coordinator.snapshot.ready, 2)
    }

    /// Dropping one more file on the window is the easiest way to hit this:
    /// the id list grows, so every row is rebuilt.
    func testAnExclusionSurvivesAFileBeingDroppedIn() throws {
        try makeFile("Alpha.2001.1080p.mkv")
        try makeFile("Bravo.2002.1080p.mkv")
        coordinator.executeForTesting(.saveSettings(configured()))
        scan()
        try untick("Alpha.2001.1080p.mkv")

        let extra = root.appendingPathComponent("Delta.2004.1080p.mkv")
        try Data("x".utf8).write(to: extra)
        coordinator.executeForTesting(.addFiles([extra]))

        XCTAssertEqual(coordinator.items.count, 3)
        XCTAssertEqual(excluded(), ["Alpha.2001.1080p.mkv"])
    }

    func testUntickingEverythingSurvivesARescanToo() throws {
        for name in ["Alpha.2001.1080p.mkv", "Bravo.2002.1080p.mkv"] {
            try makeFile(name)
        }
        coordinator.executeForTesting(.saveSettings(configured()))
        scan()
        coordinator.executeForTesting(.setAllAccepted(false))
        XCTAssertEqual(coordinator.snapshot.ready, 0)

        scan()

        XCTAssertEqual(excluded().count, 2)
        XCTAssertEqual(coordinator.snapshot.ready, 0)
    }

    /// And ticking it again really does clear the exclusion, rather than
    /// leaving a path that re-unticks the file at the next scan.
    func testTickingItBackOnSticksAsWell() throws {
        try makeFile("Alpha.2001.1080p.mkv")
        coordinator.executeForTesting(.saveSettings(configured()))
        scan()
        try untick("Alpha.2001.1080p.mkv")
        let item = try XCTUnwrap(coordinator.items.first)
        coordinator.executeForTesting(.setAccepted(item.id, true))

        scan()

        XCTAssertEqual(excluded(), [])
        XCTAssertEqual(coordinator.snapshot.ready, 1)
    }

    // MARK: The list has a ceiling

    /// Nothing bounded the accumulated list. `FolderScan.maximumFiles` is a
    /// per-call ceiling applied inside each enumeration, so dropping folder
    /// after folder grew it without limit — and every drop re-ran conflict
    /// detection over the whole thing and the window rebuilt a widget
    /// subtree per row, uncapped.
    func testDroppingPastTheCeilingStopsAndSaysSo() throws {
        coordinator.executeForTesting(.saveSettings(configured()))
        // Two drops that together exceed the ceiling. Built as URLs that do
        // not exist on disk is not enough — addFiles stats them — so this
        // uses the smallest number of real files that proves the rule, by
        // setting the items directly and then dropping one more.
        let filler = (0..<MediaScanner.maximumFiles).map { index in
            RenameItem(
                mediaFile: MediaFile(
                    url: URL(fileURLWithPath: "/downloads/F\(index).mkv"),
                    parsed: ParsedRelease(originalFileName: "F\(index).mkv",
                                          title: "F\(index)")),
                outputRoot: library,
                proposedRelativePath: "F\(index)/F\(index).mkv")
        }
        coordinator.setItemsForTesting(filler)
        XCTAssertEqual(coordinator.items.count, MediaScanner.maximumFiles)

        let extra = root.appendingPathComponent("Extra.2020.1080p.mkv")
        try Data("x".utf8).write(to: extra)
        coordinator.executeForTesting(.addFiles([extra]))

        XCTAssertEqual(coordinator.items.count, MediaScanner.maximumFiles,
                       "the list grew past its own ceiling")
        let said = coordinator.snapshot.lastResult ?? ""
        XCTAssertTrue(said.contains("nicht aufgenommen") || said.contains("not added"),
                      "the list quietly stopped growing: \(said)")
    }

    // MARK: The unattended run

    /// The worst of it: no user action at all. The nightly run rescans, the
    /// exclusion is discarded, and the file the user had set aside is in the
    /// library in the morning.
    func testAScheduledRunDoesNotRenameAnExcludedFile() throws {
        for name in ["Alpha.2001.1080p.mkv", "Bravo.2002.1080p.mkv",
                     "Charlie.2003.1080p.mkv"] {
            try makeFile(name)
        }
        coordinator.executeForTesting(.saveSettings(configured()))
        scan()
        try untick("Bravo.2002.1080p.mkv")

        coordinator.performScheduledRun(
            Schedule(isEnabled: true, hour: 3, alsoRename: true))

        XCTAssertEqual(importFolder(), ["Bravo.2002.1080p.mkv"],
                       "the unattended run renamed the file the user excluded")
    }

    /// The set of excluded paths must not grow for ever: a file that is no
    /// longer in the plan is forgotten.
    func testAPathThatLeavesThePlanIsForgotten() throws {
        try makeFile("Alpha.2001.1080p.mkv")
        coordinator.executeForTesting(.saveSettings(configured()))
        scan()
        try untick("Alpha.2001.1080p.mkv")

        // Gone from the import folder, so out of the next plan.
        try fm.removeItem(at: source.appendingPathComponent("Alpha.2001.1080p.mkv"))
        try makeFile("Bravo.2002.1080p.mkv")
        scan()
        XCTAssertEqual(excluded(), [])

        // And when it comes back, it comes back ticked.
        try makeFile("Alpha.2001.1080p.mkv")
        scan()
        XCTAssertEqual(excluded(), [])
        XCTAssertEqual(coordinator.snapshot.ready, 2)
    }
}
