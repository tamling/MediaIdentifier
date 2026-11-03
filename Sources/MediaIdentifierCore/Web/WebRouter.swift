import Foundation

/// Routes requests for the local web interface and enforces the security
/// policy in front of every route.
///
/// Pure: it maps a parsed request to a response and touches neither sockets nor
/// TLS, so the whole access-control surface is unit-testable on any platform.
/// Anything slow is handed to a `WebCommandSink` and reported back through the
/// status snapshot, so no request waits on work.
public struct WebRouter: Sendable {
    public var policy: WebSecurityPolicy
    /// Token required by every state-changing request, exposed so a form can
    /// embed it and a test can present it.
    public let csrf: CSRFToken

    private let throttle: LoginThrottle
    private let snapshot: @Sendable () -> StatusSnapshot
    private let settings: @Sendable () -> WebSettings
    private let configuredSecrets: @Sendable () -> Set<SecretKey>
    private let commands: WebCommandSink?

    public init(policy: WebSecurityPolicy,
                throttle: LoginThrottle = LoginThrottle(),
                csrf: CSRFToken = CSRFToken(),
                settings: @escaping @Sendable () -> WebSettings = { WebSettings() },
                configuredSecrets: @escaping @Sendable () -> Set<SecretKey> = { [] },
                commands: WebCommandSink? = nil,
                snapshot: @escaping @Sendable () -> StatusSnapshot) {
        self.policy = policy
        self.throttle = throttle
        self.csrf = csrf
        self.settings = settings
        self.configuredSecrets = configuredSecrets
        self.commands = commands
        self.snapshot = snapshot
    }

    /// Paths that accept a POST. Everything else is read-only, so a stray
    /// request cannot change anything by reaching an unintended route.
    static let writablePaths: Set<String> = [
        "/login", "/logout", "/settings",
        "/settings/test-llm", "/settings/test-jellyfin",
        "/library/scan", "/library/apply", "/library/undo",
        "/convert/start", "/history/clear",
    ]

    // MARK: Entry point

    public func respond(to request: HTTPRequest) -> HTTPResponse {
        guard request.isReadOnly || request.method == "POST" else {
            return .methodNotAllowed()
        }
        if request.method == "POST", !Self.writablePaths.contains(request.path) {
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
            guard RequestOrigin.isSameSite(request) else {
                return .text("cross-site request refused", status: 403)
            }
            let fields = Self.formFields(of: request)
            guard csrf.matches(fields[CSRFToken.fieldName]) else {
                return .text("this form has expired — reload the page and try again",
                             status: 403)
            }
            if request.path == "/login" { return performLogin(fields) }
            guard isAuthorized(request) else { return unauthorized(for: request) }
            return performAction(request.path, fields: fields)
        }

        if request.path == "/login" { return loginPage() }

        guard isAuthorized(request) else { return unauthorized(for: request) }

        switch request.path {
        case "/", "/index.html":
            return .html(StatusHTTP.html(snapshot()))
        case "/settings":
            return settingsPage(settings(), notice: Self.notice(for: request.query))
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
        return loginPage(status: 401, message: "Please sign in.")
    }

    private func performLogin(_ fields: [String: String]) -> HTTPResponse {
        if throttle.isBlocked() {
            var response = loginPage(status: 429,
                                     message: "Too many attempts. Please wait and try again.")
            response.headers["Retry-After"] = String(throttle.retryAfterSeconds())
            return response
        }
        guard policy.matches(fields["token"] ?? "") else {
            throttle.recordFailure()
            // No hint about why: not whether the token was close, nor whether
            // one is configured at all.
            return loginPage(status: 401, message: "Wrong access token.")
        }
        throttle.recordSuccess()
        // The cookie carries the token itself rather than a separate session
        // id. That keeps the server stateless, and the cookie is already as
        // protected as it can be: HttpOnly, SameSite=Strict and, over TLS,
        // Secure. Revoking access means rotating the token.
        return redirect(to: "/", setCookie: policy.sessionCookie(value: policy.token))
    }

    // MARK: Actions

    private func performAction(_ path: String, fields: [String: String]) -> HTTPResponse {
        switch path {
        case "/logout":
            return redirect(to: "/login", setCookie: policy.clearedCookie())
        case "/settings":
            return saveSettings(fields)
        case "/settings/test-llm":
            submit(.testLocalLLMConnection)
            return redirect(to: "/settings?tested=llm")
        case "/settings/test-jellyfin":
            submit(.testJellyfinConnection)
            return redirect(to: "/settings?tested=jellyfin")
        case "/library/scan":
            submit(.scanSourceFolder)
            return redirect(to: "/")
        case "/library/apply":
            submit(.applyProposedRenames)
            return redirect(to: "/")
        case "/library/undo":
            submit(.undoLastRename)
            return redirect(to: "/")
        case "/convert/start":
            submit(.startConversions)
            return redirect(to: "/")
        case "/history/clear":
            submit(.clearHistory)
            return redirect(to: "/")
        default:
            return .notFound()
        }
    }

    private func saveSettings(_ fields: [String: String]) -> HTTPResponse {
        let submitted = WebSettings.fromForm(fields, current: settings())
        let problems = submitted.problems()
        guard problems.isEmpty else {
            return settingsPage(submitted, problems: problems, status: 422)
        }
        submit(.saveSettings(submitted))

        // Secrets travel in the same form but are stored separately. An empty
        // field means "leave it alone", so a saved key is not wiped by someone
        // saving the page without retyping it.
        for key in SecretKey.allCases {
            if fields["clear-\(key.formField)"] != nil {
                submit(.setSecret(key, ""))
                continue
            }
            if let value = fields[key.formField], !value.isEmpty {
                submit(.setSecret(key, value))
            }
        }
        return redirect(to: "/settings?saved=1")
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

    /// Form fields of a POST, from the body and the query string. The body wins
    /// so a link cannot pre-set a field the form also carries.
    static func formFields(of request: HTTPRequest) -> [String: String] {
        var fields = request.query
        let body = HTTPRequestParser.parseFormEncoded(
            String(decoding: request.body, as: UTF8.self)
        )
        for (name, value) in body { fields[name] = value }
        return fields
    }

    // MARK: Pages

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
        <title>Mediafin – Sign in</title>
        \(Self.styles)
        </head>
        <body class="centred"><form method="post" action="/login">
          \(csrf.hiddenField)
          <h1>Mediafin</h1>
          <p class="sub">Enter the access token shown in the app.</p>
          \(note)
          <label for="token">Access token</label>
          <input id="token" name="token" type="password" autocomplete="off" autofocus>
          <button type="submit">Sign in</button>
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
                   autocomplete="off" placeholder="\(isStored ? "stored — leave blank to keep" : "not set")">
            \(isStored ? """
            <label class="inline"><input type="checkbox" name="clear-\(key.formField)" value="1"> \
            Remove the stored key</label>
            """ : "")
            """
        }

        let identificationOptions = IdentificationMode.allCases.map { mode in
            let selected = mode == current.identification ? " selected" : ""
            return "<option value=\"\(mode.rawValue)\"\(selected)>\(Self.escape(mode.label))</option>"
        }.joined()

        let conflictOptions = WebSettings.ConflictPolicyChoice.allCases.map { choice in
            let selected = choice == current.conflictPolicy ? " selected" : ""
            return "<option value=\"\(choice.rawValue)\"\(selected)>\(Self.escape(choice.label))</option>"
        }.joined()

        let banner = notice.map { "<p class=\"hint\">\(Self.escape($0))</p>" } ?? ""
        return .html("""
        <!DOCTYPE html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Mediafin – Settings</title>
        \(Self.styles)
        </head>
        <body>
        <div class="page">
          \(Self.navigation(current: "/settings"))
          <form method="post" action="/settings" class="card">
            \(csrf.hiddenField)
            <h1>Settings</h1>
            \(problems.isEmpty ? banner : "<p class=\"note\">Nothing was saved — please correct the fields marked below.</p>")

            <h2>Folders</h2>
            \(field("sourceFolder", label: "Import from", value: current.sourceFolder,
                    hint: "The folder new downloads land in. Absolute path."))
            \(field("moviesFolder", label: "Movies library", value: current.moviesFolder))
            \(field("seriesFolder", label: "Series library", value: current.seriesFolder))
            <label for="conflictPolicy">If a file already exists</label>
            <select id="conflictPolicy" name="conflictPolicy">\(conflictOptions)</select>
            <input type="hidden" name="watchSourceFolderPresent" value="1">
            <label class="inline"><input type="checkbox" name="watchSourceFolder" value="1"\
        \(current.watchSourceFolder ? " checked" : "")> Watch the import folder and offer new files automatically</label>

            <h2>Identification</h2>
            <label for="identification">How titles are identified</label>
            <select id="identification" name="identification">\(identificationOptions)</select>

            <h2>My own model</h2>
            \(field("localLLMBaseURL", label: "Server address", value: current.localLLMBaseURL,
                    hint: "For LM Studio this is usually http://<host>:1234"))
            \(field("localLLMModel", label: "Model", value: current.localLLMModel,
                    hint: "Exactly as the server reports it."))
            \(secretField(.localLLMAPIKey))

            <h2>Jellyfin</h2>
            \(field("jellyfinBaseURL", label: "Server address", value: current.jellyfinBaseURL,
                    hint: "Mediafin refreshes the library here after renaming."))
            \(secretField(.jellyfinToken))

            <h2>TMDb</h2>
            <p class="hint">Only the title and year are ever sent — never a file.</p>
            \(secretField(.tmdbAPIKey))

            <button type="submit">Save</button>
          </form>

          <form method="post" action="/settings/test-llm" class="card inline-form">
            \(csrf.hiddenField)
            <button type="submit">Test the model server</button>
          </form>
          <form method="post" action="/settings/test-jellyfin" class="card inline-form">
            \(csrf.hiddenField)
            <button type="submit">Test Jellyfin</button>
          </form>
        </div>
        </body></html>
        """, status: status)
    }

    /// Turns the redirect's query marker into something to tell the user.
    static func notice(for query: [String: String]) -> String? {
        if query["saved"] != nil { return "Settings saved." }
        switch query["tested"] {
        case "llm": return "Testing the model server — the result appears on the overview."
        case "jellyfin": return "Testing Jellyfin — the result appears on the overview."
        default: return nil
        }
    }

    /// Links shared by the pages.
    static func navigation(current: String) -> String {
        let items = [("/", "Overview"), ("/settings", "Settings")]
        let links = items.map { path, title in
            path == current
                ? "<span class=\"here\">\(title)</span>"
                : "<a href=\"\(path)\">\(title)</a>"
        }.joined(separator: "")
        return """
        <nav>\(links)<form method="post" action="/logout" class="right">\
        <button type="submit" class="link">Sign out</button></form></nav>
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
    </style>
    """

    /// Minimal HTML escaping for text interpolated into a page.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
