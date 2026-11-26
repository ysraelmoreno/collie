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
    /// P2: the last lines of the terminal's screen (what `usageLimit` reads), raw. nil: none. Read only.
    func screen(_ terminal: UUID) async -> [String]?
    /// C1 (P2-d): the daemon's live tokens (`AuthRegistry.secrets`), hidden in what of a screen goes to a note.
    func secrets() async -> Set<String>
    func dismiss(_ terminal: UUID) async
    /// F2 Z3b: `dismiss`, then every process still in the terminal's process group killed (`WorkLoop.reapGroup`).
    func dismissReaping(_ terminal: UUID) async
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
    /// T1 f2fix8 (reviewOneCopy): `laneGit` with `stdin` fed to git (`cat-file --batch`'s oids), killed past `timeout`,
    /// its output bounded by `cap` (T2 f2fix8: only `reviewSnapshot` asks above the plain `laneGit`'s 1 MiB).
    func laneGit(_ args: [String], stdin: Data?, timeout: Duration, cap: Int, in dir: URL) async throws(ProtocolError) -> ProcessResult
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
    /// F2 R4: a reviewer's terminal: `summon` as the starter's (never leashed to the agent that worked; `loop.model` is
    /// the persona's), and marked so that `othersWorking`/`anyoneWorking` never count it (the loop's own reviewer is
    /// no one working in the paddock). Dismissed with `dismiss`.
    /// F2 X1: `cwd` is its folder and its project: an empty one the loop made (`reviewScratch`, under `reviewRoot`), never the worktree nor
    /// a checkout of it, so no CLAUDE.md, AGENTS.md, settings or hooks the judged agent committed ever load there.
    func summonReviewer(name: String, for work: Work, loop: WorkLoopState, cwd: URL) async throws(ProtocolError) -> UUID
    /// F2 Y1: where the reviewers' folders are made (`WorkLoop.reviewScratch`): `<daemon root>/collie-review`.
    var reviewRoot: URL { get }
    /// F2 Z2: what a strict loop agent writes under the home besides caches (`WorkLoop.strictWritable`): the home and
    /// those paths (write grants, paddocks).
    func strictWrites() async -> (home: URL, paths: [String])
    /// F2 V2: the home whose `.claude.json` the reviewers read (`reviewGlobalConfigHash`): `strictWrites`'s.
    func globalConfigHome() async -> URL
    /// F2 V3: marks `reviewRoot` trusted in `globalConfigHome`'s `.claude.json` (`WorkLoop.trustReviewRoot`): the note to
    /// leave, nil when nothing was done.
    func trustReviewers() async -> String?
    /// F3: the integrator of the paddock whose worktree is `dir`, taken for `work`'s loop: the paddock's one (fields
    /// and the loop share its queue) on the daemon, a new one on a host with no daemon (the tests' fakes).
    func integrator(dir: URL, work: UUID) async -> LaneIntegrator
    /// F2 A4/A5/V2 (f2fix9): the judged agent, by id, started open (or free of the sandbox): it writes the whole home, so
    /// a `plantedConfig` above the reviewers is no sign of tampering and is not asked. Read at the attempt's `.dismiss`,
    /// before the terminal goes (the review comes after it). The premise that `plantedConfig` would find the owner's own
    /// `~/.claude` was contested (rev-f2i); what goes unchecked in open is a config the agent planted above `reviewRoot`
    /// (CLAUDE.md, AGENTS.md, `.claude/`): it may sway a reviewer, and the parecer never approves alone (A1: advisory).
    /// No terminal of that id: false (the check stays).
    func startedOpen(_ agent: UUID) async -> Bool
    /// F2 R4: `ask`, returning the text the terminal answered.
    func askText(_ terminal: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> String
    /// A4: the loop's paddock carries the factory mark (A2), read now.
    func factoryPaddock() async -> Bool
    /// A4: `paddock land` of the loop's paddock by the command's own path (`PaddockManager.land`): the base branch's
    /// commit before and after. The engine only ever asks `.merge`: it never pushes nor opens a PR.
    /// C2: `late`, what failed AFTER the merge (saving the paddock): the base moved all the same; nil: nothing did.
    /// A throw is a land that never merged. C3b: `base`, the base's commit the land was judged on: under the land's claim,
    /// right before the merge, a base branch elsewhere throws `.conflict` (`landBaseMoved`); nil: not checked.
    /// C4a: `unrecorded`, why the land merged but its record (what the daily cap counts) could not be written: the
    /// loop stops (`landRegistryFailed`) and the owner is told; nil: recorded (or nothing to record).
    func land(mode: LandMode, message: String, base: String?) async throws(ProtocolError) -> (before: String, after: String, late: String?, unrecorded: String?)
    /// A4: one line for the owner (`notify`).
    func notifyOwner(_ line: String) async
    /// A5: why the paddock's `factory doctor` no longer passes the minimum (static and judge at least 1), read now;
    /// nil: it passes. C3a: read at the paddock's HEAD (`FactoryDoctorReader.headRefusal`), never the agent's tree.
    func doctorRefusal() async -> String?
    /// C3a: when the paddock was auto-landed (`Paddock.autoLands`, the daemon's own record at each land): what the daily
    /// cap counts, never a work's journal (a new run, a reopen or the pruning of closed works would clear it).
    func autoLands() async -> [Date]
    /// C3b: the paddock's base branch's commit, read now (what the land merges into). nil: the host knows no base (the
    /// tests' fakes, a folder paddock); a throw: git could not say (the land stops, fail closed).
    func baseHead() async throws(ProtocolError) -> String?
}

extension LoopHost {
    /// A host that cannot tell the starter apart (the tests' fakes).
    func anyoneWorking() async -> String? { await othersWorking() }
    func resubmitted(_ terminal: UUID) async -> Bool { false }
    func usageLimit(_ terminal: UUID) async -> String? { nil }
    func screen(_ terminal: UUID) async -> [String]? { nil }
    func secrets() async -> Set<String> { [] }
    func tokens(_ terminal: UUID) async -> TokenCount? { nil }
    /// A host with no processes (the tests' fakes).
    func dismissReaping(_ terminal: UUID) async { await dismiss(terminal) }
    func taskEnded(_ line: String) async {}
    func laneHost(_ lane: Lane) async throws(ProtocolError) -> any LoopHost {
        throw ProtocolError(code: .unavailable, message: "this host runs no lanes")
    }
    func laneGone(_ lane: Lane) async {}
    /// A host with one git (the tests' fakes, which have no profile).
    func laneGit(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult { try await git(args, in: dir) }
    func laneGit(_ args: [String], stdin: Data?, timeout: Duration, cap: Int, in dir: URL) async throws(ProtocolError) -> ProcessResult {
        try await GitRunner.run(args, in: dir, timeout: timeout, cap: cap, stdin: stdin)
    }
    func namesTaken() async -> Set<String> { [] }
    /// A host with no reviewers: the review fails closed (every persona 'sem resposta').
    func summonReviewer(name: String, for work: Work, loop: WorkLoopState, cwd: URL) async throws(ProtocolError) -> UUID {
        throw ProtocolError(code: .unavailable, message: "this host runs no reviewers")
    }
    func askText(_ terminal: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> String {
        throw ProtocolError(code: .unavailable, message: "this host runs no reviewers")
    }
    /// The tests' fakes: beside their patches (a fake with reviewers puts it outside the temp dir).
    var reviewRoot: URL { WorkLoop.reviewRoot(of: patchDir(UUID()).deletingLastPathComponent()) }
    /// The tests' fakes: the user's home, no grants.
    func strictWrites() async -> (home: URL, paths: [String]) { (URL(fileURLWithPath: NSHomeDirectory()), []) }
    func globalConfigHome() async -> URL { await strictWrites().home }
    /// The tests' fakes: never the user's `~/.claude.json`.
    func trustReviewers() async -> String? { nil }
    func integrator(dir: URL, work: UUID) async -> LaneIntegrator { LaneIntegrator(host: self, dir: dir, work: work) }
    func startedOpen(_ agent: UUID) async -> Bool { false }
    /// A host with no paddock to land (the tests' fakes): never a factory's, and its land refuses.
    func factoryPaddock() async -> Bool { false }
    func land(mode: LandMode, message: String, base: String?) async throws(ProtocolError) -> (before: String, after: String, late: String?, unrecorded: String?) {
        throw ProtocolError(code: .unavailable, message: "this host lands nothing")
    }
    func notifyOwner(_ line: String) async {}
    func doctorRefusal() async -> String? { nil }
    func autoLands() async -> [Date] { [] }
    func baseHead() async throws(ProtocolError) -> String? { nil }
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
    static var nudgePrompt: String { tr("Você encerrou o turno sem fazer commit. Ninguém vai responder perguntas neste laço: decida sozinho. Faça commit do que escreveu (ou diga em uma linha o que impede) e encerre.",
        "You ended the turn without committing. Nobody will answer questions in this loop: decide on your own. Commit what you wrote (or say in one line what stops you) and end the turn.") }
    /// M10.2: what an agent whose commit failed the pre-check is told, once per attempt, before its output's tail.
    static var precheckPromptHead: String { tr("O pré-check do laço falhou no seu commit. Ninguém vai responder perguntas neste laço: corrija, faça commit e encerre o turno. Fim da saída:",
        "The loop's pre-check failed on your commit. Nobody will answer questions in this loop: fix it, commit and end the turn. End of the output:") }
    static func precheckPrompt(_ tail: String) -> String { precheckPromptHead + "\n" + tail }
    /// M10.2: the pre-check's own limit (the budget's rest bounds it too) and its tail's size.
    static let precheckTimeout = 180, precheckLines = 40, precheckChars = 3000
    /// A task's check limit (the loop's own, `init`'s default); `work run`'s start-state check (C2) uses the same.
    static let defaultCheckTimeout: Duration = .seconds(1800)
    static let evidenceCommits = 20, evidenceSubject = 200, evidenceLines = 20, evidenceChars = 2000
    let store: WorkStore, host: any LoopHost, poll: Duration, checkTimeout: Duration, othersWait: Duration
    /// A test's seam: the event an effect answers with, instead of carrying it out (nil: carried out as always).
    let events: (@Sendable (AttemptMachine.Effect) -> AttemptMachine.Event?)?
    var stopping: Set<UUID> = []
    /// C5a: `work stop --now` (or a plain stop past `stopGrace`): the attempt in course is dropped, not judged.
    var forcing: Set<UUID> = []
    /// C5a: a plain stop's wait for the attempt's verdict before it turns into `--now` (the tests' short one).
    static let defaultStopGrace: Duration = .seconds(300)
    let stopGrace: Duration
    /// C5a: the plain stop each grace timer belongs to: a timer of an older stop (an earlier run) forces nothing.
    private var stopTokens: [UUID: UUID] = [:]
    /// M3.5: set on the engine of one lane (`WorkLoopLanes`): the lane's id (its folder's name). `host` is then the
    /// lane's, an attempt that passes waits in `passed` for the integrator, and its journal and phase carry the lane.
    /// nil: the loop's own engine, in the paddock's worktree.
    let lane: String?
    /// M3.8, a lane's engine: the lane's number in its run (1…), for its agent's name (`AgentNaming`'s `f<n>`).
    let slot: Int?
    /// M3.5, a lane's engine: the attempt that passed in the lane, until it is integrated (or not).
    var passed: Passed?
    /// A5: the queued work an auto-land chain goes on to after a work's land, by that work (`takeNext`); the router
    /// activates it (`activate`) only once its engine is registered.
    var chainNext: [UUID: Chain] = [:]
    /// M3.5: the parallel runs of this engine, by work (`WorkLoopLanes`); empty without `--parallel`.
    var lanes: [UUID: Lanes] = [:]
    /// M5.1: the Shepherd's notice window, one per loop: a lane's engine shares its loop's.
    let notices: LoopNotices
    /// P2: the wait before an attempt whose prompt was not delivered starts over with a new agent (the tests' zero).
    let promptRetryWait: Duration
    /// C5c: each pre-check's own ceiling (past it: red) and the pre-checks running now, by work (`work stop` cancels them).
    static let defaultPreCheckTimeout: Duration = .seconds(120)
    let preCheckTimeout: Duration
    var preChecks: [UUID: Task<[WorkTask], Never>] = [:]
    /// C6: the land's gate or CI running now, by work: `work stop` (and `--now`) cancels it at once, as the pre-check's.
    var landRuns: [UUID: Task<Result<ProcessResult, ProtocolError>, Never>] = [:]

    init(store: WorkStore, host: any LoopHost, poll: Duration = .seconds(15), checkTimeout: Duration = WorkLoop.defaultCheckTimeout,
         othersWait: Duration = .seconds(300), events: (@Sendable (AttemptMachine.Effect) -> AttemptMachine.Event?)? = nil,
         lane: String? = nil, slot: Int? = nil, notices: LoopNotices = LoopNotices(), promptRetryWait: Duration = .seconds(20),
         stopGrace: Duration = WorkLoop.defaultStopGrace, preCheckTimeout: Duration = WorkLoop.defaultPreCheckTimeout) {
        self.stopGrace = stopGrace; self.preCheckTimeout = preCheckTimeout
        self.store = store; self.host = host; self.poll = poll; self.checkTimeout = checkTimeout; self.othersWait = othersWait
        self.events = events; self.lane = lane; self.slot = slot; self.notices = notices; self.promptRetryWait = promptRetryWait
    }

    /// Ends the loop after the current attempt's verdict. C5a: no verdict within `stopGrace`: forced (`now`), with a note.
    /// `now`: the attempt in course is dropped at once (its agent dismissed, its patch discarded, its task open again).
    /// ponytail: forcing reaches the agent's turn and the waits between (commit, other terminals); a check, gate,
    /// acceptance or review already running ends by its own timeout first. A parallel run (lanes) stops as a plain stop.
    func stop(work id: UUID, now: Bool = false) async {
        let first = !stopping.contains(id)
        stopping.insert(id)
        lanes[id]?.signal.yield(.poke)   // M3.5: a parallel run waits on its lanes: it is told now
        preChecks[id]?.cancel()   // C5c: the pre-check ends at once (its checks are killed)
        landRuns[id]?.cancel()    // C6: so does the land's gate or CI
        if first, (try? await store.get(id))?.loop?.state == .running { await event(id, .stopRequested) }
        if now { forcing.insert(id); return }
        guard first else { return }
        let token = UUID(), grace = stopGrace
        stopTokens[id] = token
        Task { [weak self] in
            await Self.nap(grace)
            await self?.graceOver(id, token)
        }
    }

    /// C5a: the plain stop `token` is still waiting for its verdict: it becomes `--now`.
    private func graceOver(_ id: UUID, _ token: UUID) async {
        guard stopTokens[id] == token, stopping.contains(id), !forcing.contains(id) else { return }
        forcing.insert(id)
        await note(id, tr("[loop] stop forçado depois de \(stopGrace.components.seconds) s", "[loop] forced stop after \(stopGrace.components.seconds) s"))
    }

    /// Runs `work`'s open tasks until all are done/deferred, `max` is used or `stop` is asked. `work.loop` must be set
    /// and `.running`. Returns the final state.
    func run(work id: UUID, dir: URL) async -> WorkLoopState.State {
        var end = WorkLoopState.State.stopped
        var stop: WorkLoopState.Stop?   // why it stopped; nil only when it finished
        let started = host.now()   // A6: the auto-land summary's start
        // F2 X3: a new run starts every task's refusals in a row over (only a refusal written by this run counts)
        // F2 U1: reviewLoopConfigBase, `~/.claude.json` before the run's first judged agent: one base for every attempt
        // F2 V3: the reviewers' folder trusted first, so the write never counts as "changed during the attempt"
        let first = try? await store.get(id)
        let review = first?.loop?.review == true
        let landing = first?.loop?.autoLand != nil   // C2: the end tells the owner even if the registry is unreadable then
        // C5c: the commit the work began on (`work run` gave it, or HEAD now): a land that does not integrate goes back to it
        if landing, first?.loop?.autoLand?.startHead == nil, let head = await out(["rev-parse", "HEAD"], dir) {
            try? await store.update(id) { if $0.loop?.autoLand != nil, $0.loop?.autoLand?.startHead == nil { $0.loop?.autoLand?.startHead = head } }
        }
        if review, let text = await host.trustReviewers() { await note(id, text) }
        let base = review ? await reviewLoopConfigBase() : nil
        try? await store.update(id) { w in
            guard w.loop?.state == .running else { return }
            w.loop?.stopReason = nil
            if let base, w.loop?.reviewConfigBase == nil { w.loop?.reviewConfigBase = base.hash; w.loop?.reviewConfigBaseRisky = base.risky }
            for i in w.tasks.indices where w.tasks[i].reviewRejects != nil { w.tasks[i].reviewRejects = 0 }
        }
        // M3.5: `--parallel N` is a path of its own (`runLanes`); with 1 or none, the loop below, as it always was
        // C5c: the first phase, a check that already passes ends the loop before any attempt
        // C6: the daily cap already spent refuses before any attempt (no agent, no review spent on a land that cannot be)
        var green = landing ? await dailyCapReached(id, first?.loop?.autoLand) : nil
        if green == nil, first?.loop?.greenPreCheck == true { green = await greenPreCheck(id, dir) }
        if let green { stop = green }
        let parallel = green != nil ? 0 : (try? await store.get(id))?.loop?.parallel ?? 1
        if parallel > 1 { (end, stop) = await runLanes(work: id, dir: dir, parallel: parallel) }
        while green == nil, parallel <= 1 {
            if stopping.contains(id) { stop = .init(.requested); break }
            if Task.isCancelled { stop = .init(.cancelled); break }
            // closed, missing or stopped from outside (a daemon restart's sweep): stop
            guard let w = try? await store.get(id), w.closedAt == nil, let loop = w.loop, loop.state == .running else { stop = .init(.workGone); break }
            guard await host.starterAlive() else { stop = .init(.starterGone); break }
            // only the tasks the owner approved: one added since waits for the next run
            guard let task = w.tasks.first(where: { $0.state == .open && (loop.tasks?.contains($0.id) ?? true) }) else { end = .finished; break }
            if let max = loop.max, loop.used >= max { stop = .init(.maxReached); break }
            if let b = loop.budget, (loop.spent ?? 0) >= b {
                await note(id, tr("[loop] orçamento de tempo usado (\(loop.spent ?? 0) de \(b) s); laço parado", "[loop] time budget used (\(loop.spent ?? 0) of \(b) s); loop stopped"))
                stop = .init(.budgetSpent); break
            }
            let t0 = host.now()
            let ended = await attempt(w, loop, task, dir)
            let secs = Int(host.now().timeIntervalSince(t0).rounded(.up))
            try? await store.update(id) { x in let was = x.loop?.spent ?? 0; x.loop?.spent = was + secs }
            if case .stop(let s) = ended { stop = s; break }
        }
        // A4: the run finished with `--auto-land`: the land's conditions, then the land, or a stop of its own
        if end == .finished, !stopping.contains(id), let al = (try? await store.get(id))?.loop?.autoLand { (end, stop) = await autoLand(work: id, al, dir: dir) }
        // C5c: a land that did not integrate leaves no commit of this work on the paddock (`landed`: the next work starts here)
        var discarded: String?
        // C6: a `work stop` (or a cancel) in the land's phase is no land either; one in an attempt's is not (`landPhase`)
        if let s = stop, Self.discards.contains(s.code) || (Self.halts.contains(s.code) && s.detail == Self.landPhase) {
            discarded = await discardLand(id, dir)
        }
        // A5: landed: the chain's next approved work, or why it ends here (a `work stop` meanwhile: `requested`)
        if stop?.code == .landed, let al = (try? await store.get(id))?.loop?.autoLand, let s = await afterLand(id, al) {
            stop = s; end = s.finishes ? .finished : .stopped
        }
        // A6: every `--auto-land` run, whatever stopped it, leaves its summary and tells the owner in one line (A5: a
        // work the chain goes on from tells nothing: the chain's last work tells once)
        await autoLandSummary(work: id, started: started, stop: stop, dir: dir, notify: chainNext[id] == nil, landing: landing, extra: discarded)
        stopping.remove(id); forcing.remove(id); stopTokens[id] = nil
        let now = host.now(), final = end, why = stop
        try? await store.update(id) { w in
            guard w.loop != nil else { return }
            // stopped from outside with its own reason and note (the daemon's sweep): those stay
            let outside = w.loop!.state == .running ? nil : w.loop!.stopReason
            w.loop!.state = final; w.loop!.endedAt = now; w.loop!.task = nil; w.loop!.stopReason = outside ?? why
            // always one summary note, after the path's own longer one (if any)
            if outside == nil, let why {
                w.notes.append(WorkNote(at: now, text: why.note))
                // A5: the `landed` event is recorded by the land itself (the daily cap counts it at once); a chain's end
                // (`queueEmpty`, `maxReached` of the auto-land) is a normal end: no `stopped`
                if !why.finishes { w.record(LoopEvent(at: now, kind: .stopped, detail: Self.eventDetail(why.label))) }
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
            await note(w.id, tr("[loop] git falhou em \(dir.path); laço parado", "[loop] git failed in \(dir.path); loop stopped"))
            return .stop(.init(.gitFailed))
        }
        // tracked changes now are someone else's (each attempt ends on a clean tree): never the loop's to reset
        guard pending.isEmpty else {
            let at = host.now(), text = tr("[loop] arquivos rastreados modificados (dirty) antes da tentativa de \"\(task.title)\", e não são do laço; laço parado, worktree intocada:\n\(pending.prefix(500))",
                                                 "[loop] modified tracked files (dirty) before the attempt of \"\(task.title)\", and they are not the loop's; loop stopped, worktree untouched:\n\(pending.prefix(500))")
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
        // C3b: the base as the agent finds it, the one the land must still see; unread (nil, a throw): the last one stays
        let base = loop.autoLand == nil ? nil : (try? await host.baseHead()) ?? nil
        try? await store.update(w.id) { x in
            if let base { x.loop?.autoLand?.baseHead = base }
            if let i = x.tasks.firstIndex(where: { $0.id == task.id }) {
                x.tasks[i].state = .inProgress; x.tasks[i].updatedAt = started
                x.tasks[i].reviewClean = nil; x.tasks[i].reviewedHead = nil   // A4: only this attempt's own review can make it clean
                x.tasks[i].acceptPassed = nil   // F3: only this attempt's own acceptance can make it pass
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
        // F2 U1: the loop's base (`run`), never one taken here: an attempt's agent may have planted it in the last one.
        // Only a loop that never took one (an engine run outside `run`) takes it here, as before
        if loop.review == true {
            if let hash = loop.reviewConfigBase { run.globalConfig = (hash, loop.reviewConfigBaseRisky ?? "") }
            else { run.globalConfig = await reviewLoopConfigBase() }
        }
        // F2 R4: without `--review` the machine never reaches `reviewing` (the loop as before)
        var (state, todo) = AttemptMachine.reduce(.init(task: task.id, n: n, tries: loop.tries, hasGate: loop.gate != nil, before: before, name: name,
                                                        precheck: loop.precheck != nil, reviewer: loop.review == true,
                                                        reviewRejectsInRow: task.reviewRejects ?? 0, promptRetries: task.promptRetries ?? 0,
                                                        accept: task.accept != nil),
                                                 adopt ? .adopted : .started)
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
            // C5a: a forced stop drops the attempt at its next event, whatever it was (an agent just summoned goes too)
            if forcing.contains(w.id), let h = happened, h != .cancelled {
                if case .summoned(let agent) = h { await host.dismiss(agent) }
                happened = .stopForced(others: await host.othersWorking())
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
            Self.endJob(&x, name, tr("loop: estado inesperado do motor", "loop: unexpected engine state"), at: at)
            Self.forget(&x, task.id)
            if let lane { x.loop?.showLane(lane, nil) } else { x.loop?.show(nil) }
            x.notes.append(WorkNote(at: at, text: tr("[loop] estado inesperado do motor\(what) em \"\(task.title)\": é um bug do laço; tarefa reaberta, tentativa não contada, worktree intocada; laço parado",
                                                    "[loop] unexpected engine state\(what) in \"\(task.title)\": this is a loop bug; task reopened, attempt not counted, worktree untouched; loop stopped")))
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
        /// F2 V1: when the last turn (the attempt's or its nudge's) began, and what the loop saw at its end: how long it
        /// lasted and whether the agent was still working (the `turnEnded` event's detail).
        var turnAt: Date?, looked: (secs: Int, busy: Bool)?
        /// C1 (P2-c): the agent's screen (`screenTail`) when its prompt was not delivered, for the retry's note.
        var lostScreen = ""
        /// The branch and the untracked files (the owner's and the agent's) before the check: what `settle` puts back.
        var on: String, loose: Set<String> = []
        var output = ""
        var checkOutput = ""   // the check's own, kept for the evidence when a gate's output replaces `output`
        /// F3: the acceptance's whole output (`acceptOutput`), once it ran.
        var acceptOutput: String?
        /// F2 X2: the check's and the gate's exit status, the only part of their run the reviewers read.
        var checkStatus: Int32?, gateStatus: Int32?
        /// F2 U1: the loop's `reviewLoopConfigBase` (`--review` only)
        var globalConfig: (hash: String, risky: String)?
        /// When the verdict was reached.
        var at: Date
        var end = AttemptEnd.go
        /// The machine's `fault`, for the safety net's note.
        var fault: String?
        /// `discard` wrote the attempt's patch (nil: nothing was discarded).
        var patched: Bool?
        /// M5.4: the agent's counts, read at the dismiss: the `agentDismissed` event carries them.
        var tokens: TokenCount?
        /// F2 V2 (f2fix9): the agent started open (`startedOpen`), read at the dismiss: what the review's `plantedConfig` goes by.
        var agentOpen = false
        /// The journal's events not yet written, oldest first, and the phase to show (`.some(nil)`: none): `record`.
        var pending: [LoopEvent] = [], phase: WorkLoopState.Phase??
        var unwritten: Bool { !pending.isEmpty || phase != nil || mark != nil }
    }

    /// Effects that may take long: what is pending is written before them.
    private static func waits(_ e: AttemptMachine.Effect) -> Bool {
        switch e {
        case .ask, .waitForCommit, .runCheck, .runGate, .runAccept, .runPrecheck, .runReview: true   // the nudges write by themselves, when they go
        default: false
        }
    }

    /// F2 X3: the least of the budget a review needs (seconds): with less, the attempt ends for want of budget and the
    /// mute reviewers are no refusal.
    static let reviewMinTurn = 20
    static var reviewBudgetNote: String { tr("[loop] orçamento de tempo sem folga para a revisão (menos de \(reviewMinTurn) s): tentativa não contada, nem como recusa", "[loop] time budget has no room for the review (less than \(reviewMinTurn) s): attempt not counted, not even as a refusal") }

    /// M2.2b: the events that carry a verdict's facts out of a long wait: a cancel during it replaces them.
    private static func judges(_ e: AttemptMachine.Event) -> Bool {
        switch e {
        case .checkDone, .gateDone, .acceptDone, .blocked, .reviewDone: true   // F2 X3: a cancelled review's mute reviewers are no refusal
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

    /// C1 (P2-a): the least of the budget (seconds, or the turn's timeout when shorter) a retried prompt needs: with
    /// less, the loop stops on the budget instead of spending its free retries on turns too short to be any.
    static let promptRetryMinTurn = 20

    /// F2 V1: a turn's end before this many seconds, with its agent busy and no commit, leaves a note when no commit comes.
    static let shortTurn = 60

    /// The `discarded` event's detail when no patch was written (the diff failed or was empty).
    static var noPatch: String { tr("sem alterações", "no changes") }

    /// Carries one effect of `AttemptMachine` out, with the host, store and git calls the attempt always made, and
    /// returns the event it observed (nil: the effect answers with none). `state`: the machine's, after it asked.
    private func perform(_ effect: AttemptMachine.Effect, _ state: AttemptMachine.State, _ r: inout Run) async -> AttemptMachine.Event? {
        let id = r.work.id, task = r.task, n = r.n, name = r.name, before = r.before, branch = r.branch, dir = r.dir
        switch effect {
        case .journal(let kind, let detail):
            // the journal: this attempt's events (it records, it never decides)
            // `discarded` names the patch only when one was written
            // `attemptStarted` went with the attempt's first write
            var detail = detail
            // F2 V1: the turn's end says how long it lasted and whether its agent was still working, e.g. `hook 38s ocupado`
            if kind == .turnEnded, let agent = r.agent, let at = r.turnAt {
                let secs = Int(host.now().timeIntervalSince(at).rounded()), busy = await host.working(agent)
                r.looked = (secs, busy)
                detail = "\(detail ?? "") \(secs)s \(busy ? "ocupado" : "ocioso")"
            }
            if kind != .attemptStarted {
                var detail = detail
                if kind == .agentSummoned, let m = r.loop.escalation(attempt: n) { detail = (detail ?? "") + " [\(m.preset):\(m.model)]" }   // C3
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
                let work = r.work, host = host
                var loop = r.loop
                if let e = loop.escalation(attempt: n) { (loop.preset, loop.model, loop.command) = (e.preset, e.model, nil) }   // C3
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
            // C1 (P2-b): from now, not from the attempt's start: a retried attempt's turn is what the budget has left
            r.deadline = host.now() + Double(turn); r.turnAt = host.now()
            var ended = await talk(agent, prompt, .seconds(turn), work: id)
            // M2.0: it only records (the turn's end, good or bad, is journaled right after)
            if await host.resubmitted(agent) { r.pending.append(entry(.resubmitted, task: task.id, attempt: n, detail: name)) }
            // C1 (P2-a/c): the screen before the dismiss, and whether the budget holds a retry after its back-off
            if case .promptNotDelivered(let message, let load, _) = ended {
                r.lostScreen = if let lines = await host.screen(agent) { Self.screenTail(lines, secrets: await host.secrets()) } else { "" }
                let rest = await left(id, r.loop, since: r.started) - Int(promptRetryWait.components.seconds)
                ended = .promptNotDelivered(message, load: load, fits: rest >= Swift.min(r.loop.timeout, Self.promptRetryMinTurn))
            }
            return ended
        case .nudge:
            // not when the turn's time is over, the loop is stopping or the daemon is: straight to the check, as before
            guard let agent = r.agent, let deadline = r.deadline, !Task.isCancelled, !stopping.contains(id) else { return .waitExpired }
            let rest = Int(deadline.timeIntervalSince(host.now()))
            guard rest >= 1 else { return .waitExpired }
            // part of the same attempt (no `used`, no try); written now, with the turn's end: the nudge's turn may be long
            r.pending.append(entry(.nudged, task: task.id, attempt: n, detail: AskResult.Source.hook.rawValue))
            await record(id, &r)
            r.turnAt = host.now()
            return await talk(agent, Self.nudgePrompt, .seconds(rest), work: id)
        case .precheckNudge(let tail):
            // as `nudge`: what is left of the turn, never when the loop or the daemon is stopping
            guard let agent = r.agent, let deadline = r.deadline, !Task.isCancelled, !stopping.contains(id) else { return .waitExpired }
            let rest = Int(deadline.timeIntervalSince(host.now()))
            guard rest >= 1 else { return .waitExpired }
            await record(id, &r)
            return await talk(agent, Self.precheckPrompt(tail), .seconds(rest), work: id)
        case .promptRetry(let used):
            // P2: the task's count, not the attempt's (it crosses attempts); the note is the summary's line of it
            let at = host.now(), text = tr("[loop] \"\(task.title)\", tentativa \(n): prompt não entregue, agente descartado; refeita \(used) sem contar tentativa (agente \(name))",
                                                 "[loop] \"\(task.title)\", attempt \(n): prompt not delivered, agent discarded; redone \(used) without counting an attempt (agent \(name))")
                + (r.lostScreen.isEmpty ? "" : tr("\ntela do agente:\n", "\nagent's screen:\n") + r.lostScreen)
            r.lostScreen = ""
            await record(id, &r) { x in
                if let i = x.tasks.firstIndex(where: { $0.id == task.id }) { x.tasks[i].promptRetries = (x.tasks[i].promptRetries ?? 0) + 1 }
                x.notes.append(WorkNote(at: at, text: text))
            }
            if promptRetryWait > .zero, !Task.isCancelled { await Self.nap(promptRetryWait) }
        case .runPrecheck:
            // a timeout, or a pre-check that could not run, is a failure (status nil): its tail says which
            let limit = Swift.min(Self.precheckTimeout, await left(id, r.loop, since: r.started))
            do {
                let res = try await host.check(r.loop.precheck ?? "false", in: dir, timeout: .seconds(limit))
                return .precheckDone(status: res.status, tail: Self.evidenceTail(check: res.stdout + res.stderr, gate: nil, lines: Self.precheckLines, chars: Self.precheckChars))
            } catch where error.code == .timeout {
                return .precheckDone(status: nil, tail: tr("o pré-check passou de \(limit) s", "the pre-check ran over \(limit) s"))
            } catch { return .precheckDone(status: nil, tail: tr("o pré-check não rodou: \(error.message)", "the pre-check did not run: \(error.message)")) }
        case .waitForCommit, .lookForCommit:
            if effect == .waitForCommit, let agent = r.agent, let deadline = r.deadline {
                await waitForCommit(agent, before: before, branch: branch, dir: dir, until: deadline, work: id)
            }
            // F2 V1: a turn that ended (hook, error) with its agent still working is not over: wait while it works, never
            // past the turn's time (a timeout's is already over) nor while the loop or the daemon is stopping
            let looked = r.looked; r.looked = nil
            if effect == .lookForCommit, looked?.busy == true, let agent = r.agent, let deadline = r.deadline {
                while host.now() < deadline, !Task.isCancelled, !stopping.contains(id), await host.working(agent) { await Self.nap(poll) }
            }
            // for the journal only: the verdict reads the commit again, after the dismiss
            guard await committed(before: before, branch: branch, dir) else {
                if let looked, looked.busy, looked.secs < Self.shortTurn {
                    // P2: what the agent's screen showed, read before the dismiss
                    let screen = if let agent = r.agent, let lines = await host.screen(agent) { Self.screenTail(lines, secrets: await host.secrets()) } else { "" }
                    let at = host.now(), text = tr("[loop] \"\(task.title)\", tentativa \(n): o turno acabou em \(looked.secs) s com o agente ainda ocupado e sem commit, e o commit não veio (agente \(name))",
                                                     "[loop] \"\(task.title)\", attempt \(n): the turn ended after \(looked.secs) s with the agent still busy and no commit, and the commit did not come (agent \(name))")
                        + (screen.isEmpty ? "" : tr("\ntela do agente:\n", "\nagent's screen:\n") + screen)
                    await record(id, &r) { $0.notes.append(WorkNote(at: at, text: text)) }
                }
                return .waitExpired
            }
            return .commitSeen(await out(["rev-parse", "--short", "HEAD"], dir))
        case .dismiss:
            // M5.4: the transcript is read while its terminal still exists (the dismiss forgets it)
            if let agent = r.agent {
                r.tokens = await host.tokens(agent)
                r.agentOpen = await host.startedOpen(agent)   // F2 V2: by id, before the terminal goes
                // F2 Z3b: with --review, nothing of the judged agent is left alive when the reviewers come
                if r.loop.review == true { await host.dismissReaping(agent) } else { await host.dismiss(agent) }
            }
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
            // M13.3: an attempt that changed collie-work.json (committed or left in the tree) is not judged: the file
            // picks the loop's gate and pre-check, so the check does not run and the attempt fails, discarded as any other
            if let why = await configTampered(spec: task.spec, before: before, keep: r.keep, dir) {
                r.output = ""; r.checkOutput = ""
                return .checkDone(status: nil, broken: why)
            }
            do {
                let budgeted = Duration.seconds(await left(id, r.loop, since: r.started))
                let res = try await host.check(task.check ?? "false", in: dir, timeout: Swift.min(checkTimeout, budgeted))
                r.output = res.stdout + res.stderr; r.checkOutput = r.output; r.checkStatus = res.status
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
                r.output = res.stdout + res.stderr; r.gateStatus = res.status
                return .gateDone(status: res.status, broken: nil)
            } catch where error.code == .timeout {
                r.output = ""
                return .gateDone(status: nil, broken: nil)
            } catch {
                r.output = ""
                return .gateDone(status: nil, broken: "gate could not run: \(error.message)")
            }
        case .guardAccept:
            // F3: the agent may not rewrite what judges its result, as for the gate
            guard let accept = task.accept, let why = await tampered(accept, spec: task.spec, before: before, judged: state.judged, dir, by: tr("o aceite", "the acceptance"), refuseNew: true) else { return .acceptClear }
            await record(id, &r) { x in
                if let i = x.tasks.firstIndex(where: { $0.id == task.id }) { x.tasks[i].acceptPassed = false; x.tasks[i].acceptResult = tr("não rodou: ", "did not run: ") + why }
            }
            return .acceptSkipped(why)
        case .runAccept:
            // F3: the command from the work's state (`task`, read before the attempt), never from the tree; the check's
            // conditions (worktree, sandbox, budget), its own timeout
            let budgeted = Duration.seconds(await left(id, r.loop, since: r.started))
            let limit = Duration.seconds(Swift.min(task.acceptTimeout ?? WorkTask.acceptTimeoutDefault, WorkTask.acceptTimeoutMax))
            let ran: AttemptMachine.Event, line: String
            var passed = false   // from the exit status, never from the (translated) line
            do {
                let res = try await host.check(task.accept ?? "false", in: dir, timeout: Swift.min(checkTimeout, budgeted, limit))
                r.acceptOutput = Self.acceptOutput(res.stdout + res.stderr, secrets: await host.secrets())
                ran = .acceptDone(status: res.status, broken: nil); passed = res.status == 0; line = res.status == 0 ? tr("passou (exit 0)", "passed (exit 0)") : tr("falhou (exit \(res.status))", "failed (exit \(res.status))")
            } catch where error.code == .timeout {
                r.acceptOutput = ""
                ran = .acceptDone(status: nil, broken: nil); line = tr("falhou (timeout)", "failed (timeout)")
            } catch {
                r.acceptOutput = ""
                ran = .acceptDone(status: nil, broken: "accept could not run: \(error.message)"); line = tr("não rodou: \(error.message)", "did not run: \(error.message)")
            }
            r.output = r.acceptOutput ?? ""
            let ok = passed, said = LotBoards.scrub(String(line.prefix(200)))
            await record(id, &r) { x in
                if let i = x.tasks.firstIndex(where: { $0.id == task.id }) { x.tasks[i].acceptPassed = ok; x.tasks[i].acceptResult = said }
            }
            return ran
        case .runReview:
            // F2 X3: too little budget for a reviewer to answer: every persona would be mute, a refusal that is not one
            let rest = await left(id, r.loop, since: r.started)
            if rest < Self.reviewMinTurn { return .reviewBudgetOut }
            // F2 R4: the personas judge `judged` against `before`, every reviewer gone before this returns
            let evidence = await reviewEvidence(before: before, judged: state.judged, check: r.checkStatus, gate: r.loop.gate == nil ? nil : .some(r.gateStatus), dir)
            let tree = await reviewTree(dir)
            let configs = Self.reviewHashAgentConfig(dir, status: tree)
            // F2 V2: the home's `~/.claude.json` as the reviewers are launched: changed since the start, all mute
            let home = await host.globalConfigHome()
            let globalLaunch = Self.reviewGlobalConfigHash(home: home, reviewRoot: host.reviewRoot)
            // F2 U1: an `env` or `autoConnectIde` the loop's base did not hold exactly mutes first, then any other change
            let risky = Self.reviewGlobalConfigRisky(home: home)
            let configSilenced = !risky.isEmpty && risky != r.globalConfig?.risky ? Self.reviewGlobalConfigRiskyNote
                : r.globalConfig?.hash != globalLaunch ? Self.reviewGlobalConfigMoved : nil
            var ran = await review(work: r.work, loop: r.loop, task: task, n: n, agent: name, before: before, judged: state.judged,
                                   evidence: evidence, configSilenced: configSilenced, agentOpen: r.agentOpen, turn: { [loop = r.loop, started = r.started] in Swift.min(loop.timeout, await self.left(id, loop, since: started)) }, dir)
            if ran.budgetOut { return .reviewBudgetOut }
            r.pending += ran.events   // P1: the mute causes and the retry, written with the review's own record
            // F2 X1: every reviewer is gone; the tree must be exactly what was judged, or nothing it said counts
            let after = await reviewTree(dir)
            // F2 Z3b: and the agent configs by their metadata (a file inside an ignored folder the status shows as one line)
            let configsAfter = Self.reviewHashAgentConfig(dir, status: tree)
            // F2 W3: another terminal reaching this worktree (the Shepherd's Claude Code, the user) may have written that
            // config itself during the review: then the change is no touch, and what is new is moved, never deleted
            let configChanged = configsAfter != configs
            // F2 V2: changed during the review: nothing the reviewers said counts
            let globalTouched = Self.reviewGlobalConfigHash(home: home, reviewRoot: host.reviewRoot) != globalLaunch
            let reviewConfigOthers = configChanged ? await host.othersWorking() : nil
            // A1 (reviewAdvisory): only a tree really changed fails the attempt (tampering); `~/.claude.json` changed alone
            // leaves the tree as judged: no opinion ('sem parecer'), the check and the gate decide
            let touched = tree == nil || after != tree || after?.hasPrefix(state.judged + "\n") != true || (configChanged && reviewConfigOthers == nil)
            let made = configsAfter.keys.filter { configs[$0] == nil }.sorted()
            var movedSaid = ""
            if let who = reviewConfigOthers, case let tops = made.filter({ p in !made.contains { p.hasPrefix($0 + "/") } }), !tops.isEmpty {
                let folder = host.patchDir(id).appendingPathComponent("\(task.id)-\(n)-config")
                let linked = tops.filter { Self.reviewPathLinked(dir, $0) }   // F2 V3: never through a swapped parent
                let moved = tops.filter { p in
                    guard !linked.contains(p) else { return false }
                    let to = folder.appendingPathComponent(p)
                    try? FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    return (try? FileManager.default.moveItem(atPath: dir.path + "/" + p, toPath: to.path)) != nil
                }
                movedSaid = String(("\nconfig nova com '\(who)' na worktree, movida para \(folder.path): " + moved.joined(separator: ", ")
                    + (linked.isEmpty ? "" : "\n\(Self.reviewPathLinkedNote): " + linked.joined(separator: ", "))).prefix(400))
            }
            if touched {
                _ = await settle(state.judged, on: r.on, loose: r.loose, reset: true, dir)
                // F2 Z3b: a config made inside such a folder goes too (an edited one cannot be put back: the touch says it)
                // F2 V3: a parent swapped for a symlink: nothing removed through it, the note says which
                let linked = reviewConfigOthers == nil ? made.filter { Self.reviewPathLinked(dir, $0) } : []
                if reviewConfigOthers == nil { for p in made where !linked.contains(p) { try? FileManager.default.removeItem(atPath: dir.path + "/" + p) } }
                // F2 Y2b: an ignored file the reviewer left (`.claude/settings.local.json`) survives `settle`: it goes too.
                // F2 Z3a: only an agent's config: any other new ignored path (`.env`) may be the Shepherd's or the user's
                var said = (globalTouched ? "\n" + Self.reviewGlobalConfigTouched : "")
                    + (linked.isEmpty ? "" : String("\n\(Self.reviewPathLinkedNote): \(linked.joined(separator: ", "))".prefix(400)))
                if tree != nil, case let fresh = Self.ignored(after).subtracting(Self.ignored(tree)), !fresh.isEmpty {
                    let (drop, keep) = Self.reviewerLeftovers(fresh)
                    if !drop.isEmpty { _ = try? await host.git(["--literal-pathspecs", "clean", "-q", "-f", "-d", "-X", "--"] + drop, in: dir) }
                    said += String(((drop.isEmpty ? "" : tr("\napagados (config de agente): ", "\ndeleted (agent config): ") + drop.joined(separator: ", "))
                        + (keep.isEmpty ? "" : tr("\nmantidos (ignorados novos, de quem não se sabe): ", "\nkept (new ignored files, owner unknown): ") + keep.joined(separator: ", "))).prefix(400))
                }
                ran.outcome = .init(approved: false, reason: Self.reviewerTouched, notes: [])
                ran.line = ReviewVerdict.reviewLabel + tr("falhou (\(Self.reviewerTouched))", "failed (\(Self.reviewerTouched))")
                ran.note = String(ran.note.prefix(Self.noteChars - 64 - said.count)) + "\n" + Self.reviewerTouched + said
            } else if globalTouched, !ran.outcome.approved {
                // F2 reviewVetoKept: a veto from a possibly tampered context can only fail more (the safe side): it stays,
                // the config note joins it; only a non-veto goes mute
                ran.note = String(ran.note.prefix(Self.noteChars - 128)) + "\n" + Self.reviewGlobalConfigTouched
            } else if globalTouched {
                ran.outcome = ReviewVerdict.silent(Self.reviewGlobalConfigTouched)
                ran.line = Self.reviewAdvisoryLine(ran.outcome, Self.reviewGlobalConfigTouched)
                ran.note = String(ran.note.prefix(Self.noteChars - 128)) + "\n" + ran.outcome.notes.joined(separator: "; ")
            }
            if !movedSaid.isEmpty { ran.note = String(ran.note.prefix(Self.noteChars - movedSaid.count)) + movedSaid }
            // F2 X3: cancelled mid-review, the reviewers went mute: nothing they said is written (`attempt` leaves with `cancelled`)
            if Task.isCancelled { return .cancelled }
            let at = host.now(), line = ran.line, approved = ran.outcome.approved, note = ran.note
            // C3a: the HEAD the review judged (the tree is as judged when not touched), recorded with its approval
            let judgedHead = touched ? nil : await out(["rev-parse", "HEAD"], dir)
            // A4: clean only with every persona answering, none mute or invalid, no veto, the tree as judged
            let clean = !touched && approved && ran.outcome.silent == nil && !ran.outcome.notes.contains(where: ReviewVerdict.isNoOpinion)
            await record(id, &r) { x in
                if let i = x.tasks.firstIndex(where: { $0.id == task.id }) {
                    x.tasks[i].review = line; x.tasks[i].reviewClean = clean ? true : nil; x.tasks[i].reviewedHead = clean ? judgedHead : nil
                    // F2 Y2a: a touched tree was not judged: no refusal to count
                    if !touched { x.tasks[i].reviewRejects = approved ? 0 : (x.tasks[i].reviewRejects ?? 0) + 1 }
                }
                x.notes.append(WorkNote(at: at, text: note))
            }
            return touched ? .reviewerTouched : .reviewDone(ran.outcome)
        case .decide:
            return .decided(AttemptDecision.decide(state.facts))
        case .discard:
            r.patched = await discard(id, task.id, n, before: before, branch: branch, keep: r.keep, dir)
        case .adoptionFailed(let reason):
            let at = r.at, text = LotBoards.scrub(tr("[loop] adoção de \"\(task.title)\" falhou: \(reason); nada foi apagado", "[loop] adoption of \"\(task.title)\" failed: \(reason); nothing was deleted"))
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
            evidence.acceptOutput = task.accept == nil ? nil : r.acceptOutput
            // the declared files, from the tree as the verdict left it: `judged`, what the agent left untracked and
            // what is ignored (an untracked file the check or the gate made is already gone)
            if let g = task.evidenceGlob {
                let c = await host.copyEvidence(g, from: dir, work: id, task: task.id)
                evidence.files = c.files; evidence.filesDir = c.dir
                if let n = c.note { await note(id, tr("[loop] evidência de \"\(task.title)\": \(n)", "[loop] evidence of \"\(task.title)\": \(n)")) }
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
            let at = r.at, refused = state.facts.review
            let tail = r.output.split(separator: "\n", omittingEmptySubsequences: false).suffix(Self.noteLines).joined(separator: "\n")
            // the next attempt's prompt carries it: secrets hidden (LotBoards.scrub's known shapes). ponytail: tail capped at 4000 chars
            // M3.8: and which agent it was (its terminal's name)
            // F3: a failed acceptance that ran leaves its WHOLE output (already scrubbed and bounded); C4a: in the
            // evidence (a file), the note only its head and tail (`acceptNote`): the notes go back into the next prompt
            var whole = state.facts.accept != nil ? r.acceptOutput : nil
            if let all = whole, !all.isEmpty {
                whole = Self.acceptNote(all, file: Self.keepAcceptOutput(all, dir: host.patchDir(id), task: task.id, attempt: n))
            }
            let text = LotBoards.scrub(tr("[loop \(task.id)] \(task.title), tentativa \(n)/\(r.loop.tries): \(reason) (agente \(name))", "[loop \(task.id)] \(task.title), attempt \(n)/\(r.loop.tries): \(reason) (agent \(name))")
                + (whole.map { $0.isEmpty ? "" : Self.acceptMark + $0 } ?? (tail.isEmpty ? "" : "\n" + String(tail.suffix(Self.noteChars)))))
            await record(id, &r) { x in
                if let i = x.tasks.firstIndex(where: { $0.id == task.id }), x.tasks[i].state == .inProgress {
                    x.tasks[i].tries = n; x.tasks[i].lastFailure = reason; x.tasks[i].updatedAt = at
                    if last { x.tasks[i].state = .deferred; x.tasks[i].reason = "loop: \(reason)" } else { x.tasks[i].state = .open }
                    // F2 X3: "in a row" = review refusals on consecutive attempts with no attempt of another kind between:
                    // a failure before the review (summon, commit, check, gate) or a deferral starts the count over
                    if x.tasks[i].reviewRejects != nil, last || refused == nil { x.tasks[i].reviewRejects = 0 }
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
        while who != nil, ContinuousClock.now < end, !Task.isCancelled, forcing.isEmpty {
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
        tr("[loop] '\(who)' está trabalhando no cercado: o laço não reseta a worktree com outro agente nela; laço parado, worktree intocada",
           "[loop] '\(who)' is working in the paddock: the loop does not reset the worktree with another agent in it; loop stopped, worktree untouched")
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
    private func waitForCommit(_ agent: UUID, before: String, branch: String, dir: URL, until deadline: Date, work id: UUID) async {
        if await committed(before: before, branch: branch, dir) { return }
        while host.now() < deadline, !Task.isCancelled, !forcing.contains(id) {
            if !(await host.working(agent)), await committed(before: before, branch: branch, dir) { return }
            await Self.nap(poll)
        }
    }

    /// The loop's one wait on the clock: its polls (a commit, another terminal, the agent's screen) have no event.
    static func nap(_ d: Duration) async { try? await Task.sleep(for: d) }   // F3: the field land's wait too

    /// `host.ask` as the machine's event. M5.3: every `poll` meanwhile the agent's screen is read; one stuck in the
    /// usage-limit dialog ends the turn now (the ask is dropped, nothing is typed) instead of at its timeout.
    /// C5a: a forced stop of `id` ends the turn too (the attempt's interpreter turns it into `stopForced`).
    private func talk(_ agent: UUID, _ prompt: String, _ timeout: Duration, work id: UUID) async -> AttemptMachine.Event {
        let host = host, poll = poll
        if forcing.contains(id) { return .turnFailed(tr("stop forçado", "forced stop")) }
        return await withTaskGroup(of: AttemptMachine.Event?.self) { g in
            g.addTask { [weak self] in
                while !Task.isCancelled {
                    await Self.nap(Swift.min(poll, .seconds(1)))
                    if await self?.forcing.contains(id) ?? true { return .turnFailed(tr("stop forçado", "forced stop")) }
                }
                return nil
            }
            g.addTask {
                do throws(ProtocolError) { return .turnEnded(source: try await host.ask(agent, prompt: prompt, timeout: timeout)) }
                // P2/P3: never reached the agent (a timeout before it, or an Enter that never took) / its reply timed out after it did
                catch where AskCoordinator.promptNotDelivered(error) { return .promptNotDelivered(error.message, load: Self.loadAverage()) }
                catch where error.code == .timeout { return .turnTimedOut(error.message) }
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

    /// P2: the one-minute load average (0 when it cannot be read).
    static func loadAverage() -> Double {
        var l = [0.0]
        return getloadavg(&l, 1) == 1 ? l[0] : 0
    }

    /// P2: the end of an agent's screen for a note: its last `screenLines` lines, clean (as an event's detail, secrets
    /// hidden), at most `screenChars` characters. C1 (P2-d): `secrets` (the host's live ones) hidden too, and every
    /// line starts with `screenMark`, so none reads as a `[collie]` line to the Shepherd (the mark adds 2 per line to the cap).
    static let screenLines = 20, screenChars = 800, screenMark = "│ "
    static func screenTail(_ lines: [String], secrets: Set<String> = []) -> String {
        let clean = lines.suffix(screenLines).map { LotBoards.scrub(RerailText.plain(ANSI.strip($0)), secrets: secrets).trimmingCharacters(in: .whitespaces) }
        let text = String(clean.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).suffix(screenChars))
        return text.isEmpty ? "" : text.split(separator: "\n", omittingEmptySubsequences: false).map { screenMark + $0 }.joined(separator: "\n")
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
    /// F3: the task's acceptance is guarded the same way (`by`: what runs the file, for the reason). C4a: `refuseNew`
    /// (the acceptance): a file its text names that the attempt created (not in `before`) fails it too, whatever the
    /// spec says: the agent would write the script that judges it.
    private func tampered(_ gate: String, spec: String?, before: String, judged: String, _ dir: URL, by: String? = nil, refuseNew: Bool = false) async -> String? {
        let by = by ?? tr("o portão", "the gate")
        let named = await specText(spec, at: before, dir)
        // M7.2 (A5): `-z`, read untrimmed: a name with a newline or a space at an end is that name
        guard let d = try? await host.git(["diff", "--name-only", "-z", "--no-renames", before, judged], in: dir), d.status == 0 else {
            return "gate did not run (could not list what the attempt changed)"
        }
        for path in d.stdout.split(separator: "\0").map(String.init) where gate.contains(path) {
            let existed = (try? await host.git(["cat-file", "-e", "\(before):\(path)"], in: dir))?.status == 0
            // a created file only when named whole (`judgedPaths`): `curl …/health` is no file `health`
            if refuseNew && !existed && Self.judgedPaths(gate, dir).contains(Self.normalPath(path, dir)) {
                return tr("\(by) cita «\(path)» que não existe no commit base: crie-o numa tarefa anterior e commite", "\(by) names «\(path)» which does not exist at the base commit: create it in an earlier task and commit")
            }
            if existed && !named.contains(path) { return tr("a tentativa alterou «\(path)», que \(by) executa", "the attempt changed «\(path)», which \(by) runs") }
        }
        return nil
    }

    /// The spec's text at `before`; empty: no spec, outside the repo or not committed there.
    func specText(_ spec: String?, at before: String, _ dir: URL) async -> String {
        guard let spec else { return "" }
        let rel = Self.repoRelative(spec, dir)
        guard !rel.hasPrefix("/"), !rel.contains(".."), let r = try? await host.git(["show", "\(before):\(rel)"], in: dir), r.status == 0 else { return "" }
        return r.stdout
    }

    /// A spec's path as the repo knows it: relative to `dir` when under it, else as given.
    static func repoRelative(_ spec: String, _ dir: URL) -> String {
        spec.hasPrefix(dir.path + "/") ? String(spec.dropFirst(dir.path.count + 1)) : spec
    }

    static var configTampered: String { tr("alterou \(ProjectWorkConfig.fileName)", "changed \(ProjectWorkConfig.fileName)") }

    /// M13.3: the attempt changed `collie-work.json` from `before` to what it left (its commits and its tree: edited,
    /// deleted, or created untracked; an untracked one that was there before the attempt, `keep`, is the owner's).
    /// A spec that names the file at `before` lets the task change it, as `tampered` does for the gate's scripts. A git
    /// that cannot answer fails the attempt too: the check never runs on a tree it could not look at.
    private func configTampered(spec: String?, before: String, keep: [String], _ dir: URL) async -> String? {
        let name = ProjectWorkConfig.fileName
        guard !(await specText(spec, at: before, dir)).contains(name) else { return nil }
        guard let d = try? await host.git(["--literal-pathspecs", "diff", "--name-only", "-z", "--no-renames", before, "--", name], in: dir), d.status == 0,
              let u = try? await host.git(["--literal-pathspecs", "ls-files", "-z", "--others", "--exclude-standard", "--", name], in: dir), u.status == 0 else {
            return Self.configTampered + tr(" (não foi possível ver o que a tentativa mudou)", " (could not see what the attempt changed)")
        }
        let changed = !d.stdout.isEmpty || u.stdout.split(separator: "\0").contains { !keep.contains(String($0)) }
        return changed ? Self.configTampered : nil
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

    /// Untracked files that are not ignored. M9.2 (B3): raw `stdout`, never `out()`: its trim would cut a space or a
    /// newline off the first and the last name, and `discard` would then lose that owner's file.
    private func untracked(_ dir: URL) async -> [String] {
        guard let r = try? await host.git(["ls-files", "-z", "--others", "--exclude-standard"], in: dir), r.status == 0 else { return [] }
        return r.stdout.split(separator: "\0").map(String.init)
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

    static var reviewerTouched: String { tr("o revisor mexeu na árvore", "the reviewer touched the tree") }

    /// F2 X1: HEAD and the porcelain status with its branch line, before and after the review (nil: git could not say).
    /// F2 Y2b: ignored files too (`--ignored=matching`), NUL-separated (`-z`, names unquoted): a reviewer's
    /// `CLAUDE.local.md` is a touch.
    func reviewTree(_ dir: URL) async -> String? {
        guard let head = await out(["rev-parse", "HEAD"], dir),
              let st = await out(["status", "--porcelain", "-z", "-b", "--ignored=matching"], dir) else { return nil }
        return head + "\n" + st
    }

    /// The ignored paths (`!! `) of a `reviewTree`.
    static func ignored(_ tree: String?) -> Set<String> {
        Set((tree ?? "").split(separator: "\0").filter { $0.hasPrefix("!! ") }.map { String($0.dropFirst(3)) })
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
    static func evidenceTail(check: String, gate: String?, lines: Int = evidenceLines, chars: Int = evidenceChars) -> String {
        let tails = [check, gate ?? ""].map {
            ANSI.strip($0).trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false)
                .suffix(lines).map { RerailText.plain(String($0)) }.joined(separator: "\n")
        }.filter { !$0.isEmpty }
        return String(LotBoards.scrub(tails.joined(separator: "\n")).suffix(chars))
    }

    /// F3: the acceptance's output as the evidence and the note keep it: ANSI gone, secrets hidden (the known shapes and
    /// the daemon's live ones), at most `acceptChars`; past it the head and the tail, with how much was cut between them.
    static let acceptChars = 64 * 1024
    static func acceptOutput(_ raw: String, secrets: Set<String> = []) -> String {
        let clean = LotBoards.scrub(ANSI.strip(raw), secrets: secrets).trimmingCharacters(in: .newlines)
        guard clean.utf8.count > acceptChars else { return clean }
        let half = acceptChars / 2 - 64
        // a cut inside a multi-byte character decodes as U+FFFD: dropped
        let head = String(decoding: Array(clean.utf8.prefix(half)), as: UTF8.self).trimmingCharacters(in: ["\u{FFFD}"])
        let tail = String(decoding: Array(clean.utf8.suffix(half)), as: UTF8.self).trimmingCharacters(in: ["\u{FFFD}"])
        return head + tr("\n… (\(clean.utf8.count - 2 * half) bytes cortados no meio) …\n", "\n… (\(clean.utf8.count - 2 * half) bytes cut in the middle) …\n") + tail
    }

    /// C4a: what a note of a failed acceptance keeps (`acceptNoteChars`, head and tail) and what the next attempt's prompt
    /// carries of all of them together (`acceptPromptChars`); the whole output goes to a file (`keepAcceptOutput`).
    static var acceptMark: String { tr("\nsaída do aceite:\n", "\nacceptance output:\n") }
    /// A note outlives a language switch: `promptNotes` finds the mark in either.
    static let acceptMarks = ["\nsaída do aceite:\n", "\nacceptance output:\n"]
    static let acceptNoteChars = 3000, acceptPromptChars = 4000

    /// C4a: `out` whole in `<patchDir>/accept-output/<task>-<attempt>.txt` (0600); nil: it could not be written.
    static func keepAcceptOutput(_ out: String, dir: URL, task: String, attempt: Int) -> String? {
        let folder = dir.appendingPathComponent("accept-output")
        let url = folder.appendingPathComponent("\(EvidenceFiles.dir(dir, task: task).lastPathComponent)-\(attempt).txt")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(out.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url.path
        } catch { return nil }
    }

    /// C4a: the acceptance's output as a note keeps it: whole up to `acceptNoteChars`, else its head and its tail (half
    /// each) and where the whole is.
    static func acceptNote(_ out: String, file: String?) -> String {
        guard out.count > acceptNoteChars else { return out }
        let half = acceptNoteChars / 2
        return String(out.prefix(half)) + tr("\n… (\(out.count - 2 * half) caracteres cortados; saída inteira em \(file ?? "nenhum arquivo: a gravação falhou")) …\n", "\n… (\(out.count - 2 * half) characters cut; whole output in \(file ?? "no file: the write failed")) …\n") + String(out.suffix(half))
    }

    /// C4a: the notes as the prompt carries them: the acceptances' outputs, newest first, at most `acceptPromptChars` in
    /// all (an older one past it keeps only its tail that fits, or a line saying it was left out).
    static func promptNotes(_ notes: [WorkNote]) -> [String] {
        var left = acceptPromptChars
        return notes.reversed().map { n -> String in
            guard let r = acceptMarks.lazy.compactMap({ n.text.range(of: $0) }).first else { return n.text }
            let out = n.text[r.upperBound...]
            let kept = out.count <= left ? String(out) : left > 2 ? "… " + String(out.suffix(left - 2)) : tr("(omitida: o limite das notas de aceite no prompt foi atingido)", "(left out: the limit of acceptance notes in the prompt was reached)")
            left = Swift.max(0, left - out.count)
            return String(n.text[..<r.upperBound]) + kept
        }.reversed()
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

    /// M10.2: the turn's rules, fixed lines of every attempt's prompt.
    static var turnRule: String { tr("Rode build e testes em primeiro plano; não encerre o turno com comando em segundo plano nem monitor pendente.", "Run builds and tests in the foreground; do not end the turn with a command in the background or a pending monitor.") }
    static var buildRule: String { tr("`swift build` não compila os testes: use `swift build --build-tests` ou `swift test --filter`.", "`swift build` does not compile the tests: use `swift build --build-tests` or `swift test --filter`.") }

    /// The attempt's prompt, in the owner's language.
    static func prompt(task: WorkTask, spec: String?, attempt: Int, tries: Int, dir: URL, notes: [WorkNote], gate: String? = nil, map: String? = nil) -> String {
        var lines = [
            tr("Tarefa \"\(task.title)\", tentativa \(attempt) de \(tries), num laço autônomo: ninguém vai responder perguntas, então decida e registre a decisão no commit.",
               "Task \"\(task.title)\", attempt \(attempt) of \(tries), in an autonomous loop: nobody will answer questions, so decide and record the decision in the commit."),
            tr("Trabalhe só em \(dir.path). Faça só esta tarefa. Não faça push nem land.", "Work only in \(dir.path). Do only this task. Do not push or land."),
            tr("Faça commit assim que código e testes estiverem escritos, ANTES de rodar build ou teste: sem commit novo a tarefa não conta. Se depois corrigir algo, faça outro commit. Não deixe arquivo modificado sem commit.",
               "Commit as soon as code and tests are written, BEFORE running a build or a test: without a new commit the task does not count. If you fix something afterwards, make another commit. Do not leave a modified file uncommitted."),
            turnRule, buildRule,
            tr("Depois do seu turno, o laço roda este comando em \(dir.path) e só ele decide se a tarefa passou:",
               "After your turn, the loop runs this command in \(dir.path) and only it decides whether the task passed:"),
            task.check ?? "",
        ]
        if let gate { lines += [tr("e depois este portão:", "and then this gate:"), gate] }
        if let map { lines.append(tr("O mapa de funcionalidades do projeto está em \(map): use os nomes dele.", "The project's feature map is at \(map): use its names.")) }
        if !notes.isEmpty { lines.append(tr("O que falhou nas tentativas anteriores:", "What failed in the previous attempts:")); lines += promptNotes(notes) }
        lines.append("")
        lines.append(spec ?? task.title)
        return lines.joined(separator: "\n")
    }
}

/// A4, `work run --auto-land`: once every task is done, the land's conditions in order, stopping at the first that fails:
/// the paddock still a factory's, the gate of the profile committed at the base green on the paddock's HEAD, the last
/// attempt of every task reviewed clean, the local CI green, a clean tree with no other agent busy and HEAD where the
/// gate and the CI judged it, then `paddock land` (merge only) by the command's own path. Fail closed: each failure stops
/// the loop with its own code and lands nothing; A6: the run's end calls the owner once (`autoLandSummary`).
extension WorkLoop {
    static let autoLandHint = "collie work status"

    func autoLand(work id: UUID, _ al: WorkLoopState.AutoLand, dir: URL) async -> (WorkLoopState.State, WorkLoopState.Stop?) {
        guard let w = try? await store.get(id) else { return (.stopped, .init(.workGone)) }
        // C2: only `.done` counts: a task dropped (`abandoned`) is work not done, and lands nothing either
        // C5a: a stop of its own (`landTasksNotDone`, the tasks named), never a finish: nothing was integrated
        let left = w.tasks.filter { $0.state != .done }
        guard left.isEmpty else {
            await note(id, tr("[loop] auto-land: \(left.count) tarefa(s) não terminaram feitas; nada integrado", "[loop] auto-land: \(left.count) task(s) did not end done; nothing landed"))
            return (.stopped, .init(.landTasksNotDone, detail: Self.eventDetail(left.map(\.title).joined(separator: ", "))))
        }
        let stop = await landConditions(id, w, al, dir)
        await phase(id, nil)
        guard let stop else { return (.finished, nil) }
        return (stop.code == .landed ? .finished : .stopped, stop)
    }

    private func phase(_ id: UUID, _ p: WorkLoopState.Phase?) async {
        let at = host.now()
        try? await store.update(id) { $0.loop?.show(p, at: at) }
    }

    /// The first condition that fails, or the land's own `landed` (nil: never; a land always says how it went).
    private func landConditions(_ id: UUID, _ w: Work, _ al: WorkLoopState.AutoLand, _ dir: URL) async -> WorkLoopState.Stop? {
        // C6: journaled (started / finished, with exit and duration) and cancelled by `work stop` at once
        func run(_ command: String, _ timeout: Duration, _ kinds: (LoopEvent.Kind, LoopEvent.Kind)) async -> String? {
            let t0 = host.now(), started = entry(kinds.0)
            try? await store.update(id) { $0.record(started) }
            let host = self.host
            let job = Task { await BoundedProcess.$killOnCancel.withValue(true) { () async -> Result<ProcessResult, ProtocolError> in
                do throws(ProtocolError) { return .success(try await host.check(command, in: dir, timeout: timeout)) } catch { return .failure(error) }
            } }
            landRuns[id] = job
            if stopping.contains(id) { job.cancel() }
            let result = await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
            landRuns[id] = nil
            let secs = tr("em \(Int(host.now().timeIntervalSince(t0).rounded())) s", "in \(Int(host.now().timeIntervalSince(t0).rounded())) s")
            let why: String?, short: String
            switch result {
            case .success(let r) where r.status == 0: why = nil; short = "exit 0 \(secs)"
            case .success(let r):
                let tail = (r.stdout + r.stderr).split(separator: "\n").suffix(20).joined(separator: "\n")
                why = "exit \(r.status)" + (tail.isEmpty ? "" : ":\n" + tail); short = "exit \(r.status) \(secs)"
            case .failure(let e) where e.code == .timeout: why = "timeout"; short = "timeout \(secs)"
            case .failure(let e): why = tr("não rodou: \(e.message)", "did not run: \(e.message)"); short = tr("não rodou", "did not run")
            }
            let finished = entry(kinds.1, detail: short)
            try? await store.update(id) { $0.record(finished) }
            return why
        }
        // C6: a `work stop` or a cancel during the land wins over what the cancelled command said (`landPhase`: discarded)
        func halted() -> WorkLoopState.Stop? {
            stopping.contains(id) ? .init(.requested, detail: Self.landPhase) : Task.isCancelled ? .init(.cancelled, detail: Self.landPhase) : nil
        }
        func failed(_ code: WorkLoopState.Stop.Code, _ what: String, _ why: String) async -> WorkLoopState.Stop {
            await note(id, LotBoards.scrub(String(tr("[loop] auto-land: \(what) (\(why)); nada integrado", "[loop] auto-land: \(what) (\(why)); nothing landed").prefix(Self.noteChars))))
            return .init(code, detail: Self.eventDetail(why))
        }
        guard await host.factoryPaddock() else { return .init(.landNotFactory) }
        // A5: the paddock's daily cap, before any land (the first of a run too)
        if let cap = await dailyCapReached(id, al) { return cap }
        guard let head = await out(["rev-parse", "HEAD"], dir) else { return await failed(.gitFailed, tr("git falhou", "git failed"), "rev-parse HEAD") }
        // C3b: the base must be the one the last attempt began on (a host with no base, the tests' fakes: none to check)
        let base: String?
        do { base = try await host.baseHead() } catch { return await failed(.gitFailed, tr("git falhou", "git failed"), tr("a base: \(error.message)", "the base: \(error.message)")) }
        if base != nil, let why = await baseMoved(from: al.baseHead, dir) { return await failed(.landBaseMoved, tr("a base mudou", "the base moved"), why) }
        // C3b: the gate and the CI run from the agent's tree: the files that judge the land must be the base's
        // C4a: fail closed: a base known at the attempt (`al.baseHead`) but unread now, or the other way, is no comparison.
        // Only a host that never knew a base (a folder paddock, the tests' fakes) has nothing to compare.
        switch (base, al.baseHead) {
        case (nil, nil): break
        case (let base?, _?):
            if let why = await judgesChanged(al, base: base, head: head, dir) { return await failed(.landGateRed, tr("portão não rodou", "gate did not run"), why) }
        default: return await failed(.landGateRed, tr("portão não rodou", "gate did not run"), tr("não consegui comparar o que julga o land com a base", "could not compare what judges the land with the base"))
        }
        await phase(id, .gate)
        let gate = await run(al.gate, checkTimeout, (.landGateStarted, .landGateFinished))
        if let h = halted() { return h }
        if let why = gate { return await failed(.landGateRed, tr("portão vermelho no HEAD \(head.prefix(12))", "gate red at HEAD \(head.prefix(12))"), why) }
        // parecer mudo/inválido or a task with no review in its last attempt is no approval
        if let t = w.tasks.first(where: { $0.state == .done && $0.reviewClean != true }) {
            return await failed(.landReviewVeto, tr("revisão sem aprovação limpa", "review without a clean approval"), RerailText.clean(t.title, max: 80) + ": " + (t.review ?? tr("sem revisão", "no review")))
        }
        if let why = await reviewedHeadVeto(w, head: head, dir) { return await failed(.landReviewVeto, tr("commits depois da revisão", "commits after the review"), why) }
        // F3: the 4th condition, only when a task of the work has `--accept`: its last acceptance passed (in the attempt
        // that made it done: each attempt clears it first)
        if let t = w.tasks.first(where: { $0.state == .done && $0.accept != nil && $0.acceptPassed != true }) {
            return await failed(.landAcceptRed, tr("aceite em runtime sem passar", "runtime acceptance not passing"), RerailText.clean(t.title, max: 80) + ": " + (t.acceptResult ?? tr("não rodou", "did not run")))
        }
        await phase(id, .check)
        let ci = await run(al.ci, .seconds(al.timeout), (.landCiStarted, .landCiFinished))
        if let h = halted() { return h }
        if let why = ci { return await failed(.landCiRed, tr("CI local vermelho", "local CI red"), why) }
        await phase(id, nil)
        guard let status = await out(["status", "--porcelain"], dir) else { return await failed(.gitFailed, tr("git falhou", "git failed"), "status") }
        if !status.isEmpty { return await failed(.landDirty, tr("árvore do cercado suja", "paddock tree is dirty"), String(status.prefix(300))) }
        if await out(["rev-parse", "HEAD"], dir) != head { return await failed(.landDirty, tr("o HEAD mudou durante o portão ou o CI", "HEAD changed during the gate or the CI"), tr("era \(head.prefix(12))", "was \(head.prefix(12))")) }
        if let who = await host.othersWorking() { return await failed(.landDirty, tr("outro agente trabalhando no cercado", "another agent working in the paddock"), who) }
        // C3b: again after the gate and the CI (they may take long); the land checks it once more under its claim
        if base != nil, let why = await baseMoved(from: al.baseHead, dir) { return await failed(.landBaseMoved, tr("a base mudou", "the base moved"), why) }
        // the gate and the CI may take long (up to the CI's timeout): a `work stop`, a cancel, the work closed or the
        // starter gone meanwhile wins, and nothing lands
        if let h = halted() { return h }
        guard let now = try? await store.get(id), now.closedAt == nil, now.loop?.state == .running else { return .init(.workGone) }
        guard await host.starterAlive() else { return .init(.starterGone) }
        do {
            let (before, after, late, unrecorded) = try await host.land(mode: .merge, message: "Land paddock (auto-land): \(w.title)", base: base == nil ? nil : al.baseHead)
            // C3a: no commit made (nothing new, or integrated already): no land, no undo line, not counted anywhere
            if before == after {
                await note(id, tr("[loop] auto-land: nada a integrar (o merge não criou commit; a base segue em \(after.prefix(12)))", "[loop] auto-land: nothing to land (the merge created no commit; the base stays at \(after.prefix(12)))"))
                return .init(.landNothing, detail: String(after.prefix(12)))
            }
            let at = host.now()
            try? await store.update(id) { x in
                x.loop?.autoLand?.before = before; x.loop?.autoLand?.after = after
                x.loop?.autoLand?.startHead = nil   // C5c: integrated: the work's next run begins at the HEAD after this land
                x.record(LoopEvent(at: at, kind: .landed, detail: "\(before.prefix(12)) -> \(after.prefix(12))"))
                x.notes.append(WorkNote(at: at, text: tr("[loop] auto-land: integrado por merge local (sem push). Base antes: \(before); depois: \(after). "
                    + "Para desfazer, na base: git reset --hard \(before) (ou git revert -m 1 \(after))",
                    "[loop] auto-land: landed by local merge (no push). Base before: \(before); after: \(after). "
                    + "To undo, in the base: git reset --hard \(before) (or git revert -m 1 \(after))"), decision: true))
            }
            // C2: a failure after the merge is no conflict: the base changed, and both commits are recorded above
            if let late {
                await note(id, LotBoards.scrub(String(tr("[loop] auto-land: a base MUDOU (merge feito, \(before.prefix(12)) -> \(after.prefix(12))), "
                    + "mas o passo depois do merge falhou: \(late)", "[loop] auto-land: the base CHANGED (merge done, \(before.prefix(12)) -> \(after.prefix(12))), "
                    + "but the step after the merge failed: \(late)").prefix(Self.noteChars))))
            }
            // C4a: a land the daily cap may not count is no land to chain from: stop, and the owner knows why
            if let unrecorded {
                let line = LotBoards.scrub(String(tr("[loop] auto-land: merge feito (\(before.prefix(12)) -> \(after.prefix(12))), mas o registro do teto diário não foi gravado: \(unrecorded); o laço parou", "[loop] auto-land: merge done (\(before.prefix(12)) -> \(after.prefix(12))), but the daily cap record was not written: \(unrecorded); the loop stopped").prefix(Self.noteChars)))
                await note(id, line)   // the stop's own notice tells the owner (its label: "chame o dono")
                return .init(.landRegistryFailed, detail: Self.eventDetail(unrecorded))
            }
            return .init(.landed, detail: "\(before.prefix(12)) -> \(after.prefix(12))" + (late.map { tr("; depois do merge falhou: \(Self.eventDetail($0))", "; after the merge it failed: \(Self.eventDetail($0))") } ?? ""))
        } catch {
            // C3b: the base moved between the check above and the merge (`.conflict`, under the land's claim)
            if error.code == .conflict { return await failed(.landBaseMoved, tr("a base mudou", "the base moved"), error.message) }
            return await failed(.landConflict, tr("o land (merge) falhou", "the land (merge) failed"), error.message)
        }
    }
}

/// A5: after a land, the paddock's next work the owner already approved on its card (`queued`, oldest approval first,
/// with its own auto-land) is picked, carrying the chain: `--auto-land-max`, the daily cap and what is left of the
/// budget (the budget is the whole execution's). Before it, in order: the max not reached, the daily cap, the paddock's
/// factory doctor still passing the minimum, budget left. The loop never approves anything: a work with no approval
/// (no `queued` loop) never enters. The engine only picks: the router moves it `queued` → `running` (`activate`) once
/// its engine is registered, so no `running` work is ever left with no engine.
extension WorkLoop {
    /// The chain's next work and what it carries.
    struct Chain: Sendable, Equatable {
        var next: UUID
        /// `--auto-land-max` and `factory.guardrails.autoLandPerDay` of the chain's first work; `chained` the lands so far.
        var max: Int?, perDay: Int?, chained: Int
        /// What is left of the execution's budget (seconds); nil: no budget.
        var budget: Int?
        /// The title of the work whose land it follows (its note).
        var after: String
    }

    static func approved(_ l: WorkLoopState) -> Date { l.autoLand?.approvedAt ?? l.startedAt }

    /// The chain the engine picked after `id`'s land (once): the caller activates and runs it.
    func takeNext(after id: UUID) -> Chain? { chainNext.removeValue(forKey: id) }

    /// `x` from `queued` to `running` with the chain's limits; false (nothing changed): no longer a queued work of the
    /// chain's (closed, run or stopped meanwhile, its auto-land gone).
    /// C3b: `base`, the base read at the activation (after the land before it): the work's reference until its first
    /// attempt takes its own; nil (unread): the one it had stays. A work `work stop` took out of the queue is never activated.
    static func activate(_ x: inout Work, _ c: Chain, at: Date, base: String? = nil) -> Bool {
        guard x.closedAt == nil, var l = x.loop, l.state == .queued, l.autoLand != nil, l.autoLand?.dequeuedAt == nil else { return false }
        l.state = .running; l.startedAt = at
        if let base { l.autoLand?.baseHead = base }
        if let left = c.budget { l.budget = Swift.min(l.budget ?? left, left) }
        l.autoLand?.max = c.max; l.autoLand?.perDay = c.perDay; l.autoLand?.chained = c.chained
        x.loop = l
        x.notes.append(WorkNote(at: at, text: tr("[loop] auto-land: ativado pela corrente após o land de \"\(c.after)\" (\(c.chained + 1) de \(c.max ?? 1))", "[loop] auto-land: activated by the chain after the land of \"\(c.after)\" (\(c.chained + 1) of \(c.max ?? 1))")))
        return true
    }

    /// C3b: why the land may not trust its gate and CI: the paddock changed (since its merge base with `base`) a file that
    /// judges the land: `collie-work.json`, or a path the CI's or the gate's command names (`judgedPaths`: the whole
    /// path, never a substring; any change counts: created, edited or deleted, a spec naming it or not). nil: none.
    /// The attempts' own `tampered` is not this: it guards each attempt, this the whole paddock against the base.
    func judgesChanged(_ al: WorkLoopState.AutoLand, base: String, head: String, _ dir: URL) async -> String? {
        guard let d = try? await host.git(["diff", "--name-only", "-z", "--no-renames", "\(base)...\(head)"], in: dir), d.status == 0 else {
            return tr("não foi possível comparar com a base \(base.prefix(12)) os arquivos que julgam o land", "could not compare the files that judge the land with the base \(base.prefix(12))")
        }
        let judges = Self.judgedPaths(al.gate + " ; " + al.ci, dir).union([ProjectWorkConfig.fileName])
        let path = d.stdout.split(separator: "\0").map(String.init).first { judges.contains(Self.normalPath($0, dir)) }
        return path.map { tr("o agente alterou \(RerailText.clean($0, max: 120)) que julga o land", "the agent changed \(RerailText.clean($0, max: 120)) which judges the land") }
    }

    /// C3b: the path tokens of a shell command (split at spaces, quotes, `&&`, `||`, `;`, `|`, parentheses and
    /// redirections), each normalized (`normalPath`). A word that is no file (`bash`, `-x`) never matches a repo path.
    static func judgedPaths(_ command: String, _ dir: URL) -> Set<String> {
        Set(command.split(whereSeparator: { " \t\n\"'`;&|()<>".contains($0) }).map { normalPath(String($0), dir) }.filter { !$0.isEmpty })
    }

    /// C3b: a path as the repo lists it: relative to `dir` when under it (`repoRelative`), with no leading `./`.
    static func normalPath(_ p: String, _ dir: URL) -> String {
        var s = repoRelative(p, dir)[...]
        while s.hasPrefix("./") { s = s.dropFirst(2) }
        return String(s)
    }

    /// C3b: nil when the base branch's commit, read now, is `judged` (the base the last attempt began on); else why not:
    /// it moved, no base is known (`judged` nil) or git could not say (fail closed).
    func baseMoved(from judged: String?, _ dir: URL) async -> String? {
        guard let judged else { return tr("base desconhecida: nenhuma tentativa registrou a base em que começou", "unknown base: no attempt recorded the base it started on") }
        let now: String?
        do { now = try await host.baseHead() } catch { return tr("a base não pôde ser lida: \(error.message)", "the base could not be read: \(error.message)") }
        guard let now else { return tr("a base não pôde ser lida", "the base could not be read") }
        return now == judged ? nil : tr("a base está em \(now.prefix(12)), a tentativa começou em \(judged.prefix(12))", "the base is at \(now.prefix(12)), the attempt started at \(judged.prefix(12))")
    }

    /// C6: the stop's detail of a `work stop` or a cancel in the land's phase (after every task ended): the run's end
    /// discards the work's commits as a failed land does. One in an attempt has none, and keeps them.
    static let landPhase = "land"
    static let halts: Set<WorkLoopState.Stop.Code> = [.requested, .cancelled]

    /// The paddock's daily cap spent (`al.perDay` lands in 24 h): the stop, with its note; nil: room left (or no auto-land).
    /// The land checks it, and C6 the run's start too, before any attempt.
    func dailyCapReached(_ id: UUID, _ al: WorkLoopState.AutoLand?) async -> WorkLoopState.Stop? {
        guard let al else { return nil }
        let perDay = al.perDay ?? WorkLoopState.AutoLand.defaultPerDay, today = await landsToday()
        guard today >= perDay else { return nil }
        let why = tr("\(today) de \(perDay) em 24 h", "\(today) of \(perDay) in 24 h")
        await note(id, LotBoards.scrub(String(tr("[loop] auto-land: teto diário atingido (\(why)); nada integrado", "[loop] auto-land: daily cap reached (\(why)); nothing landed").prefix(Self.noteChars))))
        return .init(.landDailyCap, detail: Self.eventDetail(why))
    }

    /// The paddock's lands in the last 24 h (by the host's clock), from the daemon's durable record (`LoopHost.autoLands`).
    func landsToday() async -> Int {
        let since = host.now().addingTimeInterval(-86_400)
        return await host.autoLands().filter { $0 > since }.count
    }

    /// C3a: why HEAD is not what the clean reviews judged, nil when it is. One lane: HEAD must be the HEAD some done task's
    /// review judged (a commit after the last review is no one's approval). Lanes (`parallel` over 1): the integrator's
    /// merges come after each review, so each judged HEAD must only be in HEAD's history.
    /// ponytail: with lanes a commit after the integration still passes; a review of the integrated HEAD would close it
    func reviewedHeadVeto(_ w: Work, head: String, _ dir: URL) async -> String? {
        let done = w.tasks.filter { $0.state == .done }
        guard !done.isEmpty else { return nil }
        if let t = done.first(where: { $0.reviewedHead == nil }) { return RerailText.clean(t.title, max: 80) + tr(": revisão sem o HEAD revisado", ": review without the reviewed HEAD") }
        if (w.loop?.parallel ?? 1) <= 1 {
            return done.contains { $0.reviewedHead == head } ? nil : tr("o HEAD \(head.prefix(12)) não é o que a revisão aprovou", "HEAD \(head.prefix(12)) is not what the review approved")
        }
        for t in done {
            let r = try? await host.git(["merge-base", "--is-ancestor", t.reviewedHead!, head], in: dir)
            if r?.status != 0 { return RerailText.clean(t.title, max: 80) + tr(": o HEAD revisado \(t.reviewedHead!.prefix(12)) não está no HEAD", ": the reviewed HEAD \(t.reviewedHead!.prefix(12)) is not in HEAD") }
        }
        return nil
    }

    /// nil: the chain ends as `landed` (the max reached with nothing approved waiting, or the next work picked in
    /// `chainNext`); else why it ends here. A `work stop` (or the daemon's cancel) before or between its awaits:
    /// `requested` (`cancelled`), nothing picked.
    func afterLand(_ id: UUID, _ al: WorkLoopState.AutoLand) async -> WorkLoopState.Stop? {
        func halted() -> WorkLoopState.Stop? { stopping.contains(id) ? .init(.requested) : Task.isCancelled ? .init(.cancelled) : nil }
        if let h = halted() { return h }
        guard let w = try? await store.get(id), let pid = w.paddockId, let loop = w.loop else { return halted() }
        let done = (al.chained ?? 0) + 1, max = al.max ?? 1
        let all = (try? await store.list(includeClosed: false)) ?? []
        if let h = halted() { return h }
        let queue = all.filter { $0.id != id && $0.paddockId == pid && $0.loop?.state == .queued && $0.loop?.autoLand != nil && $0.loop?.autoLand?.dequeuedAt == nil }
            // C3b: oldest approval first (the card's answer); a loop from before has no `approvedAt`: its start stands in
            .sorted { (Self.approved($0.loop!), $0.openedAt) < (Self.approved($1.loop!), $1.openedAt) }
        // N=1 with an empty queue is `landed` (the max reached); `queueEmpty` only with room left
        if queue.isEmpty { return done < max ? .init(.queueEmpty) : nil }
        if done >= max { return .init(.maxReached, detail: "\(done) de --auto-land-max \(max) integrado(s); \(queue.count) na fila") }
        let perDay = al.perDay ?? WorkLoopState.AutoLand.defaultPerDay, today = await landsToday()
        if let h = halted() { return h }
        if today >= perDay { return .init(.landDailyCap, detail: "\(today) de \(perDay) em 24 h") }
        let doctor = await host.doctorRefusal()
        if let h = halted() { return h }
        if let why = doctor { return .init(.landDoctorRegressed, detail: Self.eventDetail(why)) }
        let left = loop.budget.map { $0 - (loop.spent ?? 0) }
        if let left, left <= 0 { return .init(.budgetSpent) }
        let next = queue[0]
        chainNext[id] = Chain(next: next.id, max: al.max, perDay: al.perDay, chained: done, budget: left, after: RerailText.clean(w.title, max: 80))
        await note(id, tr("[loop] auto-land: próximo trabalho da fila: \"\(RerailText.clean(next.title, max: 80))\" (\(done + 1) de \(max))", "[loop] auto-land: next work in the queue: \"\(RerailText.clean(next.title, max: 80))\" (\(done + 1) of \(max))"))
        return nil
    }
}
