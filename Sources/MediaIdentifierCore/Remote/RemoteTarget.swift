import Foundation

/// Where files go when the library lives on another machine.
///
/// Mediafin does not speak SSH itself. It drives the tools that already do —
/// `rsync` and OpenSSH's `sftp` — because an SSH implementation is a thing to
/// get wrong quietly, and every Linux machine already has a correct one that
/// is kept patched by its distribution.
public struct RemoteTarget: Codable, Sendable, Equatable {

    /// Which tool carries the bytes.
    public enum Transport: String, Codable, Sendable, CaseIterable {
        /// Resumable, reports real progress, skips what is already there.
        /// Needs rsync on both ends.
        case rsync
        /// Works wherever there is an SSH login at all, including the thin
        /// firmware on a NAS. No resume, coarser progress.
        case sftp

        public var label: String {
            switch self {
            case .rsync: return "rsync über SSH (fortsetzbar, empfohlen)"
            case .sftp: return "SFTP (läuft überall)"
            }
        }
    }

    /// How to prove who we are.
    public enum Authentication: String, Codable, Sendable, CaseIterable {
        /// An SSH key. Nothing secret is stored by Mediafin at all.
        case key
        /// A password, kept in the secret store and handed to ssh through
        /// the environment rather than the command line.
        case password

        public var label: String {
            switch self {
            case .key: return "SSH-Schlüssel (nichts zu speichern)"
            case .password: return "Passwort"
            }
        }
    }

    public var isEnabled: Bool
    public var host: String
    public var port: Int
    public var user: String
    /// Absolute path on the server that the library is written under.
    public var basePath: String
    public var transport: Transport
    public var authentication: Authentication
    /// Private key file. Empty means ssh picks from its own configuration,
    /// which is usually what someone with a working ssh setup wants.
    public var identityFile: String

    public init(isEnabled: Bool = false,
                host: String = "",
                port: Int = 22,
                user: String = "",
                basePath: String = "",
                transport: Transport = .rsync,
                authentication: Authentication = .key,
                identityFile: String = "") {
        self.isEnabled = isEnabled
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = (1...65535).contains(port) ? port : 22
        self.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        self.basePath = basePath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
        self.authentication = authentication
        self.identityFile = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decoded through the memberwise initialiser so a hand-edited settings
    /// file gets the same trimming and port clamping as the form.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RemoteTarget()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        self.init(
            isEnabled: value(.isEnabled, defaults.isEnabled),
            host: value(.host, defaults.host),
            port: value(.port, defaults.port),
            user: value(.user, defaults.user),
            basePath: value(.basePath, defaults.basePath),
            transport: value(.transport, defaults.transport),
            authentication: value(.authentication, defaults.authentication),
            identityFile: value(.identityFile, defaults.identityFile)
        )
    }

    /// `user@host`, the form both tools take.
    public var destination: String { user.isEmpty ? host : "\(user)@\(host)" }

    /// What is missing or wrong, in the same shape the settings form uses.
    public func problems() -> [WebSettings.Problem] {
        guard isEnabled else { return [] }
        var found: [WebSettings.Problem] = []
        if host.isEmpty {
            found.append(.init(field: "remoteHost", message: "Die Serveradresse fehlt."))
        } else if host.contains(" ") || host.contains("/") {
            found.append(.init(field: "remoteHost",
                               message: "Die Serveradresse darf keine Leerzeichen oder "
                                   + "Schrägstriche enthalten."))
        }
        if user.isEmpty {
            found.append(.init(field: "remoteUser", message: "Der Benutzername fehlt."))
        }
        if basePath.isEmpty {
            found.append(.init(field: "remoteBasePath",
                               message: "Der Zielpfad auf dem Server fehlt."))
        } else if !basePath.hasPrefix("/") {
            // A relative path would land in the login directory, which is
            // rarely where a media library is and is hard to notice.
            found.append(.init(field: "remoteBasePath",
                               message: "Der Zielpfad muss absolut sein, also mit / beginnen."))
        }
        if !(1...65535).contains(port) {
            found.append(.init(field: "remotePort", message: "Der Port muss 1–65535 sein."))
        }
        return found
    }
}
