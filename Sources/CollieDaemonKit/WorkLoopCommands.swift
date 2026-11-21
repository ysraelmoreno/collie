import Foundation
import CryptoKit
import os
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
        // M3.5: absent is 1 (the loop as always); more runs tasks in lanes, which exist only sandboxed and are named by
        // the task's id
        let parallel = try num(r, "parallel", max: Double(TaskScheduler.maxParallel)).map { Int($0) }
        if let parallel, parallel > 1 {
            guard config.sandboxHome != nil else { throw invalid("--parallel needs the terminal sandbox: a lane's agent, check and git run only sandboxed") }
            for t in open { try LaneWorktree.validate(task: t.id) }
        }
        let notify = try Self.loopNotify(str(r, "notify"))
        let loop = WorkLoopState(state: .running, tries: Int(try num(r, "tries", max: Self.loopTriesMax) ?? 3),
                                 timeout: Int(try num(r, "timeout", max: Self.loopTimeoutMax) ?? 3600),
                                 preset: str(r, "preset"), model: str(r, "model"), command: str(r, "command"),
                                 max: max, used: 0, budget: Int(try num(r, "budget", max: Self.loopBudgetMax) ?? Self.loopBudgetDefault),
                                 spent: 0, tasks: open.map(\.id), gate: gate, startedAt: Date(), parallel: parallel, notify: notify)
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

    /// M5.1: `--notify` absent is `end` for a new loop (a loop already running keeps what its state says: nil, `task`);
    /// anything but task|end is refused (M3c.4).
    static func loopNotify(_ v: String?) throws(ProtocolError) -> WorkLoopState.Notify {
        guard let v else { return .end }
        guard let n = WorkLoopState.Notify(rawValue: v) else { throw ProtocolError(code: .invalidArgs, message: "--notify must be task|end") }
        return n
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

    /// The card's one line (the card shows no line breaks): where, the limits, `--parallel` (over 1 only), the gate (once),
    /// then every task, its check, its evidence glob, its `scope` and its `needs` (those it has), each in «…», which none
    /// may hold (agent text: a title must not pass for another entry). nil: it does not fit the card,
    /// and nothing the owner would not see is ever approved.
    static func loopCardText(_ w: Work, _ tasks: [WorkTask], _ l: WorkLoopState, paddock: String) -> String? {
        func quoted(_ x: String) -> String {
            "«" + x.replacingOccurrences(of: "«", with: "‹").replacingOccurrences(of: "»", with: "›") + "»"
        }
        var s = "rodar sem supervisão \(quoted(w.title)) no cercado \(quoted(paddock)): até \(l.max ?? 0) tentativas no total "
            + "(\(l.tries) por tarefa), turno de até \(l.timeout) s, orçamento de \(l.budget ?? 0) s. "
            + (l.parallel.flatMap { $0 > 1 ? "até \($0) tarefas ao mesmo tempo, cada uma na sua faixa (--parallel \($0)). " : nil } ?? "")
            + (l.gate.map { "portão depois de cada check: \(quoted($0)). " } ?? "")
            + (l.notify == .end ? "avisos: só no fim (--notify end). " : "")
            + "\(tasks.count) \(tasks.count == 1 ? "tarefa" : "tarefas"), cada uma com o seu check:"
        // M3.6: each glob and each id in its own «…» (a glob with a comma never passes for two)
        func list(_ label: String, _ xs: [String]?) -> String {
            xs.flatMap { $0.isEmpty ? nil : " \(label) " + $0.map(quoted).joined(separator: " ") } ?? ""
        }
        for (i, t) in tasks.enumerated() { s += " #\(i + 1) \(quoted(t.title)) check \(quoted(t.check ?? ""))"
                + (t.evidenceGlob.map { " evidência \(quoted($0))" } ?? "") + list("escopo", t.scope) + list("depende de", t.needs)
                + (i < tasks.count - 1 ? ";" : ".")
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

    /// M3.6: the lanes the engine left (it removes its own: none, but for a fall in between) go before the loop's profile does.
    func loopEnded(_ id: UUID, starter: UUID, paddock: UUID) async {
        workLoops[id] = nil; loopPaddocks.remove(paddock)
        if let w = try? await work.get(id) {
            await removeLanes(of: w)
            if w.loop?.lanes != nil { try? await work.update(id) { $0.loop?.lanes = nil } }
        }
        SandboxLaunch.remove(id, root: config.paths.root)
        guard let w = try? await work.get(id) else { return }
        try? await asks.inject(to: starter, prompt: WorkStatusText.loopEnded(w), afterQuiet: true)
    }

    /// M3.6: what is left on disk of the lanes of `w`'s loop goes: worktree, branch and the lane's sandbox files.
    /// Idempotent. A loop that never had a lane (no `--parallel` over 1, none on record) costs no git: it ends exactly
    /// as before lanes.
    /// M3b.1: the same git as the lanes' birth (`laneGit`: the daemon's, outside the loop's profile), at the loop's end
    /// and in the start sweep alike: no profile is needed, or made, to remove a lane.
    /// M3b.5: only `w`'s own lanes (never another work's, on record or not), and of those only the ones this daemon
    /// marked (`LaneWorktree.sweep`); one without the mark stays, with a note on `w`.
    func removeLanes(of w: Work) async {
        guard (w.loop?.parallel ?? 1) > 1 || w.loop?.lanes?.isEmpty == false,
              let p = ws.paddocks.first(where: { $0.id == w.paddockId }), !p.isFolder else { return }
        let host = laneSweepHost(p, work: w.id, starter: w.terminalId)
        let id = w.id
        let s = await LaneWorktree.sweep(await LaneWorktree.lanes(of: id, repoRoot: URL(fileURLWithPath: p.repoRoot), host: host), host: host) { $0 == id }
        for lane in s.removed { await host.laneGone(lane) }
        guard let note = Self.sparedNote(s) else { return }
        try? await work.update(w.id) { x in if x.notes.last?.text != note { x.notes.append(WorkNote(at: Date(), text: note)) } }
    }

    /// M3b.5: at start, the lanes of no work on record (one removed while its loop ran) that this daemon marked go
    /// too; the others stay, with a line in the daemon's log. One `for-each-ref` per repository with a paddock.
    /// ponytail: such a lane's sandbox files stay (`laneGone` needs its work's id); harmless, they only take space.
    func sweepOrphanLanes() async {
        guard let all = try? await work.list(includeClosed: true) else { return }
        let known = Set(all.map(\.id))
        var seen: Set<String> = []
        for p in ws.paddocks where !p.isFolder && seen.insert(p.repoRoot).inserted {
            let host = laneSweepHost(p, work: UUID(), starter: UUID())
            let s = await LaneWorktree.sweep(await LaneWorktree.orphans(repoRoot: URL(fileURLWithPath: p.repoRoot), knownWork: known, host: host), host: host) { !known.contains($0) }
            if let note = Self.sparedNote(s) { FileHandle.standardError.write(Data("collied: \(note)\n".utf8)) }
        }
    }

    private func laneSweepHost(_ p: Paddock, work: UUID, starter: UUID) -> RouterLoopHost {
        RouterLoopHost(router: self, starter: starter, root: config.paths.root, work: work, paddock: p.id,
                       dir: URL(fileURLWithPath: p.path), sandbox: config.sandboxHome.map { (home: $0, shell: config.shell) })
    }

    /// M3c.3: the lanes already noted by this daemon (repository and branch). A spared lane stays until someone removes
    /// it; one note per daemon says so, not one at every end of its work's loop.
    private static let notedLanes = OSAllocatedUnfairLock(initialState: Set<String>())

    /// The note for what `s` left behind that this daemon has not noted yet; nil when there is none.
    static func sparedNote(_ s: LaneWorktree.Swept) -> String? {
        func fresh(_ ls: [Lane]) -> String {
            ls.filter { l in notedLanes.withLock { $0.insert(l.repoRoot.path + " " + l.branch).inserted } }.map(\.branch).joined(separator: ", ")
        }
        let spared = fresh(s.spared), refused = fresh(s.refused)
        let parts = [spared.isEmpty ? nil : "faixa não removida (sem a marca deste daemon: de outro daemon ou do dono): " + spared,
                     refused.isEmpty ? nil : "faixa marcada não removida (a pasta não é a da faixa: movida ou trocada por symlink): " + refused]
            .compactMap { $0 }
        return parts.isEmpty ? nil : "[loop] " + parts.joined(separator: "; ")
    }


    /// At start: a loop a previous daemon left `running` is `stopped` (its task back to open, its attempt's job gone):
    /// `collie work run` again continues from the next open task. M3.6: its lanes go first (no orphan lane is left
    /// behind), the tasks that ran in them are open again and `lanes` is empty.
    func stopLoopsLeftRunning() async {
        guard let all = try? await work.list(includeClosed: true) else { return }
        let now = Date()
        for w in all where w.loop?.state == .running {
            await removeLanes(of: w)
            SandboxLaunch.remove(w.id, root: config.paths.root)
            // its agents' records (the processes died with the daemon)
            for t in Self.loopAgents(of: w, in: ws.terminals) { try? await remove(t) }
            try? await work.update(w.id) { Self.sweepLeftRunning(&$0, now: now) }
        }
        await sweepOrphanLanes()
    }

    /// M3.8: the terminals of `w`'s loop attempts, in its paddock: those whose id is on a loop job (`WorkJob.terminal`),
    /// whatever they are called. A job with no terminal on record (a work written before the field, or a daemon that
    /// fell between the summon and its write) still finds its agent by the job's id, the name it was summoned with.
    static func loopAgents(of w: Work, in terminals: [TerminalRecord]) -> [TerminalRecord] {
        let jobs = w.jobs.filter { $0.kind == .loop }
        let ids = Set(jobs.compactMap(\.terminal)), named = Set(jobs.filter { $0.terminal == nil }.map(\.id))
        return terminals.filter { $0.paddockId == w.paddockId && (ids.contains($0.id) || named.contains($0.name)) }
    }

    /// What the start sweep writes on a work whose loop a previous daemon left `running`: stopped by `daemonRestart`,
    /// with its note. M3.6: the tasks that ran in lanes are open again too, and no lane stays on record.
    static func sweepLeftRunning(_ x: inout Work, now: Date) {
        let inLanes = Set(x.loop?.lanes?.map(\.task) ?? [])
        for i in x.tasks.indices where x.tasks[i].state == .inProgress && (x.tasks[i].id == x.loop?.task || inLanes.contains(x.tasks[i].id)) {
            x.tasks[i].state = .open
            // a lane's commits went with the lane: nothing of it is ever adopted (in the paddock's worktree, what
            // came after `resumeFrom` is other lanes' merges)
            if inLanes.contains(x.tasks[i].id) { x.tasks[i].forgetResume(); continue }
            // M2b.1: the latest the fallen attempt can have committed: a commit made after this is never adopted.
            // ponytail: the sweep's time, not the fall's (nobody saw it): what the owner commits between a crash and
            // this start can still be adopted, and a failed adoption deletes nothing. A heartbeat if that gap matters.
            // M2c: an adoption that fell keeps the `resumeAt` of the first fall (never moved forward)
            if x.tasks[i].resumeFrom != nil, x.tasks[i].resumeAt == nil { x.tasks[i].resumeAt = now }
        }
        for j in x.jobs.indices where x.jobs[j].kind == .loop && x.jobs[j].state == .running {
            x.jobs[j].state = .gone; x.jobs[j].endedAt = now
        }
        let why = WorkLoopState.Stop(.daemonRestart)
        x.loop?.state = .stopped; x.loop?.endedAt = now; x.loop?.task = nil; x.loop?.stopReason = why; x.loop?.lanes = nil
        x.loop?.record(LoopEvent(at: now, kind: .stopped, detail: why.label))
        x.notes.append(WorkNote(at: now, text: why.note))
    }

    /// How long the daemon's stop waits, in all, for its cancelled loops to write their end.
    static let loopCancelWait = Duration.seconds(2)

    /// Daemon stop: the loops end with it, and it waits (`wait` in all) for each engine to write `cancelled`.
    /// One still busy after that (a check that ignores the cancel) stays `running` until the next start's sweep
    /// (`daemonRestart`). `wait` is a parameter for the tests (M2b.2); the daemon always passes the default.
    /// M3.6: then the lanes still on disk go (a loop that ended in time already removed its own: nothing to do).
    /// M3b.6: only a loop that ended: one still busy may be integrating in a lane (its cancelled gate unwinding), and its
    /// lanes stay for the next start's sweep (`daemonRestart`), never removed under a merge.
    func cancelLoops(wait: Duration = CommandRouter.loopCancelWait) async {
        let loops = workLoops.map { (id: $0.key, task: $0.value.task) }
        workLoops = [:]; loopPaddocks = []
        guard !loops.isEmpty else { return }
        for l in loops { l.task.cancel() }
        // the event is the tasks' own end; the clock only bounds it (a daemon's stop never hangs on a loop)
        let (ended, signal) = AsyncStream<UUID>.makeStream()
        Task {
            await withTaskGroup(of: Void.self) { g in for l in loops { g.addTask { await l.task.value; signal.yield(l.id) } } }
            signal.finish()
        }
        let limit = Task { try? await Task.sleep(for: wait); signal.finish() }
        var done: [UUID] = []
        for await id in ended { done.append(id) }
        limit.cancel()
        for id in done { if let w = try? await work.get(id) { await removeLanes(of: w) } }
    }

    // MARK: what RouterLoopHost needs from the router

    /// `lane` (M3.3): the agent is born in the work's paddock (no `--paddock`) with the lane as its folder and project.
    func loopSummon(_ r: Request, as starter: UUID, lane: URL? = nil) async throws(ProtocolError) -> UUID {
        let v: JSONValue
        do {
            if let lane {
                guard let me = ws.terminals.first(where: { $0.id == starter }), me.isShepherd else {
                    throw ProtocolError(code: .notShepherd, message: "a lane's agent is summoned as the loop's Shepherd")
                }
                v = try await summon(r, by: me, lane: lane)
            } else { v = try await shepherd(r, from: starter) }
        } catch {
            throw (error as? ProtocolError) ?? ProtocolError(code: .internal, message: "\(error)")
        }
        guard case .object(let o) = v, case .string(let s)? = o["id"], let id = UUID(uuidString: s) else {
            throw ProtocolError(code: .internal, message: "summon returned no terminal id")
        }
        return id
    }

    /// Any terminal of the paddock in a turn but the starter (Shepherds too: the loop's reset would take their edits).
    /// M3.3: `dir` is the host's own tree: a lane's host counts only what reaches its lane.
    /// M3b.2: `starter` nil counts the starter too (`anyoneWorking`).
    func loopOthersWorking(paddock: UUID, starter: UUID?, dir: URL) async -> String? {
        for t in Self.loopReaching(ws.terminals, paddock: paddock, starter: starter, dir: dir) {
            if await targetBusy(t.id) { return t.name }
        }
        return nil
    }

    /// M3c.2: who is in a turn in `dir`, the starter included, unless all the starter has open in the daemon is its
    /// `work.wait`/`work.status` of `work` (the recommended flow: the Shepherd blocked in `collie work wait`). Any other
    /// request of the starter's (an `ask`, another command) counts it, as do the paddock's other terminals.
    /// M3d.1: a wait counts only while its client lives (`work.wait` is cancelled when its client closes the socket; a
    /// pid gone is not a wait) and no tool call of the terminal came after it began (a wait in the background).
    /// ponytail: an edit beside a background wait is seen through Claude's PostToolUse only (no hook, no stamp); the
    /// integrator's diff of the tracked files still keeps such an edit.
    func loopAnyoneWorking(paddock: UUID, starter: UUID, work: UUID, dir: URL) async -> String? {
        await loopOthersWorking(paddock: paddock, starter: loopStarterOnlyWaits(starter, work: work) ? starter : nil, dir: dir)
    }

    /// M3d.1: the starter's open requests are all live waits on `work` (and there is one).
    func loopStarterOnlyWaits(_ starter: UUID, work: UUID) -> Bool {
        let live = Self.liveWaits(ownWaits[starter]?.values.map { $0 } ?? [], on: work, lastToolCall: lastToolCall[starter])
        return Self.loopStarterWaits(open: openRequests[starter] ?? 0, waitsOnWork: live)
    }

    /// M3c.2: every request the starter has open is a wait on the loop's work (and there is one).
    static func loopStarterWaits(open: Int, waitsOnWork: Int) -> Bool { waitsOnWork > 0 && open == waitsOnWork }

    /// One `work.wait`/`work.status` of a terminal on its own work: `pid` its client, `seq` when it began.
    struct OwnWait: Sendable { let work: UUID, pid: pid_t, seq: Int }

    /// M3d.1: the waits on `work` that still stand for a terminal only waiting: the client alive, no tool call since.
    static func liveWaits(_ waits: [OwnWait], on work: UUID, lastToolCall: Int?, alive: (pid_t) -> Bool = clientAlive) -> Int {
        waits.filter { $0.work == work && (lastToolCall ?? -1) < $0.seq && alive($0.pid) }.count
    }
    /// ponytail: a pid reused by another process reads as alive; the socket's EOF (the handler cancelled) covers a closed client.
    static func clientAlive(_ pid: pid_t) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }

    /// The waits counted by work (what M3c.2 kept): diagnostics and tests.
    var ownWorkWaits: [UUID: [UUID: Int]] {
        ownWaits.mapValues { Dictionary($0.values.map { ($0.work, 1) }, uniquingKeysWith: +) }
    }

    func requestBegan(_ t: UUID) { openRequests[t, default: 0] += 1 }
    func requestEnded(_ t: UUID) {
        openRequests[t, default: 1] -= 1
        if openRequests[t] ?? 0 <= 0 { openRequests[t] = nil }
    }
    /// A wait began: its token, for `ownWaitEnded`.
    func ownWaitBegan(_ t: UUID, on work: UUID, pid: pid_t) -> UUID {
        let token = UUID()
        activitySeq += 1
        ownWaits[t, default: [:]][token] = OwnWait(work: work, pid: pid, seq: activitySeq)
        return token
    }
    func ownWaitEnded(_ t: UUID, _ token: UUID) {
        ownWaits[t]?[token] = nil
        if ownWaits[t]?.isEmpty == true { ownWaits[t] = nil }
    }
    /// Claude's PostToolUse of `t`: a turn of its own, beside any wait it began before.
    func toolCalled(_ t: UUID) {
        activitySeq += 1
        lastToolCall[t] = activitySeq   // ponytail: one Int per terminal ever seen, not dropped with the terminal
    }

    /// The paddock's terminals, but the starter, that can edit the tree `dir` (the paddock's worktree, or one lane).
    /// For a lane: not the other lanes' agents, nor a terminal in the paddock's worktree (that tree is the integrator's, M3.4).
    static func loopReaching(_ terminals: [TerminalRecord], paddock: UUID, starter: UUID?, dir: URL) -> [TerminalRecord] {
        terminals.filter { $0.paddockId == paddock && $0.id != starter && loopSharesWorktree($0, dir) }
    }

    /// A terminal can edit the loop's worktree only when its folder is inside it (or cannot be told): one working
    /// elsewhere in the paddock never blocks the reset. Wrongly counting one is safe; wrongly ignoring one is not.
    static func loopSharesWorktree(_ t: TerminalRecord, _ dir: URL) -> Bool {
        guard !t.cwd.isEmpty else { return true }
        let root = dir.resolvingSymlinksInPath().standardizedFileURL.path
        let there = URL(fileURLWithPath: t.cwd).resolvingSymlinksInPath().standardizedFileURL.path
        return there == root || there.hasPrefix(root + "/") || root.hasPrefix(there + "/")
    }

    /// M3.5: the sandbox profile of one lane of the loop (`prepareLoopSandbox`), made when the lane is.
    func loopLaneSandbox(_ work: UUID, paddock: UUID, lane: Lane) throws(ProtocolError) {
        guard let p = ws.paddocks.first(where: { $0.id == paddock }) else {
            throw ProtocolError(code: .notFound, message: "the loop's paddock is gone")
        }
        do { _ = try prepareLoopSandbox(work, paddock: p, lane: lane) } catch {
            throw (error as? ProtocolError) ?? ProtocolError(code: .unavailable, message: "the lane's sandbox could not be prepared: \(error)")
        }
    }

    /// M3.8: the names a summon would refuse: the terminals', the panels' and those being launched.
    func loopNamesTaken() -> Set<String> {
        Set(ws.terminals.map { $0.name.lowercased() } + ws.panels.map { $0.name.lowercased() }).union(launching)
    }

    func loopTerminalExists(_ id: UUID) -> Bool { ws.terminals.contains { $0.id == id } }

    func loopDismiss(_ id: UUID) async {
        if let t = ws.terminals.first(where: { $0.id == id }) { try? await remove(t) }
    }

    /// The loop's sandbox: the paddock's profile, as an app service gets (strict whatever the workspace's mode: never
    /// wider than a strict terminal of the paddock), under the work's id. Removed when the loop ends.
    /// `lane` (M3.3): that lane's own profile, under `laneSandboxId`: the same strict profile with the lane as the
    /// project, closed (read and write) to the paddock's worktree and to every other lane. A lane that is not a
    /// worktree of the paddock's repository throws: no profile is guessed.
    func prepareLoopSandbox(_ work: UUID, paddock: Paddock, lane: Lane? = nil) throws -> URL {
        let project = try lane.map { try Self.vetLane($0.path, paddock: paddock) } ?? URL(fileURLWithPath: paddock.path)
        let git = SandboxInput.gitDirs(of: project)
        var input = SandboxInput(terminal: lane.map { Self.laneSandboxId(work, $0) } ?? work, project: project, mainGitDir: git.common, worktreeGitDir: git.worktree,
                                 paddockWorktrees: closedPaddocks(project), home: config.sandboxHome ?? URL(fileURLWithPath: NSHomeDirectory()),
                                 collieRoot: config.paths.root, ownFiles: [],
                                 terminalDir: SandboxLaunch.dir(work, root: config.paths.root), socket: config.paths.socket,
                                 agent: .shell, command: nil, grants: [],
                                 appBundle: SandboxInput.appBundle(of: config.collieExecutable), mode: .strict)
        if lane != nil {
            input.terminalDir = SandboxLaunch.dir(input.terminal, root: config.paths.root)
            input.lanePaddock = URL(fileURLWithPath: paddock.path)
        }
        return try SandboxLaunch.prepare(input, root: config.paths.root, collie: config.collieExecutable)
    }

    /// The id a lane's profile and files live under (`<root>/sandbox/<id>`): from the work and the lane's branch, so
    /// whoever knows the lane (the loop's end, the start sweep: M3.6) finds them again with nothing stored.
    static func laneSandboxId(_ work: UUID, _ lane: Lane) -> UUID {
        let h = Array(SHA256.hash(data: Data("\(work.uuidString.lowercased())/\(lane.branch)".utf8)).prefix(16))
        return NSUUID(uuidBytes: h) as UUID
    }

    /// The user's env (their toolchain's PATH), before the allow-list.
    func loopUserEnv() async -> [String: String] {
        UserEnvironment.merge(user: await userEnv.current(), collie: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"],
                              collieBin: config.collieExecutable.deletingLastPathComponent().path)
    }

    /// With a terminal sandbox in force, an attempt's agent must run in one too (a free one is dismissed, the attempt fails).
    /// A lane's agent (M3.3) also when no terminal is sandboxed (then never): sandboxed, strict, the lane its project.
    func loopAgentSandboxed(_ id: UUID, lane: URL? = nil) -> Bool {
        let t = ws.terminals.first { $0.id == id }
        if let lane {
            guard let t, sandboxed(t), t.startMode == .strict, lanePaddock(of: t) != nil else { return false }
            return t.projectRoot == SignedAppCheck.realPath(lane)
        }
        guard config.sandboxHome != nil else { return true }
        return t.map(sandboxed) ?? false
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

/// M3b.1: git for the lanes' birth and removal: (args, dir, sandbox profile or nil).
typealias LaneGit = @Sendable (_ args: [String], _ dir: URL, _ profile: URL?) async throws(ProtocolError) -> ProcessResult

struct RouterLoopHost: LoopHost {
    let router: CommandRouter, starter: UUID, root: URL, work: UUID, paddock: UUID, dir: URL
    let sandbox: (home: URL, shell: String)?
    /// M3.3. nil: the paddock's host (`dir` its worktree), exactly as before lanes. A lane's host (`forLane`): `dir` is
    /// the lane, git and the check run under the lane's own profile, its agent is born in the lane, and it refuses to
    /// run anything when the daemon sandboxes no terminal.
    var lane: Lane? = nil
    /// M3b.1: what runs the lanes' own git (`laneGit`), with the profile it is given: always none. A test's fake
    /// records that profile.
    var laneRunner: LaneGit = RouterLoopHost.loopGit

    /// This host for one lane of the loop: cheap, one per lane.
    func forLane(_ lane: Lane) -> RouterLoopHost {
        RouterLoopHost(router: router, starter: starter, root: root, work: work, paddock: paddock, dir: lane.path, sandbox: sandbox, lane: lane)
    }

    /// M3.5: the lane's host, its profile made first. Without a terminal sandbox there is none to make, and `profile`
    /// refuses everything the lane would run.
    func laneHost(_ lane: Lane) async throws(ProtocolError) -> any LoopHost {
        if sandbox != nil { try await router.loopLaneSandbox(work, paddock: paddock, lane: lane) }
        return forLane(lane)
    }
    func laneGone(_ lane: Lane) async { SandboxLaunch.remove(CommandRouter.laneSandboxId(work, lane), root: root) }

    /// What the profile and its shims live under: the work, or the lane's own id.
    var sandboxId: UUID { lane.map { CommandRouter.laneSandboxId(work, $0) } ?? work }

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
        let id = try await router.loopSummon(Request(id: "loop", terminalId: starter.uuidString, command: "summon", args: args), as: starter,
                                             lane: lane?.path)
        guard await router.loopAgentSandboxed(id, lane: lane?.path) else {
            await router.loopDismiss(id)
            throw ProtocolError(code: .unauthorized, message: "'\(name)' started without a sandbox")
        }
        return id
    }

    func ask(_ terminal: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> AskResult.Source {
        try await router.asks.ask(from: starter, to: terminal, prompt: prompt, raw: false, timeout: timeout).source
    }
    func resubmitted(_ terminal: UUID) async -> Bool { await router.asks.submitRetried(terminal) }

    func working(_ terminal: UUID) async -> Bool { await router.targetBusy(terminal) }
    func usageLimit(_ terminal: UUID) async -> String? {
        guard let s = await router.asks.screen(terminal, quiet: .seconds(10)) else { return nil }
        return UsageLimit.detect(s.lines, quiet: s.quiet)
    }
    func othersWorking() async -> String? { await router.loopOthersWorking(paddock: paddock, starter: starter, dir: dir) }
    func anyoneWorking() async -> String? { await router.loopAnyoneWorking(paddock: paddock, starter: starter, work: work, dir: dir) }
    func starterAlive() async -> Bool { await router.loopTerminalExists(starter) }
    func namesTaken() async -> Set<String> { await router.loopNamesTaken() }
    func dismiss(_ terminal: UUID) async { await router.loopDismiss(terminal) }
    func taskEnded(_ line: String) async { try? await router.asks.inject(to: starter, prompt: line, afterQuiet: true) }

    /// The loop's profile; nil only when no terminal is sandboxed. Never nil because it went missing.
    func profile() throws(ProtocolError) -> URL? {
        guard sandbox != nil else {
            // the paddock's host follows the daemon (no terminal sandbox, none here); a lane never runs without its profile
            if lane != nil { throw ProtocolError(code: .unavailable, message: "a lane runs only sandboxed, and this daemon sandboxes no terminal") }
            return nil
        }
        let f = SandboxLaunch.profileFile(sandboxId, root: root)
        guard FileManager.default.fileExists(atPath: f.path) else {
            throw ProtocolError(code: .unavailable, message: "the loop's sandbox profile is gone; nothing of the loop runs unsandboxed")
        }
        return f
    }

    func git(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult {
        try await Self.loopGit(args, in: dir, profile: try profile())
    }

    /// M3b.1: the daemon's own git, as `PaddockManager` runs for a paddock's worktree: no profile (the loop's cannot
    /// write a lane), with `loopGit`'s care (hooks, fsmonitor and the repo's own filters off: `worktree add` checks out).
    func laneGit(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult {
        try await laneRunner(args, dir, nil)
    }
    /// M3b.5: the install id (`remote/install-id` of this daemon's root): a dev daemon and the installed one differ.
    func laneOwner() async -> String { (try? await router.remoteInstallId()) ?? "" }

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
        let env = Self.checkEnv(await router.loopUserEnv(), sandbox: sandbox.map { (sandboxId, root, $0.shell, $0.home) })
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
    /// A lane's patches (and evidence) in its own subfolder, `lanes/<the lane's folder name>`: never mixed with another lane's.
    func patchDir(_ work: UUID) -> URL {
        let d = root.appendingPathComponent("work-loops").appendingPathComponent(work.uuidString.lowercased())
        return lane.map { d.appendingPathComponent("lanes").appendingPathComponent($0.path.lastPathComponent) } ?? d
    }
    func now() -> Date { Date() }
}
