import Foundation
import Darwin
import OrqCore
import OrqDevice
import OrqProtocol

/// One device panel's live screen: the scrcpy server on the device (`adb shell app_process …`, a `LongProcess`), an
/// `adb forward` tunnel to it and two sockets through that tunnel. Video packets are read on a dedicated thread and fanned
/// out to the panel's `ui.device` viewers; their `in` frames are scrcpy control messages written as they came (what the
/// device sends back on control — clipboard, acks — is read and dropped).
/// Ends once (video EOF/error, server exit, connect timeout, panel closed, daemon stop, idle grace): status to the
/// viewers, server terminated, `forward --remove`, sockets shut. Never restarted: the next viewer gets a new session.
final class DeviceSession: @unchecked Sendable {   // state under `lock`; control-socket writes and its close on `controlQ`
    let panel: UUID
    let serial: String
    /// A viewer with more than this queued (unsent) loses P-frames until the next keyframe.
    static let dropAbove = 1 << 20
    /// …and takes (and asks for) a keyframe again once its queue is down to this.
    static let resumeAt = dropAbove / 2
    static let notBundled = "scrcpy-server is not bundled (run scripts/fetch-scrcpy-server.sh and rebuild)"

    private let lock = NSLock()
    private struct Viewer { let conn: StreamConn; var waitKey: Bool }
    private var viewers: [ObjectIdentifier: Viewer] = [:]
    private var state = "connecting"
    private var meta: StreamFrame?
    private var config: Data?            // the last config packet's line: a viewer joining mid-stream needs it to decode
    private var resetPending = false     // a `resetVideo` was sent and no keyframe came since
    private var ended = false
    private var adb: Adb?
    private var proc: LongProcess?
    private var port: UInt16?
    private var video: Int32 = -1, control: Int32 = -1
    private var lastLine = ""            // the server's last stdout line, for an exit message
    private var cleanupTask: Task<Void, Never>?
    private let controlQ = DispatchQueue(label: "orq.device.control")
    private let onEnd: @Sendable (DeviceSession) -> Void

    init(panel: UUID, serial: String, onEnd: @escaping @Sendable (DeviceSession) -> Void) {
        self.panel = panel; self.serial = serial; self.onEnd = onEnd
    }

    var isEnded: Bool { lock.withLock { ended } }
    var viewerCount: Int { lock.withLock { viewers.count } }
    var pid: pid_t? { lock.withLock { proc?.pid } }
    /// The end's `forward --remove` (nil before the end, or when there was no tunnel yet).
    var cleanup: Task<Void, Never>? { lock.withLock { cleanupTask } }

    /// Sets state unless the session already ended (then the caller undoes what it just made).
    private func own(_ set: () -> Void) -> Bool { lock.withLock { guard !ended else { return false }; set(); return true } }

    // MARK: viewers

    /// Adds `c` (already open). Mid-stream it gets meta, status and the last config, and a keyframe is asked for.
    /// False when the session already ended.
    func join(_ c: StreamConn) -> Bool {
        lock.withLock {
            guard !ended else { return false }
            var v = Viewer(conn: c, waitKey: false)
            if state == "streaming" {
                if let meta { c.send(meta) }
                c.send(.deviceStatus(state: state, message: nil))
                if let config { c.send(config) }
                v.waitKey = true
                requestKey()
            } else {
                c.send(.deviceStatus(state: state, message: nil))
            }
            viewers[ObjectIdentifier(c)] = v
            return true
        }
    }

    /// Viewers left.
    func leave(_ c: StreamConn) -> Int { lock.withLock { viewers[ObjectIdentifier(c)] = nil; return viewers.count } }

    /// A viewer's control message, written in order; bounded by `c`'s input backpressure. Dropped without a control socket.
    func input(_ d: Data, from c: StreamConn) {
        c.inputQueued(d.count)
        writeControl(d) { c.inputDone(d.count) }
    }

    private func requestKey() {   // lock
        guard !resetPending else { return }
        resetPending = true
        writeControl(Scrcpy.resetVideo(), done: {})
    }

    private func writeControl(_ d: Data, done: @escaping @Sendable () -> Void) {
        controlQ.async { [self] in
            defer { done() }
            let fd = lock.withLock { control }   // only closed on this queue
            guard fd >= 0 else { return }
            _ = d.withUnsafeBytes { b in
                var off = 0
                while off < b.count {   // blocking; `end` shuts the socket down, which fails a stuck write
                    let n = Darwin.write(fd, b.baseAddress! + off, b.count - off)
                    if n < 0 { if errno == EINTR { continue }; return false }
                    off += n
                }
                return true
            }
        }
    }

    // MARK: startup

    /// push → forward → server → (thread) connect, meta, control, video loop. Any failure ends the session with `error`.
    func start(adb: Adb, jar: URL?, runDir: URL) async {
        guard let jar, FileManager.default.fileExists(atPath: jar.path) else { return end("error", Self.notBundled) }
        guard own({ self.adb = adb }) else { return }
        do {
            _ = try await adb.run(["push", jar.path, Scrcpy.remoteJar], serial: serial, timeout: .seconds(60))
            guard !isEnded else { return }
            let scid = String(format: "%08x", UInt32.random(in: 0...0x7FFF_FFFF))
            let out = try await adb.run(["forward", "tcp:0", "localabstract:scrcpy_\(scid)"], serial: serial, timeout: .seconds(15)).stdout
            guard let port = UInt16(out.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0 else {
                return end("error", "adb forward printed no port: \(out.prefix(200))")
            }
            guard own({ self.port = port }) else { _ = Self.unforward(adb, serial, port); return }
            let p = try LongProcess(executable: adb.url, args: ["-s", serial, "shell"] + Scrcpy.serverArgs(scid: scid),
                                    env: ProcessInfo.processInfo.environment, runDir: runDir,
                                    onLine: { [weak self] l in self?.lock.withLock { self?.lastLine = l } },
                                    onExit: { [weak self] code in self?.serverExited(code) })
            guard own({ self.proc = p }) else { p.terminate(); return }
            Thread { [self] in runVideo(port) }.start()
        } catch {
            end("error", error.message)
        }
    }

    private func serverExited(_ code: Int32) {
        let (streaming, line) = lock.withLock { (state == "streaming", lastLine) }
        end(streaming ? "ended" : "error", "scrcpy server exited (\(code))" + (line.isEmpty ? "" : ": \(line.prefix(300))"))
    }

    /// Dedicated thread (blocking reads, never the cooperative pool).
    private func runVideo(_ port: UInt16) {
        // connect: retry every 100 ms for 5 s; adb accepts before the server listens, so an attempt only counts once
        // the server's dummy byte arrives
        // ponytail: an attempt's fd is not shut down by `end`; ending mid-connect waits out that attempt (≤ the 5 s window)
        let deadline = Date().addingTimeInterval(5)
        var v: Int32 = -1
        while v < 0 {
            if isEnded { return }
            v = Self.connect(port, dummy: true, deadline: deadline)
            if v < 0 {
                if Date() >= deadline { return end("error", "Could not connect to the scrcpy server on the device") }
                usleep(100_000)
            }
        }
        guard own({ self.video = v }) else { Darwin.close(v); return }
        defer { lock.withLock { Darwin.close(video); video = -1 } }   // `end` only shuts it down
        guard let m = Self.read(v, 12, timeout: 5), let meta = Scrcpy.codecMeta(m) else {
            return end("error", "The scrcpy server sent no video header")
        }
        guard meta.codec == 0x68323634 else { return end("error", String(format: "Unsupported video codec 0x%08x", meta.codec)) }
        Self.setTimeout(v, 0)
        let c = Self.connect(port, dummy: false, deadline: Date().addingTimeInterval(5))
        guard c >= 0 else { return end("error", "Could not open the scrcpy control socket") }
        guard own({ self.control = c }) else { Darwin.close(c); return }
        Thread { [self] in drainControl(c) }.start()
        guard own({
            state = "streaming"
            let f = StreamFrame.videoMeta(width: meta.width, height: meta.height)
            self.meta = f
            for x in viewers.values { x.conn.send(f); x.conn.send(.deviceStatus(state: "streaming", message: nil)) }
        }) else { return }

        var reader = Scrcpy.PacketReader()
        var buf = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let n = Darwin.read(v, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return end("ended", "Device disconnected") }
            do {
                for p in try reader.feed(Data(buf[0..<n])) { deliver(p) }
            } catch {
                return end("error", "Bad video stream: \(error)")
            }
        }
    }

    /// Config always goes out. A viewer more than `dropAbove` behind starts waiting for a keyframe and skips everything
    /// else; it takes a keyframe only once its queue is down to `resumeAt`, and only then is one asked for (once until
    /// the next arrives). Asking while it is still behind would make the device re-encode keyframes the viewer cannot
    /// take, each one dropped and asked for again; the gap below `dropAbove` leaves room for the keyframe itself, so
    /// taking it does not put the viewer straight back behind.
    /// ponytail: the ask rides on packet arrival; a static screen sends none, so a caught-up viewer waits for the next change
    private func deliver(_ p: Scrcpy.Packet) {
        lock.withLock {
            guard !ended else { return }
            if p.key { resetPending = false }
            var line: Data?
            func encoded() -> Data {   // once for every viewer, and only if one takes it
                if let line { return line }
                let l = StreamFrame.video(p.data, pts: p.pts, config: p.config, key: p.key).line
                line = l; return l
            }
            if p.config { config = encoded() }
            for (k, var x) in viewers {
                if !p.config {
                    let queued = x.conn.queuedBytes
                    if x.waitKey {
                        let caughtUp = queued <= Self.resumeAt
                        guard p.key, caughtUp else {
                            if caughtUp { requestKey() }
                            continue
                        }
                        x.waitKey = false
                    } else if queued > Self.dropAbove {
                        x.waitKey = true
                        viewers[k] = x
                        continue
                    }
                    viewers[k] = x
                }
                x.conn.send(encoded())
            }
        }
    }

    /// Dedicated thread: reads control replies to EOF, dropping them, then closes the socket (on `controlQ`).
    private func drainControl(_ c: Int32) {
        var b = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(c, &b, b.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
        }
        controlQ.async { [self] in lock.withLock { Darwin.close(control); control = -1 } }
    }

    // MARK: end

    /// Idempotent, from any thread.
    func end(_ st: String, _ message: String?) {
        let gone: (LongProcess?, UInt16?, Adb?)? = lock.withLock {
            guard !ended else { return nil }
            ended = true; state = st
            let f = StreamFrame.deviceStatus(state: st, message: message)
            for x in viewers.values { x.conn.send(f); x.conn.closeAfterFlush() }
            viewers = [:]
            return (proc, port, adb)
        }
        guard let (proc, port, adb) = gone else { return }
        proc?.terminate()
        // ponytail: an `adb forward` survives a daemon crash (not a clean stop) until the adb server restarts; no startup sweep of `forward --list` since official scrcpy uses the same `scrcpy_<scid>` names.
        if let port, let adb { lock.withLock { cleanupTask = Self.unforward(adb, serial, port) } }
        lock.withLock {
            if video >= 0 { Darwin.shutdown(video, SHUT_RDWR) }      // their threads close them
            if control >= 0 { Darwin.shutdown(control, SHUT_RDWR) }
        }
        onEnd(self)
    }

    private static func unforward(_ adb: Adb, _ serial: String, _ port: UInt16) -> Task<Void, Never> {
        Task { _ = try? await adb.run(["forward", "--remove", "tcp:\(port)"], serial: serial, timeout: .seconds(5)) }
    }

    // MARK: sockets

    /// A blocking TCP socket to 127.0.0.1:`port` (-1 on failure). `dummy`: valid only once one byte was read.
    private static func connect(_ port: UInt16, dummy: Bool, deadline: Date) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0, !dummy || read(fd, 1, timeout: max(0.01, deadline.timeIntervalSinceNow)) != nil else {
            Darwin.close(fd); return -1
        }
        return fd
    }

    /// Exactly `n` bytes within `timeout` seconds, or nil (EOF, error, timeout).
    private static func read(_ fd: Int32, _ n: Int, timeout: Double) -> Data? {
        setTimeout(fd, timeout)
        var out = [UInt8](repeating: 0, count: n), got = 0
        while got < n {
            let r = out.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, n - got) }
            if r < 0 && errno == EINTR { continue }
            if r <= 0 { return nil }
            got += r
        }
        return Data(out)
    }

    /// SO_RCVTIMEO (0: none).
    private static func setTimeout(_ fd: Int32, _ seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}
