import Foundation
import CollieCore
import CollieProtocol
import CollieTerminal

private final class WeakRouter: @unchecked Sendable { weak var router: CommandRouter? }   // set once, in init

actor CommandRouter {
    let config: DaemonConfig
    let auth: AuthRegistry
    let registry: TerminalRegistry
    private let store: WorkspaceStore
    let asks: AskCoordinator
    let hub: StreamHub
    let usage: UsageService
    var ws: Workspace
    /// Names (lowercased) mid-launch: the launch awaits let a concurrent spawn/summon of the same name in.
    var launching: Set<String> = []
    /// Paddock names (lowercased) with a create/land/delete in flight; git awaits let other callers in.
    var paddockBusy: Set<String> = []
    /// Paddocks whose delete is in flight: a launch into one that finishes meanwhile is undone (`ensurePaddock`).
    var paddockDeleting: Set<UUID> = []
    /// A design system scope change (`design.system.use`/`undo`, a paddock's delete) in flight: one at a time.
    var designScopeBusy = false
    /// Recent plugin events per panel (ring of `panelEventCap`) and the last sequence number handed out.
    var panelEvents: [UUID: [PanelEvent]] = [:]
    var eventSeq = 0
    nonisolated let host = PluginHost()
    nonisolated let memory: MemoryService
    nonisolated let devices: DeviceService
    /// The design engine's server; started by the first design command.
    nonisolated let figcraft: FigcraftServer
    /// Design files and the callers' figcraft clients.
    nonisolated let design: DesignService
    /// Design systems: published libraries of design files.
    nonisolated let systems: DesignSystemService
    /// Pages Collie keeps: html exports and agents' pages.
    nonisolated let artifacts: ArtifactStore
    /// What each terminal's agent is doing (`<root>/work`).
    nonisolated let work: WorkStore
    /// The work chat of this workspace (`<root>/work/work-chat-<workspace>.jsonl`).
    nonisolated let chat: ChatLog
    /// Lots' boards (`<root>/lots/<id>/board.jsonl`).
    nonisolated let boards: LotBoards
    /// Saved herds (`<root>/herds`).
    nonisolated let herds: HerdStore
    /// The on-device model's rewrites of work summaries.
    nonisolated let assistant: WorkAssistant
    var jobSweeper: Task<Void, Never>?
    /// The work store failed and was logged; reset by the next good read.
    var workStoreBroken = false
    /// Works whose proposals are being captured (MemoryCapture): one capture a work at a time.
    var capturing: Set<UUID> = []
    // ponytail: not persisted. After a restart a closed work written again can be saved a second time (re-marking the
    // record unreviewed), and a crash between the close and the save loses that summary. Persist it if that matters.
    // ponytail: savedClose grows by one entry per closed work for the daemon's lifetime (tiny); prune with the works
    var savedClose: [UUID: Date] = [:]   // work -> closedAt whose summary went to Memory
    var closeCwd: [UUID: String] = [:]   // work -> its terminal's cwd when the terminal was removed on close
    var summaryDecisions: [String] = []  // what keepSummary decided each time (empty|no-repo|saved|failed), for tests
    /// An `admin.data.export` in flight: one at a time.
    var exportBusy = false
    /// Shepherds whose rerail of themselves is queued: one at a time.
    var selfRerails: Set<UUID> = []
    /// The user's interactive-shell environment, for agent launches.
    nonisolated let userEnv: UserEnvironment
    /// Artifacts being imported into a design now (in memory: an import does not outlive the daemon).
    var importingArtifacts: Set<UUID> = []
    /// A `herd.apply` in flight: one at a time, the next waits.
    var applyingHerd = false
    func setImporting(_ id: UUID, _ on: Bool) { if on { importingArtifacts.insert(id) } else { importingArtifacts.remove(id) } }

    init(config: DaemonConfig, auth: AuthRegistry, registry: TerminalRegistry, store: WorkspaceStore,
         asks: AskCoordinator, hub: StreamHub, workspace: Workspace, userEnv: UserEnvironment) {
        self.config = config; self.auth = auth; self.registry = registry; self.store = store; self.userEnv = userEnv
        self.asks = asks; self.hub = hub; self.ws = workspace
        self.usage = UsageService(dir: config.paths.root.appendingPathComponent("usage/providers"))
        self.memory = MemoryService(globalDir: config.paths.root.appendingPathComponent("memory"))
        let me = WeakRouter()   // the service's events go through this router, which exists only once init is done
        let adbPath = config.adbPath, axePath = config.axePath, emulatorPath = config.emulatorPath
        self.devices = DeviceService(root: config.paths.root, runDir: config.paths.runDir, pollInterval: config.devicePollInterval,
            scrcpyServer: config.scrcpyServer, grace: config.deviceGrace,
            adb: { adbPath ?? Adb.locate(env: ProcessInfo.processInfo.environment, home: NSHomeDirectory()) },
            emulator: { emulatorPath ?? Emulator.locate(env: ProcessInfo.processInfo.environment, home: NSHomeDirectory()) }, emulatorBoot: config.emulatorBoot, emulatorEnv: config.emulatorEnv,
            xcrun: config.xcrunPath, axe: { axePath ?? Simulator.locateAXe(env: ProcessInfo.processInfo.environment) },
            crashReports: config.crashReportsDir, logCap: config.deviceLogCap,
            emit: { p, n, pl in await me.router?.pluginEmitted(panel: p, name: n, payload: pl) })
        // no figcraftDir: a binary path that never exists, so the first design command reports `notBundled`
        self.figcraft = FigcraftServer(
            binary: (config.figcraftDir ?? URL(fileURLWithPath: "/nonexistent")).appendingPathComponent("bin/figcraft-server"),
            dataDir: config.paths.root.appendingPathComponent("design/server"), runDir: config.paths.runDir)
        self.design = DesignService(server: figcraft, figcraftDir: config.figcraftDir, root: config.paths.root,
                                    runDir: config.paths.runDir, idle: config.designIdle,
                                    timeoutCap: config.designTimeoutCap)
        self.systems = DesignSystemService(design: design, root: config.paths.root)
        self.artifacts = ArtifactStore(root: config.paths.root)
        let workDir = config.paths.root.appendingPathComponent("work")
        self.work = WorkStore(dir: workDir) { id in Task { await me.router?.workChanged(id) } }
        self.chat = ChatLog(dir: workDir, name: "work-chat-\(config.workspaceId.uuidString.lowercased())")
        self.boards = LotBoards(lotsDir: config.paths.root.appendingPathComponent("lots"))
        self.herds = HerdStore(dir: config.paths.root.appendingPathComponent("herds"))
        self.assistant = WorkAssistant(model: config.localModel)
        me.router = self
        let approvals = asks.approvalEvents
        Task { for await e in approvals { await me.router?.approvalChanged(e) } }
    }

    /// `ui.*` streams (admin only). nil: accepted, the connection is now a stream; otherwise the refusal.
    func stream(_ req: Request, peer: pid_t, conn: StreamConn) async -> Response? {
        do {
            try preflight(req)
            try await adminOnly(req, peer: peer)
            let ok = Response(id: req.id, ok: true, result: .object([:]))
            switch req.command {
            case "ui.attach":
                guard let id = UUID(uuidString: try need(req, "terminal")) else {
                    throw ProtocolError(code: .invalidArgs, message: "'terminal' must be a terminal id")
                }
                guard await hub.attach(id, conn, ok: ok) else {
                    throw ProtocolError(code: .notFound, message: "Terminal \(id) is not running")
                }
            case "ui.events": await hub.listen(conn, ok: ok)
            case "ui.host":
                await host.attach(conn, ok: ok) { [weak self] p, n, pl in await self?.pluginEmitted(panel: p, name: n, payload: pl) }
            case "ui.device":
                guard let id = UUID(uuidString: try need(req, "panel")),
                      let p = ws.panels.first(where: { $0.id == id && $0.pluginId == "device" }) else {
                    throw ProtocolError(code: .notFound, message: "No device panel '\(str(req, "panel") ?? "")'")
                }
                await devices.attach(panel: p, conn: conn, ok: ok)
            case "ui.snapshot": return Response(id: req.id, ok: true, result: try await snapshot())
            case "ui.usage":
                let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
                let reports = await usage.reports()
                return Response(id: req.id, ok: true, result: try JSONDecoder().decode(JSONValue.self, from: enc.encode(reports)))
            default: throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(req.command)'")
            }
            return nil
        } catch let e as ProtocolError {
            return Response(id: req.id, ok: false, error: e)
        } catch {
            return Response(id: req.id, ok: false, error: ProtocolError(code: .internal, message: "\(error)"))
        }
    }

    private func snapshot() async throws -> JSONValue {
        var badges: [String: StatusBadge] = [:]
        let live = await hub.currentBadges
        for t in ws.terminals {   // records reloaded after a restart have no process: stopped
            let running = await registry.process(t.id)?.isRunning == true
            badges[t.id.uuidString] = running ? live[t.id] : .stopped
        }
        let snap = WorkspaceSnapshot(terminals: ws.terminals, connections: ws.connections, badges: badges, paddocks: ws.paddocks, panels: ws.panels, lots: ws.lots, build: config.build)
        return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(snap))
    }

    private func preflight(_ req: Request) throws(ProtocolError) {
        guard req.v == Protocol.version else {
            throw ProtocolError(code: .unsupportedVersion, message: "Unsupported protocol version \(req.v)")
        }
        guard Commands.spec(req.command) != nil else {
            throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(req.command)'")
        }
    }

    func adminOnly(_ req: Request, peer: pid_t) async throws(ProtocolError) {
        guard let t = req.token, constantTimeEqual(t, auth.adminToken) else {
            throw ProtocolError(code: .unauthorized, message: "Invalid admin token")
        }
        // agents can read admin.token too; refuse callers running inside a terminal we spawned, or inside a
        // daemon-run child (git hooks, usage providers: agent-writable code)
        // ponytail: defense-in-depth, not a security boundary. Fails open (allows) for peers that were
        // reparented/double-forked away from the tree, a peer that already exited before the
        // sysctl walk, and pid 0 (peer pid unknown). Real isolation needs agents under another uid/sandbox.
        if descends(peer, fromAny: await registry.livePids().union(BoundedProcess.livePids())) {
            throw ProtocolError(code: .unauthorized, message: "admin commands are not allowed from managed terminals")
        }
    }

    /// `peer`: pid of the connecting process (0 = unknown).
    func handle(_ req: Request, peer: pid_t = 0) async -> Response {
        do {
            try preflight(req)
            if req.command.hasPrefix("admin.") {
                try await adminOnly(req, peer: peer)
                return Response(id: req.id, ok: true, result: try await admin(req))
            }
            if req.command.hasPrefix("paddock.") {   // admin or terminal principal; rules per command
                return Response(id: req.id, ok: true, result: try await paddockCommand(req, peer: peer))
            }
            if req.command.hasPrefix("panel.") || req.command == "events" {   // same principal rules as paddock.*
                return Response(id: req.id, ok: true, result: try await panelCommand(req, peer: peer))
            }
            if req.command.hasPrefix("memory.") {   // admin or terminal; admin-only ones checked in memoryCommand
                return Response(id: req.id, ok: true, result: try await memoryCommand(req, peer: peer))
            }
            if req.command.hasPrefix("work.chat.") || req.command == "work.approvals" || req.command == "work.approve" || req.command == "work.approval.dismiss" {   // the app's alone
                try await adminOnly(req, peer: peer)
                return Response(id: req.id, ok: true, result: try await chatCommand(req))
            }
            if req.command.hasPrefix("work."), req.command != "work.hook" {   // admin or terminal; reach rules in workCommand
                return Response(id: req.id, ok: true, result: try await workCommand(req, peer: peer))
            }
            if req.command.hasPrefix("lot.") {   // admin or terminal; reach rules in lotCommand
                return Response(id: req.id, ok: true, result: try await lotCommand(req, peer: peer))
            }
            if req.command.hasPrefix("herd.") {   // admin or Shepherd; app-only ones checked in herdCommand
                return Response(id: req.id, ok: true, result: try await herdCommand(req, peer: peer))
            }
            if let (plugin, spec) = PluginRegistry.command(req.command) {   // admin or terminal; reach rules in resolvePanel
                let result = plugin.id == "design" ? try await designCommand(req, peer: peer)
                    : plugin.id == "artifacts" ? try await artifactCommand(req, peer: peer)
                    : plugin.runsInDaemon ? try await deviceCommand(req, peer: peer)
                    : try await pluginCommand(req, plugin: plugin, spec: spec, peer: peer)
                return Response(id: req.id, ok: true, result: result)
            }
            guard let idStr = req.terminalId, let tid = UUID(uuidString: idStr), let t = req.token,
                  await auth.verify(terminal: tid, token: t) else {
                throw ProtocolError(code: .unauthorized, message: "Invalid terminal credentials")
            }
            switch req.command {
            case "list": return Response(id: req.id, ok: true, result: await list(from: tid))
            case "ask":
                let t = try ConnectionGraph.resolve(name: try need(req, "target"), from: tid, in: ws)
                guard await registry.process(t.id)?.isRunning == true else {   // also covers records reloaded after restart
                    throw ProtocolError(code: .notRunning, message: "Terminal '\(t.name)' is not running")
                }
                let r = try await asks.ask(from: tid, to: t.id, prompt: try need(req, "prompt"), raw: flag(req, "raw"),
                                           timeout: .seconds(try num(req, "timeout", max: 86_400) ?? 1800))
                return Response(id: req.id, ok: true, result: .object([
                    "output": .string(r.output), "source": .string(r.source.rawValue), "truncated": .bool(r.truncated)]))
            case "check":
                let t = try ConnectionGraph.resolve(name: try need(req, "target"), from: tid, in: ws)
                let s = await registry.scrollback(t.id)?.tail(lines: Int(try num(req, "lines", max: 1_000_000) ?? 200)) ?? (text: "", truncated: false)
                return Response(id: req.id, ok: true, result: .object(["output": .string(s.text), "truncated": .bool(s.truncated)]))
            case "turn.completed":
                // `continued`: Claude goes on because a Stop hook blocked; the turn the ask waits for has not ended
                let continued = flag(req, "continued"), capture = flag(req, "capture") && !continued
                // a capture Stop holds the queue first: the ask it completes must not let the next one be typed before the decision
                let hold = capture ? await asks.holdForCapture(tid) : nil
                if continued {
                    await asks.turnContinued(terminal: tid)
                    await captureContinued(tid)
                } else { await asks.turnCompleted(terminal: tid, message: str(req, "message")) }
                guard capture else {
                    Task { await workTurnEnded(tid) }   // git runs detached: never delays or fails the hook
                    return Response(id: req.id, ok: true, result: .object([:]))
                }
                // Claude's Stop may ask once per chunk: the turn's commits count, so git first (at most 3 s, then it goes on detached)
                let (done, finish) = AsyncStream<Void>.makeStream()
                Task { await workTurnEnded(tid); finish.finish() }
                Task { try? await Task.sleep(for: .seconds(3)); finish.finish() }
                for await _ in done {}
                let ask = await stopAsk(tid)
                if let hold { if ask == nil { await asks.releaseCapture(tid, hold) } else { await asks.captureBlocked(tid, hold) } }
                return Response(id: req.id, ok: true, result: .object(ask.map { ["ask": .string($0)] } ?? [:]))
            case "work.hook":
                if str(req, "hook") == "notification", let m = HookPayload.claudePermissionMessage(stdinJSON: Data((str(req, "payload") ?? "").utf8)) {
                    await asks.hookPermission(tid, message: String(m.prefix(500)))
                }
                await workHook(req, from: tid)
                return Response(id: req.id, ok: true, result: .object([:]))
            default:
                guard Commands.spec(req.command)?.shepherdOnly == true else {
                    throw ProtocolError(code: .internal, message: "'\(req.command)' not implemented yet")
                }
                return Response(id: req.id, ok: true, result: try await shepherd(req, from: tid))
            }
        } catch let e as ProtocolError {
            return Response(id: req.id, ok: false, error: e)
        } catch {
            return Response(id: req.id, ok: false, error: ProtocolError(code: .internal, message: "\(error)"))
        }
    }

    private func list(from id: UUID) async -> JSONValue {
        var out: [JSONValue] = []
        for t in ConnectionGraph.reachable(from: id, in: ws) {
            let running = await registry.process(t.id)?.isRunning ?? false
            out.append(.object(["name": .string(t.name), "preset": .string(t.preset.rawValue),
                                "running": .bool(running), "isShepherd": .bool(t.isShepherd)]))
        }
        return .array(out)
    }

    func str(_ r: Request, _ k: String) -> String? {
        if case .string(let s)? = r.args[k] { return s } else { return nil }
    }
    func need(_ r: Request, _ k: String) throws(ProtocolError) -> String {
        guard let v = str(r, k), !v.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "Missing argument '\(k)'") }
        return v
    }
    /// Number or numeric string in 1...max; nil when absent. The bound keeps Duration/Int conversions from trapping.
    func num(_ r: Request, _ k: String, max: Double) throws(ProtocolError) -> Double? {
        let v: Double?
        switch r.args[k] {
        case nil, .null?: return nil
        case .number(let n)?: v = n
        case .string(let s)?: v = Double(s)
        default: v = nil
        }
        guard let v, v >= 1, v <= max else {
            throw ProtocolError(code: .invalidArgs, message: "'\(k)' must be a number between 1 and \(Int(max))")
        }
        return v
    }
    func flag(_ r: Request, _ k: String) -> Bool {
        switch r.args[k] { case .bool(let b)?: return b; case .string(let s)?: return s == "true"; default: return false }
    }
    func lookup(_ name: String) throws(ProtocolError) -> TerminalRecord? {
        let hits = ws.terminals.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard hits.count <= 1 else { throw ProtocolError(code: .ambiguous, message: "Multiple terminals named '\(name)'") }
        return hits.first
    }
    func find(_ name: String) throws(ProtocolError) -> TerminalRecord {
        guard let t = try lookup(name) else { throw ProtocolError(code: .notFound, message: "Terminal '\(name)' not found") }
        return t
    }
    /// Forgets a launch: fails its asks, terminates it, drops its credentials, spill and hook file.
    private func discard(_ id: UUID) async {
        await asks.detach(id)
        await hub.untrack(id)
        await registry.remove(id)
        await auth.revoke(id)
        AgentLaunch.removeHooks(for: id, in: hooksDir)
        await memory.endSession(id)
        await design.callerGone(id.uuidString)
        await jobsGone(terminal: id)
    }
    func persist() async throws { try await store.save(ws) }
    /// Claims `name` for the duration of a launch; the caller releases it (`launching.remove`) with `defer`.
    /// Terminals and panels share one namespace: a panel's name is refused too.
    func reserve(_ name: String) throws(ProtocolError) {
        if let p = ws.panels.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw ProtocolError(code: .invalidArgs, message: "'\(name)' is the name of panel '\(p.name)'")
        }
        guard launching.insert(name.lowercased()).inserted else {
            throw ProtocolError(code: .invalidArgs, message: "terminal '\(name)' is already being launched")
        }
    }

    private func admin(_ r: Request) async throws -> JSONValue {
        func need(_ k: String) throws(ProtocolError) -> String { try self.need(r, k) }
        switch r.command {
        case "admin.spawn":
            let name = try need("name")
            try reserve(name); defer { launching.remove(name.lowercased()) }
            guard let preset = Preset(rawValue: try need("preset")) else {
                throw ProtocolError(code: .invalidArgs, message: "preset must be shell|claude|codex|custom")
            }
            var fl: Paddock?
            if let f = str(r, "paddock") { fl = try findPaddock(f) }
            // same name: a dead record is relaunched in place (keeps id + connections); a live one is refused
            let old = try lookup(name)
            if let old {
                if await registry.process(old.id)?.isRunning == true {
                    throw ProtocolError(code: .invalidArgs, message: "terminal '\(old.name)' is already running")
                }
                await discard(old.id)
            }
            let rec = TerminalRecord(id: old?.id ?? UUID(), name: name, preset: preset, command: str(r, "command"),
                                     cwd: str(r, "cwd") ?? fl?.path ?? r.cwd ?? NSHomeDirectory(), isShepherd: flag(r, "shepherd"),
                                     paddockId: fl?.id)
            let result = try await launch(rec)
            try await ensurePaddock(of: rec)
            return .object(result)
        case "admin.restart":
            let t = try find(try need("name"))
            try reserve(t.name); defer { launching.remove(t.name.lowercased()) }
            if await registry.process(t.id)?.isRunning == true {
                throw ProtocolError(code: .invalidArgs, message: "terminal '\(t.name)' is already running")
            }
            return .object(try await relaunch(t))
        case "admin.update":
            var t = try find(try need("name"))
            let id = t.id, old = t
            let newName = str(r, "newName")?.trimmingCharacters(in: .whitespacesAndNewlines)   // the app trims too
            if let n = newName, n.isEmpty {
                throw ProtocolError(code: .invalidArgs, message: "newName must not be empty")
            }
            try reserve(t.name); defer { launching.remove(old.name.lowercased()) }
            if let n = newName, n.lowercased() != old.name.lowercased() { try reserve(n) }
            defer { if let n = newName { launching.remove(n.lowercased()) } }
            if let n = newName {
                if ws.terminals.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
                    throw ProtocolError(code: .invalidArgs, message: "a terminal named '\(n)' already exists")
                }
                t.name = n
            }
            switch r.args["shepherd"] {
            case nil: break
            case .bool(let b)?: t.isShepherd = b
            case .string("true")?: t.isShepherd = true
            case .string("false")?: t.isShepherd = false
            default: throw ProtocolError(code: .invalidArgs, message: "shepherd must be true or false")
            }
            if let ps = str(r, "preset") {
                guard let preset = Preset(rawValue: ps) else {
                    throw ProtocolError(code: .invalidArgs, message: "preset must be shell|claude|codex|custom")
                }
                t.preset = preset
            }
            if let c = str(r, "command") { t.command = c.isEmpty ? nil : c }   // ponytail: empty clears
            if let c = str(r, "cwd") {
                guard t.paddockId == nil else {
                    throw ProtocolError(code: .invalidArgs, message: "cwd of a paddock terminal follows its paddock")
                }
                t.cwd = c
            }
            if t.preset == .custom && (t.command ?? "").isEmpty {
                throw ProtocolError(code: .invalidArgs, message: "preset custom needs a command")
            }
            let running = await registry.process(id)?.isRunning == true
            guard let i = ws.terminals.firstIndex(where: { $0.id == id }) else {   // removed during the await
                throw ProtocolError(code: .notFound, message: "Terminal '\(old.name)' not found")
            }
            ws.terminals[i] = t
            // the name reservation serializes update/restart/spawn of this terminal, but not kill: roll back only our own write
            do { try await persist() } catch {   // memory must match disk: put the old record back
                if let j = ws.terminals.firstIndex(where: { $0.id == id }), ws.terminals[j] == t { ws.terminals[j] = old }
                throw error
            }
            await hub.emit(.terminal(t))
            let needed = running && (t.isShepherd != old.isShepherd || t.preset != old.preset || t.command != old.command || t.cwd != old.cwd)
            let again = flag(r, "restart")
            // restart fails pending asks (relaunch discards the old process); if relaunch throws, the saved edit stays applied
            if again { _ = try await relaunch(t) }
            return .object(["id": .string(id.uuidString), "name": .string(t.name),
                            "restartNeeded": .bool(needed && !again), "restarted": .bool(again)])
        case "admin.unleash":
            if let (t, p) = try panelPair(r, terminal: find, panel: findPanel) { try await unleash(t, p); return .object([:]) }
            try await unleash(try find(try need("a")), try find(try need("b")))
            return .object([:])
        case "admin.leash":
            if let (t, p) = try panelPair(r, terminal: find, panel: findPanel) { try await leash(t, p); return .object([:]) }
            try await leash(try find(try need("a")), try find(try need("b")))
            return .object([:])
        case "admin.kill":
            let name = try need("target")
            if try lookup(name) == nil, let p = ws.panels.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                try await remove(p)
            } else {
                try await remove(try find(name))
            }
            return .object([:])
        case "admin.data.export", "admin.data.import":
            let key = r.command == "admin.data.export" ? "out" : "from"
            let path = try need(key)
            guard path.hasPrefix("/") else { throw ProtocolError(code: .invalidArgs, message: "'\(key)' must be an absolute path") }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if r.command == "admin.data.export" {
                guard !exportBusy else { throw ProtocolError(code: .unavailable, message: "export in progress") }
                exportBusy = true; defer { exportBusy = false }   // two would stop and restart the server under each other
                return .object(try await DataBackup.export(root: config.paths.root, to: url, server: figcraft, work: work, chat: chat,
                                                           version: config.build ?? "dev").json)
            }
            let dry = flag(r, "dryRun")
            var o = try await DataBackup.stage(root: config.paths.root, from: url, dryRun: dry).json
            if !dry { o["restartNeeded"] = .bool(true) }   // applied by collied at its next start (DataBackup.applyPending)
            return .object(o)
        default:
            throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(r.command)'")
        }
    }

    /// Relaunches `t` in place (same id, so leashes and asks keep pointing at it). The caller holds the name reservation.
    func relaunch(_ t: TerminalRecord) async throws -> [String: JSONValue] {
        var t = t
        if let fid = t.paddockId {
            if paddockDeleting.contains(fid) { throw ProtocolError(code: .invalidArgs, message: "paddock of '\(t.name)' is being deleted") }
            if !ws.paddocks.contains(where: { $0.id == fid }) {   // paddock gone: back to the pasture, never into a missing dir
                t.paddockId = nil
                if !FileManager.default.fileExists(atPath: t.cwd) {
                    let pasture = LegacyOrq.pasture(ofPaddockPath: t.cwd)
                    t.cwd = pasture.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? NSHomeDirectory()
                }
            }
        }
        await discard(t.id)
        let result = try await launch(t)
        try await ensurePaddock(of: t)
        return result
    }

    /// Leashes `a`–`b` (idempotent), persists, emits `.connected`.
    func leash(_ a: TerminalRecord, _ b: TerminalRecord) async throws {
        guard a.id != b.id else { throw ProtocolError(code: .invalidArgs, message: "cannot connect '\(a.name)' to itself") }
        for t in [a, b] where !ws.terminals.contains(where: { $0.id == t.id }) {   // removed during a caller's awaits
            throw ProtocolError(code: .notFound, message: "Terminal '\(t.name)' not found")
        }
        try await link(a.id, b.id)
    }

    /// Idempotent leash between two ids; persists, emits `.connected`.
    func link(_ a: UUID, _ b: UUID) async throws {
        guard !ws.connections.contains(where: { Set([$0.a, $0.b]) == Set([a, b]) }) else { return }
        let c = Connection(a: a, b: b)
        ws.connections.append(c)
        try await persist()
        await hub.emit(.connected(c))
    }

    /// Removes the `a`–`b` leash if any, persists, emits `.disconnected`.
    func unleash(_ a: TerminalRecord, _ b: TerminalRecord) async throws { try await unlink(a.id, b.id) }

    func unlink(_ a: UUID, _ b: UUID) async throws {
        let gone = ws.connections.filter { Set([$0.a, $0.b]) == Set([a, b]) }
        guard !gone.isEmpty else { return }
        ws.connections.removeAll { Set([$0.a, $0.b]) == Set([a, b]) }
        try await persist()
        for c in gone { await hub.emit(.disconnected(c)) }
    }

    /// Kills `t` and forgets its record and leashes; emits `.disconnected` per leash, then `.removed`.
    func remove(_ t: TerminalRecord) async throws {
        await discard(t.id)
        ws.terminals.removeAll { $0.id == t.id }
        let gone = ws.connections.filter { $0.a == t.id || $0.b == t.id }
        ws.connections.removeAll { $0.a == t.id || $0.b == t.id }
        let left = dropFromLot(t.id)   // the lot itself stays, even empty
        try await persist()
        for c in gone { await hub.emit(.disconnected(c)) }
        if let left { await hub.emit(.lot(left)) }
        await hub.emit(.removed(t.id))
        await closeRemoved(terminal: t.id, cwd: t.cwd)
        await closeHeadless(of: t.id)
    }

    /// Launches `rec` (new or relaunched in place): credentials, process, record, persist, `.spawned`.
    func launch(_ rec: TerminalRecord) async throws -> [String: JSONValue] {
        // the capture can take seconds: a relaunched record killed meanwhile stays gone
        let existed = ws.terminals.contains { $0.id == rec.id }
        let user = await agentEnv(rec)
        if existed, !ws.terminals.contains(where: { $0.id == rec.id }) {
            throw ProtocolError(code: .notFound, message: "Terminal '\(rec.name)' not found")
        }
        // its paddock deleted meanwhile: ensurePaddock would remove the record and its leashes, so keep it
        if existed, let fid = rec.paddockId, paddockDeleting.contains(fid) || !ws.paddocks.contains(where: { $0.id == fid }) {
            throw ProtocolError(code: .invalidArgs, message: "paddock of '\(rec.name)' is being deleted")
        }
        await memory.endSession(rec.id)   // a new process is a new session: memories may be injected again
        let token = await auth.issue(for: rec.id)
        let p: PTYProcess, sb: ScrollbackBuffer?
        do {
            p = try await registry.spawn(rec, launch: try launchSpec(rec, token: token, user: user))
            sb = await registry.scrollback(rec.id)
            if let sb { await asks.attach(rec, process: p, scrollback: sb) }
            // natural exit ends the memory session too, unless a newer launch already replaced this process
            let id = rec.id, me = ObjectIdentifier(p), prevExit = p.onExit
            p.onExit = { [weak self] code in prevExit?(code); Task { await self?.processExited(id, me) } }
        } catch {
            await auth.revoke(rec.id)
            AgentLaunch.removeHooks(for: rec.id, in: hooksDir)
            if let e = error as? ProtocolError { throw e }
            throw ProtocolError(code: .invalidArgs, message: "Failed to spawn '\(rec.name)': \(error)")
        }
        if let i = ws.terminals.firstIndex(where: { $0.id == rec.id }) { ws.terminals[i] = rec } else { ws.terminals.append(rec) }
        try await persist()
        if let sb {   // emits .spawned
            let tracker = await asks.approvalTracker(rec.id)
            await hub.track(rec, process: p, scrollback: sb) { tracker?.input() }
        }
        return ["id": .string(rec.id.uuidString), "name": .string(rec.name)]
    }

    private func processExited(_ id: UUID, _ process: ObjectIdentifier) async {
        if await registry.process(id).map(ObjectIdentifier.init) == process {
            await memory.endSession(id); await jobsGone(terminal: id); await closeHeadless(of: id)
            // the session's end for agents without a SessionEnd hook (Codex): its learnings become proposals
            if let w = try? await work.active(terminal: id) { Task { await captureProposals(w.id) } }
        }
    }

    private var hooksDir: URL { config.paths.root.appendingPathComponent("hooks") }

    /// The user's interactive environment for agents; none for the `shell` preset (it reads its rc files itself).
    func agentEnv(_ rec: TerminalRecord) async -> [String: String] { rec.preset == .shell ? [:] : await userEnv.current() }

    /// `user` (from `agentEnv`) under Collie's keys.
    func launchSpec(_ rec: TerminalRecord, token: String, user: [String: String]) throws -> LaunchSpec {
        let env = ProcessInfo.processInfo.environment
        var e: [String: String] = [
            "COLLIE_SOCKET": config.paths.socket.path, "COLLIE_TERMINAL_ID": rec.id.uuidString, "COLLIE_TOKEN": token,
            "COLLIE_USAGE_DIR": config.paths.root.appendingPathComponent("usage").path,   // = UsageService's parent of providers/
            "COLLIE_TERMINAL_NAME": rec.name, "COLLIE_WORKSPACE_ID": ws.id.uuidString,
            "TERM": "xterm-256color", "TERM_PROGRAM": "Collie",
            "PATH": env["PATH"] ?? "/usr/bin:/bin",
        ]
        for k in ["HOME", "USER", "LANG"] + UserEnvironment.inherited { if let v = env[k] { e[k] = v } }
        e["SHELL"] = config.shell
        if rec.isShepherd { e["COLLIE_SHEPHERD"] = "1" }   // only unlocks the MCP tool list; the daemon checks isShepherd
        if let f = ws.paddocks.first(where: { $0.id == rec.paddockId }) {
            e["COLLIE_PADDOCK_NAME"] = f.name; e["COLLIE_PADDOCK_PATH"] = f.path; e["COLLIE_BRANCH_NAME"] = f.branch
        }
        e = UserEnvironment.merge(user: user, collie: e, collieBin: config.collieExecutable.deletingLastPathComponent().path)
        return try AgentLaunch.launchSpec(for: rec, env: e, hooksDir: hooksDir, collie: config.collieExecutable,
                                          shell: config.shell, codexMCP: env["COLLIE_CODEX_MCP"] == "1")
    }
}

/// True if `pid` or one of its ancestors (up to 64 levels) is in `pids`.
func descends(_ pid: pid_t, fromAny pids: Set<pid_t>) -> Bool {
    var p = pid
    for _ in 0..<64 {
        if pids.contains(p) { return true }
        guard p > 1, let pp = parentPid(p), pp != p else { return false }
        p = pp
    }
    return false
}

func parentPid(_ pid: pid_t) -> pid_t? {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}
