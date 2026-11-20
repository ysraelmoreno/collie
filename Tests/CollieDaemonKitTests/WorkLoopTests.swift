import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// What one attempt's "agent" does, keyed by its terminal name (`loop-<task>-<n>`).
/// Shared with `LoopStopReasonTests`.
struct LoopScript: Sendable {
    /// Runs during `ask`, in the worktree.
    var act: @Sendable (URL) async throws -> Void = { _ in }
    var source: AskResult.Source = .hook
    var askError: ProtocolError?
    /// `.idle` ends: `working` stays true and nothing is committed until its `n`-th call, which runs `late`.
    var lateAfter: Int?
    var late: @Sendable (URL) async throws -> Void = { _ in }
}

/// A host without PTYs: scripted agents, real git and a real (unsandboxed) check in a temp repo.
actor LoopFakeHost: LoopHost {
    nonisolated let dir: URL, patches: URL
    var scripts: [String: LoopScript] = [:]
    var summoned: [String] = [], dismissed: [String] = [], prompts: [String: String] = [:], checks = 0
    /// Every command `check` ran (the tasks' checks and the gate), in order.
    var commands: [String] = []
    /// Each line the Shepherd got when a task ended.
    var ended: [String] = []
    /// A Shepherd that is never idle: its notices are never delivered.
    var noticeNeverDelivered = false
    func taskEnded(_ line: String) async {
        if noticeNeverDelivered { try? await Task.sleep(for: .seconds(3600)); return }
        ended.append(line)
    }
    func neverDeliverNotices() { noticeNeverDelivered = true }
    /// Called with each command before `check` runs it (a test reads the loop's phase from the store here).
    var probe: (@Sendable (String) async -> Void)?
    func setProbe(_ p: @escaping @Sendable (String) async -> Void) { probe = p }
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
    func set(_ name: String, _ s: LoopScript) { scripts[name] = s }

    func summon(name: String, for work: Work, loop: WorkLoopState) async throws(ProtocolError) -> UUID {
        let id = UUID(); names[id] = name; summoned.append(name); return id
    }
    func ask(_ terminal: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> AskResult.Source {
        let name = names[terminal]!, s = scripts[name] ?? LoopScript()
        prompts[name] = prompt
        do { try await s.act(dir) } catch { Issue.record("agent \(name): \(error)") }
        if name == starterGoneAfter { starterGone = true }
        if let e = s.askError { throw e }
        return s.source
    }
    func working(_ terminal: UUID) async -> Bool {
        let name = names[terminal]!, s = scripts[name] ?? LoopScript()
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
        await probe?(command)
        return try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/bash"), args: ["-c", command], in: dir,
                                            env: ProcessInfo.processInfo.environment, timeout: timeout)
    }
    func readSpec(_ path: String) async -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    func exists(_ path: String, in dir: URL) async -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path) }
    nonisolated func patchDir(_ work: UUID) -> URL { patches.appendingPathComponent(work.uuidString.lowercased()) }
    nonisolated func now() -> Date { Date() }
}

private actor PhaseLog {
    struct Item: Equatable { let command: String; let phase: WorkLoopState.Phase? }
    var items: [Item] = []
    func add(_ c: String, _ p: WorkLoopState.Phase?) { items.append(Item(command: c, phase: p)) }
}

private func git(_ dir: URL, _ args: String...) async throws -> String {
    let r = try await GitRunner.run(args, in: dir)
    #expect(r.status == 0, "git \(args): \(r.stderr)")
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A repo, a store holding a work with `tasks` and a running loop, a fake host and the loop.
struct LoopRig {
    let repo: URL, storeDir: URL, store: WorkStore, host: LoopFakeHost, loop: WorkLoop, work: UUID
    init(_ tasks: [WorkTask], tries: Int = 3, max: Int? = nil, budget: Int? = nil, gate: String? = nil,
         checkTimeout: Duration = .seconds(30), othersWait: Duration = .milliseconds(50)) async throws {
        repo = try await makeRepo()
        storeDir = URL(fileURLWithPath: "/tmp/collie-loop-\(UUID().uuidString.prefix(8))")
        store = WorkStore(dir: storeDir)
        let w = try await store.start(title: "W", terminal: UUID(), paddockId: UUID(), branch: "main")
        try await store.update(w.id) {
            $0.tasks = tasks
            $0.loop = WorkLoopState(tries: tries, timeout: 60, max: max, budget: budget, tasks: tasks.map(\.id), gate: gate)
        }
        work = w.id
        host = LoopFakeHost(dir: repo)
        loop = WorkLoop(store: store, host: host, poll: .milliseconds(10), checkTimeout: checkTimeout, othersWait: othersWait)
    }
    func run() async -> WorkLoopState.State { await loop.run(work: work, dir: repo) }
    func get() async throws -> Work { try #require(try await store.get(work)) }
    func cleanup() { for u in [repo, storeDir, host.patches] { try? FileManager.default.removeItem(at: u) } }
}

private typealias Script = LoopScript
private typealias Rig = LoopRig

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
        // sleep 60 vs a 20 s bound: the suite runs in parallel, and a 1 s margin failed under load (4.13 s against 4 s)
        let r = try await Rig([task("a", "sleep 60")], tries: 1, checkTimeout: .milliseconds(200)); defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) }))
        let t0 = ContinuousClock.now
        #expect(await r.run() == .finished)
        #expect(ContinuousClock.now - t0 < .seconds(20))
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
        // the path's own note, then the loop's summary note: in that order
        let notes = w.notes.suffix(2).map(\.text)
        #expect(w.tasks[0].state == .open && notes.count == 2 && notes[0].contains("dirty") && notes[1].hasPrefix("[loop] laço parado:"), "\(notes)")
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

    /// A short chat in another terminal is no reason to end the loop: it gets `othersWait` to finish.
    @Test func otherAgentThatFinishesInTimeDoesNotStopTheLoop() async throws {
        let r = try await Rig([task("a", "false")], tries: 1, othersWait: .seconds(5)); defer { r.cleanup() }
        await r.host.setBusy("dev")
        let host = r.host
        let freeing = Task { try? await Task.sleep(for: .milliseconds(150)); await host.setBusy(nil) }
        await r.host.set("loop-a-1", Script(act: { try await commit("wrong.txt", "x\n", in: $0) }))
        #expect(await r.run() == .finished)   // waited, then reset and deferred as usual
        await freeing.value
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred, "\(w.tasks)")
        #expect(!FileManager.default.fileExists(atPath: r.repo.appendingPathComponent("wrong.txt").path))   // reset ran
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

    // MARK: the gate judges the tree the check judged (B2.3)

    /// A check that edits a tracked file and creates another: the gate sees the commit alone.
    @Test func gateSeesTheCommitNotTheChecksEdits() async throws {
        let r = try await Rig([task("a", "echo broken > done.txt; echo x > made.txt")], gate: "grep -q ok done.txt && test ! -e made.txt")
        defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .done, "\(w.notes.map(\.text))")
        #expect(try await git(r.repo, "status", "--porcelain").isEmpty)
    }

    /// A check that repairs the tree does not make a bad commit pass the gate.
    @Test func gateFailsACommitTheCheckRepaired() async throws {
        let r = try await Rig([task("a", "echo ok > done.txt")], tries: 1, gate: "grep -q ok done.txt"); defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "bad\n", in: $0) }))
        #expect(await r.run() == .finished)
        #expect(try await r.get().tasks[0].lastFailure == "gate failed (exit 1)")
    }

    @Test func checkThatCommitsFailsTheAttempt() async throws {
        let sneak = "echo x > sneak.txt && git add sneak.txt && git commit -q -m sneak"
        let r = try await Rig([task("a", sneak)], tries: 1, gate: "true"); defer { r.cleanup() }
        let start = try await git(r.repo, "rev-parse", "HEAD")
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred && w.tasks[0].lastFailure == "o check moveu o HEAD", "\(w.tasks)")
        #expect(w.tasks[0].evidence == nil)
        #expect(await r.host.commands == [sneak])   // the gate did not run
        // HEAD went back to the agent's commit before the discard: the patch holds its work, not the check's commit
        let patch = try String(contentsOf: r.host.patchDir(r.work).appendingPathComponent("a-1.patch"), encoding: .utf8)
        #expect(patch.contains("done.txt") && !patch.contains("sneak.txt"), "\(patch)")
        #expect(try await git(r.repo, "rev-parse", "HEAD") == start)
        #expect(try await git(r.repo, "status", "--porcelain").isEmpty)
    }

    @Test func theShepherdHearsOfEachTaskAsItEnds() async throws {
        let r = try await Rig([task("a", "test -f done.txt"), task("b", "false")], tries: 1); defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let ended = await r.host.ended
        #expect(ended.count == 2, "\(ended)")
        #expect(ended[0].hasPrefix("[collie] Laço, tarefa terminada: ✓ Task a · tentativa 1"), "\(ended)")
        #expect(ended[1].hasPrefix("[collie] Laço, tarefa terminada: – Task b · adiada: loop:"), "\(ended)")
    }

    /// The loop does not wait for the Shepherd to be idle to hear of a task: the next task starts at once.
    @Test func aBusyShepherdDoesNotHoldTheLoop() async throws {
        let r = try await Rig([task("a", "test -f done.txt"), task("b", "test -f more.txt")]); defer { r.cleanup() }
        await r.host.neverDeliverNotices()
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) }))
        await r.host.set("loop-b-1", Script(act: { try await commit("more.txt", "ok\n", in: $0) }))
        let t0 = ContinuousClock.now
        #expect(await r.run() == .finished)
        #expect(ContinuousClock.now - t0 < .seconds(60), "the loop waited for the notice")
        let w = try await r.get()
        #expect(w.tasks.map(\.state) == [.done, .done], "\(w.tasks)")
    }

    @Test func aTaskWithTriesLeftIsNotReportedYet() async throws {
        let r = try await Rig([task("a", "false")], tries: 2); defer { r.cleanup() }
        #expect(await r.run() == .finished)
        #expect(await r.host.ended.count == 1)   // only after the 2nd and last try
    }

    @Test func statusShowsWhatTheLoopIsDoing() async throws {
        let r = try await Rig([task("a", "true")], tries: 1, gate: "echo gate"); defer { r.cleanup() }
        let seen = PhaseLog()
        let store = r.store, work = r.work
        await r.host.setProbe { cmd in
            let p = try? await store.get(work)?.loop?.phase
            await seen.add(cmd, p)
        }
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        #expect(await seen.items == [PhaseLog.Item(command: "true", phase: .check), PhaseLog.Item(command: "echo gate", phase: .gate)])
        #expect(try await r.get().loop?.phase == nil)   // between attempts and at the end: none
    }

    @Test func gateThatCommitsFailsTheAttempt() async throws {
        let sneak = "echo x > sneak.txt && git add sneak.txt && git commit -q -m sneak"
        let r = try await Rig([task("a", "true")], tries: 1, gate: sneak); defer { r.cleanup() }
        let start = try await git(r.repo, "rev-parse", "HEAD")
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred && w.tasks[0].lastFailure == "o portão moveu o HEAD", "\(w.tasks)")
        #expect(w.tasks[0].evidence == nil)
        let patch = try String(contentsOf: r.host.patchDir(r.work).appendingPathComponent("a-1.patch"), encoding: .utf8)
        #expect(patch.contains("done.txt") && !patch.contains("sneak.txt"), "\(patch)")
        #expect(try await git(r.repo, "rev-parse", "HEAD") == start)
    }

    @Test func gateDoesNotRunWithoutACommit() async throws {
        let r = try await Rig([task("a", "true")], tries: 1, gate: "echo GATE"); defer { r.cleanup() }
        #expect(await r.run() == .finished)
        #expect(try await r.get().tasks[0].lastFailure == "no new commit")
        #expect(await r.host.commands == ["true"])
    }

    @Test func gateDoesNotRunOnADirtyTree() async throws {
        let r = try await Rig([task("a", "true")], tries: 1, gate: "echo GATE"); defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(act: { d in
            try await commit("done.txt", "ok\n", in: d)
            try "dirty\n".write(to: d.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        }))
        #expect(await r.run() == .finished)
        #expect(try await r.get().tasks[0].lastFailure == "tracked files left dirty")
        #expect(await r.host.commands == ["true"])
        let patch = try String(contentsOf: r.host.patchDir(r.work).appendingPathComponent("a-1.patch"), encoding: .utf8)
        #expect(patch.contains("dirty"))   // the agent's uncommitted work is still the patch's
    }

    // MARK: the agent does not rewrite the script that judges it (B2.4)

    private static let lint = "scripts/ci/lint.sh"
    private static func script(_ text: String, in d: URL) async throws {
        try FileManager.default.createDirectory(at: d.appendingPathComponent("scripts/ci"), withIntermediateDirectories: true)
        try await commit(lint, text, in: d)
    }

    @Test func changingAScriptTheGateRunsFailsTheAttempt() async throws {
        let gate = "bash \(Self.lint) && true"
        let r = try await Rig([task("a", "true")], tries: 1, gate: gate); defer { r.cleanup() }
        try await Self.script("exit 1\n", in: r.repo)   // there before the attempt
        await r.host.set("loop-a-1", Script(act: { try await Self.script("exit 0\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred, "\(w.tasks)")
        #expect(w.tasks[0].lastFailure == "a tentativa alterou «scripts/ci/lint.sh», que o portão executa")
        #expect(await r.host.commands == ["true"])   // the gate did not run on the rewritten script
    }

    /// B4.1 adds a rule to the lint script that is the gate: its spec says so, and the owner approved that spec.
    @Test func aScriptTheTasksSpecNamesMayChange() async throws {
        let gate = "bash \(Self.lint) && true"
        var t = task("a", "true"); t.spec = "spec.md"
        let r = try await Rig([t], tries: 1, gate: gate); defer { r.cleanup() }
        try await Self.script("exit 1\n", in: r.repo)
        try await commit("spec.md", "Add a rule to \(Self.lint).\n", in: r.repo)
        await r.host.set("loop-a-1", Script(act: { try await Self.script("exit 0\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .done, "\(w.tasks)")
    }

    /// The spec counts as it was before the attempt: an agent that edits it to name the script is still refused.
    @Test func anAgentCannotAuthoriseItselfBySpecEdit() async throws {
        let gate = "bash \(Self.lint) && true"
        var t = task("a", "true"); t.spec = "spec.md"
        let r = try await Rig([t], tries: 1, gate: gate); defer { r.cleanup() }
        try await Self.script("exit 1\n", in: r.repo)
        try await commit("spec.md", "Add a feature.\n", in: r.repo)
        await r.host.set("loop-a-1", Script(act: { d in
            try await commit("spec.md", "Rewrite \(Self.lint).\n", in: d)
            try await Self.script("exit 0\n", in: d)
        }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred && w.tasks[0].lastFailure == "a tentativa alterou «scripts/ci/lint.sh», que o portão executa", "\(w.tasks)")
    }

    @Test func creatingTheScriptTheGateRunsPasses() async throws {
        let gate = "bash \(Self.lint)"
        let r = try await Rig([task("a", "true")], tries: 1, gate: gate); defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(act: { try await Self.script("exit 0\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .done, "\(w.tasks)")
        #expect(await r.host.commands == ["true", gate])
    }

    @Test func changingAFileTheGateDoesNotNamePasses() async throws {
        let r = try await Rig([task("a", "true")], tries: 1, gate: "bash \(Self.lint)"); defer { r.cleanup() }
        try await Self.script("exit 0\n", in: r.repo)
        await r.host.set("loop-a-1", Script(act: { try await commit("f.txt", "two\n", in: $0) }))   // f.txt exists since the init
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .done, "\(w.tasks)")
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

    // MARK: clean evidence (B1.4)

    @Test func evidenceIsCutAndClean() async throws {
        // the check prints red text and a bidi override (U+202E, E2 80 AE)
        let r = try await Rig([task("a", "printf '\\033[31mRED\\033[0m \\342\\200\\256ok\\n'")]); defer { r.cleanup() }
        let subject = "feat: \u{1B}[31mred\u{1B}[0m \u{202E}evil\u{7} " + String(repeating: "é", count: 5000)
        await r.host.set("loop-a-1", Script(act: { d in
            try "ok\n".write(to: d.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            _ = try await git(d, "add", "."); _ = try await git(d, "commit", "-m", subject)
        }))
        #expect(await r.run() == .finished)
        let e = try #require(try await r.get().tasks[0].evidence)
        let line = try #require(e.commits.first), head = try await git(r.repo, "rev-parse", "--short", "HEAD")
        #expect(e.commits.count == 1 && line.hasPrefix("\(head) feat: red evil  ééé"), "\(line.prefix(60))")
        #expect(line.count == head.count + 1 + 200, "\(line.count)")   // cut by Character: "é" is two bytes
        #expect(e.checkTail == "RED ok", "\(e.checkTail.unicodeScalars.map(\.value))")
        for s in e.commits + [e.checkTail] {
            #expect(!s.contains("[31m") && !s.unicodeScalars.contains { [.control, .format].contains($0.properties.generalCategory) })
        }
    }

    @Test func evidenceCommitAndTailLoseWhatHides() {
        #expect(WorkLoop.evidenceCommit("abc1234 fix: \u{202E}x\u{200B}y\u{1B}]0;title\u{7}z") == "abc1234 fix: xyz")
        #expect(WorkLoop.evidenceCommit("abc1234") == "abc1234")
        #expect(WorkLoop.evidenceCommit("abc1234 " + String(repeating: "x", count: 201)) == "abc1234 " + String(repeating: "x", count: 200))
        // the tail keeps its lines and their indentation
        #expect(WorkLoop.evidenceTail(check: "\u{1B}[32m  ok\u{1B}[0m\tdone\u{202E}\r\nnext", gate: "\u{1B}[1mgate\u{1B}[0m") == "  ok done\nnext\ngate")
    }

    /// `work.task.done` read the task while the loop still ran it and writes after the loop approved it: the write is
    /// on the task as it is then, so the loop's evidence and tries stay.
    @Test func taskDoneByHandAfterTheApprovalKeepsTheEvidence() async throws {
        let r = try await Rig([task("a", "true")]); defer { r.cleanup() }
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let at = Date(timeIntervalSince1970: 2_000_000)
        let t = try #require(try await r.store.setTask(r.work, task: "a", state: .done, reason: nil, at: at))
        #expect(t.state == .done && t.tries == 1 && t.evidence?.attempt == 1 && t.evidence?.commits.count == 1 && t.updatedAt == at)
        #expect(try await r.get().tasks[0] == t)
        // by hand first (the task still in progress): the loop keeps that state and records no evidence
        let h = try await Rig([task("a", "true")]); defer { h.cleanup() }
        let store = h.store, id = h.work
        await h.host.set("loop-a-1", Script(act: { d in
            _ = try await store.setTask(id, task: "a", state: .done, reason: nil, at: at)
            try await commit("done.txt", "ok\n", in: d)
        }))
        #expect(await h.run() == .finished)
        let m = try await h.get().tasks[0]
        #expect(m.state == .done && m.evidence == nil && m.tries == nil)
        #expect(try await store.setTask(id, task: "nope", state: .done, reason: nil, at: at) == nil)
    }

    /// B1.3: the approved task's declared files leave the worktree for the loop's folder; a symlink out, another
    /// extension and a file under `.git` never do.
    @Test func approvalCopiesTheDeclaredEvidence() async throws {
        let outside = URL(fileURLWithPath: "/tmp/collie-evidence-out-\(UUID().uuidString.prefix(8)).png")
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        var t = task("a/../x", "true"); t.evidenceGlob = "shots/*"
        let r = try await Rig([t, task("b", "true")]); defer { r.cleanup() }
        await r.host.set("loop-a/../x-1", Script(act: { d in
            let shots = d.appendingPathComponent("shots")
            try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
            try "png".write(to: shots.appendingPathComponent("a.png"), atomically: true, encoding: .utf8)   // untracked: the agent's
            try "x".write(to: shots.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: shots.appendingPathComponent("out.png"), withDestinationURL: outside)
            try FileManager.default.createSymbolicLink(at: shots.appendingPathComponent("in.md"), withDestinationURL: d.appendingPathComponent("notes.md"))
            try await commit("notes.md", "# notes\n", in: d)
        }))
        await r.host.set("loop-b-1", Script(act: { try await commit("b.txt", "x\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get(), e = try #require(w.tasks[0].evidence)
        #expect(e.files == ["a.png", "notes.md"], "\(e.files ?? [])")
        let dir = r.host.patchDir(r.work).appendingPathComponent("evidence/a____x")
        #expect(e.filesDir == dir.path)
        let fm = FileManager.default
        #expect(try String(contentsOf: dir.appendingPathComponent("a.png"), encoding: .utf8) == "png")
        #expect(try fm.contentsOfDirectory(atPath: dir.path).sorted() == ["a.png", "notes.md"])
        #expect(try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int == 0o700)
        #expect(try fm.attributesOfItem(atPath: dir.appendingPathComponent("a.png").path)[.posixPermissions] as? Int == 0o600)
        // a task that declared none has no files
        #expect(w.tasks[1].evidence != nil && w.tasks[1].evidence?.files == nil && w.tasks[1].evidence?.filesDir == nil)
    }

    @Test func evidenceCopyStopsAtTheCeiling() async throws {
        let repo = try await makeRepo(), dest = URL(fileURLWithPath: "/tmp/collie-evidence-\(UUID().uuidString.prefix(8))")
        defer { for u in [repo, dest] { try? FileManager.default.removeItem(at: u) } }
        for (n, size) in [("a.txt", 6), ("b.txt", 6), ("c.txt", 1)] {
            try String(repeating: "x", count: size).write(to: repo.appendingPathComponent(n), atomically: true, encoding: .utf8)
        }
        let c = EvidenceFiles.copy("*.txt", from: repo, to: dest, maxBytes: 10)
        #expect(c.files == ["a.txt"] && c.dir == dest.path)   // b would pass the ceiling: the copy stops there, c is not tried
        #expect(c.note?.contains("«b.txt»") == true && c.note?.contains("1 copiados") == true, "\(c.note ?? "")")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path) == ["a.txt"])
        // a new approval replaces what was there; a glob out of the worktree copies nothing
        let again = EvidenceFiles.copy("{b,c}.txt", from: repo, to: dest, maxBytes: 10)
        #expect(again.files == ["b.txt", "c.txt"] && again.note == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).sorted() == ["b.txt", "c.txt"])
        #expect(EvidenceFiles.copy("../*.txt", from: repo, to: dest).files.isEmpty)
    }

    @Test func promptWithoutAGateNamesNone() {
        let p = WorkLoop.prompt(task: task("a", "true"), spec: nil, attempt: 1, tries: 3, dir: URL(fileURLWithPath: "/tmp"), notes: [])
        #expect(!p.contains("portão"))
    }

    /// The prompt of the first attempt of a one-task loop whose worktree has `files` (untracked, empty).
    private func promptWith(_ files: [String]) async throws -> String {
        let r = try await Rig([task("a", "test -f done.txt")]); defer { r.cleanup() }
        for f in files {
            let u = r.repo.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "# mapa\n".write(to: u, atomically: true, encoding: .utf8)
        }
        await r.host.set("loop-a-1", Script(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        return await r.host.prompts["loop-a-1"] ?? ""
    }

    // one test, cases in sequence: each case is a whole loop run, and four more in parallel starve the timing tests
    @Test func promptPointsAtTheFeatureMap() async throws {
        func line(_ path: String) -> String { "O mapa de funcionalidades do projeto está em \(path): use os nomes dele." }
        #expect(try await promptWith(["docs/feature-map.md"]).contains(line("docs/feature-map.md")))
        #expect(try await promptWith(["FEATURES.md"]).contains(line("FEATURES.md")))
        let both = try await promptWith(["FEATURES.md", "docs/feature-map.md"])   // docs/feature-map.md wins
        #expect(both.contains(line("docs/feature-map.md")) && !both.contains("FEATURES.md"))
        let none = try await promptWith([])
        #expect(!none.isEmpty && !none.contains("mapa de funcionalidades"))
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
