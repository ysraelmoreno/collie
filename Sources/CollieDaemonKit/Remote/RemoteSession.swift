import Foundation
import Network
import CollieCore
import CollieProtocol

/// What every remote session of one listener shares (remote API spec §2, §3).
struct RemoteContext: Sendable {
    let devices: RemoteDevices
    let pairing: RemotePairing
    /// The listener's identity: what devices pinned.
    let fingerprint: String
    let installId: String
    let macName: String
    let build: String
    let helloDeadline: Duration
    /// A phone claimed the pairing: the app shows its dialog.
    let onClaim: @Sendable (RemotePairingRequest) -> Void
}

/// Close codes (spec §3.2). Before the WebSocket close frame the Mac sends `{"t":"closing","code","reason"}`: a native
/// client (URLSessionWebSocketTask) only surfaces the standard close codes.
enum RemoteClose: Int {
    case protocolError = 4000   // no hello in time, a request before hello, a refused hello
    case revoked = 4001
    case replaced = 4002        // a 5th session of the same device: the oldest goes
    case disabled = 4003        // listener off or restarted (identity rotated)
    var reason: String { switch self { case .protocolError: "hello"; case .revoked: "revoked"; case .replaced: "replaced"; case .disabled: "disabled" } }
}

/// One phone connection. Before `session.hello` only `pair`, `pair.wait` and `session.hello` are taken; anything else
/// closes it (4000). Messages are handled in order on `queue`, but `pair.wait`, which waits for the Mac's click.
final class RemoteSession: @unchecked Sendable {   // state under `lock`
    let conn: NWConnection
    let address: String
    let via: RemoteVia
    private let ctx: RemoteContext
    private let sessions: RemoteSessions
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var device: UUID?
    private var claimed: UUID?
    private var closing = false
    private var deadlineGen = 0

    init(conn: NWConnection, address: String, via: RemoteVia, ctx: RemoteContext, sessions: RemoteSessions, queue: DispatchQueue) {
        self.conn = conn; self.address = address; self.via = via; self.ctx = ctx; self.sessions = sessions; self.queue = queue
    }

    var deviceId: UUID? { lock.withLock { device } }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .failed, .cancelled: sessions.remove(self)
            default: break
            }
        }
        conn.start(queue: queue)
        armDeadline()
        receive()
    }

    private func armDeadline() {
        let g = lock.withLock { deadlineGen += 1; return deadlineGen }
        let c = ctx.helloDeadline.components
        queue.asyncAfter(deadline: .now() + Double(c.seconds) + Double(c.attoseconds) / 1e18) { [weak self] in
            guard let self else { return }
            if lock.withLock({ g == deadlineGen && device == nil && claimed == nil }) { close(.protocolError) }
        }
    }

    private func receive() {
        conn.receiveMessage { [weak self] data, context, _, error in   // on `queue`
            guard let self else { return }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if error != nil || meta?.opcode == .close { conn.cancel(); return }
            if let data, !data.isEmpty { handle(data) }
            if !lock.withLock({ closing }) { receive() }
        }
    }

    /// On `queue`.
    private func handle(_ data: Data) {
        guard let req = try? JSONDecoder().decode(Request.self, from: data) else {
            reply("", ProtocolError(code: .invalidArgs, message: "Not a request.")); close(.protocolError); return
        }
        guard req.v == Protocol.version else {
            return reply(req.id, ProtocolError(code: .unsupportedVersion, message: "Unsupported protocol version \(req.v)"))
        }
        guard deviceId != nil else {
            switch req.command {
            case "pair": return pair(req)
            case "pair.wait": return pairWait(req)
            case "session.hello": return hello(req)
            default:
                reply(req.id, ProtocolError(code: .unauthorized, message: "Envie session.hello primeiro."))
                return close(.protocolError)
            }
        }
        // ponytail: the allowlisted surface arrives with slice 4
        reply(req.id, ProtocolError(code: .invalidArgs, message: "Unknown command '\(req.command)'"))
    }

    private func pair(_ r: Request) {
        guard case .string(let secret)? = r.args["secret"], case .object(let d)? = r.args["device"],
              case .string(let name)? = d["name"] else {
            return reply(r.id, ProtocolError(code: .invalidArgs, message: "pair needs secret and device {name, model}"))
        }
        let model = if case .string(let m)? = d["model"] { m } else { "" }
        do {
            let claim = try ctx.pairing.claim(secret: secret, device: .init(name: name, model: model, address: address, via: via))
            lock.withLock { claimed = claim.pairingId }
            if let a = ctx.pairing.awaiting, a.pairingId == claim.pairingId {
                ctx.onClaim(RemotePairingRequest(pairingId: claim.pairingId, name: a.device.name, model: a.device.model, address: address,
                                                 via: via.rawValue, code: claim.code, deadline: Date() + RemotePairing.confirmLife))
            }
            reply(r.id, .object(["pairingId": .string(claim.pairingId.uuidString.lowercased()), "code": .string(claim.code),
                                 "via": .string(via.rawValue), "mac": macJSON(["collieVersion": .string(ctx.build)])]))
        } catch let e as ProtocolError { reply(r.id, e) } catch { reply(r.id, ProtocolError(code: .internal, message: "\(error)")) }
    }

    private func pairWait(_ r: Request) {
        guard case .string(let s)? = r.args["pairingId"], let id = UUID(uuidString: s), lock.withLock({ claimed == id }) else {
            return reply(r.id, ProtocolError(code: .notFound, message: "Pareamento não encontrado nesta conexão."))
        }
        Task { [self] in
            let o = await ctx.pairing.wait(id)
            lock.withLock { claimed = nil }
            armDeadline()   // the new device now has 10 s to hello (on this socket or another)
            switch o {
            case .accepted(let d):
                do {
                    let (dev, token) = try ctx.devices.add(d, fingerprint: ctx.fingerprint)
                    reply(r.id, .object(["deviceId": .string(dev.id.uuidString.lowercased()), "token": .string(token),
                                         "pairedAt": .string(dev.pairedAt.ISO8601Format()),
                                         "mac": macJSON(["collieVersion": .string(ctx.build), "keyFingerprint": .string(ctx.fingerprint)])]))
                } catch { reply(r.id, ProtocolError(code: .internal, message: "\(error)")) }
            case .refused: reply(r.id, ProtocolError(code: .conflict, message: "Recusado no Mac."))
            case .timedOut: reply(r.id, ProtocolError(code: .timeout, message: "O Mac não confirmou a tempo: pareie de novo."))
            case .pending, .delivered: reply(r.id, ProtocolError(code: .notFound, message: "Pareamento não encontrado."))
            }
        }
    }

    private func hello(_ r: Request) {
        guard case .string(let s)? = r.args["deviceId"], let id = UUID(uuidString: s), case .string(let token)? = r.args["token"],
              let (dev, rotate) = ctx.devices.hello(id: id, token: token, fingerprint: ctx.fingerprint, address: address, via: via) else {
            reply(r.id, ProtocolError(code: .unauthorized, message: "Aparelho não reconhecido: pareie de novo."))
            return close(.protocolError)
        }
        lock.withLock { device = id }
        for old in sessions.authenticated(self, device: id) { old.close(.replaced) }
        var o: [String: JSONValue] = ["protocol": .number(Double(Protocol.version)), "mac": macJSON(["build": .string(ctx.build)]),
                                      "device": .object(["id": .string(id.uuidString.lowercased()), "name": .string(dev.name),
                                                         "scope": .string(dev.scope.rawValue)])]
        if let rotate { o["rotate"] = .string(rotate) }
        reply(r.id, .object(o))
    }

    private func macJSON(_ extra: [String: JSONValue]) -> JSONValue {
        .object(["name": .string(ctx.macName), "installId": .string(ctx.installId)].merging(extra) { a, _ in a })
    }

    private func reply(_ id: String, _ result: JSONValue) { send(Response(id: id, ok: true, result: result)) }
    private func reply(_ id: String, _ e: ProtocolError) { send(Response(id: id, ok: false, error: e)) }
    private func send(_ r: Response) { if let d = try? JSONEncoder().encode(r) { text(d) } }

    private func text(_ d: Data, then: (@Sendable () -> Void)? = nil) {
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        conn.send(content: d, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in then?() })
    }

    /// The `closing` frame, the close frame with `code`, then the socket goes. Once.
    func close(_ code: RemoteClose) {
        guard lock.withLock({ () -> Bool in defer { closing = true }; return !closing }) else { return }
        let note = (try? JSONEncoder().encode(JSONValue.object(["t": .string("closing"), "code": .number(Double(code.rawValue)),
                                                                "reason": .string(code.reason)]))) ?? Data()
        let conn = conn
        text(note) {
            let meta = NWProtocolWebSocket.Metadata(opcode: .close)
            meta.closeCode = .privateCode(UInt16(code.rawValue))
            let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
            conn.send(content: nil, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}

/// Live sessions of a listener: the global cap, per-device order (the 5th of a device closes the oldest) and closing
/// by device (revoke) or all (off).
final class RemoteSessions: @unchecked Sendable {   // under `lock`
    static let max = 16, perDevice = 4
    private let lock = NSLock()
    private var all: [ObjectIdentifier: RemoteSession] = [:]
    private var byDevice: [UUID: [RemoteSession]] = [:]

    func add(_ s: RemoteSession) -> Bool { lock.withLock { guard all.count < Self.max else { return false }; all[ObjectIdentifier(s)] = s; return true } }

    func remove(_ s: RemoteSession) {
        lock.withLock {
            all[ObjectIdentifier(s)] = nil
            for (k, v) in byDevice { byDevice[k] = v.filter { $0 !== s }; if byDevice[k]?.isEmpty == true { byDevice[k] = nil } }
        }
    }

    /// Records `s` as `device`'s newest session; returns the ones over `perDevice` (oldest first) to close.
    func authenticated(_ s: RemoteSession, device: UUID) -> [RemoteSession] {
        lock.withLock {
            var v = (byDevice[device] ?? []).filter { $0 !== s } + [s]
            let over = v.count > Self.perDevice ? Array(v.prefix(v.count - Self.perDevice)) : []
            v.removeFirst(over.count)
            byDevice[device] = v
            return over
        }
    }

    func count(_ device: UUID) -> Int { lock.withLock { byDevice[device]?.count ?? 0 } }
    func close(device: UUID, _ code: RemoteClose) { lock.withLock { byDevice[device] ?? [] }.forEach { $0.close(code) } }
    func closeAll(_ code: RemoteClose) { lock.withLock { () -> [RemoteSession] in defer { all = [:]; byDevice = [:] }; return Array(all.values) }.forEach { $0.close(code) } }
}
