import Foundation

/// Whether an address is one a key may travel to unencrypted.
///
/// Both configurable services take a credential: the model server its API key,
/// Jellyfin its token. Over `http://` that key is on the wire in clear text,
/// readable by anything between here and there. `http://192.168.3.116:1234`
/// is nevertheless the normal case — LM Studio serves plain HTTP and a
/// self-signed certificate for a machine on the same desk buys nothing — so
/// refusing plain HTTP outright would refuse the setup most people have.
///
/// The line is therefore drawn at the network, not at the scheme: plain HTTP
/// to a machine on the local network is accepted quietly; plain HTTP to a
/// public host is the one that is called out, because that key really does
/// leave the house unprotected.
///
/// In Core, and pure, so the rule can be tested without a network — which is
/// the only way it gets tested at all here.
public enum URLSafety {

    /// Whether `host` names a machine on this network or this machine.
    ///
    /// Addresses only, plus the two name forms that cannot leave a LAN:
    /// anything else is treated as public, because guessing wrong in that
    /// direction merely shows a warning, while guessing wrong the other way
    /// hides one.
    public static func isPrivateHost(_ host: String) -> Bool {
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if name.isEmpty { return false }
        if name == "localhost" || name.hasSuffix(".localhost") { return true }
        // A bare name with no dot cannot be resolved outside a local network.
        if !name.contains(".") && !name.contains(":") { return true }
        // mDNS, and the names a home router hands out.
        for suffix in [".local", ".lan", ".home", ".internal", ".home.arpa"] {
            if name.hasSuffix(suffix) { return true }
        }
        if name == "::1" { return true }
        if name.hasPrefix("fe80:") || name.hasPrefix("fc") || name.hasPrefix("fd") {
            // Link-local and unique-local IPv6. "fc"/"fd" would also match a
            // name, but a name containing a colon is not one.
            if name.contains(":") { return true }
        }

        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 4, numbers.allSatisfy({ (0...255).contains($0) })
        else { return false }
        switch (numbers[0], numbers[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// True when a credential sent to `address` would be readable in transit.
    ///
    /// False for anything that is not a usable address: an unparsable field
    /// is a different complaint, with its own message, and reporting it twice
    /// in two voices helps nobody.
    public static func sendsCredentialsInTheClear(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty
        else { return false }
        return scheme == "http" && !isPrivateHost(host)
    }
}
