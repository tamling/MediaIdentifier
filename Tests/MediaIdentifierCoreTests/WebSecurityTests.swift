import XCTest
@testable import MediaIdentifierCore

/// Logic tests for the web interface's access control. Pure request-in,
/// response-out, so they run identically on macOS and Linux.
final class WebSecurityTests: XCTestCase {

    private let token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func router(token tokenValue: String? = nil,
                        requireAuth: Bool = true,
                        anonymousHealth: Bool = true,
                        isTLS: Bool = true,
                        throttle: LoginThrottle = LoginThrottle(),
                        snapshot: StatusSnapshot = StatusSnapshot()) -> WebRouter {
        WebRouter(
            policy: WebSecurityPolicy(token: tokenValue ?? token,
                                      requireAuth: requireAuth,
                                      allowAnonymousHealth: anonymousHealth,
                                      isTLS: isTLS),
            throttle: throttle,
            snapshot: { snapshot }
        )
    }

    private func get(_ path: String, headers: [String: String] = [:]) -> HTTPRequest {
        HTTPRequest(method: "GET", path: path, headers: headers)
    }

    private func post(_ path: String, form: String, headers: [String: String] = [:]) -> HTTPRequest {
        HTTPRequest(method: "POST", path: path, headers: headers, body: Data(form.utf8))
    }

    private func bodyText(_ response: HTTPResponse) -> String {
        String(decoding: response.body, as: UTF8.self)
    }

    // MARK: Token handling

    func testGeneratedTokenIsLongAndNotRepeated() {
        let first = WebSecurityPolicy.generateToken()
        let second = WebSecurityPolicy.generateToken()
        XCTAssertEqual(first.count, 64, "256 bits, hex encoded")
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit })
    }

    func testConstantTimeCompare() {
        XCTAssertTrue(WebAuth.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(WebAuth.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(WebAuth.constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(WebAuth.constantTimeEquals("", "a"))
        XCTAssertTrue(WebAuth.constantTimeEquals("", ""))
        XCTAssertTrue(WebAuth.constantTimeEquals("münze", "münze"))
    }

    /// An unconfigured server must refuse everything rather than accept "".
    func testEmptyConfiguredTokenNeverMatches() {
        let policy = WebSecurityPolicy(token: "")
        XCTAssertFalse(policy.matches(""))
        XCTAssertFalse(policy.matches("anything"))
        XCTAssertFalse(router(token: "").isAuthorized(get("/", headers: ["authorization": "Bearer "])))
    }

    // MARK: Where a token may be presented

    func testAcceptsBearerHeader() {
        XCTAssertTrue(router().isAuthorized(get("/", headers: ["authorization": "Bearer \(token)"])))
        XCTAssertTrue(router().isAuthorized(get("/", headers: ["authorization": "bearer \(token)"])))
    }

    func testAcceptsDedicatedHeaderAndSessionCookie() {
        XCTAssertTrue(router().isAuthorized(get("/", headers: ["x-mediafin-token": token])))
        XCTAssertTrue(router().isAuthorized(
            get("/", headers: ["cookie": "other=1; mediafin_session=\(token)"])
        ))
    }

    /// A token in a URL would leak into logs, history and referrers.
    func testQueryStringTokenIsNotAccepted() {
        let request = HTTPRequest(method: "GET", path: "/", query: ["token": token])
        XCTAssertFalse(router().isAuthorized(request))
    }

    func testRejectsWrongAndMalformedCredentials() {
        XCTAssertFalse(router().isAuthorized(get("/")))
        XCTAssertFalse(router().isAuthorized(get("/", headers: ["authorization": "Bearer nope"])))
        XCTAssertFalse(router().isAuthorized(get("/", headers: ["authorization": token])))
        XCTAssertFalse(router().isAuthorized(get("/", headers: ["authorization": "Basic \(token)"])))
    }

    func testCookieParsing() {
        let request = get("/", headers: ["cookie": "a=1; b = two ; broken; a=9"])
        let cookies = WebAuth.cookies(in: request)
        XCTAssertEqual(cookies["a"], "1", "first value wins")
        XCTAssertEqual(cookies["b"], "two")
        XCTAssertNil(cookies["broken"])
    }

    func testAuthenticationCanBeSwitchedOff() {
        XCTAssertTrue(router(requireAuth: false).isAuthorized(get("/")))
    }

    // MARK: Gate in front of the routes

    func testUnauthenticatedAPIGets401WithChallenge() {
        let response = router().respond(to: get("/api/status"))
        XCTAssertEqual(response.status, 401)
        XCTAssertEqual(response.contentType, "application/json")
        XCTAssertEqual(response.headers["WWW-Authenticate"], #"Bearer realm="Mediafin""#)
        XCTAssertFalse(bodyText(response).contains(token), "the token must never be echoed")
    }

    func testUnauthenticatedPageGetsLoginFormWith401() {
        let response = router().respond(to: get("/"))
        XCTAssertEqual(response.status, 401)
        XCTAssertTrue(bodyText(response).contains("Sign in"))
        XCTAssertFalse(bodyText(response).contains(token))
    }

    func testAuthenticatedRoutesAnswer() {
        let authorized = get("/", headers: ["authorization": "Bearer \(token)"])
        let page = router(snapshot: StatusSnapshot(busy: true, renaming: true, renameProgress: 0.5))
            .respond(to: authorized)
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(bodyText(page).contains("Mediafin"))

        let api = router().respond(to: get("/api/status",
                                           headers: ["authorization": "Bearer \(token)"]))
        XCTAssertEqual(api.status, 200)
        XCTAssertEqual(api.contentType, "application/json")
    }

    func testUnknownPathIsNotFoundOnlyAfterAuthentication() {
        XCTAssertEqual(router().respond(to: get("/secret")).status, 401,
                       "an unauthenticated client must not learn which paths exist")
        let response = router().respond(to: get("/secret",
                                                headers: ["authorization": "Bearer \(token)"]))
        XCTAssertEqual(response.status, 404)
    }

    func testWriteMethodsAreRejectedOutsideLogin() {
        XCTAssertEqual(router().respond(to: post("/", form: "")).status, 405)
        XCTAssertEqual(router().respond(to: post("/api/status", form: "")).status, 405)
        XCTAssertEqual(
            router().respond(to: HTTPRequest(method: "DELETE", path: "/login")).status, 405
        )
    }

    // MARK: Health endpoint

    func testHealthAnswersAnonymouslyWhenAllowed() {
        let busy = router(snapshot: StatusSnapshot(busy: true, renaming: true, renameProgress: 0.25))
            .respond(to: get("/healthz"))
        XCTAssertEqual(busy.status, 503)
        XCTAssertEqual(bodyText(busy), "busy 25%")

        let idle = router().respond(to: get("/healthz"))
        XCTAssertEqual(idle.status, 200)
    }

    func testHealthReportsErrorsWithFiveHundred() {
        let response = router(snapshot: StatusSnapshot(lastResult: "3 failed", hasError: true))
            .respond(to: get("/healthz"))
        XCTAssertEqual(response.status, 500)
    }

    /// With anonymous health off it falls back behind the gate like anything else.
    func testHealthCanRequireAuthentication() {
        let locked = router(anonymousHealth: false)
        XCTAssertEqual(locked.respond(to: get("/healthz")).status, 401)
        XCTAssertEqual(
            locked.respond(to: get("/healthz", headers: ["authorization": "Bearer \(token)"])).status,
            200
        )
    }

    /// The anonymous probe must not leak what is being worked on.
    func testHealthRevealsNoFileNames() {
        let snapshot = StatusSnapshot(busy: true, converting: true, convertProgress: 0.4,
                                      currentFile: "Private.Home.Video.2019.mkv")
        let response = router(snapshot: snapshot).respond(to: get("/healthz"))
        XCTAssertFalse(bodyText(response).contains("Private.Home.Video"))
    }

    // MARK: Login

    func testSuccessfulLoginSetsHardenedCookieAndRedirects() throws {
        let response = router().respond(to: post("/login", form: "token=\(token)"))
        XCTAssertEqual(response.status, 303)
        XCTAssertEqual(response.headers["Location"], "/")
        let cookie = try XCTUnwrap(response.headers["Set-Cookie"])
        XCTAssertTrue(cookie.contains("mediafin_session=\(token)"))
        XCTAssertTrue(cookie.contains("HttpOnly"))
        XCTAssertTrue(cookie.contains("SameSite=Strict"))
        XCTAssertTrue(cookie.contains("Secure"))
        XCTAssertTrue(cookie.contains("Path=/"))
    }

    /// Over plain HTTP a `Secure` cookie would simply be dropped, so it is
    /// omitted — and the page says the connection is not encrypted.
    func testPlainHTTPOmitsSecureFlagAndWarns() throws {
        let plain = router(isTLS: false)
        let cookie = try XCTUnwrap(
            plain.respond(to: post("/login", form: "token=\(token)")).headers["Set-Cookie"]
        )
        XCTAssertFalse(cookie.contains("Secure"))
        XCTAssertTrue(bodyText(plain.loginPage()).contains("not encrypted"))
    }

    func testWrongTokenIsRefusedWithoutDetail() {
        let response = router().respond(to: post("/login", form: "token=wrong"))
        XCTAssertEqual(response.status, 401)
        let body = bodyText(response)
        XCTAssertTrue(body.contains("Wrong access token"))
        XCTAssertFalse(body.contains(token))
    }

    func testLoginFormIsReachableWithoutCredentials() {
        let response = router().respond(to: get("/login"))
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(bodyText(response).contains("type=\"password\""),
                      "the token must not be rendered on screen")
    }

    func testLogoutClearsTheCookie() throws {
        let response = router().respond(to: post("/logout", form: ""))
        XCTAssertEqual(response.status, 303)
        XCTAssertEqual(response.headers["Location"], "/login")
        let cookie = try XCTUnwrap(response.headers["Set-Cookie"])
        XCTAssertTrue(cookie.contains("Max-Age=0"))
    }

    /// No route takes a redirect target from the request, so the interface
    /// cannot be used to bounce someone to another site.
    func testRedirectTargetIsNotTakenFromTheRequest() {
        let request = HTTPRequest(method: "POST", path: "/login",
                                  query: ["next": "https://evil.example"],
                                  body: Data("token=\(token)&next=https://evil.example".utf8))
        let response = router().respond(to: request)
        XCTAssertEqual(response.headers["Location"], "/")
    }

    // MARK: Brute-force protection

    func testRepeatedFailuresAreThrottled() {
        let throttle = LoginThrottle(maxAttempts: 3, window: 300)
        let guarded = router(throttle: throttle)
        for _ in 0..<3 {
            XCTAssertEqual(guarded.respond(to: post("/login", form: "token=wrong")).status, 401)
        }
        let blocked = guarded.respond(to: post("/login", form: "token=wrong"))
        XCTAssertEqual(blocked.status, 429)
        XCTAssertNotNil(blocked.headers["Retry-After"])

        // Even the correct token is refused while blocked, so the limit cannot
        // be probed around.
        XCTAssertEqual(guarded.respond(to: post("/login", form: "token=\(token)")).status, 429)
    }

    func testThrottleWindowExpires() {
        let clock = Clock()
        let throttle = LoginThrottle(maxAttempts: 2, window: 60, now: { clock.now })
        throttle.recordFailure()
        throttle.recordFailure()
        XCTAssertTrue(throttle.isBlocked())
        XCTAssertGreaterThan(throttle.retryAfterSeconds(), 0)

        clock.advance(61)
        XCTAssertFalse(throttle.isBlocked())
        XCTAssertEqual(throttle.retryAfterSeconds(), 0)
    }

    func testSuccessfulLoginClearsTheThrottle() {
        let throttle = LoginThrottle(maxAttempts: 3, window: 300)
        let guarded = router(throttle: throttle)
        _ = guarded.respond(to: post("/login", form: "token=wrong"))
        _ = guarded.respond(to: post("/login", form: "token=wrong"))
        XCTAssertEqual(guarded.respond(to: post("/login", form: "token=\(token)")).status, 303)
        XCTAssertFalse(throttle.isBlocked())
    }

    // MARK: Response hardening

    func testHTMLCarriesContentSecurityPolicyForbiddingScripts() {
        let raw = String(decoding: router().respond(to: get("/login")).serialized(), as: UTF8.self)
        XCTAssertTrue(raw.contains("Content-Security-Policy:"))
        XCTAssertTrue(raw.contains("default-src 'none'"))
        XCTAssertTrue(raw.contains("frame-ancestors 'none'"))
        XCTAssertTrue(raw.contains("X-Frame-Options: DENY"))
        XCTAssertTrue(raw.contains("Referrer-Policy: no-referrer"))
    }

    func testJSONDoesNotCarryTheHTMLPolicy() {
        let raw = String(decoding: HTTPResponse.json(Data("{}".utf8)).serialized(), as: UTF8.self)
        XCTAssertFalse(raw.contains("Content-Security-Policy:"))
        XCTAssertTrue(raw.contains("X-Frame-Options: DENY"))
    }

    func testLoginMessageIsEscaped() {
        let page = router().loginPage(status: 401, message: "<script>alert(1)</script>")
        let body = bodyText(page)
        XCTAssertFalse(body.contains("<script>"))
        XCTAssertTrue(body.contains("&lt;script&gt;"))
    }

    // MARK: Helpers

    /// Injectable clock for the throttle window.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_700_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock()
        }
    }
}
