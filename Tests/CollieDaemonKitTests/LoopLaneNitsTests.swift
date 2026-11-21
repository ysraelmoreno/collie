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

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func spawnIn(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL, shepherd: Bool = false, paddock: String? = nil) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path), "shepherd": .bool(shepherd)]
    if let paddock { args["paddock"] = .string(paddock); args["cwd"] = nil }
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func call(_ d: Daemon, _ p: Paths, _ t: Term, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "w", terminalId: t.id, token: t.token, command: cmd, args: args), timeoutSeconds: 60)
}

/// What the test sees of the paddock's gate: when it started, and whether the lane was still on disk when it ended.
private actor Seen {
    var lanes: [URL] = [], laneAtGateEnd: Bool?, summoned: [String] = []
    private let started = AsyncStream<Void>.makeStream()
    func lane(_ u: URL) { lanes.append(u) }
    func gateStarted() { started.continuation.finish() }
    func gateEnded() { laneAtGateEnd = lanes.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } && !lanes.isEmpty }
    func summon(_ n: String) { summoned.append(n) }
    nonisolated func untilGate() async { for await _ in started.stream {} }
}

/// A host with lanes: the agent commits `a.txt` in its folder; the gate in the paddock's worktree (after the merge) is
/// `paddockGate`, a real process, preceded by `disturb`. `refuse`: names the summon refuses as taken.
private struct NitsHost: LoopHost {
    let repo: URL, dir: URL, patches: URL, paddockGate: String, seen: Seen, refuse: Set<String>
    let disturb: @Sendable (URL) -> Void
    func summon(name: String, for work: Work, loop: WorkLoopState) async throws(ProtocolError) -> UUID {
        await seen.summon(name)
        if refuse.contains(name) { throw ProtocolError(code: .invalidArgs, message: "terminal '\(name)' already exists; not leashed to you") }
        return UUID()
    }
    func ask(_ terminal: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> AskResult.Source {
        if prompt != WorkLoop.nudgePrompt {
            do { try await commit("a.txt", "a\n", in: dir) } catch { Issue.record("agent: \(error)") }
        }
        return .hook
    }
    func working(_ terminal: UUID) async -> Bool { false }
    func dismiss(_ terminal: UUID) async {}
    func othersWorking() async -> String? { nil }
    func starterAlive() async -> Bool { true }
    func git(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult { try await GitRunner.run(args, in: dir) }
    func check(_ command: String, in dir: URL, timeout: Duration) async throws(ProtocolError) -> ProcessResult {
        let paddock = dir == repo && command == "gate"
        if paddock { disturb(repo); await seen.gateStarted() }
        let r = try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/bash"), args: ["-c", paddock ? paddockGate : command == "gate" ? "true" : command],
                                             in: dir, env: ProcessInfo.processInfo.environment, timeout: timeout)
        if paddock { await seen.gateEnded() }
        return r
    }
    func readSpec(_ path: String) async -> String? { nil }
    func exists(_ path: String, in dir: URL) async -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path) }
    func patchDir(_ work: UUID) -> URL { patches.appendingPathComponent(work.uuidString.lowercased()) }
    func now() -> Date { Date() }
    func laneHost(_ lane: Lane) async throws(ProtocolError) -> any LoopHost {
        await seen.lane(lane.path)
        return NitsHost(repo: repo, dir: lane.path, patches: patches, paddockGate: paddockGate, seen: seen, refuse: refuse, disturb: disturb)
    }
}

/// One loop over task `a` (check `test -f a.txt`), in a temporary repo; `parallel` 2 gives it a lane, and the gate
/// `gate` runs as `paddockGate` in the paddock's worktree.
private struct LoopRun {
    let repo: URL, base: String, store: WorkStore, storeDir: URL, work: UUID, loop: WorkLoop, seen = Seen()
    init(parallel: Int?, paddockGate: String = "true", refuse: Set<String> = [], disturb: @escaping @Sendable (URL) -> Void = { _ in }) async throws {
        repo = try await makeRepo(); base = try await git(repo, "rev-parse", "HEAD")
        storeDir = URL(fileURLWithPath: "/tmp/collie-nits-\(UUID().uuidString.prefix(8))")
        store = WorkStore(dir: storeDir)
        let w = try await store.start(title: "W", terminal: UUID(), paddockId: UUID(), branch: "main")
        work = w.id
        let task = WorkTask(id: "a", title: "Task a", check: "test -f a.txt", scope: ["a.txt"])
        try await store.update(w.id) {
            $0.tasks = [task]
            $0.loop = WorkLoopState(tries: 3, timeout: 60, max: 5, tasks: ["a"], gate: "gate", parallel: parallel)
        }
        let host = NitsHost(repo: repo, dir: repo, patches: storeDir.appendingPathComponent("patches"), paddockGate: paddockGate,
                            seen: seen, refuse: refuse, disturb: disturb)
        loop = WorkLoop(store: store, host: host, poll: .milliseconds(10), checkTimeout: .seconds(600), othersWait: .milliseconds(50))
    }
    func get() async throws -> Work { try #require(try await store.get(work)) }
    func cleanup() { try? FileManager.default.removeItem(at: storeDir) }
}

/// M3b.6: the loose ends of the Onda 3 review (nits 6 and 8): `needs`/`scope` over MCP, the daemon's stop during an
/// integration, a name taken between `namesTaken` and the summon, and the integration test with no sleep.
@Suite(.serialized, .timeLimit(.minutes(3))) struct LoopLaneNitsTests {
    // MARK: 1. `needs` and `scope`: a string or an array of strings, anything else refused

    @Test func needsAndScopeTakeAStringOrAnArrayAndRefuseAnythingElse() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let m = try await spawnIn(d, p, "M", cwd: repo, shepherd: true)
            #expect(try await call(d, p, m, "paddock.create", ["name": .string("feat")]).ok)
            let s = try await spawnIn(d, p, "S", cwd: repo, shepherd: true, paddock: "feat")
            #expect(try await call(d, p, s, "work.start", ["title": .string("Nits")]).ok)
            func add(_ title: String, _ extra: [String: JSONValue]) async throws -> Response {
                try await call(d, p, s, "work.task.add", ["title": .string(title), "check": .string("true")].merging(extra) { $1 })
            }
            func ids(_ r: Response, _ k: String) -> [String]? {
                guard case .object(let o)? = r.result, case .array(let a)? = o[k] else { return nil }
                return a.compactMap { if case .string(let s) = $0 { s } else { nil } }
            }
            let a = try await add("A", [:])
            guard case .object(let o)? = a.result, case .string(let aId)? = o["id"] else { Issue.record("\(a)"); return }
            // an array (an MCP client)
            let b = try await add("B", ["needs": .array([.string(aId)]), "scope": .array([.string("b/**"), .string("c/*.txt")])])
            #expect(b.ok, "\(b)")
            #expect(ids(b, "needs") == [aId] && ids(b, "scope") == ["b/**", "c/*.txt"], "\(b)")
            // a string, comma-separated (the CLI's repeated flag)
            let c = try await add("C", ["needs": .string(aId), "scope": .string("d/**, e/**")])
            #expect(c.ok, "\(c)")
            #expect(ids(c, "needs") == [aId] && ids(c, "scope") == ["d/**", "e/**"], "\(c)")
            // a number, an object, an array with a number: refused, never dropped
            for (k, v) in [("needs", JSONValue.number(1)), ("scope", .object(["x": .string("y")])), ("needs", .array([.number(1)])), ("scope", .bool(true))] {
                let r = try await add("X", [k: v])
                #expect(!r.ok && r.error?.code == .invalidArgs, "\(k) \(v): \(r)")
                #expect(r.error?.message.contains("--\(k) must be a string or an array of strings") == true, "\(r)")
            }
            let w = try #require(try await d.router.work.active(terminal: s.uuid))
            #expect(w.tasks.map(\.title) == ["A", "B", "C"], "nothing refused was added")
        }
    }

    @Test func theMCPSchemaOfNeedsAndScopeSaysBoth() throws {
        let tool = MCPSchema.tools().first { if case .object(let o) = $0 { o["name"] == .string("work_task_add") } else { false } }
        guard case .object(let o)? = tool, case .object(let schema)? = o["inputSchema"], case .object(let props)? = schema["properties"] else {
            Issue.record("no work_task_add"); return
        }
        for k in ["needs", "scope"] {
            guard case .object(let prop)? = props[k], case .string(let help)? = prop["description"] else { Issue.record("no \(k)"); continue }
            #expect(prop["type"] == .string("string"), "the CLI's comma list stays the documented form")
            #expect(help.contains("array of strings"), help)
        }
    }

    // MARK: 2. the daemon's stop during an integration

    /// A gate that would run for ten minutes on the merged tree: the loop is cancelled while it runs. The gate is
    /// killed, the merge undone (the tree is exactly the HEAD of before), and the lane was still there when the gate
    /// ended: it goes only after the integration.
    @Test func cancelDuringTheIntegrationUndoesTheMergeBeforeTheLaneGoes() async throws {
        let r = try await LoopRun(parallel: 2, paddockGate: "sleep 600"); defer { r.cleanup() }
        let loop = r.loop, id = r.work, repo = r.repo
        let run = Task { _ = await loop.run(work: id, dir: repo) }
        await r.seen.untilGate()
        #expect(try await git(r.repo, "rev-parse", "HEAD") != r.base, "the merge is in while the gate runs")
        run.cancel()
        await run.value
        #expect(await r.seen.laneAtGateEnd == true, "the lane was removed before the integration ended")
        let lanes = await r.seen.lanes
        #expect(!lanes.isEmpty && lanes.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "the lane goes after it")
        #expect(try await git(r.repo, "rev-parse", "HEAD") == r.base, "the merge is undone")
        #expect(try await git(r.repo, "status", "--porcelain") == "", "no merge left half-way")
        let w = try await r.get()
        #expect(w.loop?.state == .stopped && w.loop?.stopReason == .init(.cancelled), "\(String(describing: w.loop))")
        #expect(w.tasks.first?.state == .open, "no verdict: the task is open again")
        #expect(w.loop?.lanes == nil)
    }

    /// The owner edits the paddock's worktree while the gate runs, then the loop is cancelled: nothing of theirs is
    /// reset, the merge stays in the branch and the note says how to undo it.
    @Test func cancelDuringTheIntegrationLeavesTheOwnersEdits() async throws {
        let r = try await LoopRun(parallel: 2, paddockGate: "sleep 600", disturb: { write("the owner's\n", "f.txt", in: $0) })
        defer { r.cleanup() }
        let loop = r.loop, id = r.work, repo = r.repo
        let run = Task { _ = await loop.run(work: id, dir: repo) }
        await r.seen.untilGate()
        run.cancel()
        await run.value
        #expect(read("f.txt", in: r.repo) == "the owner's\n", "the owner's edit stays")
        #expect(try await git(r.repo, "rev-parse", "HEAD") != r.base, "nothing was reset")
        let w = try await r.get()
        #expect(w.loop?.state == .stopped, "\(String(describing: w.loop))")
        let note = w.notes.map(\.text).first { $0.contains("nada foi resetado") }
        #expect(note?.contains("git reset --hard \(r.base.prefix(7))") == true, "\(w.notes.map(\.text))")
        #expect(w.tasks.first?.state == .open)
    }

    /// The integrator alone: its cancel kills the gate, and the merge is undone (the M3b.2 rule: the tree is as it left it).
    @Test func aCancelledIntegrationKillsItsGateAndUndoesTheMerge() async throws {
        let repo = try await makeRepo(), host = LoopFakeHost(dir: repo), base = try await git(repo, "rev-parse", "HEAD")
        let integ = LaneIntegrator(host: host, dir: repo)
        let lane = try await LaneWorktree.create(repoRoot: repo, base: base, work: UUID(), task: "a", host: host)
        try await commit("a.txt", "a\n", in: lane.path)
        let (started, go) = AsyncStream<Void>.makeStream()
        await host.setProbe { _ in go.finish() }
        let t = Task { try await integ.integrate(lane, title: "A", attempt: 1, tries: 3, gate: "sleep 600", gateTimeout: .seconds(600)) }
        for await _ in started {}
        t.cancel()
        let res = try await t.value
        if case .retryFromNewBase = res.outcome {} else { Issue.record("\(res.outcome)") }
        #expect(try await git(repo, "rev-parse", "HEAD") == base && res.head == base)
        #expect(try await git(repo, "status", "--porcelain") == "")
        // cancelled before it began: nothing is merged at all
        let t2 = Task { () async throws -> LaneIntegrator.Result in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await integ.integrate(lane, title: "A", attempt: 1, tries: 3, gate: "true", gateTimeout: .seconds(60))
        }
        let r2 = try await t2.value
        #expect(r2.outcome == .retryFromNewBase(LaneIntegrator.cancelled))
        #expect(try await git(repo, "rev-parse", "HEAD") == base)
    }

    /// Only the integrator's gate is killed by a cancel: anywhere else a process runs to its end, as before.
    @Test func killOnCancelIsOnlyWhereItIsAsked() async throws {
        let dir = FileManager.default.temporaryDirectory
        let killed = Task {
            try await BoundedProcess.$killOnCancel.withValue(true) {
                try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/bash"), args: ["-c", "sleep 600"], in: dir, env: [:], timeout: .seconds(600))
            }
        }
        killed.cancel()
        #expect(try await killed.value.status == 128 + SIGTERM)
        let plain = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/bash"), args: ["-c", "exit 3"], in: dir, env: [:], timeout: .seconds(60))
        }
        #expect(try await plain.value.status == 3)
    }

    // MARK: 3. a name taken between `namesTaken` and the summon

    @Test func aNameTheSummonRefusesAsTakenGivesWayToTheNextSuffix() async throws {
        let calls = Seen()
        func taken(_ n: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: "terminal '\(n)' already exists; not leashed to you") }
        // the base and `-2` are taken meanwhile (a terminal, then a panel): `-3` is summoned
        let id = try await AgentNaming.summon("w-a-t1", taskId: "abc12345", taken: []) { (n: String) async throws(ProtocolError) -> UUID in
            await calls.summon(n)
            if n == "w-a-t1" { throw taken(n) }
            if n == "w-a-t1-2" { throw ProtocolError(code: .invalidArgs, message: "'\(n)' is the name of panel 'P'") }
            return UUID()
        }
        _ = id
        #expect(await calls.summoned == ["w-a-t1", "w-a-t1-2", "w-a-t1-3"])
        // every name taken: up to the short id (M3.8's last), then the summon's own error
        let all = Seen()
        await #expect(throws: ProtocolError.self) {
            _ = try await AgentNaming.summon("w-a-t1", taskId: "abc12345", taken: []) { (n: String) async throws(ProtocolError) -> UUID in
                await all.summon(n); throw taken(n)
            }
        }
        #expect(await all.summoned == ["w-a-t1"] + (2...9).map { "w-a-t1-\($0)" } + ["w-a-t1-abc12345"])
        // any other refusal is not a name's: no retry
        let other = Seen()
        await #expect(throws: ProtocolError.self) {
            _ = try await AgentNaming.summon("w-a-t1", taskId: "abc12345", taken: []) { (n: String) async throws(ProtocolError) -> UUID in
                await other.summon(n); throw ProtocolError(code: .unauthorized, message: "'\(n)' started without a sandbox")
            }
        }
        #expect(await other.summoned == ["w-a-t1"])
    }

    /// In the loop: the attempt's summon is refused for its name, and the next suffix is summoned instead (the attempt
    /// does not fail for it).
    @Test func theLoopsSummonRetriesWithTheNextSuffix() async throws {
        let r = try await LoopRun(parallel: nil, refuse: ["w-task-a-t1"]); defer { r.cleanup() }
        _ = await r.loop.run(work: r.work, dir: r.repo)
        #expect(await r.seen.summoned == ["w-task-a-t1", "w-task-a-t1-2"])
        let w = try await r.get()
        #expect(w.tasks.first?.state == .done, "\(w.notes.map(\.text))")
    }

    // MARK: 4. the integration test waits with no clock

    @Test func laneIntegrationTestsHaveNoSleep() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("LaneIntegrationTests.swift")
        let text = try String(contentsOf: here, encoding: .utf8)
        #expect(!text.contains("Task.sleep"))
        #expect(text.contains("untilWaiting"))
    }
}
