import Foundation
import os
import CryptoKit
import CollieCore
import CollieProtocol

/// Apps do cercado, slice 5 (owner decision 1, spec 2026-11-08-paddock-apps-design.md): the daemon runs an approved
/// app's `service.start` in its folder, under the paddock's terminal sandbox profile (network as a terminal has it),
/// on demand (attach, its panel, an http command), and stops it when no panel of it is open and nothing called it for
/// `idle`. Ready once `service.health` answers 2xx (no health: any HTTP answer) within `PluginManifest.startWait`. A
/// death restarts it with backoff (1 s doubling to 30 s); `crashLimit` deaths in `crashWindow` give up, with the reason.
/// Output (stdout + stderr) goes to a rotated file per paddock and app (`AppLog`, `collie app logs`). A `LongProcess`: its own process group and
/// a pidfile, so a daemon crash leaves nothing behind (`OrphanReaper`).
enum AppServices {
    nonisolated(unsafe) static var idle: Duration = .seconds(300)
    nonisolated(unsafe) static var restartBase: Double = 1
    static let restartMax: Double = 30, crashLimit = 5, crashWindow: Duration = .seconds(120)
    static let logCap = 256 * 1024

    /// The daemon each approved app folder belongs to (`refreshApps`): `PaddockApps.call`, the one way every http call
    /// goes (tools, a block panel's refresh, any later caller), starts the app's service there first. Weak: a stopped
    /// daemon's entries lead nowhere. Process-wide because `call` is static; folders are per paddock, so tests running
    /// several daemons never share one.
    final class Owner: @unchecked Sendable { weak var router: CommandRouter?; init(_ r: CommandRouter) { router = r } }
    static let owners = OSAllocatedUnfairLock(initialState: [String: Owner]())

    /// A stable id per paddock and app: its sandbox folder (`<root>/sandbox/<id>`) is reused across starts.
    static func id(paddock: UUID, app: String) -> UUID {
        let h = Array(SHA256.hash(data: Data("app-service:\(paddock.uuidString)/\(app)".utf8)))
        return UUID(uuid: (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]))
    }
}

/// What a service printed, in `<root>/app-logs/<paddock>/<app>.log` (kept across daemon restarts): past
/// `AppServices.logCap` bytes the file becomes `<app>.log.1` (the previous one dropped) and a new one starts.
final class AppLog: Sendable {
    let file: URL
    private let state = OSAllocatedUnfairLock<(h: FileHandle?, size: Int)>(uncheckedState: (nil, 0))
    init(file: URL) { self.file = file }
    static func file(root: URL, paddock: UUID, app: String) -> URL {
        root.appendingPathComponent("app-logs").appendingPathComponent(paddock.uuidString).appendingPathComponent(app + ".log")
    }
    private var old: URL { file.appendingPathExtension("1") }

    func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        state.withLockUnchecked { s in
            if s.h == nil {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                s.h = try? FileHandle(forWritingTo: file)
                s.size = Int((try? s.h?.seekToEnd()) ?? 0)
            }
            if s.size > 0, s.size + data.count > AppServices.logCap {   // rotate
                try? s.h?.close(); s.h = nil
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: file, to: old)
                FileManager.default.createFile(atPath: file.path, contents: nil)
                s.h = try? FileHandle(forWritingTo: file); s.size = 0
            }
            try? s.h?.write(contentsOf: data); s.size += data.count
        }
    }
    func close() { state.withLockUnchecked { s in try? s.h?.close(); s.h = nil } }

    /// The last `lines` lines, at most `bytes` (the rotated file first).
    func tail(_ lines: Int, bytes: Int = 64 * 1024) -> String {
        let text = state.withLockUnchecked { _ in
            [old, file].compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        }
        var out: [Substring] = [], n = 0
        for l in text.split(separator: "\n", omittingEmptySubsequences: false).reversed().drop(while: \.isEmpty).prefix(lines) {
            n += l.utf8.count + 1
            if n > bytes { break }
            out.append(l)
        }
        return out.reversed().joined(separator: "\n")
    }
}

actor AppService {
    enum Phase: Equatable {
        case stopped, starting, running, failed(String)
        var name: String {
            switch self { case .stopped: "stopped"; case .starting: "starting"; case .running: "running"; case .failed: "failed" }
        }
    }
    typealias Launch = @Sendable () async throws -> (URL, [String], [String: String])

    let paddock: UUID, app: String, pin: String
    private let title: String, origin: String, health: String?, runDir: URL
    private let launch: Launch
    private let onPhase: @Sendable (Phase) async -> Void
    let log: AppLog
    private(set) var phase: Phase = .stopped
    private(set) var lastUse = ContinuousClock.now
    private var proc: LongProcess?
    private var deaths: [ContinuousClock.Instant] = []
    private var gen = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(paddock: UUID, manifest m: PluginManifest, pin: String, runDir: URL, log: AppLog, launch: @escaping Launch, onPhase: @escaping @Sendable (Phase) async -> Void) {
        self.paddock = paddock; app = m.id; self.pin = pin; title = m.name
        origin = m.serviceOrigin ?? ""; health = m.service?.health; self.runDir = runDir; self.log = log
        self.launch = launch; self.onPhase = onPhase
    }

    var pid: pid_t? { proc?.pid }
    func touch() { lastUse = .now }

    /// Starts it unless it is starting or running; a failed one starts over (Tentar de novo, a new attach).
    func start() async {
        lastUse = .now
        switch phase {
        case .starting, .running: return
        case .stopped, .failed: break
        }
        deaths = []
        await set(.starting)
        await spawn()
    }

    /// Starts it only if it is stopped (an open panel): a failed one waits for an explicit start.
    func startIfStopped() async { if phase == .stopped { await start() } }

    /// Ready for a call: starts it if stopped, then waits for its health (up to `PluginManifest.startWait`). A failed
    /// one stays failed (its reason) until something starts it again.
    func ready() async throws(ProtocolError) {
        lastUse = .now
        if case .failed(let why) = phase { throw ProtocolError(code: .unavailable, message: "\(title): \(why) (collie app logs \(app))") }
        if phase == .stopped { await start() }
        if phase == .starting {
            let id = UUID()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiters[id] = c
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(PluginManifest.startWait))
                    await self?.wake(id)
                }
            }
        }
        switch phase {
        case .running: return
        case .failed(let why): throw ProtocolError(code: .unavailable, message: "\(title): \(why) (collie app logs \(app))")
        default: throw ProtocolError(code: .unavailable, message: "\(title) ainda está iniciando (health em \(origin)\(health ?? "/"))")
        }
    }

    func stop() async {
        gen += 1
        proc?.terminate(); proc = nil; log.close()
        guard phase != .stopped else { return }
        await set(.stopped)
    }

    private func wake(_ id: UUID) { waiters.removeValue(forKey: id)?.resume() }

    private func set(_ p: Phase) async {
        phase = p
        if p != .starting { for (_, w) in waiters { w.resume() }; waiters = [:] }
        await onPhase(p)
    }

    private func spawn() async {
        gen += 1
        let g = gen, log = log
        do {
            let (exe, args, env) = try await launch()
            guard g == gen else { return }   // stopped meanwhile
            log.append("[collie] iniciando: \(args.last ?? "")")
            proc = try LongProcess(executable: exe, args: args, env: env, runDir: runDir,
                                   onLine: { log.append($0) },
                                   onExit: { [weak self] code in Task { await self?.exited(g, code) } })
        } catch {
            let why = (error as? ProtocolError)?.message ?? error.localizedDescription
            log.append("[collie] não iniciou: \(why)")
            return await set(.failed("não iniciou: \(why)"))
        }
        Task { await probe(g) }
    }

    /// Polls the health path every 250 ms; not healthy within `startWait`: stopped and counted as a death.
    private func probe(_ g: Int) async {
        let deadline = ContinuousClock.now + .seconds(PluginManifest.startWait)
        while ContinuousClock.now < deadline {
            guard g == gen, phase == .starting else { return }
            if await PaddockApps.healthy(origin: origin, path: health) {
                guard g == gen, phase == .starting else { return }
                log.append("[collie] pronto")
                return await set(.running)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard g == gen, phase == .starting else { return }
        log.append("[collie] o health não respondeu em \(Int(PluginManifest.startWait)) s")
        proc?.terminate()   // its exit counts as a death
    }

    private func exited(_ g: Int, _ code: Int32) async {
        guard g == gen else { return }   // stopped, or a newer start
        proc = nil
        log.append("[collie] saiu com código \(code)")
        let now = ContinuousClock.now
        deaths = deaths.filter { now - $0 < AppServices.crashWindow } + [now]
        if deaths.count >= AppServices.crashLimit {
            return await set(.failed("caiu \(deaths.count) vezes em \(AppServices.crashWindow.components.seconds / 60) min (último código \(code))"))
        }
        if phase != .starting { await set(.starting) }
        let delay = min(AppServices.restartBase * pow(2, Double(deaths.count - 1)), AppServices.restartMax)
        try? await Task.sleep(for: .seconds(delay))
        guard g == gen, phase == .starting else { return }
        await spawn()
    }
}

extension PaddockApps {
    /// The service answers its health path with 2xx (no health path: any HTTP answer on `/`). No redirect followed.
    static func healthy(origin: String, path: String?) async -> Bool {
        guard let url = URL(string: origin + (path ?? "/")) else { return false }
        let s = session(2)
        defer { s.invalidateAndCancel() }
        guard let (_, resp) = try? await s.data(for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return false }
        return path == nil ? code < 500 : (200..<300).contains(code)
    }
}

extension CommandRouter {
    /// Before an http call to the app in `folder`: its service up and healthy (`AppService.ready`); nothing for an app
    /// without `service.start`.
    func ensureService(folder: String, app: String) async throws(ProtocolError) {
        guard let pid = appManifests.first(where: { $0.value[app]?.appFolder == folder })?.key,
              let s = await appService(paddock: pid, app: app) else { return }
        try await s.ready()
    }

    func serviceKey(_ paddock: UUID, _ app: String) -> String { "\(paddock.uuidString)/\(app)" }

    /// The service of the app approved in `paddock` (nil: it declares no `service.start`); created on first use, replaced
    /// (the old one stopped) when the pin moved.
    func appService(paddock: UUID, app: String) async -> AppService? {
        guard let m = appManifests[paddock]?[app], m.service?.start != nil, let pin = m.appPin, let folder = m.appFolder,
              let p = ws.paddocks.first(where: { $0.id == paddock }) else { return nil }
        let key = serviceKey(paddock, app)
        if let s = appServices[key] {
            if s.pin == pin { return s }
            appServices[key] = nil
            await s.stop()
        }
        let id = AppServices.id(paddock: paddock, app: app)
        let s = AppService(paddock: paddock, manifest: m, pin: pin, runDir: config.paths.runDir,
                           log: AppLog(file: AppLog.file(root: config.paths.root, paddock: paddock, app: app)),
                           launch: { [weak self] in
                               guard let self else { throw ProtocolError(code: .unavailable, message: "daemon stopping") }
                               return try await self.serviceLaunch(m, folder: folder, paddock: p, id: id)
                           },
                           onPhase: { [weak self] phase in await self?.servicePhase(paddock: paddock, app: app, phase) })
        appServices[key] = s
        startAppSweep()
        return s
    }

    /// `/bin/sh` in the app's folder running `service.start`, stderr into stdout; under the paddock's terminal profile
    /// when terminals are sandboxed (`config.sandboxHome`; tests: none, as for terminals).
    func serviceLaunch(_ m: PluginManifest, folder: String, paddock: Paddock, id: UUID) async throws -> (URL, [String], [String: String]) {
        guard let start = m.service?.start else { throw ProtocolError(code: .invalidArgs, message: "no service.start") }
        let env = ProcessInfo.processInfo.environment
        var e: [String: String] = ["PATH": env["PATH"] ?? "/usr/bin:/bin", "COLLIE_APP_ID": m.id, "COLLIE_APP_BASE": m.serviceOrigin ?? "",
                                   "COLLIE_PADDOCK_NAME": paddock.name, "COLLIE_PADDOCK_PATH": paddock.path]
        for k in ["HOME", "USER", "LANG"] { if let v = env[k] { e[k] = v } }
        e = UserEnvironment.merge(user: await userEnv.current(), collie: e, collieBin: config.collieExecutable.deletingLastPathComponent().path)
        let sh = ["-c", "cd \"$0\" || exit 70; exec 2>&1; exec /bin/sh -c \"$1\"", folder, start]
        guard let home = config.sandboxHome else { return (URL(fileURLWithPath: "/bin/sh"), sh, e) }
        let profile = try prepareServiceSandbox(id: id, paddock: paddock, start: start)
        return (URL(fileURLWithPath: "/usr/bin/sandbox-exec"), ["-f", profile.path, "/bin/sh"] + sh,
                SandboxLaunch.environment(e, id: id, root: config.paths.root, shell: config.shell, home: home))
    }

    /// The paddock's terminal profile for the service (as `prepareSandbox` renders a terminal's): project = the paddock.
    private func prepareServiceSandbox(id: UUID, paddock: Paddock, start: String) throws -> URL {
        let project = URL(fileURLWithPath: paddock.path)
        let git = SandboxInput.gitDirs(of: project)
        let input = SandboxInput(terminal: id, project: project, mainGitDir: git.common, worktreeGitDir: git.worktree,
                                 paddockWorktrees: closedPaddocks(project), home: config.sandboxHome ?? URL(fileURLWithPath: NSHomeDirectory()),
                                 collieRoot: config.paths.root, ownFiles: [],
                                 terminalDir: SandboxLaunch.dir(id, root: config.paths.root), socket: config.paths.socket,
                                 agent: .shell, command: start, grants: [],
                                 appBundle: SandboxInput.appBundle(of: config.collieExecutable), mode: sandboxMode)
        return try SandboxLaunch.prepare(input, root: config.paths.root, collie: config.collieExecutable)
    }

    /// Tells the app's open panels (`collie.service`: starting / running / failed with its reason / stopped).
    private func servicePhase(paddock: UUID, app: String, _ phase: AppService.Phase) async {
        var o: [String: JSONValue] = ["state": .string(phase.name)]
        if case .failed(let why) = phase { o["reason"] = .string(why) }
        for p in ws.panels where p.pluginId == app && p.paddockId == paddock {
            await hub.emit(.pluginEvent(panel: p.id, name: "collie.service", payload: .object(o)))
        }
    }

    /// Starts the services of the apps whose panels are open; stops the ones no longer approved (pin moved, paddock
    /// gone) and the idle ones (no open panel, no call for `AppServices.idle`).
    func syncAppServices() async {
        for p in ws.panels where p.placement == .canvas {
            if let pid = p.paddockId, let s = await appService(paddock: pid, app: p.pluginId) { await s.startIfStopped() }
        }
        let now = ContinuousClock.now
        for (key, s) in appServices {
            let m = appManifests[s.paddock]?[s.app]
            let open = ws.panels.contains { $0.pluginId == s.app && $0.paddockId == s.paddock }
            let idle = now - (await s.lastUse) > AppServices.idle
            if m?.appPin != s.pin || m?.service?.start == nil || (!open && idle) {
                appServices[key] = nil
                await s.stop()
            }
        }
    }

    private func startAppSweep() {
        guard appSweep == nil else { return }
        appSweep = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: min(AppServices.idle / 2, .seconds(30)))
                guard let self else { return }
                await self.syncAppServices()
            }
        }
    }

    /// Daemon stop: every service's group goes (the pidfiles cover a crash).
    func stopAppServices() async {
        appSweep?.cancel(); appSweep = nil
        let all = appServices.values
        appServices = [:]
        for s in all { await s.stop() }
    }
}
