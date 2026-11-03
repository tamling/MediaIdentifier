import XCTest
@testable import MediaIdentifierCore

/// Tests the settings form, the CSRF guard in front of every state change, and
/// that commands reach the app instead of being executed inside the request.
final class WebSettingsRouteTests: XCTestCase {

    private let token = "f00dcafef00dcafef00dcafef00dcafef00dcafef00dcafef00dcafef00dcafe"

    /// Records what the interface asked the app to do.
    private final class RecordingSink: WebCommandSink, @unchecked Sendable {
        private let lock = NSLock()
        private var _commands: [WebCommand] = []
        func submit(_ command: WebCommand) {
            lock.lock(); _commands.append(command); lock.unlock()
        }
        var commands: [WebCommand] { lock.lock(); defer { lock.unlock() }; return _commands }
    }

    /// Holds the settings the router reads back, so a save can be observed.
    private final class SettingsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: WebSettings
        init(_ value: WebSettings) { self.value = value }
        var current: WebSettings { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ new: WebSettings) { lock.lock(); value = new; lock.unlock() }
    }

    private var sink: RecordingSink!
    private var box: SettingsBox!
    private var stored: Set<SecretKey> = []

    override func setUp() {
        super.setUp()
        sink = RecordingSink()
        box = SettingsBox(WebSettings())
        stored = []
    }

    private func makeRouter() -> WebRouter {
        let box = self.box!
        let storedKeys = stored
        return WebRouter(
            policy: WebSecurityPolicy(token: token, isTLS: true),
            settings: { box.current },
            configuredSecrets: { storedKeys },
            commands: sink,
            snapshot: { StatusSnapshot() }
        )
    }

    private func authorizedPost(_ path: String, _ fields: [String: String],
                                router: WebRouter,
                                csrf: String? = nil,
                                extraHeaders: [String: String] = [:]) -> HTTPRequest {
        var body = fields.map { "\(escape($0.key))=\(escape($0.value))" }
        body.append("\(CSRFToken.fieldName)=\(csrf ?? router.csrf.value)")
        var headers = ["authorization": "Bearer \(token)"]
        for (name, value) in extraHeaders { headers[name] = value }
        return HTTPRequest(method: "POST", path: path, headers: headers,
                           body: Data(body.joined(separator: "&").utf8))
    }

    private func escape(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))
        ) ?? value
    }

    private func bodyText(_ response: HTTPResponse) -> String {
        String(decoding: response.body, as: UTF8.self)
    }

    private func validFields() -> [String: String] {
        [
            "sourceFolder": "/mnt/downloads",
            "moviesFolder": "/mnt/media/Movies",
            "seriesFolder": "/mnt/media/Series",
            "identification": "local-llm",
            "localLLMBaseURL": "http://192.168.3.116:1234",
            "localLLMModel": "qwen/qwen3.6-35b-a3b",
            "conflictPolicy": "rename",
        ]
    }

    // MARK: CSRF

    func testStateChangeWithoutACSRFTokenIsRefused() {
        let router = makeRouter()
        let request = authorizedPost("/settings", validFields(), router: router, csrf: "")
        let response = router.respond(to: request)
        XCTAssertEqual(response.status, 403)
        XCTAssertTrue(sink.commands.isEmpty, "nothing may be submitted without a token")
    }

    func testStateChangeWithAWrongCSRFTokenIsRefused() {
        let router = makeRouter()
        let request = authorizedPost("/library/apply", [:], router: router,
                                     csrf: "not-the-token")
        XCTAssertEqual(router.respond(to: request).status, 403)
        XCTAssertTrue(sink.commands.isEmpty)
    }

    /// The token is in every form that changes something, so the page works.
    func testFormsCarryTheCSRFToken() {
        let router = makeRouter()
        let settings = bodyText(router.respond(to: authorizedGet("/settings", router: router)))
        XCTAssertTrue(settings.contains(CSRFToken.fieldName))
        XCTAssertTrue(settings.contains(router.csrf.value))
        XCTAssertTrue(bodyText(router.loginPage()).contains(router.csrf.value))
    }

    func testCrossSiteOriginIsRefusedWithoutSpendingALoginAttempt() {
        let throttle = LoginThrottle(maxAttempts: 2, window: 300)
        let router = WebRouter(policy: WebSecurityPolicy(token: token),
                               throttle: throttle,
                               commands: sink,
                               snapshot: { StatusSnapshot() })
        let request = HTTPRequest(
            method: "POST", path: "/login",
            headers: ["host": "localhost:8720", "origin": "https://evil.example"],
            body: Data("token=\(token)&\(CSRFToken.fieldName)=\(router.csrf.value)".utf8)
        )
        XCTAssertEqual(router.respond(to: request).status, 403)
        XCTAssertFalse(throttle.isBlocked(),
                       "a cross-site request must not be able to lock the real user out")
    }

    func testSameOriginPostIsAccepted() {
        let router = makeRouter()
        // What a browser on https://localhost:8720 actually sends: the Origin
        // carries the port. An earlier version of this test left the port off
        // and so only passed because the check was throwing it away.
        let request = authorizedPost("/library/scan", [:], router: router, extraHeaders: [
            "host": "localhost:8720",
            "origin": "https://localhost:8720",
            "sec-fetch-site": "same-origin",
        ])
        XCTAssertEqual(router.respond(to: request).status, 303)
        XCTAssertEqual(sink.commands, [.scanSourceFolder])
    }

    /// The case the port used to be stripped for. Another service on the same
    /// machine is a different origin, and its cookies reach us anyway because
    /// SameSite is port-blind — so this check is what has to tell them apart.
    func testAnotherPortOnTheSameHostIsRefused() {
        let router = makeRouter()
        let request = authorizedPost("/library/apply", [:], router: router, extraHeaders: [
            "host": "localhost:8720",
            "origin": "http://localhost:8096",
            "sec-fetch-site": "same-site",
        ])
        XCTAssertEqual(router.respond(to: request).status, 403)
        XCTAssertTrue(sink.commands.isEmpty, "a cross-origin POST must change nothing")
    }

    /// `same-site` is reported for a different port, so it cannot be treated
    /// as proof of a same-origin request.
    func testSameSiteFetchMetadataAloneIsRefused() {
        let router = makeRouter()
        let request = authorizedPost("/library/apply", [:], router: router,
                                     extraHeaders: ["sec-fetch-site": "same-site"])
        XCTAssertEqual(router.respond(to: request).status, 403)
        XCTAssertTrue(sink.commands.isEmpty)
    }

    func testCrossSiteFetchMetadataIsRefused() {
        let router = makeRouter()
        let request = authorizedPost("/library/apply", [:], router: router,
                                     extraHeaders: ["sec-fetch-site": "cross-site"])
        XCTAssertEqual(router.respond(to: request).status, 403)
    }

    /// An unticked checkbox sends nothing at all, so for the clear-secret
    /// flags the body has no value to override a query parameter with. They
    /// are therefore read from the body alone: otherwise posting the settings
    /// form to a URL carrying ?clear-tmdbAPIKey=1 would wipe a stored key
    /// while reporting an ordinary successful save.
    func testAQueryParameterCannotClearAStoredSecret() {
        let router = makeRouter()
        var request = authorizedPost("/settings", validFields(), router: router)
        request.query = ["clear-tmdbAPIKey": "1"]

        XCTAssertEqual(router.respond(to: request).status, 303)
        XCTAssertFalse(
            sink.commands.contains(.setSecret(.tmdbAPIKey, "")),
            "a query parameter must not be able to delete a stored credential"
        )
    }

    /// The ticked checkbox, in the body, still works.
    func testTheClearCheckboxInTheBodyStillClearsTheSecret() {
        let router = makeRouter()
        var fields = validFields()
        fields["clear-tmdbAPIKey"] = "1"
        let request = authorizedPost("/settings", fields, router: router)

        XCTAssertEqual(router.respond(to: request).status, 303)
        XCTAssertTrue(sink.commands.contains(.setSecret(.tmdbAPIKey, "")))
    }

    /// And a secret submitted in the body is still stored.
    func testASecretInTheBodyIsStored() {
        let router = makeRouter()
        var fields = validFields()
        fields["jellyfinToken"] = "s3cret-value"
        let request = authorizedPost("/settings", fields, router: router)

        XCTAssertEqual(router.respond(to: request).status, 303)
        XCTAssertTrue(sink.commands.contains(.setSecret(.jellyfinToken, "s3cret-value")))
    }

    /// A credential must not be settable from a URL either — those end up in
    /// logs, shell history and bookmarks.
    func testAQueryParameterCannotSetASecret() {
        let router = makeRouter()
        var request = authorizedPost("/settings", validFields(), router: router)
        request.query = ["jellyfinToken": "leaked-through-the-url"]

        XCTAssertEqual(router.respond(to: request).status, 303)
        XCTAssertFalse(
            sink.commands.contains(.setSecret(.jellyfinToken, "leaked-through-the-url"))
        )
    }

    /// A POST to a route that is not meant to change anything is refused
    /// before authentication or CSRF even come up.
    func testPostToAReadOnlyRouteIs405() {
        let router = makeRouter()
        XCTAssertEqual(router.respond(to: authorizedPost("/api/status", [:], router: router)).status,
                       405)
        XCTAssertEqual(router.respond(to: authorizedPost("/healthz", [:], router: router)).status,
                       405)
    }

    func testUnauthenticatedStateChangeIsRefused() {
        let router = makeRouter()
        let request = HTTPRequest(
            method: "POST", path: "/library/apply",
            body: Data("\(CSRFToken.fieldName)=\(router.csrf.value)".utf8)
        )
        XCTAssertEqual(router.respond(to: request).status, 401)
        XCTAssertTrue(sink.commands.isEmpty)
    }

    // MARK: Saving settings

    func testValidSettingsAreSubmittedAndRedirect() {
        let router = makeRouter()
        let response = router.respond(to: authorizedPost("/settings", validFields(),
                                                         router: router))
        XCTAssertEqual(response.status, 303)
        XCTAssertEqual(response.headers["Location"], "/settings?saved=1")

        guard case .saveSettings(let saved)? = sink.commands.first else {
            return XCTFail("expected a saveSettings command, got \(sink.commands)")
        }
        XCTAssertEqual(saved.sourceFolder, "/mnt/downloads")
        XCTAssertEqual(saved.identification, .localLLM)
        XCTAssertEqual(saved.localLLMModel, "qwen/qwen3.6-35b-a3b")
        XCTAssertEqual(saved.conflictPolicy, .rename)
    }

    func testInvalidSettingsAreNotSavedAndTheFormSaysWhy() {
        let router = makeRouter()
        var fields = validFields()
        fields["sourceFolder"] = "relative/path"
        fields["localLLMBaseURL"] = "javascript:alert(1)"
        let response = router.respond(to: authorizedPost("/settings", fields, router: router))

        XCTAssertEqual(response.status, 422)
        XCTAssertTrue(sink.commands.isEmpty, "nothing may be saved when the form is wrong")
        let body = bodyText(response)
        XCTAssertTrue(body.contains("must be an absolute path"), body)
        XCTAssertTrue(body.contains("must look like http://host:port"), body)
    }

    func testTrailingSlashesAndWhitespaceAreTrimmed() {
        let router = makeRouter()
        var fields = validFields()
        fields["sourceFolder"] = "  /mnt/downloads/  "
        fields["localLLMBaseURL"] = "http://192.168.3.116:1234/"
        _ = router.respond(to: authorizedPost("/settings", fields, router: router))
        guard case .saveSettings(let saved)? = sink.commands.first else {
            return XCTFail("expected a saveSettings command")
        }
        XCTAssertEqual(saved.sourceFolder, "/mnt/downloads")
        XCTAssertEqual(saved.localLLMBaseURL, "http://192.168.3.116:1234")
    }

    func testCheckboxOffIsDistinguishedFromAbsent() {
        var withWatching = WebSettings()
        withWatching.watchSourceFolder = true
        box.set(withWatching)

        let router = makeRouter()
        var fields = validFields()
        fields["watchSourceFolderPresent"] = "1"   // the form was submitted…
        // …and the checkbox was not ticked, so it must turn off.
        _ = router.respond(to: authorizedPost("/settings", fields, router: router))
        guard case .saveSettings(let saved)? = sink.commands.first else {
            return XCTFail("expected a saveSettings command")
        }
        XCTAssertFalse(saved.watchSourceFolder)
    }

    // MARK: Secrets

    func testASecretIsSubmittedSeparatelyFromTheSettings() {
        let router = makeRouter()
        var fields = validFields()
        fields["localLLMAPIKey"] = "super-secret-key"
        _ = router.respond(to: authorizedPost("/settings", fields, router: router))

        XCTAssertTrue(sink.commands.contains(.setSecret(.localLLMAPIKey, "super-secret-key")))
        guard case .saveSettings(let saved)? = sink.commands.first else {
            return XCTFail("expected a saveSettings command")
        }
        // The settings value is what gets written to the config file, so the
        // key must not have ended up anywhere in it.
        let encoded = try? JSONEncoder().encode(saved)
        let text = encoded.map { String(decoding: $0, as: UTF8.self) } ?? ""
        XCTAssertFalse(text.contains("super-secret-key"),
                       "a credential must not be stored in the settings file")
    }

    func testAnEmptySecretFieldLeavesTheStoredKeyAlone() {
        stored = [.localLLMAPIKey]
        let router = makeRouter()
        var fields = validFields()
        fields["localLLMAPIKey"] = ""
        _ = router.respond(to: authorizedPost("/settings", fields, router: router))
        XCTAssertFalse(sink.commands.contains { command in
            if case .setSecret = command { return true }
            return false
        }, "saving the page without retyping the key must not wipe it")
    }

    func testASecretCanBeRemovedDeliberately() {
        stored = [.jellyfinToken]
        let router = makeRouter()
        var fields = validFields()
        fields["clear-jellyfinToken"] = "1"
        _ = router.respond(to: authorizedPost("/settings", fields, router: router))
        XCTAssertTrue(sink.commands.contains(.setSecret(.jellyfinToken, "")))
    }

    func testThePageShowsWhetherASecretIsStoredButNeverItsValue() {
        stored = [.localLLMAPIKey]
        let router = makeRouter()
        let page = bodyText(router.respond(to: authorizedGet("/settings", router: router)))
        XCTAssertTrue(page.contains("stored — leave blank to keep"), page)
        XCTAssertTrue(page.contains("clear-localLLMAPIKey"))
        XCTAssertTrue(page.contains("not set"), "an unset key says so")
        XCTAssertTrue(page.contains("type=\"password\""))
    }

    // MARK: Actions

    func testEachActionSubmitsItsCommandAndRedirects() {
        let expected: [(String, WebCommand)] = [
            ("/library/scan", .scanSourceFolder),
            ("/library/apply", .applyProposedRenames(accepting: nil)),
            ("/library/undo", .undoLastRename),
            ("/convert/scan", .findConvertible),
            ("/history/clear", .clearHistory),
            ("/settings/test-llm", .testLocalLLMConnection),
            ("/settings/test-jellyfin", .testJellyfinConnection),
        ]
        for (path, command) in expected {
            sink = RecordingSink()
            let router = makeRouter()
            let response = router.respond(to: authorizedPost(path, [:], router: router))
            XCTAssertEqual(response.status, 303, path)
            XCTAssertEqual(sink.commands, [command], path)
        }
    }

    /// The command is handed over, not run: the response must come back without
    /// waiting for the work.
    func testActionsDoNotRunInsideTheRequest() {
        let router = makeRouter()
        let response = router.respond(to: authorizedPost("/library/apply", [:], router: router))
        XCTAssertEqual(response.status, 303)
        XCTAssertEqual(response.headers["Location"], "/")
    }

    func testSettingsPageReportsWhatJustHappened() {
        let router = makeRouter()
        let saved = HTTPRequest(method: "GET", path: "/settings", query: ["saved": "1"],
                                headers: ["authorization": "Bearer \(token)"])
        XCTAssertTrue(bodyText(router.respond(to: saved)).contains("Settings saved."))

        let tested = HTTPRequest(method: "GET", path: "/settings", query: ["tested": "llm"],
                                 headers: ["authorization": "Bearer \(token)"])
        XCTAssertTrue(bodyText(router.respond(to: tested)).contains("Testing the model server"))
    }

    // MARK: Escaping

    /// A value that came back from the settings file must not be able to break
    /// out of its attribute.
    func testSettingsValuesAreEscapedInTheForm() {
        var hostile = WebSettings()
        hostile.sourceFolder = "/mnt/\"><script>alert(1)</script>"
        box.set(hostile)
        let router = makeRouter()
        let page = bodyText(router.respond(to: authorizedGet("/settings", router: router)))
        XCTAssertFalse(page.contains("<script>alert(1)</script>"))
        XCTAssertTrue(page.contains("&quot;&gt;&lt;script&gt;"))
    }

    private func authorizedGet(_ path: String, router: WebRouter) -> HTTPRequest {
        HTTPRequest(method: "GET", path: path, headers: ["authorization": "Bearer \(token)"])
    }
}
