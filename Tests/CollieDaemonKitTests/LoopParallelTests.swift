import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func git(_ dir: URL, _ args: String...) async throws -> String {
    let r = try await GitRunner.run(args, in: dir)
    #expect(r.status == 0, "git \(args): \(r.stderr)")
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Counts arrivals; `wait(for:)` returns once `n` came. No clock: the order of the lanes comes from continuations.
private actor Arrivals {
    private var count = 0, waiters: [(n: Int, c: CheckedContinuation<Void, Never>)] = []
    func hit() {
        count += 1
        for w in waiters where w.n <= count { w.c.resume() }
        waiters.removeAll { $0.n <= count }
    }
    func wait(for n: Int) async {
        if count >= n { return }
        await withCheckedContinuation { waiters.append((n, $0)) }
    }
}

/// A wait that only a cancelled task leaves: an agent that works until the loop stops it.
private actor Forever {
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                if Task.isCancelled { c.resume() } else { waiters[id] = c }
            }
        } onCancel: { Task { await self.drop(id) } }
    }
    private func drop(_ id: UUID) { waiters.removeValue(forKey: id)?.resume() }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var extra: TimeInterval = 0
    var now: Date { lock.withLock { Date().addingTimeInterval(extra) } }
    func advance(_ s: TimeInterval) { lock.withLock { extra += s } }
}

private actor Seen {
    var items: [String: String] = [:]
    func set(_ k: String, _ v: String) { items[k] = v }
}

/// What every lane's host shares: the scripted agents (by terminal name, `loop-<task>-<n>`) and what happened.
private actor ParCore {
    nonisolated let patches = URL(fileURLWithPath: "/tmp/collie-par-patches-\(UUID().uuidString.prefix(8))")
    private var scripts: [String: @Sendable (URL) async throws -> Void] = [:]
    private var agents: [UUID: (name: String, dir: URL)] = [:]
    var summoned: [String] = [], dismissed: [String] = [], made: [String] = [], gone: [String] = []
    /// "start <name>" / "end <name>", in the order the agents' turns began and ended.
    var log: [String] = []
    /// Where each agent was born.
    var dirs: [String: URL] = [:]
    func set(_ name: String, _ act: @escaping @Sendable (URL) async throws -> Void) { scripts[name] = act }
    func summon(_ name: String, _ dir: URL) -> UUID {
        let id = UUID(); agents[id] = (name, dir); summoned.append(name); dirs[name] = dir
        return id
    }
    func ask(_ terminal: UUID, _ prompt: String) async -> AskResult.Source {
        guard prompt != WorkLoop.nudgePrompt, let a = agents[terminal] else { return .hook }
        log.append("start \(a.name)")
        do { try await scripts[a.name]?(a.dir) } catch { Issue.record("agent \(a.name): \(error)") }
        log.append("end \(a.name)")
        return .hook
    }
    func dismiss(_ terminal: UUID) { dismissed.append(agents[terminal]?.name ?? "?") }
    func laneMade(_ l: Lane) { made.append(l.path.lastPathComponent) }
    func laneGone(_ l: Lane) { gone.append(l.path.lastPathComponent) }
}

/// A host without PTYs that has lanes: scripted agents, real git and a real check, in the paddock's worktree or in one lane.
private struct ParHost: LoopHost {
    let core: ParCore, clock: Clock, dir: URL
    func summon(name: String, for work: Work, loop: WorkLoopState) async throws(ProtocolError) -> UUID { await core.summon(name, dir) }
    func ask(_ terminal: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> AskResult.Source { await core.ask(terminal, prompt) }
    func working(_ terminal: UUID) async -> Bool { false }
    func dismiss(_ terminal: UUID) async { await core.dismiss(terminal) }
    func othersWorking() async -> String? { nil }
    func starterAlive() async -> Bool { true }
    func git(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult { try await GitRunner.run(args, in: dir) }
    func check(_ command: String, in dir: URL, timeout: Duration) async throws(ProtocolError) -> ProcessResult {
        try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/bash"), args: ["-c", command], in: dir,
                                     env: ProcessInfo.processInfo.environment, timeout: timeout)
    }
    func readSpec(_ path: String) async -> String? { nil }
    func exists(_ path: String, in dir: URL) async -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path) }
    func patchDir(_ work: UUID) -> URL { core.patches.appendingPathComponent(work.uuidString.lowercased()) }
    func now() -> Date { clock.now }
    func laneHost(_ lane: Lane) async throws(ProtocolError) -> any LoopHost {
        await core.laneMade(lane)
        return ParHost(core: core, clock: clock, dir: lane.path)
    }
    func laneGone(_ lane: Lane) async { await core.laneGone(lane) }
}

/// A repo (the paddock's worktree), a store with a work whose loop asks for `parallel`, the host with lanes and the loop.
private struct ParRig {
    let repo: URL, storeDir: URL, store: WorkStore, core = ParCore(), clock = Clock(), loop: WorkLoop, work: UUID, base: String
    init(_ tasks: [WorkTask], parallel: Int = 2, tries: Int = 3, max: Int? = nil, budget: Int? = nil, gate: String? = nil) async throws {
        repo = try await makeRepo()
        base = try await git(repo, "rev-parse", "HEAD")
        storeDir = URL(fileURLWithPath: "/tmp/collie-par-\(UUID().uuidString.prefix(8))")
        store = WorkStore(dir: storeDir)
        let w = try await store.start(title: "W", terminal: UUID(), paddockId: UUID(), branch: "main")
        try await store.update(w.id) {
            $0.tasks = tasks
            $0.loop = WorkLoopState(tries: tries, timeout: 60, max: max, budget: budget, tasks: tasks.map(\.id), gate: gate, parallel: parallel)
        }
        work = w.id
        loop = WorkLoop(store: store, host: ParHost(core: core, clock: clock, dir: repo), poll: .milliseconds(10),
                        checkTimeout: .seconds(30), othersWait: .milliseconds(50))
    }
    func run() async -> WorkLoopState.State { await loop.run(work: work, dir: repo) }
    func get() async throws -> Work { try #require(try await store.get(work)) }
    func task(_ id: String) async throws -> WorkTask { try #require(try await get().tasks.first { $0.id == id }) }
    /// Every trace of a lane in the repository: branches, worktrees besides the paddock's, folders.
    func lanesLeft() async throws -> [String] {
        let refs = try await git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/collie/lane/")
        let trees = try await git(repo, "worktree", "list", "--porcelain").split(separator: "\n").filter { $0.hasPrefix("worktree ") }.dropFirst()
        let dir = repo.appendingPathComponent("\(LegacyOrq.repoDirName(repoRoot: repo))/paddocks")
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return refs.split(separator: "\n").map(String.init) + trees.map(String.init) + folders
    }
    func has(_ file: String) -> Bool { FileManager.default.fileExists(atPath: repo.appendingPathComponent(file).path) }
    func cleanup() { for u in [repo, storeDir, core.patches] { try? FileManager.default.removeItem(at: u) } }
}

private func ptask(_ id: String, _ check: String, scope: [String]?, needs: [String]? = nil) -> WorkTask {
    WorkTask(id: id, title: "Task \(id)", check: check, needs: needs, scope: scope)
}

/// What a run left, without what differs from one run to another by nature (shas, temp paths, times).
private func shape(_ w: Work, _ rig: LoopRig) async -> [String] {
    func plain(_ s: String) -> String {
        s.replacingOccurrences(of: rig.repo.path, with: "<repo>").replacingOccurrences(of: rig.host.patches.path, with: "<patches>")
            .replacingOccurrences(of: "\\b[0-9a-f]{7,40}\\b", with: "#", options: .regularExpression)
    }
    var out = w.tasks.map { t in
        "task \(t.id) \(t.state.rawValue) tries=\(t.tries ?? 0) last=\(t.lastFailure ?? "-") reason=\(t.reason ?? "-") "
            + "evidence=\(t.evidence.map { "\($0.attempt)/\($0.commits.count)/\($0.shortstat)" } ?? "-") resume=\(t.resumeFrom == nil ? "-" : "set")"
    }
    out += w.notes.map { "note " + plain($0.text) }
    out += (w.loop?.events ?? []).map { "event \($0.kind.rawValue) \($0.task ?? "-") \($0.attempt ?? 0) \(plain($0.detail ?? "-")) lane=\($0.lane ?? "-")" }
    out += w.jobs.map { "job \($0.id) \($0.state.rawValue) \(plain($0.result ?? "-"))" }
    if let l = w.loop {
        out.append("loop \(l.state.rawValue) used=\(l.used) task=\(l.task ?? "-") attempt=\(l.attempt) phase=\(l.phase?.rawValue ?? "-") "
            + "stop=\(l.stopReason?.code.rawValue ?? "-") lanes=\(l.lanes?.count ?? -1)")
    }
    out += await rig.host.summoned.map { "summoned \($0)" }
    out += await rig.host.dismissed.map { "dismissed \($0)" }
    out += await rig.host.commands.map { "ran \($0)" }
    return out
}

/// M3.5: the scheduler in the engine (`work run --parallel N`), with a fake host that has lanes over temporary repositories.
@Suite(.timeLimit(.minutes(3))) struct LoopParallelTests {
    /// The old path's result for a set of tasks (a retry, a deferral, a gate), with `parallel` nil or 1.
    private func sequential(parallel: Int?) async throws -> [String] {
        let tasks = [WorkTask(id: "a", title: "Task a", check: "test -f a.txt || { echo MISSING a.txt; exit 1; }"),
                     WorkTask(id: "b", title: "Task b", check: "false"),
                     WorkTask(id: "c", title: "Task c", check: "test -f c.txt")]
        let r = try await LoopRig(tasks, tries: 2, max: 10, gate: "test -f f.txt"); defer { r.cleanup() }
        try await r.store.update(r.work) { $0.loop?.parallel = parallel }
        await r.host.set("loop-a-1", LoopScript(act: { try await commit("wrong.txt", "x\n", in: $0) }))
        await r.host.set("loop-a-2", LoopScript(act: { try await commit("a.txt", "a\n", in: $0) }))
        await r.host.set("loop-b-1", LoopScript(act: { try await commit("b.txt", "b\n", in: $0) }))
        await r.host.set("loop-b-2", LoopScript(act: { try await commit("b.txt", "b\n", in: $0) }))
        await r.host.set("loop-c-1", LoopScript(act: { try await commit("c.txt", "c\n", in: $0) }))
        let end = await r.run()
        #expect(end == .finished)
        let w = try await r.get()
        #expect(w.loop?.parallel == parallel)
        let lanes = try await git(r.repo, "for-each-ref", "refs/heads/collie/lane/")
        #expect(lanes.isEmpty, "no lane without --parallel")
        return await shape(w, r)
    }

    @Test func parallelOneIsTheLoopAsItAlwaysWas() async throws {
        let old = try await sequential(parallel: nil), one = try await sequential(parallel: 1)
        #expect(old == one)
        // the set is not trivial: a retry, a deferral, two approvals, and nothing of the lanes
        #expect(old.contains { $0.hasPrefix("task a done tries=2") } && old.contains { $0.hasPrefix("task b deferred tries=2") })
        #expect(old.contains { $0.hasPrefix("task c done tries=1") })
        #expect(old.allSatisfy { !$0.hasPrefix("event") || $0.hasSuffix("lane=-") })
        #expect(old.contains { $0.hasPrefix("loop finished used=5") && $0.hasSuffix("lanes=-1") }, "\(old.last ?? "")")
    }

    @Test func disjointScopesRunAtTheSameTimeAndBothIntegrate() async throws {
        let r = try await ParRig([ptask("a", "test -f a.txt", scope: ["a.txt"]), ptask("b", "test -f b.txt", scope: ["b.txt"])],
                                 gate: "test -f f.txt"); defer { r.cleanup() }
        // each agent only goes on once both are in their turn: in series this would never end
        let both = Arrivals()
        await r.core.set("loop-a-1") { d in await both.hit(); await both.wait(for: 2); try await commit("a.txt", "a\n", in: d) }
        await r.core.set("loop-b-1") { d in await both.hit(); await both.wait(for: 2); try await commit("b.txt", "b\n", in: d) }
        let end = await r.run()
        #expect(end == .finished)
        let log = await r.core.log
        #expect(Set(log.prefix(2)) == ["start loop-a-1", "start loop-b-1"], "both turns began before either ended: \(log)")
        let w = try await r.get()
        #expect(w.tasks.map(\.state) == [.done, .done] && w.tasks.map(\.tries) == [1, 1])
        #expect(w.tasks.allSatisfy { $0.evidence?.commits.count == 1 && $0.resumeFrom == nil })
        #expect(r.has("a.txt") && r.has("b.txt"))
        let merges = try await git(r.repo, "log", "--merges", "--format=%s")
        #expect(Set(merges.split(separator: "\n").map(String.init)) == ["merge: Task a", "merge: Task b"])
        let status = try await git(r.repo, "status", "--porcelain", "--untracked-files=no")
        #expect(status.isEmpty)
        // each agent worked in its lane, never in the paddock's worktree, and no lane is left
        let dirs = await r.core.dirs
        #expect(dirs.count == 2 && dirs.values.allSatisfy { $0 != r.repo && LaneWorktree.isLane($0) }, "\(dirs)")
        #expect(Set(dirs.values.map(\.path)).count == 2)
        let left = try await r.lanesLeft(), made = await r.core.made, gone = await r.core.gone
        #expect(left.isEmpty, "\(left)")
        #expect(made.count == 2 && made.sorted() == gone.sorted())
        // the journal names the lane, the loop's counters are one
        let ev = w.loop?.events ?? []
        #expect(ev.filter { $0.kind == .integrated }.count == 2)
        #expect(ev.filter { $0.task != nil }.allSatisfy { $0.lane.map { made.contains($0) } == true }, "\(ev.filter { $0.task != nil && $0.lane == nil })")
        #expect(w.loop?.used == 2 && w.loop?.lanes == nil && w.loop?.phase == nil && w.loop?.task == nil)
        #expect(w.jobs.count == 2 && w.jobs.allSatisfy { $0.state == .finished })
    }

    @Test func overlappingScopesRunInSeries() async throws {
        let r = try await ParRig([ptask("a", "test -f a.txt", scope: ["src/**"]), ptask("b", "test -f b.txt", scope: ["src/x.txt"])])
        defer { r.cleanup() }
        await r.core.set("loop-a-1") { try await commit("a.txt", "a\n", in: $0) }
        await r.core.set("loop-b-1") { try await commit("b.txt", "b\n", in: $0) }
        let end = await r.run()
        #expect(end == .finished)
        let log = await r.core.log
        #expect(log == ["start loop-a-1", "end loop-a-1", "start loop-b-1", "end loop-b-1"])
        let w = try await r.get(), ev = w.loop?.events ?? []
        let merged = try #require(ev.firstIndex { $0.kind == .integrated && $0.task == "a" })
        let began = try #require(ev.firstIndex { $0.kind == .attemptStarted && $0.task == "b" })
        #expect(merged < began, "b's lane is cut only after a is integrated")
        #expect(w.tasks.map(\.state) == [.done, .done])
        let left = try await r.lanesLeft()
        #expect(left.isEmpty)
    }

    @Test func aTaskWithNoScopeRunsAlone() async throws {
        let r = try await ParRig([ptask("a", "test -f a.txt", scope: nil), ptask("b", "test -f b.txt", scope: ["b.txt"])])
        defer { r.cleanup() }
        await r.core.set("loop-a-1") { try await commit("a.txt", "a\n", in: $0) }
        await r.core.set("loop-b-1") { try await commit("b.txt", "b\n", in: $0) }
        let end = await r.run()
        #expect(end == .finished)
        let log = await r.core.log
        #expect(log == ["start loop-a-1", "end loop-a-1", "start loop-b-1", "end loop-b-1"])
    }

    @Test func needsWaitForTheIntegration() async throws {
        let r = try await ParRig([ptask("a", "test -f a.txt", scope: ["a.txt"]), ptask("b", "test -f b.txt", scope: ["b.txt"], needs: ["a"])])
        defer { r.cleanup() }
        let seen = Seen()
        await r.core.set("loop-a-1") { try await commit("a.txt", "a\n", in: $0) }
        await r.core.set("loop-b-1") { d in
            await seen.set("a.txt", FileManager.default.fileExists(atPath: d.appendingPathComponent("a.txt").path) ? "there" : "missing")
            try await commit("b.txt", "b\n", in: d)
        }
        let end = await r.run()
        #expect(end == .finished)
        let log = await r.core.log, items = await seen.items
        #expect(log == ["start loop-a-1", "end loop-a-1", "start loop-b-1", "end loop-b-1"])
        #expect(items["a.txt"] == "there", "b's lane was cut from a HEAD that has a's work")
        let states = try await r.get().tasks.map(\.state)
        #expect(states == [.done, .done])
    }

    @Test func aTaskWhoseNeedWasDeferredIsDeferredToo() async throws {
        let r = try await ParRig([ptask("a", "true", scope: ["a.txt"]), ptask("b", "test -f b.txt", scope: ["b.txt"], needs: ["a"])], tries: 1)
        defer { r.cleanup() }
        let end = await r.run()   // a's agent commits nothing
        #expect(end == .finished)
        let w = try await r.get(), summoned = await r.core.summoned
        #expect(w.tasks.map(\.state) == [.deferred, .deferred])
        #expect(w.tasks[1].reason?.contains("adiada") == true, "\(w.tasks[1].reason ?? "")")
        #expect(summoned == ["loop-a-1"], "b never ran")
    }

    @Test func maxIsOneCounterForEveryLane() async throws {
        let tasks = ["a", "b", "c", "d"].map { ptask($0, "true", scope: ["\($0).txt"]) }
        let r = try await ParRig(tasks, tries: 1, max: 3); defer { r.cleanup() }
        let end = await r.run()   // no agent commits: every attempt fails
        #expect(end == .stopped)
        let w = try await r.get(), summoned = await r.core.summoned
        #expect(summoned.count == 3, "\(summoned)")
        #expect(w.loop?.used == 3 && w.loop?.stopReason?.code == .maxReached)
        #expect(w.tasks.filter { $0.state == .deferred }.count == 3 && w.tasks.filter { $0.state == .open }.count == 1)
        let left = try await r.lanesLeft()
        #expect(left.isEmpty)
    }

    @Test func theSharedBudgetSpentByOneLaneStopsTheOther() async throws {
        let r = try await ParRig([ptask("a", "test -f a.txt", scope: ["a.txt"]), ptask("b", "test -f b.txt", scope: ["b.txt"])], budget: 50)
        defer { r.cleanup() }
        let started = Arrivals(), forever = Forever(), clock = r.clock
        // a takes 100 s of the loop's 50 while b is still in its turn
        await r.core.set("loop-a-1") { d in await started.wait(for: 1); clock.advance(100); try await commit("a.txt", "a\n", in: d) }
        await r.core.set("loop-b-1") { _ in await started.hit(); await forever.wait() }
        let end = await r.run()
        #expect(end == .stopped)
        let w = try await r.get(), dismissed = await r.core.dismissed
        #expect(w.loop?.stopReason?.code == .budgetSpent)
        #expect((w.loop?.spent ?? 0) >= 100)
        #expect(w.tasks.map(\.state) == [.done, .open], "a passed and was integrated; b was stopped with no verdict")
        #expect(r.has("a.txt") && !r.has("b.txt"))
        #expect(w.tasks[1].tries == nil && w.loop?.used == 1, "b's attempt is not counted")
        #expect(dismissed.sorted() == ["loop-a-1", "loop-b-1"])
        let left = try await r.lanesLeft()
        #expect(left.isEmpty, "\(left)")
        #expect(w.loop?.lanes == nil)
    }

    @Test func stopInTheMiddleCancelsEveryLaneAndIntegratesNothing() async throws {
        let r = try await ParRig([ptask("a", "test -f a.txt", scope: ["a.txt"]), ptask("b", "test -f b.txt", scope: ["b.txt"])])
        defer { r.cleanup() }
        let started = Arrivals(), forever = Forever()
        for n in ["loop-a-1", "loop-b-1"] {
            await r.core.set(n) { d in
                try "half\n".write(to: d.appendingPathComponent("half.txt"), atomically: true, encoding: .utf8)
                await started.hit(); await forever.wait()
            }
        }
        let run = Task { await r.run() }
        await started.wait(for: 2)
        let during = try await r.get()
        #expect(during.loop?.lanes?.map(\.task).sorted() == ["a", "b"])
        #expect(during.loop?.lanes?.allSatisfy { $0.phase == .agent } == true)
        #expect(during.loop?.task == during.loop?.lanes?.first?.task && during.loop?.phase == .agent, "the loop's own phase is the oldest lane's")
        await r.loop.stop(work: r.work)
        let end = await run.value
        #expect(end == .stopped)
        let w = try await r.get(), dismissed = await r.core.dismissed
        #expect(w.loop?.stopReason?.code == .requested)
        #expect(w.tasks.map(\.state) == [.open, .open] && w.tasks.allSatisfy { $0.tries == nil && $0.resumeFrom == nil })
        #expect(w.loop?.used == 0 && w.loop?.lanes == nil && w.loop?.phase == nil && w.loop?.task == nil)
        #expect(w.jobs.allSatisfy { $0.state != .running })
        #expect(dismissed.sorted() == ["loop-a-1", "loop-b-1"])
        let head = try await git(r.repo, "rev-parse", "HEAD"), status = try await git(r.repo, "status", "--porcelain")
        #expect(head == r.base && status.isEmpty, "the paddock's worktree was never touched")
        let left = try await r.lanesLeft()
        #expect(left.isEmpty, "\(left)")
        #expect(w.notes.last?.text == WorkLoopState.Stop(.requested).note)
    }

    @Test func aLaneThatFailsDoesNotBringTheOtherDown() async throws {
        let r = try await ParRig([ptask("a", "test -f a.txt", scope: ["a.txt"]), ptask("b", "test -f b.txt", scope: ["b.txt"])], tries: 1)
        defer { r.cleanup() }
        let both = Arrivals()
        await r.core.set("loop-a-1") { _ in await both.hit(); await both.wait(for: 2) }   // commits nothing
        await r.core.set("loop-b-1") { d in await both.hit(); await both.wait(for: 2); try await commit("b.txt", "b\n", in: d) }
        let end = await r.run()
        #expect(end == .finished)
        let w = try await r.get()
        #expect(w.tasks.map(\.state) == [.deferred, .done])
        #expect(w.tasks[0].lastFailure?.contains("no new commit") == true)
        #expect(r.has("b.txt") && !r.has("a.txt"))
        let left = try await r.lanesLeft()
        #expect(left.isEmpty)
    }

    @Test func anIntegrationConflictRedoesTheAttemptFromTheNewHead() async throws {
        // the scopes say disjoint, the agents both rewrite f.txt: the second merge conflicts
        let r = try await ParRig([ptask("a", "grep -q A f.txt || test -f a2.txt", scope: ["a.txt"]),
                                  ptask("b", "grep -q B f.txt || test -f b2.txt", scope: ["b.txt"])]); defer { r.cleanup() }
        let both = Arrivals(), seen = Seen()
        for (id, letter) in [("a", "A"), ("b", "B")] {
            await r.core.set("loop-\(id)-1") { d in await both.hit(); await both.wait(for: 2); try await commit("f.txt", "\(letter)\n", in: d) }
            await r.core.set("loop-\(id)-2") { d in
                await seen.set(id, (try? String(contentsOf: d.appendingPathComponent("f.txt"), encoding: .utf8)) ?? "?")
                try await commit("\(id)2.txt", "again\n", in: d)
            }
        }
        let end = await r.run()
        #expect(end == .finished)
        let w = try await r.get(), summoned = await r.core.summoned, items = await seen.items
        #expect(w.tasks.map(\.state) == [.done, .done])
        #expect(w.tasks.compactMap(\.tries).sorted() == [1, 2] && summoned.count == 3, "\(summoned)")
        let loser = try #require(w.tasks.first { $0.tries == 2 }), winner = try #require(w.tasks.first { $0.tries == 1 })
        let won = winner.id.uppercased() + "\n"
        #expect(items == [loser.id: won], "the second attempt started from the HEAD that has the other task's merge")
        let final = try String(contentsOf: r.repo.appendingPathComponent("f.txt"), encoding: .utf8)
        #expect(final == won && r.has("\(loser.id)2.txt"))
        let ev = w.loop?.events ?? []
        let retry = ev.filter { $0.kind == .integrationRetry }
        #expect(retry.count == 1 && retry.first?.task == loser.id && retry.first?.lane != nil && retry.first?.detail?.contains("merge conflict") == true)
        #expect(ev.filter { $0.kind == .integrated }.count == 2)
        #expect(w.notes.contains { $0.text.hasPrefix("[loop \(loser.id)] ") && $0.text.contains("merge conflict") }, "the next prompt carries why")
        #expect(w.loop?.used == 3)
        let patch = r.core.patches.appendingPathComponent(r.work.uuidString.lowercased()).appendingPathComponent("\(loser.id)-1.patch")
        #expect(FileManager.default.fileExists(atPath: patch.path), "what the undone attempt committed is kept as a patch")
        let status = try await git(r.repo, "status", "--porcelain", "--untracked-files=no"), left = try await r.lanesLeft()
        #expect(status.isEmpty && left.isEmpty)
    }

    @Test func theNewFieldsAreOptionalAndTolerant() throws {
        let dec = JSONDecoder(), enc = JSONEncoder()
        // a loop written before lanes existed
        let old = try enc.encode(WorkLoopState(tries: 2, max: 5))
        let text = String(decoding: old, as: UTF8.self)
        #expect(!text.contains("parallel") && !text.contains("lanes"), "nothing new is written without --parallel")
        let back = try dec.decode(WorkLoopState.self, from: old)
        #expect(back.parallel == nil && back.lanes == nil)
        // round trip
        var l = WorkLoopState(parallel: 3)
        l.lanes = [.init(lane: "lane-x-a", task: "a", attempt: 1, since: Date(timeIntervalSince1970: 10)),
                   .init(lane: "lane-x-b", task: "b", attempt: 2, since: Date(timeIntervalSince1970: 20))]
        l.showLane("lane-x-b", .check, at: Date(timeIntervalSince1970: 30))
        #expect(l.phase == nil && l.task == "a" && l.attempt == 1, "the loop's phase is the oldest lane's")
        l.showLane("lane-x-a", .gate, at: Date(timeIntervalSince1970: 40))
        #expect(l.phase == .gate && l.phaseSince == Date(timeIntervalSince1970: 40))
        #expect(try dec.decode(WorkLoopState.self, from: enc.encode(l)) == l)
        l.lanes = nil; l.mirror()
        #expect(l.phase == nil && l.task == nil)
        // malformed: the loop survives without them; a lane with a phase from the future keeps the rest
        var obj = try #require(JSONSerialization.jsonObject(with: old) as? [String: Any])
        obj["parallel"] = "many"; obj["lanes"] = "none"
        let odd = try dec.decode(WorkLoopState.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(odd.parallel == nil && odd.lanes == nil && odd.tries == 2)
        obj["lanes"] = [["lane": "lane-x-a", "task": "a", "phase": "integrating", "since": 5, "attempt": "x"]]
        let future = try dec.decode(WorkLoopState.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(future.lanes?.count == 1 && future.lanes?.first?.phase == nil && future.lanes?.first?.attempt == nil)
        // the journal
        let e = LoopEvent(at: Date(timeIntervalSince1970: 1), kind: .integrationRetry, task: "a", attempt: 1, detail: "merge conflict", lane: "lane-x-a")
        #expect(try dec.decode(LoopEvent.self, from: enc.encode(e)) == e)
        let plain = String(decoding: try enc.encode(LoopEvent(kind: .verdict)), as: UTF8.self)
        #expect(!plain.contains("lane"))
        #expect(try dec.decode(LoopEvent.Kind.self, from: Data(#""integrated""#.utf8)) == .integrated)
    }

    @Test func workRunDeclaresParallel() throws {
        let p = try #require(Commands.spec("work.run")?.params.first { $0.name == "parallel" })
        #expect(p.kind == .int && !p.required)
        #expect(TaskScheduler.maxParallel == 4)
    }
}
