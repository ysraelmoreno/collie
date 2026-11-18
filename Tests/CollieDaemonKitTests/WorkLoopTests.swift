import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// What one attempt's "agent" does, keyed by its terminal name (`loop-<task>-<n>`).
private struct Script: Sendable {
    /// Runs during `ask`, in the worktree.
    var act: @Sendable (URL) async throws -> Void = { _ in }
    var source: AskResult.Source = .hook
    var askError: ProtocolError?
    /// `.idle` ends: `working` stays true and nothing is committed until its `n`-th call, which runs `late`.
    var lateAfter: Int?
    var late: @Sendable (URL) async throws -> Void = { _ in }
}

/// A host without PTYs: scripted agents, real git and a real (unsandboxed) check in a temp repo.
private actor FakeHost: LoopHost {
    nonisolated let dir: URL, patches: URL
    var scripts: [String: Script] = [:]
    var summoned: [String] = [], dismissed: [String] = [], prompts: [String: String] = [:], checks = 0
    /// Every command `check` ran (the tasks' checks and the gate), in order.
    var commands: [String] = []
    /// In order: "dismiss <name>", "check".
    var events: [String] = []
    /// Another terminal of the paddock in a turn (blocks the loop's reset).
    var busyOther: String?
    /// The starter is gone once the attempt with this name asked.
    var starterGoneAfter: String?
    private var starterGone = false
    private var names: [UUID: String] = [:], workingCalls: [UUID: Int] = [:]

    init(dir: URL) {
        self.dir = dir
        patches = URL(fileURLWithPath: "/tmp/collie-loop-patches-\(UUID().uuidString.prefix(8))")
    }
    func set(_ name: String, _ s: Script) { scripts[name] = s }

    func summon(name: String, for work: Work, loop: WorkLoopState) async throws(ProtocolError) -> UUID {
        let id = UUID(); names[id] = name; summoned.append(name); return id
    }
    func ask(_ terminal: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> AskResult.Source {
        let name = names[terminal]!, s = scripts[name] ?? Script()
        prompts[name] = prompt
        do { try await s.act(dir) } catch { Issue.record("agent \(name): \(error)") }
        if name == starterGoneAfter { starterGone = true }
        if let e = s.askError { throw e }
        return s.source
    }
    func working(_ terminal: UUID) async -> Bool {
        let name = names[terminal]!, s = scripts[name] ?? Script()
        guard let after = s.lateAfter else { return false }
        let n = (workingCalls[terminal] ?? 0) + 1; workingCalls[terminal] = n
        if n == after { do { try await s.late(dir) } catch { Issue.record("late \(name): \(error)") }; return false }
        return n < after
    }
    func dismiss(_ terminal: UUID) async { dismissed.append(names[terminal] ?? "?"); events.append("dismiss \(names[terminal] ?? "?")") }
    func othersWorking() async -> String? { busyOther }
    func starterAlive() async -> Bool { !starterGone }
    func setBusy(_ n: String?) { busyOther = n }
    func setStarterGone(after n: String) { starterGoneAfter = n }
    func git(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult { try await GitRunner.run(args, in: dir) }
    func check(_ command: String, in dir: URL, timeout: Duration) async throws(ProtocolError) -> ProcessResult {
        checks += 1; events.append("check"); commands.append(command)
        return try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/bash"), args: ["-c", command], in: dir,
                                            env: ProcessInfo.processInfo.environment, timeout: timeout)
    }
    func readSpec(_ path: String) async -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    nonisolated func patchDir(_ work: UUID) -> URL { patches.appendingPathComponent(work.uuidString.lowercased()) }
    nonisolated func now() -> Date { Date() }
}

private func git(_ dir: URL, _ args: String...) async throws -> String {
    let r = try await GitRunner.run(args, in: dir)
    #expect(r.status == 0, "git \(args): \(r.stderr)")
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A repo, a store holding a work with `tasks` and a running loop, a fake host and the loop.
private struct Rig {
    let repo: URL, storeDir: URL, store: WorkStore, host: FakeHost, loop: WorkLoop, work: UUID
    init(_ tasks: [WorkTask], tries: Int = 3, max: Int? = nil, budget: Int? = nil, gate: String? = nil,
         checkTimeout: Duration = .seconds(30)) async throws {
        repo = try await makeRepo()
        storeDir = URL(fileURLWithPath: "/tmp/collie-loop-\(UUID().uuidString.prefix(8))")
        store = WorkStore(dir: storeDir)
        let w = try await store.start(title: "W", terminal: UUID(), paddockId: UUID(), branch: "main")
        try await store.update(w.id) {
            $0.tasks = tasks
            $0.loop = WorkLoopState(tries: tries, timeout: 60, max: max, budget: budget, tasks: tasks.map(\.id), gate: gate)
        }
        work = w.id
        host = FakeHost(dir: repo)
        loop = WorkLoop(store: store, host: host, poll: .milliseconds(10), checkTimeout: checkTimeout)
    }
    func run() async -> WorkLoopState.State { await loop.run(work: work, dir: repo) }
    func get() async throws -> Work { try #require(try await store.get(work)) }
    func cleanup() { for u in [repo, storeDir, host.patches] { try? FileManager.default.removeItem(at: u) } }
}

private func task(_ id: String, _ check: String) -> WorkTask { WorkTask(id: id, title: "Task \(id)", check: check) }

@Suite struct WorkLoopTests {
    @Test func passesOnFirstAttempt() async throws {
        let r = try await Rig([task("a", "test -f done.txt")]); defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .done && w.tasks[0].tries == 1)
        #expect(w.loop?.state == .finished && w.loop?.endedAt != nil && w.loop?.task == nil)
        #expect(await r.host.dismissed == ["loop-a-1"])
        #expect(w.jobs.map(\.id) == ["loop-a-1"] && w.jobs[0].kind == .loop && w.jobs[0].state == .finished)
        #expect(w.jobs[0].result == (try await git(r.repo, "rev-parse", "--short", "HEAD")))
    }

    @Test func failsThenPassesFromACleanTree() async throws {
        let r = try await Rig([task("a", "test -f done.txt || { echo MISSING done.txt; exit 1; }")]); defer { r.cleanup() }
        let start = try await git(r.repo, "rev-parse", "HEAD")
        await r.host.set("loop-a-1", Script(act: { d in
            try await commit("wrong.txt", "bad\n", in: d)
            try "dirty\n".write(to: d.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        }))
        final class Seen: @unchecked Sendable { var head = "", status = "x" }
        let seen = Seen()
        await r.host.set("loop-a-2", Script(act: { d in
            seen.head = try await git(d, "rev-parse", "HEAD"); seen.status = try await git(d, "status", "--porcelain")
            try await commit("done.txt", "ok\n", in: d)
        }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .done && w.tasks[0].tries == 2)
        #expect(seen.head == start && seen.status.isEmpty, "\(seen.status)")
        let patch = try String(contentsOf: r.host.patchDir(r.work).appendingPathComponent("a-1.patch"), encoding: .utf8)
        #expect(patch.contains("wrong.txt") && patch.contains("dirty"))
        let note = try #require(w.notes.first { $0.text.hasPrefix("[loop a] Task a, tentativa 1/3:") })
        #expect(note.text.contains("MISSING done.txt") && note.text.contains("check failed (exit 1)") && note.text.contains("tracked files left dirty"))
        #expect(await r.host.prompts["loop-a-2"]?.contains("O que falhou nas tentativas anteriores:\n[loop a] Task a, tentativa 1/3") == true)
        #expect(await r.host.prompts["loop-a-1"]?.contains("O que falhou") == false)
        #expect(await r.host.dismissed == ["loop-a-1", "loop-a-2"])
    }

    @Test func defersAfterTries() async throws {
        let r = try await Rig([task("a", "false"), task("b", "true")], tries: 2); defer { r.cleanup() }
        for n in ["loop-a-1", "loop-a-2", "loop-b-1"] { await r.host.set(n, Script(act: { try await commit("\(n).txt", "x\n", in: $0) })) }
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred && w.tasks[0].reason?.hasPrefix("loop:") == true && w.tasks[0].tries == 2)
        #expect(w.tasks[0].lastFailure == "check failed (exit 1)")
        #expect(w.tasks[1].state == .done)
        #expect(await r.host.summoned == ["loop-a-1", "loop-a-2", "loop-b-1"])
        #expect(await r.host.dismissed == ["loop-a-1", "loop-a-2", "loop-b-1"])   // finding 5: every agent goes, the last failed one too
    }

    @Test func noCommitFailsEvenWithGreenCheck() async throws {
        let r = try await Rig([task("a", "true")], tries: 1); defer { r.cleanup() }
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred && w.tasks[0].lastFailure == "no new commit")
    }

    @Test func idleEndWaitsForTheCommit() async throws {
        let r = try await Rig([task("a", "test -f done.txt")], tries: 1); defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(source: .idle, lateAfter: 2, late: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        #expect(try await r.get().tasks[0].state == .done)
    }

    @Test func turnTimeoutIsNotAFailure() async throws {
        let r = try await Rig([task("a", "test -f done.txt")], tries: 1); defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) },
                                            askError: ProtocolError(code: .timeout, message: "turn timed out")))
        #expect(await r.run() == .finished)
        #expect(try await r.get().tasks[0].state == .done)
    }

    @Test func branchSwitchIsNotACommit() async throws {
        let r = try await Rig([task("a", "true")], tries: 1); defer { r.cleanup() }
        let start = try await git(r.repo, "rev-parse", "HEAD")
        await r.host.set("loop-a-1", Script(act: { d in
            _ = try await git(d, "checkout", "-q", "-b", "elsewhere")
            try await commit("done.txt", "ok\n", in: d)
        }))
        #expect(await r.run() == .finished)
        #expect(try await r.get().tasks[0].lastFailure == "no new commit")
        #expect(try await git(r.repo, "rev-parse", "--abbrev-ref", "HEAD") == "main")
        #expect(try await git(r.repo, "rev-parse", "HEAD") == start)
        #expect(try await git(r.repo, "status", "--porcelain").isEmpty)
    }

    @Test func checkEditsNeverCount() async throws {
        let r = try await Rig([task("a", "echo generated > f.txt")]); defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        #expect(try await r.get().tasks[0].state == .done)
        #expect(try await git(r.repo, "status", "--porcelain").isEmpty)
    }

    @Test func checkTimeoutFails() async throws {
        let r = try await Rig([task("a", "sleep 5")], tries: 1, checkTimeout: .milliseconds(200)); defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) }))
        let t0 = ContinuousClock.now
        #expect(await r.run() == .finished)
        #expect(ContinuousClock.now - t0 < .seconds(4))
        #expect(try await r.get().tasks[0].lastFailure == "check timed out")
    }

    @Test func stopEndsAfterTheVerdict() async throws {
        let r = try await Rig([task("a", "true"), task("b", "true")], tries: 2); defer { r.cleanup() }
        let loop = r.loop, id = r.work
        await r.host.set("loop-a-1", Script(act: { d in await loop.stop(work: id); try await commit("done.txt", "ok\n", in: d) }))
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.tasks.map(\.state) == [.done, .open] && w.loop?.state == .stopped)
    }

    @Test func maxCapsAttempts() async throws {
        let r = try await Rig([task("a", "false")], tries: 3, max: 1); defer { r.cleanup() }
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(await r.host.summoned == ["loop-a-1"] && w.loop?.state == .stopped && w.loop?.used == 1)
        #expect(w.tasks[0].state == .open && w.tasks[0].tries == 1)
    }

    @Test func closedWorkStopsTheLoop() async throws {
        let r = try await Rig([task("a", "true")]); defer { r.cleanup() }
        let store = r.store, id = r.work
        await r.host.set("loop-a-1", Script(act: { _ in try await store.close(id, by: "app") }))
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.loop?.state == .stopped && w.tasks[0].state == .open)
        #expect(await r.host.dismissed == ["loop-a-1"])
        #expect(await r.host.checks == 0)
    }

    @Test func untrackedFilesFromBeforeSurviveAFailedAttempt() async throws {
        let r = try await Rig([task("a", "false")], tries: 1); defer { r.cleanup() }
        try "mine\n".write(to: r.repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        await r.host.set("loop-a-1", Script(act: { d in
            // ponytail: an agent that commits the owner's file itself (`git add -A`) loses it to the reset; only the patch keeps it
            try "new\n".write(to: d.appendingPathComponent("agent.txt"), atomically: true, encoding: .utf8)
            _ = try await git(d, "add", "agent.txt"); _ = try await git(d, "commit", "-q", "-m", "agent")
            try "loose\n".write(to: d.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
        }))
        #expect(await r.run() == .finished)
        #expect(try String(contentsOf: r.repo.appendingPathComponent("notes.txt"), encoding: .utf8) == "mine\n")
        #expect(try await git(r.repo, "status", "--porcelain") == "?? notes.txt")
        let patch = try String(contentsOf: r.host.patchDir(r.work).appendingPathComponent("a-1.patch"), encoding: .utf8)
        #expect(patch.contains("agent.txt") && patch.contains("done.txt") && !patch.contains("notes.txt"))
    }

    /// Finding 5: the agent is dismissed before its check runs (a turn past its timeout may still be editing).
    @Test func agentGoesBeforeTheCheck() async throws {
        let r = try await Rig([task("a", "test -f done.txt")], tries: 1); defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) },
                                            askError: ProtocolError(code: .timeout, message: "turn timed out")))
        #expect(await r.run() == .finished)
        #expect(await r.host.events == ["dismiss loop-a-1", "check"])
    }

    /// Finding 4: tracked changes before an attempt are not the loop's: it stops and leaves them.
    @Test func dirtyTreeStopsBeforeTheAttempt() async throws {
        let r = try await Rig([task("a", "true")]); defer { r.cleanup() }
        try "someone's\n".write(to: r.repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        #expect(await r.run() == .stopped)
        #expect(await r.host.summoned.isEmpty)
        #expect(try String(contentsOf: r.repo.appendingPathComponent("f.txt"), encoding: .utf8) == "someone's\n")
        let w = try await r.get()
        #expect(w.tasks[0].state == .open && w.notes.last?.text.contains("dirty") == true)
    }

    /// Finding 4: another terminal of the paddock in a turn: no reset, no checkout; the loop stops.
    @Test func otherAgentWorkingBlocksTheReset() async throws {
        let r = try await Rig([task("a", "false"), task("b", "true")]); defer { r.cleanup() }
        await r.host.setBusy("dev")
        await r.host.set("loop-a-1", Script(act: { try await commit("wrong.txt", "x\n", in: $0) }))
        #expect(await r.run() == .stopped)
        #expect(FileManager.default.fileExists(atPath: r.repo.appendingPathComponent("wrong.txt").path))   // nothing reset
        let w = try await r.get()
        #expect(w.tasks.map(\.state) == [.open, .open] && w.notes.last?.text.contains("dev") == true, "\(w.notes.map(\.text))")
    }

    /// Review Focus 5: the starter (whose Shepherd the loop summons as) is gone: the loop stops, nothing is deferred.
    @Test func starterGoneStopsTheLoop() async throws {
        let r = try await Rig([task("a", "false"), task("b", "true")]); defer { r.cleanup() }
        await r.host.setStarterGone(after: "loop-a-1")
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.tasks.map(\.state) == [.open, .open] && w.tasks[0].tries == nil)
        #expect(await r.host.summoned == ["loop-a-1"])
        #expect(await r.host.dismissed == ["loop-a-1"])
        #expect(await r.host.checks == 0)
    }

    /// Finding 7: the time budget (turns + checks) stops the loop between attempts.
    @Test func budgetStopsTheLoop() async throws {
        let r = try await Rig([task("a", "sleep 1.2; false")], tries: 3, budget: 1); defer { r.cleanup() }
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(await r.host.summoned == ["loop-a-1"] && (w.loop?.spent ?? 0) >= 1)
    }

    /// Finding 7: a task added while the loop runs waits for the next run.
    @Test func tasksAddedDuringTheLoopWait() async throws {
        let r = try await Rig([task("a", "true")]); defer { r.cleanup() }
        let store = r.store, id = r.work
        await r.host.set("loop-a-1", Script(act: { d in
            try await store.update(id) { $0.tasks.append(WorkTask(id: "late", title: "Late", check: "true")) }
            try await commit("done.txt", "ok\n", in: d)
        }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks.map(\.state) == [.done, .open])
        #expect(await r.host.summoned == ["loop-a-1"])
    }

    /// Finding 8: secrets in the check's output never reach the notes (nor the next prompt).
    @Test func checkOutputSecretsAreMasked() async throws {
        let r = try await Rig([task("a", "x=abcdefgh; echo GH_TOKEN=ghp_${x}123456; echo \"Authorization: Bearer abc.def.${x}\"; echo sk-ant-0123456789${x}; false")], tries: 2)
        defer { r.cleanup() }
        #expect(await r.run() == .finished)
        let text = try await r.get().notes.map(\.text).joined(separator: "\n")
        #expect(!text.contains("ghp_abcdefgh123456") && !text.contains("abc.def.abcdefgh") && !text.contains("sk-ant-0123456789abcdefgh"), "\(text)")
        #expect(text.contains("[hidden]"))
        #expect(await r.host.prompts["loop-a-2"]?.contains("ghp_abcdefgh123456") == false)
    }

    /// Finding 8: an attempt reads its own task's failures only (two tasks may share a title).
    @Test func notesAreTheTasksOwn() async throws {
        let r = try await Rig([WorkTask(id: "a", title: "Twin", check: "false"), WorkTask(id: "b", title: "Twin", check: "false")], tries: 1)
        defer { r.cleanup() }
        #expect(await r.run() == .finished)
        #expect(await r.host.prompts["loop-b-1"]?.contains("O que falhou") == false)
    }

    /// Finding 9: a task dropped (or done) while its attempt ran keeps that state; the verdict is not written over it.
    @Test func taskChangedMidAttemptKeepsItsState() async throws {
        let r = try await Rig([task("a", "true")]); defer { r.cleanup() }
        let store = r.store, id = r.work
        await r.host.set("loop-a-1", Script(act: { d in
            try await store.update(id) { $0.tasks[0].state = .abandoned; $0.tasks[0].reason = "not needed" }
            try await commit("done.txt", "ok\n", in: d)
        }))
        #expect(await r.run() == .finished)
        let t = try await r.get().tasks[0]
        #expect(t.state == .abandoned && t.reason == "not needed" && t.tries == nil)
    }

    /// Finding 10: a cancelled loop (daemon stop) spends no attempt and discards nothing.
    @Test func cancelSpendsNoAttempt() async throws {
        let r = try await Rig([task("a", "false")]); defer { r.cleanup() }
        final class Box: @unchecked Sendable { var task: Task<WorkLoopState.State, Never>? }
        let box = Box(), loop = r.loop, id = r.work, repo = r.repo
        await r.host.set("loop-a-1", Script(act: { d in box.task?.cancel(); try await commit("wip.txt", "x\n", in: d) }))
        box.task = Task { await loop.run(work: id, dir: repo) }
        #expect(await box.task!.value == .stopped)
        let w = try await r.get()
        #expect(w.tasks[0].state == .open && w.tasks[0].tries == nil && w.loop?.used == 0, "\(w.tasks) \(String(describing: w.loop))")
        #expect(!w.notes.contains { $0.text.hasPrefix("[loop a]") })
        #expect(!FileManager.default.fileExists(atPath: r.host.patchDir(id).appendingPathComponent("a-1.patch").path))
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("wip.txt").path))
        #expect(await r.host.checks == 0)
    }

    // MARK: the gate (`work run --gate`)

    @Test func gateFailureFailsTheTask() async throws {
        let r = try await Rig([task("a", "test -f done.txt")], tries: 1, gate: "echo GATE-OUT; exit 3"); defer { r.cleanup() }
        let start = try await git(r.repo, "rev-parse", "HEAD")
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred && w.tasks[0].lastFailure == "gate failed (exit 3)", "\(w.tasks)")
        #expect(await r.host.commands == ["test -f done.txt", "echo GATE-OUT; exit 3"])
        let note = try #require(w.notes.first { $0.text.hasPrefix("[loop a] Task a, tentativa 1/1: gate failed (exit 3)") })
        #expect(note.text.contains("GATE-OUT"))
        #expect(try await git(r.repo, "rev-parse", "HEAD") == start)   // discarded as any failed attempt
    }

    @Test func gateDoesNotRunWhenTheCheckFails() async throws {
        let r = try await Rig([task("a", "false")], tries: 1, gate: "true"); defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        #expect(try await r.get().tasks[0].lastFailure == "check failed (exit 1)")
        #expect(await r.host.commands == ["false"])
    }

    @Test func gatePassesAndTheTaskIsDone() async throws {
        let r = try await Rig([task("a", "test -f done.txt"), task("b", "true")], gate: "test -f done.txt"); defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) }))
        await r.host.set("loop-b-1", Script(act: { try await commit("b.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        #expect(try await r.get().tasks.map(\.state) == [.done, .done])
        // after each task's check
        #expect(await r.host.commands == ["test -f done.txt", "test -f done.txt", "true", "test -f done.txt"])
        #expect(await r.host.prompts["loop-a-1"]?.contains("test -f done.txt\ne depois este portão:\ntest -f done.txt\n") == true)
    }

    @Test func gateTimeoutFails() async throws {
        let r = try await Rig([task("a", "true")], tries: 1, gate: "sleep 5", checkTimeout: .milliseconds(200)); defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        #expect(try await r.get().tasks[0].lastFailure == "gate timed out")
    }

    // MARK: evidence (B1.1)

    @Test func passedAttemptRecordsEvidence() async throws {
        let r = try await Rig([task("a", "echo CHECK-OUT; test -f done.txt")], gate: "echo GATE-OUT"); defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(act: { d in
            try await commit("done.txt", "ok\n", in: d); try await commit("more.txt", "x\n", in: d)
        }))
        #expect(await r.run() == .finished)
        let e = try #require(try await r.get().tasks[0].evidence)
        let head = try await git(r.repo, "rev-parse", "--short", "HEAD")
        #expect(e.commits.count == 2 && e.commits[0] == "\(head) edit more.txt" && e.commits[1].hasSuffix(" edit done.txt"), "\(e.commits)")
        #expect(e.shortstat.contains("2 files changed") && e.shortstat.contains("2 insertions"), "\(e.shortstat)")
        #expect(e.checkTail == "CHECK-OUT\nGATE-OUT")
        #expect(e.attempt == 1 && e.seconds >= 0)
    }

    @Test func failedAttemptRecordsNoEvidence() async throws {
        let r = try await Rig([task("a", "test -f done.txt"), task("b", "false")], tries: 2); defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(act: { try await commit("wrong.txt", "x\n", in: $0) }))
        await r.host.set("loop-a-2", Script(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        // the failed attempt's commit was discarded: only the approved one is evidence
        #expect(w.tasks[0].evidence?.attempt == 2 && w.tasks[0].evidence?.commits.count == 1, "\(String(describing: w.tasks[0].evidence))")
        #expect(w.tasks[1].state == .deferred && w.tasks[1].evidence == nil)
    }

    @Test func evidenceSecretsAreMasked() async throws {
        let r = try await Rig([task("a", "x=abcdefgh; echo GH_TOKEN=ghp_${x}123456; echo sk-ant-0123456789${x}; echo fine")]); defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let tail = try #require(try await r.get().tasks[0].evidence).checkTail
        #expect(!tail.contains("ghp_abcdefgh123456") && !tail.contains("sk-ant-0123456789abcdefgh"), "\(tail)")
        #expect(tail.contains("[hidden]") && tail.hasSuffix("fine"))
    }

    @Test func evidenceTailIsCut() {
        let long = (1...30).map { "line \($0) " + String(repeating: "x", count: 150) }.joined(separator: "\n") + "\n"
        let t = WorkLoop.evidenceTail(check: long, gate: nil)
        #expect(t.count == 2000 && t.hasSuffix("line 30 " + String(repeating: "x", count: 150)))
        #expect(WorkLoop.evidenceTail(check: (1...30).map { "l\($0)" }.joined(separator: "\n"), gate: nil).hasPrefix("l11\n"))
    }

    @Test func promptWithoutAGateNamesNone() {
        let p = WorkLoop.prompt(task: task("a", "true"), spec: nil, attempt: 1, tries: 3, dir: URL(fileURLWithPath: "/tmp"), notes: [])
        #expect(!p.contains("portão"))
    }

    @Test func oldLoopStateDecodesWithoutAGate() throws {
        let old = #"{"state":"stopped","attempt":1,"tries":3,"timeout":3600,"used":2,"startedAt":0}"#
        #expect(try JSONDecoder().decode(WorkLoopState.self, from: Data(old.utf8)).gate == nil)
    }

    @Test func verdictJoinsReasons() {
        #expect(WorkLoop.verdict(checkStatus: 0, gate: WorkLoop.failure("gate", 2), committed: false, dirty: false) == "gate failed (exit 2); no new commit")
        #expect(WorkLoop.verdict(checkStatus: 0, gate: WorkLoop.failure("gate", nil), committed: true, dirty: false) == "gate timed out")
        #expect(WorkLoop.verdict(checkStatus: 0, gate: WorkLoop.failure("gate", 0), committed: true, dirty: false) == nil)
        #expect(WorkLoop.verdict(checkStatus: 0, committed: true, dirty: false) == nil)
        #expect(WorkLoop.verdict(checkStatus: nil, committed: false, dirty: true) == "check timed out; no new commit; tracked files left dirty")
        #expect(WorkLoop.verdict(checkStatus: 2, committed: true, dirty: false) == "check failed (exit 2)")
    }
}
