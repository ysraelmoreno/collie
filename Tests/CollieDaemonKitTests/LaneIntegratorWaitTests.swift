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

/// The starter as the real host sees it (`CommandRouter.loopAnyoneWorking`): `open` requests in the daemon, `waits` of
/// them `work.wait`/`work.status` of this work. nil: not working.
private func starter(open: Int, waits: Int) -> String? {
    CommandRouter.loopStarterWaits(open: open, waitsOnWork: waits) ? nil : "Shepherd"
}

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
    func go(_ l: Lane, gate: String?) async throws -> LaneIntegrator.Result {
        try await integ.integrate(l, title: "A", attempt: 1, tries: 3, gate: gate, gateTimeout: .seconds(60))
    }
    func head() async throws -> String { try await git(repo, "rev-parse", "HEAD") }
    func status() async throws -> String { try await git(repo, "status", "--porcelain") }
    func destructive() async -> [[String]] { await host.gits.filter { $0.contains("reset") || $0.contains("clean") } }
    /// While the gate runs: the starter becomes `who`, and `also` happens in the tree.
    func duringTheGate(starter who: String?, busy other: String? = nil, _ also: @escaping @Sendable (URL) -> Void = { _ in }) async {
        let host = host, repo = repo
        await host.setProbe { _ in await host.setStarterBusy(who); await host.setBusy(other); also(repo) }
    }
}

private func isRetry(_ o: LaneIntegration.Outcome) -> Bool { if case .retryFromNewBase = o { true } else { false } }
private func isLeftDirty(_ o: LaneIntegration.Outcome) -> Bool { if case .leftDirty = o { true } else { false } }

/// A host with lanes for one loop (as `LaneIntegratorRaceTests`'s): the agent commits `a.txt` in its lane; the gate in
/// the paddock's worktree is `paddockGate`, after `disturb`. The starter is `starter` for `anyoneWorking`.
private struct WaitHost: LoopHost {
    let repo: URL, dir: URL, patches: URL, starter: String?, paddockGate: String
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
    func anyoneWorking() async -> String? { starter }
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
        WaitHost(repo: repo, dir: lane.path, patches: patches, starter: starter, paddockGate: paddockGate, disturb: disturb)
    }
}

private func runLoop(gate: String, starter: String? = nil, disturb: @escaping @Sendable (URL) -> Void = { _ in }) async throws -> (work: Work, repo: URL, base: String) {
    let repo = try await makeRepo(), base = try await git(repo, "rev-parse", "HEAD")
    let storeDir = URL(fileURLWithPath: "/tmp/collie-wait-loop-\(UUID().uuidString.prefix(8))")
    let store = WorkStore(dir: storeDir)
    let w = try await store.start(title: "W", terminal: UUID(), paddockId: UUID(), branch: "main")
    let task = WorkTask(id: "a", title: "Task a", check: "test -f a.txt", scope: ["a.txt"])
    try await store.update(w.id) {
        $0.tasks = [task]
        $0.loop = WorkLoopState(tries: 3, timeout: 60, max: 5, tasks: ["a"], gate: "true", parallel: 2)
    }
    let host = WaitHost(repo: repo, dir: repo, patches: storeDir.appendingPathComponent("patches"), starter: starter, paddockGate: gate, disturb: disturb)
    let loop = WorkLoop(store: store, host: host, poll: .milliseconds(10), checkTimeout: .seconds(30), othersWait: .milliseconds(50))
    _ = await loop.run(work: w.id, dir: repo)
    let end = try #require(try await store.get(w.id))
    try? FileManager.default.removeItem(at: storeDir)
    return (end, repo, base)
}

/// M3c.2: the Shepherd blocked in `collie work wait` is not working; what a gate leaves untracked stops nothing.
@Suite(.timeLimit(.minutes(3))) struct LaneIntegratorWaitTests {
    // MARK: the rule (the starter only waiting)

    @Test func theStarterWaitsOnlyWhenEveryOpenRequestIsAWaitOnTheWork() {
        #expect(CommandRouter.loopStarterWaits(open: 1, waitsOnWork: 1))
        #expect(CommandRouter.loopStarterWaits(open: 2, waitsOnWork: 2))
        #expect(!CommandRouter.loopStarterWaits(open: 0, waitsOnWork: 0), "no wait: its badge decides, as before")
        #expect(!CommandRouter.loopStarterWaits(open: 2, waitsOnWork: 1), "another command open (an ask): working")
        #expect(!CommandRouter.loopStarterWaits(open: 1, waitsOnWork: 0), "a wait on another work is not this one's")
    }

    /// The real daemon counts a parked `work.wait` of the caller's own work, and any other request of the terminal.
    @Test func theDaemonKnowsWhatTheStarterIsServing() async throws {
        try await withDaemon { d, p in
            let args: [String: JSONValue] = ["name": .string("Shepherd"), "preset": .string("shell"), "cwd": .string("/tmp")]
            let s = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
            guard case .object(let o)? = s.result, case .string(let id)? = o["id"], let me = UUID(uuidString: id) else { Issue.record("\(s)"); return }
            let token = try await tokenOf(d, id)
            func call(_ cmd: String, _ a: [String: JSONValue] = [:]) async throws -> Response {
                try await send(p, Request(id: "w", terminalId: id, token: token, command: cmd, args: a), timeoutSeconds: 60)
            }
            #expect(try await call("work.start", ["title": "Feature"]).ok)
            let store = d.router.work
            let w = try #require(try await store.active(terminal: me)), v = try #require(w.version)
            let router = d.router
            func waits(on work: UUID) async -> Bool {
                CommandRouter.loopStarterWaits(open: await router.openRequests[me] ?? 0, waitsOnWork: await router.ownWorkWaits[me]?[work] ?? 0)
            }
            #expect(!(await waits(on: w.id)), "nothing open")
            let wait = Task { try await call("work.wait", ["since": .number(Double(v)), "timeout": .number(3600)]) }
            var parked = false
            for _ in 0..<100_000 where !parked { parked = await store.changeWaiterCount == 1; await Task.yield() }
            #expect(parked)
            #expect(await waits(on: w.id), "only its wait on this work")
            #expect(!(await waits(on: UUID())), "not another work's")
            await router.requestBegan(me)   // another command of the starter's (an ask) is open meanwhile
            #expect(!(await waits(on: w.id)))
            await router.requestEnded(me)
            #expect(await waits(on: w.id))
            try await store.update(w.id) { $0.notes.append(WorkNote(text: "changed")) }
            #expect(try await wait.value.ok)
            let open = await router.openRequests[me], own = await router.ownWorkWaits[me]
            #expect(open == nil && own == nil, "nothing left counted")
        }
    }

    // MARK: the integrator, in a real repository

    @Test func theStarterOnlyWaitingDoesNotStopTheReset() async throws {
        let rig = try await Rig()
        let a = try await rig.lane("a", "a.txt", "a\n")
        let status = try await rig.status()
        await rig.duringTheGate(starter: starter(open: 1, waits: 1))
        let r = try await rig.go(a, gate: "exit 7")
        #expect(r.outcome == .retryFromNewBase("gate broke after the merge: gate failed (exit 7)"))
        #expect(r.blockedBy == nil && r.kept.isEmpty && r.undo == nil)
        #expect(try await rig.head() == rig.base, "the merge is undone")
        #expect(try await rig.status() == status)
        #expect(read("a.txt", in: rig.repo) == nil)
    }

    @Test func theStarterEditingStopsAsBefore() async throws {
        let rig = try await Rig()
        let a = try await rig.lane("a", "a.txt", "a\n")
        await rig.duringTheGate(starter: starter(open: 2, waits: 1))
        let r = try await rig.go(a, gate: "exit 7")
        #expect(isLeftDirty(r.outcome), "\(r.outcome)")
        #expect(r.blockedBy == "Shepherd" && r.undo == rig.base)
        let destructive = await rig.destructive()
        #expect(destructive.isEmpty, "\(destructive)")
        #expect(try await rig.head() != rig.base, "the merge stays for the owner to undo")
    }

    @Test func anotherTerminalOfThePaddockStops() async throws {
        let rig = try await Rig()
        let a = try await rig.lane("a", "a.txt", "a\n")
        await rig.duringTheGate(starter: starter(open: 1, waits: 1), busy: "dev")
        let r = try await rig.go(a, gate: "exit 7")
        #expect(isLeftDirty(r.outcome), "\(r.outcome)")
        #expect(r.blockedBy == "dev")
        let destructive = await rig.destructive()
        #expect(destructive.isEmpty, "\(destructive)")
    }

    @Test func aConflictWithTheStarterWaitingComesBackClean() async throws {
        let rig = try await Rig()
        let c = try await rig.lane("c", "f.txt", "from c\n"), d = try await rig.lane("d", "f.txt", "from d\n")
        #expect(try await rig.go(c, gate: nil).outcome == .integrated)
        let head = try await rig.head(), status = try await rig.status()
        await rig.host.setStarterBusy(starter(open: 1, waits: 1))
        let r = try await rig.go(d, gate: nil)
        #expect(isRetry(r.outcome), "\(r.outcome)")
        #expect(r.blockedBy == nil && r.kept.isEmpty)
        #expect(try await rig.head() == head)
        #expect(try await rig.status() == status)
        #expect(read("f.txt", in: rig.repo) == "from c\n")
    }

    /// M3b.2 does not regress: with the starter only waiting, what the owner edited during the gate stays untouched.
    @Test func theOwnersEditDuringTheGateStays() async throws {
        let rig = try await Rig()
        let a = try await rig.lane("a", "a.txt", "a\n")
        await rig.duringTheGate(starter: starter(open: 1, waits: 1)) { repo in
            write("the owner's\n", "f.txt", in: repo); write("notes\n", "notas.md", in: repo)
        }
        let r = try await rig.go(a, gate: "exit 7")
        #expect(isLeftDirty(r.outcome), "\(r.outcome)")
        #expect(r.kept == ["f.txt", "notas.md"] && r.blockedBy == nil && r.undo == rig.base)
        #expect(read("f.txt", in: rig.repo) == "the owner's\n")
        #expect(read("notas.md", in: rig.repo) == "notes\n")
        #expect(read("loose.txt", in: rig.repo) == "mine\n")
        let destructive = await rig.destructive()
        #expect(destructive.isEmpty, "\(destructive)")
    }

    // MARK: the loop

    @Test func aBrokenGateWithTheStarterWaitingIsRedoneFromTheNewHead() async throws {
        let once = FileManager.default.temporaryDirectory.appendingPathComponent("collie-wait-once-\(UUID().uuidString.prefix(8))").path
        defer { try? FileManager.default.removeItem(atPath: once) }
        let (w, repo, base) = try await runLoop(gate: "[ -f '\(once)' ] || { touch '\(once)'; exit 7; }", starter: starter(open: 1, waits: 1))
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(w.loop?.stopReason?.code != .othersWorking, "\(String(describing: w.loop?.stopReason))")
        #expect(w.tasks.first?.state == .done)
        #expect(try await git(repo, "log", "--first-parent", "--format=%s", "\(base)..HEAD") == "merge: Task a", "one merge stayed: the redone one")
        #expect(try await git(repo, "status", "--porcelain", "--untracked-files=no") == "")
    }

    @Test func anUntrackedFileFromAGateThatPassedDoesNotStopTheLoop() async throws {
        let (w, repo, _) = try await runLoop(gate: "echo report > report.txt")
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(w.tasks.first?.state == .done)
        #expect(w.loop?.stopReason?.code != .dirtyTree, "\(String(describing: w.loop?.stopReason))")
        // M3d.3: the gate's own file, unchanged, goes with the loop (it no longer blocks a later lane that adds it)
        #expect(read("report.txt", in: repo) == nil, "the gate's, removed at the loop's end")
        let note = w.notes.map(\.text).joined(separator: "\n")
        #expect(note.contains("report.txt") && note.contains("não rastreados"), "\(note)")
    }

    @Test func aTrackedFileEditedByAGateThatPassedStopsTheLoopWithANote() async throws {
        let (w, repo, _) = try await runLoop(gate: "echo formatted >> f.txt")
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(w.tasks.first?.state == .done)
        #expect(w.loop?.stopReason?.code == .dirtyTree)
        let note = w.notes.map(\.text).joined(separator: "\n")
        #expect(note.contains("f.txt") && note.contains("nada foi resetado nem apagado"), "\(note)")
        #expect(read("f.txt", in: repo) == "one\nformatted\n")
    }
}
