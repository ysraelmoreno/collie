import Foundation
import CollieCore
import CollieProtocol
import CollieTerminal

public struct DaemonConfig: Sendable {
    public var paths: Paths
    public var collieExecutable: URL
    /// `BuildID` of the running executable, reported in `ui.snapshot` (collied computes it once at startup).
    public var build: String?
    public var workspaceId: UUID
    public var idleQuietSeconds: Double = 2.0
    /// How long a timed-out turn keeps its target's ask slot (lost hook / hung agent).
    public var heldMaxSeconds: Double = 600
    /// How long a Claude capture block holds the terminal's queued asks when the continued Stop never comes.
    public var captureHoldSeconds: Double = 120
    public var memoryCapBytes: Int = 1_048_576
    /// How long a terminal input write may block on a full tty before the stream is cut.
    public var writeStall: Duration = .seconds(2)
    /// Login shell for the shell preset and for `-lc` commands.
    /// The adb binary; nil = `Adb.locate` (tests point it at a fake).
    public var adbPath: URL?
    /// The Android `emulator` binary; nil = `Emulator.locate` (tests point it at a fake).
    public var emulatorPath: URL?
    /// How long a launched emulator may take to finish booting (tests shorten it).
    public var emulatorBoot: Duration = .seconds(180)
    /// The launched emulator's environment; nil = the daemon's minus `COLLIE_*` (tests pass their fakes' inputs).
    public var emulatorEnv: [String: String]?
    /// `xcrun` for `simctl` (tests point it at a fake).
    public var xcrunPath = URL(fileURLWithPath: "/usr/bin/xcrun")
    /// The AXe binary; nil = `Simulator.locateAXe`.
    public var axePath: URL?
    /// Where the host writes `.ips` crash reports (iOS Simulator crashes are read from here).
    public var crashReportsDir = Simulator.defaultCrashReports
    /// Most bytes of an iOS Simulator `log show` kept (tests shrink it).
    public var deviceLogCap = 8 << 20
    /// How often the device watcher polls `adb devices -l` while a device panel is open.
    public var devicePollInterval: Duration = .seconds(2)
    /// The scrcpy-server jar pushed to devices for video; nil/missing: device panels report it is not bundled.
    public var scrcpyServer: URL?
    /// `collie-ctty` (next to collied): terminals start through it so the PTY is their controlling terminal
    /// (resizes reach them as SIGWINCH); nil: started directly (tests).
    public var cttyHelper: URL?
    /// Who may present the admin token besides the session check: the bundled daemon checks the app's signature
    /// (`SignedAppCheck`); nil: off (dev runs, tests).
    public var adminPeerCheck: (any AdminPeerCheck)?
    /// How long a device video session outlives its last viewer.
    public var deviceGrace: Duration = .seconds(5)
    /// The bundled figcraft (`bin/figcraft-server`, `bin/figcraft-cli`, `web/`); nil/missing: design commands report it is not bundled.
    public var figcraftDir: URL?
    /// How long a caller's design client may sit unused before it is closed.
    public var designIdle: Duration = .seconds(300)
    /// Longest any design command may take (tests shrink it); nil: each command's own timeout.
    public var designTimeoutCap: Duration?
    public var shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    /// false: agents get only Collie's keys, no `$SHELL -ilc` capture (process tests: never the developer's rc files).
    public var captureUserEnv = true
    /// How long `herd.apply` waits for each new terminal to be ready (tests shorten it).
    public var herdReady: Duration = .seconds(60)
    /// The home a sandboxed terminal's profile closes (collied: the user's); nil: terminals start unsandboxed (tests,
    /// which pass a fake home in a temp dir when they test the sandbox, R2).
    public var sandboxHome: URL?
    /// Watch sandbox denials with `log stream` (collied, with the sandbox on): the app's access cards.
    public var watchDenials = false
    /// The denial lines (ndjson) in place of `log stream` (tests); nil: `watchDenials` decides.
    var denialSource: (@Sendable () -> AsyncStream<String>)?
    /// First restart delay of a `log stream` that ended (doubles to 60 s).
    var denialBackoff: Duration = .seconds(1)
    /// Runs `/usr/bin/open` for `collie open` (tests record instead).
    var opener: @Sendable ([String]) async throws(ProtocolError) -> Void = OpenCommand.live
    /// Captures the user's interactive environment for agent launches (unit tests replace it).
    var envRunner: UserEnvironment.Runner = UserEnvironment.live
    /// The on-device model for summary rewrites (tests pass a fake).
    var localModel: any LocalModel = FoundationLocalModel()
    public init(paths: Paths, collieExecutable: URL, workspaceId: UUID) {
        self.paths = paths; self.collieExecutable = collieExecutable; self.workspaceId = workspaceId
    }
}

public final class Daemon: Sendable {
    private let auth: AuthRegistry
    private let registry: TerminalRegistry
    private let asks: AskCoordinator
    private let hub: StreamHub
    private let server: UnixSocketServer
    let router: CommandRouter   // tests feed plugin events through it (`record`)
    private let hooksDir: URL
    private let root: URL
    private let runDir: URL
    private let spillDir: URL
    public var adminToken: String { auth.adminToken }
    /// The refusal of the admin token from anything but the app.
    static let notAppMessage = "admin commands are only accepted from the Collie app: use the app (comandos de admin só pelo app Collie)"

    private let config: DaemonConfig

    public init(config: DaemonConfig) throws {
        self.config = config
        let auth = AuthRegistry(adminTokenFile: config.paths.adminTokenFile)
        let store = WorkspaceStore(paths: config.paths)
        let wsDir = config.paths.workspaceDir(config.workspaceId)
        let spillDir = wsDir.appendingPathComponent("terminals")
        let registry = TerminalRegistry(spillDir: spillDir,
                                        memoryCapBytes: config.memoryCapBytes, runDir: config.paths.runDir,
                                        writeStall: config.writeStall, cttyHelper: config.cttyHelper?.path)
        // ponytail: a corrupt/missing workspace.json starts a fresh workspace.
        let loaded = (try? Data(contentsOf: wsDir.appendingPathComponent("workspace.json")))
            .flatMap { try? JSONDecoder().decode(Workspace.self, from: $0) }
        var ws = loaded ?? Workspace(id: config.workspaceId, name: "default")
        // repair: a canvas panel left on a paddock that no longer exists (before paddock.delete moved them) goes to pasture
        let paddockIds = Set(ws.paddocks.map(\.id))
        for i in ws.panels.indices where ws.panels[i].paddockId.map({ !paddockIds.contains($0) }) == true { ws.panels[i].paddockId = nil }
        // headless panels close with their terminals, and a previous daemon's terminals all died with it
        let headless = Set(ws.panels.filter { $0.placement == .headless }.map(\.id))
        ws.panels.removeAll { headless.contains($0.id) }
        ws.connections.removeAll { headless.contains($0.a) || headless.contains($0.b) }
        for id in headless { CommandRouter.removeScreenshots(of: id, root: config.paths.root) }
        let asks = AskCoordinator(idleQuietSeconds: config.idleQuietSeconds, heldMaxSeconds: config.heldMaxSeconds,
                                  captureHoldSeconds: config.captureHoldSeconds)
        // a replay (base64 of the whole memory tail) must always fit the stream send queue on its own
        precondition(config.memoryCapBytes / 3 * 4 + 64 * 1024 < UnixSocketServer.Connection.sendCap,
                     "memoryCapBytes too large for the stream send queue")
        let hub = StreamHub(asks: asks)
        let userEnv = UserEnvironment(shell: config.shell, home: URL(fileURLWithPath: NSHomeDirectory()),
                                      run: config.captureUserEnv ? config.envRunner : UserEnvironment.empty)
        let router = CommandRouter(config: config, auth: auth, registry: registry, store: store, asks: asks, hub: hub,
                                   workspace: ws, userEnv: userEnv)
        self.auth = auth; self.registry = registry; self.asks = asks; self.hub = hub; self.router = router
        self.root = config.paths.root; self.runDir = config.paths.runDir; self.spillDir = spillDir
        self.hooksDir = config.paths.root.appendingPathComponent("hooks")
        // the admin token alone is not enough: only from the app (when a check is configured), on every path
        let check = config.adminPeerCheck, admin = auth.adminToken
        @Sendable func notApp(_ r: Request, _ peer: Peer) async -> Response? {
            guard let check, let t = r.token, constantTimeEqual(t, admin), await !check.allows(peer) else { return nil }
            return Response(id: r.id, ok: false, error: ProtocolError(code: .unauthorized, message: Self.notAppMessage))
        }
        self.server = UnixSocketServer(path: config.paths.socket,
                                       peerHandler: { r, p in if let no = await notApp(r, p) { return no }; return await router.handle(r, peer: p.pid) },
                                       streamHandler: { r, p, c in if let no = await notApp(r, p) { return no }; return await router.stream(r, peer: p.pid, conn: c) })
    }

    // Test/diagnostic accessors (Task 8+ route through the registry directly).
    func process(_ id: UUID) async -> PTYProcess? { await registry.process(id) }
    func scrollbackText(_ id: UUID) async -> String { await registry.scrollback(id)?.text(since: 0).text ?? "" }

    func scrollbackMemoryBytes(_ id: UUID) async -> Int { await registry.scrollback(id)?.memoryBytes ?? -1 }
    func scrollbackRaw(_ id: UUID) async -> Data { await registry.scrollback(id)?.snapshot().data ?? Data() }
    func scrollbackTotalBytes(_ id: UUID) async -> Int { await registry.scrollback(id)?.totalBytesWritten ?? -1 }
    var streamQueuePeakBytes: Int { server.streamQueuePeakBytes }
    var streamInputPeakBytes: Int { server.streamInputPeakBytes }
    func streamCount() async -> Int { await hub.streamCount }
    func badge(_ id: UUID) async -> StatusBadge? { await hub.currentBadges[id] }
    func askBusy(_ id: UUID) async -> Bool { await asks.isBusy(id) }
    func counts() async -> (procs: Int, buffers: Int, targets: Int) {
        let r = await registry.counts
        return (r.procs, r.buffers, await asks.targetCount)
    }

    /// Each terminal holds a master, its replica and a spill file; launchd's default soft limit (256) caps that at ~80
    /// terminals. Raise the soft limit to the hard one, capped at OPEN_MAX (setrlimit rejects more on macOS).
    static func raiseFileLimit() {
        var rl = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &rl) == 0 else { return }
        let want = min(rl.rlim_max, rlim_t(OPEN_MAX))
        if rl.rlim_cur < want { rl.rlim_cur = want; _ = setrlimit(RLIMIT_NOFILE, &rl) }
    }

    public func start() async throws {
        Self.raiseFileLimit()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chmod(root.path, 0o700)      // even if it pre-existed with a looser mode
        try server.start()           // refuses if another daemon owns the socket; only then touch admin.token
        // denials: before any terminal can launch (`log stream` takes 1-2 s to attach; SandboxWatcher)
        if let src = config.denialSource ?? (config.watchDenials ? SandboxWatcher.logStream : nil) {
            await router.startSandboxWatch(src, base: config.denialBackoff)
        }
        // The admin token is still the in-memory one no client has seen (admin.token is rewritten below), so
        // nothing can authenticate until the reap and sweeps are done. A failed bind never gets here.
        let runDir = runDir
        // pidfiles are groups orphaned by a crashed daemon; blocking wait, so off the cooperative pool
        await withCheckedContinuation { c in
            DispatchQueue.global().async { _ = OrphanReaper.reapAll(in: runDir); c.resume() }
        }
        sweep(spillDir) { $0.hasSuffix(".log") }
        // an export's or an import's scratch left by a crash (never `.import-pending` nor `.replaced-*`: the user's data)
        sweep(root) { n in [".backup-", ".import-"].contains { n.hasPrefix($0) && UUID(uuidString: String(n.dropFirst($0.count))) != nil } }
        await router.jobsGoneWithoutProcess()   // a previous daemon's terminals all died with it
        sweep(hooksDir) { $0.hasSuffix(".claude.json") || $0.hasSuffix(".mcp.json") }
        try await auth.persist()
        await hub.start()
        await router.watchDevices()
        await router.userEnv.warm()
        await router.startJobSweep()
    }

    private func sweep(_ dir: URL, _ match: (String) -> Bool) {
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where match(f.lastPathComponent) { try? FileManager.default.removeItem(at: f) }
    }

    public func stop() async {
        server.stop()
        await router.stopSandboxWatch()
        await router.stopJobSweep()
        await router.host.stop()
        await router.devices.stop()
        await router.design.stop()
        await router.figcraft.stop()
        await hub.stop()
        await registry.killAll()
        await auth.revokeAll()
        sweep(hooksDir) { $0.hasSuffix(".claude.json") || $0.hasSuffix(".mcp.json") }
    }
}
