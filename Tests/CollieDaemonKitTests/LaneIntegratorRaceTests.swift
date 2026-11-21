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

private func write(_ text: String, _ file: String, in dir: URL) {
    do { try text.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8) } catch { Issue.record("write \(file): \(error)") }
}
private func read(_ file: String, in dir: URL) -> String? { try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8) }

/// The paddock's worktree with one untracked file of the owner's (`loose.txt`), a fake host and the integrator.
private struct Rig {
    let repo: URL, host: LoopFakeHost, integ: LaneIntegrator, base: String, work = UUID()
    init() async throws {
        repo = try await makeRepo(); host = LoopFakeHost(dir: repo)
        integ = LaneIntegrator(host: host, dir: repo)
        base = try await git(repo, "rev-parse", "HEAD")
        write("mine\n", "loose.txt", in: repo)
    }
    func lane(_ task: String, _ file: String, _ text: String) async throws -> Lane {
        let l = try await LaneWorktree.create(repoRoot: repo, base: base, work: work, task: task, host: host)
        try await commit(file, text, in: l.path)
        return l
    }
    func go(_ l: Lane, attempt: Int = 1, tries: Int = 3, gate: String?) async throws -> LaneIntegrator.Result {
        try await integ.integrate(l, title: "A", attempt: attempt, tries: tries, gate: gate, gateTimeout: .seconds(60))
    }
    func head() async throws -> String { try await git(repo, "rev-parse", "HEAD") }
    func status() async throws -> String { try await git(repo, "status", "--porcelain") }
    /// The git commands that throw work away, as the integrator ran them.
    func destructive() async -> [[String]] { await host.gits.filter { $0.contains("reset") || $0.contains("clean") } }
    /// The owner (or their Shepherd) edits a tracked file and makes a new one while the gate runs.
    func ownerEditsDuringTheGate() async {
        let repo = repo
        await host.setProbe { _ in write("the owner's\n", "f.txt", in: repo); write("notes\n", "notas.md", in: repo) }
    }
}

private func isRetry(_ o: LaneIntegration.Outcome) -> Bool { if case .retryFromNewBase = o { true } else { false } }
private func isLeftDirty(_ o: LaneIntegration.Outcome) -> Bool { if case .leftDirty = o { true } else { false } }

/// A host with lanes for one loop: the agent commits `<task>.txt` in its lane; the gate, when it runs in the paddock's
/// worktree (after the merge), is preceded by `disturb` (what the owner does meanwhile).
private struct RaceHost: LoopHost {
    let repo: URL, dir: URL, patches: URL, starterBusy: String?, paddockGate: String
    let disturb: @Sendable (URL) -> Void
    func summon(name: String, for work: Work, loop: WorkLoopState) async throws(ProtocolError) -> UUID { UUID() }
    func ask(_ terminal: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> AskResult.Source {
        if prompt != WorkLoop.nudgePrompt, dir != repo {
            do { try await commit("a.txt", "a\n", in: dir) } catch { Issue.record("agent: \(error)") }
        }
        return .hook
    }
    func working(_ terminal: UUID) async -> Bool { false }
    func dismiss(_ terminal: UUID) async {}
    func othersWorking() async -> String? { nil }
    func anyoneWorking() async -> String? { starterBusy }
    func starterAlive() async -> Bool { true }
    func git(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult { try await GitRunner.run(args, in: dir) }
    func check(_ command: String, in dir: URL, timeout: Duration) async throws(ProtocolError) -> ProcessResult {
        if dir == repo { disturb(repo) }
        return try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/bash"), args: ["-c", dir == repo ? paddockGate : command], in: dir,
                                            env: ProcessInfo.processInfo.environment, timeout: timeout)
    }
    func readSpec(_ path: String) async -> String? { nil }
    func exists(_ path: String, in dir: URL) async -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path) }
    func patchDir(_ work: UUID) -> URL { patches.appendingPathComponent(work.uuidString.lowercased()) }
    func now() -> Date { Date() }
    func laneHost(_ lane: Lane) async throws(ProtocolError) -> any LoopHost {
        RaceHost(repo: repo, dir: lane.path, patches: patches, starterBusy: starterBusy, paddockGate: paddockGate, disturb: disturb)
    }
}

/// One task in a parallel loop whose gate passes in the lane and, in the paddock's worktree, is `gate` run after `disturb`.
private func runLoop(gate: String, starterBusy: String? = nil, disturb: @escaping @Sendable (URL) -> Void) async throws -> (work: Work, repo: URL, base: String) {
    let repo = try await makeRepo(), base = try await git(repo, "rev-parse", "HEAD")
    let storeDir = URL(fileURLWithPath: "/tmp/collie-race-\(UUID().uuidString.prefix(8))")
    let store = WorkStore(dir: storeDir)
    let w = try await store.start(title: "W", terminal: UUID(), paddockId: UUID(), branch: "main")
    let task = WorkTask(id: "a", title: "Task a", check: "test -f a.txt", scope: ["a.txt"])
    try await store.update(w.id) {
        $0.tasks = [task]
        $0.loop = WorkLoopState(tries: 3, timeout: 60, max: 5, tasks: ["a"], gate: "true", parallel: 2)
    }
    let host = RaceHost(repo: repo, dir: repo, patches: storeDir.appendingPathComponent("patches"), starterBusy: starterBusy, paddockGate: gate, disturb: disturb)
    let loop = WorkLoop(store: store, host: host, poll: .milliseconds(10), checkTimeout: .seconds(30), othersWait: .milliseconds(50))
    _ = await loop.run(work: w.id, dir: repo)
    let end = try #require(try await store.get(w.id))
    try? FileManager.default.removeItem(at: storeDir)
    return (end, repo, base)
}

/// M3b.2: the integrator measures again before it throws anything away. What the owner (or the starter) did in the
/// paddock's worktree while the gate ran stays, and the loop stops saying so.
@Suite(.timeLimit(.minutes(3))) struct LaneIntegratorRaceTests {
    typealias F = LaneIntegration.Facts

    @Test func decideLeavesADisturbedTreeAlone() {
        func f(_ m: LaneIntegration.Merge, _ g: LaneIntegration.Gate, _ attempt: Int = 1) -> LaneIntegration.Outcome {
            LaneIntegration.decide(F(mergeResult: m, gateAfterMerge: g, treeClean: true, attempt: attempt, tries: 3, detail: "x", disturbed: true))
        }
        #expect(f(.clean, .failed) == .leftDirty("gate broke after the merge: x"))
        #expect(f(.clean, .failed, 3) == .leftDirty("gate broke after the merge: x"), "never a defer: it is not the task's fault")
        #expect(f(.conflict, .notRun, 3) == .leftDirty("merge conflict: x"))
        // nothing is reset when the gate passed: the merge stands
        #expect(f(.clean, .passed) == .integrated)
        #expect(f(.noop, .notRun) == .noop)
    }

    /// (a) and (d): the gate breaks, and meanwhile a tracked file was edited and a new file made.
    @Test func brokenGateResetsNothingTheOwnerDidMeanwhile() async throws {
        let rig = try await Rig()
        let a = try await rig.lane("a", "a.txt", "a\n")
        await rig.ownerEditsDuringTheGate()
        let r = try await rig.go(a, gate: "exit 7")
        #expect(r.outcome == .leftDirty("gate broke after the merge: gate failed (exit 7)"))
        #expect(r.kept == ["f.txt", "notas.md"], "what stayed, without the owner's older untracked file")
        #expect(r.blockedBy == nil)
        #expect(read("f.txt", in: rig.repo) == "the owner's\n")
        #expect(read("notas.md", in: rig.repo) == "notes\n")
        #expect(read("loose.txt", in: rig.repo) == "mine\n")
        let destructive = await rig.destructive()
        #expect(destructive.isEmpty, "\(destructive)")
        // the merge is not undone (that takes a reset): the result says where the branch was
        let head = try await rig.head()
        #expect(head != rig.base && r.head == head)
        #expect(r.undo == rig.base)
        // on the last try too: never a defer
        let rig2 = try await Rig()
        let b = try await rig2.lane("a", "a.txt", "a\n")
        await rig2.ownerEditsDuringTheGate()
        let last = try await rig2.go(b, attempt: 3, tries: 3, gate: "exit 7")
        #expect(isLeftDirty(last.outcome), "\(last.outcome)")
    }

    /// (a), a new untracked file alone is enough.
    @Test func aNewUntrackedFileAloneKeepsTheTree() async throws {
        let rig = try await Rig()
        let a = try await rig.lane("a", "a.txt", "a\n")
        let repo = rig.repo
        await rig.host.setProbe { _ in write("notes\n", "notas.md", in: repo) }
        let r = try await rig.go(a, gate: "false")
        #expect(isLeftDirty(r.outcome), "\(r.outcome)")
        #expect(r.kept == ["notas.md"])
        #expect(read("notas.md", in: rig.repo) == "notes\n")
    }

    /// (b): the starter is in a turn in the paddock's worktree when the gate ends: its edits may be on their way.
    @Test func theStarterWorkingKeepsTheTree() async throws {
        let rig = try await Rig()
        let a = try await rig.lane("a", "a.txt", "a\n")
        let host = rig.host
        await host.setProbe { _ in await host.setStarterBusy("Shepherd") }
        let r = try await rig.go(a, gate: "exit 7")
        #expect(r.outcome == .leftDirty("gate broke after the merge: gate failed (exit 7)"))
        #expect(r.blockedBy == "Shepherd")
        #expect(r.kept.isEmpty)
        let destructive = await rig.destructive()
        #expect(destructive.isEmpty, "\(destructive)")
        let head = try await rig.head()
        #expect(head != rig.base)
        // the starter does not stop a merge from starting (as before): only what would be thrown away is guarded
        let rig2 = try await Rig()
        let b = try await rig2.lane("a", "a.txt", "a\n")
        await rig2.host.setStarterBusy("Shepherd")
        let ok = try await rig2.go(b, gate: "true")
        #expect(ok.outcome == .integrated)
    }

    /// (b): the real host counts the starter when asked about anyone, and not when asked about the others.
    @Test func anyoneCountsTheStarter() {
        let paddock = UUID(), starter = UUID(), dir = URL(fileURLWithPath: "/tmp/collie-race-paddock")
        func term(_ id: UUID, _ name: String) -> TerminalRecord {
            TerminalRecord(id: id, name: name, preset: .shell, command: nil, cwd: dir.path, isShepherd: false, paddockId: paddock)
        }
        let all = [term(starter, "starter"), term(UUID(), "dev")]
        #expect(CommandRouter.loopReaching(all, paddock: paddock, starter: starter, dir: dir).map(\.name) == ["dev"])
        #expect(CommandRouter.loopReaching(all, paddock: paddock, starter: nil, dir: dir).map(\.name) == ["starter", "dev"])
    }

    /// (c) and (d): nobody touched the tree, so the merge is undone as before, and the owner's untracked file stays.
    @Test func untouchedTreeIsRestoredAsBefore() async throws {
        let rig = try await Rig()
        let a = try await rig.lane("a", "a.txt", "a\n")
        let status = try await rig.status()
        let r = try await rig.go(a, gate: "echo broke; exit 7")
        #expect(r.outcome == .retryFromNewBase("gate broke after the merge: gate failed (exit 7)"))
        #expect(r.kept.isEmpty && r.blockedBy == nil && r.undo == nil)
        #expect(r.head == rig.base)
        let head = try await rig.head(), after = try await rig.status()
        #expect(head == rig.base)
        #expect(after == status)
        #expect(read("a.txt", in: rig.repo) == nil)
        #expect(read("loose.txt", in: rig.repo) == "mine\n")
        let destructive = await rig.destructive()
        #expect(destructive.contains { $0.contains("reset") && $0.contains(rig.base) })
        // a gate that moved HEAD and left nothing else: undone too
        let moved = try await rig.go(a, gate: "git commit -q --allow-empty -m sneaky")
        #expect(moved.outcome == .retryFromNewBase("gate broke after the merge: gate moved HEAD"))
        let back = try await rig.head()
        #expect(back == rig.base)
        // and a conflict: undone, the tree exactly as it was
        let c = try await rig.lane("c", "f.txt", "from c\n"), d = try await rig.lane("d", "f.txt", "from d\n")
        let first = try await rig.go(c, gate: nil)
        #expect(first.outcome == .integrated)
        let merged = try await rig.head()
        let conflict = try await rig.go(d, gate: nil)
        #expect(isRetry(conflict.outcome), "\(conflict.outcome)")
        let still = try await rig.head(), clean = try await rig.status()
        #expect(still == merged)
        #expect(clean == status)
        #expect(read("f.txt", in: rig.repo) == "from c\n")
    }

    /// The success path throws nothing away either: a gate that passed leaves the merge and whatever is in the tree.
    @Test func passedGateKeepsWhatChangedMeanwhile() async throws {
        let rig = try await Rig()
        let a = try await rig.lane("a", "a.txt", "a\n")
        await rig.ownerEditsDuringTheGate()
        let r = try await rig.go(a, gate: "true")
        #expect(r.outcome == .integrated)
        #expect(r.kept == ["f.txt", "notas.md"])
        #expect(r.undo == nil)
        #expect(read("f.txt", in: rig.repo) == "the owner's\n")
        #expect(read("notas.md", in: rig.repo) == "notes\n")
        let subject = try await git(rig.repo, "log", "-1", "--format=%s")
        #expect(subject == "merge: A")
        // and with nothing changed there is nothing to restore: no reset at all
        let rig2 = try await Rig()
        let b = try await rig2.lane("a", "a.txt", "a\n")
        let ok = try await rig2.go(b, gate: "true")
        #expect(ok.outcome == .integrated && ok.kept.isEmpty)
        let destructive = await rig.destructive() + (await rig2.destructive())
        #expect(destructive.isEmpty, "\(destructive)")
    }

    /// (a) in the loop: it stops with `dirtyTree`, the note names what stayed, the task is open and its attempt is back.
    @Test func theLoopStopsAndSaysWhatStayed() async throws {
        let (w, repo, base) = try await runLoop(gate: "exit 7") { repo in
            write("the owner's\n", "f.txt", in: repo); write("notes\n", "notas.md", in: repo)
        }
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(w.loop?.state == .stopped)
        #expect(w.loop?.stopReason?.code == .dirtyTree)
        #expect(w.loop?.used == 0)
        #expect(w.tasks.first?.state == .open)
        let note = w.notes.map(\.text).joined(separator: "\n")   // the loop's own stop note comes last
        #expect(note.contains("f.txt") && note.contains("notas.md"), "\(note)")
        #expect(note.contains("nada foi resetado nem apagado"), "\(note)")
        #expect(note.contains(String(base.prefix(7))), "how to undo the merge by hand: \(note)")
        #expect(read("f.txt", in: repo) == "the owner's\n")
        #expect(read("notas.md", in: repo) == "notes\n")
    }

    /// (b) in the loop: the starter in a turn stops it with `othersWorking`, naming it.
    @Test func theLoopStopsNamingTheStarter() async throws {
        let (w, repo, _) = try await runLoop(gate: "exit 7", starterBusy: "Shepherd") { _ in }
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(w.loop?.state == .stopped)
        #expect(w.loop?.stopReason?.code == .othersWorking)
        #expect(w.loop?.stopReason?.detail == "Shepherd")
        #expect(w.loop?.used == 0)
        #expect(w.tasks.first?.state == .open)
        let note = w.notes.map(\.text).joined(separator: "\n")   // the loop's own stop note comes last
        #expect(note.contains("'Shepherd'") && note.contains("nada foi resetado nem apagado"), "\(note)")
        #expect(read("a.txt", in: repo) == "a\n", "the merge was not undone")
    }

    /// The gate passed with the tree changed: the task is done, and the loop stops before the next merge would refuse it.
    @Test func theLoopStopsAfterAnIntegrationThatKeptEdits() async throws {
        let (w, repo, _) = try await runLoop(gate: "true") { repo in write("the owner's\n", "f.txt", in: repo) }
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(w.tasks.first?.state == .done)
        #expect(w.loop?.stopReason?.code == .dirtyTree)
        let note = w.notes.map(\.text).joined(separator: "\n")   // the loop's own stop note comes last
        #expect(note.contains("f.txt") && note.contains("nada foi resetado nem apagado"), "\(note)")
        #expect(read("f.txt", in: repo) == "the owner's\n")
    }
}
