import Foundation
import os
import CollieProtocol

/// One running `mitmdump`: loopback only, on a free ephemeral port, HTTP/2 off (clients fall back to HTTP/1.1), the
/// addon printing one JSON line per flow. A `LongProcess`, so a crashed daemon's mitmdump is killed by the next one's
/// orphan reap; whoever owns it calls `stop()` when the daemon stops.
/// The CA lives in `confdir` (0700; mitmdump writes the key 0600 and generates it on first start): `start` returns
/// once the proxy listens and `caCert` exists, so a device attach can use both right away.
/// stdout and stderr are one stream (run through `sh -c 'exec … 2>&1'`): the addon's JSON lines for the consumer, the
/// last other line kept for error messages. Lines are split here, not by `LongProcess` (which cuts at 64 KiB): one flow
/// line carries a whole base64 body.
final class MitmProcess: Sendable {
    let port: Int
    let confdir: URL
    /// stdout, line by line (the addon's JSON lines); finishes when mitmdump exits. One consumer, which reports what it
    /// took with `consumed(_:)`: unread lines are capped by bytes (`LineQueue`).
    let lines: AsyncStream<String>
    private let proc: LongProcess
    private let exitCode: OSAllocatedUnfairLock<Int32?>
    private let queue: LineQueue
    private let tool: MitmTool, addon: URL, runDir: URL

    /// The addon's per-body cap (`collie_body_cap` default, 10 MiB): base64 makes it 4/3, plus headers and JSON.
    static let bodyCap = 10 << 20
    static let maxLine = bodyCap * 4 / 3 + (1 << 20)
    /// Unread lines held at most (bytes); past it new lines are dropped and counted.
    static let queueLimit = 64 << 20

    /// The CA certificate (PEM, no key) pushed to devices.
    var caCert: URL { Self.caCert(in: confdir) }
    static func caCert(in confdir: URL) -> URL { confdir.appendingPathComponent("mitmproxy-ca-cert.pem") }
    /// nil while running; else its exit code (128+signal).
    var exited: Int32? { exitCode.withLock { $0 } }
    /// Lines lost: longer than `maxLine`, or arriving while `queueLimit` bytes were unread.
    var dropped: Int { queue.dropped }
    func consumed(_ line: String) { queue.consumed(line.utf8.count) }
    /// The last line that was not addon JSON (mitmdump's own errors), for messages.
    var lastNoise: String? { queue.lastNoise }

    static func args(port: Int, confdir: URL, addon: URL) -> [String] {
        ["--listen-host", "127.0.0.1", "-p", "\(port)", "--set", "confdir=\(confdir.path)", "--set", "http2=false", "-q", "-s", addon.path]
    }

    private init(tool: MitmTool, port: Int, confdir: URL, addon: URL, runDir: URL, env: [String: String]) throws(ProtocolError) {
        let (stream, cont) = AsyncStream.makeStream(of: String.self)
        let code = OSAllocatedUnfairLock<Int32?>(initialState: nil)
        let queue = LineQueue(limit: Self.queueLimit, yield: { cont.yield($0) })
        let splitter = OSAllocatedUnfairLock(initialState: LineSplitter(maxLine: Self.maxLine))
        // sh only to merge stderr into stdout (LongProcess drops stderr); exec: mitmdump keeps the pid and the group
        let sh = ["-c", "exec \"$0\" \"$@\" 2>&1", tool.url.path] + Self.args(port: port, confdir: confdir, addon: addon)
        proc = try LongProcess(executable: URL(fileURLWithPath: "/bin/sh"), args: sh, env: env, runDir: runDir,
            onData: { data in
                let (lines, overlong) = splitter.withLock { $0.feed(data) }
                queue.overlong(overlong)
                lines.forEach(queue.push)
            },
            onExit: { c in
                let (rest, overlong) = splitter.withLock { $0.finish() }
                queue.overlong(overlong); rest.forEach(queue.push)
                code.withLock { $0 = c }; cont.finish()
            })
        self.port = port; self.confdir = confdir; self.lines = stream; self.exitCode = code; self.queue = queue
        self.tool = tool; self.addon = addon; self.runDir = runDir
    }

    /// Writes `addonSource` to `<runDir>/network/addon-<port>.py` (one per running mitmdump), prepares `confdir`, starts
    /// mitmdump on `port` (nil: a free one, and one retry on another if it exits first: the port may have been taken in
    /// between) and waits until it listens and the CA exists. Exiting or not ready within `ready`: stopped, and the
    /// error carries mitmdump's last line. `runDir` is the daemon's: the orphan reap looks for the pidfile there.
    static func start(tool: MitmTool, addonSource: String, confdir: URL, runDir: URL, port: Int? = nil,
                      ready: Duration = .seconds(20)) async throws(ProtocolError) -> MitmProcess {
        do { return try await startOnce(tool: tool, addonSource: addonSource, confdir: confdir, runDir: runDir, port: port, ready: ready) }
        catch where port == nil && error.code == .internal && error.message.hasPrefix("mitmdump exited") {
            return try await startOnce(tool: tool, addonSource: addonSource, confdir: confdir, runDir: runDir, port: nil, ready: ready)
        }
    }

    private static func startOnce(tool: MitmTool, addonSource: String, confdir: URL, runDir: URL, port: Int?,
                                  ready: Duration) async throws(ProtocolError) -> MitmProcess {
        let p: Int
        if let port { p = port } else { p = try freePort() }
        let dir = runDir.appendingPathComponent("network"), addon = dir.appendingPathComponent("addon-\(p).py")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(addonSource.utf8).write(to: addon, options: .atomic)
            try prepareConfdir(confdir)
        } catch { throw ProtocolError(code: .internal, message: "cannot prepare mitmdump files: \(error.localizedDescription)") }
        let env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("COLLIE_") }   // no tokens or socket
        let m = try MitmProcess(tool: tool, port: p, confdir: confdir, addon: addon, runDir: runDir, env: env)
        let deadline = ContinuousClock.now + ready
        while true {
            if let c = m.exited {
                m.stop()   // its addon file
                throw ProtocolError(code: .internal, message: "mitmdump exited (\(c)) before listening on 127.0.0.1:\(m.port)"
                                    + (m.lastNoise.map { ": \($0.prefix(300))" } ?? ""))
            }
            if FileManager.default.fileExists(atPath: m.caCert.path), listening(port: m.port) { return m }
            guard ContinuousClock.now < deadline else {
                m.stop()
                throw ProtocolError(code: .timeout, message: "mitmdump not listening on 127.0.0.1:\(m.port) after \(ready)"
                                    + (m.lastNoise.map { ": \($0.prefix(300))" } ?? ""))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// A new mitmdump on the same port, confdir and addon (this one is stopped first).
    func restarted(ready: Duration = .seconds(20)) async throws(ProtocolError) -> MitmProcess {
        let source = (try? String(contentsOf: addon, encoding: .utf8)) ?? ""   // before stop() removes it
        stop()
        let deadline = ContinuousClock.now + .seconds(3)   // the port frees once the old group is gone (TERM, KILL after 1 s)
        while Self.listening(port: port), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        return try await Self.start(tool: tool, addonSource: source, confdir: confdir, runDir: runDir, port: port, ready: ready)
    }

    /// Idempotent, never blocks (`LongProcess.terminate`). Its addon file goes with it.
    func stop() { proc.terminate(); try? FileManager.default.removeItem(at: addon) }

    /// Creates `url` (and parents) and forces it to 0700: it holds the CA's private key.
    static func prepareConfdir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// A port the kernel hands out for 127.0.0.1, released at once for mitmdump to bind.
    // ponytail: another process may take it in between; start then fails with "exited before listening" and the caller retries
    static func freePort() throws(ProtocolError) -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProtocolError(code: .internal, message: "socket: \(errno)") }
        defer { close(fd) }
        var a = loopback(port: 0), len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard ok else { throw ProtocolError(code: .internal, message: "cannot find a free port: \(errno)") }
        return Int(UInt16(bigEndian: a.sin_port))
    }

    /// True when something accepts TCP on 127.0.0.1:`port` (loopback: refused or accepted at once).
    static func listening(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var a = loopback(port: port)
        return withUnsafePointer(to: &a) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    private static func loopback(port: Int) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_port = UInt16(port).bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return a
    }
}

/// Splits a byte stream into lines (without `\n`, `\r`). A line longer than `maxLine` is dropped whole (counted), not cut:
/// half a JSON line is no flow.
struct LineSplitter: Sendable {
    let maxLine: Int
    private var buf = Data(), skipping = false

    init(maxLine: Int) { self.maxLine = maxLine }

    /// Complete lines in `data` (with what was buffered) and how many overlong ones were dropped.
    mutating func feed(_ data: Data) -> (lines: [String], overlong: Int) {
        var out: [String] = [], overlong = 0, rest = data[...]
        while let nl = rest.firstIndex(of: 10) {
            if skipping { skipping = false } else if buf.count + (nl - rest.startIndex) > maxLine { overlong += 1 } else {
                buf.append(rest[rest.startIndex..<nl]); out.append(Self.text(buf))
            }
            buf.removeAll(keepingCapacity: true); rest = rest[(nl + 1)...]
        }
        if !skipping {
            if buf.count + rest.count > maxLine { overlong += 1; skipping = true; buf.removeAll() } else { buf.append(rest) }
        }
        return (out, overlong)
    }

    /// What is left at EOF (a last line without `\n`).
    mutating func finish() -> (lines: [String], overlong: Int) {
        defer { buf.removeAll(); skipping = false }
        return (buf.isEmpty || skipping ? [] : [Self.text(buf)], 0)
    }

    private static func text(_ d: Data) -> String {
        var d = d[...]
        if d.last == 13 { d = d.dropLast() }
        return String(decoding: d, as: UTF8.self)
    }
}

/// The lines between mitmdump's reader thread and the session's reader: at most `limit` unread bytes (what the consumer
/// has not `consumed` yet); past it a line is dropped and counted. Non-JSON lines (mitmdump's own output) are not
/// queued: the last one is kept for error messages.
final class LineQueue: Sendable {
    private struct State { var pending = 0, dropped = 0, lastNoise: String? }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let limit: Int
    private let yield: @Sendable (String) -> Void

    init(limit: Int, yield: @escaping @Sendable (String) -> Void) { self.limit = limit; self.yield = yield }

    var dropped: Int { state.withLock { $0.dropped } }
    var lastNoise: String? { state.withLock { $0.lastNoise } }

    func push(_ line: String) {
        guard line.hasPrefix("{") else {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { state.withLock { $0.lastNoise = line } }
            return
        }
        let n = line.utf8.count
        let ok = state.withLock { s in
            guard s.pending + n <= limit else { s.dropped += 1; return false }
            s.pending += n; return true
        }
        if ok { yield(line) }
    }

    func overlong(_ n: Int) { if n > 0 { state.withLock { $0.dropped += n } } }
    func consumed(_ bytes: Int) { state.withLock { $0.pending = max(0, $0.pending - bytes) } }
}
