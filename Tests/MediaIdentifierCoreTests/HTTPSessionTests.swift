import XCTest
@testable import MediaIdentifierCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Building and dropping the things that talk to the network.
///
/// This is here because of a crash, and the crash had no symptom anyone could
/// read. Dropping a film on the window printed every line of the drop handler,
/// said "submitted", and then:
///
///     Object 0x… of class _MultiHandle deallocated with non-zero retain
///     count 2. … resulting in a dangling reference.
///     Aborted
///
/// On Linux a `URLSession` carries a libcurl multi handle on its own thread,
/// and swift-corelibs-foundation only cleans it up if the session is
/// invalidated first. Four places built one per instance and let it go, the
/// engine builds a metadata provider per run, and so asking the model server
/// about one dropped film took the window with it.
///
/// A scan did not crash for the one reason that made this hard to find: with
/// no import folder set, identification never reached the network at all.
final class HTTPSessionTests: XCTestCase {

    /// The assertion is that the process is still running.
    ///
    /// There is nothing else to assert: the failure mode is `abort()`, which
    /// takes the test runner down with it. A green run of this test IS the
    /// result — which is unusual enough to say out loud rather than leave
    /// looking like a test that checks nothing.
    func testBuildingAndDroppingNetworkClientsDoesNotAbortTheProcess() {
        for _ in 0..<25 {
            _ = URLSessionTransport()
            _ = TMDbMetadataProvider(apiKey: "0123456789abcdef0123456789abcdef")
            _ = LocalLLMMetadataProvider(config: .init(
                baseURL: "http://127.0.0.1:1", model: "none", apiKey: ""))
            _ = try? JellyfinConnector(serverURL: "http://127.0.0.1:1", apiKey: "x")
        }
        XCTAssertTrue(true, "still running, which is the whole point")
    }

    /// And they all share one session, rather than each holding its own.
    ///
    /// Checked through the behaviour that matters — that the shared session is
    /// one object and the same one every time — because the sessions inside
    /// the clients are private. The guard against a new
    /// `URLSession(configuration:)` creeping back into a provider is a grep in
    /// the build; it cannot be written here.
    func testThereIsOneSharedSessionAndItIsStable() {
        let first = SharedHTTPSession.ephemeral
        let second = SharedHTTPSession.ephemeral
        XCTAssertTrue(first === second, "the shared session is being rebuilt")
    }

    /// A request that cannot finish must not hold the engine's serial queue
    /// for ever: everything else — scanning, renaming, the traffic light —
    /// waits behind it.
    func testTheSharedSessionHasABoundedTimeout() {
        let configuration = SharedHTTPSession.ephemeral.configuration
        XCTAssertGreaterThan(configuration.timeoutIntervalForRequest, 0)
        XCTAssertLessThanOrEqual(configuration.timeoutIntervalForRequest, 60)
    }
}
