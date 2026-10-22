import Foundation
import OrqCore
import OrqDevice
import OrqProtocol

/// Runs the `device.*` agent commands: through adb for an Android panel, simctl + AXe for an iOS Simulator one
/// (`state["platform"]`, "android" when absent). Per-panel state (UI refs) lives here; the panel's serial is in
/// its `state`. Screenshots go to `<root>/screens/<panelId>-<epochMs>.png` and die with the panel.
/// While a device panel is open its serial is watched (`watch(panels:)`): connection changes and crashes become events.
/// A panel's screen is one `ViewerSession` (`DeviceSession` on Android, `SimSession` on iOS), shared by its `ui.device` viewers (`attach`).
actor DeviceService {
    private let root: URL
    let runDir: URL
    private let pollInterval: Duration
    private let adb: @Sendable () -> URL?
    private let xcrun: URL
    private let axe: @Sendable () -> URL?
    let emulator: @Sendable () -> URL?
    /// How long a launched emulator may take to show up as booted.
    let emulatorBoot: Duration
    /// The launched emulator's environment (the daemon's minus `ORQ_*`: no tokens or socket).
    let emulatorEnv: [String: String]
    /// AVD name → its boot in progress (`bootAvd`): concurrent opens share it; it leaves when done.
    var boots: [String: Task<String, Error>] = [:]
    let emit: @Sendable (UUID, String, JSONValue) async -> Void
    var refs: [UUID: [UINode]] = [:]
    /// Panels closed so far: a command that was awaiting adb when its panel closed must not write anything afterwards.
    /// ponytail: grows by one UUID per closed device panel for the daemon's life; fine at this scale.
    var closed: Set<UUID> = []

    /// Watched panels → their serial; the last seen online state per watched serial (nil: not polled yet).
    private var watched: [UUID: String] = [:]
    private var online: [String: Bool] = [:]
    private var poller: Task<Void, Never>?
    /// iOS Simulator panels → UDID; last seen booted state per UDID; crash reports seen (oldest first, ≤ 1000); when watching began.
    private var watchedIOS: [UUID: String] = [:]
    private var booted: [String: Bool] = [:]
    private var seenIPS: [String] = []
    private var iosSince = Date()
    private let crashReports: URL
    /// Most bytes of `log show` kept (iOS `device.logcat`).
    let logCap: Int
    /// One crash watcher (`adb logcat -b crash`) per online watched serial; `id` tells a restarted one from the old one.
    private struct CrashWatch {
        let id = UUID()
        var proc: LongProcess?
        var log = CrashLog()
        var lineGen = 0
        var backoff: Duration = .seconds(2)
        var startedAt = ContinuousClock.now
        var starting = false
    }
    private var crash: [String: CrashWatch] = [:]

    private let scrcpyServer: URL?
    /// How long a session outlives its last viewer.
    private let grace: Duration
    private var sessions: [UUID: any ViewerSession] = [:]
    private var idle: [UUID: Task<Void, Never>] = [:]

    init(root: URL, runDir: URL, pollInterval: Duration = .seconds(2), scrcpyServer: URL? = nil, grace: Duration = .seconds(5),
         adb: @escaping @Sendable () -> URL?, emulator: @escaping @Sendable () -> URL? = { nil }, emulatorBoot: Duration = .seconds(180),
         emulatorEnv: [String: String]? = nil,
         xcrun: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
         axe: @escaping @Sendable () -> URL? = { nil }, crashReports: URL = Simulator.defaultCrashReports, logCap: Int = 8 << 20,
         emit: @escaping @Sendable (UUID, String, JSONValue) async -> Void) {
        self.root = root; self.runDir = runDir; self.pollInterval = pollInterval; self.adb = adb; self.emulator = emulator; self.emulatorBoot = emulatorBoot; self.emit = emit
        self.emulatorEnv = emulatorEnv ?? ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("ORQ_") }
        self.xcrun = xcrun; self.axe = axe; self.crashReports = crashReports; self.logCap = logCap
        self.scrcpyServer = scrcpyServer; self.grace = grace
    }

    var screens: URL { root.appendingPathComponent("screens") }
    /// AXe is looked up per use: it may be installed while the daemon runs.
    var sim: Simulator { Simulator(xcrun: xcrun, axe: axe()) }

    /// The session's one `adb start-server` (shared by concurrent first callers; retried after a failure).
    private var server: Task<Bool, Never>?

    /// The adb tool, with the server started (`Adb.startServer`) before its first use in this daemon session.
    func tool() async throws(ProtocolError) -> Adb {
        guard let u = adb(), FileManager.default.isExecutableFile(atPath: u.path) else { throw Adb.missing }
        let tool = Adb(url: u), t = server ?? Task { await tool.startServer() }
        server = t
        guard await t.value else {
            if server == t { server = nil }
            throw ProtocolError(code: .internal, message: "adb start-server failed")
        }
        return tool
    }

    func devices() async throws(ProtocolError) -> [AdbDevice] {
        AdbParsing.devices(try await tool().run(["devices", "-l"], serial: nil, timeout: .seconds(15)).stdout)
    }

    static func attempt<T: Sendable>(_ f: @Sendable () async throws(ProtocolError) -> T) async -> Result<T, ProtocolError> {
        do { return .success(try await f()) } catch { return .failure(error) }
    }

    /// `s`: an adb serial, `avd:<name>` (booted when off) or a simulator UDID (a simulator not booted yet is booted first); nil: the only Android device
    /// in state `device` or simulator `booted`. adb or simctl failing hides only its own devices; both failing: adb's error.
    func resolveSerial(_ s: String?) async throws(ProtocolError) -> (serial: String, platform: String) {
        if let s, s.hasPrefix("avd:") { return (try await bootAvd(String(s.dropFirst(4))), "android") }
        var adbError: ProtocolError?, simError: ProtocolError?, all: [AdbDevice] = [], sims: [SimDevice]?
        async let adbR = Self.attempt { () async throws(ProtocolError) in try await self.devices() }   // concurrent: a cold CoreSimulator must not slow Android
        async let simR = Self.attempt { () async throws(ProtocolError) in try await self.simulators() }
        switch await adbR { case .success(let v): all = v; case .failure(let e): adbError = e }
        switch await simR { case .success(let v): sims = v; case .failure(let e): simError = e }
        if let adbError, sims == nil { throw adbError }
        if let s, !s.isEmpty {
            if all.contains(where: { $0.serial == s }) { return (s, "android") }
            if let sim = sims?.first(where: { $0.udid == s }) { try await boot(sim); return (s, "ios") }
            if let simError, UUID(uuidString: s) != nil { throw simError }   // a UDID, but simctl is gone
            if let adbError { throw adbError }   // likely an Android serial, but adb is gone
            let known = all.map(\.serial) + (sims ?? []).map(\.udid)
            throw ProtocolError(code: .invalidArgs, message: "Unknown device '\(s)' (\(known.isEmpty ? "none connected" : known.joined(separator: ", ")))")
        }
        // (serial, platform, how the error lists it)
        let online = all.filter { $0.state == "device" }.map { ($0.serial, "android", $0.serial) }
            + (sims ?? []).filter { $0.state == "booted" }.map { ($0.udid, "ios", "\($0.udid) (\($0.name))") }
        switch online.count {
        case 1: return (online[0].0, online[0].1)
        case 0:
            let others = all.map { "\($0.serial) \($0.state)" } + (sims ?? []).map { "\($0.udid) (\($0.name)) \($0.state)" }
            throw ProtocolError(code: .invalidArgs, message: "No device online" + (others.isEmpty ? "" : " (" + others.joined(separator: ", ") + ")"))
        default: throw ProtocolError(code: .invalidArgs, message: "Several devices online (\(online.map(\.2).joined(separator: ", "))); pass --serial")
        }
    }

    func run(_ command: String, panel: Panel?, args: [String: JSONValue], cwd: String?) async throws(ProtocolError) -> JSONValue {
        guard let panel, case .string(let serial)? = panel.state["serial"] else {
            throw ProtocolError(code: .invalidArgs, message: "'\(command)' needs a device panel")
        }
        if panel.state["platform"] == .string("ios") { return try await runIOS(command, panel: panel, udid: serial, args: args, cwd: cwd) }
        return try await runAndroid(command, panel: panel, serial: serial, args: args, cwd: cwd)
    }

    /// Checked after every await that precedes a write: a panel closed meanwhile gets nothing written for it.
    func alive(_ panel: Panel) throws(ProtocolError) {
        if closed.contains(panel.id) { throw ProtocolError(code: .notFound, message: "Panel '\(panel.name)' was closed meanwhile") }
    }

    /// Integer in `range` (default pixels 0...100000), from a number or numeric string; nil when absent.
    static func int(_ a: [String: JSONValue], _ k: String, _ range: ClosedRange<Int> = 0...100_000) throws(ProtocolError) -> Int? {
        let v: Int?
        switch a[k] {
        case nil, .null?: return nil
        case .number(let n)?: v = Int(exactly: n)
        case .string(let s)?: v = Int(s)
        default: v = nil
        }
        guard let v, range.contains(v) else {
            throw ProtocolError(code: .invalidArgs, message: "'\(k)' must be an integer between \(range.lowerBound) and \(range.upperBound)")
        }
        return v
    }

    // MARK: video

    /// A `ui.device` viewer of `panel`: opens `conn` and joins the panel's session, starting one if there is none.
    func attach(panel: Panel, conn: StreamConn, ok: Response) {
        idle.removeValue(forKey: panel.id)?.cancel()
        let s: any ViewerSession
        let serial = { if case .string(let v)? = panel.state["serial"] { v } else { "" } }()
        if let cur = sessions[panel.id], !cur.isEnded {
            s = cur
        } else if panel.state["platform"] == .string("ios") {
            let sim = SimSession(panel: panel.id, udid: serial, onEnd: { s in Task { await self.ended(s) } })
            s = sim
            sessions[panel.id] = sim
            let tools = self.sim, runDir = runDir
            Task { await sim.start(sim: tools, runDir: runDir) }
        } else {
            let dev = DeviceSession(panel: panel.id, serial: serial, onEnd: { s in Task { await self.ended(s) } })
            s = dev
            sessions[panel.id] = dev
            let jar = scrcpyServer, runDir = runDir
            Task {
                do throws(ProtocolError) { await dev.start(adb: try await self.tool(), jar: jar, runDir: runDir) }
                catch { dev.end("error", error.message) }
            }
        }
        conn.open(ok, onFrame: { [unowned conn, weak s] f in if case .in(let d) = f { s?.input(d, from: conn) } },
                  onClose: { [weak s] in Task { if let s { await self.left(s, conn) } } })
        if !s.join(conn) {   // ended between the check and the join (another thread): tell the viewer, it reconnects
            conn.send(.deviceStatus(state: "ended", message: nil)); conn.closeAfterFlush()
        }
    }

    /// The last viewer gone: the session ends after `grace` unless one comes back.
    private func left(_ s: any ViewerSession, _ c: StreamConn) {
        guard s.leave(c) == 0, sessions[s.panel] === s else { return }
        idle[s.panel]?.cancel()
        let grace = grace
        idle[s.panel] = Task {
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            await self.idleOver(s)
        }
    }

    private func idleOver(_ s: any ViewerSession) {
        guard s.viewerCount == 0, sessions[s.panel] === s else { return }
        s.end("ended", "No viewers")
    }

    private func ended(_ s: any ViewerSession) {
        guard sessions[s.panel] === s else { return }
        sessions[s.panel] = nil
        idle.removeValue(forKey: s.panel)?.cancel()
    }

    /// The panel is gone: its session, screenshots and refs go too.
    func panelClosed(_ id: UUID) async {
        closed.insert(id)
        refs[id] = nil
        idle.removeValue(forKey: id)?.cancel()
        sessions.removeValue(forKey: id)?.end("ended", "Panel closed")
        let prefix = id.uuidString + "-"
        for f in (try? FileManager.default.contentsOfDirectory(at: screens, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.hasPrefix(prefix) { try? FileManager.default.removeItem(at: f) }
    }

    // MARK: watchers

    /// The device panels now open (any others in `panels` are ignored). Polls `adb devices -l` while there is one;
    /// watchers of serials no panel holds any more are stopped at once.
    func watch(panels: [Panel]) async {
        watched = [:]
        let hadIOS = !watchedIOS.isEmpty
        watchedIOS = [:]
        for p in panels where p.pluginId == "device" {
            guard case .string(let s)? = p.state["serial"] else { continue }
            if p.state["platform"] == .string("ios") { watchedIOS[p.id] = s } else { watched[p.id] = s }
        }
        if !hadIOS && !watchedIOS.isEmpty { iosSince = Date() }
        let udids = Set(watchedIOS.values)
        booted = booted.filter { udids.contains($0.key) }
        let wanted = Set(watched.values)
        for s in crash.keys where !wanted.contains(s) { endCrash(s) }
        online = online.filter { wanted.contains($0.key) }
        if wanted.isEmpty && udids.isEmpty {
            poller?.cancel(); poller = nil
        } else if poller == nil {
            let interval = pollInterval
            poller = Task { while !Task.isCancelled { await self.poll(); try? await Task.sleep(for: interval) } }
        }
    }

    private func poll() async { await pollAndroid(); await pollIOS() }

    /// One `adb devices -l`: a serial's first sighting is its baseline; later flips to/from `device` are events.
    private func pollAndroid() async {
        guard !watched.isEmpty, let all = try? await devices() else { return }   // adb missing/failing: try next tick
        // no await until every state change is applied: a `watch` in between must not see (or leave) a half-done poll
        var flips: [(serial: String, online: Bool, panels: [UUID])] = []
        for s in Set(watched.values) {
            let now = all.contains { $0.serial == s && $0.state == "device" }
            let was = online[s]; online[s] = now
            if !now { endCrash(s) } else if crash[s] == nil { crash[s] = CrashWatch(); Task { await self.startCrash(s) } }   // its `date` must not hold up the poll
            if let was, was != now { flips.append((s, now, watched.filter { $0.value == s }.map(\.key))) }
        }
        for f in flips {
            for id in f.panels { await emit(id, f.online ? "device.connected" : "device.disconnected", .object(["serial": .string(f.serial)])) }
        }
    }

    private func toPanels(of serial: String, _ name: String, _ payload: [String: JSONValue]) async {
        for (id, s) in watched.merging(watchedIOS, uniquingKeysWith: { a, _ in a }) where s == serial { await emit(id, name, .object(payload)) }
    }

    /// One `simctl list devices -j` (booted/shutdown flips, first sighting is the baseline) and one scan of the crash
    /// reports dir. Each applies its state with no await between reading and writing, then emits.
    private func pollIOS() async {
        guard !watchedIOS.isEmpty else { return }
        if let sims = try? await simulators() {
            var flips: [(String, Bool)] = []
            for u in Set(watchedIOS.values) {
                let now = sims.contains { $0.udid == u && $0.state == "booted" }
                let was = booted[u]; booted[u] = now
                if let was, was != now { flips.append((u, now)) }
            }
            // a shut-down simulator's `axe stream-video` may never exit by itself: its sessions end here
            for (u, on) in flips where !on {
                for (id, s) in watchedIOS where s == u { sessions[id]?.end("ended", "Simulator shut down") }
            }
            for (u, on) in flips { await toPanels(of: u, on ? "device.connected" : "device.disconnected", ["serial": .string(u)]) }
        }
        let (dir, since, seen) = (crashReports, iosSince, Set(seenIPS))
        // a report modified in the last 2 s may be half-written: left for a later poll, neither read nor marked seen
        let found = (try? await UnixSocketClient.offPool { () -> [(String, Data)] in
            let urls = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            return urls.compactMap { u in
                guard u.pathExtension == "ips", !seen.contains(u.lastPathComponent),
                      let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > since, m < Date().addingTimeInterval(-2),
                      let d = try? Data(contentsOf: u) else { return nil }
                return (u.lastPathComponent, d)
            }
        }) ?? []
        var out: [(String, CrashEvent, String)] = []
        for (name, data) in found where !seenIPS.contains(name) {
            seenIPS.append(name)
            if seenIPS.count > 1000 { seenIPS.removeFirst() }
            for u in Set(watchedIOS.values) { if let e = IPSCrash.parse(data, udid: u) { out.append((u, e, name)) } }
        }
        for (u, e, name) in out {
            await toPanels(of: u, "device.crash", ["serial": .string(u), "package": e.package.map { .string($0) } ?? .null, "text": .string(e.text),
                                                   "path": .string(dir.appendingPathComponent(name).path)])
        }
    }

    /// Starts `serial`'s crash watcher from the device's clock (`-T <epoch>`: only crashes from now on).
    /// ponytail: each (re)start takes a fresh epoch, so a crash in the restart gap is missed rather than replayed twice.
    private func startCrash(_ serial: String) async {
        guard let w = crash[serial], w.proc == nil, !w.starting, online[serial] == true,
              watched.values.contains(serial) else { return }
        crash[serial]?.starting = true
        let tool = try? await tool()
        let date = try? await tool?.run(["shell", "date", "+%s"], serial: serial, timeout: .seconds(15)).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard crash[serial]?.id == w.id else { return }   // stopped meanwhile
        crash[serial]?.starting = false
        guard let tool, let epoch = date, !epoch.isEmpty, epoch.allSatisfy(\.isASCII), epoch.allSatisfy(\.isNumber) else {
            return retry(serial, w.id)
        }
        let (lines, cont) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingOldest(4096))
        do {
            crash[serial]?.proc = try LongProcess(executable: tool.url,
                args: ["-s", serial, "logcat", "-b", "crash", "-v", "brief", "-T", "\(epoch).000"],
                env: ProcessInfo.processInfo.environment, runDir: runDir,
                onLine: { cont.yield($0) }, onExit: { _ in cont.finish() })
            crash[serial]?.startedAt = .now
        } catch { cont.finish(); return retry(serial, w.id) }
        let id = w.id
        Task {   // one consumer keeps the lines in order; the exit is handled once they are all fed
            for await line in lines { await self.crashLine(serial, id, line) }
            await self.crashExited(serial, id)
        }
    }

    private func crashLine(_ serial: String, _ id: UUID, _ line: String) async {
        guard crash[serial]?.id == id, let events = crash[serial]?.log.feed(line: line) else { return }
        crash[serial]?.lineGen += 1
        let gen = crash[serial]?.lineGen
        Task {   // a Java crash ends with the next unrelated line; when none comes, 300 ms of quiet ends it
            try? await Task.sleep(for: .milliseconds(300))
            await self.crashQuiet(serial, id, gen)
        }
        await emitCrashes(serial, events)
    }

    private func crashQuiet(_ serial: String, _ id: UUID, _ gen: Int?) async {
        guard crash[serial]?.id == id, crash[serial]?.lineGen == gen, let events = crash[serial]?.log.flush() else { return }
        await emitCrashes(serial, events)
    }

    private func emitCrashes(_ serial: String, _ events: [CrashEvent]) async {
        for e in events {
            await toPanels(of: serial, "device.crash", ["serial": .string(serial), "package": e.package.map { .string($0) } ?? .null,
                                                        "text": .string(e.text)])
        }
    }

    /// The logcat ended by itself: flush, then restart after the backoff while the device stays online.
    private func crashExited(_ serial: String, _ id: UUID) async {
        guard crash[serial]?.id == id, let events = crash[serial]?.log.flush() else { return }
        crash[serial]?.proc?.terminate()   // the leader is gone; whatever it left in its group goes too
        crash[serial]?.proc = nil
        await emitCrashes(serial, events)
        retry(serial, id)
    }

    /// Backoff 2 s doubling to 30 s; back to 2 s once a watcher has lived 30 s.
    private func retry(_ serial: String, _ id: UUID) {
        guard var w = crash[serial], w.id == id else { return }
        if ContinuousClock.now - w.startedAt >= .seconds(30) { w.backoff = .seconds(2) }
        let delay = w.backoff
        w.backoff = min(w.backoff * 2, .seconds(30)); w.startedAt = .now
        crash[serial] = w
        Task { try? await Task.sleep(for: delay); await self.startCrash(serial) }   // startCrash re-checks it is still wanted
    }

    private func endCrash(_ serial: String) { crash.removeValue(forKey: serial)?.proc?.terminate() }

    /// Daemon stop: ends every session and watcher and waits (≤ 1.5 s) for their groups, so the delayed KILL is not lost
    /// with the process; and for the sessions' `forward --remove` (≤ its 5 s adb timeout).
    func stop() async {
        refs = [:]
        watched = [:]; online = [:]; watchedIOS = [:]; booted = [:]
        poller?.cancel(); poller = nil
        let live = Array(sessions.values); sessions = [:]
        idle.values.forEach { $0.cancel() }; idle = [:]
        for s in live { s.end("ended", "Orq is shutting down") }
        for s in live { await s.cleanup?.value }
        let pids = crash.values.compactMap { $0.proc?.pid } + live.compactMap(\.pid)
        for s in Array(crash.keys) { endCrash(s) }
        let deadline = ContinuousClock.now + .milliseconds(1500)
        while pids.contains(where: { kill(-$0, 0) == 0 }) && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }
}
