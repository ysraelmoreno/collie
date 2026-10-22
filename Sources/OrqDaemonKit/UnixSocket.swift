import Foundation
import Darwin
import Dispatch
import OrqCore
import OrqProtocol

private let connectionDeadline: TimeInterval = 30

public final class UnixSocketServer: @unchecked Sendable {
    private let path: URL
    private let handler: @Sendable (Request, pid_t) async -> Response
    /// `ui.*` requests: return a Response to reply and close, or nil after calling `open` on the connection.
    let streamHandler: (@Sendable (Request, pid_t, Connection) async -> Response?)?
    private let statLock = NSLock()
    private var peak = 0
    /// High-water mark of unsent bytes queued on any one stream (diagnostics/tests).
    var streamQueuePeakBytes: Int { statLock.withLock { peak } }
    fileprivate func notePeak(_ n: Int) { statLock.withLock { peak = max(peak, n) } }
    private var inputPeak = 0
    /// High-water mark of client input accepted on any one stream but not yet written to its PTY.
    var streamInputPeakBytes: Int { statLock.withLock { inputPeak } }
    fileprivate func noteInputPeak(_ n: Int) { statLock.withLock { inputPeak = max(inputPeak, n) } }
    private let queue = DispatchQueue(label: "orq.socket.server")      // accept + reads (serial)
    private let writeQueue = DispatchQueue(label: "orq.socket.write", attributes: .concurrent)
    private var source: DispatchSourceRead?
    private var created = false
    private var acceptPaused = false     // queue-only

    public convenience init(path: URL, handler: @escaping @Sendable (Request) async -> Response) {
        self.init(path: path, peerHandler: { r, _ in await handler(r) })
    }
    /// `peerHandler` also receives the client's pid (LOCAL_PEERPID; 0 when unavailable).
    public init(path: URL, peerHandler: @escaping @Sendable (Request, pid_t) async -> Response) {
        self.path = path; self.handler = peerHandler; self.streamHandler = nil
    }
    init(path: URL, peerHandler: @escaping @Sendable (Request, pid_t) async -> Response,
         streamHandler: @escaping @Sendable (Request, pid_t, Connection) async -> Response?) {
        self.path = path; self.handler = peerHandler; self.streamHandler = streamHandler
    }

    public func start() throws {
        let dir = path.deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)

        // Existing file: live daemon -> refuse; ECONNREFUSED -> stale, remove.
        if FileManager.default.fileExists(atPath: path.path) {
            let probe = makeSocket(); defer { close(probe) }
            let rc = try withAddr(path.path) { connect(probe, $0, $1) }
            if rc == 0 || Darwin.errno == EINPROGRESS { throw ProtocolError(code: .internal, message: "daemon already running") }
            guard Darwin.errno == ECONNREFUSED else { throw sysError("probe existing socket") }
            unlink(path.path)
        }

        let fd = makeSocket()
        guard fd >= 0 else { throw sysError("socket") }
        guard try withAddr(path.path, { bind(fd, $0, $1) }) == 0 else { let e = sysError("bind"); close(fd); throw e }
        created = true
        chmod(path.path, 0o600)
        guard listen(fd, 128) == 0 else { let e = sysError("listen"); close(fd); unlink(path.path); created = false; throw e }

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll(fd) }
        src.setCancelHandler { close(fd) }
        queue.sync { source = src; acceptPaused = false }
        src.resume()
    }

    public func stop() {
        queue.sync {
            if acceptPaused { source?.resume(); acceptPaused = false }   // cancel handler never runs on a suspended source
            source?.cancel(); source = nil
        }
        if created { unlink(path.path); created = false }
    }

    private func pauseAccept() {       // queue only
        guard let src = source, !acceptPaused else { return }
        src.suspend(); acceptPaused = true
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.acceptPaused, self.source === src else { return }
            src.resume(); self.acceptPaused = false
        }
    }
    func _simulateAcceptPause() { queue.sync { pauseAccept() } }   // test hook

    private func acceptAll(_ lfd: Int32) {
        while true {
            let cfd = accept(lfd, nil, nil)
            if cfd < 0 {
                if Darwin.errno == EMFILE || Darwin.errno == ENFILE {   // level-triggered: pause to avoid CPU spin
                    pauseAccept()
                }
                return
            }
            prepare(cfd)
            var pid: pid_t = 0, len = socklen_t(MemoryLayout<pid_t>.size)
            if getsockopt(cfd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) != 0 { pid = 0 }
            Connection(fd: cfd, peer: pid, server: self).begin()
        }
    }

    /// One accepted client. Request mode: one line in, one line out, close. Stream mode (`ui.*`, after `open`):
    /// client lines -> `onFrame`; `send` queues lines (bounded) flushed by a write source. Never blocks a caller.
    final class Connection: @unchecked Sendable {     // read/source state on server.queue only; send queue under `lock`
        let fd: Int32; let peer: pid_t; let server: UnixSocketServer
        var buf = Data(); var src: DispatchSourceRead?; var timer: DispatchSourceTimer?; var done = false
        private var streaming = false, wsrc: DispatchSourceWrite?, wArmed = false, sources = 1
        private var onFrame: (@Sendable (StreamFrame) -> Void)?
        /// Wire size of the frame `onFrame` is being called with (server.queue only; read it inside `onFrame`).
        private(set) var frameBytes = 0
        // lock-guarded
        private let lock = NSLock()
        private var out = Data(), outOff = 0, cut = false, closed = false, kicked = false, draining = false
        private var midLine = false     // the last byte written was not a newline (compaction moves outOff, not this)
        private var onClose: (@Sendable () -> Void)?
        init(fd: Int32, peer: pid_t, server: UnixSocketServer) { self.fd = fd; self.peer = peer; self.server = server }

        func begin() {
            let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: server.queue)
            s.setEventHandler { [self] in readable() }
            s.setCancelHandler { [self] in sourceGone() }
            src = s; s.resume()
            let t = DispatchSource.makeTimerSource(queue: server.queue)
            t.schedule(deadline: .now() + connectionDeadline)
            t.setEventHandler { [self] in finish() }
            timer = t; t.resume()
        }
        private func sourceGone() { sources -= 1; if sources == 0 { Darwin.close(fd) } }   // fd outlives every source

        func readable() {
            guard !done else { return }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { if Darwin.errno == EAGAIN || Darwin.errno == EINTR { return }; return finish() }
            if n == 0 { return finish() }                      // EOF (request mode: before newline)
            let hasNL = chunk[0..<n].contains(10)
            buf.append(contentsOf: chunk[0..<n])
            if streaming { return frames() }
            if buf.count > maxRequestBytes + 1 { halt(); return reply(tooLarge) }
            if hasNL, let nl = buf.firstIndex(of: 10) {
                if nl > maxRequestBytes { halt(); return reply(tooLarge) }
                let line = Data(buf[buf.startIndex..<nl])
                buf = Data(buf[(nl + 1)...])                   // a stream client may pipeline frames after its request
                process(line)
            }
        }

        let tooLarge = Response(id: "", ok: false, error: ProtocolError(code: .invalidArgs, message: "request too large"))

        func process(_ line: Data) {
            halt()
            guard let req = try? JSONDecoder().decode(Request.self, from: line) else {
                return reply(Response(id: "", ok: false, error: ProtocolError(code: .invalidArgs, message: "invalid request")))
            }
            let peer = peer
            if req.command.hasPrefix("ui."), let sh = server.streamHandler {
                Task.detached { [self] in if let r = await sh(req, peer, self) { reply(r) } }   // nil: handler called open
                return
            }
            let h = server.handler
            Task.detached { [self] in reply(await h(req, peer)) }
        }
        var suspended = false
        func halt() { src?.suspend(); suspended = true; timer?.cancel(); timer = nil }   // stop reading, drop deadline

        /// Callable from any context: hops to the write queue, then back to finish.
        func reply(_ r: Response) {
            server.writeQueue.async { [self] in
                var data = (try? JSONEncoder().encode(r)) ?? Data()
                data.append(10)
                _ = writeAll(fd, data, deadline: Date().addingTimeInterval(connectionDeadline))
                server.queue.async { self.finish() }
            }
        }

        // MARK: stream mode

        static let sendCap = 4 * 1024 * 1024

        /// Turns the connection into a stream: `ok` is its first line. Frames `send` before this returns follow it.
        /// `onClose` runs once, from any thread, when the stream is cut or closed.
        func open(_ ok: Response, onFrame: @escaping @Sendable (StreamFrame) -> Void, onClose: @escaping @Sendable () -> Void) {
            var line = (try? JSONEncoder().encode(ok)) ?? Data(); line.append(10)
            lock.withLock { self.onClose = onClose; out = line + out }
            server.queue.async { [self] in
                guard !done else {     // client left while the handler ran: finish already passed, report the close
                    let cb: (@Sendable () -> Void)? = lock.withLock { defer { self.onClose = nil }; return self.onClose }
                    cb?(); return
                }
                self.onFrame = onFrame
                streaming = true
                let w = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: server.queue)
                w.setEventHandler { [self] in wsrc?.suspend(); wArmed = false; flush() }
                w.setCancelHandler { [self] in sourceGone() }
                wsrc = w; sources += 1
                w.activate(); w.suspend()                        // idle (wArmed false) until a write would block
                if suspended { src?.resume(); suspended = false }
                frames()
                flush()
            }
        }

        var isOpen: Bool { lock.withLock { !closed && !cut } }

        /// Never blocks: queues the line; past `sendCap` unsent bytes the stream is cut (best-effort `.overflow`).
        func send(_ line: Data) { enqueue(line) }
        /// Cuts the stream now (`.overflow`, then close): e.g. client input could not be delivered.
        func abort() { enqueue(nil) }
        /// `line` nil: cut.
        private func enqueue(_ line: Data?) {
            let (kick, cb): (Bool, (@Sendable () -> Void)?) = lock.withLock {
                guard !closed, !cut else { return (false, nil) }
                var cb: (@Sendable () -> Void)?
                if let line, out.count - outOff + line.count <= Self.sendCap {
                    out.append(line)
                } else {
                    // keep the rest of a half-written line so the client never sees a torn frame
                    let end = !midLine ? outOff : (out[outOff...].firstIndex(of: 10).map { $0 + 1 } ?? out.count)
                    out = Data(out[outOff..<end]) + StreamFrame.overflow.line; outOff = 0
                    cut = true; cb = onClose; onClose = nil
                }
                server.notePeak(out.count - outOff)
                defer { kicked = true }
                return (!kicked, cb)
            }
            if cb != nil {
                cb?()
                server.queue.asyncAfter(deadline: .now() + connectionDeadline) { [self] in finish() }  // reader never drains
            }
            if kick { server.queue.async { [self] in flush() } }
        }
        func send(_ f: StreamFrame) { send(f.line) }
        var isCut: Bool { lock.withLock { cut } }
        /// Bytes queued but not yet written to the client.
        var queuedBytes: Int { lock.withLock { out.count - outOff } }

        // Client input backpressure: past `inputHigh` bytes accepted but not yet written to the PTY, stop reading
        // this client (its socket fills, its writes block) until the backlog drains below `inputLow`.
        static let inputHigh = 4 * 1024 * 1024, inputLow = 1024 * 1024
        private var inPending = 0, inPaused = false   // lock

        /// An input frame of `n` bytes was accepted. Called from `onFrame` (server.queue).
        func inputQueued(_ n: Int) {
            let pause: Bool = lock.withLock {
                inPending += n
                server.noteInputPeak(inPending)
                guard inPending > Self.inputHigh, !inPaused else { return false }
                inPaused = true; return true
            }
            if pause, !suspended, !done { src?.suspend(); suspended = true }
        }
        /// `n` input bytes were written (or dropped). Any thread.
        func inputDone(_ n: Int) {
            let resume: Bool = lock.withLock {
                inPending -= n
                guard inPaused, inPending < Self.inputLow else { return false }
                inPaused = false; return true
            }
            if resume {
                server.queue.async { [self] in
                    guard !done, suspended else { return }
                    src?.resume(); suspended = false
                    frames()
                }
            }
        }
        /// From any context.
        func close() { server.queue.async { [self] in finish() } }
        /// From any context: closes once what is queued has been written (or after the connection deadline).
        func closeAfterFlush() {
            lock.withLock { draining = true }
            server.queue.async { [self] in flush() }
            server.queue.asyncAfter(deadline: .now() + connectionDeadline) { [self] in finish() }   // reader never drains
        }

        private func frames() {           // queue
            while !lock.withLock({ inPaused }), let nl = buf.firstIndex(of: 10) {
                let line = Data(buf[buf.startIndex..<nl]); buf = Data(buf[(nl + 1)...])
                if let f = try? JSONDecoder().decode(StreamFrame.self, from: line) { frameBytes = line.count + 1; onFrame?(f) }
            }
            if buf.count > maxRequestBytes { finish() }
        }

        private func flush() {            // queue
            lock.withLock { kicked = false }
            guard streaming, !done, !wArmed else { return }
            while true {
                // write under the lock (non-blocking, so brief): a concurrent cut must see the exact sent offset
                let (n, isCut, err): (Int, Bool, Int32) = lock.withLock {   // isCut: also "closing once drained"
                    if outOff > 0 && outOff * 2 >= out.count { out = Data(out[outOff...]); outOff = 0 }   // amortized compaction
                    guard outOff < out.count else { return (0, cut || draining, 0) }
                    let n = out[outOff...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                    if n > 0 { outOff += n; midLine = out[outOff - 1] != 10 }
                    return (n, cut, Darwin.errno)
                }
                if n == 0 { if isCut { finish() }; return }
                if n > 0 { continue }
                if err == EINTR { continue }
                if err == EAGAIN { wArmed = true; wsrc?.resume(); return }
                return finish()
            }
        }

        func finish() {
            guard !done else { return }
            done = true
            timer?.cancel(); timer = nil
            let cb: (@Sendable () -> Void)? = lock.withLock {
                closed = true; out = Data(); outOff = 0
                defer { onClose = nil }; return onClose
            }
            if let w = wsrc { w.cancel(); if !wArmed { w.resume() }; wsrc = nil }
            onFrame = nil
            src?.cancel()                                       // cancel handlers close fd exactly once
            if suspended { src?.resume() }
            src = nil
            cb?()
        }
    }
}
