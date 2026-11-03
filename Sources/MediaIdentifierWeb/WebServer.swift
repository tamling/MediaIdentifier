import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import MediaIdentifierCore

/// Where the server's TLS identity comes from.
public enum WebTLSSource: Sendable, Equatable {
    /// PEM files on disk: a certificate chain and its private key. Point this
    /// at a real certificate (from a reverse proxy or an ACME client) to avoid
    /// the browser warning a self-signed certificate causes.
    case pemFiles(certificateChain: String, privateKey: String)
}

public struct WebServerConfiguration: Sendable, Equatable {
    /// TCP port, or 0 to let the system pick a free one.
    public var port: Int
    /// Bind to 127.0.0.1 only, so nothing on the network can connect. The
    /// default, because the interface exposes the whole library.
    public var bindLocalOnly: Bool
    /// TLS identity. `nil` serves plain HTTP, which `start` refuses for a
    /// non-local bind unless `allowPlainHTTPOnNetwork` is set.
    public var tls: WebTLSSource?
    /// Escape hatch for someone who terminates TLS in front of Mediafin (a
    /// reverse proxy). Off by default: plaintext credentials on a network are
    /// otherwise trivially readable.
    public var allowPlainHTTPOnNetwork: Bool

    public init(port: Int = 8720, bindLocalOnly: Bool = true,
                tls: WebTLSSource? = nil, allowPlainHTTPOnNetwork: Bool = false) {
        self.port = port
        self.bindLocalOnly = bindLocalOnly
        self.tls = tls
        self.allowPlainHTTPOnNetwork = allowPlainHTTPOnNetwork
    }
}

public enum WebServerError: Error, CustomStringConvertible, Equatable {
    case invalidPort(Int)
    case plainHTTPOnNetworkRefused
    case tlsMaterialUnreadable(String)
    case alreadyRunning
    case bindFailed(String)

    public var description: String {
        switch self {
        case .invalidPort(let port):
            return "Port \(port) is outside the valid range 0–65535."
        case .plainHTTPOnNetworkRefused:
            return """
            Refusing to serve the interface on the network without HTTPS. \
            Enable TLS, or restrict it to this machine.
            """
        case .tlsMaterialUnreadable(let reason):
            return "The certificate or key could not be loaded: \(reason)"
        case .alreadyRunning:
            return "The web server is already running."
        case .bindFailed(let reason):
            return "Could not start listening: \(reason)"
        }
    }
}

/// HTTP/1.1 server for the local web interface, with TLS.
///
/// Built on SwiftNIO because Linux is a target platform and Apple's Network
/// framework does not exist there; NIOSSL brings its own BoringSSL, so this
/// needs no system OpenSSL on either platform.
///
/// Routing, access control and response shaping live in `MediaIdentifierCore`
/// (`WebRouter`, `HTTPRequest`, `HTTPResponse`) — this type only moves bytes.
public final class WebServer: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let lock = NSLock()
    private var channel: Channel?
    private var _port = 0
    private var isShutDown = false

    public init(threads: Int = 1) {
        group = MultiThreadedEventLoopGroup(numberOfThreads: max(1, threads))
    }

    deinit {
        // Only release the event loops, and never block: a `wait()` in deinit
        // deadlocks if the last reference is dropped on an event loop thread.
        lock.lock()
        let needsShutdown = !isShutDown
        isShutDown = true
        lock.unlock()
        if needsShutdown { group.shutdownGracefully { _ in } }
    }

    /// The port being served, 0 when stopped.
    public var port: Int { lock.lock(); defer { lock.unlock() }; return _port }

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return channel != nil }

    /// Starts listening and returns the port actually bound.
    @discardableResult
    public func start(
        configuration: WebServerConfiguration,
        handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse
    ) throws -> Int {
        guard (0...65535).contains(configuration.port) else {
            throw WebServerError.invalidPort(configuration.port)
        }
        lock.lock()
        let running = channel != nil
        lock.unlock()
        guard !running else { throw WebServerError.alreadyRunning }

        // Serving credentials in clear text across a network is the one
        // mistake this interface must not make quietly.
        if configuration.tls == nil, !configuration.bindLocalOnly,
           !configuration.allowPlainHTTPOnNetwork {
            throw WebServerError.plainHTTPOnNetworkRefused
        }

        let sslContext = try Self.makeSSLContext(for: configuration.tls)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 32)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                var chain = channel.eventLoop.makeSucceededVoidFuture()
                if let sslContext {
                    chain = chain.flatMap {
                        channel.pipeline.addHandler(NIOSSLServerHandler(context: sslContext))
                    }
                }
                return chain
                    .flatMap { channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true) }
                    .flatMap { channel.pipeline.addHandler(RequestHandler(handler: handler)) }
            }

        let host = configuration.bindLocalOnly ? "127.0.0.1" : "0.0.0.0"
        let bound: Channel
        do {
            bound = try bootstrap.bind(host: host, port: configuration.port).wait()
        } catch {
            throw WebServerError.bindFailed(String(describing: error))
        }

        lock.lock()
        channel = bound
        _port = bound.localAddress?.port ?? configuration.port
        let port = _port
        lock.unlock()
        return port
    }

    public func stop() {
        lock.lock()
        let bound = channel
        channel = nil
        _port = 0
        lock.unlock()
        try? bound?.close().wait()
    }

    /// Shuts down the event loops. The server cannot be started again after
    /// this; call it when the app quits. Calling it twice is harmless.
    public func shutdown() {
        stop()
        lock.lock()
        let needsShutdown = !isShutDown
        isShutDown = true
        lock.unlock()
        guard needsShutdown else { return }
        try? group.syncShutdownGracefully()
    }

    private static func makeSSLContext(for source: WebTLSSource?) throws -> NIOSSLContext? {
        guard let source else { return nil }
        switch source {
        case .pemFiles(let chainPath, let keyPath):
            do {
                let certificates = try NIOSSLCertificate.fromPEMFile(chainPath)
                    .map { NIOSSLCertificateSource.certificate($0) }
                guard !certificates.isEmpty else {
                    throw WebServerError.tlsMaterialUnreadable("the certificate file is empty")
                }
                let key = try NIOSSLPrivateKey(file: keyPath, format: .pem)
                var tls = TLSConfiguration.makeServerConfiguration(
                    certificateChain: certificates,
                    privateKey: .privateKey(key)
                )
                // TLS 1.0/1.1 are broken and unnecessary for a browser talking
                // to a local server.
                tls.minimumTLSVersion = .tlsv12
                return try NIOSSLContext(configuration: tls)
            } catch let error as WebServerError {
                throw error
            } catch {
                throw WebServerError.tlsMaterialUnreadable(String(describing: error))
            }
        }
    }
}

// MARK: - Request handling

/// Collects one request, hands it to the router, writes the response, closes.
private final class RequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let handler: @Sendable (HTTPRequest) -> HTTPResponse
    private var head: HTTPRequestHead?
    private var body = ByteBufferAllocator().buffer(capacity: 0)
    private var isOversized = false

    init(handler: @escaping @Sendable (HTTPRequest) -> HTTPResponse) {
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let requestHead):
            head = requestHead
            body.clear()
            isOversized = false
        case .body(var buffer):
            guard !isOversized else { return }
            if body.readableBytes + buffer.readableBytes > HTTPRequestParser.maxRequestBytes {
                // Stop buffering rather than let a large upload grow memory.
                isOversized = true
                body.clear()
                return
            }
            body.writeBuffer(&buffer)
        case .end:
            guard let requestHead = head else { return }
            write(response(for: requestHead), to: context, version: requestHead.version,
                  omitBody: requestHead.method == .HEAD)
            head = nil
            body.clear()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func response(for requestHead: HTTPRequestHead) -> HTTPResponse {
        guard !isOversized else { return .text("request too large", status: 413) }
        return handler(makeRequest(from: requestHead))
    }

    private func makeRequest(from requestHead: HTTPRequestHead) -> HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in requestHead.headers {
            let key = name.lowercased()
            if headers[key] == nil { headers[key] = value }
        }
        let target = HTTPRequestParser.splitTarget(requestHead.uri)
        return HTTPRequest(
            method: requestHead.method.rawValue.uppercased(),
            path: target.path,
            query: target.query,
            headers: headers,
            body: body.readableBytes == 0 ? Data() : Data(body.readableBytesView)
        )
    }

    private func write(_ response: HTTPResponse, to context: ChannelHandlerContext,
                       version: HTTPVersion, omitBody: Bool) {
        var headers = HTTPHeaders()
        for header in response.wireHeaders() {
            headers.add(name: header.name, value: header.value)
        }
        let status = HTTPResponseStatus(statusCode: response.status,
                                        reasonPhrase: HTTPResponse.reason(for: response.status))
        let responseHead = HTTPResponseHead(version: version, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)

        if !omitBody, !response.body.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}
