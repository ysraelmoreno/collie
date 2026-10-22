import Foundation
import Synchronization
import CollieCore
import CollieProtocol

/// The app's `ui.host` stream: runs the plugin commands the daemon forwards (`handler`, one task per call) and
/// sends plugin events. Reconnects on its own with backoff 0.25 → 2 s, re-reading the admin token per attempt.
/// The daemon keeps one host: a newer one replaces this one, which then stops for good (`status == .replaced`; the
/// app can show it and start a new HostConnection to take the role back).
public final class HostConnection: Sendable {
    public enum Status: Sendable, Equatable { case idle, connecting, connected, replaced, stopped }
    /// `timeoutSeconds`: the daemon's deadline for the call.
    public typealias Handler = @Sendable (_ panel: UUID, _ command: String, _ args: [String: JSONValue], _ timeoutSeconds: Double) async throws(ProtocolError) -> JSONValue
    /// Frames waiting to be written; past this, `emit`s are dropped (replies are bounded by the daemon's 64 pending calls).
    static let sendCap = 256

    private struct State { var client: StreamClient?; var started = false, closed = false; var queued = 0; var status = Status.idle }
    private let paths: Paths
    private let token: @Sendable () throws -> String
    private let handler: Handler
    private let state = Mutex(State())
    private let wake = DispatchSemaphore(value: 0)   // interrupts a reconnect backoff on stop
    private let writeQueue = DispatchQueue(label: "collie.client.host.write")

    public init(paths: Paths, token: @escaping @Sendable () throws -> String, handler: @escaping Handler) {
        self.paths = paths; self.token = token; self.handler = handler
    }

    public var status: Status { state.withLock { $0.status } }

    public func start() {
        let go = state.withLock { s in
            guard !s.started, !s.closed else { return false }
            s.started = true; s.status = .connecting; return true
        }
        if go { Thread { [self] in run() }.start() }   // own thread: long-lived blocking reads (cf. TerminalStream)
    }

    /// Idempotent; closes the stream (the daemon fails calls still pending) and stops reconnecting.
    public func stop() {
        let c: StreamClient?? = state.withLock { s in
            guard !s.closed else { return .none }
            s.closed = true; if s.status != .replaced { s.status = .stopped }
            defer { s.client = nil }; return .some(s.client)
        }
        guard let c else { return }
        c?.close()
        wake.signal()
    }

    /// A plugin event for `panel`. Dropped while disconnected.
    public func emit(panel: UUID, name: String, payload: JSONValue) {
        send(.emit(panel: panel, name: name, payload: payload), on: nil)
    }

    /// `on` nil: the current connection. A reply goes to the connection its call came from.
    private func send(_ f: StreamFrame, on target: StreamClient?) {
        let ok = state.withLock { s in
            if case .emit = f, s.queued >= Self.sendCap { return false }
            s.queued += 1; return true
        }
        guard ok else { return }
        writeQueue.async { [self] in
            defer { state.withLock { $0.queued -= 1 } }
            guard let c = target ?? state.withLock({ $0.client }) else { return }
            // failed or timed out: possibly mid-line, so the stream is unusable; drop it (the daemon fails what is
            // pending, the reader reconnects). 30 s: a 1 MiB reply to a loaded daemon.
            do { try c.sendBlocking(f, timeoutSeconds: 30) } catch { c.close() }
        }
    }

    private func run() {
        var delay = 0.25
        while !state.withLock({ $0.closed }) {
            do {
                let c = try StreamClient.openBlocking(Request(id: "host", token: try token(), command: "ui.host"),
                                                      path: paths.socket, timeoutSeconds: 5)
                let kept = state.withLock { s in
                    if s.closed { return false }
                    s.client = c; s.status = .connected; return true
                }
                if !kept { c.close(); return }
                delay = 0.25
                while let f = try? c.nextBlocking(timeoutSeconds: forever) {
                    if f == .replaced {   // another host took over: stop, never reconnect (no ping-pong)
                        state.withLock { if !$0.closed { $0.status = .replaced; $0.closed = true }; $0.client = nil }
                        c.close(); return
                    }
                    guard case .call(let id, let panel, let command, let args, let timeout) = f else { continue }
                    let handler = handler
                    Task { [self] in
                        let r: StreamFrame
                        do throws(ProtocolError) { r = .reply(id: id, result: try await handler(panel, command, args, timeout), error: nil) }
                        catch { r = .reply(id: id, result: nil, error: error) }
                        send(r, on: c)
                    }
                }
                c.close()
                state.withLock { if $0.client === c { $0.client = nil }; if !$0.closed { $0.status = .connecting } }
            } catch {
                // daemon down/restarting or token rotating: back off below
            }
            if wake.wait(timeout: .now() + delay) == .success { wake.signal() }   // stopped: leave it signalled
            delay = min(delay * 2, 2)
        }
    }
}
