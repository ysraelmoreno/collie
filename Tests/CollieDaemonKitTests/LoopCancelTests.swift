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

private func task(_ id: String, _ check: String) -> WorkTask { WorkTask(id: id, title: "Task \(id)", check: check) }

/// Where the fake host stops in the middle of a call, with continuations (no sleep): the host parks on its `n`-th
/// `park` (once only), the test learns it is there (`reached`), acts, and lets it go (`release`).
private actor Hold {
    private var skip: Int, used = false, there = false
    private var parked: CheckedContinuation<Void, Never>?, waiter: CheckedContinuation<Void, Never>?
    init(onCall n: Int = 1) { skip = n - 1 }

    func park() async {
        if used { return }
        if skip > 0 { skip -= 1; return }
        used = true; there = true
        waiter?.resume(); waiter = nil
        await withCheckedContinuation { parked = $0 }
    }
    func reached() async {
        if there { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { parked?.resume(); parked = nil }
}

/// M2.2b: the daemon stops (`cancelLoops` cancels the `Task` of `run`) while the check, the gate or the wait for
/// another terminal runs: no verdict. The task is `open` again, the attempt is not counted, nothing is discarded or
/// deferred, even on the last attempt, and the task still says where to resume from (M2.2a).
@Suite struct LoopCancelTests {
    /// The agent of the first attempt commits `file`. Returns HEAD before it (what the attempt starts from).
    private func agentCommits(_ r: LoopRig, _ file: String = "done.txt") async throws -> String {
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit(file, "ok\n", in: $0) }))
        return try await git(r.repo, "rev-parse", "HEAD")
    }

    /// Runs the loop in a `Task`, cancels it once the host is parked at `hold`, lets the host go: the work it leaves.
    private func cancel(_ r: LoopRig, at hold: Hold) async throws -> Work {
        let loop = r.loop, id = r.work, repo = r.repo
        let run = Task { await loop.run(work: id, dir: repo) }
        await hold.reached()
        run.cancel()
        await hold.release()
        #expect(await run.value == .stopped)
        return try await r.get()
    }

    /// No verdict was applied: `from` is the HEAD the attempt started from.
    private func expectNoVerdict(_ w: Work, _ r: LoopRig, from: String, _ at: SourceLocation = #_sourceLocation) async throws {
        let t = w.tasks[0], ev = w.loop?.events ?? []
        #expect(t.state == .open && t.tries == nil && t.lastFailure == nil && t.reason == nil, "\(t)", sourceLocation: at)
        #expect(!w.tasks.contains { $0.state == .deferred }, sourceLocation: at)
        #expect(w.loop?.used == 0, sourceLocation: at)
        #expect(w.loop?.state == .stopped && w.loop?.stopReason == .init(.cancelled), "\(String(describing: w.loop?.stopReason))", sourceLocation: at)
        #expect(w.jobs.map(\.id) == ["w-task-a-t1"] && w.jobs[0].state == .gone, "\(w.jobs)", sourceLocation: at)
        // nothing discarded: no failure note, no patch, and the agent's commit is still HEAD
        #expect(!w.notes.contains { $0.text.hasPrefix("[loop a]") }, "\(w.notes.map(\.text))", sourceLocation: at)
        #expect(!FileManager.default.fileExists(atPath: r.host.patchDir(r.work).appendingPathComponent("a-1.patch").path), sourceLocation: at)
        #expect(!ev.contains { $0.kind == .discarded }, "\(ev.map(\.kind.rawValue))", sourceLocation: at)
        let parent = try await git(r.repo, "rev-parse", "HEAD~1")
        #expect(parent == from, sourceLocation: at)
        #expect(ev.last?.kind == .stopped, sourceLocation: at)
        // M2.2a: the next run judges the commit that is already there
        let branch = try await git(r.repo, "rev-parse", "--abbrev-ref", "HEAD")
        #expect(t.resumeFrom == from && t.resumeBranch == branch, sourceLocation: at)
    }

    @Test func duringTheCheckOfTheLastAttempt() async throws {
        let r = try await LoopRig([task("a", "false")], tries: 1); defer { r.cleanup() }
        let from = try await agentCommits(r), hold = Hold()
        await r.host.setProbe { _ in await hold.park() }
        let w = try await cancel(r, at: hold)
        try await expectNoVerdict(w, r, from: from)
        #expect(await r.host.commands == ["false"])
        #expect(await r.host.dismissed == ["w-task-a-t1"])
    }

    @Test func duringTheGateOfTheLastAttempt() async throws {
        let r = try await LoopRig([task("a", "true")], tries: 1, gate: "exit 3"); defer { r.cleanup() }
        let from = try await agentCommits(r), hold = Hold()
        await r.host.setProbe { if $0 == "exit 3" { await hold.park() } }
        let w = try await cancel(r, at: hold)
        try await expectNoVerdict(w, r, from: from)
        #expect(await r.host.commands == ["true", "exit 3"])
    }

    /// The wait after the check (call 1) and the one before a failed attempt's discard (call 2), nobody working.
    @Test(arguments: [1, 2])
    func duringAwaitOthersOfTheLastAttempt(call: Int) async throws {
        let r = try await LoopRig([task("a", "false")], tries: 1); defer { r.cleanup() }
        let from = try await agentCommits(r), hold = Hold(onCall: call)
        await r.host.setOthersProbe { await hold.park() }
        let w = try await cancel(r, at: hold)
        try await expectNoVerdict(w, r, from: from)
    }

    /// Another terminal is working and the loop is giving it time: the cancel ends the wait, and it is no verdict.
    @Test func duringTheWaitForAnotherTerminalThatWorks() async throws {
        let r = try await LoopRig([task("a", "true")], tries: 1, othersWait: .seconds(3600)); defer { r.cleanup() }
        let from = try await agentCommits(r), hold = Hold()
        await r.host.setBusy("other")
        await r.host.setOthersProbe { await hold.park() }
        let w = try await cancel(r, at: hold)
        try await expectNoVerdict(w, r, from: from)
        #expect(w.loop?.stopReason?.code != .othersWorking)
    }

    /// End to end: the check the daemon's stop interrupted is run again by the next run, on the same commit, with no agent.
    @Test func theNextRunAdoptsTheCommitTheCancelLeft() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")], tries: 1); defer { r.cleanup() }
        let from = try await agentCommits(r), hold = Hold()
        // M2c: the agent committed seconds before the cancel (a commit of the cancel's very second is not adopted)
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", at: Date(timeIntervalSinceNow: -5), in: $0) }))
        await r.host.setProbe { _ in await hold.park() }
        try await expectNoVerdict(try await cancel(r, at: hold), r, from: from)
        try await r.store.update(r.work) { $0.loop?.state = .running }   // `work run` again
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(await r.host.summoned == ["w-task-a-t1"])
        #expect(await r.host.checks == 2)
        #expect(w.tasks[0].state == .done && w.tasks[0].tries == 1 && w.tasks[0].resumeFrom == nil, "\(w.notes.map(\.text))")
        #expect((w.loop?.events ?? []).contains { $0.kind == .adopted })
        #expect(w.loop?.stopReason == nil)
    }

    /// Regression: with no cancel, a check that fails is still a verdict (counted, discarded, deferred on the last attempt).
    @Test func aCheckThatFailsWithoutACancelIsStillAVerdict() async throws {
        let r = try await LoopRig([task("a", "false")], tries: 1); defer { r.cleanup() }
        let from = try await agentCommits(r)
        #expect(await r.run() == .finished)
        let w = try await r.get(), t = w.tasks[0]
        #expect(t.state == .deferred && t.tries == 1 && t.lastFailure == "check failed (exit 1)" && t.resumeFrom == nil, "\(t)")
        #expect(w.loop?.used == 1 && w.loop?.stopReason == nil)
        #expect(w.jobs[0].state == .finished)
        #expect(FileManager.default.fileExists(atPath: r.host.patchDir(r.work).appendingPathComponent("a-1.patch").path))
        #expect(try await git(r.repo, "rev-parse", "HEAD") == from)
    }

    /// Regression: a gate that fails without a cancel is a verdict too.
    @Test func aGateThatFailsWithoutACancelIsStillAVerdict() async throws {
        let r = try await LoopRig([task("a", "true")], tries: 1, gate: "exit 3"); defer { r.cleanup() }
        _ = try await agentCommits(r)
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred && w.loop?.used == 1 && w.tasks[0].lastFailure?.contains("gate") == true, "\(w.tasks[0])")
    }
}
