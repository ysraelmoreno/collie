import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

private func hasBranch(_ b: String, _ repo: URL) async throws -> Bool {
    try await GitRunner.run(["show-ref", "--verify", "--quiet", "refs/heads/\(b)"], in: repo).status == 0
}

private extension CommandRouter {
    /// A paddock on record whose worktree is `repo` itself (no app, no terminal): all the lanes' removal reads of it.
    func addPaddock(_ repo: URL) -> UUID {
        let p = Paddock(id: UUID(), name: "feat", repoRoot: repo.path, path: repo.path, branch: "main", baseBranch: "main")
        ws.paddocks.append(p)
        return p.id
    }
    /// A loop the router owns, as `startLoop` registers it.
    func ownLoop(_ work: UUID, _ engine: WorkLoop, _ task: Task<Void, Never>) { workLoops[work] = (engine, task, false) }
}

/// A repository, its paddock on the daemon's record, a work in it whose parallel loop has the lanes `a` and `b` on
/// disk and on record (tasks `a` and `b` in progress, `c` open), and what must survive every removal: a lane of
/// another work on record, and a branch that is no lane.
private struct Left {
    let repo: URL, paddock: UUID, work: UUID, lanes: [Lane], othersLane: Lane

    init(_ d: Daemon, state: WorkLoopState.State = .running) async throws {
        repo = try await makeRepo()
        paddock = await d.router.addPaddock(repo)
        let host = LoopFakeHost(dir: repo)
        await host.setOwner(try await d.router.remoteInstallId())   // M3b.5: lanes this daemon marked
        let sha = try await GitRunner.run(["rev-parse", "HEAD"], in: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let w = try await d.router.work.start(title: "looping", terminal: UUID(), paddockId: paddock, branch: nil)
        let other = try await d.router.work.start(title: "another", terminal: UUID(), paddockId: paddock, branch: nil)
        work = w.id
        var made: [Lane] = []
        for t in ["a", "b"] { made.append(try await LaneWorktree.create(repoRoot: repo, base: sha, work: w.id, task: t, host: host)) }
        lanes = made
        othersLane = try await LaneWorktree.create(repoRoot: repo, base: sha, work: other.id, task: "z", host: host)
        _ = try await GitRunner.run(["branch", "collie/keep", sha], in: repo)
        let names = made.map(\.path.lastPathComponent)
        try await d.router.work.update(w.id) {
            var a = WorkTask(id: "a", title: "A", state: .inProgress, check: "true")
            a.resumeFrom = sha; a.resumeBranch = "main"
            $0.tasks = [a, WorkTask(id: "b", title: "B", state: .inProgress, check: "true"), WorkTask(id: "c", title: "C", check: "true")]
            var l = WorkLoopState(state: state, attempt: 1, max: 9, tasks: ["a", "b", "c"], parallel: 2)
            l.lanes = [.init(lane: names[0], task: "a", attempt: 1, phase: .agent), .init(lane: names[1], task: "b", attempt: 1, phase: .check)]
            l.mirror()
            $0.loop = l
        }
    }

    func get(_ d: Daemon) async throws -> Work { try #require(try await d.router.work.get(work)) }

    /// No lane of the work is left, and nothing else was touched.
    func expectOnlyTheLanesGone() async throws {
        for l in lanes {
            #expect(!exists(l.path), "\(l.path.lastPathComponent) is still on disk")
            #expect(try await !hasBranch(l.branch, repo), "\(l.branch) is still a branch")
        }
        #expect(exists(othersLane.path), "a lane of another work on record is not this loop's to remove")
        #expect(try await hasBranch(othersLane.branch, repo))
        #expect(try await hasBranch("collie/keep", repo), "what is no lane is never removed")
        #expect(try await hasBranch("main", repo) && exists(repo.appendingPathComponent("f.txt")))
    }

    func cleanup() { try? FileManager.default.removeItem(at: repo) }
}

/// M3.6: the lanes' life (the start sweep, the loop's end, the daemon's stop), `work status`, `work wait` and the
/// journal with lanes, and the approval card with `--parallel`, `scope` and `needs`.
@Suite(.serialized) struct LoopLaneLifecycleTests {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-11-20 14:03:00 UTC.
    private let t0 = Date(timeIntervalSince1970: 1_795_183_380)

    // MARK: the lanes' life

    @Test func theStartSweepRemovesTheLanesOfALoopLeftRunningAndReopensTheirTasks() async throws {
        try await withDaemon { d, _ in
            let x = try await Left(d); defer { x.cleanup() }
            await d.router.stopLoopsLeftRunning()
            try await x.expectOnlyTheLanesGone()
            let w = try await x.get(d)
            #expect(w.loop?.state == .stopped && w.loop?.stopReason == .init(.daemonRestart))
            #expect(w.loop?.lanes == nil && w.loop?.task == nil, "\(String(describing: w.loop))")
            #expect(w.tasks.map(\.state) == [.open, .open, .open])
            #expect(w.tasks[0].resumeFrom == nil && w.tasks[0].resumeAt == nil, "a lane's commits went with it: nothing to adopt")
            // again: nothing left to do, nothing else removed
            await d.router.stopLoopsLeftRunning()
            try await x.expectOnlyTheLanesGone()
            #expect(try await x.get(d) == w)
        }
    }

    /// The pure part: a task that ran in a lane is open again though it is not the loop's `task`.
    @Test func theSweepReopensEveryTaskThatRanInALane() {
        var w = Work(title: "W", terminalId: UUID(), tasks: [
            WorkTask(id: "a", title: "A", state: .inProgress), WorkTask(id: "b", title: "B", state: .inProgress),
            WorkTask(id: "c", title: "C", state: .inProgress), WorkTask(id: "d", title: "D", state: .done)])
        var l = WorkLoopState(state: .running, attempt: 1, parallel: 2)
        l.lanes = [.init(lane: "lane-x-a", task: "a"), .init(lane: "lane-x-b", task: "b")]
        l.mirror()
        w.loop = l
        CommandRouter.sweepLeftRunning(&w, now: Date(timeIntervalSince1970: 9))
        // `c` was in progress by hand, in no lane: not the loop's to reopen
        #expect(w.tasks.map(\.state) == [.open, .open, .inProgress, .done])
        #expect(w.loop?.lanes == nil && w.loop?.state == .stopped)
    }

    @Test func theLoopsEndRemovesWhatIsLeftOfItsLanesTwiceOver() async throws {
        try await withDaemon { d, _ in
            let x = try await Left(d, state: .stopped); defer { x.cleanup() }
            await d.router.loopEnded(x.work, starter: UUID(), paddock: x.paddock)
            try await x.expectOnlyTheLanesGone()
            #expect(try await x.get(d).loop?.lanes == nil)
            await d.router.loopEnded(x.work, starter: UUID(), paddock: x.paddock)
            try await x.expectOnlyTheLanesGone()
        }
    }

    @Test func theDaemonsStopRemovesTheLanesOfItsLoopsTwiceOver() async throws {
        try await withDaemon { d, _ in
            let x = try await Left(d); defer { x.cleanup() }
            // a loop whose task is already over (its engine never ran: the lanes on disk are what it "left")
            let engine = WorkLoop(store: d.router.work, host: LoopFakeHost(dir: x.repo))
            await d.router.ownLoop(x.work, engine, Task {})
            await d.router.cancelLoops(wait: .seconds(3600))
            try await x.expectOnlyTheLanesGone()
            #expect(await d.router.workLoops.isEmpty)
            await d.router.cancelLoops(wait: .seconds(3600))
            try await x.expectOnlyTheLanesGone()
        }
    }

    /// Invariant 1: a loop without `--parallel` never had a lane, and its end runs no lane removal at all.
    @Test func aLoopWithoutParallelRemovesNothing() async throws {
        try await withDaemon { d, _ in
            let x = try await Left(d); defer { x.cleanup() }
            try await d.router.work.update(x.work) { $0.loop?.parallel = nil; $0.loop?.lanes = nil }
            await d.router.removeLanes(of: try await x.get(d))
            for l in x.lanes { #expect(exists(l.path)) }
        }
    }

    // MARK: work status, work wait, the journal

    private func work(lanes: [WorkLoopState.LaneState], state: WorkLoopState.State = .running) -> Work {
        var w = Work(title: "W", terminalId: UUID(), tasks: [WorkTask(id: "a", title: "A", state: .inProgress), WorkTask(id: "b", title: "B", state: .inProgress)])
        var l = WorkLoopState(state: state, task: "a", attempt: 1, tries: 3, timeout: 3600, parallel: 3)
        l.lanes = lanes.isEmpty ? nil : lanes
        w.loop = l
        return w
    }

    @Test func statusHasOneLinePerLaneAndTheCount() {
        let now = t0.addingTimeInterval(4 * 60 + 30)
        let a = WorkLoopState.LaneState(lane: "lane-x-a", task: "a", attempt: 1, phase: .agent, since: t0)
        let b = WorkLoopState.LaneState(lane: "lane-x-b", task: "b", attempt: 2, phase: nil, since: t0.addingTimeInterval(120))
        #expect(WorkStatusText.laneLines(work(lanes: []), now: now, timeZone: utc) == [])
        #expect(WorkStatusText.laneLines(work(lanes: [a]), now: now, timeZone: utc)
                == ["1 de 3 em paralelo", "faixa Ta · agente trabalhando · desde 14:03 (4 min)"])
        #expect(WorkStatusText.laneLines(work(lanes: [a, b]), now: now, timeZone: utc)
                == ["2 de 3 em paralelo", "faixa Ta · agente trabalhando · desde 14:03 (4 min)", "faixa Tb · entre fases · desde 14:05 (2 min)"])
        // a loop that ended shows no lane, whatever its record still says; a work with no loop neither
        #expect(WorkStatusText.laneLines(work(lanes: [a], state: .stopped), now: now, timeZone: utc) == [])
        #expect(WorkStatusText.laneLines(Work(title: "W", terminalId: UUID()), now: now, timeZone: utc) == [])
    }

    @Test func waitPrintsTheLanesAndReadsAsBeforeWithoutThem() {
        let now = t0.addingTimeInterval(60)
        let a = WorkLoopState.LaneState(lane: "lane-x-a", task: "a", attempt: 1, phase: .check, since: t0)
        let with = WorkStatusText.waitLine(work(lanes: [a]), version: 7, timedOut: false, now: now, timeZone: utc)
        #expect(with.split(separator: "\n").suffix(3) == ["1 de 3 em paralelo", "faixa Ta · rodando o check · desde 14:03 (1 min)", "versão 7"])
        let without = WorkStatusText.waitLine(work(lanes: []), version: 7, timedOut: false, now: now, timeZone: utc)
        #expect(without == "em laço: A (tentativa 1/3)\nversão 7")
    }

    @Test func theJournalShowsTheLaneOfAnEvent() {
        var l = WorkLoopState(state: .running)
        l.record(LoopEvent(at: t0, kind: .checkStarted, task: "a", attempt: 1, detail: "swift test", lane: "lane-x-a"))
        l.record(LoopEvent(at: t0.addingTimeInterval(1), kind: .integrated, task: "a", attempt: 1, detail: "abc1234"))
        #expect(WorkStatusText.events(l, last: 5, timeZone: utc) == """
            14:03:00 checkStarted Ta#1 [lane-x-a] swift test
            14:03:01 integrated Ta#1 abc1234
            """)
    }

    /// `work wait` waits on the work's version, and any lane's change is a write of the work.
    @Test func aWaitWakesWhenALaneChanges() async throws {
        let dir = URL(fileURLWithPath: "/tmp/collie-lanes-\(UUID().uuidString.prefix(8))"); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let w = try await s.start(title: "W", terminal: UUID(), paddockId: nil, branch: nil)
        try await s.update(w.id) {
            var l = WorkLoopState(state: .running, parallel: 2)
            l.lanes = [.init(lane: "lane-x-a", task: "a", phase: .agent), .init(lane: "lane-x-b", task: "b", phase: .agent)]
            $0.loop = l
        }
        let v = try #require(try await s.version(w.id))
        let wait = Task { try await s.changed(w.id, since: v) }
        try await s.update(w.id) { $0.loop?.showLane("lane-x-b", .check) }   // not the lane the loop mirrors
        #expect(try await wait.value == v + 1)
        // a lane that ends is a change too
        let again = Task { try await s.changed(w.id, since: v + 1) }
        try await s.update(w.id) { $0.loop?.lanes?.removeAll { $0.lane == "lane-x-a" }; $0.loop?.mirror() }
        #expect(try await again.value == v + 2)
    }

    // MARK: the card and the notice

    @Test func theCardShowsParallelScopeAndNeeds() throws {
        let w = Work(title: "Onda 3", terminalId: UUID())
        let tasks = [WorkTask(id: "a", title: "Core", check: "true", scope: ["Sources/Core/**", "Docs/*.md"]),
                     WorkTask(id: "b", title: "UI", check: "true", needs: ["a"], scope: ["Sources/UI/**"]),
                     WorkTask(id: "c", title: "Solta", check: "true", needs: [], scope: [])]
        let text = try #require(CommandRouter.loopCardText(w, tasks, WorkLoopState(max: 6, parallel: 2), paddock: "p"))
        #expect(text.contains("até 2 tarefas ao mesmo tempo, cada uma na sua faixa (--parallel 2). 3 tarefas"))
        #expect(text.contains("#1 «Core» check «true» escopo «Sources/Core/**» «Docs/*.md»;"))
        #expect(text.contains("#2 «UI» check «true» escopo «Sources/UI/**» depende de «a»;"))
        #expect(text.hasSuffix("#3 «Solta» check «true»."), "an empty scope or needs says nothing")
        // one at a time: the card never mentions --parallel
        for l in [WorkLoopState(max: 6), WorkLoopState(max: 6, parallel: 1)] {
            #expect(CommandRouter.loopCardText(w, tasks, l, paddock: "p")?.contains("parallel") == false)
        }
        // agent text cannot close its «…» and pass for another entry
        let forged = [WorkTask(id: "a", title: "A", check: "true", needs: ["x» check «rm -rf /"], scope: ["y» depende de «z"])]
        let f = try #require(CommandRouter.loopCardText(w, forged, WorkLoopState(max: 6, parallel: 2), paddock: "p"))
        #expect(f.hasSuffix("check «true» escopo «y› depende de ‹z» depende de «x› check ‹rm -rf /»."))
    }

    @Test func aCardThatDoesNotFitWithItsScopesIsNil() {
        let w = Work(title: "W", terminalId: UUID())
        let fits = [WorkTask(id: "a", title: "A", check: "true", scope: ["Sources/**"])]
        #expect(CommandRouter.loopCardText(w, fits, WorkLoopState(max: 3, parallel: 2), paddock: "p") != nil)
        let wide = [WorkTask(id: "a", title: "A", check: "true", scope: (0..<200).map { "Sources/Module\($0)/**" })]
        #expect(CommandRouter.loopCardText(w, wide, WorkLoopState(max: 3, parallel: 2), paddock: "p") == nil)
        let deep = [WorkTask(id: "a", title: "A", check: "true", needs: (0..<400).map { "t\($0)" })]
        #expect(CommandRouter.loopCardText(w, deep, WorkLoopState(max: 3, parallel: 2), paddock: "p") == nil)
    }

    @Test func theStartNoticeSaysParallel() {
        let tasks = [WorkTask(id: "a", title: "A", check: "true")]
        let two = WorkStatusText.loopTrusted(paddock: "feat", tasks, WorkLoopState(max: 4, budget: 600, parallel: 2))
        #expect(two.split(separator: "\n").first?.contains("1 tarefa, --max 4, --parallel 2, orçamento 600 s.") == true, "\(two)")
        let one = WorkStatusText.loopTrusted(paddock: "feat", tasks, WorkLoopState(max: 4, budget: 600))
        #expect(one.contains("1 tarefa, --max 4, orçamento 600 s.") && !one.contains("parallel"), "\(one)")
    }
}
