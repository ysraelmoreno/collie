import Foundation
import CollieCore
import CollieProtocol

/// M3.5, `collie work run --parallel N`: the loop's parallel path. `runLanes` is the scheduler: at every change it asks
/// `TaskScheduler.ready` and gives each ready task a lane (M3.2), the lane's host (M3.3) and an engine of its own (a
/// `WorkLoop` with `lane` set) that runs the same `attempt` there. An attempt that passes in its lane goes to the
/// `LaneIntegrator` (M3.4), and only an integrated task is `done`. The paddock's worktree is touched by the
/// integrator alone. No lane outlives `runLanes`.
///
/// The counters are the loop's, in the work's file, written through the store (an actor): `used` is raised here, by
/// the one scheduler, before a lane starts (so the attempts running count against `--max`), `spent` grows by each
/// lane's own seconds when it ends (`--budget` is the sum of the lanes' time, not the wall clock), and `tries` is the
/// task's, written by its lane. M3b.4: the lanes alive count against `--budget` too, by when each began (`unspent`):
/// what a lane may still take is what nobody used, shared by the lanes alive (`laneShare`).
extension WorkLoop {
    /// What wakes the scheduler: a lane ended (its task's id), or something else changed (a stop was asked, a lane
    /// went to the integrator).
    enum Wake: Sendable { case ended(String), poke }

    /// One parallel run's state, on the loop's own engine.
    struct Lanes {
        /// Tasks that passed in their lane and are with the integrator: no slot, their scope still taken.
        var integrating: Set<String> = []
        /// The first lane that said the loop must stop, and why.
        var stop: WorkLoopState.Stop?
        /// M3b.6: the integrations running, by task, and whether the daemon's stop cancelled them (only it does: a
        /// budget spent or the owner's stop still lets a merge end integrated or undone, as before).
        var integrations: [String: Task<LaneIntegrator.Result?, Never>] = [:]
        var aborted = false
        let signal: AsyncStream<Wake>.Continuation
    }

    /// An attempt that passed in its lane (`markDone`), kept until the integrator answers.
    struct Passed: Sendable {
        let task: WorkTask, name: String, n: Int, tries: Int, at: Date, evidence: TaskEvidence
        /// The lane's base and the commit that was judged, in the lane `dir`; `head`: the short sha of `judged`.
        let before: String, judged: String, head: String, dir: URL
    }

    /// The parallel loop: how it ended and why (nil: it finished). `run` writes the end, as for the sequential path.
    func runLanes(work id: UUID, dir: URL, parallel: Int) async -> (WorkLoopState.State, WorkLoopState.Stop?) {
        guard let root = await repoRoot(dir) else {
            await note(id, "[loop] git falhou em \(dir.path); laço parado")
            return (.stopped, .init(.gitFailed))
        }
        let integrator = LaneIntegrator(host: host, dir: dir)
        await integrator.clearQuarantine()   // M6.3: what the last loop's gates left goes now
        let (woken, signal) = AsyncStream<Wake>.makeStream()
        lanes[id] = Lanes(signal: signal)
        var alive: [String: Task<Void, Never>] = [:]   // by task: running in its lane, or with the integrator
        var slots: [String: Int] = [:]   // M3.8, by task: its lane's number, the lowest free one (the agent's `f<n>`)
        var end = WorkLoopState.State.stopped, stop: WorkLoopState.Stop?
        signal.yield(.poke)   // the first look
        // no clock: the scheduler looks again only when something changed (a cancelled daemon ends the stream)
        for await wake in woken {
            if case .ended(let task) = wake { alive[task] = nil; slots[task] = nil }
            if stopping.contains(id) { stop = .init(.requested); break }
            if Task.isCancelled { stop = .init(.cancelled); break }
            guard let w = try? await store.get(id), w.closedAt == nil, let loop = w.loop, loop.state == .running else { stop = .init(.workGone); break }
            guard await host.starterAlive() else { stop = .init(.starterGone); break }
            if let s = lanes[id]?.stop { stop = s; break }
            // only the tasks the owner approved: one added since waits for the next run
            let approved = loop.tasks.map { Set($0) }
            let open = w.tasks.filter { $0.state == .open && approved?.contains($0.id) != false }
            if alive.isEmpty, open.isEmpty { end = .finished; break }
            // M3b.4: with what the lanes alive have run: no lane starts on a spent budget, and the ones alive are
            // cancelled below, each adding its own seconds to `spent`, once, as it ends
            if let b = loop.budget, let rest = Self.unspent(loop, now: host.now()), rest <= 0 {
                await note(id, "[loop] orçamento de tempo usado (\(b - rest) de \(b) s, com as faixas em curso); laço parado")
                stop = .init(.budgetSpent); break
            }
            let integrating = lanes[id]?.integrating ?? []
            var ready = TaskScheduler.ready(tasks: w.tasks, running: Set(alive.keys).subtracting(integrating), integrating: integrating,
                                            parallel: parallel, approved: approved)
            // `used` already holds the attempts running: no attempt starts past `--max`
            if let max = loop.max { ready = Array(ready.prefix(Swift.max(0, max - loop.used))) }
            if ready.isEmpty, alive.isEmpty {
                if let max = loop.max, loop.used >= max { stop = .init(.maxReached); break }
                // nothing runs and nothing can start: what is left waits for a task that will not be done here
                var stuck = TaskScheduler.blocked(tasks: w.tasks).filter { approved?.contains($0.task) != false }
                if stuck.isEmpty { stuck = open.map { .init(task: $0.id, reason: "depende de uma tarefa que este laço não roda") } }
                await deferBlocked(id, stuck)
                signal.yield(.poke)
                continue
            }
            for t in ready {
                try? await store.update(id) { $0.loop?.used += 1 }
                let slot = (1...).first { !slots.values.contains($0) } ?? 1
                slots[t.id] = slot
                alive[t.id] = Task {
                    await self.runLane(id, t, slot: slot, dir: dir, root: root, integrator: integrator)
                    signal.yield(.ended(t.id))
                }
            }
        }
        // the stream ended under the loop: the daemon is stopping
        if stop == nil, end != .finished { stop = .init(stopping.contains(id) ? .requested : .cancelled) }
        // M3b.6: the daemon stopping (the loop's own task cancelled) also cancels the integrations running: a gate on the
        // merged tree is killed and the merge undone under M3b.2's rule. Any other stop lets them end.
        if stop?.code == .cancelled {
            lanes[id]?.aborted = true
            for t in (lanes[id]?.integrations ?? [:]).values { t.cancel() }
        }
        // stopping: every lane is cancelled; each dismisses its agent, reopens its task and removes itself
        for t in alive.values { t.cancel() }
        for t in alive.values { await t.value }
        // M3d.3: what the last gate left goes with the loop, unless someone works in the tree now
        if await host.othersWorking() == nil {
            let swept = await integrator.sweep()
            if let at = swept.at, !swept.moved.isEmpty { await note(id, Self.movedNote(swept.moved, at: at)) }
            if !swept.spared.isEmpty { await note(id, Self.sparedNote(swept.spared)) }
        }
        lanes[id] = nil
        signal.finish()
        try? await store.update(id) { $0.loop?.lanes = nil; $0.loop?.mirror() }
        return (end, stop)
    }

    /// The repository's root (where its worktrees live, lanes included), from the paddock's worktree `dir`.
    private func repoRoot(_ dir: URL) async -> URL? {
        guard let common = await out(["rev-parse", "--path-format=absolute", "--git-common-dir"], dir) else { return nil }
        let git = URL(fileURLWithPath: common)
        return git.lastPathComponent == ".git" ? git.deletingLastPathComponent() : dir
    }

    /// One lane, from its worktree to its removal: one attempt of `task` in it and, if it passed, its integration.
    /// The scheduler already counted the attempt (`used`). A failed attempt leaves the task open (or deferred) as
    /// always, and the scheduler gives it a new lane, from the paddock's HEAD of then.
    private func runLane(_ id: UUID, _ task: WorkTask, slot: Int, dir: URL, root: URL, integrator: LaneIntegrator) async {
        guard !Task.isCancelled else { await noLane(id, task, nil); return }
        let lane: Lane, laneHost: any LoopHost
        do { (lane, laneHost) = try await cut(id, task.id, dir: dir, root: root) } catch {
            await noLane(id, task, error.message); return
        }
        let name = lane.path.lastPathComponent, n = (task.tries ?? 0) + 1, t0 = host.now()
        try? await store.update(id) { x in
            let others = x.loop?.lanes ?? []
            x.loop?.lanes = others + [WorkLoopState.LaneState(lane: name, task: task.id, attempt: n, since: t0, started: t0)]
            x.loop?.mirror()
        }
        var stop: WorkLoopState.Stop?
        if let w = try? await store.get(id), let loop = w.loop {
            // a lane's commits die with the lane: what the task carried from a fallen attempt is never adopted here
            var fresh = w.tasks.first { $0.id == task.id } ?? task
            fresh.forgetResume()
            let engine = WorkLoop(store: store, host: laneHost, poll: poll, checkTimeout: checkTimeout, othersWait: othersWait,
                                  events: events, lane: name, slot: slot, notices: notices)
            if case .stop(let s) = await engine.attempt(w, loop, fresh, lane.path) { stop = s }
            if await engine.passed != nil {
                // nothing is integrated once the loop is stopping
                if stop == nil, !Task.isCancelled { stop = await integrate(id, engine, lane, loop, integrator) }
                else { await engine.release(id, "não integrada: o laço parou") }
            }
        }
        let secs = Int(host.now().timeIntervalSince(t0).rounded(.up)), taskId = task.id
        try? await store.update(id) { x in
            let was = x.loop?.spent ?? 0
            x.loop?.spent = was + secs
            x.loop?.lanes?.removeAll { $0.lane == name }
            if x.loop?.lanes?.isEmpty == true { x.loop?.lanes = nil }
            x.loop?.mirror()
            Self.forget(&x, taskId)
        }
        await dropLane(lane)
        // a lane cancelled by the loop's stop says nothing new
        if let stop, stop.code != .cancelled, lanes[id]?.stop == nil { lanes[id]?.stop = stop }
    }

    /// A lane cut from the paddock's HEAD of now, and its host; a lane that got no host is removed.
    /// M3b.1: HEAD is read under the loop's profile (`host.git`); the worktree is made by the daemon's git (`laneGit`).
    func cut(_ id: UUID, _ task: String, dir: URL, root: URL) async throws(ProtocolError) -> (Lane, any LoopHost) {
        guard let head = await out(["rev-parse", "HEAD"], dir) else { throw ProtocolError(code: .internal, message: "git rev-parse HEAD failed") }
        let lane = try await LaneWorktree.create(repoRoot: root, base: head, work: id, task: task, host: host)
        do { return (lane, try await host.laneHost(lane)) } catch {
            await dropLane(lane)
            throw error
        }
    }

    /// The task got no lane (`why`; nil: the loop was stopping before it had one): no attempt ran, none is counted.
    /// With a reason the task is deferred: left open, the scheduler would hand it a lane again without end.
    private func noLane(_ id: UUID, _ task: WorkTask, _ why: String?) async {
        let at = host.now(), reason = Task.isCancelled ? nil : why.map { Self.eventDetail("a faixa não pôde ser criada: \($0)") }
        try? await store.update(id) { x in
            let used = x.loop?.used ?? 0
            x.loop?.used = Swift.max(0, used - 1)
            guard let reason, let i = x.tasks.firstIndex(where: { $0.id == task.id }), x.tasks[i].state == .open else { return }
            x.tasks[i].state = .deferred; x.tasks[i].reason = "loop: \(reason)"; x.tasks[i].lastFailure = reason; x.tasks[i].updatedAt = at
            x.notes.append(WorkNote(at: at, text: "[loop] \"\(task.title)\" adiada: \(reason)"))
        }
        if reason != nil { await reportEnd(id, task.id) }
    }

    /// The lane's worktree, its branch and what its host made for it go. In a task of its own: a lane is removed even
    /// when the loop was cancelled (git under a cancelled task may not run), so none outlives the run.
    func dropLane(_ lane: Lane) async {
        let host = host
        await Task {
            try? await LaneWorktree.remove(lane, host: host)
            await host.laneGone(lane)
        }.value
    }

    /// Open tasks that can never start in this run are deferred with why, so the loop ends instead of waiting for them.
    private func deferBlocked(_ id: UUID, _ stuck: [TaskScheduler.Blocked]) async {
        let at = host.now()
        try? await store.update(id) { x in
            for b in stuck {
                guard let i = x.tasks.firstIndex(where: { $0.id == b.task }), x.tasks[i].state == .open else { continue }
                x.tasks[i].state = .deferred; x.tasks[i].reason = "loop: \(b.reason)"; x.tasks[i].updatedAt = at
                x.notes.append(WorkNote(at: at, text: "[loop] \"\(x.tasks[i].title)\" adiada: \(b.reason)"))
            }
        }
        for b in stuck { await reportEnd(id, b.task) }
    }

    /// The lane passed: the integrator joins it to the paddock's branch, and only then the task is done. Returns why
    /// the loop must stop (the paddock's worktree is not the loop's to touch right now), or nil.
    private func integrate(_ id: UUID, _ engine: WorkLoop, _ lane: Lane, _ loop: WorkLoopState,
                           _ integrator: LaneIntegrator) async -> WorkLoopState.Stop? {
        guard let p = await engine.passed else { return nil }
        let name = lane.path.lastPathComponent, gate = loop.gate
        lanes[id]?.integrating.insert(p.task.id)
        lanes[id]?.signal.yield(.poke)   // its slot is free (its scope is not): another task may start
        defer { lanes[id]?.integrating.remove(p.task.id) }
        try? await store.update(id) { $0.loop?.showLane(name, gate == nil ? nil : .gate) }
        // M3b.4: the budget as it is now, not as the lane found it: the time in the integrator's queue counted too
        let timeout = Swift.min(checkTimeout, Duration.seconds(loop.budget == nil ? 86_400 : await laneShare(id)))
        // in a task of its own: a stop never cuts a merge in half. It ends integrated or undone, whatever was cancelled.
        // M3b.6: only the daemon's stop cancels it (`aborted`, at the end of `runLanes`): a gate running on the merged
        // tree is killed and the merge undone, under M3b.2's rule. The lane is removed only after this returns (`runLane`).
        let run = Task {
            try? await integrator.integrate(lane, title: p.task.title, attempt: p.n, tries: p.tries, gate: gate, gateTimeout: timeout)
        }
        lanes[id]?.integrations[p.task.id] = run
        if lanes[id]?.aborted == true { run.cancel() }
        let result = await run.value
        lanes[id]?.integrations[p.task.id] = nil
        guard let result else {
            await engine.refuse(id, "integração recusada: o branch não é de uma faixa", output: "", last: true)
            return nil
        }
        // M3c.2: new untracked files never stop the loop nor a reset: they stay, and the note names them
        if result.kept.isEmpty, !result.left.isEmpty { await note(id, Self.leftNote(result.left)) }
        if let at = result.quarantine, !result.moved.isEmpty { await note(id, Self.movedNote(result.moved, at: at)) }
        if !result.spared.isEmpty { await note(id, Self.sparedNote(result.spared)) }
        switch result.outcome {
        case .integrated, .noop:
            await engine.finish(id, head: result.head)
            // M3b.2: the gate passed, but the tree changed while it ran: nothing was reset, and the next merge would
            // find it dirty. The loop stops now, saying what is there.
            guard !result.kept.isEmpty else { return nil }
            await note(id, Self.keptNote(nil, result))
            return WorkLoopState.Stop(.dirtyTree)
        case .leftDirty(let why):
            // M3b.2: not the task's fault: it is open again and its attempt is given back, as for `.wait`
            await engine.release(id, "não integrada: \(why)")
            await note(id, Self.keptNote(why, result))
            return result.blockedBy.map { WorkLoopState.Stop(.othersWorking, detail: $0) } ?? WorkLoopState.Stop(.dirtyTree)
        case .retryFromNewBase(let why), .defer(let why):
            // the loop stopped meanwhile: no verdict on the task, as for an attempt cancelled
            if Task.isCancelled || stopping.contains(id) { await engine.release(id, "não integrada: o laço parou"); return nil }
            var last = false
            if case .defer = result.outcome { last = true }
            await engine.refuse(id, why, output: result.output, last: last)
            return nil
        case .wait(let why):
            // as the engine does for another terminal in the worktree: nothing touched, the loop stops
            await engine.release(id, "não integrada: \(why)")
            let who = await host.othersWorking()
            await note(id, who.map(Self.blockedNote)
                ?? "[loop] a worktree do cercado tem arquivos rastreados modificados, e não são do laço: nada foi integrado; laço parado, worktree intocada")
            return who.map { WorkLoopState.Stop(.othersWorking, detail: $0) } ?? WorkLoopState.Stop(.dirtyTree)
        }
    }

    /// M3b.2: the note of an integration that reset nothing: what was preserved, who was there, and the merge left in
    /// the branch (`why` nil: the gate passed and the task is integrated).
    static func keptNote(_ why: String?, _ r: LaneIntegrator.Result) -> String {
        var s = why.map { "[loop] não integrada (\($0))" } ?? "[loop] integrada"
        s += ", mas a worktree do cercado não estava como o integrador a deixou: nada foi resetado nem apagado."
        if let who = r.blockedBy { s += " '\(who)' está trabalhando nela." }
        if !r.kept.isEmpty {
            // ponytail: the first 10 names; `git status` shows the rest
            let more = r.kept.count > 10 ? " e mais \(r.kept.count - 10)" : ""
            s += " Preservado: " + eventDetail(r.kept.prefix(10).joined(separator: ", ")) + more + "."
        }
        if let undo = r.undo {
            s += " O merge \(r.head.prefix(7)) ficou no branch sem passar no portão: para desfazer, guarde o que é seu e rode git reset --hard \(undo.prefix(7))."
        }
        return s + " Laço parado."
    }

    /// M3c.2: the untracked files a merge's gate (or someone meanwhile) left in the paddock's worktree. M3d.3: removed
    /// before the next merge (or at the loop's end) if still as the gate left them.
    static func leftNote(_ left: [String]) -> String {
        "[loop] arquivos não rastreados novos na worktree do cercado (do portão): " + fileList(left)
            + ". Vão para a quarentena antes do próximo merge, ou no fim do laço, se ninguém mexer neles."
    }

    /// M6.3: the gate's files moved out of the tree: where they are (nothing removed).
    static func movedNote(_ moved: [String], at: String) -> String {
        "[loop] arquivos deixados pelo portão foram movidos para a quarentena \(at) (nada foi apagado; ela é esvaziada no começo do próximo laço): "
            + fileList(moved) + "."
    }

    /// M3d.3: files a gate left that changed since: they are the owner's now, and stay.
    static func sparedNote(_ spared: [String]) -> String {
        "[loop] arquivos deixados pelo portão ficaram na worktree do cercado (mudaram depois dele, têm nome que o laço não toca ou a quarentena estava cheia; nada foi apagado): "
            + fileList(spared) + "."
    }

    private static func fileList(_ files: [String]) -> String {
        let more = files.count > 10 ? " e mais \(files.count - 10)" : ""
        return eventDetail(files.prefix(10).joined(separator: ", ")) + more
    }

    // MARK: on a lane's engine: what becomes of the attempt that passed

    /// Integrated: the task is done as the loop's own `markDone` leaves it, and the Shepherd hears of it.
    func finish(_ id: UUID, head: String) async {
        guard let p = passed else { return }
        passed = nil
        let e = entry(.integrated, task: p.task.id, attempt: p.n, detail: String(head.prefix(7)))
        try? await store.update(id) { x in
            Self.markDone(&x, p.task.id, n: p.n, at: p.at, evidence: p.evidence, job: p.name, head: p.head)
            x.loop?.record(e)
        }
        await reportEnd(id, p.task.id)
    }

    /// Not integrated, and it is the attempt's (a conflict, the gate broken on the merged tree): the attempt counts and
    /// the task is open again, for one from the paddock's new HEAD, or deferred when `last`. The next attempt's prompt
    /// carries the reason, as for a failed check.
    func refuse(_ id: UUID, _ reason: String, output: String, last: Bool) async {
        guard let p = passed else { return }
        passed = nil
        await keepPatch(id, p)
        let at = host.now(), task = p.task
        let tail = output.split(separator: "\n", omittingEmptySubsequences: false).suffix(Self.noteLines).joined(separator: "\n")
        let text = LotBoards.scrub("[loop \(task.id)] \(task.title), tentativa \(p.n)/\(p.tries): \(reason) (agente \(p.name))"
            + (tail.isEmpty ? "" : "\n" + String(tail.suffix(Self.noteChars))))
        let e = entry(last ? .verdict : .integrationRetry, task: task.id, attempt: p.n, detail: reason)
        try? await store.update(id) { x in
            if let i = x.tasks.firstIndex(where: { $0.id == task.id }), x.tasks[i].state == .inProgress {
                x.tasks[i].tries = p.n; x.tasks[i].lastFailure = reason; x.tasks[i].updatedAt = at
                if last { x.tasks[i].state = .deferred; x.tasks[i].reason = "loop: \(reason)" } else { x.tasks[i].state = .open }
            }
            x.notes.append(WorkNote(at: at, text: text))
            Self.endJob(&x, p.name, reason, at: at)
            x.loop?.record(e)
        }
        if last { await reportEnd(id, task.id) }
    }

    /// Not integrated, and not the attempt's fault (the loop stopped, the paddock's worktree is busy or dirty): the task
    /// reopens and the attempt is not counted, as for one cancelled.
    func release(_ id: UUID, _ why: String) async {
        guard let p = passed else { return }
        passed = nil
        await keepPatch(id, p)
        let at = host.now()
        try? await store.update(id) { x in
            if let i = x.tasks.firstIndex(where: { $0.id == p.task.id }), x.tasks[i].state == .inProgress { x.tasks[i].state = .open }
            let used = x.loop?.used ?? 0
            x.loop?.used = Swift.max(0, used - 1)
            Self.endJob(&x, p.name, why, at: at)
        }
    }

    /// What the attempt committed in its lane, as `<task>-<n>.patch` in the lane's patch folder: the lane's branch dies
    /// with the lane, and work that passed its check is not thrown away with it.
    private func keepPatch(_ id: UUID, _ p: Passed) async {
        let host = host
        await Task {
            // ponytail: the first 1 MiB of the diff, like the engine's `discard`
            guard let d = try? await host.git(["diff", "--binary", p.before, p.judged], in: p.dir), d.status == 0, !d.stdoutData.isEmpty else { return }
            let folder = host.patchDir(id)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? d.stdoutData.write(to: folder.appendingPathComponent("\(p.task.id)-\(p.n).patch"))
        }.value
    }
}
