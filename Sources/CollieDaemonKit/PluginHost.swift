import Foundation
import CollieCore
import CollieProtocol

/// The app's end of `ui.host`: plugin commands go to it as `call` frames and come back as `reply` by call id.
/// One host at a time; a new one replaces the old, which gets `.replaced` (it stops reconnecting) and is closed.
/// Every pending call ends exactly once, removed from `pending` by whichever comes first: reply, timeout, host drop
/// or replacement, daemon stop.
/// ponytail: a call whose CLI caller went away keeps its slot until reply/timeout: the socket server neither
/// cancels the request task nor notices the disconnect of a request-mode client.
actor PluginHost {
    static let pendingCap = 64
    static let resultCap = 1 << 20

    private struct Pending { let waiter: CheckedContinuation<JSONValue, any Error>; let timer: Task<Void, Never> }
    private var conn: StreamConn?
    private var pending: [String: Pending] = [:]

    var pendingCount: Int { pending.count }   // tests

    /// `onEmit` receives the host's `emit` frames, in order.
    func attach(_ c: StreamConn, ok: Response, onEmit: @escaping @Sendable (UUID, String, JSONValue) async -> Void) {
        let old = conn
        conn = c
        failAll()   // sent to the old host: its replies will never come
        old?.send(.replaced)
        old?.closeAfterFlush()
        // Unbounded here, but bounded in bytes upstream: every frame counts against `c`'s input backpressure
        // (reading pauses past `inputHigh`) until it has been handled.
        let (frames, sink) = AsyncStream.makeStream(of: (StreamFrame, Int).self)
        Task { [weak self] in
            for await (f, n) in frames {
                switch f {
                case .reply(let id, let result, let error): await self?.reply(id, result, error)
                case .emit(let panel, let name, let payload): await onEmit(panel, name, payload)
                default: break
                }
                c.inputDone(n)
            }
        }
        c.open(ok, onFrame: { [unowned c] f in
            let n = c.frameBytes
            c.inputQueued(n)
            sink.yield((f, n))
        }, onClose: { [weak self] in
            sink.finish()
            Task { await self?.closed(c) }
        })
    }

    func call(panel: Panel, command: String, args: [String: JSONValue], timeout: Duration) async throws(ProtocolError) -> JSONValue {
        try await call(target: panel.id, command: command, args: args, timeout: timeout)
    }

    /// A command the app runs itself (`HostTarget.importer`), not a panel.
    func callApp(command: String, args: [String: JSONValue], timeout: Duration) async throws(ProtocolError) -> JSONValue {
        try await call(target: HostTarget.importer, command: command, args: args, timeout: timeout)
    }

    private func call(target: UUID, command: String, args: [String: JSONValue], timeout: Duration) async throws(ProtocolError) -> JSONValue {
        guard let c = conn else { throw ProtocolError(code: .unavailable, message: "Collie app is not running") }
        guard pending.count < Self.pendingCap else { throw ProtocolError(code: .unavailable, message: "host busy") }
        let id = UUID().uuidString
        let secs = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let shown = String(format: "%g", secs)
        do {
            return try await withCheckedThrowingContinuation { w in
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.finish(id, .failure(ProtocolError(code: .timeout, message: "'\(command)' timed out after \(shown) s")))
                }
                pending[id] = Pending(waiter: w, timer: timer)
                c.send(.call(id: id, panel: target, command: command, args: args, timeoutSeconds: secs))
            }
        } catch {
            throw (error as? ProtocolError) ?? ProtocolError(code: .internal, message: "\(error)")
        }
    }

    /// Daemon stop: closes the host, fails what is pending.
    func stop() {
        conn?.close(); conn = nil
        failAll()
    }

    private func reply(_ id: String, _ result: JSONValue?, _ error: ProtocolError?) {
        guard pending[id] != nil else { return }   // late (timed out) or unknown: dropped
        if let error { return finish(id, .failure(error)) }
        let v = result ?? .null
        // the host truncates results itself; this is the safety net
        let size = (try? JSONEncoder().encode(v).count) ?? Int.max
        finish(id, size > Self.resultCap ? .failure(ProtocolError(code: .internal, message: "plugin result exceeds 1 MiB")) : .success(v))
    }

    private func finish(_ id: String, _ r: Result<JSONValue, ProtocolError>) {
        guard let p = pending.removeValue(forKey: id) else { return }
        p.timer.cancel()
        p.waiter.resume(with: r.mapError { $0 as any Error })
    }

    private func closed(_ c: StreamConn) {
        guard conn === c else { return }   // already replaced
        conn = nil
        failAll()
    }

    private func failAll() {
        let all = pending; pending = [:]
        for p in all.values {
            p.timer.cancel()
            p.waiter.resume(throwing: ProtocolError(code: .unavailable, message: "Collie app disconnected"))
        }
    }
}

/// Max encoded size of one plugin event payload kept and broadcast (the ring holds `panelEventCap` per panel).
let pluginEventPayloadCap = 64 * 1024

extension CommandRouter {
    /// A plugin command (`browser.*`): the panel must be within the caller's reach (admin: any), then the app runs it.
    func pluginCommand(_ r: Request, plugin: PluginSpec, spec: CommandSpec, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin
        let panel = try ConnectionGraph.resolvePanel(name: str(r, "panel"), plugin: plugin.id, from: caller?.id, in: ws)
        var args = r.args; args["panel"] = nil
        return try await host.call(panel: panel, command: r.command, args: args, timeout: .seconds(spec.timeoutSeconds ?? 30))
    }

    /// A host `emit`: kept in the panel's event ring and pushed to `ui.events`. Unknown panels are ignored.
    func pluginEmitted(panel: UUID, name: String, payload: JSONValue) async {
        guard ws.panels.contains(where: { $0.id == panel }) else { return }
        // ponytail: oversized payloads are dropped, not truncated; the host keeps its events small
        guard ((try? JSONEncoder().encode(payload).count) ?? Int.max) <= pluginEventPayloadCap else { return }
        record(panel: panel, name: name, payload: payload)
        await hub.emit(.pluginEvent(panel: panel, name: name, payload: payload))
    }
}
