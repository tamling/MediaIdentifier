import Foundation

/// Routes requests for the local web interface and enforces the security
/// policy in front of every route.
///
/// Pure: it maps a parsed request to a response and touches neither sockets nor
/// TLS, so the whole access-control surface is unit-testable on any platform.
public struct WebRouter: Sendable {
    public var policy: WebSecurityPolicy
    private let throttle: LoginThrottle
    private let snapshot: @Sendable () -> StatusSnapshot

    public init(policy: WebSecurityPolicy,
                throttle: LoginThrottle = LoginThrottle(),
                snapshot: @escaping @Sendable () -> StatusSnapshot) {
        self.policy = policy
        self.throttle = throttle
        self.snapshot = snapshot
    }

    // MARK: Entry point

    public func respond(to request: HTTPRequest) -> HTTPResponse {
        // The login form is the only route that accepts a write, and even it
        // changes nothing on disk. Everything else is read-only.
        let allowedMethods: Set<String> = request.path == "/login" || request.path == "/logout"
            ? ["GET", "HEAD", "POST"]
            : ["GET", "HEAD"]
        guard allowedMethods.contains(request.method) else { return .methodNotAllowed() }

        // A liveness probe cannot log in, so it may stay anonymous. It answers
        // with idle/busy/error only — no names, no paths.
        if request.path == "/healthz", policy.allowAnonymousHealth {
            return health()
        }

        switch request.path {
        case "/login":
            return request.method == "POST" ? performLogin(request) : loginPage()
        case "/logout":
            return performLogout()
        default:
            break
        }

        guard isAuthorized(request) else { return unauthorized(for: request) }

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

    private func performLogin(_ request: HTTPRequest) -> HTTPResponse {
        if throttle.isBlocked() {
            var response = loginPage(status: 429,
                                     message: "Too many attempts. Please wait and try again.")
            response.headers["Retry-After"] = String(throttle.retryAfterSeconds())
            return response
        }
        let fields = HTTPRequestParser.parseFormEncoded(String(decoding: request.body, as: UTF8.self))
        let presented = fields["token"] ?? ""
        guard policy.matches(presented) else {
            throttle.recordFailure()
            // No hint about why: not whether the token was close, nor whether
            // one is configured at all.
            return loginPage(status: 401, message: "Wrong access token.")
        }
        throttle.recordSuccess()
        // The cookie carries the token itself rather than a separate session
        // id. That keeps the server stateless, and the cookie is already as
        // protected as it can be: HttpOnly, SameSite=Strict and, over TLS,
        // Secure. Revoking access means rotating the token in the app.
        var response = HTTPResponse(status: 303, contentType: "text/plain; charset=utf-8",
                                    body: Data("ok".utf8))
        response.headers["Location"] = "/"
        response.headers["Set-Cookie"] = policy.sessionCookie(value: policy.token)
        return response
    }

    private func performLogout() -> HTTPResponse {
        var response = HTTPResponse(status: 303, contentType: "text/plain; charset=utf-8",
                                    body: Data("signed out".utf8))
        response.headers["Location"] = "/login"
        response.headers["Set-Cookie"] = policy.clearedCookie()
        return response
    }

    // MARK: Routes

    private func health() -> HTTPResponse {
        let result = StatusHTTP.health(snapshot())
        return .text(result.body, status: Int(result.status.prefix(3)) ?? 200)
    }

    /// Login form. No JavaScript, and the token field is a password field so it
    /// is not shown on screen or kept by autofill history.
    func loginPage(status: Int = 200, message: String? = nil) -> HTTPResponse {
        let note = message.map {
            "<p class=\"note\">\(WebRouter.escape($0))</p>"
        } ?? ""
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
        <style>
          :root { color-scheme: dark; }
          body { font-family: -apple-system, system-ui, sans-serif; background:#16161a;
                 color:#e6e6ea; margin:0; display:flex; min-height:100vh;
                 align-items:center; justify-content:center; padding:24px; }
          form { background:#1e1e24; border:1px solid #2a2a32; border-radius:16px;
                 padding:28px; width:100%; max-width:380px; }
          h1 { font-size:18px; margin:0 0 6px; }
          .sub { color:#8a8a92; font-size:13px; margin:0 0 18px; }
          label { display:block; font-size:13px; color:#8a8a92; margin-bottom:6px; }
          input { width:100%; box-sizing:border-box; padding:10px 12px; border-radius:10px;
                  border:1px solid #33333d; background:#141418; color:#e6e6ea; font-size:14px; }
          button { margin-top:16px; width:100%; padding:11px; border:0; border-radius:10px;
                   background:#4f7cff; color:#fff; font-size:14px; font-weight:600; }
          .note { color:#e0a0a0; font-size:13px; margin:0 0 14px; }
          .warn { color:#f0a020; font-size:12px; margin:14px 0 0; }
        </style></head>
        <body><form method="post" action="/login">
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

    /// Minimal HTML escaping for text interpolated into a page.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
