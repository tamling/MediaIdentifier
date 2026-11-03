import Foundation
import MediaIdentifierCore

/// Stores the web interface's access token in a file only its owner can read.
public struct TokenStore: Sendable {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notWritable(String)

        public var description: String {
            switch self {
            case .notWritable(let path): return "Cannot write the access token to \(path)."
            }
        }
    }

    /// What `loadOrCreate` did, so the caller can tell the user.
    public enum Outcome: Sendable, Equatable {
        case created
        case loaded
        /// Loaded, but the file was readable by other accounts and has been
        /// tightened to 0600.
        case loadedAndTightened
    }

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("token") }

    public init(directory: URL) {
        self.directory = directory
    }

    /// Returns the stored token, creating one on first use.
    public func loadOrCreate() throws -> (token: String, outcome: Outcome) {
        try prepareDirectory()
        let fileManager = FileManager.default

        if let data = fileManager.contents(atPath: fileURL.path) {
            let existing = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !existing.isEmpty {
                // Never silently replace a token the user may have noted down;
                // just make sure nobody else on the machine can read it.
                if isReadableByOthers {
                    try? fileManager.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: fileURL.path)
                    return (existing, .loadedAndTightened)
                }
                return (existing, .loaded)
            }
        }
        return (try write(WebSecurityPolicy.generateToken()), .created)
    }

    /// Replaces the token, invalidating every browser session.
    @discardableResult
    public func rotate() throws -> String {
        try prepareDirectory()
        return try write(WebSecurityPolicy.generateToken())
    }

    /// True when the token file's permissions let other accounts read it.
    public var isReadableByOthers: Bool {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: fileURL.path),
              let permissions = attributes[.posixPermissions] as? NSNumber
        else { return false }
        return permissions.int16Value & 0o077 != 0
    }

    private func prepareDirectory() throws {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw Failure.notWritable(directory.path)
        }
    }

    private func write(_ token: String) throws -> String {
        let fileManager = FileManager.default
        // Create rather than overwrite, so the 0600 mode is applied at
        // creation and the secret is never briefly world-readable.
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
        }
        guard fileManager.createFile(atPath: fileURL.path,
                                     contents: Data((token + "\n").utf8),
                                     attributes: [.posixPermissions: 0o600])
        else {
            throw Failure.notWritable(fileURL.path)
        }
        return token
    }
}

/// Command-line options for the `mediafin` binary.
public struct MediafinOptions: Sendable, Equatable {
    public var port: Int = 8720
    /// Bind to loopback only. The default, because the interface exposes the
    /// whole library.
    public var bindLocalOnly: Bool = true
    public var tlsEnabled: Bool = true
    public var certificatePath: String?
    public var privateKeyPath: String?
    public var configDirectory: String?
    public var rotateToken: Bool = false
    public var printTokenOnly: Bool = false
    public var allowPlainHTTPOnNetwork: Bool = false
    public var showHelp: Bool = false

    public init() {}

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case unknownOption(String)
        case missingValue(String)
        case invalidPort(String)
        case invalidBind(String)
        case certificateAndKeyGoTogether

        public var description: String {
            switch self {
            case .unknownOption(let name):
                return "Unknown option \(name). Try --help."
            case .missingValue(let name):
                return "\(name) needs a value."
            case .invalidPort(let value):
                return "\(value) is not a port between 0 and 65535."
            case .invalidBind(let value):
                return "--bind takes 'local' or 'all', not \(value)."
            case .certificateAndKeyGoTogether:
                return "--cert and --key must be given together."
            }
        }
    }

    /// Parses arguments, excluding the executable name.
    public static func parse(_ arguments: [String]) throws -> MediafinOptions {
        var options = MediafinOptions()
        var index = arguments.startIndex

        func nextValue(for name: String) throws -> String {
            index += 1
            guard index < arguments.endIndex else { throw Failure.missingValue(name) }
            return arguments[index]
        }

        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                options.showHelp = true
            case "--port", "-p":
                let raw = try nextValue(for: argument)
                guard let port = Int(raw), (0...65535).contains(port) else {
                    throw Failure.invalidPort(raw)
                }
                options.port = port
            case "--bind":
                let raw = try nextValue(for: argument).lowercased()
                switch raw {
                case "local", "localhost", "loopback": options.bindLocalOnly = true
                case "all", "any": options.bindLocalOnly = false
                default: throw Failure.invalidBind(raw)
                }
            case "--no-tls":
                options.tlsEnabled = false
            case "--cert":
                options.certificatePath = try nextValue(for: argument)
            case "--key":
                options.privateKeyPath = try nextValue(for: argument)
            case "--config-dir":
                options.configDirectory = try nextValue(for: argument)
            case "--rotate-token":
                options.rotateToken = true
            case "--print-token":
                options.printTokenOnly = true
            case "--i-accept-plain-http-on-the-network":
                options.allowPlainHTTPOnNetwork = true
            default:
                throw Failure.unknownOption(argument)
            }
            index += 1
        }

        let hasCertificate = options.certificatePath != nil
        let hasKey = options.privateKeyPath != nil
        guard hasCertificate == hasKey else { throw Failure.certificateAndKeyGoTogether }
        return options
    }

    /// The TLS source implied by the options, or nil for plain HTTP.
    /// `generated` is used when TLS is on but no files were supplied.
    public func tlsSource(generated: @autoclosure () throws -> WebTLSSource) throws -> WebTLSSource? {
        guard tlsEnabled else { return nil }
        if let certificatePath, let privateKeyPath {
            return .pemFiles(certificateChain: certificatePath, privateKey: privateKeyPath)
        }
        return try generated()
    }

    public static let helpText = """
    mediafin — Jellyfin-style media renaming with a local web interface

    Usage: mediafin [options]

    Options:
      -p, --port <number>      Port to listen on (default 8720).
          --bind local|all     Reachable from this machine only (default), or
                               from the network. A network bind requires TLS.
          --no-tls             Serve plain HTTP. Only allowed with --bind local
                               unless you also pass the flag below.
          --cert <file>        Use this PEM certificate chain instead of the
          --key  <file>        self-signed one, together with this PEM key.
          --config-dir <dir>   Where to keep the token and certificate.
          --rotate-token       Issue a new access token and exit.
          --print-token        Print the access token and exit.
      -h, --help               Show this help.

          --i-accept-plain-http-on-the-network
                               Serve unencrypted on the network anyway. Only do
                               this when something in front of Mediafin already
                               terminates TLS.

    On first start an access token and a self-signed certificate are created in
    the configuration directory. The browser will warn about the self-signed
    certificate; compare the fingerprint printed at startup, or pass your own
    certificate with --cert/--key.
    """
}
