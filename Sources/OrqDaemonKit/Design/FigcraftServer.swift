import Foundation
import Darwin
import OrqProtocol

/// Supervises the local `figcraft-server` (design files, share links, live sessions), started on first use.
/// It listens on 127.0.0.1 only, on the port it last bound (kept in `<dataDir>/orq-port`, so links keep working across
/// daemon restarts) while that is free, else `port` or the next free one up to `port + 99`; its key comes from
/// `figcraft-server key` each start (the server keeps it in its data dir). Up once `GET /healthz` answers (within 10 s).
/// A server that dies is started again on its own (the Design panel's page reconnects), after a delay doubling from
/// 1 s to 30 s per failure in a row, until it is up or `stop`; calls inside that window fail fast (`.unavailable`
/// "design engine restarting, retry in Ns").
actor FigcraftServer {
    static let notBundled = ProtocolError(code: .unavailable,
                                          message: "Design engine not bundled (run scripts/build-figcraft.sh and rebuild)")
    private static let stopped = ProtocolError(code: .unavailable, message: "design engine stopped")
    typealias Endpoint = (wsURL: String, key: String)

    private let binary: URL, dataDir: URL, runDir: URL, basePort: UInt16
    private let env: [String: String]
    private var proc: LongProcess?
    private var current: Endpoint?
    private var starting: Task<Result<Endpoint, ProtocolError>, Never>?
    /// Which start `proc` is: an exit report from an older one is ignored.
    private var generation = 0
    private var startedAt = ContinuousClock.now
    private var crashes = 0
    private var crashedAt: ContinuousClock.Instant?
    /// The start scheduled after a crash (cancelled by `stop`).
    private var restart: Task<Void, Never>?
    /// The port the last server came up on (this daemon's, else `<dataDir>/orq-port`): a restart keeps it while it is free.
    private var lastBound: UInt16?
    private var portFile: URL { dataDir.appendingPathComponent("orq-port") }
    /// Servers started so far: a client made under an older one rejoins (its session went with that server).
    private var starts = 0

    /// `env` is added to the daemon's environment for the server (tests: the fake's knobs).
    init(binary: URL, dataDir: URL, runDir: URL, port: UInt16 = 47900, env: [String: String] = [:]) {
        self.binary = binary; self.dataDir = dataDir; self.runDir = runDir; self.basePort = port
        self.env = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
    }

    /// Held by a backup export while it copies the server's data: no start meanwhile (callers retry).
    private var held = false
    func hold(_ on: Bool) { held = on }

    func ensureRunning() async throws(ProtocolError) -> Endpoint {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw Self.notBundled }
        if held { throw ProtocolError(code: .unavailable, message: "design engine: backup in progress, retry") }
        if let current { return current }
        if starting == nil, let at = crashedAt {
            let left = backoff - (ContinuousClock.now - at)
            if left > .zero {
                let secs = Int((Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18).rounded(.up))
                throw ProtocolError(code: .unavailable, message: "design engine restarting, retry in \(secs)s")
            }
        }
        let t = starting ?? Task { await self.start() }
        starting = t
        let r = await t.value
        if starting == t { starting = nil }
        return try r.get()
    }

    /// Up and answering (a backup export stops it while copying, and starts it again only if it was).
    var isRunning: Bool { current != nil }

    /// `ensureRunning`, with which start of the server answered.
    func running() async throws(ProtocolError) -> (Endpoint, generation: Int) {
        let e = try await ensureRunning()
        return (e, starts)
    }

    /// TERM to the server, KILL if its group is still there after 2 s (awaited: the daemon exits right after `stop`, so
    /// `LongProcess`'s own delayed KILL would never fire). A start in flight gives up; a later `ensureRunning` starts one at once.
    func stop() async {
        generation += 1
        let p = proc
        starting?.cancel()   // its healthz wait ends now; its callers get `stopped`
        restart?.cancel(); restart = nil
        proc = nil; current = nil; starting = nil; crashes = 0; crashedAt = nil
        guard let p else { return }
        p.terminate()
        let deadline = ContinuousClock.now + .seconds(2)
        while kill(-p.pid, 0) == 0 && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        if kill(-p.pid, 0) == 0 { kill(-p.pid, SIGKILL) }
    }

    private func start() async -> Result<Endpoint, ProtocolError> {
        generation += 1
        let gen = generation
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try? FileManager.default.removeItem(at: dataDir.appendingPathComponent("key"))   // an older build's copy of the key
            let key = try await fetchKey()
            guard gen == generation else { throw Self.stopped }
            let preferred = lastBound ?? (try? String(contentsOf: portFile, encoding: .utf8)).flatMap { UInt16($0) }
            guard let port = preferred.flatMap({ Self.isFree($0) ? $0 : nil }) ?? Self.freePort(from: basePort) else {
                throw ProtocolError(code: .unavailable, message: "design engine: no free port in \(basePort)...\(Self.lastPort(basePort))")
            }
            let p = try LongProcess(executable: binary, args: ["--listen", "127.0.0.1:\(port)", "--data", dataDir.path],
                                    env: env, runDir: runDir, onLine: { _ in },
                                    onExit: { [weak self] _ in Task { await self?.exited(gen) } })
            proc = p; startedAt = .now
            let up = await Self.healthy(port, within: .seconds(10))
            guard gen == generation else { p.terminate(); throw Self.stopped }
            guard up else {
                p.terminate(); exited(gen)
                throw ProtocolError(code: .unavailable, message: "design engine did not start (no answer on 127.0.0.1:\(port))")
            }
            lastBound = port; starts += 1
            try? Data(String(port).utf8).write(to: portFile)
            current = (wsURL: "ws://127.0.0.1:\(port)/?key=\(key)", key: key)
            return .success(current!)
        } catch let e as ProtocolError {
            return .failure(e)
        } catch {
            return .failure(ProtocolError(code: .internal, message: "design engine: \(error.localizedDescription)"))
        }
    }

    private func exited(_ gen: Int) {
        guard gen == generation, proc != nil else { return }
        proc = nil; current = nil
        failed(longRun: ContinuousClock.now - startedAt >= .seconds(60))
    }

    private var backoff: Duration { .seconds(min(30, 1 << min(crashes - 1, 5))) }

    /// Counts a failure (a long run first resets the backoff) and starts the server again once the backoff is over.
    private func failed(longRun: Bool = false) {
        crashes = longRun ? 1 : crashes + 1
        crashedAt = .now
        restart?.cancel()
        let wait = backoff
        restart = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.restartNow()
        }
    }

    /// Runs inside `restart`: a failure that did not schedule the next try itself (`exited` does) schedules it here.
    private func restartNow() async {
        do { _ = try await ensureRunning() } catch {
            if !Task.isCancelled { failed() }   // cancelled: stopped, or `exited` already scheduled a new one
        }
    }

    /// `figcraft-server key --data <dataDir>`: the publish address it prints carries `key=<key>` (the same each time
    /// for a data dir: the server keeps it there; Orq keeps no copy).
    private func fetchKey() async throws(ProtocolError) -> String {
        let r = try await BoundedProcess.run(executable: binary, args: ["key", "--data", dataDir.path], in: dataDir, env: env,
                                             timeout: .seconds(10), cap: 64 * 1024)
        guard r.status == 0, let m = r.stdout.firstMatch(of: /key=([A-Za-z0-9_\-]+)/) else {
            throw ProtocolError(code: .unavailable, message: "design engine: no server key (\(r.stderr.prefix(200)))")
        }
        return String(m.1)
    }

    /// First port from `base` that a loopback listener can bind (`SO_REUSEADDR`, like the server: TIME_WAIT is not busy).
    /// ponytail: probe-then-bind races another process taking the port in between; the healthz wait then fails this start
    private static func lastPort(_ base: UInt16) -> UInt16 { UInt16(min(Int(base) + 99, Int(UInt16.max))) }

    static func freePort(from base: UInt16) -> UInt16? {
        (base...lastPort(base)).first(where: isFree)
    }

    private static func isFree(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &a) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return ok == 0
    }

    private static let http: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]; c.timeoutIntervalForRequest = 1
        return URLSession(configuration: c)
    }()

    private static func healthy(_ port: UInt16, within: Duration) async -> Bool {
        let deadline = ContinuousClock.now + within
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/healthz")!)
        req.setValue("close", forHTTPHeaderField: "Connection")   // a kept-alive connection holds the server's TERM shutdown
        while ContinuousClock.now < deadline && !Task.isCancelled {
            if let (_, r) = try? await http.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
