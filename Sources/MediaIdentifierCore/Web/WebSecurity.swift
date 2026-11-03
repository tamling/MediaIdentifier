import Foundation

/// Security policy for the local web interface.
///
/// The web UI can reach the whole media library, so it is treated as a
/// privileged surface: authenticated by default, served over TLS by default,
/// and bound to loopback unless the user opens it deliberately.
public struct WebSecurityPolicy: Sendable, Equatable {
    /// Name of the session cookie the browser gets after logging in.
    public static let sessionCookieName = "mediafin_session"

    /// Shared secret. An empty token with `requireAuth` on means "not
    /// configured yet", and every request is refused rather than let through.
    public var token: String
    /// When false the interface is wide open — only sensible for loopback.
    public var requireAuth: Bool
    /// Let `/healthz` answer without a token so a plain uptime monitor can poll
    /// it. It reveals only idle/busy/error, never file names.
    public var allowAnonymousHealth: Bool
    /// True when the connection is TLS, which decides whether the session
    /// cookie carries `Secure` (a `Secure` cookie is dropped over plain HTTP).
    public var isTLS: Bool

    public init(token: String, requireAuth: Bool = true,
                allowAnonymousHealth: Bool = true, isTLS: Bool = true) {
        self.token = token
        self.requireAuth = requireAuth
        self.allowAnonymousHealth = allowAnonymousHealth
        self.isTLS = isTLS
    }

    /// A fresh 256-bit token, hex encoded.
    public static func generateToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32)
            .map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }
            .joined()
    }

    /// True when `candidate` is the configured token. An unset token never
    /// matches, so a misconfigured server cannot be logged into.
    public func matches(_ candidate: String) -> Bool {
        guard !token.isEmpty else { return false }
        return WebAuth.constantTimeEquals(token, candidate)
    }

    /// The `Set-Cookie` value establishing a session.
    ///
    /// `HttpOnly` keeps it away from scripts, `SameSite=Strict` stops another
    /// site from riding the session, and `Secure` is added over TLS.
    public func sessionCookie(value: String, maxAgeSeconds: Int = 60 * 60 * 12) -> String {
        var cookie = "\(Self.sessionCookieName)=\(value); Path=/; HttpOnly; SameSite=Strict"
        cookie += "; Max-Age=\(maxAgeSeconds)"
        if isTLS { cookie += "; Secure" }
        return cookie
    }

    /// A `Set-Cookie` value that deletes the session.
    public func clearedCookie() -> String {
        var cookie = "\(Self.sessionCookieName)=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
        if isTLS { cookie += "; Secure" }
        return cookie
    }
}

/// Request authentication helpers.
public enum WebAuth {
    /// Where a token may be presented, in the order it is looked for.
    ///
    /// Deliberately **not** the query string: URLs end up in logs, history and
    /// referrers, so a token in one would leak.
    public static func presentedToken(in request: HTTPRequest) -> String? {
        if let header = request.headers["authorization"] {
            let parts = header.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                return String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        if let header = request.headers["x-mediafin-token"], !header.isEmpty {
            return header
        }
        return cookies(in: request)[WebSecurityPolicy.sessionCookieName]
    }

    /// Parses a `Cookie:` header into its pairs.
    public static func cookies(in request: HTTPRequest) -> [String: String] {
        guard let header = request.headers["cookie"] else { return [:] }
        var result: [String: String] = [:]
        for pair in header.split(separator: ";") {
            let halves = pair.split(separator: "=", maxSplits: 1)
            guard halves.count == 2 else { continue }
            let name = halves[0].trimmingCharacters(in: .whitespaces)
            let value = halves[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, result[name] == nil else { continue }
            result[name] = value
        }
        return result
    }

    /// Length-independent comparison, so the time taken does not reveal how
    /// many leading characters of a guess were right.
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference: UInt8 = left.count == right.count ? 0 : 1
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }
}

/// Rate limit for failed logins, so the token cannot be brute-forced.
///
/// The limit is global rather than per client address: the interface serves a
/// single user, and a per-address limit would be trivially bypassed by anyone
/// who could reach it at all.
public final class LoginThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private let maxAttempts: Int
    private let window: TimeInterval
    private let now: @Sendable () -> Date
    private var failures: [Date] = []

    public init(maxAttempts: Int = 10, window: TimeInterval = 300,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.maxAttempts = maxAttempts
        self.window = window
        self.now = now
    }

    /// True while further login attempts should be refused.
    public func isBlocked() -> Bool {
        lock.lock(); defer { lock.unlock() }
        prune()
        return failures.count >= maxAttempts
    }

    public func recordFailure() {
        lock.lock(); defer { lock.unlock() }
        prune()
        failures.append(now())
    }

    /// Clears the history, so a correct login does not leave the user throttled.
    public func recordSuccess() {
        lock.lock(); defer { lock.unlock() }
        failures.removeAll()
    }

    /// Seconds until the next attempt is allowed, 0 when not blocked.
    public func retryAfterSeconds() -> Int {
        lock.lock(); defer { lock.unlock() }
        prune()
        guard failures.count >= maxAttempts, let oldest = failures.first else { return 0 }
        return max(1, Int((oldest.addingTimeInterval(window).timeIntervalSince(now())).rounded(.up)))
    }

    /// Drops failures that have aged out of the window. Caller holds the lock.
    private func prune() {
        let cutoff = now().addingTimeInterval(-window)
        failures.removeAll { $0 < cutoff }
    }
}
