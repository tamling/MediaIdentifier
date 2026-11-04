import Foundation

/// One lamp on the traffic light.
///
/// The point of this panel is to answer "why did nothing happen?" before the
/// user has to go looking. So a lamp never says only that something is wrong:
/// it carries the sentence that says what to do about it.
public struct SystemCheck: Identifiable, Equatable, Sendable {

    /// Three colours and an absence.
    ///
    /// `.off` is not a failure — it is a part of the program the user is not
    /// using. Colouring an unused service red teaches people to ignore the
    /// panel, which costs more than leaving it grey.
    public enum State: String, Sendable, Equatable {
        case ok
        case warning
        case failed
        case off

        /// For a terminal, a screen reader, and anywhere colour alone will
        /// not carry: the lamp always has a word next to it.
        public var word: String {
            switch self {
            case .ok: return "bereit"
            case .warning: return "prüfen"
            case .failed: return "Problem"
            case .off: return "aus"
            }
        }
    }

    /// Stable across refreshes, so a list can keep its rows in place rather
    /// than rebuilding and flickering twice a second.
    public let id: String
    public let name: String
    public let state: State
    public let detail: String

    public init(id: String, name: String, state: State, detail: String) {
        self.id = id
        self.name = name
        self.state = state
        self.detail = detail
    }
}

/// The outcome of asking a service whether it is there.
///
/// Kept with the time it was taken: a green lamp from an hour ago is not the
/// same claim as a green lamp from a second ago, and the panel says which.
public struct ProbeResult: Equatable, Sendable {
    public let ok: Bool
    public let detail: String
    public let date: Date

    public init(ok: Bool, detail: String, date: Date = Date()) {
        self.ok = ok
        self.detail = detail
        self.date = date
    }
}

/// Which service a probe was about.
public enum ProbeSubject: String, Sendable, Equatable, CaseIterable {
    case localLLM
    case jellyfin
    case remote
}

/// Works out the lamps.
///
/// Everything it needs is passed in — no file system of its own, no settings
/// singleton, no clock — so every row below can be tested without a server, a
/// model or a media library. That matters more here than anywhere else in the
/// program: a status panel that lies is worse than no status panel.
public enum SystemChecks {

    public static func all(
        settings: WebSettings,
        tools: RemoteTools,
        ffmpegAvailable: Bool,
        secrets: Set<SecretKey>,
        probes: [ProbeSubject: ProbeResult],
        fileManager: FileManager = .default
    ) -> [SystemCheck] {
        var checks: [SystemCheck] = []

        checks.append(folder(id: "source", name: "Importordner",
                             path: settings.sourceFolder,
                             missingDetail: "Noch kein Ordner gewählt — ohne ihn gibt es "
                                 + "nichts zu durchsuchen.",
                             fileManager: fileManager))

        // With a server configured, the local library folders are not where
        // the library lives, so demanding them would be a red lamp for a
        // setup that is working exactly as the user set it up.
        if settings.remote.isEnabled {
            let where_ = settings.remote.host.isEmpty
                ? "(Adresse fehlt)" : settings.remote.host
            checks.append(SystemCheck(id: "library", name: "Bibliothek", state: .ok,
                                      detail: "Liegt auf dem Server \(where_)."))
        } else {
            checks.append(folder(id: "movies", name: "Filme", path: settings.moviesFolder,
                                 missingDetail: "Kein Ordner gewählt — Filme werden dort "
                                     + "umbenannt, wo sie liegen.",
                                 missingState: .warning, fileManager: fileManager))
            checks.append(folder(id: "series", name: "Serien", path: settings.seriesFolder,
                                 missingDetail: "Kein Ordner gewählt — Serien werden dort "
                                     + "umbenannt, wo sie liegen.",
                                 missingState: .warning, fileManager: fileManager))
        }

        checks.append(SystemCheck(
            id: "ffmpeg", name: "FFmpeg",
            state: ffmpegAvailable ? .ok : .warning,
            detail: ffmpegAvailable
                ? "Gefunden — Konvertieren ist möglich."
                : "Nicht gefunden. Nur zum Konvertieren nötig: sudo apt install ffmpeg"))

        checks.append(identification(settings: settings, secrets: secrets, probes: probes))
        checks.append(jellyfin(settings: settings, secrets: secrets, probes: probes))
        checks.append(contentsOf: remote(settings: settings, tools: tools,
                                         secrets: secrets, probes: probes))
        return checks
    }

    /// The worst lamp on the panel, for a single badge in a header bar.
    public static func worst(_ checks: [SystemCheck]) -> SystemCheck.State {
        if checks.contains(where: { $0.state == .failed }) { return .failed }
        if checks.contains(where: { $0.state == .warning }) { return .warning }
        if checks.contains(where: { $0.state == .ok }) { return .ok }
        return .off
    }

    /// A one-line summary: "4 bereit · 1 prüfen · 1 Problem".
    public static func summary(_ checks: [SystemCheck]) -> String {
        let counted: [(SystemCheck.State, Int)] = [.ok, .warning, .failed, .off]
            .map { state in (state, checks.filter { $0.state == state }.count) }
        return counted.filter { $0.1 > 0 }
            .map { "\($0.1) \($0.0.word)" }
            .joined(separator: " · ")
    }

    // MARK: The individual lamps

    private static func folder(id: String, name: String, path: String,
                               missingDetail: String,
                               missingState: SystemCheck.State = .failed,
                               fileManager: FileManager) -> SystemCheck {
        guard !path.isEmpty else {
            return SystemCheck(id: id, name: name, state: missingState,
                               detail: missingDetail)
        }
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            // Set but not there is always red, whatever the field: this is
            // the unmounted-drive case, and it is the one where carrying on
            // silently does real damage.
            return SystemCheck(id: id, name: name, state: .failed,
                               detail: exists
                                   ? "\(path) ist kein Ordner."
                                   : "\(path) gibt es nicht — Laufwerk nicht eingebunden?")
        }
        guard fileManager.isWritableFile(atPath: path) else {
            return SystemCheck(id: id, name: name, state: .failed,
                               detail: "\(path) ist nicht beschreibbar.")
        }
        return SystemCheck(id: id, name: name, state: .ok, detail: path)
    }

    private static func identification(settings: WebSettings, secrets: Set<SecretKey>,
                                       probes: [ProbeSubject: ProbeResult]) -> SystemCheck {
        switch settings.identification {
        case .offline:
            return SystemCheck(id: "identification", name: "Erkennung", state: .ok,
                               detail: "Nur Dateinamen — nichts verlässt diesen Rechner.")
        case .tmdb:
            let hasKey = secrets.contains(.tmdbAPIKey)
            return SystemCheck(id: "identification", name: "TMDb",
                               state: hasKey ? .ok : .failed,
                               detail: hasKey
                                   ? "API-Key hinterlegt."
                                   : "Kein API-Key hinterlegt — die Erkennung fällt auf "
                                       + "Dateinamen zurück.")
        case .localLLM:
            guard !settings.localLLMBaseURL.isEmpty, !settings.localLLMModel.isEmpty else {
                return SystemCheck(id: "identification", name: "Modellserver", state: .failed,
                                   detail: "Adresse oder Modellname fehlt.")
            }
            return probed(id: "identification", name: "Modellserver",
                          probe: probes[.localLLM],
                          untested: "Eingerichtet, aber noch nicht geprüft.")
        }
    }

    private static func jellyfin(settings: WebSettings, secrets: Set<SecretKey>,
                                 probes: [ProbeSubject: ProbeResult]) -> SystemCheck {
        guard !settings.jellyfinBaseURL.isEmpty else {
            return SystemCheck(id: "jellyfin", name: "Jellyfin", state: .off,
                               detail: "Nicht eingerichtet.")
        }
        guard secrets.contains(.jellyfinToken) else {
            return SystemCheck(id: "jellyfin", name: "Jellyfin", state: .warning,
                               detail: "Adresse steht, aber kein API-Key hinterlegt.")
        }
        return probed(id: "jellyfin", name: "Jellyfin", probe: probes[.jellyfin],
                      untested: "Eingerichtet, aber noch nicht geprüft.")
    }

    private static func remote(settings: WebSettings, tools: RemoteTools,
                               secrets: Set<SecretKey>,
                               probes: [ProbeSubject: ProbeResult]) -> [SystemCheck] {
        let target = settings.remote
        guard target.isEnabled else {
            return [SystemCheck(id: "remote", name: "Server", state: .off,
                                detail: "Nicht eingeschaltet.")]
        }

        var checks: [SystemCheck] = []
        let missing = tools.missing(for: target)
        checks.append(SystemCheck(
            id: "remote-tools", name: "Übertragungsprogramme",
            state: missing.isEmpty ? .ok : .failed,
            detail: missing.isEmpty
                ? "\(target.transport.rawValue) und OpenSSH sind da."
                : "Fehlt: \(missing.joined(separator: ", ")). "
                    + "sudo apt install \(missing.joined(separator: " "))"))

        let problems = target.problems()
        if !problems.isEmpty {
            checks.append(SystemCheck(
                id: "remote", name: "Server", state: .failed,
                detail: problems.map(\.message).joined(separator: " ")))
            return checks
        }
        if target.authentication == .password, !secrets.contains(.remotePassword) {
            checks.append(SystemCheck(id: "remote", name: "Server", state: .failed,
                                      detail: "Anmeldung per Passwort gewählt, aber keines "
                                          + "hinterlegt."))
            return checks
        }
        checks.append(probed(id: "remote", name: "Server", probe: probes[.remote],
                             untested: "Eingerichtet, aber noch nicht geprüft."))
        return checks
    }

    /// A lamp whose colour comes from an actual connection attempt.
    ///
    /// Amber, not green, when nothing has been tried: a configuration that
    /// merely looks complete is exactly the state this panel exists to tell
    /// apart from one that works.
    private static func probed(id: String, name: String, probe: ProbeResult?,
                               untested: String) -> SystemCheck {
        guard let probe else {
            return SystemCheck(id: id, name: name, state: .warning, detail: untested)
        }
        return SystemCheck(id: id, name: name, state: probe.ok ? .ok : .failed,
                           detail: probe.detail)
    }
}
