import Foundation
import OrqCore
import OrqProtocol
import OrqTerminal

public struct DaemonConfig: Sendable {
    public var paths: Paths
    public var orqExecutable: URL
    /// `BuildID` of the running executable, reported in `ui.snapshot` (orqd computes it once at startup).
    public var build: String?
    public var workspaceId: UUID
    public var idleQuietSeconds: Double = 2.0
    /// How long a timed-out turn keeps its target's ask slot (lost hook / hung agent).
    public var heldMaxSeconds: Double = 600
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
    /// The launched emulator's environment; nil = the daemon's minus `ORQ_*` (tests pass their fakes' inputs).
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
    /// How long a device video session outlives its last viewer.
    public var deviceGrace: Duration = .seconds(5)
    /// The bundled figcraft (`bin/figcraft-server`, `bin/figcraft-cli`, `web/`); nil/missing: design commands report it is not bundled.
    public var figcraftDir: URL?
    /// How long a caller's design client may sit unused before it is closed.
    public var designIdle: Duration = .seconds(300)
    /// Longest any design command may take (tests shrink it); nil: each command's own timeout.
    public var designTimeoutCap: Duration?
    public var shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    /// false: agents get only Orq's keys, no `$SHELL -ilc` capture (process tests: never the developer's rc files).
    public var captureUserEnv = true
    /// How long `partitura.apply` waits for each new terminal to be ready (tests shorten it).
    public var partituraReady: Duration = .seconds(60)
    /// Captures the user's interactive environment for agent launches (unit tests replace it).
    var envRunner: UserEnvironment.Runner = UserEnvironment.live
    /// The on-device model for summary rewrites (tests pass a fake).
    var localModel: any LocalModel = FoundationLocalModel()
    public init(paths: Paths, orqExecutable: URL, workspaceId: UUID) {
        self.paths = paths; self.orqExecutable = orqExecutable; self.workspaceId = workspaceId
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

    public init(config: DaemonConfig) throws {
        let auth = AuthRegistry(adminTokenFile: config.paths.adminTokenFile)
        let store = WorkspaceStore(paths: config.paths)
        let wsDir = config.paths.workspaceDir(config.workspaceId)
        let spillDir = wsDir.appendingPathComponent("terminals")
        let registry = TerminalRegistry(spillDir: spillDir,
                                        memoryCapBytes: config.memoryCapBytes, runDir: config.paths.runDir,
                                        writeStall: config.writeStall)
        // ponytail: a corrupt/missing workspace.json starts a fresh workspace.
        let loaded = (try? Data(contentsOf: wsDir.appendingPathComponent("workspace.json")))
            .flatMap { try? JSONDecoder().decode(Workspace.self, from: $0) }
        var ws = loaded ?? Workspace(id: config.workspaceId, name: "default")
        // repair: a canvas panel left on a floor that no longer exists (before floor.delete grounded them) goes to ground
        let floorIds = Set(ws.floors.map(\.id))
        for i in ws.panels.indices where ws.panels[i].floorId.map({ !floorIds.contains($0) }) == true { ws.panels[i].floorId = nil }
        let asks = AskCoordinator(idleQuietSeconds: config.idleQuietSeconds, heldMaxSeconds: config.heldMaxSeconds)
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
        self.server = UnixSocketServer(path: config.paths.socket, peerHandler: { await router.handle($0, peer: $1) },
                                       streamHandler: { await router.stream($0, peer: $1, conn: $2) })
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
