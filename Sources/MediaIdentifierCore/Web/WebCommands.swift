import Foundation

/// Something the interface asks the app to do.
///
/// Commands are submitted and acknowledged immediately; anything slow (a scan,
/// a rename, a connection test) runs in the background and reports back
/// through `StatusSnapshot`. That keeps request handling free of long waits and
/// means a reload never re-triggers work.
public enum WebCommand: Sendable, Equatable {
    case saveSettings(WebSettings)
    /// An empty value clears the secret.
    case setSecret(SecretKey, String)
    case testLocalLLMConnection
    case testJellyfinConnection
    case scanSourceFolder
    /// Applies the proposed renames. `accepting` lists the items the user
    /// ticked; nil means every proposal.
    case applyProposedRenames(accepting: Set<UUID>?)
    case undoLastRename
    case startConversions
    case clearHistory
}

/// Accepts commands from the interface. Implementations must return at once.
public protocol WebCommandSink: Sendable {
    func submit(_ command: WebCommand)
}

/// Guards state-changing requests against being triggered by another site.
///
/// The session cookie is already `SameSite=Strict`, which a current browser
/// will not send on a cross-site form post, and the page's
/// `Content-Security-Policy` sets `form-action 'self'`. This token is the third
/// layer, so a single browser quirk is not enough on its own.
///
/// The token is per process: after a restart an open form is rejected once and
/// works on reload. That is a fair trade for not having to store it.
public struct CSRFToken: Sendable, Equatable {
    public let value: String

    public init(value: String = WebSecurityPolicy.generateToken()) {
        self.value = value
    }

    /// The hidden form field carrying it.
    public static let fieldName = "_csrf"

    public func matches(_ candidate: String?) -> Bool {
        guard let candidate, !candidate.isEmpty else { return false }
        return WebAuth.constantTimeEquals(value, candidate)
    }

    /// The hidden input to put in every form that changes something.
    public var hiddenField: String {
        "<input type=\"hidden\" name=\"\(Self.fieldName)\" value=\"\(value)\">"
    }
}

/// Checks that a state-changing request came from the interface itself.
public enum RequestOrigin {
    /// Rejects a request whose `Origin` or `Sec-Fetch-Site` shows it came from
    /// somewhere else. A missing header is accepted: curl and older browsers
    /// send none, and the CSRF token still has to match.
    public static func isSameSite(_ request: HTTPRequest) -> Bool {
        if let fetchSite = request.headers["sec-fetch-site"]?.lowercased() {
            guard fetchSite == "same-origin" || fetchSite == "same-site" || fetchSite == "none"
            else { return false }
        }
        guard let origin = request.headers["origin"], !origin.isEmpty, origin != "null" else {
            return true
        }
        guard let host = request.headers["host"], !host.isEmpty,
              let originHost = URL(string: origin)?.host
        else { return false }
        // `Host` carries the port, `Origin`'s host does not.
        let hostWithoutPort = host.split(separator: ":").first.map(String.init) ?? host
        return originHost == hostWithoutPort
    }
}
