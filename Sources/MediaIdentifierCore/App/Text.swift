import Foundation

/// Which language the interface speaks.
public enum Language: String, Codable, Sendable, CaseIterable {
    case german = "de"
    case english = "en"

    /// In the language itself, which is how a language picker should read:
    /// somebody who has landed in the wrong one cannot read the other one's
    /// name for it.
    public var label: String {
        switch self {
        case .german: return "Deutsch"
        case .english: return "English"
        }
    }

    /// The language the environment asks for, or nil when it names one this
    /// program does not speak.
    ///
    /// `LC_ALL` beats `LC_MESSAGES` beats `LANG`, which is the order the C
    /// library itself uses. Only the first two letters are read: "de_AT",
    /// "de_DE.UTF-8" and "de" are all German, and Austrian German is not a
    /// separate translation anyone here is going to write.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Language? {
        for key in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            guard let value = environment[key], !value.isEmpty else { continue }
            // "C" and "POSIX" are not a request for English, they are a
            // request for no localisation at all — but English is the
            // closest this program has to that.
            let code = value.prefix(while: { $0 != "_" && $0 != "." && $0 != "@" })
                .lowercased()
            if code == "c" || code == "posix" { return .english }
            if let match = Language(rawValue: String(code.prefix(2))) { return match }
            // A language it does not speak: say so by returning nil rather
            // than silently picking one, so the caller's own default wins.
            return nil
        }
        return nil
    }
}

/// The interface's words, in both languages, at the place they are used.
///
/// Deliberately not a catalogue of keys in a separate file. With two
/// languages and one developer, a key-based catalogue buys nothing and costs
/// the failure mode it is famous for: a key that is looked up and not there,
/// which shows the user the key. Writing both strings at the call site makes
/// a missing translation impossible to express — the compiler will not let
/// you leave one out — and puts the two versions where they can be compared,
/// which is where they drift apart if they are anywhere else.
///
/// The cost is that every string is in the binary twice. For an interface
/// this size that is a few kilobytes.
public enum Text {
    private static let lock = NSLock()
    private static var _language: Language = .german

    /// Read on every string the interface draws, from more than one thread:
    /// the GTK window paints on the main thread while the web server answers
    /// on its own.
    public static var language: Language {
        get { lock.lock(); defer { lock.unlock() }; return _language }
        set { lock.lock(); _language = newValue; lock.unlock() }
    }

    /// One phrase, in both languages.
    public static func s(_ de: String, _ en: String) -> String {
        language == .german ? de : en
    }

    /// Starts the interface in the language the settings ask for, or, when
    /// they ask for nothing, the one the environment does.
    ///
    /// The setting wins over the environment on purpose: somebody who has
    /// chosen a language in the program has chosen it for the program, and a
    /// media server is quite often run under a different locale than its
    /// owner reads.
    public static func start(configured: Language?,
                             environment: [String: String]
                                 = ProcessInfo.processInfo.environment) {
        language = configured ?? Language.fromEnvironment(environment) ?? .german
    }
}
