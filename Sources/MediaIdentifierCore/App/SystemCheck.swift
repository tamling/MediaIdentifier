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
            case .ok: return Text.s("bereit", "ready")
            case .warning: return Text.s("prüfen", "check")
            case .failed: return Text.s("Problem", "problem")
            case .off: return Text.s("aus", "off")
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
        nextScheduledRun: Date? = nil,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> [SystemCheck] {
        var checks: [SystemCheck] = []

        checks.append(folder(id: "source",
                             name: Text.s("Importordner", "Import folder"),
                             path: settings.sourceFolder,
                             missingDetail: Text.s(
                                "Noch kein Ordner gewählt — ohne ihn gibt es nichts zu "
                                    + "durchsuchen.",
                                "No folder chosen yet — without one there is nothing to "
                                    + "look through."),
                             fileManager: fileManager))

        // With a server configured, the local library folders are not where
        // the library lives, so demanding them would be a red lamp for a
        // setup that is working exactly as the user set it up.
        // The local library folders are checked whether or not a server is
        // configured: "Umbenennen" still writes to them, so hiding the lamp
        // when the server is on took away the unmounted-drive warning from
        // the exact setup most likely to have a network mount.
        checks.append(folder(id: "movies", name: Text.s("Filme", "Films"),
                             path: settings.moviesFolder,
                             missingDetail: Text.s(
                                "Kein Ordner gewählt — Filme werden dort umbenannt, wo "
                                    + "sie liegen.",
                                "No folder chosen — films are renamed where they lie."),
                             missingState: .warning, fileManager: fileManager))
        checks.append(folder(id: "series", name: Text.s("Serien", "Series"),
                             path: settings.seriesFolder,
                             missingDetail: Text.s(
                                "Kein Ordner gewählt — Serien werden dort umbenannt, wo "
                                    + "sie liegen.",
                                "No folder chosen — series are renamed where they lie."),
                             missingState: .warning, fileManager: fileManager))

        checks.append(SystemCheck(
            id: "ffmpeg", name: "FFmpeg",
            state: ffmpegAvailable ? .ok : .warning,
            detail: ffmpegAvailable
                ? Text.s("Gefunden — Konvertieren ist möglich.",
                         "Found — converting is possible.")
                : Text.s("Nicht gefunden. Nur zum Konvertieren nötig: "
                             + "sudo apt install ffmpeg",
                         "Not found. Only needed for converting: "
                             + "sudo apt install ffmpeg")))

        checks.append(identification(settings: settings, secrets: secrets,
                                     probes: probes, now: now))
        checks.append(jellyfin(settings: settings, secrets: secrets,
                               probes: probes, now: now))
        checks.append(contentsOf: remote(settings: settings, tools: tools,
                                         secrets: secrets, probes: probes,
                                         fileManager: fileManager, now: now))
        checks.append(schedule(settings.schedule, nextRun: nextScheduledRun, now: now))
        return checks
    }

    /// Whether the unattended run is really going to happen.
    ///
    /// The lamp this panel most needed and did not have. A schedule is a
    /// promise about a time nobody is present for, so the only way to know
    /// it was kept is to be told beforehand that it will be — and the
    /// state worth a red lamp is the one that looks fine everywhere else:
    /// switched on in the settings, with nothing armed to run it.
    static func schedule(_ schedule: Schedule, nextRun: Date?,
                         now: Date = Date()) -> SystemCheck {
        let name = Text.s("Zeitplan", "Schedule")
        guard schedule.isEnabled else {
            return SystemCheck(id: "schedule", name: name, state: .off,
                               detail: Text.s("Aus — es läuft nichts von selbst.",
                                              "Off — nothing runs by itself."))
        }
        let problems = schedule.problems()
        if let first = problems.first {
            return SystemCheck(id: "schedule", name: name, state: .failed,
                               detail: first.message)
        }
        guard let nextRun else {
            return SystemCheck(id: "schedule", name: name, state: .failed,
                               detail: Text.s(
                                "Eingeschaltet, läuft aber nicht. ‚Speichern‘ in den "
                                    + "Einstellungen schaltet ihn wieder scharf.",
                                "Switched on but not running. ‘Save’ in the settings "
                                    + "arms it again."))
        }
        return SystemCheck(id: "schedule", name: name, state: .ok,
                           detail: schedule.summary
                               + Text.s(" Nächster Lauf: ", " Next run: ")
                               + Schedule.describe(nextRun, now: now) + ".")
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

    /// Used by three lamps, so it is written once.
    private static var untested: String {
        Text.s("Eingerichtet, aber noch nicht geprüft.",
               "Set up, but not checked yet.")
    }

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
                                   ? Text.s("\(path) ist kein Ordner.",
                                            "\(path) is not a folder.")
                                   : Text.s(
                                    "\(path) gibt es nicht — Laufwerk nicht eingebunden?",
                                    "\(path) does not exist — drive not mounted?"))
        }
        guard fileManager.isWritableFile(atPath: path) else {
            return SystemCheck(id: id, name: name, state: .failed,
                               detail: Text.s("\(path) ist nicht beschreibbar.",
                                              "\(path) is not writable."))
        }
        return SystemCheck(id: id, name: name, state: .ok, detail: path)
    }

    private static func identification(settings: WebSettings, secrets: Set<SecretKey>,
                                       probes: [ProbeSubject: ProbeResult],
                                       now: Date) -> SystemCheck {
        switch settings.identification {
        case .offline:
            return SystemCheck(id: "identification",
                               name: Text.s("Erkennung", "Identification"), state: .ok,
                               detail: Text.s(
                                "Nur Dateinamen — nichts verlässt diesen Rechner.",
                                "File names only — nothing leaves this machine."))
        case .tmdb:
            let hasKey = secrets.contains(.tmdbAPIKey)
            return SystemCheck(id: "identification", name: "TMDb",
                               state: hasKey ? .ok : .failed,
                               detail: hasKey
                                   ? Text.s("API-Key hinterlegt.", "API key stored.")
                                   : Text.s(
                                    "Kein API-Key hinterlegt — die Erkennung fällt auf "
                                        + "Dateinamen zurück.",
                                    "No API key stored — identification falls back to "
                                        + "file names."))
        case .localLLM:
            guard !settings.localLLMBaseURL.isEmpty, !settings.localLLMModel.isEmpty else {
                return SystemCheck(id: "identification",
                                   name: Text.s("Modellserver", "Model server"),
                                   state: .failed,
                                   detail: Text.s("Adresse oder Modellname fehlt.",
                                                  "The address or the model name is missing."))
            }
            return probed(id: "identification", name: Text.s("Modellserver", "Model server"),
                          probe: probes[.localLLM],
                          untested: Self.untested, now: now)
        }
    }

    private static func jellyfin(settings: WebSettings, secrets: Set<SecretKey>,
                                 probes: [ProbeSubject: ProbeResult],
                                 now: Date) -> SystemCheck {
        guard !settings.jellyfinBaseURL.isEmpty else {
            return SystemCheck(id: "jellyfin", name: "Jellyfin", state: .off,
                               detail: Text.s("Nicht eingerichtet.", "Not set up."))
        }
        guard secrets.contains(.jellyfinToken) else {
            return SystemCheck(id: "jellyfin", name: "Jellyfin", state: .warning,
                               detail: Text.s("Adresse steht, aber kein API-Key hinterlegt.",
                                              "The address is set but no API key is stored."))
        }
        return probed(id: "jellyfin", name: "Jellyfin", probe: probes[.jellyfin],
                      untested: Self.untested, now: now)
    }

    private static func remote(settings: WebSettings, tools: RemoteTools,
                               secrets: Set<SecretKey>,
                               probes: [ProbeSubject: ProbeResult],
                               fileManager: FileManager = .default,
                               now: Date) -> [SystemCheck] {
        let target = settings.remote
        guard target.isEnabled else {
            return [SystemCheck(id: "remote", name: "Server", state: .off,
                                detail: Text.s("Nicht eingeschaltet.", "Not switched on."))]
        }

        var checks: [SystemCheck] = []
        let missing = tools.missing(for: target)
        checks.append(SystemCheck(
            id: "remote-tools",
            name: Text.s("Übertragungsprogramme", "Transfer programs"),
            state: missing.isEmpty ? .ok : .failed,
            detail: missing.isEmpty
                ? Text.s("\(target.transport.rawValue) und OpenSSH sind da.",
                         "\(target.transport.rawValue) and OpenSSH are present.")
                : Text.s("Fehlt: \(missing.joined(separator: ", ")). ",
                         "Missing: \(missing.joined(separator: ", ")). ")
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
                                      detail: Text.s(
                                        "Anmeldung per Passwort gewählt, aber keines "
                                            + "hinterlegt.",
                                        "Password login is selected but none is stored.")))
            return checks
        }
        if let lamp = login(target, secrets: secrets, fileManager: fileManager) {
            checks.append(lamp)
        }
        checks.append(probed(id: "remote", name: "Server", probe: probes[.remote],
                             untested: Self.untested, now: now))
        return checks
    }

    /// The login trap, made visible.
    ///
    /// Key login puts ssh in batch mode: it may not ask for anything. So a
    /// key file that is not there fails in a tenth of a second with
    /// "Permission denied", and a password sitting in the store is never
    /// offered — nothing anywhere said that it would not be. This is the
    /// lamp for exactly that, because it is what happened.
    static func login(_ target: RemoteTarget, secrets: Set<SecretKey>,
                      fileManager: FileManager) -> SystemCheck? {
        guard target.authentication == .key else { return nil }
        let name = Text.s("Anmeldung", "Login")
        let key = (target.identityFile as NSString).expandingTildeInPath

        if !target.identityFile.isEmpty, !fileManager.fileExists(atPath: key) {
            return SystemCheck(
                id: "remote-login", name: name, state: .failed,
                detail: Text.s(
                    "Die Schlüsseldatei \(target.identityFile) ist nicht da, und bei "
                        + "Anmeldung per Schlüssel darf ssh nicht nach einem Passwort "
                        + "fragen — die Anmeldung scheitert also sofort."
                        + (secrets.contains(.remotePassword)
                            ? " Ein Passwort ist hinterlegt: bei „Anmeldung“ mit ←→ auf "
                                + "„Passwort“ stellen, dann wird es benutzt."
                            : " Entweder den Pfad berichtigen, das Feld leeren, oder bei "
                                + "„Anmeldung“ auf „Passwort“ stellen."),
                    "The key file \(target.identityFile) is not there, and with key login "
                        + "ssh is not allowed to ask for a password — so the login fails "
                        + "at once."
                        + (secrets.contains(.remotePassword)
                            ? " A password is stored: set “Login” to “Password” with ←→ "
                                + "and it will be used."
                            : " Either correct the path, empty the field, or set “Login” "
                                + "to “Password”.")))
        }
        if secrets.contains(.remotePassword) {
            return SystemCheck(
                id: "remote-login", name: name, state: .warning,
                detail: Text.s(
                    "Ein Passwort ist hinterlegt, aber die Anmeldung steht auf Schlüssel "
                        + "— das Passwort wird nicht benutzt. Bei „Anmeldung“ mit ←→ auf "
                        + "„Passwort“ stellen, wenn es benutzt werden soll.",
                    "A password is stored but the login is set to key, so the password is "
                        + "not used. Set “Login” to “Password” with ←→ if it should be."))
        }
        return nil
    }

    /// A lamp whose colour comes from an actual connection attempt.
    ///
    /// Amber, not green, when nothing has been tried: a configuration that
    /// merely looks complete is exactly the state this panel exists to tell
    /// apart from one that works.
    private static func probed(id: String, name: String, probe: ProbeResult?,
                               untested: String, now: Date) -> SystemCheck {
        guard let probe else {
            return SystemCheck(id: id, name: name, state: .warning, detail: untested)
        }
        // The age, which is the whole reason the date is recorded. A green
        // lamp from this morning is not the same claim as one from a second
        // ago, and a panel that does not say which is a panel that can be
        // green about a server that was unplugged at lunchtime.
        let age = now.timeIntervalSince(probe.date)
        let when: String
        switch age {
        case ..<90: when = Text.s("gerade geprüft", "just checked")
        case ..<3600: when = Text.s("vor \(Int(age / 60)) Min geprüft",
                                    "checked \(Int(age / 60)) min ago")
        case ..<86400: when = Text.s("vor \(Int(age / 3600)) Std geprüft",
                                     "checked \(Int(age / 3600)) h ago")
        default: when = Text.s("vor über einem Tag geprüft",
                               "checked over a day ago")
        }
        // Stale and green is amber: it was true once, and nobody has
        // checked since.
        let state: SystemCheck.State = probe.ok ? (age > 3600 ? .warning : .ok) : .failed
        return SystemCheck(id: id, name: name, state: state,
                           detail: "\(probe.detail) (\(when))")
    }
}
