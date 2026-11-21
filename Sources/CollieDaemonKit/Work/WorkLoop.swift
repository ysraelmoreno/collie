import Foundation
import CollieCore
import CollieProtocol
import CollieTerminal

/// Everything the loop needs from the daemon. No preset or LLM appears here.
protocol LoopHost: Sendable {
    /// A fresh agent terminal in `work`'s paddock, as the loop's settings ask. Returns its id.
    func summon(name: String, for work: Work, loop: WorkLoopState) async throws(ProtocolError) -> UUID
    func ask(_ terminal: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> AskResult.Source
    /// M2.0: a prompt written to `terminal` was not submitted and had its Enter sent again (the journal's `resubmitted`).
    func resubmitted(_ terminal: UUID) async -> Bool
    /// True while the terminal's agent is in a turn (the daemon's own badge/turn state).
    func working(_ terminal: UUID) async -> Bool
    /// M5.3: the terminal sits in the model's usage-limit dialog, printing nothing (`UsageLimit.detect` on its screen):
    /// the dialog's text, short. nil: not in it. Read only, never typed into.
    func usageLimit(_ terminal: UUID) async -> String?
    func dismiss(_ terminal: UUID) async
    /// M5.4: what `terminal`'s agent used, from its own transcript, read just before it is dismissed: counts only. nil:
    /// no number (no transcript, refused, gone, too big); never an error, never holds the loop.
    func tokens(_ terminal: UUID) async -> TokenCount?
    /// A terminal of the work's paddock in a turn, other than the starter (the loop's agent is already gone): its name.
    func othersWorking() async -> String?
    /// M3b.2: any terminal of the paddock in a turn in this tree, the starter included: its name. What the integrator
    /// asks before it throws anything away (in a parallel loop the starter is free to edit the paddock's worktree).
    func anyoneWorking() async -> String?
    /// The starter (the Shepherd the loop summons as) still exists.
    func starterAlive() async -> Bool
    func git(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult
    /// M3b.1: the git that makes, removes and prunes lanes (`LaneWorktree`, nothing else): the daemon's own, outside
    /// the loop's profile, which cannot write a sibling `lane-*` worktree nor `<common>/worktrees/lane-*`. Only on
    /// paths the daemon builds and validates itself. What runs inside a lane (agent, check, gate) stays in `git`.
    func laneGit(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult
    /// M3b.5: this daemon's id (its install id), written in every lane it makes: a sweep removes only lanes with it.
    func laneOwner() async -> String
    /// `command` via `/bin/bash -c` in `dir`, under the loop's own sandbox profile; throws (never runs unsandboxed) when
    /// the daemon sandboxes terminals and that profile is missing.
    func check(_ command: String, in dir: URL, timeout: Duration) async throws(ProtocolError) -> ProcessResult
    func readSpec(_ path: String) async -> String?
    /// `path` (relative) is a file in the worktree `dir`.
    func exists(_ path: String, in dir: URL) async -> Bool
    /// Where attempt patches go: `<root>/work-loops/<work id>/`.
    func patchDir(_ work: UUID) -> URL
    func now() -> Date
    /// One line for the Shepherd the moment a task of the loop ends (done, or deferred after its last try).
    func taskEnded(_ line: String) async
    /// An approved task's declared evidence: what `glob` matches in the worktree `dir`, copied under `patchDir`
    /// (`EvidenceFiles`). It reads only inside the worktree: never more than the check could.
    func copyEvidence(_ glob: String, from dir: URL, work: UUID, task: String) async -> EvidenceFiles.Copied
    /// M3.5: this host for one lane of the loop (M3.3), its sandbox profile made: the lane's agent, git and check run
    /// through it. Throws when the lane cannot be given one (nothing of a lane runs without it).
    func laneHost(_ lane: Lane) async throws(ProtocolError) -> any LoopHost
    /// M3.5: `lane` was removed: what `laneHost` made for it goes too.
    func laneGone(_ lane: Lane) async
    /// M3.8: the names an attempt's agent may not take: every live terminal's and panel's (a summon refuses them).
    func namesTaken() async -> Set<String>
}

extension LoopHost {
    /// A host that cannot tell the starter apart (the tests' fakes).
    func anyoneWorking() async -> String? { await othersWorking() }
    func resubmitted(_ terminal: UUID) async -> Bool { false }
    func usageLimit(_ terminal: UUID) async -> String? { nil }
    func tokens(_ terminal: UUID) async -> TokenCount? { nil }
    func taskEnded(_ line: String) async {}
    func laneHost(_ lane: Lane) async throws(ProtocolError) -> any LoopHost {
        throw ProtocolError(code: .unavailable, message: "this host runs no lanes")
    }
    func laneGone(_ lane: Lane) async {}
    /// A host with one git (the tests' fakes, which have no profile).
    func laneGit(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult { try await git(args, in: dir) }
    func namesTaken() async -> Set<String> { [] }
    /// The tests' fakes: one daemon.
    func laneOwner() async -> String { "collie-test" }
    func copyEvidence(_ glob: String, from dir: URL, work: UUID, task: String) async -> EvidenceFiles.Copied {
        EvidenceFiles.copy(glob, from: dir, to: EvidenceFiles.dir(patchDir(work), task: task))
    }
}

/// `collie work run`'s attempt cycle: a fresh agent per attempt, a check that alone decides, a clean tree between
/// attempts. A task passes only when its check exits 0, the loop's gate (if any) exits 0 too, there is a new commit on
/// the same branch, no tracked file is left dirty and neither the check nor the gate moved HEAD. The gate judges the
/// tree of the commit the check judged, and not one whose commit changed a script the gate's text names. The loop never pushes, lands or creates a paddock.
/// M5.1: the notices a loop sends to its Shepherd inside `window` seconds of the last one sent go as one line with the
/// counts. No timer and no sleep (the clock is the caller's `now`, the host's): what is held goes with the next notice
/// past the window. The loop's end notice (the daemon's `WorkStatusText.loopEnded`) is never held and names every
/// task of the loop, so what was still held when the loop ended goes with it.
/// M6.5 (A5): under `end` a done task sends no line, so what is held also goes (`flush`) when a task is done past the
/// window and when a new attempt starts past it: a deferral waits at most for the next task's end or attempt.
/// ponytail: no timer; an attempt that runs for hours still holds a deferral that long (a timer, if that matters).
actor LoopNotices {
    static let window: TimeInterval = 60
    let window: TimeInterval
    private var last: Date?
    private var pending: [(line: String, done: Bool)] = []   // one per notice held
    init(window: TimeInterval = LoopNotices.window) { self.window = window }
    var held: Int { pending.count }

    /// What goes now for `line` (a task's notice; `done`: it was done, not deferred) at `now`; nil: held.
    func offer(_ line: String, done: Bool, at now: Date) -> String? {
        if let last, now.timeIntervalSince(last) < window { pending.append((line, done)); return nil }
        pending.append((line, done))
        return send(at: now)
    }

    /// What was held, if the window passed at `now`; nil: nothing held, or still inside the window.
    func flush(at now: Date) -> String? {
        guard !pending.isEmpty, let last, now.timeIntervalSince(last) >= window else { return nil }
        return send(at: now)
    }

    private func send(at now: Date) -> String {
        let all = pending
        pending = []; last = now
        return all.count == 1 ? all[0].line
            : WorkStatusText.noticeBatch(done: all.filter(\.done).count, deferred: all.filter { !$0.done }.count)
    }
}

actor WorkLoop {
    static let noteLines = 40, noteChars = 4000
    /// Where a project keeps its feature map, in order of preference.
    static let featureMaps = ["docs/feature-map.md", "FEATURES.md"]
    /// M2.1: what an agent that ended its turn by hook with no new commit is told, once per attempt.
    static let nudgePrompt = "Você encerrou o turno sem fazer commit. Ninguém vai responder perguntas neste laço: decida sozinho. Faça commit do que escreveu (ou diga em uma linha o que impede) e encerre."
    static let evidenceCommits = 20, evidenceSubject = 200, evidenceLines = 20, evidenceChars = 2000
    let store: WorkStore, host: any LoopHost, poll: Duration, checkTimeout: Duration, othersWait: Duration
    /// A test's seam: the event an effect answers with, instead of carrying it out (nil: carried out as always).
    let events: (@Sendable (AttemptMachine.Effect) -> AttemptMachine.Event?)?
    var stopping: Set<UUID> = []
    /// M3.5: set on the engine of one lane (`WorkLoopLanes`): the lane's id (its folder's name). `host` is then the
    /// lane's, an attempt that passes waits in `passed` for the integrator, and its journal and phase carry the lane.
    /// nil: the loop's own engine, in the paddock's worktree.
    let lane: String?
    /// M3.8, a lane's engine: the lane's number in its run (1…), for its agent's name (`AgentNaming`'s `f<n>`).
    let slot: Int?
    /// M3.5, a lane's engine: the attempt that passed in the lane, until it is integrated (or not).
    var passed: Passed?
    /// M3.5: the parallel runs of this engine, by work (`WorkLoopLanes`); empty without `--parallel`.
    var lanes: [UUID: Lanes] = [:]
    /// M5.1: the Shepherd's notice window, one per loop: a lane's engine shares its loop's.
    let notices: LoopNotices

    init(store: WorkStore, host: any LoopHost, poll: Duration = .seconds(15), checkTimeout: Duration = .seconds(1800),
         othersWait: Duration = .seconds(300), events: (@Sendable (AttemptMachine.Effect) -> AttemptMachine.Event?)? = nil,
         lane: String? = nil, slot: Int? = nil, notices: LoopNotices = LoopNotices()) {
        self.store = store; self.host = host; self.poll = poll; self.checkTimeout = checkTimeout; self.othersWait = othersWait
        self.events = events; self.lane = lane; self.slot = slot; self.notices = notices
    }

    /// Ends the loop after the current attempt's verdict.
    func stop(work id: UUID) async {
        stopping.insert(id)
        lanes[id]?.signal.yield(.poke)   // M3.5: a parallel run waits on its lanes: it is told now
        if (try? await store.get(id))?.loop?.state == .running { await event(id, .stopRequested) }
    }

    /// Runs `work`'s open tasks until all are done/deferred, `max` is used or `stop` is asked. `work.loop` must be set
    /// and `.running`. Returns the final state.
    func run(work id: UUID, dir: URL) async -> WorkLoopState.State {
        var end = WorkLoopState.State.stopped
        var stop: WorkLoopState.Stop?   // why it stopped; nil only when it finished
        try? await store.update(id) { w in if w.loop?.state == .running { w.loop?.stopReason = nil } }
        // M3.5: `--parallel N` is a path of its own (`runLanes`); with 1 or none, the loop below, as it always was
        let parallel = (try? await store.get(id))?.loop?.parallel ?? 1
        if parallel > 1 { (end, stop) = await runLanes(work: id, dir: dir, parallel: parallel) }
        while parallel <= 1 {
            if stopping.contains(id) { stop = .init(.requested); break }
            if Task.isCancelled { stop = .init(.cancelled); break }
            // closed, missing or stopped from outside (a daemon restart's sweep): stop
            guard let w = try? await store.get(id), w.closedAt == nil, let loop = w.loop, loop.state == .running else { stop = .init(.workGone); break }
            guard await host.starterAlive() else { stop = .init(.starterGone); break }
            // only the tasks the owner approved: one added since waits for the next run
            guard let task = w.tasks.first(where: { $0.state == .open && (loop.tasks?.contains($0.id) ?? true) }) else { end = .finished; break }
            if let max = loop.max, loop.used >= max { stop = .init(.maxReached); break }
            if let b = loop.budget, (loop.spent ?? 0) >= b {
                await note(id, "[loop] orçamento de tempo usado (\(loop.spent ?? 0) de \(b) s); laço parado")
                stop = .init(.budgetSpent); break
            }
            let t0 = host.now()
            let ended = await attempt(w, loop, task, dir)
            let secs = Int(host.now().timeIntervalSince(t0).rounded(.up))
            try? await store.update(id) { x in let was = x.loop?.spent ?? 0; x.loop?.spent = was + secs }
            if case .stop(let s) = ended { stop = s; break }
        }
        stopping.remove(id)
        let now = host.now(), final = end, why = stop
        try? await store.update(id) { w in
            guard w.loop != nil else { return }
            // stopped from outside with its own reason and note (the daemon's sweep): those stay
            let outside = w.loop!.state == .running ? nil : w.loop!.stopReason
            w.loop!.state = final; w.loop!.endedAt = now; w.loop!.task = nil; w.loop!.stopReason = outside ?? why
            // always one summary note, after the path's own longer one (if any)
            if outside == nil, let why {
                w.notes.append(WorkNote(at: now, text: why.note))
                w.record(LoopEvent(at: now, kind: .stopped, detail: Self.eventDetail(why.label)))
            }
        }
        return end
    }

    /// How an attempt ends for the loop: on to the next one, or the loop stops and why.
    enum AttemptEnd: Equatable { case go, stop(WorkLoopState.Stop) }

    /// One attempt of `task`, through its verdict. `.stop`: the loop stops (no verdict when the work closed, the starter is
    /// gone, or the tree holds changes that are not the attempt's; a verdict and no reset when another terminal works).
    /// After its first reads it only interprets `AttemptMachine`: the order of the effects and their conditions are there.
    func attempt(_ w: Work, _ loop: WorkLoopState, _ task: WorkTask, _ dir: URL) async -> AttemptEnd {
        await flushNotices()   // M6.5 (A5): a deferral held in the window goes once a new attempt starts past it
        let n = (task.tries ?? 0) + 1, started = host.now()
        // M3.8: named after the work and the task (their titles are data: `AgentNaming` leaves only `[a-z0-9-]`), and
        // never as a live terminal. Nothing finds the agent by this name: its terminal's id goes on the job (`record`)
        let name = AgentNaming.unique(AgentNaming.name(work: w.title, task: task.title, taskId: task.id, attempt: n, lane: slot),
                                      taskId: task.id, taken: await host.namesTaken())
        let lane = lane   // M3.5: the engine's own, read once for the writes below
        // git failing here (the loop's profile gone, not a repo): stop, nothing to judge
        guard let head = await out(["rev-parse", "HEAD"], dir), let branch = await out(["rev-parse", "--abbrev-ref", "HEAD"], dir),
              let pending = await out(["status", "--porcelain", "--untracked-files=no"], dir) else {
            await note(w.id, "[loop] git falhou em \(dir.path); laço parado")
            return .stop(.init(.gitFailed))
        }
        // tracked changes now are someone else's (each attempt ends on a clean tree): never the loop's to reset
        guard pending.isEmpty else {
            let at = host.now(), text = "[loop] arquivos rastreados modificados (dirty) antes da tentativa de \"\(task.title)\", e não são do laço; laço parado, worktree intocada:\n\(pending.prefix(500))"
            // M2.2a: nothing is adopted over a dirty tree, and what the task resumed from is forgotten
            try? await store.update(w.id) { Self.forget(&$0, task.id); $0.notes.append(WorkNote(at: at, text: text)) }
            return .stop(.init(.dirtyTree))
        }
        // pre-existing untracked files are never the attempt's: the reset must not delete them
        let keep = await untracked(dir)
        // the attempt's first write carries its first event too (the machine's `attemptStarted` is not written again)
        let first = LoopEvent(at: started, kind: .attemptStarted, task: task.id, attempt: n, lane: lane)
        // M2.2a: a fallen daemon's attempt left its commit: this attempt judges it from where that one started, with
        // no agent. Anything else the task carried is ignored (and overwritten by this attempt's own, right below)
        let adopt = await adoptable(task, branch: branch, dir)
        let before = adopt ? task.resumeFrom ?? head : head
        try? await store.update(w.id) { x in
            if let i = x.tasks.firstIndex(where: { $0.id == task.id }) {
                x.tasks[i].state = .inProgress; x.tasks[i].updatedAt = started
                // where a fall resumes from; `forget` clears it when the attempt ends
                // M2c: an adoption keeps the `resumeAt` it was judged by (when the attempt was first left): cancelled
                // or fallen again, a commit made during it is still after that, and never adopted
                x.tasks[i].resumeFrom = before; x.tasks[i].resumeBranch = branch; x.tasks[i].resumeAt = adopt ? task.resumeAt : nil
            }
            // M2b.1: one attempt, one live `resumeFrom`: from here on the commits are this task's, so what another
            // task was left with can no longer tell its own commits from these
            for j in x.tasks.indices where x.tasks[j].id != task.id { x.tasks[j].forgetResume() }
            // M3.5: in a lane the scheduler already counted the attempt, and `loop.task` mirrors the oldest lane
            if let lane { x.loop?.showLane(lane, .agent, at: started) }
            else { x.loop?.task = task.id; x.loop?.attempt = n; x.loop?.used += 1; x.loop?.show(adopt ? nil : .agent, at: started) }
            x.jobs.append(WorkJob(id: name, kind: .loop, label: task.title, startedAt: started))
            x.record(first)
        }
        // from here the attempt is `AttemptMachine`'s: it says what to do, this carries it out and tells it what happened
        var run = Run(work: w, loop: loop, task: task, dir: dir, n: n, name: name, started: started, before: before,
                      branch: branch, keep: keep, on: branch, at: started)
        var (state, todo) = AttemptMachine.reduce(.init(task: task.id, n: n, tries: loop.tries, hasGate: loop.gate != nil, before: before, name: name), adopt ? .adopted : .started)
        while !todo.isEmpty {
            let effect = todo.removeFirst()
            // the journal and the phase wait for the attempt's next write, but never through a long wait: `work status`
            // shows what the loop is doing while the agent, the check or the gate runs
            if Self.waits(effect), run.unwritten { await record(w.id, &run) }
            var happened = events?(effect)
            if happened == nil {
                happened = await perform(effect, state, &run)
                // M2.2b: the daemon stopped while the check, the gate or the wait for another terminal ran: what they
                // answered (often the error of a killed check) is no verdict. The machine leaves with `cancelled`
                if Task.isCancelled, let h = happened, Self.judges(h) { happened = .cancelled }
            }
            guard let happened else { continue }
            let (next, more) = AttemptMachine.reduce(state, happened)
            state = next; todo += more
        }
        guard state.phase != .finished else {
            if run.unwritten { await record(w.id, &run) }   // every path ends on a write of its own: this is a net
            return run.end
        }
        // the safety net: the machine ran out of effects before its end (an event out of its phase, `fault`). A bug:
        // the task must not stay `inProgress` with its job running. Like `.reopen`: the task is open again, the attempt
        // is not counted on it, the tree is left as it is, and the loop stops here (no next task on a broken engine).
        let at = host.now(), what = run.fault.map { " (\($0))" } ?? ""
        if let agent = state.agent { await host.dismiss(agent) }
        await record(w.id, &run) { x in
            if let i = x.tasks.firstIndex(where: { $0.id == task.id }), x.tasks[i].state == .inProgress { x.tasks[i].state = .open }
            Self.endJob(&x, name, "loop: estado inesperado do motor", at: at)
            Self.forget(&x, task.id)
            if let lane { x.loop?.showLane(lane, nil) } else { x.loop?.show(nil) }
            x.notes.append(WorkNote(at: at, text: "[loop] estado inesperado do motor\(what) em \"\(task.title)\": é um bug do laço; tarefa reaberta, tentativa não contada, worktree intocada; laço parado"))
        }
        return .stop(.init(.internal))
    }

    /// What an attempt's effects read and leave behind: the interpreter's own, `AttemptMachine` never sees it.
    private struct Run {
        let work: Work, loop: WorkLoopState, task: WorkTask, dir: URL
        let n: Int, name: String, started: Date, before: String, branch: String
        /// Untracked files that were there before the attempt: never the attempt's, the discard must not delete them.
        let keep: [String]
        var agent: UUID?
        /// M3.8: the agent's terminal, until it is written on the attempt's job (`record`, with the next write).
        var mark: UUID?
        /// When the turn's time is over (set by `ask`).
        var deadline: Date?
        /// The branch and the untracked files (the owner's and the agent's) before the check: what `settle` puts back.
        var on: String, loose: Set<String> = []
        var output = ""
        var checkOutput = ""   // the check's own, kept for the evidence when a gate's output replaces `output`
        /// When the verdict was reached.
        var at: Date
        var end = AttemptEnd.go
        /// The machine's `fault`, for the safety net's note.
        var fault: String?
        /// `discard` wrote the attempt's patch (nil: nothing was discarded).
        var patched: Bool?
        /// M5.4: the agent's counts, read at the dismiss: the `agentDismissed` event carries them.
        var tokens: TokenCount?
        /// The journal's events not yet written, oldest first, and the phase to show (`.some(nil)`: none): `record`.
        var pending: [LoopEvent] = [], phase: WorkLoopState.Phase??
        var unwritten: Bool { !pending.isEmpty || phase != nil || mark != nil }
    }

    /// Effects that may take long: what is pending is written before them.
    private static func waits(_ e: AttemptMachine.Effect) -> Bool {
        switch e {
        case .ask, .waitForCommit, .runCheck, .runGate: true   // `nudge` writes by itself, once, when it goes
        default: false
        }
    }

    /// M2.2b: the events that carry a verdict's facts out of a long wait: a cancel during it replaces them.
    private static func judges(_ e: AttemptMachine.Event) -> Bool {
        switch e {
        case .checkDone, .gateDone, .blocked: true
        default: false
        }
    }

    /// One write of the work: the attempt's pending phase and events (in their order), then `change`. Every write of an
    /// attempt goes through here, so an event next to another write costs no write of its own (M1b.2: at most 8
    /// `store.update` in an attempt that passes with a gate, `LoopJournalWritesTests`).
    private func record(_ id: UUID, _ r: inout Run, _ change: @Sendable (inout Work) -> Void = { _ in }) async {
        let events = r.pending, phase = r.phase, lane = lane, mark = r.mark, name = r.name
        r.pending = []; r.phase = nil; r.mark = nil
        try? await store.update(id) { x in
            // M3.8: the job knows its terminal: what the start sweep removes after a fall, whatever the agent is called
            if let mark, let j = x.jobs.lastIndex(where: { $0.id == name && $0.kind == .loop && $0.state == .running }) { x.jobs[j].terminal = mark }
            if let phase { if let lane { x.loop?.showLane(lane, phase) } else { x.loop?.show(phase) } }
            for e in events {
                x.record(e)
                // M5.4: the attempt's counts add to its task's (the journal is a ring: the task keeps the sum)
                if let t = e.tokens, let i = x.tasks.firstIndex(where: { $0.id == e.task }) { x.tasks[i].tokens = (x.tasks[i].tokens ?? TokenCount()) + t }
            }
            change(&x)
        }
    }

    /// The `discarded` event's detail when no patch was written (the diff failed or was empty).
    static let noPatch = "sem alterações"

    /// Carries one effect of `AttemptMachine` out, with the host, store and git calls the attempt always made, and
    /// returns the event it observed (nil: the effect answers with none). `state`: the machine's, after it asked.
    private func perform(_ effect: AttemptMachine.Effect, _ state: AttemptMachine.State, _ r: inout Run) async -> AttemptMachine.Event? {
        let id = r.work.id, task = r.task, n = r.n, name = r.name, before = r.before, branch = r.branch, dir = r.dir
        switch effect {
        case .journal(let kind, let detail):
            // the journal: this attempt's events (it records, it never decides)
            // `discarded` names the patch only when one was written
            // `attemptStarted` went with the attempt's first write
            if kind != .attemptStarted {
                var e = entry(kind, task: task.id, attempt: n, detail: kind == .discarded && r.patched == false ? Self.noPatch : detail)
                if kind == .agentDismissed { e.tokens = r.tokens; r.tokens = nil }
                r.pending.append(e)
            }
            if kind == .verdict { r.at = host.now() }   // the verdict's time: before any wait for another terminal
        case .note(let text):
            let at = host.now()
            await record(id, &r) { $0.notes.append(WorkNote(at: at, text: text)) }
        case .show(let p): r.phase = .some(p)
        case .stopLoop(let stop): r.end = .stop(stop)
        case .fault(let what): r.fault = what
        case .summon:
            do {
                // M3b.6: a name taken since `attempt` read the names gives way to the next one (the job keeps `name`)
                let work = r.work, loop = r.loop, host = host
                let base = AgentNaming.name(work: work.title, task: task.title, taskId: task.id, attempt: n, lane: slot)
                let agent = try await AgentNaming.summon(base, taskId: task.id, taken: await host.namesTaken()) { (x: String) async throws(ProtocolError) -> UUID in
                    try await host.summon(name: x, for: work, loop: loop)
                }
                r.agent = agent; r.mark = agent
                return .summoned(agent)
            } catch { return .summonFailed(error.message) }
        case .ask:
            guard let agent = r.agent else { return .turnFailed("no terminal") }
            let spec = if let s = task.spec { await host.readSpec(s) } else { String?.none }
            let notes = r.work.notes.filter { $0.text.hasPrefix("[loop \(task.id)] ") }   // its own failures, by id
            var map: String?
            for m in Self.featureMaps where map == nil { if await host.exists(m, in: dir) { map = m } }
            let prompt = Self.prompt(task: task, spec: spec, attempt: n, tries: r.loop.tries, dir: dir, notes: notes, gate: r.loop.gate, map: map)
            let turn = Swift.min(r.loop.timeout, await left(id, r.loop, since: r.started))   // the budget bounds the turn too
            r.deadline = r.started + Double(turn)
            let ended = await talk(agent, prompt, .seconds(turn))
            // M2.0: it only records (the turn's end, good or bad, is journaled right after)
            if await host.resubmitted(agent) { r.pending.append(entry(.resubmitted, task: task.id, attempt: n, detail: name)) }
            return ended
        case .nudge:
            // not when the turn's time is over, the loop is stopping or the daemon is: straight to the check, as before
            guard let agent = r.agent, let deadline = r.deadline, !Task.isCancelled, !stopping.contains(id) else { return .waitExpired }
            let rest = Int(deadline.timeIntervalSince(host.now()))
            guard rest >= 1 else { return .waitExpired }
            // part of the same attempt (no `used`, no try); written now, with the turn's end: the nudge's turn may be long
            r.pending.append(entry(.nudged, task: task.id, attempt: n, detail: AskResult.Source.hook.rawValue))
            await record(id, &r)
            return await talk(agent, Self.nudgePrompt, .seconds(rest))
        case .waitForCommit, .lookForCommit:
            if effect == .waitForCommit, let agent = r.agent, let deadline = r.deadline {
                await waitForCommit(agent, before: before, branch: branch, dir: dir, until: deadline)
            }
            // for the journal only: the verdict reads the commit again, after the dismiss
            guard await committed(before: before, branch: branch, dir) else { return .waitExpired }
            return .commitSeen(await out(["rev-parse", "--short", "HEAD"], dir))
        case .dismiss:
            // M5.4: the transcript is read while its terminal still exists (the dismiss forgets it)
            if let agent = r.agent { r.tokens = await host.tokens(agent); await host.dismiss(agent) }
        case .measureFacts:
            // cancelled (the daemon stops): no verdict, no discard, the attempt not counted
            if Task.isCancelled { return .cancelled }
            let closed = (try? await store.get(id)).map { $0?.closedAt != nil } ?? true
            let starterGone = !(await host.starterAlive())
            if closed { return .workClosed }
            if starterGone { return .starterGone }
            guard state.facts.failure == nil else { return .measured(nil) }
            let committed = await committed(before: before, branch: branch, dir)
            let dirty = (await out(["status", "--porcelain", "--untracked-files=no"], dir)).map { !$0.isEmpty } ?? true
            let judged = await out(["rev-parse", "HEAD"], dir) ?? before
            r.on = await out(["rev-parse", "--abbrev-ref", "HEAD"], dir) ?? branch
            r.loose = Set(await untracked(dir))   // untracked before the check: the owner's (`keep`) and the agent's
            return .measured(.init(committed: committed, dirty: dirty, judged: judged))
        case .runCheck:
            do {
                let budgeted = Duration.seconds(await left(id, r.loop, since: r.started))
                let res = try await host.check(task.check ?? "false", in: dir, timeout: Swift.min(checkTimeout, budgeted))
                r.output = res.stdout + res.stderr; r.checkOutput = r.output
                return .checkDone(status: res.status, broken: nil)
            } catch where error.code == .timeout {
                return .checkDone(status: nil, broken: nil)
            } catch { return .checkDone(status: nil, broken: "check could not run: \(error.message)") }
        case .awaitOthers:
            guard let who = await host.othersWorking() else { return .blocked(nil) }
            // told once who it waits for, before the wait
            r.pending.append(entry(.othersWaiting, task: task.id, attempt: n, detail: who))
            await record(id, &r)
            return .blocked(await othersStillWorking(who))
        case .settle(let reset):
            // the check's (or the gate's) own edits, files and commits never count, never reach the gate and never leak
            // into the next attempt
            let after = await settle(state.judged, on: r.on, loose: r.loose, reset: reset, dir)
            return .settled(moved: after.moved, reset: after.reset)
        case .guardGate:
            guard let gate = r.loop.gate, let why = await tampered(gate, spec: task.spec, before: before, judged: state.judged, dir) else { return .gateClear }
            return .gateSkipped(why)
        case .runGate:
            // on the tree of `judged`, in the check's conditions (timeout, budget); its output is the note's
            do {
                let budgeted = Duration.seconds(await left(id, r.loop, since: r.started))
                let res = try await host.check(r.loop.gate ?? "false", in: dir, timeout: Swift.min(checkTimeout, budgeted))
                r.output = res.stdout + res.stderr
                return .gateDone(status: res.status, broken: nil)
            } catch where error.code == .timeout {
                r.output = ""
                return .gateDone(status: nil, broken: nil)
            } catch {
                r.output = ""
                return .gateDone(status: nil, broken: "gate could not run: \(error.message)")
            }
        case .decide:
            return .decided(AttemptDecision.decide(state.facts))
        case .discard:
            r.patched = await discard(id, task.id, n, before: before, branch: branch, keep: r.keep, dir)
        case .adoptionFailed(let reason):
            let at = r.at, text = LotBoards.scrub("[loop] adoção de \"\(task.title)\" falhou: \(reason); nada foi apagado")
            // the attempt is not counted on the task (no agent of its own ran); the next run starts from the HEAD of then
            await record(id, &r) { x in
                if let i = x.tasks.firstIndex(where: { $0.id == task.id }), x.tasks[i].state == .inProgress {
                    x.tasks[i].state = .open; x.tasks[i].lastFailure = reason; x.tasks[i].updatedAt = at
                }
                x.notes.append(WorkNote(at: at, text: text))
                Self.endJob(&x, name, reason, at: at)
                Self.forget(&x, task.id)
            }
        case .uncount:
            let at = host.now()
            await record(id, &r) { x in
                if let i = x.tasks.firstIndex(where: { $0.id == task.id }), x.tasks[i].state == .inProgress { x.tasks[i].state = .open }
                let used = x.loop?.used ?? 0
                x.loop?.used = Swift.max(0, used - 1)
                if let j = x.jobs.firstIndex(where: { $0.id == name && $0.state == .running }) { x.jobs[j].state = .gone; x.jobs[j].endedAt = at }
                // M2.2b: `resumeFrom` stays, as after a fall (M2.2a): a commit already there is judged by the next run
                // M2b.1: left now: only what was committed before here is the attempt's. M2c: not an adoption's, which
                // still carries when its attempt was first left
                if let i = x.tasks.firstIndex(where: { $0.id == task.id }), x.tasks[i].resumeFrom != nil, x.tasks[i].resumeAt == nil {
                    x.tasks[i].resumeAt = at
                }
            }
        case .reopen(let why):
            let at = host.now()
            await record(id, &r) { x in
                if let i = x.tasks.firstIndex(where: { $0.id == task.id }), x.tasks[i].state == .inProgress { x.tasks[i].state = .open }
                Self.endJob(&x, name, why, at: at)
                Self.forget(&x, task.id)
            }
        case .markDone:
            let at = r.at, judged = state.judged
            // of `judged`, never of a HEAD read after the check and the gate ran
            let head = await out(["rev-parse", "--short", judged], dir) ?? ""
            let log = await out(["log", "--format=%h %s", "-n", "\(Self.evidenceCommits)", "\(before)..\(judged)"], dir) ?? ""
            var evidence = TaskEvidence(
                commits: log.split(separator: "\n").map { Self.evidenceCommit(String($0)) },
                shortstat: await out(["diff", "--shortstat", before, judged], dir) ?? "",
                checkTail: Self.evidenceTail(check: r.checkOutput, gate: r.loop.gate == nil ? nil : r.output),
                seconds: Swift.max(0, Int(at.timeIntervalSince(r.started).rounded())), attempt: n)
            // the declared files, from the tree as the verdict left it: `judged`, what the agent left untracked and
            // what is ignored (an untracked file the check or the gate made is already gone)
            if let g = task.evidenceGlob {
                let c = await host.copyEvidence(g, from: dir, work: id, task: task.id)
                evidence.files = c.files; evidence.filesDir = c.dir
                if let n = c.note { await note(id, "[loop] evidência de \"\(task.title)\": \(n)") }
            }
            let found = evidence
            // M3.5: in a lane the task is `done` only once integrated: what passed waits for `WorkLoopLanes`
            if lane != nil {
                passed = Passed(task: task, name: name, n: n, tries: r.loop.tries, at: at, evidence: found, before: before, judged: judged, head: head, dir: dir)
                await record(id, &r)
                return nil
            }
            await record(id, &r) { Self.markDone(&$0, task.id, n: n, at: at, evidence: found, job: name, head: head) }
            await reportEnd(id, task.id)
        case .markOpenOrDeferred(let reason, let last):
            let at = r.at
            let tail = r.output.split(separator: "\n", omittingEmptySubsequences: false).suffix(Self.noteLines).joined(separator: "\n")
            // the next attempt's prompt carries it: secrets hidden (LotBoards.scrub's known shapes). ponytail: tail capped at 4000 chars
            // M3.8: and which agent it was (its terminal's name)
            let text = LotBoards.scrub("[loop \(task.id)] \(task.title), tentativa \(n)/\(r.loop.tries): \(reason) (agente \(name))"
                + (tail.isEmpty ? "" : "\n" + String(tail.suffix(Self.noteChars))))
            await record(id, &r) { x in
                if let i = x.tasks.firstIndex(where: { $0.id == task.id }), x.tasks[i].state == .inProgress {
                    x.tasks[i].tries = n; x.tasks[i].lastFailure = reason; x.tasks[i].updatedAt = at
                    if last { x.tasks[i].state = .deferred; x.tasks[i].reason = "loop: \(reason)" } else { x.tasks[i].state = .open }
                }
                x.notes.append(WorkNote(at: at, text: text))
                Self.endJob(&x, name, reason, at: at)
                Self.forget(&x, task.id)
            }
            if last { await reportEnd(id, task.id) }
        }
        return nil
    }

    /// What an approved task is left as (the loop's own write, and a lane's once it is integrated).
    static func markDone(_ x: inout Work, _ task: String, n: Int, at: Date, evidence: TaskEvidence, job: String, head: String) {
        // a task dropped or done meanwhile keeps that state
        if let i = x.tasks.firstIndex(where: { $0.id == task }), x.tasks[i].state == .inProgress {
            x.tasks[i].state = .done; x.tasks[i].tries = n; x.tasks[i].reason = nil; x.tasks[i].lastFailure = nil; x.tasks[i].updatedAt = at
            x.tasks[i].evidence = evidence
        }
        endJob(&x, job, head, at: at)
        forget(&x, task)
    }

    /// Another terminal that can edit the worktree is in a turn: no reset under it. It gets `othersWait` to finish (a short
    /// chat is no reason to end the loop); the name of the one still working after that, nil when none is.
    /// `first`: the one found working, already in the attempt's journal.
    private func othersStillWorking(_ first: String) async -> String? {
        var who: String? = first
        let end = ContinuousClock.now + othersWait
        while who != nil, ContinuousClock.now < end, !Task.isCancelled {
            await Self.nap(Swift.min(poll, .seconds(5)))
            who = await host.othersWorking()
        }
        return who
    }

    /// The Shepherd hears of a task the moment it ends, not only when the whole loop does.
    /// Never awaited: the line is typed into the Shepherd only once it is idle, and a loop that waited for that stood
    /// still while the Shepherd was in a turn (up to the inject's hold), with the next task's terminal never opening.
    /// M3d.2: the line it sent (nil: none), decided before the `Task`, so a test reads the decision without a clock.
    /// M5.1: inside the window of the last one sent it is held (`LoopNotices`), and goes with the next one as counts.
    @discardableResult
    func reportEnd(_ work: UUID, _ task: String) async -> String? {
        guard let w = try? await store.get(work) else { return nil }
        // M6.5 (A5): a task with no line of its own (done under `end`) still lets what is held go past the window
        guard let one = Self.endNotice(w, task) else { return await flushNotices() }
        let done = w.tasks.first { $0.id == task }?.state == .done
        return sendNotice(await notices.offer(one, done: done, at: host.now()))
    }

    /// M6.5 (A5): what the window held, sent now if it passed (nil: nothing went).
    @discardableResult
    func flushNotices() async -> String? { sendNotice(await notices.flush(at: host.now())) }

    /// Never awaited (`reportEnd`): the line goes to the Shepherd once it is idle.
    private func sendNotice(_ line: String?) -> String? {
        guard let line else { return nil }
        let host = host
        Task { await host.taskEnded(line) }
        return line
    }

    /// The notice for `task` as it ended in `w`; nil: none goes now.
    /// M3c.4: `--notify end` keeps a task done for the loop's end notice (a deferred one still goes now).
    static func endNotice(_ w: Work, _ task: String) -> String? {
        guard let t = w.tasks.first(where: { $0.id == task }) else { return nil }
        if w.loop?.notify == .end && t.state == .done { return nil }
        return WorkStatusText.taskEnded(t)
    }

    /// Seconds of the budget left for this attempt (at least 1); no budget: a day. In a lane: `laneShare`.
    func left(_ id: UUID, _ loop: WorkLoopState, since started: Date) async -> Int {
        guard let b = loop.budget else { return 86_400 }
        if lane != nil { return await laneShare(id) }
        return Swift.max(1, b - (loop.spent ?? 0) - Int(host.now().timeIntervalSince(started)))
    }

    /// M3b.4: seconds of `--budget` nobody used yet (zero or less: it is spent; nil: no budget): the budget, less
    /// `spent` (the lanes that ended), less what every lane alive has run so far. A lane is in `lanes` or in `spent`,
    /// never in both: its seconds go to `spent` in the write that takes it out of `lanes`.
    static func unspent(_ loop: WorkLoopState, now: Date) -> Int? {
        guard let b = loop.budget else { return nil }
        let live = (loop.lanes ?? []).reduce(0.0) { $0 + Swift.max(0, now.timeIntervalSince($1.started ?? $1.since)) }
        return b - (loop.spent ?? 0) - Int(live.rounded(.up))
    }

    /// M3b.4: seconds one phase of one lane (a turn, a check, a gate, the integrator's gate) may take (at least 1; no
    /// budget: a day): what is `unspent` now, read from the work's file, divided by the lanes alive, which all spend
    /// it at once. Four lanes that start with 100 s get 25 s each, not 100.
    // ponytail: a phase keeps the limit it began with. When younger lanes end early, an older phase may still run on
    // a limit from when fewer lanes were alive: the loop's total may pass the budget by what is left of that one
    // phase (the scheduler stops everything at the first lane that ends past the budget). No watchdog: it would be a
    // clock of its own, and the loop has none.
    func laneShare(_ id: UUID) async -> Int {
        guard let loop = (try? await store.get(id))?.loop else { return 1 }
        guard let rest = Self.unspent(loop, now: host.now()) else { return 86_400 }
        return Swift.max(1, rest / Swift.max(1, loop.lanes?.count ?? 1))
    }

    static func blockedNote(_ who: String) -> String {
        "[loop] '\(who)' está trabalhando no cercado: o laço não reseta a worktree com outro agente nela; laço parado, worktree intocada"
    }

    /// One line of the loop's journal (`WorkLoopState.events`, `work status --events`). It only records: no decision
    /// reads it, and it never reaches an agent's prompt.
    private func event(_ id: UUID, _ kind: LoopEvent.Kind) async {
        let e = entry(kind)
        try? await store.update(id) { $0.record(e) }
    }

    /// The event as the journal keeps it, timed now.
    func entry(_ kind: LoopEvent.Kind, task: String? = nil, attempt: Int? = nil, detail: String? = nil) -> LoopEvent {
        LoopEvent(at: host.now(), kind: kind, task: task, attempt: attempt, detail: detail.map(Self.eventDetail), lane: lane)
    }

    /// An event's `detail`: it may be the agent's or the check's text, so, like the evidence, it loses its ANSI sequences
    /// and its control and format characters, has its secrets hidden and is cut at `LoopEvent.detailMax` characters.
    static func eventDetail(_ s: String) -> String {
        String(LotBoards.scrub(RerailText.plain(ANSI.strip(s))).trimmingCharacters(in: .whitespaces).prefix(LoopEvent.detailMax))
    }

    func note(_ id: UUID, _ text: String) async {
        let at = host.now()
        try? await store.update(id) { $0.notes.append(WorkNote(at: at, text: text)) }
    }

    /// An `.idle` end with no new commit yet: wait until there is one and the agent is out of its turn, or `deadline`.
    private func waitForCommit(_ agent: UUID, before: String, branch: String, dir: URL, until deadline: Date) async {
        if await committed(before: before, branch: branch, dir) { return }
        while host.now() < deadline, !Task.isCancelled {
            if !(await host.working(agent)), await committed(before: before, branch: branch, dir) { return }
            await Self.nap(poll)
        }
    }

    /// The loop's one wait on the clock: its polls (a commit, another terminal, the agent's screen) have no event.
    private static func nap(_ d: Duration) async { try? await Task.sleep(for: d) }

    /// `host.ask` as the machine's event. M5.3: every `poll` meanwhile the agent's screen is read; one stuck in the
    /// usage-limit dialog ends the turn now (the ask is dropped, nothing is typed) instead of at its timeout.
    private func talk(_ agent: UUID, _ prompt: String, _ timeout: Duration) async -> AttemptMachine.Event {
        let host = host, poll = poll
        return await withTaskGroup(of: AttemptMachine.Event?.self) { g in
            g.addTask {
                do throws(ProtocolError) { return .turnEnded(source: try await host.ask(agent, prompt: prompt, timeout: timeout)) }
                catch where error.code == .timeout { return .turnTimedOut }
                catch { return .turnFailed(error.message) }
            }
            g.addTask {
                while !Task.isCancelled {
                    await Self.nap(poll)
                    if !Task.isCancelled, let text = await host.usageLimit(agent) { return .usageLimit(UsageLimit.excerpt(text)) }
                }
                return nil
            }
            for await e in g { if let e { g.cancelAll(); return e } }
            return .turnFailed("no turn")
        }
    }

    /// M2.2a: a 40-character lowercase hex sha, as `git rev-parse HEAD` prints one. `resumeFrom` comes from the work's
    /// file: it is a git argument only after this.
    static func isSha(_ s: String) -> Bool {
        s.utf8.count == 40 && s.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }

    /// M2.2a: `task` was left mid-attempt by a daemon that fell and its commit is here to be judged: `resumeFrom` is a
    /// sha of this repository, the worktree is on the same branch and HEAD is ahead of it (`committed`). The caller
    /// already saw the tracked tree clean. M2b.1: and every commit between them was made before `resumeAt`, when the
    /// attempt was left: one made after it (the owner's) is not the attempt's. No `resumeAt`, or a date that cannot be
    /// read: not adopted. M2c: `%ct` is whole seconds and `resumeAt` is not, so a commit of the very second of
    /// `resumeAt` may be from after it: in doubt, not adopted (a fresh agent is called instead; nothing is deleted).
    // ponytail: the committer date is the commit's own word (GIT_COMMITTER_DATE, a clock set back): it keeps out what
    // came after the fall, not a forged commit. A failed adoption deletes nothing either way.
    private func adoptable(_ task: WorkTask, branch: String, _ dir: URL) async -> Bool {
        guard let from = task.resumeFrom, Self.isSha(from), task.resumeBranch == branch, let left = task.resumeAt,
              (try? await host.git(["cat-file", "-e", "\(from)^{commit}"], in: dir))?.status == 0,
              await committed(before: from, branch: branch, dir),
              let dates = await out(["log", "--format=%ct", "\(from)..HEAD"], dir), !dates.isEmpty else { return false }
        return dates.split(separator: "\n").allSatisfy { Int($0).map { Double($0) < left.timeIntervalSince1970.rounded(.down) } ?? false }
    }

    /// The attempt of `task` ended (a verdict, or none: reopened): there is nothing to resume. Not when cancelled.
    static func forget(_ w: inout Work, _ task: String) {
        guard let i = w.tasks.firstIndex(where: { $0.id == task }) else { return }
        w.tasks[i].forgetResume()
    }

    /// A new commit: HEAD moved, `before` is its ancestor (no rewritten history) and the branch is still `branch`.
    private func committed(before: String, branch: String, _ dir: URL) async -> Bool {
        guard let head = await out(["rev-parse", "HEAD"], dir), head != before,
              await out(["rev-parse", "--abbrev-ref", "HEAD"], dir) == branch,
              (try? await host.git(["merge-base", "--is-ancestor", before, "HEAD"], in: dir))?.status == 0 else { return false }
        return true
    }

    /// Why the attempt may not go to the gate `gate`: it changed (edited, deleted, renamed) a file whose full path
    /// appears literally in the gate's text and that already existed in `before`. nil = it did not. Creating the file
    /// for the first time is allowed (a task whose spec is to write that script), and only the gate is guarded: a
    /// task's own check often names the very files the task must write. A file the task's spec names is the task's to
    /// change too (B4.1 adds a rule to the lint script that is the gate): the spec is read from `before`, never from
    /// the attempt's tree, so an agent cannot authorise itself by editing its spec.
    // ponytail: substring match on the command text, no shell parsing; a script the gate reaches indirectly
    // (sourced by another script, a directory argument) is not seen. Parse the command if that gap is ever used.
    private func tampered(_ gate: String, spec: String?, before: String, judged: String, _ dir: URL) async -> String? {
        var named = ""   // the spec's text at `before`; empty: no spec, outside the repo or not committed there
        if let spec {
            let rel = spec.hasPrefix(dir.path + "/") ? String(spec.dropFirst(dir.path.count + 1)) : spec
            if !rel.hasPrefix("/"), !rel.contains(".."), let r = try? await host.git(["show", "\(before):\(rel)"], in: dir), r.status == 0 { named = r.stdout }
        }
        // M7.2 (A5): `-z`, read untrimmed: a name with a newline or a space at an end is that name
        guard let d = try? await host.git(["diff", "--name-only", "-z", "--no-renames", before, judged], in: dir), d.status == 0 else {
            return "gate did not run (could not list what the attempt changed)"
        }
        for path in d.stdout.split(separator: "\0").map(String.init) where gate.contains(path) && !named.contains(path) {
            if (try? await host.git(["cat-file", "-e", "\(before):\(path)"], in: dir))?.status == 0 {
                return "a tentativa alterou «\(path)», que o portão executa"
            }
        }
        return nil
    }

    /// After the check or the gate ran: `moved` when it moved HEAD off `judged` (a commit, a branch switch). With `reset`,
    /// the tree goes back to exactly `judged` on `on`: tracked files restored, the untracked files it created (those
    /// not in `loose`) removed. Ignored files (build output) stay. The result's `reset` (for the journal only): there
    /// was something to put back.
    private func settle(_ judged: String, on: String, loose: Set<String>, reset: Bool, _ dir: URL) async -> (moved: Bool, reset: Bool) {
        let head = await out(["rev-parse", "HEAD"], dir), ref = await out(["rev-parse", "--abbrev-ref", "HEAD"], dir)
        let moved = head != judged || ref != on
        guard reset else { return (moved, false) }
        let edited = (await out(["status", "--porcelain", "--untracked-files=no"], dir)).map { !$0.isEmpty } ?? false
        if ref != on { _ = try? await host.git(["checkout", "-q", "-f", on == "HEAD" ? judged : on], in: dir) }
        // only when there is something to put back (M2b.1: a check that touched nothing costs no `reset --hard`)
        if moved || edited { _ = try? await host.git(["reset", "-q", "--hard", judged], in: dir) }
        let made = await untracked(dir).filter { !loose.contains($0) }
        // ponytail: one git call, so a check that leaves tens of thousands of untracked files passes ARG_MAX; chunk then
        if !made.isEmpty { _ = try? await host.git(["--literal-pathspecs", "clean", "-q", "-f", "--"] + made, in: dir) }
        return (moved, moved || edited || !made.isEmpty)
    }

    /// Untracked files that are not ignored.
    private func untracked(_ dir: URL) async -> [String] {
        (await out(["ls-files", "-z", "--others", "--exclude-standard"], dir) ?? "").split(separator: "\0").map(String.init)
    }

    /// A failed attempt's work goes to `patchDir/<task>-<n>.patch`; the tree goes back to `before` on `branch`.
    /// True: the patch was written (false: the diff failed or was empty, so there is no file).
    private func discard(_ work: UUID, _ task: String, _ n: Int, before: String, branch: String, keep: [String], _ dir: URL) async -> Bool {
        var wrote = false
        _ = try? await host.git(["add", "-A"], in: dir)
        if !keep.isEmpty { _ = try? await host.git(["--literal-pathspecs", "reset", "-q", "--"] + keep, in: dir) }
        // ponytail: the patch is the first 1 MiB of the diff (BoundedProcess's cap)
        if let d = try? await host.git(["diff", "--cached", "--binary", before], in: dir), d.status == 0, !d.stdoutData.isEmpty {
            let folder = host.patchDir(work)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            wrote = (try? d.stdoutData.write(to: folder.appendingPathComponent("\(task)-\(n).patch"))) != nil
        }
        _ = try? await host.git(["checkout", "-q", "-f", branch == "HEAD" ? before : branch], in: dir)
        _ = try? await host.git(["reset", "-q", "--hard", before], in: dir)
        return wrote
    }

    func out(_ args: [String], _ dir: URL) async -> String? {
        guard let r = try? await host.git(args, in: dir), r.status == 0 else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func endJob(_ w: inout Work, _ id: String, _ result: String, at: Date) {
        guard let j = w.jobs.firstIndex(where: { $0.id == id && $0.state == .running }) else { return }
        w.jobs[j].state = .finished; w.jobs[j].endedAt = at; w.jobs[j].result = String(result.prefix(280))
    }

    /// One of the evidence's `commits`, from a `git log --format="%h %s"` line: the subject is the agent's text, so it
    /// loses its ANSI sequences and its control and format characters (`RerailText.plain`) and is cut at
    /// `evidenceSubject` characters (`Character`s, not bytes).
    static func evidenceCommit(_ line: String) -> String {
        let p = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let subject = RerailText.plain(ANSI.strip(p.count > 1 ? String(p[1]) : "")).trimmingCharacters(in: .whitespaces)
        return subject.isEmpty ? String(p[0]) : "\(p[0]) \(subject.prefix(evidenceSubject))"
    }

    /// The evidence's `checkTail`: the last `evidenceLines` lines of the check's output, then the gate's (if any),
    /// without ANSI sequences or control and format characters (`RerailText.plain`, line by line), secrets hidden
    /// (LotBoards.scrub's known shapes), the last `evidenceChars` characters.
    static func evidenceTail(check: String, gate: String?) -> String {
        let tails = [check, gate ?? ""].map {
            ANSI.strip($0).trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false)
                .suffix(evidenceLines).map { RerailText.plain(String($0)) }.joined(separator: "\n")
        }.filter { !$0.isEmpty }
        return String(LotBoards.scrub(tails.joined(separator: "\n")).suffix(evidenceChars))
    }

    /// Why `what` (the check, the gate) did not pass, from its exit status (nil: it timed out); nil = it passed.
    static func failure(_ what: String, _ status: Int32?) -> String? {
        guard let status else { return "\(what) timed out" }
        return status == 0 ? nil : "\(what) failed (exit \(status))"
    }

    /// nil = pass, else the reasons joined by `; `. `gate`: the gate's `failure` (nil: it passed, did not run or there is none).
    static func verdict(checkStatus: Int32?, gate: String? = nil, committed: Bool, dirty: Bool) -> String? {
        var r = [failure("check", checkStatus), gate].compactMap { $0 }
        if !committed { r.append("no new commit") }
        if dirty { r.append("tracked files left dirty") }
        return r.isEmpty ? nil : r.joined(separator: "; ")
    }

    /// The attempt's prompt, in the owner's language.
    static func prompt(task: WorkTask, spec: String?, attempt: Int, tries: Int, dir: URL, notes: [WorkNote], gate: String? = nil, map: String? = nil) -> String {
        var lines = [
            "Tarefa \"\(task.title)\", tentativa \(attempt) de \(tries), num laço autônomo: ninguém vai responder perguntas, então decida e registre a decisão no commit.",
            "Trabalhe só em \(dir.path). Faça só esta tarefa. Não faça push nem land.",
            "Faça commit assim que código e testes estiverem escritos, ANTES de rodar build ou teste: sem commit novo a tarefa não conta. Se depois corrigir algo, faça outro commit. Não deixe arquivo modificado sem commit.",
            "Depois do seu turno, o laço roda este comando em \(dir.path) e só ele decide se a tarefa passou:",
            task.check ?? "",
        ]
        if let gate { lines += ["e depois este portão:", gate] }
        if let map { lines.append("O mapa de funcionalidades do projeto está em \(map): use os nomes dele.") }
        if !notes.isEmpty { lines.append("O que falhou nas tentativas anteriores:"); lines += notes.map(\.text) }
        lines.append("")
        lines.append(spec ?? task.title)
        return lines.joined(separator: "\n")
    }
}
