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
    /// The app's version ("0.1.0"; "dev" outside a bundle) and the daemon's build hash.
    let version: String
    let build: String
    let helloDeadline: Duration
    /// A phone claimed the pairing: the app shows its dialog.
    let onClaim: @Sendable (RemotePairingRequest) -> Void
    /// An allowlisted request of a hello'd device (scope already checked): the daemon's answer.
    let handle: @Sendable (Request, RemoteDevice, RemoteVia) async -> Response
    /// `events.subscribe`'s source, and how many unsent event bytes a session may have before its subscription is cut.
    let events: RemoteEventBus
    let eventQueueBytes: Int
    /// `terminal.attach`'s source (output only); the same unsent-bytes cap applies to each attach.
    let hub: StreamHub
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
    /// Event frame bytes handed to the connection and not sent yet (bounded by `ctx.eventQueueBytes`).
    private var pendingEventBytes = 0
    /// `terminal.attach` subs by name ("t-<n>"): on `queue` only.
    private var attaches: [String: Attach] = [:]
    private var attachSeq = 0
    static let maxAttaches = 4, replayDefault = 64 << 10, replayMax = 256 << 10
    static let outEvery: DispatchTimeInterval = .milliseconds(100), outChunk = 512 << 10   // ≤ 10 frames/s; < 1 MiB frames

    init(conn: NWConnection, address: String, via: RemoteVia, ctx: RemoteContext, sessions: RemoteSessions, queue: DispatchQueue) {
        self.conn = conn; self.address = address; self.via = via; self.ctx = ctx; self.sessions = sessions; self.queue = queue
    }

    var deviceId: UUID? { lock.withLock { device } }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .failed, .cancelled: sessions.remove(self); ctx.events.remove(ObjectIdentifier(self)); detachAll()
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
            switch meta?.opcode {
            case .ping?: pong(data ?? Data())   // the phone's keepalive, at any time (before pair and hello too)
            case .text?, .binary?: if let data, !data.isEmpty { handle(data) }
            default: break   // pong, continuation
            }
            if !lock.withLock({ closing }) { receive() }
        }
    }

    /// On `queue`.
    private func handle(_ data: Data) {
        // a client frame (`in`, `resize`: the phone's keyboard and size) is not taken: output only (spec §3.5)
        if case .object(let o)? = try? JSONDecoder().decode(JSONValue.self, from: data), o["t"] != nil, o["command"] == nil { return }
        guard let req = try? JSONDecoder().decode(Request.self, from: data) else {
            reply("", ProtocolError(code: .invalidArgs, message: "Not a request.")); close(.protocolError); return
        }
        guard req.v == Protocol.version else {
            return reply(req.id, ProtocolError(code: .unsupportedVersion, message: "Unsupported protocol version \(req.v)"))
        }
        guard let devId = deviceId else {
            switch req.command {
            case "pair": return pair(req)
            case "pair.wait": return pairWait(req)
            case "session.hello": return hello(req)
            default:
                reply(req.id, ProtocolError(code: .unauthorized, message: "Envie session.hello primeiro."))
                return close(.protocolError)
            }
        }
        // the device as stored now: a revoke or a scope change made while this session is open applies here
        guard let dev = ctx.devices.device(devId, fingerprint: ctx.fingerprint) else {
            reply(req.id, ProtocolError(code: .unauthorized, message: "Aparelho revogado: pareie de novo."))
            return close(.revoked)
        }
        guard let kind = RemoteSurface.commands[req.command] else {
            return reply(req.id, ProtocolError(code: .invalidArgs, message: "Unknown command '\(req.command)'"))
        }
        guard kind == .read || dev.scope == .full else {
            return reply(req.id, ProtocolError(code: .unauthorized, message: "Este aparelho é só de leitura: mude no Mac (Preferências → Celular)."))
        }
        switch req.command {
        case "events.subscribe":
            ctx.events.add(ObjectIdentifier(self)) { [weak self] e in self?.event(e) }
            return reply(req.id, .object(["sub": .string("ev")]))
        case "events.unsubscribe":
            ctx.events.remove(ObjectIdentifier(self))
            return reply(req.id, .object([:]))
        case "terminal.attach": return attach(req)
        case "terminal.detach": return detach(req)
        default: break
        }
        let via = via, handle = ctx.handle
        Task { [weak self] in self?.send(await handle(req, dev, via)) }
    }

    /// One published event (any thread). The device is re-read (a revoke closes, 4001); past `eventQueueBytes` unsent,
    /// the subscription is cut with `{"t":"overflow","sub":"ev"}` and the phone re-snapshots and subscribes again.
    private func event(_ e: JSONValue) {
        guard let id = deviceId, ctx.devices.device(id, fingerprint: ctx.fingerprint) != nil else { return close(.revoked) }
        guard let frame = try? JSONEncoder().encode(JSONValue.object(["t": .string("event"), "sub": .string("ev"), "e": e])) else { return }
        let cap = ctx.eventQueueBytes, n = frame.count
        let over = lock.withLock { () -> Bool in
            guard !closing else { return false }
            if pendingEventBytes + n > cap { return true }
            pendingEventBytes += n
            return false
        }
        if over {
            ctx.events.remove(ObjectIdentifier(self))
            if let d = try? JSONEncoder().encode(JSONValue.object(["t": .string("overflow"), "sub": .string("ev")])) { text(d) }
            return
        }
        text(frame) { [weak self] in self?.lock.withLock { self?.pendingEventBytes -= n } }
    }

    /// One `terminal.attach`: output bytes wait in `buf` and go out at most every `outEvery` (joined, nothing dropped)
    /// once the reply and the replay went; past `eventQueueBytes` waiting or unsent, the sub is cut (`overflow`).
    private final class Attach: @unchecked Sendable {   // on `queue` only
        let sub: String, terminal: UUID
        var ready = false, done = false, scheduled = false
        var buf = Data(), unsent = 0, exitCode: Int32?
        var last = DispatchTime(uptimeNanoseconds: 0)
        init(sub: String, terminal: UUID) { self.sub = sub; self.terminal = terminal }
    }

    private func attach(_ r: Request) {   // on `queue`
        guard case .string(let s)? = r.args["terminal"], let tid = UUID(uuidString: s) else {
            return reply(r.id, ProtocolError(code: .invalidArgs, message: "terminal.attach needs terminal (its id)"))
        }
        var want = Self.replayDefault
        if let v = r.args["replayBytes"] {
            guard case .number(let n) = v, n >= 0, n == n.rounded() else {
                return reply(r.id, ProtocolError(code: .invalidArgs, message: "replayBytes: a whole number ≥ 0"))
            }
            want = min(Int(n), Self.replayMax)
        }
        guard attaches.count < Self.maxAttaches else {
            return reply(r.id, ProtocolError(code: .tooMany, message: "\(Self.maxAttaches) terminais já abertos nesta conexão: feche um."))
        }
        attachSeq += 1
        let a = Attach(sub: "t-\(attachSeq)", terminal: tid), q = queue, hub = ctx.hub, key = ObjectIdentifier(a)
        attaches[a.sub] = a
        let tap = Fanout.Tap(out: { [weak self] d in q.async { self?.out(a, d) } },
                             exited: { [weak self] c in q.async { self?.exited(a, c) } })
        Task { [weak self] in
            let res = await hub.attachRemote(tid, key: key, replayBytes: want, tap)
            q.async { [weak self] in
                guard let self else { return }
                switch res {
                case .notFound, .notRunning:
                    attaches[a.sub] = nil; a.done = true
                    if case .notFound = res { reply(r.id, ProtocolError(code: .notFound, message: "Terminal não encontrado.")) }
                    else { reply(r.id, ProtocolError(code: .notRunning, message: "Terminal parado: sem saída ao vivo.")) }
                case .attached(let replay, let truncated):
                    guard !a.done, !lock.withLock({ closing }) else { Task { await hub.detachRemote(tid, key: key) }; return }
                    reply(r.id, .object(["sub": .string(a.sub)]))
                    frame(["t": .string("replay"), "sub": .string(a.sub), "d": .string(replay.base64EncodedString()), "truncated": .bool(truncated)])
                    a.ready = true
                    if let c = a.exitCode { exited(a, c) } else { schedule(a) }
                }
            }
        }
    }

    private func detach(_ r: Request) {   // on `queue`
        guard case .string(let sub)? = r.args["sub"], let a = attaches[sub] else {
            return reply(r.id, ProtocolError(code: .notFound, message: "Assinatura não encontrada."))
        }
        drop(a)
        reply(r.id, .object([:]))
    }

    private func out(_ a: Attach, _ d: Data) {   // on `queue`
        guard !a.done else { return }
        a.buf.append(d)
        if a.buf.count + a.unsent > ctx.eventQueueBytes { return overflow(a) }
        schedule(a)
    }

    private func schedule(_ a: Attach) {
        guard a.ready, !a.done, !a.scheduled, !a.buf.isEmpty else { return }
        a.scheduled = true
        queue.asyncAfter(deadline: max(.now(), a.last + Self.outEvery)) { [weak self] in a.scheduled = false; self?.flush(a) }
    }

    private func flush(_ a: Attach) {
        guard !a.done, !a.buf.isEmpty else { return }
        guard let id = deviceId, ctx.devices.device(id, fingerprint: ctx.fingerprint) != nil else { return close(.revoked) }
        let all = a.buf
        a.buf = Data(); a.last = .now()
        var i = all.startIndex
        while i < all.endIndex {
            let j = all.index(i, offsetBy: Self.outChunk, limitedBy: all.endIndex) ?? all.endIndex
            let n = frame(["t": .string("out"), "sub": .string(a.sub), "d": .string(all[i..<j].base64EncodedString())]) { a.unsent -= $0 }
            a.unsent += n
            i = j
        }
    }

    private func exited(_ a: Attach, _ code: Int32) {   // on `queue`
        guard !a.done else { return }
        guard a.ready else { a.exitCode = code; return }
        flush(a)   // what came before the exit, now
        a.done = true; attaches[a.sub] = nil
        frame(["t": .string("exited"), "sub": .string(a.sub), "code": .number(Double(code))])
    }

    private func overflow(_ a: Attach) {
        drop(a)
        frame(["t": .string("overflow"), "sub": .string(a.sub)])
    }

    private func drop(_ a: Attach) {   // on `queue`
        a.done = true; a.buf = Data(); attaches[a.sub] = nil
        let hub = ctx.hub, t = a.terminal, k = ObjectIdentifier(a)
        Task { await hub.detachRemote(t, key: k) }
    }

    private func detachAll() { attaches.values.forEach(drop) }   // on `queue`

    /// A pushed frame; `sent` gets its size once the connection took it. Returns its size.
    @discardableResult
    private func frame(_ o: [String: JSONValue], sent: (@Sendable (Int) -> Void)? = nil) -> Int {
        guard let d = try? JSONEncoder().encode(JSONValue.object(o)) else { return 0 }
        let n = d.count
        text(d) { sent?(n) }
        return n
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
                                 "via": .string(via.rawValue), "mac": macJSON([:])]))
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
                                         "mac": macJSON(["keyFingerprint": .string(ctx.fingerprint)])]))
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
        var o: [String: JSONValue] = ["protocol": .number(Double(Protocol.version)), "mac": macJSON([:]),
                                      "device": .object(["id": .string(id.uuidString.lowercased()), "name": .string(dev.name),
                                                         "scope": .string(dev.scope.rawValue)])]
        if let rotate { o["rotate"] = .string(rotate) }
        reply(r.id, .object(o))
    }

    private func macJSON(_ extra: [String: JSONValue]) -> JSONValue {
        .object(["name": .string(ctx.macName), "installId": .string(ctx.installId), "collieVersion": .string(ctx.version),
                 "build": .string(ctx.build)].merging(extra) { a, _ in a })
    }

    /// Answers a ping with its payload. autoReplyPing is off: with it on, Network.framework sent the pong only when the
    /// connection closed (measured: 2 s, at the hello deadline), so the phone's keepalive saw no answer (E2E, 2026-11-05).
    private func pong(_ payload: Data) {
        let ctx = NWConnection.ContentContext(identifier: "pong", metadata: [NWProtocolWebSocket.Metadata(opcode: .pong)])
        conn.send(content: payload, contentContext: ctx, isComplete: true, completion: .idempotent)
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
        ctx.events.remove(ObjectIdentifier(self))
        let note = (try? JSONEncoder().encode(JSONValue.object(["t": .string("closing"), "code": .number(Double(code.rawValue)),
                                                                "reason": .string(code.reason)]))) ?? Data()
        queue.async { [weak self] in self?.detachAll() }
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
