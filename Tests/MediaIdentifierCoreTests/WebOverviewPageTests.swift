import XCTest
@testable import MediaIdentifierCore

/// Tests the overview page: that it shows the proposals, that the selection
/// reaches the command, and that nothing it renders can break the page.
final class WebOverviewPageTests: XCTestCase {

    private let token = "beefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeefbeef"

    private final class RecordingSink: WebCommandSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _commands: [WebCommand] = []
        func submit(_ command: WebCommand) {
            lock.lock(); _commands.append(command); lock.unlock()
        }
        var commands: [WebCommand] { lock.lock(); defer { lock.unlock() }; return _commands }
    }

    private var sink: RecordingSink!

    override func tearDown() {
        Text.language = .german
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        // These assert the page's English wording, and German is
        // the default. Said out loud: the language is global, so without
        // this the suite would pass or fail on the machine's LANG.
        Text.language = .english
        sink = RecordingSink()
    }

    private func item(_ name: String, to relativePath: String,
                      conflict: ConflictKind? = nil) -> RenameItem {
        let url = URL(fileURLWithPath: "/mnt/downloads/\(name)")
        let parsed = ParsedRelease(originalFileName: name, title: "Whatever", kind: .movie)
        return RenameItem(mediaFile: MediaFile(url: url, parsed: parsed),
                          outputRoot: URL(fileURLWithPath: "/mnt/media/Movies"),
                          proposedRelativePath: relativePath,
                          conflict: conflict)
    }

    private func makeRouter(items: [RenameItem] = [],
                            settings: WebSettings = WebSettings(sourceFolder: "/mnt/downloads"),
                            snapshot: StatusSnapshot = StatusSnapshot()) -> WebRouter {
        WebRouter(policy: WebSecurityPolicy(token: token, isTLS: true),
                  settings: { settings },
                  items: { items },
                  commands: sink,
                  snapshot: { snapshot })
    }

    private func page(_ router: WebRouter) -> String {
        let request = HTTPRequest(method: "GET", path: "/",
                                  headers: ["authorization": "Bearer \(token)"])
        return String(decoding: router.respond(to: request).body, as: UTF8.self)
    }

    private func apply(_ router: WebRouter, body: String) -> HTTPResponse {
        let full = "\(body)\(body.isEmpty ? "" : "&")\(CSRFToken.fieldName)=\(router.csrf.value)"
        return router.respond(to: HTTPRequest(
            method: "POST", path: "/library/apply",
            headers: ["authorization": "Bearer \(token)"],
            body: Data(full.utf8)
        ))
    }

    // MARK: Rendering

    func testProposalsAreListedWithBothNames() {
        let router = makeRouter(items: [
            item("The.Matrix.1999.1080p.mkv", to: "The Matrix (1999)/The Matrix (1999).mkv"),
        ])
        let html = page(router)
        XCTAssertTrue(html.contains("The.Matrix.1999.1080p.mkv"), html)
        XCTAssertTrue(html.contains("The Matrix (1999)/The Matrix (1999).mkv"), html)
    }

    func testConflictsAreExplainedInPlainWords() {
        let router = makeRouter(items: [
            item("a.mkv", to: "A (2020)/A (2020).mkv", conflict: .existingFile),
            item("b.mkv", to: "B (2020)/B (2020).mkv", conflict: .duplicateInBatch),
        ])
        let html = page(router)
        XCTAssertTrue(html.contains("a file is already there"), html)
        XCTAssertTrue(html.contains("two files want the same name"), html)
        XCTAssertFalse(html.contains("existingFile"), "the raw case name means nothing")
    }

    func testEmptyListSaysSoRatherThanShowingAnEmptyTable() {
        let html = page(makeRouter())
        XCTAssertTrue(html.contains("Nothing proposed yet"), html)
        XCTAssertFalse(html.contains("Rename the ticked files"))
    }

    /// First run: there is nothing to look for until a folder is configured,
    /// so the button is disabled and the page says where to go.
    func testFirstRunDisablesScanningAndPointsAtTheSettings() {
        let router = makeRouter(settings: WebSettings())
        let html = page(router)
        XCTAssertTrue(html.contains("No import folder is set yet"), html)
        XCTAssertTrue(html.contains("disabled"), html)
        XCTAssertTrue(html.contains("href=\"/settings\""), html)
    }

    func testUndoAndClearAreDisabledUntilSomethingHasHappened() {
        let fresh = page(makeRouter())
        XCTAssertTrue(fresh.contains(" disabled>Undo the last run"), fresh)
        XCTAssertTrue(fresh.contains(" disabled>Clear the history"), fresh)

        let afterRun = page(makeRouter(snapshot: StatusSnapshot(done: 3)))
        XCTAssertFalse(afterRun.contains(" disabled>Undo the last run"), afterRun)
        XCTAssertFalse(afterRun.contains(" disabled>Clear the history"), afterRun)
    }

    func testStateIsShown() {
        XCTAssertTrue(page(makeRouter()).contains("Ready"))
        let busy = makeRouter(snapshot: StatusSnapshot(busy: true, renaming: true,
                                                       renameProgress: 0.4,
                                                       convertStatus: "Renaming"))
        let html = page(busy)
        XCTAssertTrue(html.contains("Renaming 40 %"), html)
        XCTAssertTrue(html.contains("http-equiv=\"refresh\""),
                      "a running job should refresh the page by itself")
    }

    func testIdlePageDoesNotKeepRefreshing() {
        XCTAssertFalse(page(makeRouter()).contains("http-equiv=\"refresh\""))
    }

    func testLastResultIsShown() {
        let router = makeRouter(snapshot: StatusSnapshot(lastResult: "Renamed 3, skipped 1."))
        XCTAssertTrue(page(router).contains("Renamed 3, skipped 1."))
    }

    /// The page forbids scripts in its own CSP, so it must not need any.
    func testThePageUsesNoJavaScript() {
        let router = makeRouter(items: [item("a.mkv", to: "A (2020)/A (2020).mkv")])
        let html = page(router)
        XCTAssertFalse(html.contains("<script"), html)
        XCTAssertFalse(html.lowercased().contains("onclick"), html)
    }

    /// A hostile file name must not be able to escape its cell.
    func testFileNamesAreEscaped() {
        let router = makeRouter(items: [
            item("<img src=x onerror=alert(1)>.mkv", to: "X (2020)/X (2020).mkv"),
        ])
        let html = page(router)
        XCTAssertFalse(html.contains("<img src=x"), html)
        XCTAssertTrue(html.contains("&lt;img src=x"), html)
    }

    // MARK: Selection

    func testTickedItemsAreTheOnesApplied() {
        let first = item("a.mkv", to: "A (2020)/A (2020).mkv")
        let second = item("b.mkv", to: "B (2020)/B (2020).mkv")
        let router = makeRouter(items: [first, second])

        let response = apply(router, body: "itemsPresent=1&items=\(first.id.uuidString)")
        XCTAssertEqual(response.status, 303)
        XCTAssertEqual(sink.commands, [.applyProposedRenames(accepting: [first.id])])
    }

    func testBothItemsTickedAreBothApplied() {
        let first = item("a.mkv", to: "A (2020)/A (2020).mkv")
        let second = item("b.mkv", to: "B (2020)/B (2020).mkv")
        let router = makeRouter(items: [first, second])

        _ = apply(router, body: "itemsPresent=1&items=\(first.id.uuidString)"
            + "&items=\(second.id.uuidString)")
        XCTAssertEqual(sink.commands,
                       [.applyProposedRenames(accepting: [first.id, second.id])],
                       "repeated checkbox values must all be read, not just the first")
    }

    /// Unticking everything must rename nothing — not everything.
    func testUntickingEverythingAppliesNothing() {
        let router = makeRouter(items: [item("a.mkv", to: "A (2020)/A (2020).mkv")])
        _ = apply(router, body: "itemsPresent=1")
        XCTAssertEqual(sink.commands, [.applyProposedRenames(accepting: [])])
    }

    /// A caller with no list in front of it (a script, say) means everything.
    func testApplyWithoutASelectionMeansEverything() {
        let router = makeRouter(items: [item("a.mkv", to: "A (2020)/A (2020).mkv")])
        _ = apply(router, body: "")
        XCTAssertEqual(sink.commands, [.applyProposedRenames(accepting: nil)])
    }

    func testUnknownItemIdsAreIgnoredRatherThanCrashing() {
        let router = makeRouter(items: [item("a.mkv", to: "A (2020)/A (2020).mkv")])
        _ = apply(router, body: "itemsPresent=1&items=not-a-uuid")
        XCTAssertEqual(sink.commands, [.applyProposedRenames(accepting: [])])
    }

    func testTheListFormCarriesTheCSRFToken() {
        let router = makeRouter(items: [item("a.mkv", to: "A (2020)/A (2020).mkv")])
        XCTAssertTrue(page(router).contains(router.csrf.value))
    }

    // MARK: Multi-value form parsing

    func testMultiValueFormParsing() {
        let fields = HTTPRequestParser.parseFormEncodedMulti("a=1&a=2&b=3&c=")
        XCTAssertEqual(fields["a"], ["1", "2"])
        XCTAssertEqual(fields["b"], ["3"])
        XCTAssertEqual(fields["c"], [""])
        XCTAssertNil(fields["d"])
    }
}
