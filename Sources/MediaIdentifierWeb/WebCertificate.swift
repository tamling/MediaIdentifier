import Foundation

/// Creates and locates the TLS material for the local web interface.
///
/// A self-signed certificate is generated on first use so HTTPS works without
/// any setup. A browser will warn about it — that is inherent to self-signing,
/// not a fault: the warning can be accepted once, or a real certificate
/// supplied instead via `WebTLSSource.pemFiles`.
public enum WebCertificate {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case opensslMissing
        case generationFailed(String)
        case directoryNotWritable(String)

        public var description: String {
            switch self {
            case .opensslMissing:
                return """
                No `openssl` command was found, so Mediafin cannot create a \
                certificate itself. Install OpenSSL, or point Mediafin at an \
                existing certificate and key.
                """
            case .generationFailed(let detail):
                return "Creating the certificate failed: \(detail)"
            case .directoryNotWritable(let path):
                return "Cannot write to \(path)."
            }
        }
    }

    /// Paths the generated material lives at.
    public struct Material: Sendable, Equatable {
        public let certificatePath: String
        public let privateKeyPath: String

        public var source: WebTLSSource {
            .pemFiles(certificateChain: certificatePath, privateKey: privateKeyPath)
        }
    }

    /// Returns the material in `directory`, generating it if it is not there.
    ///
    /// - Parameters:
    ///   - directory: where `cert.pem` and `key.pem` live.
    ///   - commonName: the name the certificate is issued for.
    ///   - validForDays: 825 days is the maximum browsers accept for a
    ///     server certificate.
    public static func ensure(in directory: URL,
                              commonName: String = "mediafin.local",
                              validForDays: Int = 825) throws -> Material {
        let certificate = directory.appendingPathComponent("cert.pem")
        let key = directory.appendingPathComponent("key.pem")
        let material = Material(certificatePath: certificate.path, privateKeyPath: key.path)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: certificate.path),
           fileManager.fileExists(atPath: key.path) {
            return material
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            throw Failure.directoryNotWritable(directory.path)
        }

        guard let openssl = locateOpenSSL() else { throw Failure.opensslMissing }
        try run(openssl, arguments: [
            "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
            "-days", String(max(1, validForDays)),
            "-keyout", key.path,
            "-out", certificate.path,
            "-subj", "/CN=\(commonName)",
            // Browsers ignore the common name and require a subject
            // alternative name, so loopback has to be listed explicitly.
            "-addext", "subjectAltName=DNS:\(commonName),DNS:localhost,IP:127.0.0.1",
        ])

        guard fileManager.fileExists(atPath: certificate.path),
              fileManager.fileExists(atPath: key.path) else {
            throw Failure.generationFailed("openssl reported success but wrote no files")
        }
        // The private key must not be readable by other accounts on the machine.
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: certificate.path)
        return material
    }

    /// Deletes the material so the next start generates a fresh identity.
    public static func remove(in directory: URL) {
        for name in ["cert.pem", "key.pem"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// The SHA-256 fingerprint a user can compare against what the browser
    /// shows, which is the only way to tell a self-signed certificate from an
    /// impostor's.
    public static func fingerprint(ofCertificateAt path: String) -> String? {
        guard let openssl = locateOpenSSL() else { return nil }
        guard let output = try? run(openssl, arguments: [
            "x509", "-in", path, "-noout", "-fingerprint", "-sha256",
        ]) else { return nil }
        // Output looks like "sha256 Fingerprint=AB:CD:…".
        guard let equals = output.firstIndex(of: "=") else { return nil }
        return String(output[output.index(after: equals)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Running openssl

    /// Looks for openssl in the usual places. No shell is involved, and the
    /// path is never taken from the environment's `PATH` lookup semantics, so
    /// nothing in the environment can redirect it.
    static func locateOpenSSL() -> String? {
        let candidates = [
            "/usr/bin/openssl",       // macOS (LibreSSL) and most Linux distributions
            "/bin/openssl",
            "/usr/local/bin/openssl", // Homebrew on Intel
            "/opt/homebrew/bin/openssl",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    private static func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // An argument array, never a command string: nothing here can be
        // interpreted as shell syntax.
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw Failure.generationFailed(String(describing: error))
        }
        let standardOutput = output.fileHandleForReading.readDataToEndOfFile()
        let standardError = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(decoding: standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.generationFailed(detail.isEmpty
                ? "openssl exited with status \(process.terminationStatus)"
                : detail)
        }
        return String(decoding: standardOutput, as: UTF8.self)
    }
}
