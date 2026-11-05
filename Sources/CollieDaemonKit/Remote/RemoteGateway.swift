import Foundation
import Network
import Security
import CollieCore
import CollieProtocol

/// The remote listener's preference (`CollieSettings.remote`); absent = off (remote API spec §1).
struct RemoteSettings: Codable, Equatable, Sendable {
    static let defaultPort = 47820
    var enabled: Bool
    var port: Int
    var tailscaleOnly: Bool
}

/// The optional WebSocket-over-TLS door to `collied` for paired phones (remote API spec §1): source filter before TLS,
/// TLS 1.3 with the pinned identity, no `Origin` (no browsers); each connection is a `RemoteSession`.
actor RemoteGateway {
    struct Status: Sendable { var listening: Bool; var port: Int?; var error: String? }
    static let maxMessage = 256 * 1024

    /// What sessions need from the daemon, besides the identity and install id given at `apply`.
    struct Deps: Sendable {
        var devices: RemoteDevices
        var pairing: RemotePairing
        var macName: String
        var build: String
        var helloDeadline: Duration
        var onClaim: @Sendable (RemotePairingRequest) -> Void
        var handle: @Sendable (Request, RemoteDevice, RemoteVia) async -> Response
    }

    private let allowLoopback: Bool
    private let deps: Deps
    private let queue = DispatchQueue(label: "collie.remote")
    private var listener: NWListener?
    private var running: (settings: RemoteSettings, fingerprint: String)?
    private var lastError: String?
    /// Bumped by every apply/stop: an apply that resumes after a newer one (actor reentrancy at the await) drops its listener.
    private var generation = 0
    nonisolated let sessions = RemoteSessions()

    init(allowLoopback: Bool, deps: Deps) { self.allowLoopback = allowLoopback; self.deps = deps }

    var status: Status { Status(listening: listener != nil, port: listener?.port.map { Int($0.rawValue) }, error: lastError) }

    /// Listens as `s` says with `identity` (restarting when the port, filter or identity changed), or stops when off.
    /// Waits for the listener to be ready or fail (≤ 5 s); a failure is reported in `status.error`, never thrown.
    func apply(_ s: RemoteSettings, identity: RemoteIdentity?, installId: String = "") async -> Status {
        guard s.enabled, let identity else { stop(); return status }
        if let r = running, r.settings == s, r.fingerprint == identity.fingerprint, listener != nil { return status }
        stop()
        lastError = nil
        let gen = generation
        do {
            let l = try NWListener(using: parameters(identity), on: s.port == 0 ? .any : try port(s.port))
            let filter = (tailscaleOnly: s.tailscaleOnly, loopback: allowLoopback), sessions = sessions, queue = queue
            let ctx = RemoteContext(devices: deps.devices, pairing: deps.pairing, fingerprint: identity.fingerprint, installId: installId,
                                    macName: deps.macName, build: deps.build, helloDeadline: deps.helloDeadline, onClaim: deps.onClaim,
                                    handle: deps.handle)
            l.newConnectionHandler = { c in Self.accept(c, filter: filter, ctx: ctx, sessions: sessions, queue: queue) }
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

    /// Stops listening and closes every remote session (4003).
    func stop() {
        generation += 1
        listener?.stateUpdateHandler = nil
        listener?.cancel(); listener = nil; running = nil
        sessions.closeAll(.disabled)
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
    private nonisolated static func accept(_ c: NWConnection, filter: (tailscaleOnly: Bool, loopback: Bool), ctx: RemoteContext,
                                           sessions: RemoteSessions, queue: DispatchQueue) {
        guard case .hostPort(let host, _) = c.endpoint else { c.cancel(); return }
        let address = "\(host)".split(separator: "%", maxSplits: 1).first.map(String.init) ?? "\(host)"
        guard let via = RemoteAddress.via(address, tailscaleOnly: filter.tailscaleOnly, allowLoopback: filter.loopback) else { c.cancel(); return }
        let s = RemoteSession(conn: c, address: address, via: via, ctx: ctx, sessions: sessions, queue: queue)
        guard sessions.add(s) else { c.cancel(); return }
        s.start()
    }

    private final class Once: @unchecked Sendable {   // under `lock`
        private let lock = NSLock()
        private var k: CheckedContinuation<String?, Never>?
        init(_ k: CheckedContinuation<String?, Never>) { self.k = k }
        func resume(_ v: String?) { lock.withLock { let x = k; k = nil; return x }?.resume(returning: v) }
    }
}
