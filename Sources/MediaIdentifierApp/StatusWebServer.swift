import Foundation
import Network
import MediaIdentifierCore

/// A tiny, read-only HTTP server that exposes the app's current status so
/// external monitors (Uptime Kuma, a browser, …) can watch progress and be
/// notified when a run finishes (FR20). Uses the Network framework — no external
/// dependencies. It only ever serves status; it never accepts commands.
final class StatusWebServer: @unchecked Sendable {
    /// Thread-safe holder for the latest snapshot (read on the listener queue,
    /// written from the main actor).
    private final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = StatusSnapshot.empty
        func get() -> StatusSnapshot { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ snapshot: StatusSnapshot) { lock.lock(); value = snapshot; lock.unlock() }
    }

    private let box = SnapshotBox()
    private let queue = DispatchQueue(label: "media.identifier.status-web", qos: .utility)
    private var listener: NWListener?
    private(set) var isRunning = false

    /// Publishes a new snapshot to be served on the next request.
    func update(_ snapshot: StatusSnapshot) { box.set(snapshot) }

    /// Starts listening on `port` (all interfaces, so a monitor on another host
    /// on the LAN can reach it). Returns false if the port is invalid or in use.
    @discardableResult
    func start(port: Int) -> Bool {
        stop()
        guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: nwPort) else { return false }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        isRunning = true
        return true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = StatusHTTP.path(from: request)
            let response = StatusHTTP.route(path, snapshot: self.box.get())
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
