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
/// task's, written by its lane.
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
        let (woken, signal) = AsyncStream<Wake>.makeStream()
        lanes[id] = Lanes(signal: signal)
        var alive: [String: Task<Void, Never>] = [:]   // by task: running in its lane, or with the integrator
        var end = WorkLoopState.State.stopped, stop: WorkLoopState.Stop?
        signal.yield(.poke)   // the first look
        // no clock: the scheduler looks again only when something changed (a cancelled daemon ends the stream)
        for await wake in woken {
            if case .ended(let task) = wake { alive[task] = nil }
            if stopping.contains(id) { stop = .init(.requested); break }
            if Task.isCancelled { stop = .init(.cancelled); break }
            guard let w = try? await store.get(id), w.closedAt == nil, let loop = w.loop, loop.state == .running else { stop = .init(.workGone); break }
            guard await host.starterAlive() else { stop = .init(.starterGone); break }
            if let s = lanes[id]?.stop { stop = s; break }
            // only the tasks the owner approved: one added since waits for the next run
            let approved = loop.tasks.map { Set($0) }
            let open = w.tasks.filter { $0.state == .open && approved?.contains($0.id) != false }
            if alive.isEmpty, open.isEmpty { end = .finished; break }
            if let b = loop.budget, (loop.spent ?? 0) >= b {
                await note(id, "[loop] orçamento de tempo usado (\(loop.spent ?? 0) de \(b) s); laço parado")
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
                alive[t.id] = Task {
                    await self.runLane(id, t, dir: dir, root: root, integrator: integrator)
                    signal.yield(.ended(t.id))
                }
            }
        }
        // the stream ended under the loop: the daemon is stopping
        if stop == nil, end != .finished { stop = .init(stopping.contains(id) ? .requested : .cancelled) }
        // stopping: every lane is cancelled; each dismisses its agent, reopens its task and removes itself
        for t in alive.values { t.cancel() }
        for t in alive.values { await t.value }
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
    private func runLane(_ id: UUID, _ task: WorkTask, dir: URL, root: URL, integrator: LaneIntegrator) async {
        guard !Task.isCancelled else { await noLane(id, task, nil); return }
        let lane: Lane, laneHost: any LoopHost
        do {
            guard let head = await out(["rev-parse", "HEAD"], dir) else { throw ProtocolError(code: .internal, message: "git rev-parse HEAD failed") }
            lane = try await LaneWorktree.create(repoRoot: root, base: head, work: id, task: task.id, host: host)
        } catch {
            await noLane(id, task, error.message); return
        }
        do { laneHost = try await host.laneHost(lane) } catch {
            await dropLane(lane)
            await noLane(id, task, error.message); return
        }
        let name = lane.path.lastPathComponent, n = (task.tries ?? 0) + 1, t0 = host.now()
        try? await store.update(id) { x in
            x.loop?.lanes = (x.loop?.lanes ?? []) + [.init(lane: name, task: task.id, attempt: n, since: t0)]
            x.loop?.mirror()
        }
        var stop: WorkLoopState.Stop?
        if let w = try? await store.get(id), let loop = w.loop {
            // a lane's commits die with the lane: what the task carried from a fallen attempt is never adopted here
            var fresh = w.tasks.first { $0.id == task.id } ?? task
            fresh.forgetResume()
            let engine = WorkLoop(store: store, host: laneHost, poll: poll, checkTimeout: checkTimeout, othersWait: othersWait,
                                  events: events, lane: name)
            if case .stop(let s) = await engine.attempt(w, loop, fresh, lane.path) { stop = s }
            if await engine.passed != nil {
                // nothing is integrated once the loop is stopping
                if stop == nil, !Task.isCancelled { stop = await integrate(id, engine, lane, loop, since: t0, integrator) }
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
    private func dropLane(_ lane: Lane) async {
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
    private func integrate(_ id: UUID, _ engine: WorkLoop, _ lane: Lane, _ loop: WorkLoopState, since t0: Date,
                           _ integrator: LaneIntegrator) async -> WorkLoopState.Stop? {
        guard let p = await engine.passed else { return nil }
        let name = lane.path.lastPathComponent, gate = loop.gate
        lanes[id]?.integrating.insert(p.task.id)
        lanes[id]?.signal.yield(.poke)   // its slot is free (its scope is not): another task may start
        defer { lanes[id]?.integrating.remove(p.task.id) }
        try? await store.update(id) { $0.loop?.showLane(name, gate == nil ? nil : .gate) }
        let timeout = Swift.min(checkTimeout, Duration.seconds(left(loop, since: t0)))
        // in a task of its own: a stop never cuts a merge in half. It ends integrated or undone, whatever was cancelled.
        // ponytail: so a stop waits for a gate already running on the merged tree (the check's timeout bounds it)
        let result = await Task {
            try? await integrator.integrate(lane, title: p.task.title, attempt: p.n, tries: p.tries, gate: gate, gateTimeout: timeout)
        }.value
        guard let result else {
            await engine.refuse(id, "integração recusada: o branch não é de uma faixa", output: "", last: true)
            return nil
        }
        switch result.outcome {
        case .integrated, .noop:
            await engine.finish(id, head: result.head)
            return nil
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
            return who.map { .init(.othersWorking, detail: $0) } ?? .init(.dirtyTree)
        }
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
        let text = LotBoards.scrub("[loop \(task.id)] \(task.title), tentativa \(p.n)/\(p.tries): \(reason)"
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
