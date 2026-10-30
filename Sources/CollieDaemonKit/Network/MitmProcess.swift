import Foundation
import os
import CollieProtocol

/// One running `mitmdump`: loopback only, on a free ephemeral port, HTTP/2 off (clients fall back to HTTP/1.1), the
/// addon printing one JSON line per flow. A `LongProcess`, so a crashed daemon's mitmdump is killed by the next one's
/// orphan reap; whoever owns it calls `stop()` when the daemon stops.
/// The CA lives in `confdir` (0700; mitmdump writes the key 0600 and generates it on first start): `start` returns
/// once the proxy listens and `caCert` exists, so a device attach can use both right away.
final class MitmProcess: Sendable {
    let port: Int
    let confdir: URL
    /// stdout, line by line (the addon's JSON lines); finishes when mitmdump exits. One consumer.
    let lines: AsyncStream<String>
    private let proc: LongProcess
    private let exitCode: OSAllocatedUnfairLock<Int32?>
    private let tool: MitmTool, addon: URL, runDir: URL

    /// The CA certificate (PEM, no key) pushed to devices.
    var caCert: URL { Self.caCert(in: confdir) }
    static func caCert(in confdir: URL) -> URL { confdir.appendingPathComponent("mitmproxy-ca-cert.pem") }
    /// nil while running; else its exit code (128+signal).
    var exited: Int32? { exitCode.withLock { $0 } }

    static func args(port: Int, confdir: URL, addon: URL) -> [String] {
        ["--listen-host", "127.0.0.1", "-p", "\(port)", "--set", "confdir=\(confdir.path)", "--set", "http2=false", "-q", "-s", addon.path]
    }

    private init(tool: MitmTool, port: Int, confdir: URL, addon: URL, runDir: URL, env: [String: String]) throws(ProtocolError) {
        let (stream, cont) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(10_000))
        let code = OSAllocatedUnfairLock<Int32?>(initialState: nil)
        proc = try LongProcess(executable: tool.url, args: Self.args(port: port, confdir: confdir, addon: addon), env: env, runDir: runDir,
                               onLine: { cont.yield($0) }, onExit: { c in code.withLock { $0 = c }; cont.finish() })
        self.port = port; self.confdir = confdir; self.lines = stream; self.exitCode = code
        self.tool = tool; self.addon = addon; self.runDir = runDir
    }

    /// Writes `addonSource` to `<runDir>/network/addon.py`, prepares `confdir`, starts mitmdump on `port` (nil: a free
    /// one) and waits until it listens and the CA exists. Exiting or not ready within `ready`: the error, process stopped.
    static func start(tool: MitmTool, addonSource: String, confdir: URL, runDir: URL, port: Int? = nil,
                      ready: Duration = .seconds(20)) async throws(ProtocolError) -> MitmProcess {
        let dir = runDir.appendingPathComponent("network"), addon = dir.appendingPathComponent("addon.py")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(addonSource.utf8).write(to: addon, options: .atomic)
            try prepareConfdir(confdir)
        } catch { throw ProtocolError(code: .internal, message: "cannot prepare mitmdump files: \(error.localizedDescription)") }
        let env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("COLLIE_") }   // no tokens or socket
        let p: Int
        if let port { p = port } else { p = try freePort() }
        let m = try MitmProcess(tool: tool, port: p, confdir: confdir, addon: addon, runDir: runDir, env: env)
        let deadline = ContinuousClock.now + ready
        while true {
            if let c = m.exited {
                throw ProtocolError(code: .internal, message: "mitmdump exited (\(c)) before listening on 127.0.0.1:\(m.port)")
            }
            if FileManager.default.fileExists(atPath: m.caCert.path), listening(port: m.port) { return m }
            guard ContinuousClock.now < deadline else {
                m.stop()
                throw ProtocolError(code: .timeout, message: "mitmdump not listening on 127.0.0.1:\(m.port) after \(ready)")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// A new mitmdump on the same port, confdir and addon (this one is stopped first).
    func restarted(ready: Duration = .seconds(20)) async throws(ProtocolError) -> MitmProcess {
        stop()
        let deadline = ContinuousClock.now + .seconds(3)   // the port frees once the old group is gone (TERM, KILL after 1 s)
        while Self.listening(port: port), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        let source = (try? String(contentsOf: addon, encoding: .utf8)) ?? ""
        return try await Self.start(tool: tool, addonSource: source, confdir: confdir, runDir: runDir, port: port, ready: ready)
    }

    /// Idempotent, never blocks (`LongProcess.terminate`).
    func stop() { proc.terminate() }

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
