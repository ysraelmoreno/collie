import Foundation
import Synchronization
import OrqCore
import OrqProtocol

let forever: Double = 1e9   // seconds; a read deadline that never fires

/// A live terminal: `frames` starts with `.replay` and, after an `.overflow` or a dropped connection, reattaches
/// on its own (the new attach starts with another `.replay`, which replaces the screen). `.overflow` itself is not
/// surfaced. After `.exited` the stream stays open until `close()`.
///
/// Reads are pulled: nothing is read from the socket until the consumer asks for the next frame, so a paused
/// consumer is cut by the daemon (and reattaches) instead of buffering without bound here.
///
/// Hold the TerminalStream while consuming `frames`: its deinit closes the stream, and so does cancelling the
/// task iterating `frames`.
public final class TerminalStream: Sendable {
    public let frames: AsyncStream<StreamFrame>
    private let core: Core

    init(terminal: UUID, socket: URL, token: @escaping @Sendable () -> String?) {
        let core = Core(terminal: terminal, socket: socket, token: token)
        self.core = core
        frames = AsyncStream(unfolding: { await core.next() }, onCancel: { core.close() })
    }
    deinit { core.close() }

    /// Keyboard input, written verbatim. While reattaching it is buffered (up to 64 KiB) and flushed after the
    /// attach; past that the buffer is dropped and counted in `droppedInputBytes`.
    public func send(_ bytes: Data) { core.write(bytes) }
    /// Debounced 100 ms: only the last size is sent. The last size is re-sent after every reattach.
    public func resize(cols: UInt16, rows: UInt16) { core.resize(cols, rows) }
    /// Idempotent; releases the socket now and ends `frames`.
    public func close() { core.close() }
    /// Input bytes lost because the reattach buffer overflowed.
    public var droppedInputBytes: Int { core.dropped }

    /// Test hook: drops the connection as if the daemon went away (the stream reattaches).
    func _simulateDrop() { core.drop() }
}

private final class Core: Sendable {
    static let pendingCap = 64 * 1024
    private struct State {
        var client: StreamClient?
        var closed = false, finished = false               // finished: the reader thread is gone
        var waiter: CheckedContinuation<StreamFrame?, Never>?
        var pending = Data(), dropped = 0
        var lastSize: (cols: UInt16, rows: UInt16)?, resizeGen = 0
    }
    private let terminal: UUID, socket: URL, token: @Sendable () -> String?
    private let state = Mutex(State())
    private let demand = DispatchSemaphore(value: 0)   // one signal per `next()` (or close)
    private let wake = DispatchSemaphore(value: 0)     // interrupts a reattach backoff on close
    private let writeQueue = DispatchQueue(label: "orq.client.stream.write")

    init(terminal: UUID, socket: URL, token: @escaping @Sendable () -> String?) {
        self.terminal = terminal; self.socket = socket; self.token = token
        Thread { [self] in readLoop() }.start()   // own thread: long-lived blocking reads (cf. UnixSocketClient.offPool)
    }

    var dropped: Int { state.withLock { $0.dropped } }

    func next() async -> StreamFrame? {
        await withCheckedContinuation { c in
            let done = state.withLock { s in
                if s.finished { return true }
                s.waiter = c; return false
            }
            if done { c.resume(returning: nil) } else { demand.signal() }
        }
    }

    /// Reader thread: one frame per demand; exits (ending `frames`) once closed.
    private func readLoop() {
        while true {
            demand.wait()
            let f = nextBlocking()
            let w = state.withLock { s in
                if f == nil { s.finished = true }
                defer { s.waiter = nil }; return s.waiter
            }
            w?.resume(returning: f)
            if f == nil { return }
        }
    }

    /// The next frame, (re)attaching as needed; nil once closed.
    private func nextBlocking() -> StreamFrame? {
        var delay = 0.25
        while true {
            let (closed, current) = state.withLock { ($0.closed, $0.client) }
            if closed { return nil }
            if let current {
                if let f = try? current.nextBlocking(timeoutSeconds: forever), f != .overflow { return f }
                current.close()   // EOF, error or overflow: reattach
                state.withLock { if $0.client === current { $0.client = nil } }
                continue
            }
            do {
                let req = Request(id: "attach", token: token(), command: "ui.attach", args: ["terminal": .string(terminal.uuidString)])
                let c = try StreamClient.openBlocking(req, path: socket, timeoutSeconds: 5)
                let kept = state.withLock { s in
                    if s.closed { return false }
                    s.client = c; return true
                }
                if !kept { c.close(); return nil }
                writeQueue.async { [self] in flush(resend: true) }   // last size, then input typed meanwhile
                delay = 0.25
            } catch {
                // daemon down/restarting, token rotating, or terminal not there yet: back off, never spin
                if wake.wait(timeout: .now() + delay) == .success { wake.signal() }   // closed: leave it signalled
                delay = min(delay * 2, 2)
            }
        }
    }

    /// writeQueue: buffered input goes out before anything typed later (all sends run here, in order).
    func write(_ bytes: Data) {
        writeQueue.async { [self] in
            state.withLock { s in
                guard !s.closed else { return }
                if s.pending.count + bytes.count <= Self.pendingCap { s.pending.append(bytes) }
                else { s.dropped += s.pending.count + bytes.count; s.pending = Data() }   // never silent: counted
            }
            flush(resend: false)
        }
    }

    /// writeQueue. On a failed send the bytes go back to the buffer; the reattach flushes them.
    /// ponytail: input the daemon read after it cut the stream is lost there (it has no acks); bytes sent to a
    /// socket that was already cut are not retried.
    private func flush(resend: Bool) {
        let (c, size, data): (StreamClient?, (cols: UInt16, rows: UInt16)?, Data) = state.withLock { s in
            guard !s.closed, let c = s.client else { return (nil, nil, Data()) }
            defer { s.pending = Data() }
            return (c, resend ? s.lastSize : nil, s.pending)
        }
        guard let c else { return }
        if let size { try? c.sendBlocking(.resize(cols: size.cols, rows: size.rows), timeoutSeconds: 5) }
        guard !data.isEmpty else { return }
        do { try c.sendBlocking(.in(data), timeoutSeconds: 5) } catch {
            state.withLock { s in
                if data.count + s.pending.count <= Self.pendingCap { s.pending = data + s.pending }
                else { s.dropped += data.count }
            }
        }
    }

    func resize(_ cols: UInt16, _ rows: UInt16) {
        let gen = state.withLock { $0.lastSize = (cols, rows); $0.resizeGen += 1; return $0.resizeGen }
        writeQueue.asyncAfter(deadline: .now() + 0.1) { [self] in
            guard let c = state.withLock({ $0.resizeGen == gen && !$0.closed ? $0.client : nil }) else { return }
            try? c.sendBlocking(.resize(cols: cols, rows: rows), timeoutSeconds: 5)   // lost: re-sent on reattach
        }
    }

    func drop() { state.withLock { $0.client }?.close() }

    func close() {
        let c: StreamClient?? = state.withLock { s in
            guard !s.closed else { return .none }
            s.closed = true; s.pending = Data(); defer { s.client = nil }; return .some(s.client)
        }
        guard let c else { return }   // already closed
        c?.close()                    // shutdown: a blocked read returns nil now
        wake.signal()
        demand.signal()               // a reader waiting for demand wakes, sees closed, and exits
    }
}
