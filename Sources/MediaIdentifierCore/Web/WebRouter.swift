import Foundation

/// Routes requests for the local web interface and enforces the security
/// policy in front of every route.
///
/// Pure: it maps a parsed request to a response and touches neither sockets nor
/// TLS, so the whole access-control surface is unit-testable on any platform.
/// Anything slow is handed to a `WebCommandSink` and reported back through the
/// status snapshot, so no request waits on work.
public struct WebRouter: Sendable {
    /// How much of the interface is served.
    public enum Mode: Sendable, Equatable {
        /// Everything: settings, the file list, converting, history.
        case full
        /// Status only, read-only. Used by the macOS app, which has its own
        /// native interface and only needs something a monitor can poll.
        case statusOnly
    }

    public var policy: WebSecurityPolicy
    public let mode: Mode
    /// Token required by every state-changing request, exposed so a form can
    /// embed it and a test can present it.
    public let csrf: CSRFToken

    private let throttle: LoginThrottle
    private let snapshot: @Sendable () -> StatusSnapshot
    private let settings: @Sendable () -> WebSettings
    private let configuredSecrets: @Sendable () -> Set<SecretKey>
    private let items: @Sendable () -> [RenameItem]
    private let logEntries: @Sendable () -> [RenameLogEntry]
    private let convertible: @Sendable () -> [ConversionCandidate]
    private let ffmpegAvailable: @Sendable () -> Bool
    private let systemChecks: @Sendable () -> [SystemCheck]
    private let commands: WebCommandSink?

    public init(policy: WebSecurityPolicy,
                mode: Mode = .full,
                throttle: LoginThrottle = LoginThrottle(),
                csrf: CSRFToken = CSRFToken(),
                settings: @escaping @Sendable () -> WebSettings = { WebSettings() },
                configuredSecrets: @escaping @Sendable () -> Set<SecretKey> = { [] },
                items: @escaping @Sendable () -> [RenameItem] = { [] },
                logEntries: @escaping @Sendable () -> [RenameLogEntry] = { [] },
                convertible: @escaping @Sendable () -> [ConversionCandidate] = { [] },
                ffmpegAvailable: @escaping @Sendable () -> Bool = { false },
                systemChecks: @escaping @Sendable () -> [SystemCheck] = { [] },
                commands: WebCommandSink? = nil,
                snapshot: @escaping @Sendable () -> StatusSnapshot) {
        self.policy = policy
        self.mode = mode
        self.throttle = throttle
        self.csrf = csrf
        self.settings = settings
        self.configuredSecrets = configuredSecrets
        self.items = items
        self.logEntries = logEntries
        self.convertible = convertible
        self.ffmpegAvailable = ffmpegAvailable
        self.systemChecks = systemChecks
        self.commands = commands
        self.snapshot = snapshot
    }

    /// Paths that accept a POST. Everything else is read-only, so a stray
    /// request cannot change anything by reaching an unintended route.
    static let writablePaths: Set<String> = [
        "/login", "/logout", "/settings",
        "/settings/test-llm", "/settings/test-jellyfin", "/settings/test-remote",
        "/library/scan", "/library/apply", "/library/undo",
        "/library/send", "/library/send-cancel",
        "/library/select-all", "/library/select-none",
        "/library/download", "/library/download-cancel",
        "/convert/scan", "/convert/start", "/convert/cancel",
        "/system/check",
        "/history/clear",
    ]

    // MARK: Entry point

    public func respond(to request: HTTPRequest) -> HTTPResponse {
        guard request.isReadOnly || request.method == "POST" else {
            return .methodNotAllowed()
        }
        if request.method == "POST", !Self.writablePaths.contains(request.path) {
            return .methodNotAllowed()
        }
        // In status-only mode nothing can be changed at all, so a write is
        // refused before it reaches any handler.
        if mode == .statusOnly, request.method == "POST",
           request.path != "/login", request.path != "/logout" {
            return .methodNotAllowed()
        }

        // A liveness probe cannot log in, so it may stay anonymous. It answers
        // with idle/busy/error only — no names, no paths.
        if request.path == "/healthz", request.isReadOnly, policy.allowAnonymousHealth {
            return health()
        }

        if request.method == "POST" {
            // Checked before the credentials: a cross-site request must not be
            // able to spend login attempts and lock the real user out.
            guard RequestOrigin.isSameSite(request, isTLS: policy.isTLS) else {
                return .text("cross-site request refused", status: 403)
            }
            let fields = Self.formFields(of: request)
            guard csrf.matches(fields[CSRFToken.fieldName]) else {
                return .text("this form has expired — reload the page and try again",
                             status: 403)
            }
            if request.path == "/login" { return performLogin(fields) }
            guard isAuthorized(request) else { return unauthorized(for: request) }
            return performAction(request, fields: fields)
        }

        if request.path == "/login" { return loginPage() }

        guard isAuthorized(request) else { return unauthorized(for: request) }

        if mode == .statusOnly {
            switch request.path {
            case "/", "/index.html":
                return .html(StatusHTTP.html(snapshot()))
            case "/api/status", "/api/status/":
                return .json(StatusHTTP.json(snapshot()))
            case "/healthz":
                return health()
            default:
                return .notFound()
            }
        }

        switch request.path {
        case "/", "/index.html":
            return overviewPage()
        case "/settings":
            return settingsPage(settings(), notice: Self.notice(for: request.query))
        case "/convert":
            return convertPage()
        case "/history":
            return historyPage()
        case "/history/export":
            return exportedLog()
        case "/api/status", "/api/status/":
            return .json(StatusHTTP.json(snapshot()))
        case "/healthz":
            return health()
        default:
            return .notFound()
        }
    }

    // MARK: Access control

    /// True when the request may proceed. With authentication switched off
    /// everything is allowed; with it on, an unset token refuses everything.
    public func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard policy.requireAuth else { return true }
        guard let presented = WebAuth.presentedToken(in: request) else { return false }
        return policy.matches(presented)
    }

    /// 401 for the API (so a client sees a clear status) and the login page for
    /// a browser — also with 401, so no route ever pretends to have succeeded.
    private func unauthorized(for request: HTTPRequest) -> HTTPResponse {
        if request.path.hasPrefix("/api/") {
            var response = HTTPResponse.json(Data(#"{"error":"unauthorized"}"#.utf8), status: 401)
            response.headers["WWW-Authenticate"] = #"Bearer realm="Mediafin""#
            return response
        }
        return loginPage(status: 401, message: Text.s("Bitte anmelden.", "Please sign in."))
    }

    private func performLogin(_ fields: [String: String]) -> HTTPResponse {
        if throttle.isBlocked() {
            var response = loginPage(status: 429,
                                     message: Text.s("Zu viele Versuche. Bitte warten und erneut versuchen.", "Too many attempts. Please wait and try again."))
            response.headers["Retry-After"] = String(throttle.retryAfterSeconds())
            return response
        }
        guard policy.matches(fields["token"] ?? "") else {
            throttle.recordFailure()
            // No hint about why: not whether the token was close, nor whether
            // one is configured at all.
            return loginPage(status: 401, message: Text.s("Falscher Zugangs-Token.", "Wrong access token."))
        }
        throttle.recordSuccess()
        // The cookie carries the token itself rather than a separate session
        // id. That keeps the server stateless, and the cookie is already as
        // protected as it can be: HttpOnly, SameSite=Strict and, over TLS,
        // Secure. Revoking access means rotating the token.
        return redirect(to: "/", setCookie: policy.sessionCookie(value: policy.token))
    }

    // MARK: Actions

    private func performAction(_ request: HTTPRequest,
                               fields: [String: String]) -> HTTPResponse {
        switch request.path {
        case "/logout":
            return redirect(to: "/login", setCookie: policy.clearedCookie())
        case "/settings":
            return saveSettings(fields, body: Self.bodyFields(of: request))
        case "/settings/test-llm":
            if let refused = applySubmitted(fields, body: Self.bodyFields(of: request)) {
                return refused
            }
            submit(.testLocalLLMConnection)
            return redirect(to: "/settings?tested=llm")
        case "/settings/test-jellyfin":
            if let refused = applySubmitted(fields, body: Self.bodyFields(of: request)) {
                return refused
            }
            submit(.testJellyfinConnection)
            return redirect(to: "/settings?tested=jellyfin")
        case "/settings/test-remote":
            if let refused = applySubmitted(fields, body: Self.bodyFields(of: request)) {
                return refused
            }
            submit(.testRemoteConnection)
            return redirect(to: "/settings?tested=remote")
        case "/library/scan":
            submit(.scanSourceFolder)
            return redirect(to: "/")
        case "/library/apply":
            submit(.applyProposedRenames(accepting: Self.selectedItemIDs(in: request)))
            return redirect(to: "/")
        case "/library/download":
            submit(.downloadURL(fields["url"] ?? ""))
            return redirect(to: "/")
        case "/library/download-cancel":
            submit(.cancelDownload)
            return redirect(to: "/")
        case "/library/select-all":
            submit(.setAllAccepted(true))
            return redirect(to: "/")
        case "/library/select-none":
            submit(.setAllAccepted(false))
            return redirect(to: "/")
        case "/library/send":
            // Only the ticked files, and only because a button was pressed.
            submit(.transferFiles(accepting: Self.selectedItemIDs(in: request) ?? []))
            return redirect(to: "/")
        case "/library/send-cancel":
            submit(.cancelTransfers)
            return redirect(to: "/")
        case "/system/check":
            submit(.checkEverything)
            return redirect(to: "/")
        case "/library/undo":
            submit(.undoLastRename)
            return redirect(to: "/")
        case "/convert/scan":
            submit(.findConvertible)
            return redirect(to: "/convert")
        case "/convert/start":
            // Only the ticked files, and only because a button was pressed.
            submit(.convertFiles(accepting: Self.selectedItemIDs(in: request) ?? []))
            return redirect(to: "/convert")
        case "/convert/cancel":
            submit(.cancelConversions)
            return redirect(to: "/convert")
        case "/history/clear":
            submit(.clearHistory)
            return redirect(to: "/")
        default:
            return .notFound()
        }
    }

    /// - Parameter body: the POST body alone, without the query string merged
    ///   in. The clear-secret flags are read from this rather than from
    ///   `fields`: an unticked checkbox sends nothing at all, so for those
    ///   fields the body cannot override a query parameter and a crafted URL
    ///   would wipe a stored key on an ordinary save.
    private func saveSettings(_ fields: [String: String],
                              body: [String: String]) -> HTTPResponse {
        if let refused = applySubmitted(fields, body: body) { return refused }
        return redirect(to: Self.settingsReturnPath(fields) + "?saved=1")
    }

    /// Stores what the form carried, or returns the page to send back.
    ///
    /// Shared with the three test buttons, which submit the same form: a
    /// test that ran against the stored address while the user is looking at
    /// a corrected one reports on the wrong server, and records a red lamp
    /// for a setting they never saved.
    ///
    /// - Returns: nil when everything was stored, or the response to send.
    private func applySubmitted(_ fields: [String: String],
                                body: [String: String]) -> HTTPResponse? {
        let submitted = WebSettings.fromForm(fields, current: settings())
        let problems = submitted.problems()
        guard problems.isEmpty else {
            // A mistake in the conversion form must come back on that page.
            if Self.settingsReturnPath(fields) == "/convert" {
                return convertPage(problems: problems, status: 422)
            }
            return settingsPage(submitted, problems: problems, status: 422)
        }
        submit(.saveSettings(submitted))

        // Secrets travel in the same form but are stored separately. An empty
        // field means "leave it alone", so a saved key is not wiped by someone
        // saving the page without retyping it.
        for key in SecretKey.allCases {
            if body["clear-\(key.formField)"] != nil {
                submit(.setSecret(key, ""))
                continue
            }
            if let value = body[key.formField], !value.isEmpty {
                submit(.setSecret(key, value))
            }
        }
        return nil
    }

    /// Where to go after saving, so the convert page's own form comes back to
    /// itself. Only these two paths are honoured: a redirect target is never
    /// taken from the request as given.
    static func settingsReturnPath(_ fields: [String: String]) -> String {
        fields["after"] == "/convert" ? "/convert" : "/settings"
    }

    private func submit(_ command: WebCommand) {
        commands?.submit(command)
    }

    // MARK: Routes

    private func health() -> HTTPResponse {
        let result = StatusHTTP.health(snapshot())
        return .text(result.body, status: Int(result.status.prefix(3)) ?? 200)
    }

    private func redirect(to location: String, setCookie: String? = nil) -> HTTPResponse {
        var response = HTTPResponse(status: 303, contentType: "text/plain; charset=utf-8",
                                    body: Data("ok".utf8))
        // Always a fixed, internal location: no route takes a redirect target
        // from the request, so the interface cannot bounce anyone elsewhere.
        response.headers["Location"] = location
        if let setCookie { response.headers["Set-Cookie"] = setCookie }
        return response
    }

    /// The items the user ticked, or nil when the form carried no selection at
    /// all (so "apply" from somewhere without checkboxes still means
    /// everything).
    ///
    /// Read with the multi-valued parser: a set of checkboxes sharing a name
    /// submits that name once per tick, and the single-valued form would see
    /// only the first.
    static func selectedItemIDs(in request: HTTPRequest) -> Set<UUID>? {
        let fields = HTTPRequestParser.parseFormEncodedMulti(
            String(decoding: request.body, as: UTF8.self)
        )
        let ids = (fields[Self.selectionField] ?? []).compactMap { UUID(uuidString: $0) }
        if !ids.isEmpty { return Set(ids) }
        // The hidden companion distinguishes "the list was shown and nothing
        // was ticked" from "this form carries no selection".
        return fields[Self.selectionPresentField] != nil ? [] : nil
    }

    /// Name each ticked item is submitted under.
    static let selectionField = "items"
    static let selectionPresentField = "itemsPresent"

    /// Form fields of a POST, from the body and the query string. The body
    /// wins, so a link cannot pre-set a field the form also carries.
    ///
    /// Note what that does *not* cover: a checkbox sends nothing when it is
    /// unticked, so for a field that is absent-when-off the body has no value
    /// to win with and the query survives. Anything acting on mere presence —
    /// the clear-secret flags — must read `bodyFields` instead.
    static func formFields(of request: HTTPRequest) -> [String: String] {
        var fields = request.query
        for (name, value) in bodyFields(of: request) { fields[name] = value }
        return fields
    }

    /// The POST body alone, with no query parameters merged in.
    static func bodyFields(of request: HTTPRequest) -> [String: String] {
        HTTPRequestParser.parseFormEncoded(String(decoding: request.body, as: UTF8.self))
    }

    // MARK: Pages

    /// The overview: what is happening, what is proposed, and the buttons.
    ///
    /// No JavaScript anywhere, so the page works with scripting forbidden
    /// outright by its own Content-Security-Policy.
    func overviewPage() -> HTTPResponse {
        let state = snapshot()
        let proposals = items()
        let settings = settings()

        let stateLabel: String
        let stateClass: String
        if state.hasError {
            stateLabel = Text.s("Mit Fehlern beendet", "Finished with errors")
            stateClass = "bad"
        } else if state.isWorking {
            stateLabel = state.busy
                ? "\(state.convertStatus ?? Text.s("Arbeitet", "Working")) "
                    + "\(state.activePercent) %"
                : Text.s("Arbeitet …", "Working…")
            stateClass = "busy"
        } else {
            stateLabel = Text.s("Bereit", "Ready")
            stateClass = "ok"
        }

        let result = state.lastResult.map {
            "<p class=\"result\">\(Self.escape($0))</p>"
        } ?? ""

        let needsSetup = settings.sourceFolder.isEmpty
        let setupHint = needsSetup ? """
        <p class="hint">\(Text.s("Es ist noch kein Importordner gesetzt.",
                                 "No import folder is set yet.")) \
        <a href="/settings">\(Text.s("Einstellungen öffnen", "Open the settings"))</a>\
        \(Text.s(", um einen zu wählen.", " to choose one."))</p>
        """ : ""

        var rows = ""
        for item in proposals {
            let conflict = item.conflict.map {
                "<span class=\"flag\">\(Self.escape(Self.conflictLabel($0)))</span>"
            } ?? ""
            rows += """
            <tr>
              <td class="tick"><input type="checkbox" name="\(Self.selectionField)" \
            value="\(item.id.uuidString)"\(item.isAccepted ? " checked" : "")></td>
              <td>
                <div class="from">\(Self.escape(item.originalFileName))</div>
                <div class="to">→ \(Self.escape(item.proposedRelativePath)) \(conflict)</div>
              </td>
            </tr>
            """
        }

        // The same ticked rows, sent somewhere else. `formaction` reuses the
        // one form rather than duplicating the table into a second one,
        // which would let the two lists of ticks drift apart.
        let sendButton = state.remoteConfigured ? """
        <button type="submit" formaction="/library/send"\(state.isWorking ? " disabled" : "")>\
        Send the ticked files to the server</button>
        """ : ""

        let list = proposals.isEmpty ? """
        <p class="hint">\(Text.s("Noch nichts vorgeschlagen.", "Nothing proposed yet."))\(needsSetup ? "" : " " + Text.s("„Nach neuen Dateien sehen“ benutzen.", "Use “Look for new files”."))</p>
        """ : """
        <form method="post" action="/library/apply">
          \(csrf.hiddenField)
          <input type="hidden" name="\(Self.selectionPresentField)" value="1">
          <table>\(rows)</table>
          <button type="submit"\(state.isWorking ? " disabled" : "")>\
        \(Text.s("Angehakte umbenennen", "Rename the ticked files"))</button>
          \(sendButton)
        </form>
        <form method="post" action="/library/select-all" class="inline-form bare">
          \(csrf.hiddenField)<button type="submit" class="link">\
        \(Text.s("Alle anhaken", "Tick all"))</button>
        </form>
        <form method="post" action="/library/select-none" class="inline-form bare">
          \(csrf.hiddenField)<button type="submit" class="link">\
        \(Text.s("Alle abhaken", "Tick none"))</button>
        </form>
        """

        // A bar as well as the sentence. <progress> is plain HTML, so it
        // works under a policy that forbids scripts outright. sftp reports
        // nothing, so the bar then tracks whole files rather than bytes —
        // which is what transferSummary says in words.
        let transfer = state.remoteConfigured ? """
        <div class="card">
          <h2>\(Text.s("Zum Server senden", "Sending to the server"))</h2>
          <progress max="100" value="\(state.transferring ? state.activePercent : 0)"></progress>
          <p class="sub">\(Self.escape(state.transferSummary))</p>
          <form method="post" action="/library/send-cancel">
            \(csrf.hiddenField)
            <button type="submit"\(state.transferring ? "" : " disabled")>\
        \(Text.s("Senden stoppen", "Stop sending"))</button>
          </form>
        </div>
        """ : ""

        // Only while something is being fetched: a bar at zero when nothing
        // is happening reads as a stall. No value attribute at all when the
        // size is unknown, which renders as an indeterminate bar — honest
        // for a stream with no Content-Length.
        let download = state.downloading ? """
        <progress max="100" \(state.downloadProgress.map {
            "value=\"\(Int(($0 * 100).rounded()))\""
        } ?? "")></progress>
        <p class="sub">\(Self.escape(state.downloadDetail
            ?? Text.s("Wird geladen …", "Fetching…")))</p>
        <form method="post" action="/library/download-cancel" class="bare inline-form">
          \(csrf.hiddenField)<button type="submit" class="link">\
        \(Text.s("Laden stoppen", "Stop fetching"))</button>
        </form>
        """ : ""

        let counts = Text.s(
            "\(state.totalItems) vorgeschlagen · \(state.done) bisher umbenannt",
            "\(state.totalItems) proposed · \(state.done) renamed so far")

        // The traffic light. A dot carries the colour and a word carries the
        // same thing again, because colour alone is unreadable to about one
        // man in twelve.
        let checks = systemChecks()
        let lamps = checks.map { check in
            """
            <tr>
              <td><span class="lamp lamp-\(check.state.rawValue)">\u{25CF}</span></td>
              <td><strong>\(Self.escape(check.name))</strong><br>
                  <span class="hint">\(Self.escape(check.detail))</span></td>
              <td class="hint">\(Self.escape(check.state.word))</td>
            </tr>
            """
        }.joined()
        // <details> rather than a permanently open card, so seven rows of
        // detail do not push the proposals off the screen — the same reason
        // the window puts it behind an expander. Open when something is
        // wrong, because then it is the thing to read.
        let worst = SystemChecks.worst(checks)
        let panel = checks.isEmpty ? "" : """
        <details class="card"\(worst == .failed ? " open" : "")>
          <summary><strong>\(Text.s("Status", "Status"))</strong> — \
        \(Self.escape(SystemChecks.summary(checks)))</summary>
          <table>\(lamps)</table>
          <form method="post" action="/system/check">
            \(csrf.hiddenField)
            <button type="submit">\(Text.s("Alles prüfen", "Check everything"))</button>
          </form>
        </details>
        """

        let logAside = Self.logAside(logEntries())

        return .html("""
        <!DOCTYPE html>
        <html lang="\(Text.language.rawValue)"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        \(state.isWorking ? "<meta http-equiv=\"refresh\" content=\"2\">" : "")
        <title>Mediafin</title>
        \(Self.styles)
        </head>
        <body>
        <div class="page wide">
          \(Self.navigation(current: "/"))
          <div class="split">
            <div class="work">
              <div class="card">
                <h1>Mediafin</h1>
                <span class="badge \(stateClass)">\(Self.escape(stateLabel))</span>
                <p class="sub">\(Self.escape(counts))</p>
                \(result)
                \(setupHint)
              </div>

              \(panel)

              <div class="card">
                <h2>\(Text.s("Aus dem Netz laden", "Fetch from a link"))</h2>
                <form method="post" action="/library/download">
                  \(csrf.hiddenField)
                  <label for="url">\(Text.s("Adresse des Videos",
                                             "Address of the video"))</label>
                  <input id="url" name="url" type="text" placeholder="https://…"\
        \(state.isWorking ? " disabled" : "")>
                  <p class="hint">\(Text.s(
                    "Landet im Importordner und wird dann wie jede andere gefundene "
                        + "Datei vorgeschlagen. Nur http und https.",
                    "It lands in the import folder and is then proposed like anything "
                        + "else found there. Only http and https."))</p>
                  <button type="submit"\(needsSetup || state.isWorking ? " disabled" : "")>\
        \(Text.s("Laden", "Fetch"))</button>
                </form>
                \(download)
              </div>

              <div class="card">
                <h2>\(Text.s("Vorgeschlagene Namen", "Proposed renames"))</h2>
                \(list)
              </div>

              \(transfer)

              <div class="card actions">
                <form method="post" action="/library/scan">
                  \(csrf.hiddenField)
                  <button type="submit"\(needsSetup || state.isWorking ? " disabled" : "")>\
        \(Text.s("Nach neuen Dateien sehen", "Look for new files"))</button>
                </form>
                <form method="post" action="/library/undo">
                  \(csrf.hiddenField)
                  <button type="submit"\(state.done == 0 || state.isWorking ? " disabled" : "")>\
        \(Text.s("Letzten Lauf rückgängig", "Undo the last run"))</button>
                </form>
                <form method="post" action="/history/clear">
                  \(csrf.hiddenField)
                  <button type="submit"\(state.done == 0 || state.isWorking ? " disabled" : "")>\
        \(Text.s("Verlauf leeren", "Clear the history"))</button>
                </form>
              </div>

              <p class="footer">Mediafin \(Self.escape(MediafinVersion.display))</p>
            </div>
            \(logAside)
          </div>
        </div>
        </body></html>
        """)
    }

    /// Files that could be re-encoded, with the options and a start button.
    ///
    /// Nothing is converted without this button being pressed, and the output
    /// is written beside the original — which is why the page says so plainly
    /// rather than leaving the user to guess what happens to their media.
    func convertPage(problems: [WebSettings.Problem] = [],
                     status: Int = 200) -> HTTPResponse {
        let state = snapshot()
        let settings = settings().conversion
        let candidates = convertible()
        let haveFFmpeg = ffmpegAvailable()

        let missingFFmpeg = haveFFmpeg ? "" : """
        <p class="note">FFmpeg was not found, so nothing can be converted. \
        Install it — <code>apt install ffmpeg</code> on Debian or Ubuntu — or \
        set its path below.</p>
        """

        var rows = ""
        for candidate in candidates {
            rows += """
            <tr>
              <td class="tick"><input type="checkbox" name="\(Self.selectionField)" \
            value="\(candidate.id.uuidString)"></td>
              <td><div class="to">\(Self.escape(candidate.fileName))</div></td>
              <td class="right-cell"><span class="hint">\(Self.escape(candidate.readableSize))</span></td>
            </tr>
            """
        }

        let list: String
        if state.converting {
            let file = state.currentFile.map { Self.escape($0) } ?? "a file"
            list = """
            <p class="sub">Converting \(file) — \(state.activePercent) % \
            (\(state.pendingConversions) still queued)</p>
            <form method="post" action="/convert/cancel">
              \(csrf.hiddenField)
              <button type="submit">\(Text.s("Nach dieser Datei stoppen", "Stop after this file"))</button>
            </form>
            """
        } else if candidates.isEmpty {
            list = """
            <p class="hint">\(Text.s("Noch nichts gefunden. „Nach Dateien sehen“ durchsucht die Bibliotheksordner nach Videos, die noch nicht konvertiert sind.", "Nothing found yet. “Look for files” searches your library folders for videos that are not already converted."))</p>
            """
        } else {
            list = """
            <form method="post" action="/convert/start">
              \(csrf.hiddenField)
              <input type="hidden" name="\(Self.selectionPresentField)" value="1">
              <table>\(rows)</table>
              <button type="submit"\(haveFFmpeg ? "" : " disabled")>\
            \(Text.s("Angehakte konvertieren", "Convert the ticked files"))</button>
              <p class="hint">The result is written beside the original, as \
            <code>…\(Self.escape(".\(ConversionOutput.marker(for: settings.options))"))\
            .mkv</code>. Nothing is deleted — remove the originals yourself once \
            you are happy.</p>
            </form>
            """
        }

        func options<T: Equatable>(_ all: [T], _ current: T,
                                   value: (T) -> String, label: (T) -> String) -> String {
            all.map { item in
                let selected = item == current ? " selected" : ""
                return "<option value=\"\(value(item))\"\(selected)>\(Self.escape(label(item)))</option>"
            }.joined()
        }

        let codecOptions = options(ConversionOptions.VideoCodec.allCases, settings.videoCodec,
                                   value: { $0.rawValue },
                                   label: { Self.codecLabel($0) })
        let presetOptions = options(ConversionOptions.Preset.allCases, settings.preset,
                                    value: { $0.rawValue },
                                    label: { "\($0.rawValue) — \(Self.presetHint($0))" })
        let audioOptions = options(ConversionOptions.AudioMode.allCases, settings.audioMode,
                                   value: { $0.rawValue },
                                   label: { Self.audioLabel($0) })
        let heightOptions = WebConversionSettings.offeredHeights.map { height in
            let selected = height == settings.targetHeight ? " selected" : ""
            let value = height.map(String.init) ?? ""
            return "<option value=\"\(value)\"\(selected)>"
                + "\(Self.escape(WebConversionSettings.heightLabel(height)))</option>"
        }.joined()

        return .html("""
        <!DOCTYPE html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        \(state.converting ? "<meta http-equiv=\"refresh\" content=\"3\">" : "")
        <title>Mediafin – \(Text.s("Konvertieren", "Convert"))</title>
        \(Self.styles)
        </head>
        <body>
        <div class="page">
          \(Self.navigation(current: "/convert"))
          <div class="card">
            <h1>\(Text.s("Konvertieren", "Convert"))</h1>
            <p class="sub">\(Text.s("Neu kodieren, um Platz zu sparen. Mit diesen Einstellungen etwa", "Re-encode to save space. Expect about")) \
        \(settings.estimatedSizePercent) % \(Text.s("der ursprünglichen Größe.", "of the original size with these settings."))</p>
            \(missingFFmpeg)
            \(list)
          </div>

          <div class="card actions">
            <form method="post" action="/convert/scan">
              \(csrf.hiddenField)
              <button type="submit"\(state.converting ? " disabled" : "")>\(Text.s("Nach Dateien sehen", "Look for files"))</button>
            </form>
          </div>

          <form method="post" action="/settings" class="card">
            \(csrf.hiddenField)
            <input type="hidden" name="conversionFormPresent" value="1">
            <input type="hidden" name="after" value="/convert">
            <h2>\(Text.s("Einstellungen", "Settings"))</h2>
            \(problems.isEmpty ? "" : problems.map {
                "<p class=\"note\">\(Self.escape($0.message))</p>"
            }.joined())
            <label for="videoCodec">\(Text.s("Video-Codec", "Video codec"))</label>
            <select id="videoCodec" name="videoCodec">\(codecOptions)</select>
            <label for="quality">\(Text.s("Qualität (kleiner ist besser und größer, 0–51)", "Quality (lower is better and larger, 0–51)"))</label>
            <input id="quality" name="quality" type="text" value="\(settings.quality)">
            <label for="preset">\(Text.s("Kodierer-Aufwand", "Encoder effort"))</label>
            <select id="preset" name="preset">\(presetOptions)</select>
            <label for="targetHeight">\(Text.s("Auflösung", "Resolution"))</label>
            <select id="targetHeight" name="targetHeight">\(heightOptions)</select>
            <label for="audioMode">\(Text.s("Ton", "Audio"))</label>
            <select id="audioMode" name="audioMode">\(audioOptions)</select>
            <label class="inline"><input type="checkbox" name="stripSubtitles" value="1"\
        \(settings.stripSubtitles ? " checked" : "")> \(Text.s("Untertitelspuren weglassen", "Drop subtitle tracks"))</label>
            <label for="ffmpegPath">\(Text.s("FFmpeg-Pfad (nur wenn er irgendwo Ungewöhnlichem liegt)", "FFmpeg path (only if it is somewhere unusual)"))</label>
            <input id="ffmpegPath" name="ffmpegPath" type="text" \
        value="\(Self.escape(settings.ffmpegPath))">
            <button type="submit">\(Text.s("Speichern", "Save"))</button>
          </form>
        </div>
        </body></html>
        """, status: status)
    }

    static func codecLabel(_ codec: ConversionOptions.VideoCodec) -> String {
        switch codec {
        case .h265: return Text.s("H.265 / HEVC — bestes Verhältnis, läuft fast überall", "H.265 / HEVC — best balance, plays nearly everywhere")
        case .h264: return Text.s("H.264 — größte Dateien, läuft überall", "H.264 — largest files, plays everywhere")
        case .av1: return Text.s("AV1 — kleinste Dateien, am langsamsten, braucht einen neueren Player", "AV1 — smallest files, slowest, needs a recent player")
        case .copy: return Text.s("Das Video so lassen (nur neu verpacken)", "Keep the video as it is (only repackage)")
        }
    }

    static func presetHint(_ preset: ConversionOptions.Preset) -> String {
        switch preset {
        case .veryslow, .slower: return Text.s("kleinste Dateien, sehr langsam", "smallest files, very slow")
        case .slow: return Text.s("empfohlen", "recommended")
        case .medium: return Text.s("schneller, etwas größer", "faster, slightly larger")
        case .fast, .faster, .veryfast: return Text.s("schnell, merklich größer", "quick, noticeably larger")
        }
    }

    static func audioLabel(_ mode: ConversionOptions.AudioMode) -> String {
        switch mode {
        case .passthrough: return Text.s("Originalton behalten (empfohlen)", "Keep the original audio (recommended)")
        case .opus: return Text.s("Neu nach Opus — am kleinsten", "Re-encode to Opus — smallest")
        case .aac: return Text.s("Neu nach AAC — am verträglichsten", "Re-encode to AAC — most compatible")
        }
    }

    /// What has been renamed, newest first, with a download of the whole log.
    func historyPage() -> HTTPResponse {
        let entries = logEntries()
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium

        var rows = ""
        for entry in entries.reversed() {
            let status: String
            switch entry.status {
            case .success: status = "<span class=\"ok-text\">renamed</span>"
            case .skipped: status = "<span class=\"flag\">skipped</span>"
            case .failure: status = "<span class=\"bad-text\">failed</span>"
            case .converted: status = "<span class=\"ok-text\">converted</span>"
            case .sent: status = "<span class=\"ok-text\">sent</span>"
            case .downloaded: status = "<span class=\"ok-text\">downloaded</span>"
            }
            let detail = entry.errorDescription.map {
                "<div class=\"hint\">\(Self.escape($0))</div>"
            } ?? ""
            rows += """
            <tr>
              <td>
                <div class="from">\(Self.escape(entry.oldName))</div>
                <div class="to">→ \(Self.escape(entry.newName))</div>
                \(detail)
              </td>
              <td class="right-cell">\(status)<div class="hint">\
            \(Self.escape(formatter.string(from: entry.date)))</div></td>
            </tr>
            """
        }

        let body = entries.isEmpty
            ? "<p class=\"hint\">" + Text.s("Es wurde noch nichts umbenannt.", "Nothing has been renamed yet.") + "</p>"
            : "<table>\(rows)</table>"

        return .html("""
        <!DOCTYPE html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Mediafin – \(Text.s("Verlauf", "History"))</title>
        \(Self.styles)
        </head>
        <body>
        <div class="page">
          \(Self.navigation(current: "/history"))
          <div class="card">
            <h1>\(Text.s("Verlauf", "History"))</h1>
            <p class="sub">\(entries.count) entr\(entries.count == 1 ? "y" : "ies")</p>
            \(body)
          </div>
          <div class="card actions">
            <a class="button" href="/history/export">\(Text.s("Als Text herunterladen", "Download as text"))</a>
            <form method="post" action="/history/clear">
              \(csrf.hiddenField)
              <button type="submit"\(entries.isEmpty ? " disabled" : "")>\
        \(Text.s("Verlauf leeren", "Clear the history"))</button>
            </form>
          </div>
        </div>
        </body></html>
        """)
    }

    /// The whole log as a plain-text download, so it can be kept or sent on.
    func exportedLog() -> HTTPResponse {
        var text = "Mediafin rename log\n\n"
        let formatter = ISO8601DateFormatter()
        for entry in logEntries() {
            text += formatter.string(from: entry.date)
            text += "\t\(entry.status.rawValue)\t\(entry.oldName)\t→\t\(entry.newName)"
            if let detail = entry.errorDescription { text += "\t\(detail)" }
            text += "\n"
        }
        var response = HTTPResponse.text(text)
        // A fixed file name: nothing from the log reaches this header.
        response.headers["Content-Disposition"] = "attachment; filename=\"mediafin-log.txt\""
        return response
    }

    /// Login form. No JavaScript, and the token field is a password field so it
    /// is not shown on screen or kept by autofill history.
    func loginPage(status: Int = 200, message: String? = nil) -> HTTPResponse {
        let note = message.map { "<p class=\"note\">\(Self.escape($0))</p>" } ?? ""
        let warning = policy.isTLS ? "" : """
        <p class="warn">This connection is not encrypted. Enable HTTPS in Mediafin \
        before using the interface over a network.</p>
        """
        return .html("""
        <!DOCTYPE html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Mediafin – \(Text.s("Anmelden", "Sign in"))</title>
        \(Self.styles)
        </head>
        <body class="centred"><form method="post" action="/login">
          \(csrf.hiddenField)
          <h1>Mediafin</h1>
          <p class="sub">\(Text.s("Den Zugangs-Token eingeben, den das Programm anzeigt.", "Enter the access token shown in the app."))</p>
          \(note)
          <label for="token">\(Text.s("Zugangs-Token", "Access token"))</label>
          <input id="token" name="token" type="password" autocomplete="off" autofocus>
          <button type="submit">\(Text.s("Anmelden", "Sign in"))</button>
          \(warning)
        </form></body></html>
        """, status: status)
    }

    /// Settings form. Secrets are never written back into the page — only
    /// whether one is stored — so the HTML cannot leak a key.
    func settingsPage(_ current: WebSettings, problems: [WebSettings.Problem] = [],
                      notice: String? = nil, status: Int = 200) -> HTTPResponse {
        let stored = configuredSecrets()

        func problem(_ field: String) -> String {
            guard let match = problems.first(where: { $0.field == field }) else { return "" }
            return "<p class=\"note\">\(Self.escape(match.message))</p>"
        }

        func field(_ name: String, label: String, value: String,
                   hint: String = "", type: String = "text") -> String {
            """
            <label for="\(name)">\(Self.escape(label))</label>
            <input id="\(name)" name="\(name)" type="\(type)" value="\(Self.escape(value))">
            \(hint.isEmpty ? "" : "<p class=\"hint\">\(Self.escape(hint))</p>")
            \(problem(name))
            """
        }

        func secretField(_ key: SecretKey) -> String {
            let isStored = stored.contains(key)
            return """
            <label for="\(key.formField)">\(Self.escape(key.label))</label>
            <input id="\(key.formField)" name="\(key.formField)" type="password"
                   autocomplete="off" placeholder="\(isStored ? Text.s("gespeichert — zum Behalten leer lassen", "stored — leave blank to keep") : Text.s("nicht gesetzt", "not set"))">
            \(isStored ? """
            <label class="inline"><input type="checkbox" name="clear-\(key.formField)" value="1"> \
            \(Text.s("Gespeicherten Schlüssel entfernen", "Remove the stored key"))</label>
            """ : "")
            """
        }

        // What the program will actually do, beside what was asked for. A
        // schedule can be set and not running — it was, for every restart,
        // before it was armed at startup — and this is the line that says so.
        let scheduleState: String = {
            guard current.schedule.isEnabled else { return "" }
            let state = snapshot()
            // The same sentence the GTK window shows, from the same place.
            // Its second line is the part that matters; the first is the
            // summary already printed above.
            let lines = ScheduleLine.describe(current.schedule, state)
                .split(separator: "\n").dropFirst()
            guard let line = lines.first else { return "" }
            // A schedule that is set but not armed is a fault, not a hint.
            let style = state.nextScheduledRun == nil ? "note" : "hint"
            return "<p class=\"\(style)\">\(Self.escape(String(line)))</p>"
        }()

        let cadenceOptions = Schedule.Cadence.allCases.map { cadence in
            let selected = cadence == current.schedule.cadence ? " selected" : ""
            return "<option value=\"\(cadence.rawValue)\"\(selected)>"
                + "\(Self.escape(cadence.label))</option>"
        }.joined()

        // "" first, and selected when nothing is stored: following the
        // machine is the default, and it has to be choosable again after a
        // language has been picked.
        let languageOptions: String = {
            let follow = "<option value=\"\"\(current.language == nil ? " selected" : "")>"
                + Self.escape(Text.s("Wie das System (LANG)", "Follow the system (LANG)"))
                + "</option>"
            return follow + Language.allCases.map { language in
                let selected = current.language == language ? " selected" : ""
                return "<option value=\"\(language.rawValue)\"\(selected)>"
                    + "\(Self.escape(language.label))</option>"
            }.joined()
        }()

        let modeOptions = LibraryMode.allCases.map { mode in
            let selected = mode == current.libraryMode ? " selected" : ""
            return "<option value=\"\(mode.rawValue)\"\(selected)>"
                + "\(Self.escape(mode.label))</option>"
        }.joined()

        let identificationOptions = IdentificationMode.allCases.map { mode in
            let selected = mode == current.identification ? " selected" : ""
            return "<option value=\"\(mode.rawValue)\"\(selected)>\(Self.escape(mode.label))</option>"
        }.joined()

        let conflictOptions = WebSettings.ConflictPolicyChoice.allCases.map { choice in
            let selected = choice == current.conflictPolicy ? " selected" : ""
            return "<option value=\"\(choice.rawValue)\"\(selected)>\(Self.escape(choice.label))</option>"
        }.joined()

        let transportOptions = RemoteTarget.Transport.allCases.map { transport in
            let selected = transport == current.remote.transport ? " selected" : ""
            return "<option value=\"\(transport.rawValue)\"\(selected)>"
                + "\(Self.escape(transport.label))</option>"
        }.joined()

        let authOptions = RemoteTarget.Authentication.allCases.map { auth in
            let selected = auth == current.remote.authentication ? " selected" : ""
            return "<option value=\"\(auth.rawValue)\"\(selected)>"
                + "\(Self.escape(auth.label))</option>"
        }.joined()

        let banner = notice.map { "<p class=\"hint\">\(Self.escape($0))</p>" } ?? ""
        return .html("""
        <!DOCTYPE html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Mediafin – \(Text.s("Einstellungen", "Settings"))</title>
        \(Self.styles)
        </head>
        <body>
        <div class="page">
          \(Self.navigation(current: "/settings"))
          <form method="post" action="/settings" class="card">
            \(csrf.hiddenField)
            <h1>\(Text.s("Einstellungen", "Settings"))</h1>
            \(problems.isEmpty ? banner : "<p class=\"note\">" + Text.s("Nichts gespeichert — bitte die unten markierten Felder berichtigen.", "Nothing was saved — please correct the fields marked below.") + "</p>")

            <h2>\(Text.s("Sprache", "Language"))</h2>
            <label for="language">\(Text.s("Sprache der Oberfl\u{00E4}che", "Interface language"))</label>
            <select id="language" name="language">\(languageOptions)</select>

            <h2>\(Text.s("Was diese Bibliothek enth\u{00E4}lt", "What this library holds"))</h2>
            <label for="libraryMode">\(Text.s("Sortierung", "Sorting"))</label>
            <select id="libraryMode" name="libraryMode">\(modeOptions)</select>
            <p class="hint">Video and music are sorted differently — different folders, \
        different names, and music is identified from its own tags rather than from the \
        file name.</p>

            <h2>\(Text.s("Ordner", "Folders"))</h2>
            \(field("sourceFolder", label: Text.s("Importieren aus", "Import from"), value: current.sourceFolder,
                    hint: Text.s("Der Ordner, in dem neue Downloads landen. Absoluter Pfad.", "The folder new downloads land in. Absolute path.")))
            \(field("moviesFolder", label: Text.s("Filmbibliothek", "Movies library"), value: current.moviesFolder))
            \(field("seriesFolder", label: Text.s("Serienbibliothek", "Series library"), value: current.seriesFolder))
            \(field("musicFolder", label: Text.s("Musikbibliothek", "Music library"), value: current.musicFolder,
                    hint: Text.s("Im Musikmodus: /Künstler/Album (Jahr)/01 - Titel.flac", "Used in music mode: /Artist/Album (Year)/01 - Title.flac")))
            <label for="conflictPolicy">\(Text.s("Wenn schon eine Datei da ist", "If a file already exists"))</label>
            <select id="conflictPolicy" name="conflictPolicy">\(conflictOptions)</select>
            <input type="hidden" name="watchSourceFolderPresent" value="1">
            <label class="inline"><input type="checkbox" name="watchSourceFolder" value="1"\
        \(current.watchSourceFolder ? " checked" : "")> \(Text.s("Importordner beobachten und neue Dateien von selbst vorschlagen", "Watch the import folder and offer new files automatically"))</label>

            <h2>\(Text.s("Erkennung", "Identification"))</h2>
            <label for="identification">\(Text.s("Wie Titel erkannt werden", "How titles are identified"))</label>
            <select id="identification" name="identification">\(identificationOptions)</select>

            <h2>\(Text.s("Eigener Modellserver", "My own model"))</h2>
            \(field("localLLMBaseURL", label: Text.s("Serveradresse", "Server address"), value: current.localLLMBaseURL,
                    hint: Text.s("Bei LM Studio meist http://<host>:1234", "For LM Studio this is usually http://<host>:1234")))
            \(field("localLLMModel", label: Text.s("Modell", "Model"), value: current.localLLMModel,
                    hint: Text.s("Genau so, wie der Server ihn meldet.", "Exactly as the server reports it.")))
            \(secretField(.localLLMAPIKey))

            <h2>Jellyfin</h2>
            \(field("jellyfinBaseURL", label: Text.s("Serveradresse", "Server address"), value: current.jellyfinBaseURL,
                    hint: Text.s("Mediafin lässt die Bibliothek hier nach dem Umbenennen neu einlesen.", "Mediafin refreshes the library here after renaming.")))
            \(secretField(.jellyfinToken))

            <h2>TMDb</h2>
            <p class="hint">\(Text.s("Es werden nur Titel und Jahr gesendet — nie eine Datei.", "Only the title and year are ever sent — never a file."))</p>
            \(secretField(.tmdbAPIKey))

            <h2>\(Text.s("Von selbst nachsehen", "Looking by itself"))</h2>
            <input type="hidden" name="schedulePresent" value="1">
            <label class="inline"><input type="checkbox" name="scheduleEnabled" value="1"\
        \(current.schedule.isEnabled ? " checked" : "")> \(Text.s("Ungefragt nachsehen", "Check without being asked"))</label>
            <label for="scheduleCadence">\(Text.s("Wie oft", "How often"))</label>
            <select id="scheduleCadence" name="scheduleCadence">\(cadenceOptions)</select>
            \(field("scheduleTime", label: Text.s("Um (24-Stunden-Uhr)", "At (24-hour clock)"),
                    value: String(format: "%02d:%02d", current.schedule.hour,
                                  current.schedule.minute)))
            \(field("scheduleEveryHours", label: Text.s("Oder alle N Stunden", "Or every N hours"),
                    value: String(current.schedule.everyHours)))
            <label class="inline"><input type="checkbox" name="scheduleRename" value="1"\
        \(current.schedule.alsoRename ? " checked" : "")> \(Text.s("Gefundenes auch umbenennen", "Also rename what it finds"))</label>
            <label class="inline"><input type="checkbox" name="scheduleSend" value="1"\
        \(current.schedule.alsoSend ? " checked" : "")> \(Text.s("Es auch zum Server senden", "Also send it to the server"))</label>
            <p class="hint">\(Self.escape(current.schedule.summary))</p>
            \(scheduleState)

            <h2>\(Text.s("Die Bibliothek auf einem anderen Rechner", "The library on another machine"))</h2>
            <input type="hidden" name="remoteEnabledPresent" value="1">
            <label class="inline"><input type="checkbox" name="remoteEnabled" value="1"\
        \(current.remote.isEnabled ? " checked" : "")> \(Text.s("Die sortierten Dateien zu einem Server senden", "Send the sorted files to a server"))</label>
            \(field("remoteHost", label: Text.s("Serveradresse", "Server address"), value: current.remote.host,
                    hint: Text.s("Ein Rechnername oder eine Adresse — kein Pfad, kein Schema.", "A host name or address — no path, no scheme.")))
            \(field("remotePort", label: Text.s("Port", "Port"), value: String(current.remote.port)))
            \(field("remoteUser", label: Text.s("Benutzer", "User"), value: current.remote.user))
            \(field("remoteBasePath", label: Text.s("Zielpfad auf dem Server", "Target path on the server"),
                    value: current.remote.basePath,
                    hint: Text.s("Absolut. Gilt für alles, wofür darunter kein eigener Pfad steht.", "Absolute. Used for anything that has no path of its own below.")))
            \(field("remoteMoviesPath", label: Text.s("Nur Filme", "Films only"),
                    value: current.remote.moviesPath,
                    hint: Text.s("Leer lassen, um den Zielpfad zu benutzen.", "Leave empty to use the target path.")))
            \(field("remoteSeriesPath", label: Text.s("Nur Serien", "Series only"),
                    value: current.remote.seriesPath,
                    hint: Text.s("Leer lassen, um den Zielpfad zu benutzen.", "Leave empty to use the target path.")))
            \(field("remoteMusicPath", label: Text.s("Nur Musik", "Music only"),
                    value: current.remote.musicPath,
                    hint: Text.s("Leer lassen, um den Zielpfad zu benutzen.", "Leave empty to use the target path.")))
            <label for="remoteTransport">\(Text.s("Übertragen mit", "Transfer with"))</label>
            <select id="remoteTransport" name="remoteTransport">\(transportOptions)</select>
            <label for="remoteAuthentication">\(Text.s("Anmelden mit", "Sign in with"))</label>
            <select id="remoteAuthentication" name="remoteAuthentication">\(authOptions)</select>
            \(field("remoteIdentityFile", label: Text.s("Schlüsseldatei", "Key file"), value: current.remote.identityFile,
                    hint: Text.s("Leer lassen, um die bestehende ssh-Konfiguration zu benutzen.", "Leave empty to use whatever your ssh configuration already does.")))
            \(secretField(.remotePassword))
            <input type="hidden" name="remoteTrustOnFirstUsePresent" value="1">
            <label class="inline"><input type="checkbox" name="remoteTrustOnFirstUse" value="1"\
        \(current.remote.trustOnFirstUse ? " checked" : "")> \(Text.s("Dem Server beim ersten Mal vertrauen", "Trust this server the first time"))</label>
            <p class="hint">\(Text.s("Nimmt den Schlüssel eines unbekannten Servers an, statt zu verlangen, dass man sich einmal von Hand verbindet. Ein Schlüssel, der sich später ändert, wird weiterhin abgelehnt — das ist der Fall, der zählt.", "Accepts the key of a server it has not met, instead of requiring you to connect once by hand. A key that changes later is still refused — that is the case that matters."))</p>
            <input type="hidden" name="remoteRemoveLocalPresent" value="1">
            <label class="inline"><input type="checkbox" name="remoteRemoveLocal" value="1"\
        \(current.remote.removeLocalAfterSend ? " checked" : "")> \(Text.s("Die lokale Datei löschen, sobald der Server sie hat", "Delete the local file once the server has it"))</label>
            <p class="hint">\(Text.s("Standardmäßig aus. Senden ist eine Kopie und lässt sich rückgängig machen, indem man das Angekommene löscht; das Löschen der lokalen Datei nicht.", "Off by default. Sending is a copy, which can be undone by deleting what arrived; deleting the local file cannot."))</p>

            <button type="submit">\(Text.s("Speichern", "Save"))</button>
            <button type="submit" formaction="/settings/test-llm">\
        \(Text.s("Speichern und Modellserver testen", "Save and test the model server"))</button>
            <button type="submit" formaction="/settings/test-jellyfin">\
        \(Text.s("Speichern und Jellyfin testen", "Save and test Jellyfin"))</button>
            <button type="submit" formaction="/settings/test-remote">\
        \(Text.s("Speichern und Server testen", "Save and test the server"))</button>
          </form>
        </div>
        </body></html>
        """, status: status)
    }

    /// Turns the redirect's query marker into something to tell the user.
    static func notice(for query: [String: String]) -> String? {
        if query["saved"] != nil {
            return Text.s("Einstellungen gespeichert.", "Settings saved.")
        }
        switch query["tested"] {
        case "llm":
            return Text.s("Modellserver wird geprüft — das Ergebnis erscheint in der Übersicht.", "Testing the model server — the result appears on the overview.")
        case "jellyfin":
            return Text.s("Jellyfin wird geprüft — das Ergebnis erscheint in der Übersicht.", "Testing Jellyfin — the result appears on the overview.")
        default: return nil
        }
    }

    /// Links shared by the pages.
    /// How many log entries the column beside the work shows.
    ///
    /// The same number the window keeps. Enough that a whole run is still
    /// there, few enough that the page stays a page.
    static let visibleLogEntries = 200

    /// Time of day on each log row, as the window shows it. The log is kept
    /// across runs, so "failed" with no time could belong to last week.
    static let logTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// The log, always beside the work rather than on a page of its own.
    ///
    /// A rename that failed is the thing you most need to see, and a panel
    /// you have to navigate to is a panel you look at after wondering for a
    /// while why nothing happened. Newest first, because the question is
    /// almost always "what just happened" and a column that grows downwards
    /// puts that answer off the bottom of the screen.
    static func logAside(_ entries: [RenameLogEntry]) -> String {
        let recent = entries.reversed().prefix(visibleLogEntries)
        // Counted over the WHOLE log, not the visible slice: a failure that
        // has scrolled past 200 entries is still a failure, and a header
        // reading "200 entries" with no count gives nobody a reason to look.
        let failed = entries.filter { $0.status == .failure }.count
        let rows = recent.map { entry -> String in
            let word: String
            let cssClass: String
            switch entry.status {
            case .success: word = "renamed"; cssClass = "lamp-ok"
            case .converted: word = "converted"; cssClass = "lamp-ok"
            case .sent: word = "sent"; cssClass = "lamp-ok"
            case .downloaded: word = "downloaded"; cssClass = "lamp-ok"
            case .skipped: word = "skipped"; cssClass = "lamp-off"
            case .failure: word = "failed"; cssClass = "lamp-failed"
            }
            // The error is the reason this column exists, so it is not
            // truncated and not hidden behind anything.
            let error = entry.errorDescription.map {
                "<div class=\"log-error\">\(Self.escape($0))</div>"
            } ?? ""
            return """
            <li>
              <span class="hint">\(Self.logTime.string(from: entry.date))</span>
              <span class="\(cssClass)">\(word)</span>
              <div class="log-name">\(Self.escape(entry.oldName))</div>
              <div class="log-to">→ \(Self.escape(entry.newName))</div>
              \(error)
            </li>
            """
        }.joined()

        let more = entries.count > visibleLogEntries
            ? "<p class=\"hint\">\(entries.count - visibleLogEntries) older entries are on "
                + "the <a href=\"/history\">history page</a>.</p>"
            : ""

        return """
        <aside class="logside">
          <h2>\(Text.s("Verlauf", "History"))</h2>
          <p class="sub">\(entries.count) \(entries.count == 1
            ? Text.s("Eintrag", "entry") : Text.s("Einträge", "entries"))\(failed > 0
            ? " · <span class=\"bad-text\">\(failed) " + Text.s("fehlgeschlagen", "failed") + "</span>" : "")</p>
          \(entries.isEmpty
            ? "<p class=\"hint\">" + Text.s("Noch nichts passiert.", "Nothing has happened yet.") + "</p>"
            : "<ul class=\"log\">\(rows)</ul>\(more)")
        </aside>
        """
    }

    static func navigation(current: String) -> String {
        let items = [("/", Text.s("Übersicht", "Overview")), ("/convert", Text.s("Konvertieren", "Convert")),
                     ("/history", Text.s("Verlauf", "History")), ("/settings", Text.s("Einstellungen", "Settings"))]
        let links = items.map { path, title in
            path == current
                ? "<span class=\"here\">\(title)</span>"
                : "<a href=\"\(path)\">\(title)</a>"
        }.joined(separator: "")
        return """
        <nav>\(links)<form method="post" action="/logout" class="right">\
        <button type="submit" class="link">\(Text.s("Abmelden", "Sign out"))</button></form></nav>
        """
    }

    static let styles = """
    <style>
      :root { color-scheme: dark; }
      body { font-family: -apple-system, system-ui, sans-serif; background:#16161a;
             color:#e6e6ea; margin:0; padding:24px; }
      body.centred { display:flex; min-height:100vh; align-items:center; justify-content:center; }
      .page { max-width:720px; margin:0 auto; }
      nav { display:flex; gap:18px; align-items:center; margin-bottom:18px; font-size:14px; }
      nav a { color:#8aa4ff; text-decoration:none; }
      nav .here { color:#e6e6ea; font-weight:600; }
      nav .right { margin-left:auto; }
      button.link { background:none; border:0; color:#8a8a92; font-size:14px; padding:0; width:auto; }
      form, .card { background:#1e1e24; border:1px solid #2a2a32; border-radius:16px;
                    padding:24px 28px; width:100%; max-width:420px; box-sizing:border-box; }
      .page form, .page .card { max-width:100%; margin-bottom:16px; }
      .inline-form { display:inline-block; width:auto; padding:14px 18px; margin-right:12px; }
      h1 { font-size:18px; margin:0 0 6px; }
      h2 { font-size:14px; text-transform:uppercase; letter-spacing:0.05em; color:#8a8a92;
           margin:26px 0 10px; }
      .sub { color:#8a8a92; font-size:13px; margin:0 0 18px; }
      label { display:block; font-size:13px; color:#8a8a92; margin:12px 0 6px; }
      label.inline { display:block; color:#c8c8d0; margin-top:10px; }
      input[type=text], input[type=password], select {
        width:100%; box-sizing:border-box; padding:10px 12px; border-radius:10px;
        border:1px solid #33333d; background:#141418; color:#e6e6ea; font-size:14px; }
      input[type=checkbox] { width:auto; }
      button { margin-top:18px; padding:11px 18px; border:0; border-radius:10px;
               background:#4f7cff; color:#fff; font-size:14px; font-weight:600; width:100%; }
      .inline-form button { margin-top:0; }
      .note { color:#e0a0a0; font-size:13px; margin:8px 0 0; }
      .hint { color:#71717a; font-size:12px; margin:6px 0 0; }
      .warn { color:#f0a020; font-size:12px; margin:14px 0 0; }
      .result { color:#c8c8d0; font-size:13px; margin:14px 0 0; }
      .badge { display:inline-block; padding:5px 12px; border-radius:999px; font-size:13px;
               font-weight:700; }
      .badge.ok { background:#36c98d22; color:#36c98d; border:1px solid #36c98d55; }
      .badge.busy { background:#f0a02022; color:#f0a020; border:1px solid #f0a02055; }
      .badge.bad { background:#e05a4f22; color:#e05a4f; border:1px solid #e05a4f55; }
      table { width:100%; border-collapse:collapse; margin-top:6px; }
      td { padding:10px 4px; border-bottom:1px solid #26262e; font-size:14px;
           vertical-align:top; }
      td.tick { width:28px; }
      .from { color:#8a8a92; }
      .to { color:#e6e6ea; margin-top:3px; }
      .flag { color:#f0a020; font-size:12px; margin-left:6px; }
      .actions { display:flex; gap:12px; flex-wrap:wrap; }
      .actions form { background:none; border:0; padding:0; width:auto; margin:0; }
      .actions button { margin-top:0; width:auto; }
      button[disabled] { background:#2a2a32; color:#6a6a72; }
      a { color:#8aa4ff; }
      a.button { display:inline-block; padding:11px 18px; border-radius:10px;
                 background:#4f7cff; color:#fff; font-size:14px; font-weight:600;
                 text-decoration:none; }
      .right-cell { text-align:right; white-space:nowrap; width:1%; }
      .ok-text { color:#36c98d; font-size:13px; }
      .bad-text { color:#e05a4f; font-size:13px; }
      /* The traffic light. The word beside each lamp is not decoration:
         colour alone is unreadable to about one man in twelve. */
      .lamp { font-size:16px; line-height:1; }
      .lamp-ok { color:#36c98d; }
      .lamp-warning { color:#f0a020; }
      .lamp-failed { color:#e05a4f; }
      .lamp-off { color:#55555f; }

      /* Work on the left, log on the right — the window's layout, so the
         two interfaces are the same shape. Below 900px the aside drops
         underneath instead of squeezing the work into a gutter. */
      .page.wide { max-width:1180px; }
      .split { display:flex; gap:20px; align-items:flex-start; }
      .work { flex:1 1 auto; min-width:0; }
      .logside { flex:0 0 320px; background:#1e1e24; border:1px solid #2a2a32;
                 border-radius:16px; padding:18px 20px; box-sizing:border-box;
                 max-height:80vh; overflow-y:auto; }
      .logside h2 { margin-top:0; }
      @media (max-width: 900px) {
        .split { display:block; }
        .logside { width:100%; margin-top:16px; max-height:none; }
      }
      ul.log { list-style:none; margin:0; padding:0; }
      ul.log li { padding:8px 0; border-top:1px solid #26262e; font-size:12px; }
      ul.log li:first-child { border-top:0; }
      .log-name { color:#8a8a92; word-break:break-all; }
      .log-to { color:#e6e6ea; word-break:break-all; }
      .log-error { color:#e05a4f; margin-top:4px; }
      .footer { color:#55555f; font-size:12px; text-align:right; margin:4px 2px 0; }
      details.card > summary { cursor:pointer; list-style:revert; }
      details.card > summary strong { color:#e6e6ea; }
      progress { width:100%; height:10px; }
      /* A form that is only a text button: no box, no border, no padding —
         otherwise "Tick all" renders as a bordered card of its own. */
      .page form.bare { background:none; border:0; padding:0; margin:4px 14px 0 0;
                        display:inline-block; width:auto; }
    </style>
    """

    /// Plain wording for a conflict, since the raw case name means nothing to
    /// someone reading the page.
    static func conflictLabel(_ kind: ConflictKind) -> String {
        switch kind {
        case .existingFile: return "a file is already there"
        case .duplicateInBatch: return "two files want the same name"
        }
    }

    /// HTML escaping for text interpolated into a page. Kept as a name the
    /// page builders already use; the implementation is shared with the status
    /// page so the two cannot drift apart again.
    static func escape(_ value: String) -> String { HTML.escape(value) }
}
