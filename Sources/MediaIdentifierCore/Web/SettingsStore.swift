import Foundation
// For rename(2). Foundation does not re-export the C library on every
// platform, so it is imported explicitly.
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Reads and writes the settings file.
///
/// A missing or damaged file never stops the app: the defaults are used and
/// the damage is reported, so a bad write cannot lock the user out of the
/// interface that would let them fix it. The file itself is not overwritten in
/// that case, so it can still be inspected.
public struct SettingsStore: Sendable {
    public let fileURL: URL

    public init(directory: URL, fileName: String = "settings.json") {
        self.fileURL = directory.appendingPathComponent(fileName)
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notWritable(String)

        public var description: String {
            switch self {
            case .notWritable(let path): return "Could not write the settings to \(path)."
            }
        }
    }

    /// What `load` found.
    public enum State: Sendable, Equatable {
        case loaded
        /// No file yet — first start.
        case missing
        /// The file could not be read; the defaults are in use and the file is
        /// left untouched.
        case unreadable(String)
    }

    public func load() -> (settings: WebSettings, state: State) {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else {
            return (WebSettings(), .missing)
        }
        do {
            return (try JSONDecoder().decode(WebSettings.self, from: data), .loaded)
        } catch {
            return (WebSettings(), .unreadable(String(describing: error)))
        }
    }

    public func save(_ settings: WebSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings.normalised())
        try AtomicFile.write(data, to: fileURL, permissions: 0o600)
    }
}

/// Stores the credentials the web interface needs, apart from the settings.
///
/// On macOS the app keeps secrets in the Keychain; a Linux service has no
/// equivalent, so they live in a file only the owner can read. Keeping them
/// out of `settings.json` means that file can be copied, diffed or pasted into
/// a bug report without leaking a key.
public struct SecretStore: Sendable {
    public let fileURL: URL

    public init(directory: URL, fileName: String = "secrets.json") {
        self.fileURL = directory.appendingPathComponent(fileName)
    }

    /// The value, or nil when not set.
    public func value(for key: SecretKey) -> String? {
        let value = load()[key.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// Stores `value`, or removes the secret when it is empty.
    public func set(_ value: String, for key: SecretKey) throws {
        var secrets = load()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            secrets.removeValue(forKey: key.rawValue)
        } else {
            secrets[key.rawValue] = trimmed
        }
        let data = try JSONEncoder().encode(secrets)
        try AtomicFile.write(data, to: fileURL, permissions: 0o600)
    }

    /// Which secrets are set. This is all the interface is ever told, so a
    /// page can show "stored" without the value passing through it.
    public func configuredKeys() -> Set<SecretKey> {
        let secrets = load()
        return Set(SecretKey.allCases.filter { key in
            guard let value = secrets[key.rawValue] else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
    }

    /// True when the file's permissions let other accounts read it.
    public var isReadableByOthers: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let permissions = attributes[.posixPermissions] as? NSNumber
        else { return false }
        return permissions.int16Value & 0o077 != 0
    }

    /// Tightens the file if it is readable by others. Returns true if it had
    /// to act, so the caller can tell the user their keys may have been seen.
    @discardableResult
    public func tightenPermissionsIfNeeded() -> Bool {
        guard isReadableByOthers else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: fileURL.path)
        return true
    }

    /// Errors are swallowed deliberately: a damaged secrets file must not stop
    /// the app, and its contents must never end up in a message.
    private func load() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let secrets = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return secrets
    }
}

/// Writes a file without a window in which it is missing or world-readable.
enum AtomicFile {
    /// Writes `data` to `url`, replacing whatever is there in one step.
    ///
    /// The replacement is `rename(2)` rather than `FileManager.moveItem`.
    /// `moveItem` refuses to overwrite, and the obvious workaround — delete the
    /// destination first, then move — is what this function used to do. That
    /// leaves a window in which neither file exists, and if the move then fails
    /// (read-only directory, no space, the destination turning out to be a
    /// directory) the old contents are gone for good. For `secrets.json` that
    /// means every stored API key. `rename` replaces an existing file
    /// atomically, so a reader sees either the old file or the new one and
    /// never nothing, and a failure leaves the original exactly as it was.
    static func write(_ data: Data, to url: URL, permissions: Int) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])

        // Create with the permissions already applied, so the contents are
        // never briefly readable by anyone else. In the same directory, because
        // rename is only atomic within one filesystem.
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp")
        if fileManager.fileExists(atPath: temporary.path) {
            try? fileManager.removeItem(at: temporary)
        }
        guard fileManager.createFile(atPath: temporary.path, contents: data,
                                     attributes: [.posixPermissions: permissions])
        else {
            throw SettingsStore.Failure.notWritable(url.path)
        }

        guard rename(temporary.path, url.path) == 0 else {
            // The original is untouched; only the half-written replacement goes.
            try? fileManager.removeItem(at: temporary)
            throw SettingsStore.Failure.notWritable(url.path)
        }
    }
}
