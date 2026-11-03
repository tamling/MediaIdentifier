import Foundation

/// Where Mediafin keeps its configuration, token and TLS material.
public enum MediafinPaths {
    /// Resolves the configuration directory.
    ///
    /// `MEDIAFIN_CONFIG_DIR` wins, then the platform convention: XDG on Linux,
    /// Application Support on macOS. Taking the environment as a parameter
    /// keeps this testable without touching the real one.
    public static func configDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let explicit = environment["MEDIAFIN_CONFIG_DIR"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory()
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        #if os(macOS)
        return homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Mediafin", isDirectory: true)
        #else
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeURL.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("mediafin", isDirectory: true)
        #endif
    }
}
