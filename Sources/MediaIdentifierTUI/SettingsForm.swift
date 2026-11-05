import Foundation
import MediaIdentifierCore

/// The settings, as a list of fields.
///
/// Two pure functions and no state: `fields` describes the settings and
/// `applying` changes them. Keeping those apart is what makes the form
/// testable — a test can ask what the screen would show, or what a key
/// press would do to the settings, without a terminal and without saving
/// anything.
public enum SettingsForm {

    public struct Field: Equatable {
        public enum Kind: Equatable {
            /// Typed in. The placeholder is shown when the value is empty.
            case text(placeholder: String)
            /// Typed in, never shown back. The value says whether one is
            /// stored, never what it is.
            case secret
            case toggle
            /// Stepped through with left/right, so there is no menu to open
            /// and close inside a form.
            case choice([String])
            /// Not a field: a heading in the list.
            case section
        }

        public let id: String
        public let label: String
        public let kind: Kind
        /// What the field currently says, already read from the settings.
        public let value: String
        public let hint: String?
        /// Set when the validator complains about this field.
        public var problem: String?

        public var isEditable: Bool { kind != .section }

        public init(id: String, label: String, kind: Kind, value: String,
                    hint: String? = nil, problem: String? = nil) {
            self.id = id
            self.label = label
            self.kind = kind
            self.value = value
            self.hint = hint
            self.problem = problem
        }
    }

    static let on = "[x]"
    static let off = "[ ]"

    static func flag(_ value: Bool) -> String { value ? on : off }

    // MARK: Describing

    public static func fields(for settings: WebSettings,
                              secrets: Set<SecretKey>) -> [Field] {
        let problems = settings.problems()
        func problem(_ field: String) -> String? {
            problems.first { $0.field == field }?.message
        }
        func stored(_ key: SecretKey) -> String {
            secrets.contains(key)
                ? Text.s("gespeichert", "stored")
                : Text.s("nicht gesetzt", "not set")
        }

        var out: [Field] = []
        func section(_ title: String) {
            out.append(Field(id: "section-\(out.count)", label: title,
                             kind: .section, value: ""))
        }

        section(Text.s("Allgemein", "General"))
        out.append(Field(
            id: "language", label: Text.s("Sprache", "Language"),
            kind: .choice([Text.s("Wie das System", "Follow the system")]
                + Language.allCases.map(\.label)),
            value: settings.language?.label
                ?? Text.s("Wie das System", "Follow the system")))
        out.append(Field(
            id: "libraryMode", label: Text.s("Sortierung", "Sorting"),
            kind: .choice(LibraryMode.allCases.map(\.label)),
            value: settings.libraryMode.label))

        section(Text.s("Ordner", "Folders"))
        out.append(Field(
            id: "sourceFolder", label: Text.s("Import", "Import"),
            kind: .text(placeholder: "/home/you/Downloads"),
            value: settings.sourceFolder,
            hint: Text.s("Wo neue Dateien landen. Absoluter Pfad.",
                         "Where new files land. Absolute path."),
            problem: problem("sourceFolder")))
        out.append(Field(
            id: "moviesFolder", label: Text.s("Filme", "Films"),
            kind: .text(placeholder: "/srv/media/Filme"),
            value: settings.moviesFolder, problem: problem("moviesFolder")))
        out.append(Field(
            id: "seriesFolder", label: Text.s("Serien", "Series"),
            kind: .text(placeholder: "/srv/media/Serien"),
            value: settings.seriesFolder, problem: problem("seriesFolder")))
        out.append(Field(
            id: "musicFolder", label: Text.s("Musik", "Music"),
            kind: .text(placeholder: "/srv/media/Musik"),
            value: settings.musicFolder, problem: problem("musicFolder")))
        out.append(Field(
            id: "conflictPolicy",
            label: Text.s("Bei Namensgleichheit", "If a name clashes"),
            kind: .choice(WebSettings.ConflictPolicyChoice.allCases.map(\.label)),
            value: settings.conflictPolicy.label))
        out.append(Field(
            id: "watchSourceFolder", label: Text.s("Beobachten", "Watch"),
            kind: .toggle, value: flag(settings.watchSourceFolder),
            hint: Text.s("Importordner beobachten und neue Dateien vorschlagen.",
                         "Watch the import folder and offer new files.")))

        section(Text.s("Erkennung", "Identification"))
        out.append(Field(
            id: "identification", label: Text.s("Verfahren", "Method"),
            kind: .choice(IdentificationMode.allCases.map(\.label)),
            value: settings.identification.label))
        out.append(Field(
            id: "localLLMBaseURL", label: Text.s("Modellserver", "Model server"),
            kind: .text(placeholder: "http://192.168.1.2:1234"),
            value: settings.localLLMBaseURL, problem: problem("localLLMBaseURL")))
        out.append(Field(
            id: "localLLMModel", label: Text.s("Modell", "Model"),
            kind: .text(placeholder: "qwen/qwen3-8b"),
            value: settings.localLLMModel, problem: problem("localLLMModel")))
        out.append(Field(
            id: Self.secretField(.localLLMAPIKey), label: Text.s("API-Key", "API key"),
            kind: .secret, value: stored(.localLLMAPIKey)))
        out.append(Field(
            id: "jellyfinBaseURL", label: "Jellyfin",
            kind: .text(placeholder: "http://192.168.1.2:8096"),
            value: settings.jellyfinBaseURL, problem: problem("jellyfinBaseURL")))
        out.append(Field(
            id: Self.secretField(.jellyfinToken), label: Text.s("Jellyfin-Key", "Jellyfin key"),
            kind: .secret, value: stored(.jellyfinToken)))
        out.append(Field(
            id: Self.secretField(.tmdbAPIKey), label: Text.s("TMDb-Key", "TMDb key"),
            kind: .secret, value: stored(.tmdbAPIKey)))

        section(Text.s("Von selbst nachsehen", "Looking by itself"))
        out.append(Field(
            id: "scheduleEnabled", label: Text.s("Eingeschaltet", "Switched on"),
            kind: .toggle, value: flag(settings.schedule.isEnabled),
            hint: settings.schedule.summary))
        out.append(Field(
            id: "scheduleCadence", label: Text.s("Wie oft", "How often"),
            kind: .choice(Schedule.Cadence.allCases.map(\.label)),
            value: settings.schedule.cadence.label))
        out.append(Field(
            id: "scheduleTime", label: Text.s("Uhrzeit", "Time"),
            kind: .text(placeholder: "03:00"),
            value: String(format: "%02d:%02d", settings.schedule.hour,
                          settings.schedule.minute),
            problem: problem("scheduleTime")))
        out.append(Field(
            id: "scheduleEveryHours", label: Text.s("Abstand (h)", "Interval (h)"),
            kind: .text(placeholder: "6"),
            value: String(settings.schedule.everyHours),
            problem: problem("scheduleEveryHours")))
        out.append(Field(
            id: "scheduleRename", label: Text.s("Auch umbenennen", "Also rename"),
            kind: .toggle, value: flag(settings.schedule.alsoRename)))
        out.append(Field(
            id: "scheduleSend", label: Text.s("Auch senden", "Also send"),
            kind: .toggle, value: flag(settings.schedule.alsoSend)))

        section(Text.s("Server", "Server"))
        out.append(Field(
            id: "remoteEnabled", label: Text.s("Eingeschaltet", "Switched on"),
            kind: .toggle, value: flag(settings.remote.isEnabled)))
        out.append(Field(
            id: "remoteHost", label: Text.s("Adresse", "Address"),
            kind: .text(placeholder: "nas.fritz.box"),
            value: settings.remote.host, problem: problem("remoteHost")))
        out.append(Field(
            id: "remotePort", label: "Port", kind: .text(placeholder: "22"),
            value: String(settings.remote.port), problem: problem("remotePort")))
        out.append(Field(
            id: "remoteUser", label: Text.s("Benutzer", "User"),
            kind: .text(placeholder: "media"),
            value: settings.remote.user, problem: problem("remoteUser")))
        out.append(Field(
            id: "remoteBasePath", label: Text.s("Zielpfad", "Target path"),
            kind: .text(placeholder: "/volume1/Medien"),
            value: settings.remote.basePath,
            hint: Text.s("Gilt für alles, wofür unten kein eigener Pfad steht.",
                         "Used for anything that has no path of its own below."),
            problem: problem("remoteBasePath")))
        // One path per kind, because a server rarely has all three under one
        // parent — two disks and three libraries is the normal case, and the
        // single path above could not say it.
        out.append(Field(
            id: "remoteMoviesPath", label: Text.s("· Filme", "· Films"),
            kind: .text(placeholder: Text.s("leer = Zielpfad", "empty = target path")),
            value: settings.remote.moviesPath,
            hint: Text.s("Wohin Filme auf dem Server gehen.",
                         "Where films go on the server."),
            problem: problem("remoteMoviesPath")))
        out.append(Field(
            id: "remoteSeriesPath", label: Text.s("· Serien", "· Series"),
            kind: .text(placeholder: Text.s("leer = Zielpfad", "empty = target path")),
            value: settings.remote.seriesPath,
            hint: Text.s("Wohin Serien auf dem Server gehen.",
                         "Where series go on the server."),
            problem: problem("remoteSeriesPath")))
        out.append(Field(
            id: "remoteMusicPath", label: Text.s("· Musik", "· Music"),
            kind: .text(placeholder: Text.s("leer = Zielpfad", "empty = target path")),
            value: settings.remote.musicPath,
            hint: Text.s("Wohin Musik auf dem Server geht.",
                         "Where music goes on the server."),
            problem: problem("remoteMusicPath")))
        out.append(Field(
            id: "remoteTransport", label: Text.s("Übertragung", "Transfer"),
            kind: .choice(RemoteTarget.Transport.allCases.map(\.label)),
            value: settings.remote.transport.label))
        out.append(Field(
            id: "remoteAuthentication", label: Text.s("Anmeldung", "Login"),
            kind: .choice(RemoteTarget.Authentication.allCases.map(\.label)),
            value: settings.remote.authentication.label,
            // Spelled out, because the wrong setting here fails silently:
            // with „Schlüssel“ ssh may not ask for anything, so a stored
            // password is never offered and the login simply says no.
            hint: Text.s("Mit ←→ umstellen. Bei „Schlüssel“ wird ein gespeichertes "
                             + "Passwort nicht benutzt.",
                         "Change with ←→. With “key” a stored password is not used.")))
        out.append(Field(
            id: "remoteIdentityFile", label: Text.s("Schlüssel", "Key file"),
            kind: .text(placeholder: "~/.ssh/id_ed25519"),
            value: settings.remote.identityFile,
            hint: Text.s("Nur bei Anmeldung per Schlüssel. Leer = die ssh-Einrichtung "
                             + "des Rechners.",
                         "Only for key login. Empty = whatever this machine's ssh "
                             + "setup already does.")))
        out.append(Field(
            id: Self.secretField(.remotePassword), label: Text.s("Passwort", "Password"),
            kind: .secret, value: stored(.remotePassword),
            hint: Text.s("Nur bei Anmeldung per Passwort.",
                         "Only for password login.")))
        out.append(Field(
            id: "remoteTrustOnFirstUse",
            label: Text.s("Erstmals vertrauen", "Trust first time"),
            kind: .toggle, value: flag(settings.remote.trustOnFirstUse),
            hint: Text.s("Den Schlüssel des Servers beim ersten Mal übernehmen. Ein "
                             + "geänderter Schlüssel wird weiterhin abgelehnt.",
                         "Accept the server's key the first time it is seen. A key that "
                             + "has changed is still refused.")))
        out.append(Field(
            id: "remoteRemoveLocal",
            label: Text.s("Lokal löschen", "Delete locally"),
            kind: .toggle, value: flag(settings.remote.removeLocalAfterSend),
            hint: Text.s("Nach erfolgreicher Übertragung. Standardmäßig aus.",
                         "After a successful transfer. Off by default.")))
        return out
    }

    // MARK: Changing

    /// Typed text committed to a field.
    public static func applying(_ text: String, to field: String,
                                in settings: WebSettings) -> WebSettings {
        var out = settings
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch field {
        case "sourceFolder": out.sourceFolder = trimmed
        case "moviesFolder": out.moviesFolder = trimmed
        case "seriesFolder": out.seriesFolder = trimmed
        case "musicFolder": out.musicFolder = trimmed
        case "localLLMBaseURL": out.localLLMBaseURL = trimmed
        case "localLLMModel": out.localLLMModel = trimmed
        case "jellyfinBaseURL": out.jellyfinBaseURL = trimmed
        case "remoteHost": out.remote.host = trimmed
        case "remoteUser": out.remote.user = trimmed
        case "remoteBasePath": out.remote.basePath = trimmed
        case "remoteMoviesPath": out.remote.moviesPath = trimmed
        case "remoteSeriesPath": out.remote.seriesPath = trimmed
        case "remoteMusicPath": out.remote.musicPath = trimmed
        case "remoteIdentityFile": out.remote.identityFile = trimmed
        case "remotePort":
            // Kept impossible rather than clamped when it is not a number:
            // the validator then says so, instead of the program silently
            // listening on a port nobody asked for.
            out.remote.port = Int(trimmed) ?? -1
        case "scheduleEveryHours":
            out.schedule.everyHours = Int(trimmed) ?? -1
        case "scheduleTime":
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            if parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) {
                out.schedule.hour = hour
                out.schedule.minute = minute
            } else if !trimmed.isEmpty {
                // Same rule as the web form: an unparseable time is kept
                // impossible so the validator can complain about it, rather
                // than quietly becoming midnight.
                out.schedule.hour = -1
            }
        default: break
        }
        return out
    }

    /// A toggle flipped.
    public static func toggling(_ field: String, in settings: WebSettings) -> WebSettings {
        var out = settings
        switch field {
        case "watchSourceFolder": out.watchSourceFolder.toggle()
        case "scheduleEnabled": out.schedule.isEnabled.toggle()
        case "scheduleRename": out.schedule.alsoRename.toggle()
        case "scheduleSend": out.schedule.alsoSend.toggle()
        case "remoteEnabled": out.remote.isEnabled.toggle()
        case "remoteTrustOnFirstUse": out.remote.trustOnFirstUse.toggle()
        case "remoteRemoveLocal": out.remote.removeLocalAfterSend.toggle()
        default: break
        }
        return out
    }

    /// A choice stepped by `delta`, wrapping at both ends.
    public static func cycling(_ field: String, by delta: Int,
                               in settings: WebSettings) -> WebSettings {
        var out = settings
        func step<T>(_ all: [T], _ current: Int) -> T {
            let count = all.count
            // Swift's % keeps the sign of the left operand, so stepping
            // backwards from the first entry would index with -1.
            return all[((current + delta) % count + count) % count]
        }
        switch field {
        case "language":
            // The list is "follow the system" and then the languages, so it
            // is one longer than Language.allCases.
            let all: [Language?] = [nil] + Language.allCases
            let current = all.firstIndex(of: settings.language) ?? 0
            out.language = step(all, current)
        case "libraryMode":
            out.libraryMode = step(LibraryMode.allCases,
                                   LibraryMode.allCases.firstIndex(of: settings.libraryMode) ?? 0)
        case "conflictPolicy":
            out.conflictPolicy = step(
                WebSettings.ConflictPolicyChoice.allCases,
                WebSettings.ConflictPolicyChoice.allCases
                    .firstIndex(of: settings.conflictPolicy) ?? 0)
        case "identification":
            out.identification = step(
                IdentificationMode.allCases,
                IdentificationMode.allCases.firstIndex(of: settings.identification) ?? 0)
        case "scheduleCadence":
            out.schedule.cadence = step(
                Schedule.Cadence.allCases,
                Schedule.Cadence.allCases.firstIndex(of: settings.schedule.cadence) ?? 0)
        case "remoteTransport":
            out.remote.transport = step(
                RemoteTarget.Transport.allCases,
                RemoteTarget.Transport.allCases
                    .firstIndex(of: settings.remote.transport) ?? 0)
        case "remoteAuthentication":
            out.remote.authentication = step(
                RemoteTarget.Authentication.allCases,
                RemoteTarget.Authentication.allCases
                    .firstIndex(of: settings.remote.authentication) ?? 0)
        default: break
        }
        return out
    }

    /// Which connection a field belongs to, so the cursor's position can
    /// say what [t] would test.
    ///
    /// Testing lives here rather than on a screen of its own because the
    /// moment you want it is the moment you have just typed the address —
    /// and because without it the traffic light stays amber for ever:
    /// "set up, but not checked yet" only goes away when something checks.
    public static func test(for field: String) -> WebCommand? {
        if field.hasPrefix("localLLM") || field == secretField(.localLLMAPIKey) {
            return .testLocalLLMConnection
        }
        if field.hasPrefix("jellyfin") || field == secretField(.jellyfinToken) {
            return .testJellyfinConnection
        }
        if field.hasPrefix("remote") || field == secretField(.remotePassword) {
            return .testRemoteConnection
        }
        return nil
    }

    /// What [t] would test, named, for the menu row.
    public static func testName(for field: String) -> String? {
        switch test(for: field) {
        case .testLocalLLMConnection: return Text.s("Modellserver", "model server")
        case .testJellyfinConnection: return "Jellyfin"
        case .testRemoteConnection: return Text.s("Server", "server")
        default: return nil
        }
    }

    /// The field id a secret is listed under. Built from the raw value and
    /// not from the case name, because the two differ here —
    /// `.localLLMAPIKey` is "local-llm-api-key" — and a mismatch would make
    /// the field unwritable in a way nothing would report.
    public static func secretField(_ key: SecretKey) -> String {
        "secret-" + key.rawValue
    }

    /// The secret a field id names, or nil when it names something else.
    public static func secret(for field: String) -> SecretKey? {
        guard field.hasPrefix("secret-") else { return nil }
        return SecretKey(rawValue: String(field.dropFirst("secret-".count)))
    }
}
