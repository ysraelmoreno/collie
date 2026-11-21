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

private actor Seen {
    var items: [String: String] = [:]
    func set(_ k: String, _ v: String) { items[k] = v }
}

/// The only fake: the agents. Each is scripted by `<task title>#<attempt>`, read from the prompt the engine wrote
/// (so the key does not depend on how the loop names its terminals), and works in the folder it was summoned in.
private actor Agents {
    nonisolated let patches = URL(fileURLWithPath: "/tmp/collie-e2e-patches-\(UUID().uuidString.prefix(8))")
    private var scripts: [String: @Sendable (URL) async throws -> Void] = [:]
    private var born: [UUID: URL] = [:]
    /// "start <key>" / "end <key>", in the order the agents' turns began and ended.
    var log: [String] = []
    /// Where each agent worked.
    var dirs: [String: URL] = [:]
    /// Every command the engine ran as a check or a gate, and where.
    var checks: [(command: String, dir: URL)] = []
    var made: [String] = [], gone: [String] = [], dismissed = 0
    func set(_ key: String, _ act: @escaping @Sendable (URL) async throws -> Void) { scripts[key] = act }
    func summon(_ dir: URL) -> UUID { let id = UUID(); born[id] = dir; return id }
    func ask(_ terminal: UUID, _ prompt: String) async {
        guard prompt != WorkLoop.nudgePrompt, let dir = born[terminal],
              let m = prompt.firstMatch(of: #/Tarefa "([^"]+)", tentativa (\d+) de/#) else { return }
        let key = "\(m.1)#\(m.2)"
        log.append("start \(key)"); dirs[key] = dir
        do { try await scripts[key]?(dir) } catch { Issue.record("agent \(key): \(error)") }
        log.append("end \(key)")
    }
    func dismiss() { dismissed += 1 }
    func ran(_ command: String, _ dir: URL) { checks.append((command, dir)) }
    func laneMade(_ l: Lane) { made.append(l.path.lastPathComponent) }
    func laneGone(_ l: Lane) { gone.append(l.path.lastPathComponent) }
}

/// Real git and a real check, in the paddock's worktree or in one lane; only the agent is scripted.
private struct E2EHost: LoopHost {
    let agents: Agents, dir: URL
    func summon(name: String, for work: Work, loop: WorkLoopState) async throws(ProtocolError) -> UUID { await agents.summon(dir) }
    func ask(_ terminal: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> AskResult.Source {
        await agents.ask(terminal, prompt)
        return .hook
    }
    func working(_ terminal: UUID) async -> Bool { false }
    func dismiss(_ terminal: UUID) async { await agents.dismiss() }
    func othersWorking() async -> String? { nil }
    func starterAlive() async -> Bool { true }
    func git(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult { try await GitRunner.run(args, in: dir) }
    func check(_ command: String, in dir: URL, timeout: Duration) async throws(ProtocolError) -> ProcessResult {
        await agents.ran(command, dir)
        return try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/bash"), args: ["-c", command], in: dir,
                                            env: ProcessInfo.processInfo.environment, timeout: timeout)
    }
    func readSpec(_ path: String) async -> String? { nil }
    func exists(_ path: String, in dir: URL) async -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path) }
    func patchDir(_ work: UUID) -> URL { agents.patches.appendingPathComponent(work.uuidString.lowercased()) }
    func now() -> Date { Date() }
    func laneHost(_ lane: Lane) async throws(ProtocolError) -> any LoopHost {
        await agents.laneMade(lane)
        return E2EHost(agents: agents, dir: lane.path)
    }
    func laneGone(_ lane: Lane) async { await agents.laneGone(lane) }
}

/// A real repository of its own (the paddock's worktree), a store with a work whose loop asks for `parallel`, and the
/// real engine over them. The gate, when asked, writes the subject of the HEAD it judged to `gateLog` (outside the repo).
private struct Rig {
    let repo: URL, storeDir: URL, gateLog: URL, store: WorkStore, agents = Agents(), loop: WorkLoop, work: UUID, base: String, gate: String?
    init(_ tasks: [WorkTask], parallel: Int? = 2, tries: Int = 3, gated: Bool = false) async throws {
        repo = try await makeRepo()
        base = try await git(repo, "rev-parse", "HEAD")
        let tag = UUID().uuidString.prefix(8)
        storeDir = URL(fileURLWithPath: "/tmp/collie-e2e-\(tag)")
        gateLog = URL(fileURLWithPath: "/tmp/collie-e2e-gate-\(tag).log")
        let gate = gated ? "git log -1 --format=%s >> \(gateLog.path)" : nil
        self.gate = gate
        store = WorkStore(dir: storeDir)
        let w = try await store.start(title: "W", terminal: UUID(), paddockId: UUID(), branch: "main")
        try await store.update(w.id) {
            $0.tasks = tasks
            $0.loop = WorkLoopState(tries: tries, timeout: 60, max: 12, tasks: tasks.map(\.id), gate: gate, parallel: parallel)
        }
        work = w.id
        loop = WorkLoop(store: store, host: E2EHost(agents: agents, dir: repo), poll: .milliseconds(10),
                        checkTimeout: .seconds(30), othersWait: .milliseconds(50))
    }
    func run() async -> WorkLoopState.State { await loop.run(work: work, dir: repo) }
    func get() async throws -> Work { try #require(try await store.get(work)) }
    func has(_ file: String) -> Bool { FileManager.default.fileExists(atPath: repo.appendingPathComponent(file).path) }
    func read(_ file: String) -> String { (try? String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)) ?? "?" }
    /// The subjects of the paddock's branch, newest first.
    func subjects() async throws -> [String] { try await git(repo, "log", "--format=%s").split(separator: "\n").map(String.init) }
    func merges() async throws -> [String] { try await git(repo, "log", "--merges", "--format=%s").split(separator: "\n").map(String.init) }
    /// What the gate judged, in order.
    func gated() -> [String] {
        ((try? String(contentsOf: gateLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    /// Every trace of a lane in the repository: branches, worktrees besides the paddock's, folders.
    func lanesLeft() async throws -> [String] {
        let refs = try await git(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/collie/lane/")
        let trees = try await git(repo, "worktree", "list", "--porcelain").split(separator: "\n").filter { $0.hasPrefix("worktree ") }.dropFirst()
        let dir = repo.appendingPathComponent("\(LegacyOrq.repoDirName(repoRoot: repo))/paddocks")
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return refs.split(separator: "\n").map(String.init) + trees.map(String.init) + folders
    }
    /// The paddock's worktree is whole: no tracked file modified, no merge left open.
    func expectWhole() async throws {
        let status = try await git(repo, "status", "--porcelain", "--untracked-files=no")
        #expect(status.isEmpty, "\(status)")
        #expect(!has(".git/MERGE_HEAD"), "a merge was left half done")
    }
    func cleanup() { for u in [repo, storeDir, gateLog, agents.patches] { try? FileManager.default.removeItem(at: u) } }
}

/// A task whose title is its id (the agents are keyed by title).
private func task(_ id: String, _ check: String, scope: [String]?, needs: [String]? = nil) -> WorkTask {
    WorkTask(id: id, title: id, check: check, needs: needs, scope: scope)
}

/// The set of (a) and (f): two tasks of disjoint scope, each adding its own file.
private let disjoint = [task("a", "test -f a.txt", scope: ["a.txt"]), task("b", "test -f b.txt", scope: ["b.txt"])]

/// M3.7: the parallel loop end to end. The real engine (scheduler, lanes, integrator) over a real temporary repository
/// per test; only the agent is fake (it writes files and commits where it was summoned). No sleep, no clock.
@Suite(.timeLimit(.minutes(3))) struct LoopParallelE2ETests {
    // (a)
    @Test func twoDisjointTasksRunTogetherAndBothAreIntegrated() async throws {
        let r = try await Rig(disjoint, gated: true); defer { r.cleanup() }
        // each agent only goes on once both are in their turn: in series this would never end
        let both = Arrivals()
        for id in ["a", "b"] {
            await r.agents.set("\(id)#1") { d in await both.hit(); await both.wait(for: 2); try await commit("\(id).txt", "\(id)\n", in: d) }
        }
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks.map(\.state) == [.done, .done] && w.tasks.map(\.tries) == [1, 1])
        #expect(r.has("a.txt") && r.has("b.txt"))
        // the history: the two commits and two merges, over the commit the loop started from
        let subjects = try await r.subjects(), merges = try await r.merges()
        #expect(subjects.sorted() == ["edit a.txt", "edit b.txt", "init", "merge: a", "merge: b"], "\(subjects)")
        #expect(merges.sorted() == ["merge: a", "merge: b"])
        // the gate: once in each lane (the attempt's), and again in the paddock's worktree after each merge
        let gate = try #require(r.gate), checks = await r.agents.checks
        #expect(r.gated().sorted() == ["edit a.txt", "edit b.txt", "merge: a", "merge: b"], "\(r.gated())")
        #expect(checks.filter { $0.command == gate && $0.dir == r.repo }.count == 2)
        #expect(checks.filter { $0.command != gate }.allSatisfy { LaneWorktree.isLane($0.dir) }, "a task's check runs in its lane")
        // each agent worked in a lane of its own, and no lane is left
        let dirs = await r.agents.dirs, made = await r.agents.made, gone = await r.agents.gone, left = try await r.lanesLeft()
        #expect(Set(dirs.values.map(\.path)).count == 2 && dirs.values.allSatisfy { $0 != r.repo && LaneWorktree.isLane($0) }, "\(dirs)")
        #expect(left.isEmpty, "\(left)")
        #expect(made.count == 2 && made.sorted() == gone.sorted() && w.loop?.lanes == nil)
        try await r.expectWhole()
    }

    // (b)
    @Test func overlappingScopesRunInSeriesEvenWithParallelTwo() async throws {
        let r = try await Rig([task("a", "test -f src/a.txt", scope: ["src/**"]), task("b", "test -f src/b.txt", scope: ["src/b.txt"])])
        defer { r.cleanup() }
        for id in ["a", "b"] {
            await r.agents.set("\(id)#1") { d in
                try FileManager.default.createDirectory(at: d.appendingPathComponent("src"), withIntermediateDirectories: true)
                try await commit("src/\(id).txt", "\(id)\n", in: d)
            }
        }
        #expect(await r.run() == .finished)
        let log = await r.agents.log, w = try await r.get(), ev = w.loop?.events ?? []
        #expect(w.loop?.parallel == 2)
        #expect(log == ["start a#1", "end a#1", "start b#1", "end b#1"], "one at a time: \(log)")
        let merged = try #require(ev.firstIndex { $0.kind == .integrated && $0.task == "a" })
        let began = try #require(ev.firstIndex { $0.kind == .attemptStarted && $0.task == "b" })
        #expect(merged < began, "b's lane is cut only after a is integrated")
        #expect(w.tasks.map(\.state) == [.done, .done] && r.has("src/a.txt") && r.has("src/b.txt"))
        let left = try await r.lanesLeft()
        #expect(left.isEmpty, "\(left)")
        try await r.expectWhole()
    }

    // (c)
    @Test func theSecondToChangeTheSameLineConflictsAndPassesFromTheNewHead() async throws {
        // the scopes say disjoint, so the two run together; both rewrite the one line of f.txt
        let r = try await Rig([task("a", "grep -q A f.txt", scope: ["a.txt"]), task("b", "grep -q B f.txt", scope: ["b.txt"])])
        defer { r.cleanup() }
        let both = Arrivals(), seen = Seen()
        for (id, letter) in [("a", "A"), ("b", "B")] {
            await r.agents.set("\(id)#1") { d in await both.hit(); await both.wait(for: 2); try await commit("f.txt", "\(letter)\n", in: d) }
            await r.agents.set("\(id)#2") { d in
                let now = (try? String(contentsOf: d.appendingPathComponent("f.txt"), encoding: .utf8)) ?? "?"
                await seen.set(id, now)
                try await commit("f.txt", now + "\(letter)\n", in: d)
            }
        }
        #expect(await r.run() == .finished)
        let w = try await r.get(), items = await seen.items, log = await r.agents.log
        #expect(w.tasks.map(\.state) == [.done, .done])
        #expect(w.tasks.compactMap(\.tries).sorted() == [1, 2], "the second passed on its 2nd attempt")
        let loser = try #require(w.tasks.first { $0.tries == 2 }), winner = try #require(w.tasks.first { $0.tries == 1 })
        let won = winner.id.uppercased() + "\n"
        #expect(items == [loser.id: won], "the 2nd attempt was cut from the HEAD that has the other task's merge")
        #expect(r.read("f.txt") == won + loser.id.uppercased() + "\n")
        #expect(log.filter { $0.hasPrefix("start") }.count == 3 && w.loop?.used == 3)
        // the conflicting merge was undone before anything else happened to the paddock's worktree
        let ev = w.loop?.events ?? [], retry = ev.filter { $0.kind == .integrationRetry }
        #expect(retry.count == 1 && retry.first?.task == loser.id && retry.first?.detail?.contains("merge conflict") == true, "\(retry)")
        #expect(ev.filter { $0.kind == .integrated }.count == 2)
        let merges = try await r.merges(), left = try await r.lanesLeft()
        #expect(merges.sorted() == ["merge: a", "merge: b"], "the undone merge left no commit: \(merges)")
        #expect(left.isEmpty, "\(left)")
        try await r.expectWhole()
    }

    // (d)
    @Test func aDependentStartsOnlyAfterTheIntegrationAndSeesItsCode() async throws {
        let r = try await Rig([task("a", "test -f a.txt", scope: ["a.txt"]), task("b", "test -f b.txt", scope: ["b.txt"], needs: ["a"])])
        defer { r.cleanup() }
        let seen = Seen()
        await r.agents.set("a#1") { try await commit("a.txt", "from a\n", in: $0) }
        await r.agents.set("b#1") { d in
            await seen.set("a.txt", (try? String(contentsOf: d.appendingPathComponent("a.txt"), encoding: .utf8)) ?? "missing")
            await seen.set("log", (try? await git(d, "log", "--format=%s")) ?? "?")
            try await commit("b.txt", "b\n", in: d)
        }
        #expect(await r.run() == .finished)
        let log = await r.agents.log, items = await seen.items, w = try await r.get(), ev = w.loop?.events ?? []
        #expect(log == ["start a#1", "end a#1", "start b#1", "end b#1"], "disjoint scopes, yet in order: \(log)")
        #expect(items["a.txt"] == "from a\n", "b's lane has a's code")
        #expect(items["log"]?.hasPrefix("merge: a\n") == true, "b's lane was cut from a's merge: \(items["log"] ?? "")")
        let merged = try #require(ev.firstIndex { $0.kind == .integrated && $0.task == "a" })
        let began = try #require(ev.firstIndex { $0.kind == .attemptStarted && $0.task == "b" })
        #expect(merged < began)
        #expect(w.tasks.map(\.state) == [.done, .done])
        let left = try await r.lanesLeft()
        #expect(left.isEmpty, "\(left)")
    }

    // (e)
    @Test func aStopInTheMiddleLeavesNoLaneAndNothingHalfIntegrated() async throws {
        let r = try await Rig(disjoint + [task("c", "test -f c.txt", scope: ["c.txt"], needs: ["b"])], gated: true); defer { r.cleanup() }
        let forever = Forever()
        await r.agents.set("a#1") { try await commit("a.txt", "a\n", in: $0) }
        // b commits what would pass, and its turn never ends
        await r.agents.set("b#1") { d in try await commit("b.txt", "b\n", in: d); await forever.wait() }
        let run = Task { await r.run() }
        // a is whole in the paddock's branch (no clock: the store says when the work changed)
        var v = try #require(try await r.store.version(r.work))
        while try await r.get().tasks[0].state != .done { v = try #require(try await r.store.changed(r.work, since: v)) }
        #expect(try await r.get().loop?.lanes?.contains { $0.task == "b" } == true, "b is still in its lane")
        await r.loop.stop(work: r.work)   // what `collie work stop` asks of the engine
        #expect(await run.value == .stopped)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .requested && w.loop?.stopReason == .init(.requested))
        #expect(w.tasks.map(\.state) == [.done, .open, .open], "a integrated before the stop; b got no verdict; c never began")
        #expect(w.tasks[1].tries == nil && w.loop?.used == 1, "b's attempt is not counted")
        #expect(w.loop?.lanes == nil && w.loop?.task == nil && w.loop?.phase == nil)
        #expect(w.jobs.allSatisfy { $0.state != .running })
        // integrated whole or not at all: a's merge is the HEAD, b's commit never reached the branch
        let subjects = try await r.subjects(), left = try await r.lanesLeft(), log = await r.agents.log
        #expect(subjects == ["merge: a", "edit a.txt", "init"], "\(subjects)")
        #expect(r.has("a.txt") && !r.has("b.txt"))
        #expect(r.gated().last == "merge: a", "the gate judged a's merge, and nothing after it")
        #expect(!log.contains("start c#1"))
        #expect(left.isEmpty, "\(left)")
        try await r.expectWhole()
    }

    // (f)
    /// What a run left, without what differs from one run to another by nature (shas, temp paths).
    private func shape(_ r: Rig) async throws -> [String] {
        func plain(_ s: String) -> String {
            s.replacingOccurrences(of: r.gateLog.path, with: "<gate>").replacingOccurrences(of: r.repo.path, with: "<repo>")
                .replacingOccurrences(of: r.agents.patches.path, with: "<patches>")
                .replacingOccurrences(of: "\\b[0-9a-f]{7,40}\\b", with: "#", options: .regularExpression)
        }
        let w = try await r.get()
        var out = w.tasks.map { t in
            "task \(t.id) \(t.state.rawValue) tries=\(t.tries ?? 0) last=\(t.lastFailure ?? "-") reason=\(t.reason ?? "-") "
                + "evidence=\(t.evidence.map { "\($0.attempt)/\($0.commits.count)/\($0.shortstat)" } ?? "-")"
        }
        out += w.notes.map { "note " + plain($0.text) }
        out += (w.loop?.events ?? []).map { "event \($0.kind.rawValue) \($0.task ?? "-") \($0.attempt ?? 0) \(plain($0.detail ?? "-")) lane=\($0.lane ?? "-")" }
        out += w.jobs.map { "job \($0.id) \($0.state.rawValue) \(plain($0.result ?? "-"))" }
        if let l = w.loop {
            out.append("loop \(l.state.rawValue) used=\(l.used) task=\(l.task ?? "-") phase=\(l.phase?.rawValue ?? "-") "
                + "stop=\(l.stopReason?.code.rawValue ?? "-") lanes=\(l.lanes?.count ?? -1)")
        }
        out += await r.agents.log.map { "agent \($0)" }
        out += await r.agents.checks.map { "ran \(plain($0.command)) in \(plain($0.dir.path))" }
        out += try await r.subjects().map { "commit \($0)" }
        out += r.gated().map { "gated \($0)" }
        return out
    }

    /// The set of (a) with `parallel` nil (the loop before lanes) or 1.
    private func oneAtATime(parallel: Int?) async throws -> [String] {
        let r = try await Rig(disjoint, parallel: parallel, gated: true); defer { r.cleanup() }
        for id in ["a", "b"] { await r.agents.set("\(id)#1") { try await commit("\(id).txt", "\(id)\n", in: $0) } }
        #expect(await r.run() == .finished)
        let made = await r.agents.made, dirs = await r.agents.dirs, left = try await r.lanesLeft()
        #expect(made.isEmpty && left.isEmpty && dirs.values.allSatisfy { $0 == r.repo }, "no lane: the agents work in the paddock's worktree")
        return try await shape(r)
    }

    @Test func parallelOneOfTheSameSetIsTheOldLoop() async throws {
        let old = try await oneAtATime(parallel: nil), one = try await oneAtATime(parallel: 1)
        #expect(old == one)
        // and it is the old loop's result: both done in order, a straight history, no merge, no lane in the journal
        #expect(one.filter { $0.hasPrefix("task") }.map { String($0.prefix(19)) } == ["task a done tries=1", "task b done tries=1"])
        #expect(one.filter { $0.hasPrefix("agent") } == ["agent start a#1", "agent end a#1", "agent start b#1", "agent end b#1"])
        #expect(one.filter { $0.hasPrefix("commit") } == ["commit edit b.txt", "commit edit a.txt", "commit init"])
        #expect(one.filter { $0.hasPrefix("gated") } == ["gated edit a.txt", "gated edit b.txt"], "the gate once per task, never after a merge")
        #expect(one.filter { $0.hasPrefix("event") }.allSatisfy { $0.hasSuffix("lane=-") } && !one.contains { $0.contains("integrated") })
        #expect(one.contains { $0.hasPrefix("loop finished used=2") && $0.hasSuffix("lanes=-1") }, "\(one)")
    }

    // (g)
    @Test func aLaneThatFailsThreeTimesIsDeferredAndTheOtherIntegrates() async throws {
        let r = try await Rig(disjoint, tries: 3); defer { r.cleanup() }
        let both = Arrivals()
        await r.agents.set("a#1") { d in await both.hit(); await both.wait(for: 2); try await commit("wrong1.txt", "x\n", in: d) }
        for n in [2, 3] { await r.agents.set("a#\(n)") { try await commit("wrong\(n).txt", "x\n", in: $0) } }
        await r.agents.set("b#1") { d in await both.hit(); await both.wait(for: 2); try await commit("b.txt", "b\n", in: d) }
        #expect(await r.run() == .finished)
        let w = try await r.get(), log = await r.agents.log, made = await r.agents.made, gone = await r.agents.gone
        #expect(w.tasks.map(\.state) == [.deferred, .done])
        #expect(w.tasks[0].tries == 3 && w.tasks[0].reason?.hasPrefix("loop: ") == true && w.tasks[0].lastFailure != nil, "\(w.tasks[0])")
        #expect(log.filter { $0.hasPrefix("start a#") } == ["start a#1", "start a#2", "start a#3"] && w.loop?.used == 4)
        #expect(w.tasks[1].tries == 1 && w.tasks[1].evidence?.commits.count == 1)
        // b is in the branch as if a had never run; nothing of a's three lanes reached it
        let subjects = try await r.subjects(), left = try await r.lanesLeft()
        #expect(subjects == ["merge: b", "edit b.txt", "init"], "\(subjects)")
        #expect(r.has("b.txt") && !(1...3).contains { r.has("wrong\($0).txt") })
        #expect(made.count == 4 && made.sorted() == gone.sorted(), "a lane per attempt, each removed")
        #expect(left.isEmpty, "\(left)")
        try await r.expectWhole()
    }

    // MARK: the documentation

    /// Tests/CollieDaemonKitTests/<this file>: the repository is three levels up.
    private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func theLoopCommandSaysWhenToRunInParallel() {
        for md in [LoopCommand.markdown(arguments: true), LoopCommand.markdown(arguments: false)] {
            for must in ["--parallel", "--scope", "--needs",
                         // the exclusive scope rule
                         "Two tasks run at the same time only when their scopes do not overlap",
                         "a task with no scope is exclusive: it runs alone",
                         // when, when not, the default
                         "independent and long", "the same file", "Package.swift", "One task at a time is the default (--parallel 1)"] {
                #expect(md.contains(must), "\(must)")
            }
            #expect(!md.contains("`"))   // still no inline shell
        }
    }

    @Test func theReferenceHasTheNewCommands() throws {
        let ref = try String(contentsOf: repoRoot.appendingPathComponent("docs/referencia.md"), encoding: .utf8)
        for must in ["work run --parallel", "work task add", "--needs", "--scope", "work wait", "work task reopen", "work status --events",
                     "escopo exclusivo", "compilação a frio", "scripts/dev/lane-coldbuild.sh", "máximo 4"] {
            #expect(ref.contains(must), "docs/referencia.md: \(must)")
        }
        let map = try String(contentsOf: repoRoot.appendingPathComponent("docs/feature-map.md"), encoding: .utf8)
        #expect(map.contains("--parallel") && map.contains("faixa"))
        #expect(FileManager.default.isExecutableFile(atPath: repoRoot.appendingPathComponent("scripts/dev/lane-coldbuild.sh").path))
    }
}
