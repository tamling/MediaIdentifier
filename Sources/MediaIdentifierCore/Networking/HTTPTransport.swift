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

/// The production transport: a real `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// - Parameter session: defaults to an ephemeral session so credentials and
    ///   responses are not written to the shared URL cache on disk.
    public init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse?) {
        let (data, response) = try await session.data(for: request)
        return (data, response as? HTTPURLResponse)
    }
}
