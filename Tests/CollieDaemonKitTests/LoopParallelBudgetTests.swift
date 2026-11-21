import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Counts arrivals; `wait(for:)` returns once `n` came.
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

/// True for the first caller only.
private actor Once {
    private var taken = false
    func first() -> Bool { defer { taken = true }; return !taken }
}

/// The host's clock: it stands still until a test moves it. No wall clock: the seconds asserted are exact.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var extra: TimeInterval = 0
    var now: Date { lock.withLock { Date(timeIntervalSince1970: 1_000_000 + extra) } }
    func advance(_ s: Int) { lock.withLock { extra += TimeInterval(s) } }
}

/// An agent's turn: the worktree and the seconds the turn was given. True: the turn ran until its limit (it timed out).
private typealias Turn = @Sendable (URL, Int) async throws -> Bool

/// What the paddock's host and every lane's share: the scripted agents (by name, without the lane's `-f<n>`) and the
/// seconds each turn and each check was given.
private actor BudgetCore {
    nonisolated let patches = URL(fileURLWithPath: "/tmp/collie-budget-patches-\(UUID().uuidString.prefix(8))")
    private var scripts: [String: Turn] = [:], agents: [UUID: (name: String, dir: URL)] = [:]
    var summoned: [String] = [], turns: [String: Int] = [:], checks: [String: Int] = [:]
    func set(_ name: String, _ act: @escaping Turn) { scripts[name] = act }
    func summon(_ full: String, _ dir: URL) -> UUID {
        let name = full.replacingOccurrences(of: #"-f\d+(-t\d+)$"#, with: "$1", options: .regularExpression)
        let id = UUID(); agents[id] = (name, dir); summoned.append(name)
        return id
    }
    /// True: the turn timed out.
    func ask(_ terminal: UUID, _ prompt: String, _ limit: Int) async -> Bool {
        guard prompt != WorkLoop.nudgePrompt, let a = agents[terminal] else { return false }
        turns[a.name] = limit
        do { return try await scripts[a.name]?(a.dir, limit) ?? false } catch { Issue.record("agent \(a.name): \(error)"); return false }
    }
    func checked(_ command: String, _ limit: Int) { checks[command] = limit }
}

/// Scripted agents, real git and a real check, in the paddock's worktree or in one lane, on the fake clock.
private struct BudgetHost: LoopHost {
    let core: BudgetCore, clock: FakeClock, dir: URL
    func summon(name: String, for work: Work, loop: WorkLoopState) async throws(ProtocolError) -> UUID { await core.summon(name, dir) }
    func ask(_ terminal: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> AskResult.Source {
        if await core.ask(terminal, prompt, Int(timeout.components.seconds)) { throw ProtocolError(code: .timeout, message: "ask timed out") }
        return .hook
    }
    func working(_ terminal: UUID) async -> Bool { false }
    func dismiss(_ terminal: UUID) async {}
    func othersWorking() async -> String? { nil }
    func starterAlive() async -> Bool { true }
    func git(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult { try await GitRunner.run(args, in: dir) }
    func check(_ command: String, in dir: URL, timeout: Duration) async throws(ProtocolError) -> ProcessResult {
        await core.checked(command, Int(timeout.components.seconds))
        // the limit is what the test reads; the command itself is instant and runs with time to spare
        return try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/bash"), args: ["-c", command], in: dir,
                                            env: ProcessInfo.processInfo.environment, timeout: .seconds(30))
    }
    func readSpec(_ path: String) async -> String? { nil }
    func exists(_ path: String, in dir: URL) async -> Bool { false }
    func patchDir(_ work: UUID) -> URL { core.patches.appendingPathComponent(work.uuidString.lowercased()) }
    func now() -> Date { clock.now }
    func laneHost(_ lane: Lane) async throws(ProtocolError) -> any LoopHost { BudgetHost(core: core, clock: clock, dir: lane.path) }
}

/// A repo, a work whose loop has `budget` and `parallel`, the host and the loop. Turns and checks may take 600 s: only
/// the budget bounds them here.
private struct BudgetRig {
    let repo: URL, storeDir: URL, store: WorkStore, core = BudgetCore(), clock = FakeClock(), loop: WorkLoop, work: UUID
    init(_ tasks: [WorkTask], parallel: Int?, budget: Int) async throws {
        repo = try await makeRepo()
        storeDir = URL(fileURLWithPath: "/tmp/collie-budget-\(UUID().uuidString.prefix(8))")
        store = WorkStore(dir: storeDir)
        let w = try await store.start(title: "W", terminal: UUID(), paddockId: UUID(), branch: "main")
        try await store.update(w.id) {
            $0.tasks = tasks
            $0.loop = WorkLoopState(tries: 3, timeout: 600, budget: budget, tasks: tasks.map(\.id), parallel: parallel)
        }
        work = w.id
        loop = WorkLoop(store: store, host: BudgetHost(core: core, clock: clock, dir: repo), poll: .milliseconds(10),
                        checkTimeout: .seconds(600), othersWait: .milliseconds(50))
    }
    func run() async -> WorkLoopState.State { await loop.run(work: work, dir: repo) }
    func get() async throws -> Work { try #require(try await store.get(work)) }
    func cleanup() { for u in [repo, storeDir, core.patches] { try? FileManager.default.removeItem(at: u) } }
}

private func btask(_ id: String, needs: [String]? = nil, scoped: Bool = true) -> WorkTask {
    WorkTask(id: id, title: "Task \(id)", check: "test -f \(id).txt", needs: needs, scope: scoped ? ["\(id).txt"] : nil)
}

/// M3b.4: `--budget` counts the lanes alive. Before, each lane was given all that was left when it began, and
/// `--budget 600 --parallel 4` could spend 2400 s.
@Suite(.timeLimit(.minutes(3))) struct LoopParallelBudgetTests {
    /// The slack the loop declares (`laneShare`): a phase keeps the limit it began with. Here: one turn of one of four lanes.
    static let slack = 25

    @Test func fourLanesShareOneBudget() async throws {
        let r = try await BudgetRig(["a", "b", "c", "d"].map { btask($0) }, parallel: 4, budget: 100); defer { r.cleanup() }
        let all = Arrivals(), once = Once(), forever = Forever(), clock = r.clock, core = r.core
        for id in ["a", "b", "c", "d"] {
            await r.core.set("w-task-\(id)-t1") { _, limit in
                await all.hit(); await all.wait(for: 4)
                // the four spend at once: the shortest limit runs out first, as a real host's timeout would (one turn
                // moves the clock: the 25 s pass for the four)
                guard limit == (await core.turns.values.min()), await once.first() else { await forever.wait(); return false }
                clock.advance(limit)
                return true
            }
        }
        let end = await r.run()
        #expect(end == .stopped)
        let w = try await r.get(), turns = await r.core.turns, summoned = await r.core.summoned
        // the last lane to ask saw the four alive: a quarter of the budget, and none got more than all of it
        #expect(turns.count == 4 && turns.values.min() == 25 && turns.values.allSatisfy { $0 <= 100 }, "\(turns)")
        #expect(w.loop?.stopReason?.code == .budgetSpent)
        // the sum of the lanes' time is the budget: 4 × 25, not 4 × 100
        let spent = w.loop?.spent ?? 0
        #expect(spent >= 100 && spent <= 100 + Self.slack, "\(spent)")
        // the task whose turn timed out is open again, and no lane began for it on a spent budget
        #expect(summoned.count == 4, "\(summoned)")
        #expect(w.tasks.allSatisfy { $0.state == .open } && w.tasks.compactMap(\.tries) == [1], "\(w.tasks.map(\.tries))")
        #expect(w.loop?.used == 1 && w.loop?.lanes == nil, "the three lanes cancelled are not counted")
        #expect(w.notes.contains { $0.text.contains("orçamento de tempo usado (100 de 100 s") }, "\(w.notes.map(\.text))")
    }

    @Test func noLaneStartsOnASpentBudget() async throws {
        let r = try await BudgetRig(["a", "b", "c"].map { btask($0) }, parallel: 2, budget: 100); defer { r.cleanup() }
        let started = Arrivals(), forever = Forever(), clock = r.clock
        // a takes 50 s while b is in its turn too: 50 + 50. Counting only the lanes that ended (50), c would start
        await r.core.set("w-task-a-t1") { d, _ in await started.wait(for: 1); clock.advance(50); try await commit("a.txt", "a\n", in: d); return false }
        await r.core.set("w-task-b-t1") { _, _ in await started.hit(); await forever.wait(); return false }
        let end = await r.run()
        #expect(end == .stopped)
        let w = try await r.get(), summoned = await r.core.summoned, checks = await r.core.checks
        #expect(w.loop?.stopReason?.code == .budgetSpent)
        #expect(summoned.sorted() == ["w-task-a-t1", "w-task-b-t1"], "c never ran: \(summoned)")
        #expect(w.tasks.map(\.state) == [.done, .open, .open] && w.tasks[1].tries == nil && w.tasks[2].tries == nil)
        // a's check saw b's 50 s too: nothing was left (1 s, the least a phase gets), not the 50 s of a alone
        #expect(checks["test -f a.txt"] == 1, "\(checks)")
        #expect(w.loop?.spent == 100 && w.loop?.lanes == nil, "\(w.loop?.spent ?? -1)")
    }

    @Test func aLanesTimeIsAddedToSpentOnce() async throws {
        // b needs a: one lane after the other, so every second is exact
        let r = try await BudgetRig([btask("a"), btask("b", needs: ["a"])], parallel: 2, budget: 500); defer { r.cleanup() }
        let clock = r.clock, store = r.store, work = r.work
        await r.core.set("w-task-a-t1") { d, _ in clock.advance(30); try await commit("a.txt", "a\n", in: d); return false }
        await r.core.set("w-task-b-t1") { d, _ in
            // a ended: its 30 s are in `spent` and it is no longer a lane (never in both)
            let loop = try #require(try await store.get(work)?.loop)
            #expect(loop.spent == 30 && loop.lanes?.map(\.task) == ["b"])
            #expect(WorkLoop.unspent(loop, now: clock.now) == 470)
            clock.advance(10); try await commit("b.txt", "b\n", in: d); return false
        }
        let end = await r.run()
        #expect(end == .finished)
        let w = try await r.get(), turns = await r.core.turns, checks = await r.core.checks
        #expect(w.tasks.map(\.state) == [.done, .done])
        #expect(w.loop?.spent == 40 && w.loop?.lanes == nil, "30 + 10, each once: \(w.loop?.spent ?? -1)")
        // a lane alone gets all that is left, as a sequential attempt does
        #expect(turns == ["w-task-a-t1": 500, "w-task-b-t1": 470], "\(turns)")
        #expect(checks == ["test -f a.txt": 470, "test -f b.txt": 460], "\(checks)")
    }

    /// `--parallel 1` (or none) with `--budget`: the loop as it always was, each phase given `budget − spent − its own time`.
    private func sequential(parallel: Int?) async throws -> [String] {
        let r = try await BudgetRig(["a", "b", "c"].map { btask($0, scoped: false) }, parallel: parallel, budget: 100); defer { r.cleanup() }
        let clock = r.clock
        await r.core.set("w-task-a-t1") { d, _ in clock.advance(30); try await commit("a.txt", "a\n", in: d); return false }
        await r.core.set("w-task-b-t1") { d, _ in clock.advance(80); try await commit("b.txt", "b\n", in: d); return false }
        let end = await r.run()
        let w = try await r.get(), turns = await r.core.turns, checks = await r.core.checks, summoned = await r.core.summoned
        let lanes = try await GitRunner.run(["for-each-ref", "refs/heads/collie/lane/"], in: r.repo).stdout
        return ["end \(end.rawValue) stop=\(w.loop?.stopReason?.code.rawValue ?? "-") spent=\(w.loop?.spent ?? -1) used=\(w.loop?.used ?? -1)",
                "tasks \(w.tasks.map { "\($0.id)=\($0.state.rawValue)" }.joined(separator: " "))", "summoned \(summoned)",
                "turns \(turns.sorted { $0.key < $1.key })", "checks \(checks.sorted { $0.key < $1.key })", "lanes [\(lanes)]",
                "notes \(w.notes.map(\.text))"]
    }

    @Test func parallelOneWithABudgetIsTheLoopAsItAlwaysWas() async throws {
        let old = try await sequential(parallel: nil), one = try await sequential(parallel: 1)
        #expect(old == one)
        // the numbers of before this task: a's turn 100, its check 100 − 30; b's turn 100 − 30, its check the least (1 s)
        #expect(old.contains(#"turns [(key: "w-task-a-t1", value: 100), (key: "w-task-b-t1", value: 70)]"#), "\(old)")
        #expect(old.contains(#"checks [(key: "test -f a.txt", value: 70), (key: "test -f b.txt", value: 1)]"#), "\(old)")
        #expect(old[0] == "end stopped stop=budgetSpent spent=110 used=2", "\(old[0])")
        #expect(old[1] == "tasks a=done b=done c=open" && old.contains("lanes []"))
        #expect(old.last?.contains("orçamento de tempo usado (110 de 100 s); laço parado") == true, "\(old.last ?? "")")
    }

    @Test func unspentCountsEveryLaneAliveOnce() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var l = WorkLoopState(budget: 100, parallel: 4)
        #expect(WorkLoop.unspent(l, now: now) == 100)
        l.spent = 10
        l.lanes = [.init(lane: "lane-x-a", task: "a", since: now - 20, started: now - 20),
                   .init(lane: "lane-x-b", task: "b", since: now - 30, started: now - 30)]
        #expect(WorkLoop.unspent(l, now: now) == 40, "100 − 10 − (20 + 30)")
        // a phase change moves `since`, never when the lane began
        l.showLane("lane-x-a", .check, at: now)
        #expect(l.lanes?.first?.since == now && WorkLoop.unspent(l, now: now) == 40)
        l.lanes?[1].started = nil   // a lane written before the field: `since` stands in
        #expect(WorkLoop.unspent(l, now: now) == 40)
        l.spent = 70
        #expect(WorkLoop.unspent(l, now: now) == -20, "spent: zero or less")
        #expect(WorkLoop.unspent(WorkLoopState(parallel: 4), now: now) == nil, "no budget")
        // the new field is optional and tolerant
        let enc = JSONEncoder(), dec = JSONDecoder()
        let plain = WorkLoopState.LaneState(lane: "lane-x-a", task: "a", since: now)
        #expect(!String(decoding: try enc.encode(plain), as: UTF8.self).contains("started"))
        #expect(try dec.decode(WorkLoopState.LaneState.self, from: enc.encode(l.lanes![0])) == l.lanes![0])
        var obj = try #require(JSONSerialization.jsonObject(with: enc.encode(plain)) as? [String: Any])
        obj["started"] = "yesterday"
        let odd = try dec.decode(WorkLoopState.LaneState.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(odd.started == nil && odd.lane == "lane-x-a")
    }
}
