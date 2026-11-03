import Foundation
import MediaIdentifierCore
import MediaIdentifierWeb

/// Serves the app's current status so external monitors (Uptime Kuma, a
/// browser, …) can watch progress and notice when a run finishes (FR20).
///
/// It used to be a plain-HTTP, unauthenticated page on Apple's Network
/// framework. It is now the same HTTPS server the Linux binary uses: TLS, an
/// access token, and read-only — `WebRouter.Mode.statusOnly`, since the Mac
/// app has its own native interface and only needs something pollable.
///
/// `/healthz` stays reachable without the token, because a plain uptime
/// monitor cannot sign in and that endpoint reveals only idle/busy/error.
@MainActor
final class StatusWebServer {
    /// Thread-safe holder for the latest snapshot: written here, read on the
    /// server's own threads.
    private final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = StatusSnapshot.empty
        func get() -> StatusSnapshot { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ snapshot: StatusSnapshot) { lock.lock(); value = snapshot; lock.unlock() }
    }

    private let box = SnapshotBox()
    private var server: WebServer?
    private(set) var isRunning = false

    /// The token a browser needs. Kept in the Keychain so it survives a
    /// restart and is not readable as a plain file.
    private(set) var accessToken = ""
    /// SHA-256 fingerprint of the certificate, to compare with the browser's
    /// warning. Empty when no certificate could be made.
    private(set) var certificateFingerprint = ""
    /// Why the last start failed, for the UI to show.
    private(set) var lastError: String?

    /// Publishes a new snapshot to be served on the next request.
    func update(_ snapshot: StatusSnapshot) { box.set(snapshot) }

    /// Starts listening on `port`. Returns false if it could not start, with
    /// the reason in `lastError`.
    @discardableResult
    func start(port: Int, localOnly: Bool) -> Bool {
        stop()
        lastError = nil

        let directory = Self.supportDirectory()
        let token = Self.loadOrCreateToken()
        accessToken = token

        let tls: WebTLSSource
        do {
            let material = try WebCertificate.ensure(in: directory)
            tls = material.source
            certificateFingerprint =
                WebCertificate.fingerprint(ofCertificateAt: material.certificatePath) ?? ""
        } catch {
            // Without TLS this would have to serve the token in clear text, so
            // it does not start at all.
            lastError = "\(error)"
            return false
        }

        let snapshot = box
        let router = WebRouter(
            policy: WebSecurityPolicy(token: token, requireAuth: true,
                                      allowAnonymousHealth: true, isTLS: true),
            mode: .statusOnly,
            snapshot: { snapshot.get() }
        )

        let server = WebServer()
        do {
            try server.start(
                configuration: WebServerConfiguration(port: port, bindLocalOnly: localOnly,
                                                      tls: tls)
            ) { request in
                router.respond(to: request)
            }
        } catch {
            lastError = "\(error)"
            server.shutdown()
            return false
        }

        self.server = server
        isRunning = true
        return true
    }

    func stop() {
        server?.shutdown()
        server = nil
        isRunning = false
    }

    /// Issues a new token, signing every browser out.
    func rotateToken() {
        accessToken = WebSecurityPolicy.generateToken()
        KeychainStore.set(accessToken, for: Self.keychainAccount)
    }

    // MARK: Storage

    private static let keychainAccount = "web-status-token"

    private static func loadOrCreateToken() -> String {
        let existing = KeychainStore.get(Self.keychainAccount)
        if !existing.isEmpty { return existing }
        let fresh = WebSecurityPolicy.generateToken()
        KeychainStore.set(fresh, for: Self.keychainAccount)
        return fresh
    }

    private static func supportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Mediafin", isDirectory: true)
    }
}
