import Foundation

/// How titles are identified (FR3). Ordered from least to most that leaves the
/// machine.
public enum IdentificationMode: String, Codable, Sendable, CaseIterable {
    /// Parse the file name only. Nothing leaves the machine.
    case offline
    /// Ask a model the user runs themselves. Only the file name is sent, to
    /// their own server.
    case localLLM = "local-llm"
    /// Ask TMDb. Title and year are sent to a third party; no media ever is.
    case tmdb

    public var label: String {
        switch self {
        case .offline: return "File names only (nothing leaves this machine)"
        case .localLLM: return "My own local model"
        case .tmdb: return "TMDb (sends title and year to themoviedb.org)"
        }
    }
}

/// Whether the program is sorting video or music.
///
/// A switch rather than one pass that handles both, because the two
/// genuinely differ all the way down: what is enumerated, what is read
/// from a file, how items are grouped, which library root they go to, and
/// which columns the proposals list needs. A mixed list would be a table
/// with half its columns empty on every row, in both front-ends.
public enum LibraryMode: String, Codable, Sendable, CaseIterable {
    case video
    case music

    public var label: String {
        switch self {
        case .video: return "Filme und Serien"
        case .music: return "Musik"
        }
    }
}

/// The settings the web interface can change.
///
/// Secrets are deliberately absent: API keys and tokens live in `SecretStore`,
/// in a separate file only the owner can read, so this one can be backed up or
/// looked at without leaking credentials.
public struct WebSettings: Codable, Sendable, Equatable {
    public var sourceFolder: String
    public var moviesFolder: String
    public var seriesFolder: String
    /// Where music is filed. Only used in music mode.
    public var musicFolder: String
    /// Whether this is sorting video or music.
    public var libraryMode: LibraryMode
    public var identification: IdentificationMode
    /// Base URL of the user's own model server, e.g. `http://192.168.1.2:1234`.
    public var localLLMBaseURL: String
    public var localLLMModel: String
    /// Base URL of the Jellyfin server to refresh after renaming (FR20).
    public var jellyfinBaseURL: String
    /// Move files instead of only previewing.
    public var conflictPolicy: ConflictPolicyChoice
    public var watchSourceFolder: Bool
    /// Transcoding settings (FR16, FR17).
    public var conversion: WebConversionSettings
    /// Where the library lives when it is on another machine.
    public var remote: RemoteTarget
    /// When Mediafin looks by itself.
    public var schedule: Schedule

    public enum ConflictPolicyChoice: String, Codable, Sendable, CaseIterable {
        case skip, rename, replace

        public var label: String {
            switch self {
            case .skip: return "Skip the file"
            case .rename: return "Keep both, add a number"
            case .replace: return "Replace (the old file goes to the trash)"
            }
        }

        /// The engine's policy. `.ask` is not offered: a web page has nobody
        /// standing by to answer a prompt mid-run.
        public var policy: ConflictPolicy {
            switch self {
            case .skip: return .skip
            case .rename: return .rename
            case .replace: return .replace
            }
        }
    }

    public init(sourceFolder: String = "", moviesFolder: String = "",
                seriesFolder: String = "", musicFolder: String = "",
                libraryMode: LibraryMode = .video,
                identification: IdentificationMode = .offline,
                localLLMBaseURL: String = "", localLLMModel: String = "",
                jellyfinBaseURL: String = "",
                conflictPolicy: ConflictPolicyChoice = .skip,
                watchSourceFolder: Bool = false,
                conversion: WebConversionSettings = WebConversionSettings(),
                remote: RemoteTarget = RemoteTarget(),
                schedule: Schedule = Schedule()) {
        self.sourceFolder = sourceFolder
        self.moviesFolder = moviesFolder
        self.seriesFolder = seriesFolder
        self.musicFolder = musicFolder
        self.libraryMode = libraryMode
        self.identification = identification
        self.localLLMBaseURL = localLLMBaseURL
        self.localLLMModel = localLLMModel
        self.jellyfinBaseURL = jellyfinBaseURL
        self.conflictPolicy = conflictPolicy
        self.watchSourceFolder = watchSourceFolder
        self.conversion = conversion
        self.remote = remote
        self.schedule = schedule
    }

    // MARK: Decoding

    /// Every field is optional on the way in, so a settings file written by an
    /// older version still loads once a field is added. Without this, one
    /// unknown-shaped file would throw and silently reset *all* settings.
    enum CodingKeys: String, CodingKey {
        case sourceFolder, moviesFolder, seriesFolder, musicFolder, libraryMode
        case identification
        case localLLMBaseURL, localLLMModel, jellyfinBaseURL
        case conflictPolicy, watchSourceFolder, conversion, remote, schedule
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WebSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            // `try?` flattens the Optional that decodeIfPresent returns, so
            // this single coalesce covers both ways a damaged file fails: the
            // key is absent, or it holds the wrong type. Either way the
            // default stands and the rest of the file still loads.
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        sourceFolder = value(.sourceFolder, defaults.sourceFolder)
        moviesFolder = value(.moviesFolder, defaults.moviesFolder)
        seriesFolder = value(.seriesFolder, defaults.seriesFolder)
        musicFolder = value(.musicFolder, defaults.musicFolder)
        libraryMode = value(.libraryMode, defaults.libraryMode)
        identification = value(.identification, defaults.identification)
        localLLMBaseURL = value(.localLLMBaseURL, defaults.localLLMBaseURL)
        localLLMModel = value(.localLLMModel, defaults.localLLMModel)
        jellyfinBaseURL = value(.jellyfinBaseURL, defaults.jellyfinBaseURL)
        conflictPolicy = value(.conflictPolicy, defaults.conflictPolicy)
        watchSourceFolder = value(.watchSourceFolder, defaults.watchSourceFolder)
        conversion = value(.conversion, defaults.conversion)
        remote = value(.remote, defaults.remote)
        schedule = value(.schedule, defaults.schedule)
    }

    // MARK: Validation

    public struct Problem: Sendable, Equatable {
        /// Form field the problem belongs to, so the page can point at it.
        public let field: String
        public let message: String

        public init(field: String, message: String) {
            self.field = field
            self.message = message
        }
    }

    /// Checks the settings, returning everything that is wrong rather than
    /// only the first problem.
    public func problems() -> [Problem] {
        var found: [Problem] = []

        for (field, path, label) in [
            ("sourceFolder", sourceFolder, "The folder to import from"),
            ("moviesFolder", moviesFolder, "The movies folder"),
            ("seriesFolder", seriesFolder, "The series folder"),
            ("musicFolder", musicFolder, "The music folder"),
        ] where !path.isEmpty {
            if !path.hasPrefix("/") {
                found.append(Problem(field: field,
                                     message: "\(label) must be an absolute path."))
            } else if path.contains("..") {
                found.append(Problem(field: field,
                                     message: "\(label) must not contain '..'."))
            }
        }

        if identification == .localLLM {
            if let problem = Self.urlProblem(localLLMBaseURL, field: "localLLMBaseURL",
                                             label: "The model server address",
                                             required: true) {
                found.append(problem)
            }
            if localLLMModel.trimmingCharacters(in: .whitespaces).isEmpty {
                found.append(Problem(field: "localLLMModel",
                                     message: "Enter the model name your server reports."))
            }
        } else if let problem = Self.urlProblem(localLLMBaseURL, field: "localLLMBaseURL",
                                                label: "The model server address",
                                                required: false) {
            found.append(problem)
        }

        if let problem = Self.urlProblem(jellyfinBaseURL, field: "jellyfinBaseURL",
                                         label: "The Jellyfin address", required: false) {
            found.append(problem)
        }
        found.append(contentsOf: conversion.problems())
        found.append(contentsOf: remote.problems())
        found.append(contentsOf: schedule.problems())
        return found
    }

    public var isValid: Bool { problems().isEmpty }

    /// Only http and https are accepted: a `file:` or `javascript:` value in a
    /// field that later becomes a request or a link has no legitimate use.
    private static func urlProblem(_ value: String, field: String, label: String,
                                   required: Bool) -> Problem? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return required ? Problem(field: field, message: "\(label) is required.") : nil
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else {
            return Problem(field: field,
                           message: "\(label) must look like http://host:port.")
        }
        return nil
    }

    /// Settings with whitespace trimmed, as they should be stored.
    public func normalised() -> WebSettings {
        var copy = self
        copy.sourceFolder = Self.trim(sourceFolder)
        copy.moviesFolder = Self.trim(moviesFolder)
        copy.seriesFolder = Self.trim(seriesFolder)
        copy.localLLMBaseURL = Self.trim(localLLMBaseURL)
        copy.localLLMModel = Self.trim(localLLMModel)
        copy.jellyfinBaseURL = Self.trim(jellyfinBaseURL)
        return copy
    }

    private static func trim(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // A trailing slash on a base URL or folder is never meaningful here and
        // produces doubled separators later.
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    // MARK: Form decoding

    /// Builds settings from a submitted form, keeping `current` for fields the
    /// form did not include.
    public static func fromForm(_ fields: [String: String],
                                current: WebSettings) -> WebSettings {
        var settings = current
        if let value = fields["sourceFolder"] { settings.sourceFolder = value }
        if let value = fields["moviesFolder"] { settings.moviesFolder = value }
        if let value = fields["seriesFolder"] { settings.seriesFolder = value }
        if let value = fields["musicFolder"] { settings.musicFolder = value }
        if let value = fields["libraryMode"], let mode = LibraryMode(rawValue: value) {
            settings.libraryMode = mode
        }
        if let value = fields["localLLMBaseURL"] { settings.localLLMBaseURL = value }
        if let value = fields["localLLMModel"] { settings.localLLMModel = value }
        if let value = fields["jellyfinBaseURL"] { settings.jellyfinBaseURL = value }
        if let value = fields["identification"],
           let mode = IdentificationMode(rawValue: value) {
            settings.identification = mode
        }
        if let value = fields["conflictPolicy"],
           let policy = ConflictPolicyChoice(rawValue: value) {
            settings.conflictPolicy = policy
        }
        // An unchecked checkbox is simply absent from the submission, so the
        // form carries a hidden companion field to tell "unchecked" apart from
        // "not part of this form".
        if fields["watchSourceFolderPresent"] != nil {
            settings.watchSourceFolder = fields["watchSourceFolder"] != nil
        }
        settings.conversion = WebConversionSettings.fromForm(fields, current: current.conversion)
        settings.remote = RemoteTarget.fromForm(fields, current: current.remote)
        settings.schedule = Schedule.fromForm(fields, current: current.schedule)
        return settings.normalised()
    }
}

/// Credentials, kept apart from the settings file.
public enum SecretKey: String, Codable, Sendable, CaseIterable {
    case localLLMAPIKey = "local-llm-api-key"
    case jellyfinToken = "jellyfin-token"
    case tmdbAPIKey = "tmdb-api-key"
    case remotePassword = "remote-password"

    public var label: String {
        switch self {
        case .localLLMAPIKey: return "Model server API key"
        case .jellyfinToken: return "Jellyfin API key"
        case .tmdbAPIKey: return "TMDb API key"
        case .remotePassword: return "Server password"
        }
    }

    /// The form field it is submitted under.
    public var formField: String {
        switch self {
        case .localLLMAPIKey: return "localLLMAPIKey"
        case .jellyfinToken: return "jellyfinToken"
        case .tmdbAPIKey: return "tmdbAPIKey"
        case .remotePassword: return "remotePassword"
        }
    }
}
