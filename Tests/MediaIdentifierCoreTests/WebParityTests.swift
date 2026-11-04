import XCTest
@testable import MediaIdentifierCore

/// What the page gained when it was brought up to the window.
///
/// The window shows the log beside the work, a traffic light, a progress bar
/// and the version. The page had some of that on other pages and some of it
/// nowhere. These check it is there now — and, for the two things that were
/// actually wrong rather than merely missing, that they stay fixed.
final class WebParityTests: XCTestCase {

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

    override func setUp() {
        super.setUp()
        sink = RecordingSink()
    }

    private func item(_ name: String, to relativePath: String,
                      accepted: Bool = true) -> RenameItem {
        let url = URL(fileURLWithPath: "/mnt/downloads/\(name)")
        let parsed = ParsedRelease(originalFileName: name, title: "Whatever", kind: .movie)
        return RenameItem(mediaFile: MediaFile(url: url, parsed: parsed),
                          outputRoot: URL(fileURLWithPath: "/mnt/media/Movies"),
                          proposedRelativePath: relativePath,
                          isAccepted: accepted)
    }

    private func makeRouter(items: [RenameItem] = [],
                            log: [RenameLogEntry] = [],
                            checks: [SystemCheck] = [],
                            settings: WebSettings = WebSettings(sourceFolder: "/mnt/downloads"),
                            snapshot: StatusSnapshot = StatusSnapshot()) -> WebRouter {
        WebRouter(policy: WebSecurityPolicy(token: token, isTLS: true),
                  settings: { settings },
                  items: { items },
                  logEntries: { log },
                  systemChecks: { checks },
                  commands: sink,
                  snapshot: { snapshot })
    }

    private func page(_ router: WebRouter) -> String {
        let request = HTTPRequest(method: "GET", path: "/",
                                  headers: ["authorization": "Bearer \(token)"])
        return String(decoding: router.respond(to: request).body, as: UTF8.self)
    }

    private func post(_ router: WebRouter, _ path: String,
                      withToken: Bool = true) -> HTTPResponse {
        let body = withToken ? "\(CSRFToken.fieldName)=\(router.csrf.value)" : ""
        return router.respond(to: HTTPRequest(
            method: "POST", path: path,
            headers: ["authorization": "Bearer \(token)"],
            body: Data(body.utf8)
        ))
    }

    // MARK: The log, beside the work

    /// The reason this column exists: a failure has to be readable from the
    /// page you are already on, not from one you have to think to visit.
    func testAFailureIsVisibleOnTheOverviewItself() {
        let entry = RenameLogEntry(oldName: "Dark.S01E01.mkv",
                                   newName: "Dark/Staffel 01/Dark - S01E01.mkv",
                                   status: .failure,
                                   errorDescription: "Der Zielpfad ist nicht beschreibbar.")
        let html = page(makeRouter(log: [entry]))
        XCTAssertTrue(html.contains("Dark.S01E01.mkv"), "the log column is not on the page")
        XCTAssertTrue(html.contains("Der Zielpfad ist nicht beschreibbar."),
                      "the error text — the whole point — is missing")
        XCTAssertTrue(html.contains("failed"))
    }

    /// Newest first: the question is almost always "what just happened", and
    /// a column that grows downwards puts that answer off the screen.
    func testTheNewestEntryComesFirst() {
        let html = page(makeRouter(log: [
            RenameLogEntry(oldName: "first.mkv", newName: "First.mkv", status: .success),
            RenameLogEntry(oldName: "second.mkv", newName: "Second.mkv", status: .success),
        ]))
        let first = html.range(of: "first.mkv")
        let second = html.range(of: "second.mkv")
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        if let first, let second {
            XCTAssertTrue(second.lowerBound < first.lowerBound,
                          "the newest entry must be at the top")
        }
    }

    func testAnEmptyLogSaysSoRatherThanShowingNothing() {
        XCTAssertTrue(page(makeRouter()).contains("Nothing has happened yet."))
    }

    /// A sent file is not a renamed file, and the column must not call it one:
    /// the user would go looking for it in the wrong place.
    func testASentFileIsLabelledSentAndNotRenamed() {
        let html = page(makeRouter(log: [
            RenameLogEntry(oldName: "Dark.S01E01.mkv", newName: "Dark/Dark - S01E01.mkv",
                           status: .sent),
        ]))
        XCTAssertTrue(html.contains(">sent<"), "a transfer is labelled as a rename")
    }

    /// The column is bounded, and says where the rest went rather than
    /// quietly dropping it.
    func testALongHistoryIsCappedAndSaysWhereTheRestIs() {
        let many = (0..<(WebRouter.visibleLogEntries + 5)).map {
            RenameLogEntry(oldName: "file\($0).mkv", newName: "File \($0).mkv",
                           status: .success)
        }
        let html = page(makeRouter(log: many))
        XCTAssertTrue(html.contains("5 older entries"), "the cap is silent")
        XCTAssertTrue(html.contains("/history"))
    }

    // MARK: The two things that were wrong

    /// The page used to render every row "checked" whatever the proposal
    /// said, so it showed one thing and would have done another.
    func testAnUntickedProposalIsRenderedUnticked() {
        let html = page(makeRouter(items: [
            item("a.mkv", to: "A.mkv", accepted: true),
            item("b.mkv", to: "B.mkv", accepted: false),
        ]))
        // Two checkboxes, exactly one of them ticked.
        let boxes = html.components(separatedBy: "type=\"checkbox\"").count - 1
        let ticked = html.components(separatedBy: " checked>").count - 1
        XCTAssertEqual(boxes, 2)
        XCTAssertEqual(ticked, 1, "the page ticks rows the engine has not accepted")
    }

    /// Ticking all is server-side because the page forbids JavaScript in its
    /// own Content-Security-Policy. These two routes are what replaces the
    /// script, so they have to exist and reach the engine.
    func testTickAllAndTickNoneReachTheEngine() {
        let router = makeRouter(items: [item("a.mkv", to: "A.mkv")])
        XCTAssertEqual(post(router, "/library/select-all").status, 303)
        XCTAssertEqual(post(router, "/library/select-none").status, 303)
        XCTAssertEqual(sink.commands, [.setAllAccepted(true), .setAllAccepted(false)])
    }

    /// Every other state-changing route needs the token; these must not be
    /// the two that forgot.
    func testTheNewRoutesStillNeedTheToken() {
        for path in ["/library/select-all", "/library/select-none",
                     "/library/send", "/library/send-cancel", "/system/check"] {
            let router = makeRouter()
            let response = post(router, path, withToken: false)
            XCTAssertNotEqual(response.status, 303, "\(path) accepted a request with no token")
            XCTAssertTrue(sink.commands.isEmpty, "\(path) acted without a token")
        }
    }

    /// The page still forbids scripts. If that ever changes, the "tick all"
    /// buttons above stop being necessary — and something has quietly been
    /// given permission to run.
    func testThePageStillForbidsScripts() {
        let request = HTTPRequest(method: "GET", path: "/",
                                  headers: ["authorization": "Bearer \(token)"])
        let response = makeRouter().respond(to: request)
        // wireHeaders(), not `headers`: the hardening set is added on the way
        // out, so reading the dictionary would test nothing.
        let policy = response.wireHeaders()
            .first { $0.name.lowercased() == "content-security-policy" }?.value
        XCTAssertNotNil(policy)
        XCTAssertTrue(policy?.contains("default-src 'none'") ?? false, policy ?? "none")
        XCTAssertFalse(policy?.contains("script-src") ?? true,
                       "the page has been given permission to run scripts")
    }

    // MARK: The rest of the parity list

    func testTheTrafficLightIsOnTheOverview() {
        let html = page(makeRouter(checks: [
            SystemCheck(id: "source", name: "Importordner", state: .ok, detail: "/downloads"),
            SystemCheck(id: "ffmpeg", name: "FFmpeg", state: .warning, detail: "Nicht gefunden."),
        ]))
        XCTAssertTrue(html.contains("Importordner"))
        XCTAssertTrue(html.contains("Nicht gefunden."))
        // The word as well as the colour.
        XCTAssertTrue(html.contains("prüfen"))
    }

    /// Closed when all is well, open when something is red — because then it
    /// is the thing to read.
    func testTheStatusPanelOpensItselfWhenSomethingIsWrong() {
        let fine = page(makeRouter(checks: [
            SystemCheck(id: "a", name: "A", state: .ok, detail: "fine"),
        ]))
        XCTAssertTrue(fine.contains("<details class=\"card\">"), "should start closed")

        let broken = page(makeRouter(checks: [
            SystemCheck(id: "a", name: "A", state: .failed, detail: "broken"),
        ]))
        XCTAssertTrue(broken.contains("<details class=\"card\" open>"),
                      "a red lamp must not be hidden behind a closed panel")
    }

    func testATransferShowsABarAndNotOnlyASentence() {
        var state = StatusSnapshot()
        state.remoteConfigured = true
        state.transferring = true
        state.transferProgress = 0.42
        state.currentFile = "Dark - S01E01.mkv"
        let html = page(makeRouter(snapshot: state))
        XCTAssertTrue(html.contains("<progress"), "no progress bar")
        XCTAssertTrue(html.contains("value=\"42\""))
        XCTAssertTrue(html.contains("Dark - S01E01.mkv"))
        XCTAssertTrue(html.contains("Stop sending"))
    }

    func testTheVersionIsOnThePageSoABugReportCanNameOne() {
        XCTAssertTrue(page(makeRouter()).contains(MediafinVersion.display))
    }

    // MARK: Knowing that something is happening

    /// The bug this fixes: every button redirects before the work starts, so
    /// a page that only refreshed while `busy` stopped refreshing exactly
    /// when the user was waiting for an answer. Pressing "Check everything"
    /// showed the lamps from before the probe, for ever.
    func testThePageKeepsRefreshingWhileWorkIsOnlyQueued() {
        var queued = StatusSnapshot()
        queued.busy = false
        queued.queuedWork = 1
        let html = page(makeRouter(snapshot: queued))
        XCTAssertTrue(html.contains("http-equiv=\"refresh\""),
                      "the page stops refreshing while the user waits")
        XCTAssertTrue(html.contains("Working"), "and claims to be Ready while working")

        XCTAssertFalse(page(makeRouter()).contains("http-equiv=\"refresh\""),
                       "an idle page must not reload itself for ever")
    }

    /// Clearing the history during a rename throws away the undo journal for
    /// the very files being moved.
    func testTheDangerousButtonsAreUnavailableWhileWorkIsRunning() {
        var working = StatusSnapshot()
        working.queuedWork = 1
        working.done = 3
        let html = page(makeRouter(items: [item("a.mkv", to: "A.mkv")], snapshot: working))
        // Three in the actions card plus the rename submit.
        XCTAssertGreaterThanOrEqual(html.components(separatedBy: " disabled>").count - 1, 4,
                                    "actions stay live while work is running")
    }

    /// Stop has to be reachable before the first byte moves: `transferring`
    /// only becomes true inside the sending loop, long after the redirect.
    func testStopSendingExistsBeforeTheTransferStarts() {
        var state = StatusSnapshot()
        state.remoteConfigured = true
        state.transferring = false
        let html = page(makeRouter(snapshot: state))
        XCTAssertTrue(html.contains("Stop sending"),
                      "there is no way to stop a send that has not reported itself yet")
        XCTAssertTrue(html.contains("<progress"))
    }

    func testThereIsNoTransferCardWithoutAServer() {
        XCTAssertFalse(page(makeRouter()).contains("Stop sending"))
    }

    // MARK: Reading the log at a glance

    func testEachLogRowCarriesTheTimeOfDay() {
        let entry = RenameLogEntry(oldName: "a.mkv", newName: "A.mkv", status: .success)
        let html = page(makeRouter(log: [entry]))
        XCTAssertTrue(html.contains(WebRouter.logTime.string(from: entry.date)),
                      "a persistent log with no times cannot say whether this was today")
    }

    /// One failure among eighteen successes sits below the fold. Without a
    /// count in the header a half-failed run reads as a clean one.
    func testTheHeaderCountsFailuresSoOneCannotHideBelowTheFold() {
        var log = (0..<18).map {
            RenameLogEntry(oldName: "ok\($0).mkv", newName: "Ok \($0).mkv", status: .success)
        }
        log.insert(RenameLogEntry(oldName: "bad.mkv", newName: "Bad.mkv",
                                  status: .failure, errorDescription: "nope"), at: 0)
        let html = page(makeRouter(log: log))
        XCTAssertTrue(html.contains("1 failed"), "a failed run reads as a clean one")
    }

    // MARK: Testing what is on screen

    /// The test used to run against the stored address while the user looked
    /// at a corrected one — and recorded a red lamp for a setting they had
    /// never saved.
    func testTheTestButtonsSaveWhatIsOnScreenFirst() {
        for (path, expected) in [("/settings/test-llm", WebCommand.testLocalLLMConnection),
                                 ("/settings/test-jellyfin", .testJellyfinConnection),
                                 ("/settings/test-remote", .testRemoteConnection)] {
            sink = RecordingSink()
            let router = makeRouter()
            let body = "sourceFolder=/mnt/neu&\(CSRFToken.fieldName)=\(router.csrf.value)"
            let response = router.respond(to: HTTPRequest(
                method: "POST", path: path,
                headers: ["authorization": "Bearer \(token)"],
                body: Data(body.utf8)))
            XCTAssertEqual(response.status, 303, path)

            guard case .saveSettings(let saved)? = sink.commands.first else {
                return XCTFail("\(path) tested without saving first")
            }
            XCTAssertEqual(saved.sourceFolder, "/mnt/neu",
                           "\(path) saved something other than what was submitted")
            XCTAssertTrue(sink.commands.contains(expected), "\(path) never ran the test")
        }
    }

    /// Nothing in the log is HTML. A file named after a tag must not become
    /// one — this column renders names the user never chose.
    func testAFilenameCannotBecomeMarkup() {
        let html = page(makeRouter(log: [
            RenameLogEntry(oldName: "<img src=x onerror=alert(1)>.mkv",
                           newName: "ok.mkv", status: .failure,
                           errorDescription: "</aside><script>alert(2)</script>"),
        ]))
        XCTAssertFalse(html.contains("<img src=x"))
        XCTAssertFalse(html.contains("<script>alert(2)"))
        XCTAssertTrue(html.contains("&lt;img"))
    }
}
