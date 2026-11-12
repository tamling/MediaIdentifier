import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A minimal seam over `URLSession` so request construction and response
/// handling can be exercised without a network.
///
/// The usual trick on Apple platforms — a custom `URLProtocol` registered via
/// `URLSessionConfiguration.protocolClasses` — does not work on Linux:
/// swift-corelibs-foundation's `URLSession` is built on libcurl and never
/// consults custom protocol classes. Since Linux is a target platform, the
/// tests inject a transport instead, which behaves identically everywhere.
public protocol HTTPTransport: Sendable {
    /// Performs `request` and returns its body plus the HTTP response, or nil
    /// for the response when the reply was not HTTP.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse?)
}

/// One `URLSession` for the whole process, deliberately never released.
///
/// This exists because releasing one kills the program. On Linux a
/// `URLSession` carries a libcurl multi handle on a thread of its own, and
/// swift-corelibs-foundation does not clean that up unless the session is
/// invalidated first. Let one go out of scope instead and the Swift runtime
/// aborts the process:
///
///     Object 0x… of class _MultiHandle deallocated with non-zero retain
///     count 2. … resulting in a dangling reference.
///     Aborted
///
/// Four places used to build `URLSession(configuration: .ephemeral)` per
/// instance, and the engine builds a metadata provider per run — so asking the
/// model server about one dropped film created a session, used it, let it go,
/// and took the window down with it. Nothing invalidated anything anywhere.
///
/// A shared session that outlives the process is the fix rather than calling
/// `finishTasksAndInvalidate()` in the right places: there is no reliable
/// "right place" when the owner is a short-lived value type handed around
/// async code, and getting it wrong aborts rather than leaks.
///
/// Still ephemeral, for the original reason: credentials and responses stay
/// out of the shared on-disk URL cache.
public enum SharedHTTPSession {
    public static let ephemeral: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // Bounded, because the engine's serial queue waits on these: an
        // unreachable model server must not hold up a scan for ever.
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()
}

/// The production transport: a real `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// - Parameter session: defaults to the one shared session. Passing one in
    ///   is for tests; whatever is passed must outlive the process, for the
    ///   reason spelled out on `SharedHTTPSession`.
    public init(session: URLSession? = nil) {
        self.session = session ?? SharedHTTPSession.ephemeral
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse?) {
        let (data, response) = try await session.data(for: request)
        return (data, response as? HTTPURLResponse)
    }
}
