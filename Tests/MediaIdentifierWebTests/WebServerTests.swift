import XCTest
import NIOCore
import NIOPosix
import NIOSSL
import MediaIdentifierCore
@testable import MediaIdentifierWeb

/// Dynamic end-to-end tests: a real listening socket, a real client, and for
/// the HTTPS cases a real TLS handshake with certificate verification on.
final class WebServerTests: XCTestCase {

    private var server: WebServer!
    private var clientGroup: MultiThreadedEventLoopGroup!
    private var scratch: URL!

    private let token = "a0b1c2d3e4f5a0b1c2d3e4f5a0b1c2d3e4f5a0b1c2d3e4f5a0b1c2d3e4f5a0b1"

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = WebServer()
        clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mediafin-web-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        server?.shutdown()
        server = nil
        try? clientGroup?.syncShutdownGracefully()
        clientGroup = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        try super.tearDownWithError()
    }

    // MARK: Helpers

    private func router(requireAuth: Bool = true, isTLS: Bool = false) -> WebRouter {
        WebRouter(
            policy: WebSecurityPolicy(token: token, requireAuth: requireAuth, isTLS: isTLS),
            snapshot: { StatusSnapshot() }
        )
    }

    private func handler(_ router: WebRouter) -> @Sendable (HTTPRequest) -> HTTPResponse {
        { request in router.respond(to: request) }
    }

    /// Sends a raw request and returns the whole reply, over TLS when
    /// `trustRoot` is given. Certificate verification stays on, so a TLS test
    /// passing means the chain really validated.
    private func send(_ raw: String, port: Int, trustRoot: String? = nil) throws -> String {
        let promise = clientGroup.next().makePromise(of: String.self)
        let collector = ReplyCollector(promise: promise)

        let bootstrap = ClientBootstrap(group: clientGroup)
            .channelInitializer { channel in
                guard let trustRoot else {
                    return channel.pipeline.addHandler(collector)
                }
                do {
                    var tls = TLSConfiguration.makeClientConfiguration()
                    tls.trustRoots = .file(trustRoot)
                    let context = try NIOSSLContext(configuration: tls)
                    let tlsHandler = try NIOSSLClientHandler(context: context,
                                                             serverHostname: "localhost")
                    return channel.pipeline.addHandler(tlsHandler).flatMap {
                        channel.pipeline.addHandler(collector)
                    }
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel = try bootstrap.connect(host: "127.0.0.1", port: port).wait()
        var buffer = channel.allocator.buffer(capacity: raw.utf8.count)
        buffer.writeString(raw)
        try channel.writeAndFlush(buffer).wait()
        let reply = try promise.futureResult.wait()
        try? channel.close().wait()
        return reply
    }

    private func get(_ path: String, extraHeaders: String = "") -> String {
        "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\(extraHeaders)Connection: close\r\n\r\n"
    }

    // MARK: Plain HTTP on loopback

    func testServesHealthOverPlainHTTPOnLoopback() throws {
        let port = try server.start(
            configuration: WebServerConfiguration(port: 0, bindLocalOnly: true),
            handler: handler(router())
        )
        XCTAssertGreaterThan(port, 0)
        XCTAssertTrue(server.isRunning)

        let reply = try send(get("/healthz"), port: port)
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 OK"), reply)
        XCTAssertTrue(reply.hasSuffix("ok"), reply)
    }

    /// The hardening headers must survive the NIO transport, not just
    /// `serialized()`.
    func testHardeningHeadersReachTheClient() throws {
        let port = try server.start(
            configuration: WebServerConfiguration(port: 0, bindLocalOnly: true),
            handler: handler(router())
        )
        let reply = try send(get("/login"), port: port)
        XCTAssertTrue(reply.contains("X-Content-Type-Options: nosniff"), reply)
        XCTAssertTrue(reply.contains("X-Frame-Options: DENY"), reply)
        XCTAssertTrue(reply.contains("Referrer-Policy: no-referrer"), reply)
        XCTAssertTrue(reply.contains("Content-Security-Policy:"), reply)
        XCTAssertFalse(reply.lowercased().contains("access-control-allow-origin"), reply)
    }

    func testUnauthenticatedRequestIsRefusedEndToEnd() throws {
        let port = try server.start(
            configuration: WebServerConfiguration(port: 0, bindLocalOnly: true),
            handler: handler(router())
        )
        let page = try send(get("/"), port: port)
        XCTAssertTrue(page.hasPrefix("HTTP/1.1 401"), page)

        let api = try send(get("/api/status"), port: port)
        XCTAssertTrue(api.hasPrefix("HTTP/1.1 401"), api)
        XCTAssertTrue(api.contains("WWW-Authenticate:"), api)
        XCTAssertFalse(api.contains(token), "the token must never be echoed")
    }

    func testAuthenticatedRequestSucceedsEndToEnd() throws {
        let port = try server.start(
            configuration: WebServerConfiguration(port: 0, bindLocalOnly: true),
            handler: handler(router())
        )
        let reply = try send(get("/", extraHeaders: "Authorization: Bearer \(token)\r\n"),
                             port: port)
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 OK"), reply)
        XCTAssertTrue(reply.contains("Mediafin"), reply)
    }

    func testHeadRequestSendsHeadersWithoutBody() throws {
        let port = try server.start(
            configuration: WebServerConfiguration(port: 0, bindLocalOnly: true),
            handler: handler(router())
        )
        let reply = try send("HEAD /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
                             port: port)
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 OK"), reply)
        XCTAssertTrue(reply.contains("Content-Length: 2"), reply)
        XCTAssertTrue(reply.hasSuffix("\r\n\r\n"), reply)
    }

    func testOversizedBodyIsRefusedWith413() throws {
        let port = try server.start(
            configuration: WebServerConfiguration(port: 0, bindLocalOnly: true),
            handler: handler(router())
        )
        let payload = String(repeating: "x", count: HTTPRequestParser.maxRequestBytes + 1024)
        let raw = "POST /login HTTP/1.1\r\nHost: localhost\r\n"
            + "Content-Type: application/x-www-form-urlencoded\r\n"
            + "Content-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n\(payload)"
        let reply = try send(raw, port: port)
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 413"), reply)
    }

    // MARK: Refusing to serve credentials in the clear

    func testRefusesPlainHTTPOnTheNetwork() {
        let configuration = WebServerConfiguration(port: 0, bindLocalOnly: false, tls: nil)
        XCTAssertThrowsError(try server.start(configuration: configuration,
                                              handler: handler(router()))) { error in
            XCTAssertEqual(error as? WebServerError, .plainHTTPOnNetworkRefused)
        }
        XCTAssertFalse(server.isRunning)
    }

    /// Someone terminating TLS in a reverse proxy can still opt in.
    func testPlainHTTPOnTheNetworkCanBeExplicitlyAllowed() throws {
        let port = try server.start(
            configuration: WebServerConfiguration(port: 0, bindLocalOnly: false, tls: nil,
                                                  allowPlainHTTPOnNetwork: true),
            handler: handler(router())
        )
        XCTAssertGreaterThan(port, 0)
    }

    func testRejectsInvalidPortAndDoubleStart() throws {
        XCTAssertThrowsError(
            try server.start(configuration: WebServerConfiguration(port: 70_000),
                             handler: handler(router()))
        ) { XCTAssertEqual($0 as? WebServerError, .invalidPort(70_000)) }

        _ = try server.start(configuration: WebServerConfiguration(port: 0),
                             handler: handler(router()))
        XCTAssertThrowsError(
            try server.start(configuration: WebServerConfiguration(port: 0),
                             handler: handler(router()))
        ) { XCTAssertEqual($0 as? WebServerError, .alreadyRunning) }
    }

    func testStopReleasesThePort() throws {
        let port = try server.start(configuration: WebServerConfiguration(port: 0),
                                    handler: handler(router()))
        XCTAssertEqual(server.port, port)
        server.stop()
        XCTAssertFalse(server.isRunning)
        XCTAssertEqual(server.port, 0)
    }

    // MARK: HTTPS

    func testServesOverHTTPSWithAGeneratedCertificate() throws {
        try XCTSkipIf(WebCertificate.locateOpenSSL() == nil, "openssl is not installed")
        let material = try WebCertificate.ensure(in: scratch)

        let port = try server.start(
            configuration: WebServerConfiguration(port: 0, bindLocalOnly: true,
                                                  tls: material.source),
            handler: handler(router(isTLS: true))
        )
        // Verification is on and the trust root is the generated certificate,
        // so a reply at all means the TLS chain validated.
        let reply = try send(get("/healthz"), port: port,
                             trustRoot: material.certificatePath)
        XCTAssertTrue(reply.hasPrefix("HTTP/1.1 200 OK"), reply)
    }

    /// A client that does not trust the certificate must fail the handshake
    /// rather than fall back to something weaker.
    func testHTTPSHandshakeFailsForAnUntrustedClient() throws {
        try XCTSkipIf(WebCertificate.locateOpenSSL() == nil, "openssl is not installed")
        let material = try WebCertificate.ensure(in: scratch)
        let other = try WebCertificate.ensure(
            in: scratch.appendingPathComponent("other"), commonName: "impostor.local"
        )
        let port = try server.start(
            configuration: WebServerConfiguration(port: 0, bindLocalOnly: true,
                                                  tls: material.source),
            handler: handler(router(isTLS: true))
        )
        // Either the handshake error surfaces, or the connection is closed
        // with nothing served — never an HTTP reply.
        let reply = (try? send(get("/healthz"), port: port,
                               trustRoot: other.certificatePath)) ?? ""
        XCTAssertFalse(reply.contains("HTTP/1.1 200"),
                       "a client that does not trust the certificate must not be served")
    }

    func testPlainRequestToATLSPortDoesNotSucceed() throws {
        try XCTSkipIf(WebCertificate.locateOpenSSL() == nil, "openssl is not installed")
        let material = try WebCertificate.ensure(in: scratch)
        let port = try server.start(
            configuration: WebServerConfiguration(port: 0, bindLocalOnly: true,
                                                  tls: material.source),
            handler: handler(router(isTLS: true))
        )
        // An HTTP request sent to an HTTPS port must not produce an HTTP reply.
        let reply = (try? send(get("/healthz"), port: port)) ?? ""
        XCTAssertFalse(reply.hasPrefix("HTTP/1.1"), reply)
    }

    func testMissingTLSMaterialIsReportedClearly() {
        let configuration = WebServerConfiguration(
            port: 0, bindLocalOnly: true,
            tls: .pemFiles(certificateChain: "/nonexistent/cert.pem",
                           privateKey: "/nonexistent/key.pem")
        )
        XCTAssertThrowsError(try server.start(configuration: configuration,
                                              handler: handler(router()))) { error in
            guard case .tlsMaterialUnreadable = error as? WebServerError else {
                return XCTFail("expected a TLS material error, got \(error)")
            }
        }
    }

    // MARK: Certificate handling

    func testGeneratedPrivateKeyIsNotReadableByOthers() throws {
        try XCTSkipIf(WebCertificate.locateOpenSSL() == nil, "openssl is not installed")
        let material = try WebCertificate.ensure(in: scratch)
        let attributes = try FileManager.default
            .attributesOfItem(atPath: material.privateKeyPath)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.int16Value & 0o077, 0,
                       "the private key must not be readable by other accounts")
    }

    func testCertificateIsReusedOnTheNextStart() throws {
        try XCTSkipIf(WebCertificate.locateOpenSSL() == nil, "openssl is not installed")
        let first = try WebCertificate.ensure(in: scratch)
        let firstBytes = try Data(contentsOf: URL(fileURLWithPath: first.certificatePath))
        let second = try WebCertificate.ensure(in: scratch)
        let secondBytes = try Data(contentsOf: URL(fileURLWithPath: second.certificatePath))
        XCTAssertEqual(firstBytes, secondBytes, "a restart must not change the identity")
    }

    func testRemovingMaterialForcesAFreshIdentity() throws {
        try XCTSkipIf(WebCertificate.locateOpenSSL() == nil, "openssl is not installed")
        let first = try WebCertificate.ensure(in: scratch)
        let firstBytes = try Data(contentsOf: URL(fileURLWithPath: first.certificatePath))
        WebCertificate.remove(in: scratch)
        let second = try WebCertificate.ensure(in: scratch)
        let secondBytes = try Data(contentsOf: URL(fileURLWithPath: second.certificatePath))
        XCTAssertNotEqual(firstBytes, secondBytes)
    }

    /// The fingerprint is what a user compares against the browser's warning
    /// dialog, so it has to be readable and look like one.
    func testFingerprintIsReported() throws {
        try XCTSkipIf(WebCertificate.locateOpenSSL() == nil, "openssl is not installed")
        let material = try WebCertificate.ensure(in: scratch)
        let fingerprint = try XCTUnwrap(
            WebCertificate.fingerprint(ofCertificateAt: material.certificatePath)
        )
        XCTAssertEqual(fingerprint.split(separator: ":").count, 32, fingerprint)
    }
}

/// Collects everything the server sends until it closes the connection.
private final class ReplyCollector: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<String>
    private var received = Data()
    private var isSettled = false

    init(promise: EventLoopPromise<String>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if let bytes = buffer.readBytes(length: buffer.readableBytes) {
            received.append(contentsOf: bytes)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        settle { promise.succeed(String(decoding: received, as: UTF8.self)) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        settle { promise.fail(error) }
        context.close(promise: nil)
    }

    /// A promise may only be fulfilled once; a TLS failure delivers both an
    /// error and a close.
    private func settle(_ action: () -> Void) {
        guard !isSettled else { return }
        isSettled = true
        action()
    }
}
