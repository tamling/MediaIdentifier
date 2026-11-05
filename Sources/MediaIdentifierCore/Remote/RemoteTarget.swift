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
            case .rsync: return Text.s("rsync über SSH (fortsetzbar, mit Fortschritt, empfohlen)", "rsync over SSH (resumable, with progress, recommended)")
            case .sftp: return Text.s("SFTP (läuft überall, ohne Fortschrittsanzeige)", "SFTP (works everywhere, no progress)")
            }
        }

        /// Whether the tool says anything about how far it has got.
        ///
        /// rsync does, with `--info=progress2`. sftp does not, and cannot be
        /// made to: it draws its meter only when standard output is a
        /// terminal and never in batch mode, and batch mode is how a script
        /// drives it at all. Measured against a real server rather than
        /// assumed — the first version of this code assumed otherwise and
        /// the integration test caught it.
        public var reportsProgress: Bool {
            switch self {
            case .rsync: return true
            case .sftp: return false
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
            case .key: return Text.s("SSH-Schlüssel (nichts zu speichern)", "SSH key (nothing to store)")
            case .password: return Text.s("Passwort", "Password")
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
    /// Delete the local file once the server has an identical copy.
    ///
    /// Off by default, and deliberately: sending is a copy, which can be
    /// undone by deleting the new file, while moving destroys the only
    /// other copy of someone's recording. Nobody's media is deleted
    /// because a default said so.
    public var removeLocalAfterSend: Bool

    public init(isEnabled: Bool = false,
                host: String = "",
                port: Int = 22,
                user: String = "",
                basePath: String = "",
                transport: Transport = .rsync,
                authentication: Authentication = .key,
                identityFile: String = "",
                removeLocalAfterSend: Bool = false) {
        self.isEnabled = isEnabled
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        // Kept as given. Clamping it here meant problems() could never see
        // an out-of-range port, so "Der Port muss 1–65535 sein." was
        // unreachable and a mistyped port silently became 22 — which is a
        // different machine's SSH port, not a correction.
        self.port = port
        self.user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        self.basePath = basePath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
        self.authentication = authentication
        self.identityFile = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        self.removeLocalAfterSend = removeLocalAfterSend
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
            identityFile: value(.identityFile, defaults.identityFile),
            removeLocalAfterSend: value(.removeLocalAfterSend, defaults.removeLocalAfterSend)
        )
    }

    /// `user@host`, the form both tools take.
    public var destination: String { user.isEmpty ? host : "\(user)@\(host)" }

    /// Reads the form, starting from what is stored.
    ///
    /// Absent fields keep their current value, so a form that does not carry
    /// the server section — the conversion page's own form, for one — cannot
    /// wipe it. Checkboxes send nothing when unticked, so each has a hidden
    /// companion field that says the section was present at all.
    public static func fromForm(_ fields: [String: String],
                                current: RemoteTarget) -> RemoteTarget {
        var host = current.host
        var port = current.port
        var user = current.user
        var basePath = current.basePath
        var transport = current.transport
        var authentication = current.authentication
        var identityFile = current.identityFile
        var isEnabled = current.isEnabled
        var removeLocal = current.removeLocalAfterSend

        if let value = fields["remoteHost"] { host = value }
        if let value = fields["remoteUser"] { user = value }
        if let value = fields["remoteBasePath"] { basePath = value }
        if let value = fields["remoteIdentityFile"] { identityFile = value }
        // A port that is not a number keeps the stored one rather than
        // silently becoming 22: the form shows what was kept.
        if let value = fields["remotePort"], let number = Int(value.trimmingCharacters(
            in: .whitespaces)) {
            port = number
        }
        if let value = fields["remoteTransport"], let choice = Transport(rawValue: value) {
            transport = choice
        }
        if let value = fields["remoteAuthentication"],
           let choice = Authentication(rawValue: value) {
            authentication = choice
        }
        if fields["remoteEnabledPresent"] != nil {
            isEnabled = fields["remoteEnabled"] != nil
        }
        if fields["remoteRemoveLocalPresent"] != nil {
            removeLocal = fields["remoteRemoveLocal"] != nil
        }

        return RemoteTarget(isEnabled: isEnabled, host: host, port: port, user: user,
                            basePath: basePath, transport: transport,
                            authentication: authentication, identityFile: identityFile,
                            removeLocalAfterSend: removeLocal)
    }

    /// What is missing or wrong, in the same shape the settings form uses.
    public func problems() -> [WebSettings.Problem] {
        guard isEnabled else { return [] }
        var found: [WebSettings.Problem] = []
        if host.isEmpty {
            found.append(.init(field: "remoteHost", message: Text.s("Die Serveradresse fehlt.", "The server address is missing.")))
        } else if host.contains(" ") || host.contains("/") {
            found.append(.init(field: "remoteHost",
                               message: Text.s("Die Serveradresse darf keine Leerzeichen oder Schrägstriche enthalten.", "The server address may not contain spaces or slashes.")))
        }
        if user.isEmpty {
            found.append(.init(field: "remoteUser", message: Text.s("Der Benutzername fehlt.", "The user name is missing.")))
        }
        if basePath.isEmpty {
            found.append(.init(field: "remoteBasePath",
                               message: Text.s("Der Zielpfad auf dem Server fehlt.", "The target path on the server is missing.")))
        } else if !basePath.hasPrefix("/") {
            // A relative path would land in the login directory, which is
            // rarely where a media library is and is hard to notice.
            found.append(.init(field: "remoteBasePath",
                               message: Text.s("Der Zielpfad muss absolut sein, also mit / beginnen.", "The target path must be absolute, so it has to start with /.")))
        }
        if !(1...65535).contains(port) {
            found.append(.init(field: "remotePort", message: Text.s("Der Port muss 1–65535 sein.", "The port must be between 1 and 65535.")))
        }
        return found
    }
}
