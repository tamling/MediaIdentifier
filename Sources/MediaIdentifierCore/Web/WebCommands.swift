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
    /// Looks for files that could be converted, so the page has something to
    /// show. Does not convert anything.
    case findConvertible
    /// Converts the files the user ticked. Never started on its own.
    case convertFiles(accepting: Set<UUID>)
    case cancelConversions
    /// Sends the files the user ticked to the remote library, sorted into the
    /// proposed folders. Never started on its own.
    /// Ticks or unticks every proposal.
    ///
    /// Server-side because the web interface forbids JavaScript outright in
    /// its own Content-Security-Policy, so "select all" cannot be a script.
    /// Keeping the state in the engine also means a reload does not lose it.
    case setAllAccepted(Bool)
    /// Ticks or unticks one proposal.
    ///
    /// The web page has no need of this — its checkboxes carry the whole
    /// selection in the form that applies it — but a terminal has no form,
    /// and the counts in its header come from the engine, so the engine has
    /// to be where a tick is recorded.
    case setAccepted(UUID, Bool)
    case transferFiles(accepting: Set<UUID>)
    case cancelTransfers
    /// Fetches one URL into the import folder with yt-dlp, then scans, so
    /// the download appears as a proposal like anything else that lands
    /// there. Never started on its own.
    case downloadURL(String)
    case cancelDownload
    /// Logs in to the server and checks the target path, for the status panel.
    case testRemoteConnection
    /// Runs every connection test there is, so one press answers "is
    /// everything there?" instead of three.
    case checkEverything
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
    ///
    /// The comparison includes the port, and `Sec-Fetch-Site: same-site` is
    /// **not** accepted. A "site" is port-blind, so a page served from another
    /// port of the same machine — a Jellyfin at :8096, a dev server at :3000 —
    /// reports `same-site` and shares a hostname while being a different
    /// origin to every other part of the browser's security model. Its cookies
    /// reach us too, for the same port-blind reason, so this check is the only
    /// thing that can tell it apart from the real interface.
    ///
    /// - Parameter isTLS: how to fill in an absent port in `Host`, which omits
    ///   it when it is the default for the scheme.
    public static func isSameSite(_ request: HTTPRequest, isTLS: Bool = true) -> Bool {
        if let fetchSite = request.headers["sec-fetch-site"]?.lowercased() {
            guard fetchSite == "same-origin" || fetchSite == "none" else { return false }
        }
        // A literal "null" origin is never this interface. It comes from
        // sandboxed iframes and from redirects that cross an origin, so it is
        // refused rather than treated as absent. An absent header still passes:
        // curl and older browsers send none, and the CSRF token still has to
        // match.
        if let origin = request.headers["origin"], origin.lowercased() == "null" { return false }
        guard let origin = request.headers["origin"], !origin.isEmpty else {
            return true
        }
        guard let host = request.headers["host"], !host.isEmpty,
              let url = URL(string: origin), let originHost = url.host
        else { return false }

        let originPort = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        let target = authority(host, defaultPort: isTLS ? 443 : 80)
        return originHost.lowercased() == target.host.lowercased() && originPort == target.port
    }

    /// Splits `host[:port]` into its parts, filling in `defaultPort` when the
    /// port is absent. Handles the bracketed form IPv6 literals use,
    /// `[::1]:8741`, whose colons would otherwise be read as separators.
    static func authority(_ value: String, defaultPort: Int) -> (host: String, port: Int) {
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            // URL.host reports an IPv6 literal without its brackets, so this
            // strips them to match.
            let host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            if rest.hasPrefix(":"), let port = Int(rest.dropFirst()) { return (host, port) }
            return (host, defaultPort)
        }
        let parts = value.split(separator: ":", maxSplits: 1)
        if parts.count == 2, let port = Int(parts[1]) { return (String(parts[0]), port) }
        return (String(parts.first ?? ""), defaultPort)
    }
}
