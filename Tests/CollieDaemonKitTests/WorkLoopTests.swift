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
    func dismiss(_ terminal: UUID) async { dismissed.append(names[terminal] ?? "?") }
    func git(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult { try await GitRunner.run(args, in: dir) }
    func check(_ command: String, in dir: URL, timeout: Duration) async throws(ProtocolError) -> ProcessResult {
        checks += 1
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
    init(_ tasks: [WorkTask], tries: Int = 3, max: Int? = nil, checkTimeout: Duration = .seconds(30)) async throws {
        repo = try await makeRepo()
        storeDir = URL(fileURLWithPath: "/tmp/collie-loop-\(UUID().uuidString.prefix(8))")
        store = WorkStore(dir: storeDir)
        let w = try await store.start(title: "W", terminal: UUID(), paddockId: UUID(), branch: "main")
        try await store.update(w.id) { $0.tasks = tasks; $0.loop = WorkLoopState(tries: tries, timeout: 60, max: max) }
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
        let note = try #require(w.notes.first { $0.text.hasPrefix("[loop] Task a, tentativa 1/3:") })
        #expect(note.text.contains("MISSING done.txt") && note.text.contains("check failed (exit 1)") && note.text.contains("tracked files left dirty"))
        #expect(await r.host.prompts["loop-a-2"]?.contains("O que falhou nas tentativas anteriores:\n[loop] Task a, tentativa 1/3") == true)
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
        #expect(await r.host.dismissed == ["loop-a-1", "loop-b-1"])   // the last failed attempt's agent stays for the owner
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

    @Test func verdictJoinsReasons() {
        #expect(WorkLoop.verdict(checkStatus: 0, committed: true, dirty: false) == nil)
        #expect(WorkLoop.verdict(checkStatus: nil, committed: false, dirty: true) == "check timed out; no new commit; tracked files left dirty")
        #expect(WorkLoop.verdict(checkStatus: 2, committed: true, dirty: false) == "check failed (exit 2)")
    }
}
