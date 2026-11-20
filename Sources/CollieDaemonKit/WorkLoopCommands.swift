import Foundation
import CollieCore
import CollieProtocol

/// `collie work run` / `collie work stop`: the caller's active work run by a `WorkLoop` in the daemon.
extension CommandRouter {
    /// Hard ceilings (the owner may raise them later): attempts per task, attempts in all (`--max`, required), a turn,
    /// and the time budget of all turns and checks.
    static let loopTriesMax = 10.0, loopMaxMax = 30.0, loopTimeoutMax = 14_400.0, loopBudgetMax = 43_200.0
    static let loopBudgetDefault = 14_400.0, loopCardMax = 1500

    /// `starter`: the terminal whose active work runs (the caller, or `--terminal` from the app); it must be a Shepherd,
    /// since the loop summons agents as it. Returns at once; the starter gets one line when the loop ends.
    func workRun(_ r: Request, caller: TerminalRecord?, starter t: TerminalRecord) async throws -> JSONValue {
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        guard caller?.isShepherd ?? true, t.isShepherd else {
            throw ProtocolError(code: .notShepherd, message: "'work.run' is for Shepherds (and the app, on a Shepherd's work): a loop summons agents")
        }
        // a terminal sandbox in force (`sandboxHome`): the loop never acts for a terminal that runs without one
        guard config.sandboxHome == nil || sandboxed(t) else {
            throw invalid("'\(t.name)' runs without a sandbox: a loop's agents, check and git all run sandboxed; start it from a sandboxed Shepherd")
        }
        guard let pid = t.paddockId, let paddock = ws.paddocks.first(where: { $0.id == pid }), !paddock.isFolder else {
            throw invalid("'\(t.name)' is not in a paddock: a loop resets its worktree between attempts; ask the owner for a paddock")
        }
        // reserved before the first await: a concurrent work.run (actor reentrancy) finds it taken
        guard !loopPaddocks.contains(pid) else {
            throw invalid("a loop is already running in paddock '\(paddock.name)'; collie work status shows it, collie work stop ends it")
        }
        loopPaddocks.insert(pid)
        var started = false
        defer { if !started { loopPaddocks.remove(pid) } }
        guard let max = try num(r, "max", max: Self.loopMaxMax).map(Int.init) else {
            throw invalid("--max is required: the attempts the loop may use in all (1-\(Int(Self.loopMaxMax)))")
        }
        guard let w = try await work.active(terminal: t.id) else {
            throw invalid("no active work for '\(t.name)'; start one: collie work start <title>")
        }
        guard w.paddockId == pid else {
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
        for o in ws.terminals where o.paddockId == paddock.id && o.id != t.id && !o.isShepherd && Self.loopSharesWorktree(o, URL(fileURLWithPath: paddock.path)) {
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
        // absent: no gate; given: a command (an empty one is a mistake, never "no gate")
        let gate = str(r, "gate")
        if let gate, gate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw invalid("--gate is empty: give the command that runs after every task's check, or leave --gate out")
        }
        let loop = WorkLoopState(state: .running, tries: Int(try num(r, "tries", max: Self.loopTriesMax) ?? 3),
                                 timeout: Int(try num(r, "timeout", max: Self.loopTimeoutMax) ?? 3600),
                                 preset: str(r, "preset"), model: str(r, "model"), command: str(r, "command"),
                                 max: max, used: 0, budget: Int(try num(r, "budget", max: Self.loopBudgetMax) ?? Self.loopBudgetDefault),
                                 spent: 0, tasks: open.map(\.id), gate: gate, startedAt: Date())
        // the owner approves the tasks, their checks, the gate and the limits on a card; until then nothing runs
        guard let text = Self.loopCardText(w, open, loop, paddock: paddock.name) else {
            throw invalid("the owner's approval card would not fit (\(Self.loopCardMax) characters) all \(open.count) tasks, their checks and the gate; "
                          + "shorten the checks (a script in the repo: --check 'scripts/check-x.sh') or split the work into smaller loops")
        }
        let id = w.id, starter = t.id, title = w.title
        // a paddock the owner trusts for loops (read now, after the awaits): no card. Everything above held all the same
        // (the limits, the sandbox, the idle paddock, the clean tree, the text that fits a card); the Shepherd gets a notice.
        if ws.paddocks.first(where: { $0.id == pid })?.trustLoops == true {
            guard await startLoop(id, loop, paddock: paddock, starter: starter, dir: dir) else {
                throw ProtocolError(code: .unavailable, message: "the loop did not start")
            }
            started = true   // the reservation now belongs to the loop
            let notice = WorkStatusText.loopTrusted(paddock: paddock.name, open, loop)
            Task { [weak self] in try? await self?.asks.inject(to: starter, prompt: notice, afterQuiet: true) }
            return .object(["id": .string(w.id.uuidString.lowercased()), "tasks": .number(Double(open.count)), "state": .string("running")])
        }
        let card = AppCard(kind: .confirm, paddock: pid, paddockName: paddock.name, app: "work-loop", name: "Laço autônomo",
                           base: nil, call: text, command: "run", by: t.id)
        started = true   // the reservation now belongs to the approval
        loopCards[id] = card.id
        Task { [weak self] in
            guard let self else { return }
            let allowed = await self.confirmCard(card, wait: self.config.loopCardWait)
            let withdrawn = await self.takeLoopCard(id)
            guard allowed, !withdrawn else {
                await self.loopDenied(paddock: pid, starter: starter, title: title, withdrawn: withdrawn)
                return
            }
            await self.startLoop(id, loop, paddock: paddock, starter: starter, dir: dir)
        }
        return .object(["id": .string(w.id.uuidString.lowercased()), "tasks": .number(Double(open.count)), "state": .string("awaiting approval")])
    }

    /// The card was answered or expired: forget it. True when `work.stop` had withdrawn it first.
    private func takeLoopCard(_ work: UUID) -> Bool { loopCards.removeValue(forKey: work) == nil }

    private func loopDenied(paddock: UUID, starter: UUID, title: String, withdrawn: Bool) async {
        loopPaddocks.remove(paddock)
        let t = RerailText.clean(title)
        let line = withdrawn ? "[collie] O laço de \"\(t)\" foi cancelado antes da aprovação; nada rodou."
            : "[collie] O dono não aprovou o laço de \"\(t)\"; nada rodou."
        try? await asks.inject(to: starter, prompt: line, afterQuiet: true)
    }

    /// After the owner's Permitir (or at once, in a paddock trusted for loops): the loop's sandbox, its state, the engine.
    /// False: it did not start, and the paddock is free again.
    @discardableResult
    private func startLoop(_ id: UUID, _ loop: WorkLoopState, paddock: Paddock, starter: UUID, dir: URL) async -> Bool {
        // the loop's own profile (the paddock's, strict), made now: it outlives every terminal of the loop
        if config.sandboxHome != nil {
            do { _ = try prepareLoopSandbox(id, paddock: paddock) } catch {
                loopPaddocks.remove(paddock.id)
                try? await asks.inject(to: starter, prompt: "[collie] O laço não começou: o sandbox dele não pôde ser preparado.", afterQuiet: true)
                return false
            }
        }
        do { try await work.update(id) { $0.loop = loop } } catch { loopPaddocks.remove(paddock.id); return false }
        let host = RouterLoopHost(router: self, starter: starter, root: config.paths.root, work: id, paddock: paddock.id, dir: dir,
                                  sandbox: config.sandboxHome.map { (home: $0, shell: config.shell) })
        let engine = WorkLoop(store: work, host: host)
        let pid = paddock.id
        let task = Task { [weak self] in
            _ = await engine.run(work: id, dir: dir)
            await self?.loopEnded(id, starter: starter, paddock: pid)
        }
        workLoops[id] = (engine, task, false)
        return true
    }

    /// `admin.paddock.trust-loops` (app only: no agent command sets it): `--on` trusts the paddock for loops, without it
    /// the card is back. Replies with the state.
    func trustLoops(_ r: Request) async throws -> JSONValue {
        guard let i = ws.paddocks.firstIndex(where: { $0.id.uuidString.caseInsensitiveCompare(str(r, "paddock") ?? "") == .orderedSame }) else {
            throw ProtocolError(code: .notFound, message: "Paddock '\(str(r, "paddock") ?? "")' not found")
        }
        let f = try await setTrustLoops(ws.paddocks[i].id, flag(r, "on")) ?? ws.paddocks[i]
        return .object(["paddock": .string(f.id.uuidString), "name": .string(f.name), "trustLoops": .bool(f.trustLoops == true)])
    }

    /// Trust (or stop trusting) a paddock for loops, saved and told to the app; nil: no such paddock. Also the loop
    /// card's "Sempre neste cercado" (`admin.app.answer --allow --always`).
    @discardableResult
    func setTrustLoops(_ id: UUID, _ on: Bool) async throws -> Paddock? {
        guard let i = ws.paddocks.firstIndex(where: { $0.id == id }) else { return nil }
        ws.paddocks[i].trustLoops = on ? true : nil
        try await persist()
        let f = ws.paddocks[i]
        await hub.emit(.paddock(f))
        return f
    }

    /// The card's one line (the card shows no line breaks): where, the limits, the gate (once), then every task, its
    /// check and its evidence glob (if any), each in «…», which none may hold (agent text: a title must not pass for another entry). nil: it does not fit the card,
    /// and nothing the owner would not see is ever approved.
    static func loopCardText(_ w: Work, _ tasks: [WorkTask], _ l: WorkLoopState, paddock: String) -> String? {
        func quoted(_ x: String) -> String {
            "«" + x.replacingOccurrences(of: "«", with: "‹").replacingOccurrences(of: "»", with: "›") + "»"
        }
        var s = "rodar sem supervisão \(quoted(w.title)) no cercado \(quoted(paddock)): até \(l.max ?? 0) tentativas no total "
            + "(\(l.tries) por tarefa), turno de até \(l.timeout) s, orçamento de \(l.budget ?? 0) s. "
            + (l.gate.map { "portão depois de cada check: \(quoted($0)). " } ?? "")
            + "\(tasks.count) \(tasks.count == 1 ? "tarefa" : "tarefas"), cada uma com o seu check:"
        for (i, t) in tasks.enumerated() { s += " #\(i + 1) \(quoted(t.title)) check \(quoted(t.check ?? ""))"
                + (t.evidenceGlob.map { " evidência \(quoted($0))" } ?? "") + (i < tasks.count - 1 ? ";" : ".")
        }
        return s.count <= Self.loopCardMax ? s : nil
    }

    /// Ends the loop after the current attempt's verdict (the engine records `requested` when it does stop); a loop still waiting for the owner's card: withdraws the card.
    func workStop(_ t: TerminalRecord) async throws -> JSONValue {
        if let w = try await work.active(terminal: t.id), let card = loopCards.removeValue(forKey: w.id) {
            appWaiters.removeValue(forKey: card)?.resume(returning: false)   // the approval task frees the paddock and tells the starter
            await dropAppCard(card)
            return .object(["state": .string("cancelled")])
        }
        guard let w = try await work.active(terminal: t.id), let l = workLoops[w.id], !l.stopping else {
            throw ProtocolError(code: .invalidArgs, message: "no loop is running on '\(t.name)'s work")
        }
        workLoops[w.id]?.stopping = true
        await l.engine.stop(work: w.id)
        return .object(["state": .string("stopped")])
    }

    private func loopEnded(_ id: UUID, starter: UUID, paddock: UUID) async {
        workLoops[id] = nil; loopPaddocks.remove(paddock)
        SandboxLaunch.remove(id, root: config.paths.root)
        guard let w = try? await work.get(id) else { return }
        try? await asks.inject(to: starter, prompt: WorkStatusText.loopEnded(w), afterQuiet: true)
    }

    /// At start: a loop a previous daemon left `running` is `stopped` (its task back to open, its attempt's job gone):
    /// `collie work run` again continues from the next open task.
    func stopLoopsLeftRunning() async {
        guard let all = try? await work.list(includeClosed: true) else { return }
        let now = Date()
        for w in all where w.loop?.state == .running {
            SandboxLaunch.remove(w.id, root: config.paths.root)
            // its agents' records (the processes died with the daemon): named as its loop jobs, in its paddock
            let agents = Set(w.jobs.filter { $0.kind == .loop }.map(\.id))
            for t in ws.terminals where agents.contains(t.name) && t.paddockId == w.paddockId { try? await remove(t) }
            try? await work.update(w.id) { Self.sweepLeftRunning(&$0, now: now) }
        }
    }

    /// What the start sweep writes on a work whose loop a previous daemon left `running`: stopped by `daemonRestart`,
    /// with its note.
    static func sweepLeftRunning(_ x: inout Work, now: Date) {
        for i in x.tasks.indices where x.tasks[i].state == .inProgress && x.tasks[i].id == x.loop?.task { x.tasks[i].state = .open }
        for j in x.jobs.indices where x.jobs[j].kind == .loop && x.jobs[j].state == .running {
            x.jobs[j].state = .gone; x.jobs[j].endedAt = now
        }
        let why = WorkLoopState.Stop(.daemonRestart)
        x.loop?.state = .stopped; x.loop?.endedAt = now; x.loop?.task = nil; x.loop?.stopReason = why
        x.loop?.record(LoopEvent(at: now, kind: .stopped, detail: why.label))
        x.notes.append(WorkNote(at: now, text: why.note))
    }

    /// How long the daemon's stop waits, in all, for its cancelled loops to write their end.
    static let loopCancelWait = Duration.seconds(2)

    /// Daemon stop: the loops end with it, and it waits (`loopCancelWait` in all) for each engine to write `cancelled`.
    /// One still busy after that (a check that ignores the cancel) stays `running` until the next start's sweep
    /// (`daemonRestart`).
    func cancelLoops() async {
        let tasks = workLoops.values.map(\.task)
        workLoops = [:]; loopPaddocks = []
        guard !tasks.isEmpty else { return }
        for t in tasks { t.cancel() }
        // the event is the tasks' own end; the clock only bounds it (a daemon's stop never hangs on a loop)
        let (ended, signal) = AsyncStream<Void>.makeStream()
        Task { for t in tasks { await t.value }; signal.finish() }
        let limit = Task { try? await Task.sleep(for: Self.loopCancelWait); signal.finish() }
        for await _ in ended {}
        limit.cancel()
    }

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

    /// Any terminal of the paddock in a turn but the starter (Shepherds too: the loop's reset would take their edits).
    func loopOthersWorking(paddock: UUID, starter: UUID, dir: URL) async -> String? {
        for t in ws.terminals where t.paddockId == paddock && t.id != starter && Self.loopSharesWorktree(t, dir) {
            if await targetBusy(t.id) { return t.name }
        }
        return nil
    }

    /// A terminal can edit the loop's worktree only when its folder is inside it (or cannot be told): one working
    /// elsewhere in the paddock never blocks the reset. Wrongly counting one is safe; wrongly ignoring one is not.
    static func loopSharesWorktree(_ t: TerminalRecord, _ dir: URL) -> Bool {
        guard !t.cwd.isEmpty else { return true }
        let root = dir.resolvingSymlinksInPath().standardizedFileURL.path
        let there = URL(fileURLWithPath: t.cwd).resolvingSymlinksInPath().standardizedFileURL.path
        return there == root || there.hasPrefix(root + "/") || root.hasPrefix(there + "/")
    }

    func loopTerminalExists(_ id: UUID) -> Bool { ws.terminals.contains { $0.id == id } }

    func loopDismiss(_ id: UUID) async {
        if let t = ws.terminals.first(where: { $0.id == id }) { try? await remove(t) }
    }

    /// The loop's sandbox: the paddock's profile, as an app service gets (strict whatever the workspace's mode: never
    /// wider than a strict terminal of the paddock), under the work's id. Removed when the loop ends.
    func prepareLoopSandbox(_ work: UUID, paddock: Paddock) throws -> URL {
        let project = URL(fileURLWithPath: paddock.path)
        let git = SandboxInput.gitDirs(of: project)
        let input = SandboxInput(terminal: work, project: project, mainGitDir: git.common, worktreeGitDir: git.worktree,
                                 paddockWorktrees: closedPaddocks(project), home: config.sandboxHome ?? URL(fileURLWithPath: NSHomeDirectory()),
                                 collieRoot: config.paths.root, ownFiles: [],
                                 terminalDir: SandboxLaunch.dir(work, root: config.paths.root), socket: config.paths.socket,
                                 agent: .shell, command: nil, grants: [],
                                 appBundle: SandboxInput.appBundle(of: config.collieExecutable), mode: .strict)
        return try SandboxLaunch.prepare(input, root: config.paths.root, collie: config.collieExecutable)
    }

    /// The user's env (their toolchain's PATH), before the allow-list.
    func loopUserEnv() async -> [String: String] {
        UserEnvironment.merge(user: await userEnv.current(), collie: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"],
                              collieBin: config.collieExecutable.deletingLastPathComponent().path)
    }

    /// With a terminal sandbox in force, an attempt's agent must run in one too (a free one is dismissed, the attempt fails).
    func loopAgentSandboxed(_ id: UUID) -> Bool {
        guard config.sandboxHome != nil else { return true }
        return ws.terminals.first { $0.id == id }.map(sandboxed) ?? false
    }

    /// The spec, read again at the attempt: a regular file (no symlink, one link) still inside the starter's project.
    func loopSpec(_ path: String, starter: UUID) async -> String? {
        guard let t = ws.terminals.first(where: { $0.id == starter }), let root = try? await projectRoot(of: t),
              let data = try? Self.readBodyFile(path, allowed: { ProjectRoot.contains($0, root: root) }) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// `LoopHost` over the daemon: summons as the starter (a Shepherd), asks with the daemon's own end of turn, and runs
/// git and the check under the loop's own profile (`<root>/sandbox/<work id>.sb`). `sandbox` nil: the daemon sandboxes no
/// terminal (`--no-terminal-sandbox`, the test daemons), so neither does the loop; else a missing profile throws.
/// Git for a summary's reverts count, with the loop's care (`loopGit`: the repo's own filters off), under the
/// request's sandbox when it has one.
struct LoopRevertGit: RevertGit {
    let dir: URL
    func out(_ args: [String]) async -> String? {
        guard let r = try? await RouterLoopHost.loopGit(args, in: dir, profile: GitRunner.sandbox), r.status == 0, !r.truncated else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RouterLoopHost: LoopHost {
    let router: CommandRouter, starter: UUID, root: URL, work: UUID, paddock: UUID, dir: URL
    let sandbox: (home: URL, shell: String)?

    /// The only keys a check gets from the user's env: the toolchain's, never a token or an agent socket (GH_TOKEN,
    /// SSH_AUTH_SOCK, COLLIE_*). ponytail: a fixed list; a toolchain that needs another key fails its check, add it here.
    static let checkEnvKeys: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR",
                                            "DEVELOPER_DIR", "SDKROOT", "JAVA_HOME", "ANDROID_HOME", "ANDROID_SDK_ROOT", "GOPATH", "GOROOT",
                                            "CARGO_HOME", "RUSTUP_HOME", "NVM_DIR", "PYENV_ROOT", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME"]

    func summon(name: String, for work: Work, loop: WorkLoopState) async throws(ProtocolError) -> UUID {
        // no --paddock: the starter stands in the work's paddock (work.start took it from there)
        var args: [String: JSONValue] = ["name": .string(name)]
        if let p = loop.preset { args["preset"] = .string(p) }
        if let m = loop.model { args["model"] = .string(m) }
        if let c = loop.command { args["command"] = .string(c) }
        let id = try await router.loopSummon(Request(id: "loop", terminalId: starter.uuidString, command: "summon", args: args), as: starter)
        guard await router.loopAgentSandboxed(id) else {
            await router.loopDismiss(id)
            throw ProtocolError(code: .unauthorized, message: "'\(name)' started without a sandbox")
        }
        return id
    }

    func ask(_ terminal: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> AskResult.Source {
        try await router.asks.ask(from: starter, to: terminal, prompt: prompt, raw: false, timeout: timeout).source
    }

    func working(_ terminal: UUID) async -> Bool { await router.targetBusy(terminal) }
    func othersWorking() async -> String? { await router.loopOthersWorking(paddock: paddock, starter: starter, dir: dir) }
    func starterAlive() async -> Bool { await router.loopTerminalExists(starter) }
    func dismiss(_ terminal: UUID) async { await router.loopDismiss(terminal) }
    func taskEnded(_ line: String) async { try? await router.asks.inject(to: starter, prompt: line, afterQuiet: true) }

    /// The loop's profile; nil only when no terminal is sandboxed. Never nil because it went missing.
    func profile() throws(ProtocolError) -> URL? {
        guard sandbox != nil else { return nil }
        let f = SandboxLaunch.profileFile(work, root: root)
        guard FileManager.default.fileExists(atPath: f.path) else {
            throw ProtocolError(code: .unavailable, message: "the loop's sandbox profile is gone; nothing of the loop runs unsandboxed")
        }
        return f
    }

    func git(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult {
        try await Self.loopGit(args, in: dir, profile: try profile())
    }

    /// Git for the loop, in an agent-writable repo: under `profile`, hooks and fsmonitor off (GitRunner), and the filter
    /// drivers the repo's own config defines (local/worktree scope: what an agent can plant), external diffs and textconv off.
    /// The user's global drivers (git-lfs) stay.
    static func loopGit(_ args: [String], in dir: URL, profile: URL?) async throws(ProtocolError) -> ProcessResult {
        do {
            return try await GitRunner.$sandbox.withValue(profile) {
                var off = [("diff.external", "")]
                let cfg = try await GitRunner.run(["config", "--show-scope", "-z", "--name-only", "--get-regexp", #"^filter\."#], in: dir, timeout: .seconds(30))
                let f = cfg.stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
                var names: Set<String> = []
                for i in stride(from: 0, to: f.count - 1, by: 2) where !["global", "system"].contains(f[i]) {
                    let key = f[i + 1]   // filter.<name>.<var>; the name may hold dots and spaces
                    guard key.hasPrefix("filter."), let dot = key.lastIndex(of: "."), dot > key.index(key.startIndex, offsetBy: 6) else { continue }
                    names.insert(String(key[key.index(key.startIndex, offsetBy: 7)..<dot]))
                }
                for n in names.sorted() {
                    off += [("filter.\(n).clean", ""), ("filter.\(n).smudge", ""), ("filter.\(n).process", ""), ("filter.\(n).required", "false")]
                }
                var a = args
                if a.first == "diff" { a.insert(contentsOf: ["--no-ext-diff", "--no-textconv"], at: 1) }
                // by env, not `-c`: a driver name may hold `=`
                return try await GitRunner.run(a, in: dir, timeout: .seconds(120), config: off)
            }
        } catch { throw (error as? ProtocolError) ?? ProtocolError(code: .internal, message: "\(error)") }
    }

    func check(_ command: String, in dir: URL, timeout: Duration) async throws(ProtocolError) -> ProcessResult {
        let profile = try profile()
        let env = Self.checkEnv(await router.loopUserEnv(), sandbox: sandbox.map { (work, root, $0.shell, $0.home) })
        return try await Self.runCheck(command, in: dir, profile: profile, env: env, timeout: timeout)
    }

    /// The allow-listed user env; sandboxed, the loop's shims first on PATH (SwiftPM and xcodebuild can't nest a sandbox)
    /// and HOME the sandbox's. Never a COLLIE_ key.
    static func checkEnv(_ user: [String: String], sandbox: (id: UUID, root: URL, shell: String, home: URL)?) -> [String: String] {
        var e = user.filter { checkEnvKeys.contains($0.key) }
        if let s = sandbox { e = SandboxLaunch.environment(e, id: s.id, root: s.root, shell: s.shell, home: s.home) }
        return e.filter { !$0.key.hasPrefix("COLLIE_") }
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
    func exists(_ path: String, in dir: URL) async -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path, isDirectory: &isDir) && !isDir.boolValue
    }
    func patchDir(_ work: UUID) -> URL { root.appendingPathComponent("work-loops").appendingPathComponent(work.uuidString.lowercased()) }
    func now() -> Date { Date() }
}
