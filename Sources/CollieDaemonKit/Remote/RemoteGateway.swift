import Foundation
import Network
import Security

/// The remote listener's preference (`CollieSettings.remote`); absent = off (remote API spec §1).
struct RemoteSettings: Codable, Equatable, Sendable {
    static let defaultPort = 47820
    var enabled: Bool
    var port: Int
    var tailscaleOnly: Bool
}

/// The optional WebSocket-over-TLS door to `collied` for paired phones (remote API spec §1). Slice 1: the listener
/// itself — source filter before TLS, TLS 1.3 with the pinned identity, no `Origin` (no browsers). The session
/// (`pair`, `session.hello`) comes in slice 3: until then any message gets close code 4000 and the socket ends.
actor RemoteGateway {
    struct Status: Sendable { var listening: Bool; var port: Int?; var error: String? }
    static let maxConnections = 16
    static let maxMessage = 256 * 1024

    private let allowLoopback: Bool
    private let queue = DispatchQueue(label: "collie.remote")
    private var listener: NWListener?
    private var running: (settings: RemoteSettings, fingerprint: String)?
    private var lastError: String?
    /// Bumped by every apply/stop: an apply that resumes after a newer one (actor reentrancy at the await) drops its listener.
    private var generation = 0
    private let conns = Conns()

    init(allowLoopback: Bool) { self.allowLoopback = allowLoopback }

    var status: Status { Status(listening: listener != nil, port: listener?.port.map { Int($0.rawValue) }, error: lastError) }

    /// Listens as `s` says with `identity` (restarting when the port, filter or identity changed), or stops when off.
    /// Waits for the listener to be ready or fail (≤ 5 s); a failure is reported in `status.error`, never thrown.
    func apply(_ s: RemoteSettings, identity: RemoteIdentity?) async -> Status {
        guard s.enabled, let identity else { stop(); return status }
        if let r = running, r.settings == s, r.fingerprint == identity.fingerprint, listener != nil { return status }
        stop()
        lastError = nil
        let gen = generation
        do {
            let l = try NWListener(using: parameters(identity), on: s.port == 0 ? .any : try port(s.port))
            let filter = (tailscaleOnly: s.tailscaleOnly, loopback: allowLoopback), conns = conns, queue = queue
            l.newConnectionHandler = { c in Self.accept(c, filter: filter, conns: conns, queue: queue) }
            let ready = await withCheckedContinuation { (k: CheckedContinuation<String?, Never>) in
                let once = Once(k)
                l.stateUpdateHandler = { st in
                    switch st {
                    case .ready: once.resume(nil)
                    case .failed(let e): once.resume("\(e)")
                    case .waiting(let e): once.resume("\(e)")
                    default: break
                    }
                }
                l.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 5) { once.resume("timed out starting the listener") }
            }
            guard gen == generation else { l.cancel(); return status }
            if let ready { l.cancel(); lastError = ready; return status }
            listener = l; running = (s, identity.fingerprint)
        } catch { lastError = "\(error)" }
        return status
    }

    /// Stops listening and closes every remote connection.
    func stop() {
        generation += 1
        listener?.stateUpdateHandler = nil
        listener?.cancel(); listener = nil; running = nil
        conns.cancelAll()
    }

    private func port(_ p: Int) throws -> NWEndpoint.Port {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: p)) else { throw NWError.posix(.EINVAL) }
        return port
    }

    private func parameters(_ id: RemoteIdentity) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        if let sid = sec_identity_create(id.identity) { sec_protocol_options_set_local_identity(sec, sid) }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = Self.maxMessage
        // a browser always sends Origin; the phone's URLSessionWebSocketTask doesn't (spec §4.1)
        ws.setClientRequestHandler(queue) { _, headers in
            headers.contains { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }
                ? NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
                : NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let p = NWParameters(tls: tls)
        p.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        p.allowLocalEndpointReuse = true
        return p
    }

    /// On `queue`. Refused before `start` (no TLS) when the source isn't LAN/Tailscale or the cap is reached.
    private nonisolated static func accept(_ c: NWConnection, filter: (tailscaleOnly: Bool, loopback: Bool), conns: Conns, queue: DispatchQueue) {
        guard case .hostPort(let host, _) = c.endpoint,
              RemoteAddress.via("\(host)", tailscaleOnly: filter.tailscaleOnly, allowLoopback: filter.loopback) != nil,
              conns.add(c, max: maxConnections) else { c.cancel(); return }
        c.stateUpdateHandler = { st in
            switch st {
            case .failed, .cancelled: conns.remove(c)
            default: break
            }
        }
        c.start(queue: queue)
        // ponytail: slice 1 has no session yet; slice 3 replaces this with pair / session.hello
        c.receiveMessage { _, _, _, _ in
            let meta = NWProtocolWebSocket.Metadata(opcode: .close)
            meta.closeCode = .privateCode(4000)
            let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
            c.send(content: nil, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
        }
    }

    /// Live connections, so turning the listener off closes them at once.
    final class Conns: @unchecked Sendable {   // under `lock`
        private let lock = NSLock()
        private var all: [ObjectIdentifier: NWConnection] = [:]
        func add(_ c: NWConnection, max: Int) -> Bool { lock.withLock { guard all.count < max else { return false }; all[ObjectIdentifier(c)] = c; return true } }
        func remove(_ c: NWConnection) { lock.withLock { _ = all.removeValue(forKey: ObjectIdentifier(c)) } }
        func cancelAll() { lock.withLock { let v = Array(all.values); all = [:]; return v }.forEach { $0.cancel() } }
    }

    private final class Once: @unchecked Sendable {   // under `lock`
        private let lock = NSLock()
        private var k: CheckedContinuation<String?, Never>?
        init(_ k: CheckedContinuation<String?, Never>) { self.k = k }
        func resume(_ v: String?) { lock.withLock { let x = k; k = nil; return x }?.resume(returning: v) }
    }
}
