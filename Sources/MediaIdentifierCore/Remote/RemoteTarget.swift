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

    /// Which of the three libraries a file belongs to.
    ///
    /// Three paths and not one, because a server almost never has all three
    /// under one parent. `/volume1/Filme`, `/volume2/Serien`, `/volume1/Musik`
    /// is the ordinary shape of a NAS with two disks, and a single base path
    /// cannot say it — it would put the series on the disk the films are on.
    public enum Library: String, Codable, Sendable, CaseIterable {
        case movies
        case series
        case music

        public var label: String {
            switch self {
            case .movies: return Text.s("Filme", "Films")
            case .series: return Text.s("Serien", "Series")
            case .music: return Text.s("Musik", "Music")
            }
        }

        /// Which library a file belongs to, from the file itself.
        ///
        /// The extension decides music, not the parsed kind: a track is
        /// parsed as `.unknown`, which is also what an unrecognised film is,
        /// so going by the kind alone would send albums to the film folder.
        public static func of(_ url: URL, kind: MediaKind) -> Library {
            if AudioFileTypes.isAudio(url) { return .music }
            return kind == .episode ? .series : .movies
        }
    }

    public var isEnabled: Bool
    public var host: String
    public var port: Int
    public var user: String
    /// Absolute path on the server that the library is written under, for
    /// whichever of the three below is left empty.
    public var basePath: String
    /// Where films go on the server. Empty means "under the base path".
    public var moviesPath: String
    /// Where series go on the server. Empty means "under the base path".
    public var seriesPath: String
    /// Where music goes on the server. Empty means "under the base path".
    public var musicPath: String
    public var transport: Transport
    public var authentication: Authentication
    /// Remember a server's host key the first time it is seen.
    ///
    /// Off by default. On, ssh is given `StrictHostKeyChecking=accept-new`:
    /// a server it has never met is written to `known_hosts` without asking,
    /// and one whose key has **changed** is still refused. That second half
    /// is the point — a changed key is what a machine in the middle looks
    /// like, and `=no`, which accepts that too, would make every other
    /// precaution in this file pointless. So this is the first connection
    /// made easy, not the check turned off.
    public var trustOnFirstUse: Bool
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
                moviesPath: String = "",
                seriesPath: String = "",
                musicPath: String = "",
                transport: Transport = .rsync,
                authentication: Authentication = .key,
                identityFile: String = "",
                trustOnFirstUse: Bool = false,
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
        self.moviesPath = moviesPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.seriesPath = seriesPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.musicPath = musicPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
        self.authentication = authentication
        self.identityFile = identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        self.trustOnFirstUse = trustOnFirstUse
        self.removeLocalAfterSend = removeLocalAfterSend
    }

    // MARK: Where each kind goes

    /// The server path a given library is written under.
    ///
    /// Falls back to `basePath`, so a setup that worked with one path keeps
    /// working and only the kinds that live somewhere else need filling in.
    public func path(for library: Library) -> String {
        let specific: String
        switch library {
        case .movies: specific = moviesPath
        case .series: specific = seriesPath
        case .music: specific = musicPath
        }
        return specific.isEmpty ? basePath : specific
    }

    /// Every distinct path a transfer could write to, with what lands there.
    ///
    /// What the connection test checks. With one path per kind it becomes
    /// possible for films to work and music to fail silently, so testing
    /// only one of them would be testing the wrong thing.
    public func targetPaths() -> [(path: String, libraries: [Library])] {
        var order: [String] = []
        var byPath: [String: [Library]] = [:]
        for library in Library.allCases {
            let path = self.path(for: library)
            guard !path.isEmpty else { continue }
            if byPath[path] == nil { order.append(path) }
            byPath[path, default: []].append(library)
        }
        return order.map { ($0, byPath[$0] ?? []) }
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
            moviesPath: value(.moviesPath, defaults.moviesPath),
            seriesPath: value(.seriesPath, defaults.seriesPath),
            musicPath: value(.musicPath, defaults.musicPath),
            transport: value(.transport, defaults.transport),
            authentication: value(.authentication, defaults.authentication),
            identityFile: value(.identityFile, defaults.identityFile),
            trustOnFirstUse: value(.trustOnFirstUse, defaults.trustOnFirstUse),
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
        var moviesPath = current.moviesPath
        var seriesPath = current.seriesPath
        var musicPath = current.musicPath
        var transport = current.transport
        var authentication = current.authentication
        var identityFile = current.identityFile
        var isEnabled = current.isEnabled
        var trustOnFirstUse = current.trustOnFirstUse
        var removeLocal = current.removeLocalAfterSend

        if let value = fields["remoteHost"] { host = value }
        if let value = fields["remoteUser"] { user = value }
        if let value = fields["remoteBasePath"] { basePath = value }
        if let value = fields["remoteMoviesPath"] { moviesPath = value }
        if let value = fields["remoteSeriesPath"] { seriesPath = value }
        if let value = fields["remoteMusicPath"] { musicPath = value }
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
        if fields["remoteTrustOnFirstUsePresent"] != nil {
            trustOnFirstUse = fields["remoteTrustOnFirstUse"] != nil
        }

        return RemoteTarget(isEnabled: isEnabled, host: host, port: port, user: user,
                            basePath: basePath, moviesPath: moviesPath,
                            seriesPath: seriesPath, musicPath: musicPath,
                            transport: transport,
                            authentication: authentication, identityFile: identityFile,
                            trustOnFirstUse: trustOnFirstUse,
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
        // The base path is only needed for the kinds that have no path of
        // their own: fill in all three and it may stay empty.
        let perKind = [moviesPath, seriesPath, musicPath]
        if basePath.isEmpty, perKind.contains(where: \.isEmpty) {
            found.append(.init(field: "remoteBasePath",
                               message: Text.s("Der Zielpfad auf dem Server fehlt.", "The target path on the server is missing.")))
        } else if !basePath.isEmpty, !basePath.hasPrefix("/") {
            // A relative path would land in the login directory, which is
            // rarely where a media library is and is hard to notice.
            found.append(.init(field: "remoteBasePath",
                               message: Text.s("Der Zielpfad muss absolut sein, also mit / beginnen.", "The target path must be absolute, so it has to start with /.")))
        }
        for (field, path, what) in [
            ("remoteMoviesPath", moviesPath, Library.movies.label),
            ("remoteSeriesPath", seriesPath, Library.series.label),
            ("remoteMusicPath", musicPath, Library.music.label),
        ] where !path.isEmpty && !path.hasPrefix("/") {
            found.append(.init(field: field, message: Text.s(
                "Der Pfad für \(what) muss absolut sein, also mit / beginnen.",
                "The path for \(what) must be absolute, so it has to start with /.")))
        }
        if !(1...65535).contains(port) {
            found.append(.init(field: "remotePort", message: Text.s("Der Port muss 1–65535 sein.", "The port must be between 1 and 65535.")))
        }
        return found
    }
}
