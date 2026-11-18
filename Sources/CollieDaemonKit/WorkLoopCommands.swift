import Foundation
import CollieCore
import CollieProtocol

/// `collie work run` / `collie work stop`: the caller's active work run by a `WorkLoop` in the daemon.
extension CommandRouter {
    static let loopTriesMax = 10.0, loopTimeoutMax = 86_400.0

    /// `starter`: the terminal whose active work runs (the caller, or `--terminal` from the app); it must be a Shepherd,
    /// since the loop summons agents as it. Returns at once; the starter gets one line when the loop ends.
    func workRun(_ r: Request, caller: TerminalRecord?, starter t: TerminalRecord) async throws -> JSONValue {
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        guard caller?.isShepherd ?? true, t.isShepherd else {
            throw ProtocolError(code: .notShepherd, message: "'work.run' is for Shepherds (and the app, on a Shepherd's work): a loop summons agents")
        }
        guard let w = try await work.active(terminal: t.id) else {
            throw invalid("no active work for '\(t.name)'; start one: collie work start <title>")
        }
        guard let paddock = ws.paddocks.first(where: { $0.id == w.paddockId }), !paddock.isFolder else {
            throw invalid("work '\(w.title)' is not in a paddock: a loop resets its worktree between attempts; ask the owner for a paddock")
        }
        let open = w.tasks.filter { $0.state == .open }
        guard !open.isEmpty else { throw invalid("no open task in '\(w.title)'; add some: collie work task add <title> --spec <file> --check <command>") }
        let unchecked = w.tasks.filter { ($0.state == .open || $0.state == .inProgress) && $0.check == nil }
        guard unchecked.isEmpty else {
            throw invalid("every open task needs a --check; these have none: " + unchecked.map { "\"\($0.title)\" [\($0.id)]" }.joined(separator: ", "))
        }
        let others = try await work.list(includeClosed: false).filter { $0.paddockId == paddock.id }
        if workLoops[w.id] != nil || others.contains(where: { $0.loop?.state == .running }) {
            throw invalid("a loop is already running in paddock '\(paddock.name)'; collie work status shows it, collie work stop ends it")
        }
        for o in ws.terminals where o.paddockId == paddock.id && o.id != t.id && !o.isShepherd {
            if await targetBusy(o.id) {
                throw invalid("'\(o.name)' is working in paddock '\(paddock.name)': the loop needs the worktree to itself; wait for it, or run the loop in its own paddock")
            }
        }
        let dir = URL(fileURLWithPath: paddock.path)
        let st = try await GitRunner.run(["status", "--porcelain", "--untracked-files=no"], in: dir, timeout: .seconds(30))
        guard st.status == 0 else { throw invalid("'\(paddock.path)' is not a git worktree") }
        let dirty = st.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard dirty.isEmpty else { throw invalid("tracked files are dirty in paddock '\(paddock.name)'; commit or discard them first:\n\(dirty.prefix(500))") }

        // the summon's own checks run again per attempt; these only save three failed attempts
        if let p = str(r, "preset"), Preset(rawValue: p) == nil { throw invalid("preset must be shell|claude|codex|cursor|custom") }
        if let m = str(r, "model") { try ClaudeModel.validate(m) }
        let loop = WorkLoopState(state: .running, tries: Int(try num(r, "tries", max: Self.loopTriesMax) ?? 3),
                                 timeout: Int(try num(r, "timeout", max: Self.loopTimeoutMax) ?? 3600),
                                 preset: str(r, "preset"), model: str(r, "model"), command: str(r, "command"),
                                 max: try num(r, "max", max: 1000).map(Int.init), used: 0, startedAt: Date())
        try await work.update(w.id) { $0.loop = loop }
        let engine = WorkLoop(store: work, host: RouterLoopHost(router: self, starter: t.id, root: config.paths.root))
        let id = w.id, starter = t.id
        let task = Task { [weak self] in
            _ = await engine.run(work: id, dir: dir)
            await self?.loopEnded(id, starter: starter)
        }
        workLoops[w.id] = (engine, task, false)
        return .object(["id": .string(w.id.uuidString.lowercased()), "tasks": .number(Double(open.count)), "state": .string("running")])
    }

    /// Ends the loop after the current attempt's verdict.
    func workStop(_ t: TerminalRecord) async throws -> JSONValue {
        guard let w = try await work.active(terminal: t.id), let l = workLoops[w.id], !l.stopping else {
            throw ProtocolError(code: .invalidArgs, message: "no loop is running on '\(t.name)'s work")
        }
        workLoops[w.id]?.stopping = true
        await l.engine.stop(work: w.id)
        return .object(["state": .string("stopped")])
    }

    private func loopEnded(_ id: UUID, starter: UUID) async {
        workLoops[id] = nil
        guard let w = try? await work.get(id) else { return }
        let done = w.tasks.filter { $0.state == .done }.count, deferred = w.tasks.filter { $0.state == .deferred }.count
        let line = "[collie] Laço de \"\(RerailText.clean(w.title))\" terminou: \(done) feitas, \(deferred) adiadas. Veja: collie work status"
        try? await asks.inject(to: starter, prompt: line, afterQuiet: true)
    }

    /// At start: a loop a previous daemon left `running` is `stopped` (its task back to open, its attempt's job gone):
    /// `collie work run` again continues from the next open task.
    func stopLoopsLeftRunning() async {
        guard let all = try? await work.list(includeClosed: true) else { return }
        let now = Date()
        for w in all where w.loop?.state == .running {
            try? await work.update(w.id) { x in
                for i in x.tasks.indices where x.tasks[i].state == .inProgress && x.tasks[i].id == x.loop?.task { x.tasks[i].state = .open }
                for j in x.jobs.indices where x.jobs[j].kind == .loop && x.jobs[j].state == .running {
                    x.jobs[j].state = .gone; x.jobs[j].endedAt = now
                }
                x.loop?.state = .stopped; x.loop?.endedAt = now; x.loop?.task = nil
            }
        }
    }

    /// Daemon stop: the loops end with it (their state stays `running` until the next start's sweep).
    func cancelLoops() { for l in workLoops.values { l.task.cancel() }; workLoops = [:] }

    // MARK: what RouterLoopHost needs from the router

    func loopSummon(_ r: Request, as starter: UUID) async throws(ProtocolError) -> UUID {
        let v: JSONValue
        do { v = try await shepherd(r, from: starter) } catch {
            throw (error as? ProtocolError) ?? ProtocolError(code: .internal, message: "\(error)")
        }
        guard case .object(let o) = v, case .string(let s)? = o["id"], let id = UUID(uuidString: s) else {
            throw ProtocolError(code: .internal, message: "summon returned no terminal id")
        }
        return id
    }

    func loopDismiss(_ id: UUID) async {
        if let t = ws.terminals.first(where: { $0.id == id }) { try? await remove(t) }
    }

    /// The terminal's sandbox profile; nil when it runs without one. A sandboxed terminal whose profile is missing throws:
    /// its check never runs with more access than it has.
    func loopProfile(_ id: UUID) throws(ProtocolError) -> URL? {
        guard let t = ws.terminals.first(where: { $0.id == id }), sandboxed(t) else { return nil }
        let f = SandboxLaunch.profileFile(id, root: config.paths.root)
        guard FileManager.default.fileExists(atPath: f.path) else {
            throw ProtocolError(code: .unavailable, message: "no sandbox profile for '\(t.name)'")
        }
        return f
    }

    /// The env a check runs with: the user's (PATH for their toolchain), never Collie's keys.
    func loopEnv() async -> [String: String] {
        UserEnvironment.filtered(UserEnvironment.merge(user: await userEnv.current(), collie: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"],
                                                       collieBin: config.collieExecutable.deletingLastPathComponent().path))
    }

    /// The spec, read again at the attempt: a regular file (no symlink, one link) still inside the starter's project.
    func loopSpec(_ path: String, starter: UUID) async -> String? {
        guard let t = ws.terminals.first(where: { $0.id == starter }), let root = try? await projectRoot(of: t),
              let data = try? Self.readBodyFile(path, allowed: { ProjectRoot.contains($0, root: root) }) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// `LoopHost` over the daemon: summons as the starter (a Shepherd), asks with the daemon's own end of turn, runs git
/// and the check under the sandbox profile of the terminal they act for.
struct RouterLoopHost: LoopHost {
    let router: CommandRouter, starter: UUID, root: URL

    func summon(name: String, for work: Work, loop: WorkLoopState) async throws(ProtocolError) -> UUID {
        // no --paddock: the starter stands in the work's paddock (work.start took it from there)
        var args: [String: JSONValue] = ["name": .string(name)]
        if let p = loop.preset { args["preset"] = .string(p) }
        if let m = loop.model { args["model"] = .string(m) }
        if let c = loop.command { args["command"] = .string(c) }
        return try await router.loopSummon(Request(id: "loop", terminalId: starter.uuidString, command: "summon", args: args), as: starter)
    }

    func ask(_ terminal: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> AskResult.Source {
        try await router.asks.ask(from: starter, to: terminal, prompt: prompt, raw: false, timeout: timeout).source
    }

    func working(_ terminal: UUID) async -> Bool { await router.targetBusy(terminal) }
    func dismiss(_ terminal: UUID) async { await router.loopDismiss(terminal) }

    /// Under the starter's profile (it stands in the same worktree): the repo is agent-writable.
    func git(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult {
        let profile = try await router.loopProfile(starter)
        do {
            return try await GitRunner.$sandbox.withValue(profile) { try await GitRunner.run(args, in: dir, timeout: .seconds(120)) }
        } catch { throw (error as? ProtocolError) ?? ProtocolError(code: .internal, message: "\(error)") }
    }

    func check(_ command: String, in dir: URL, terminal: UUID, timeout: Duration) async throws(ProtocolError) -> ProcessResult {
        try await Self.runCheck(command, in: dir, profile: try await router.loopProfile(terminal), env: await router.loopEnv(), timeout: timeout)
    }

    /// `/bin/bash -c command` in `dir`, wrapped in `sandbox-exec -f profile` when there is one.
    static func runCheck(_ command: String, in dir: URL, profile: URL?, env: [String: String], timeout: Duration) async throws(ProtocolError) -> ProcessResult {
        let bash = ["/bin/bash", "-c", command]
        if let profile {
            return try await BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), args: ["-f", profile.path] + bash,
                                                in: dir, env: env, timeout: timeout)
        }
        return try await BoundedProcess.run(executable: URL(fileURLWithPath: bash[0]), args: Array(bash.dropFirst()), in: dir, env: env, timeout: timeout)
    }

    func readSpec(_ path: String) async -> String? { await router.loopSpec(path, starter: starter) }
    func patchDir(_ work: UUID) -> URL { root.appendingPathComponent("work-loops").appendingPathComponent(work.uuidString.lowercased()) }
    func now() -> Date { Date() }
}
