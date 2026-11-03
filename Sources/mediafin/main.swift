import Foundation
import Dispatch
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import MediaIdentifierCore
import MediaIdentifierWeb

/// The `mediafin` binary: starts the local web interface and keeps it running.
///
/// This is how Mediafin runs on Linux, where there is no SwiftUI app. The
/// interface is reachable from a browser; everything it needs — routing,
/// access control, TLS — comes from the Core and Web libraries.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func report(_ message: String) {
    print(message)
    fflush(stdout)
}

/// Runs `work`, reporting the error and exiting rather than trapping.
func orExit<T>(_ work: () throws -> T) -> T {
    do {
        return try work()
    } catch {
        fail("\(error)")
    }
}

// MARK: Options

let options = orExit { try MediafinOptions.parse(Array(CommandLine.arguments.dropFirst())) }

if options.showHelp {
    report(MediafinOptions.helpText)
    exit(0)
}

let configDirectory = options.configDirectory.map {
    URL(fileURLWithPath: $0, isDirectory: true)
} ?? MediafinPaths.configDirectory()

let tokenStore = TokenStore(directory: configDirectory)

// MARK: Token-only modes

if options.rotateToken {
    let fresh = orExit { try tokenStore.rotate() }
    report("""
    A new access token has been issued. Every signed-in browser is now signed out.

      \(fresh)
    """)
    exit(0)
}

if options.printTokenOnly {
    report(orExit { try tokenStore.loadOrCreate() }.token)
    exit(0)
}

// MARK: Token

let stored = orExit { try tokenStore.loadOrCreate() }

// MARK: TLS

let tlsSource: WebTLSSource? = orExit {
    do {
        return try options.tlsSource(
            generated: try WebCertificate.ensure(in: configDirectory).source
        )
    } catch {
        fail("""
        \(error)

        You can also start without encryption, for this machine only:
          mediafin --no-tls --bind local
        """)
    }
}

var certificateFingerprint: String?
if case .pemFiles(let chain, _)? = tlsSource {
    certificateFingerprint = WebCertificate.fingerprint(ofCertificateAt: chain)
}

// MARK: Server

let server = WebServer()
let router = WebRouter(
    policy: WebSecurityPolicy(
        token: stored.token,
        requireAuth: true,
        allowAnonymousHealth: true,
        isTLS: tlsSource != nil
    ),
    // Until the renaming engine is wired into the interface the snapshot
    // reports an idle server, which /healthz already makes useful to a monitor.
    snapshot: { StatusSnapshot() }
)

let boundPort = orExit {
    try server.start(
        configuration: WebServerConfiguration(
            port: options.port,
            bindLocalOnly: options.bindLocalOnly,
            tls: tlsSource,
            allowPlainHTTPOnNetwork: options.allowPlainHTTPOnNetwork
        )
    ) { request in
        router.respond(to: request)
    }
}

// MARK: What the user needs to know

let scheme = tlsSource == nil ? "http" : "https"
let host = options.bindLocalOnly ? "localhost" : "<this machine>"
report("Mediafin is serving its interface on \(scheme)://\(host):\(boundPort)")

switch stored.outcome {
case .created:
    report("""

    An access token has been created. You need it to sign in:

      \(stored.token)

    It is kept in \(tokenStore.fileURL.path) and survives a restart.
    """)
case .loadedAndTightened:
    report("""

    The access token file was readable by other accounts on this machine; its
    permissions have been corrected. Consider issuing a new one:
      mediafin --rotate-token
    """)
case .loaded:
    report("Sign in with the access token from \(tokenStore.fileURL.path).")
}

if let certificateFingerprint, options.certificatePath == nil {
    report("""

    The certificate is self-signed, so the browser warns once. Check that the
    fingerprint it shows matches this one:

      \(certificateFingerprint)
    """)
}

if tlsSource == nil {
    let where_ = options.bindLocalOnly
        ? "this machine."
        : "a network you fully trust, behind something that terminates TLS."
    report("""

    Warning: this connection is not encrypted, so the access token travels in
    clear text. Only use it on \(where_)
    """)
}

report("\nPress Ctrl-C to stop.")

// MARK: Run until interrupted

/// A dispatch source handles the signal on a queue instead of in a signal
/// handler, so shutting down can do real work.
func installShutdownHandler(for signalNumber: Int32) -> DispatchSourceSignal {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        report("\nStopping.")
        server.shutdown()
        exit(0)
    }
    source.resume()
    return source
}

let signalSources = [installShutdownHandler(for: SIGINT),
                     installShutdownHandler(for: SIGTERM)]
withExtendedLifetime(signalSources) {
    dispatchMain()
}
