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

/// Commits `file` with the committer date `date` (whole seconds, as `%ct` reads it): no test waits for the wall clock.
func commit(_ file: String, at date: Date, in dir: URL) async throws {
    try "ok\n".write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
    _ = try await GitRunner.run(["add", "."], in: dir)
    var env = ProcessInfo.processInfo.environment
    env["GIT_COMMITTER_DATE"] = "\(Int(date.timeIntervalSince1970)) +0000"
    let r = try await BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/git"), args: ["commit", "-m", "edit \(file)"],
                                         in: dir, env: env, timeout: .seconds(30))
    #expect(r.status == 0, "git commit: \(r.stderr)")
}

private func task(_ id: String, _ check: String) -> WorkTask { WorkTask(id: id, title: "Task \(id)", check: check) }

/// M2c: `resumeAt` is when the attempt was first left and an adoption never moves it forward, and a commit made in
/// the very second of `resumeAt` is not the attempt's.
@Suite struct LoopResumeNitsTests {
    /// A whole second, well in the past: what the store writes and reads back is the same `Date`.
    private let fell = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 100).rounded(.down))

    /// Task `i` was left at the HEAD of now, on the branch checked out, at `at`. Returns the sha it resumes from.
    @discardableResult
    private func fall(_ r: LoopRig, task i: Int = 0, at: Date) async throws -> String {
        let head = try await git(r.repo, "rev-parse", "HEAD"), on = try await git(r.repo, "rev-parse", "--abbrev-ref", "HEAD")
        try await r.store.update(r.work) { $0.tasks[i].resumeFrom = head; $0.tasks[i].resumeBranch = on; $0.tasks[i].resumeAt = at }
        return head
    }

    private func adoptions(_ w: Work) -> Int { (w.loop?.events ?? []).filter { $0.kind == .adopted }.count }

    // (a)
    @Test func aCancelledAdoptionKeepsTheResumeAtOfTheFirstFall() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")]); defer { r.cleanup() }
        let from = try await fall(r, at: fell)
        try await commit("done.txt", at: fell - 10, in: r.repo)   // the fallen attempt's
        // during the adopted check the owner commits, and the daemon stops before the verdict
        final class Seen: @unchecked Sendable { var during: Date?, state: TaskState? }
        let seen = Seen(), store = r.store, id = r.work, repo = r.repo, loop = r.loop
        await r.host.setProbe { _ in
            if let t = try? await store.get(id)?.tasks[0] { seen.during = t.resumeAt; seen.state = t.state }
            try? await commit("owner.txt", "mine\n", in: repo)
            withUnsafeCurrentTask { $0?.cancel() }
        }
        #expect(await Task { await loop.run(work: id, dir: repo) }.value == .stopped)
        var w = try await r.get()
        #expect(adoptions(w) == 1 && w.loop?.stopReason == .init(.cancelled), "\(w.notes.map(\.text))")
        // mid-adoption (what a second fall would leave) and after the cancel: still the first fall's
        #expect(seen.state == .inProgress && seen.during == fell)
        #expect(w.tasks[0].state == .open && w.tasks[0].resumeFrom == from && w.tasks[0].resumeAt == fell, "\(w.tasks[0])")
        // `work run` again: the owner's commit came after the first fall, so nothing is adopted
        let owner = try await git(r.repo, "rev-parse", "HEAD")
        await r.host.setProbe { _ in }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("more.txt", "x\n", in: $0) }))
        try await r.store.update(r.work) { $0.loop?.state = .running }
        #expect(await r.run() == .finished)
        w = try await r.get()
        #expect(adoptions(w) == 1)
        #expect(await r.host.summoned == ["w-task-a-t1"])
        #expect(w.tasks[0].state == .done && w.tasks[0].resumeAt == nil && w.tasks[0].resumeFrom == nil, "\(w.notes.map(\.text))")
        #expect(w.tasks[0].evidence?.commits.count == 1)   // judged from the owner's commit on
        #expect(try await git(r.repo, "rev-parse", "HEAD~1") == owner)
    }

    /// A cancelled attempt that adopted nothing still says when it was left (M2b.1).
    @Test func aCancelledAttemptWithoutAdoptionSaysWhenItWasLeft() async throws {
        let r = try await LoopRig([task("a", "true")]); defer { r.cleanup() }
        let began = Date()
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        await r.host.setProbe { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let id = r.work, repo = r.repo, loop = r.loop
        #expect(await Task { await loop.run(work: id, dir: repo) }.value == .stopped)
        let t = try await r.get().tasks[0]
        #expect(t.state == .open && t.resumeFrom != nil)
        #expect(try #require(t.resumeAt) >= began - 1)
    }

    // (b)
    @Test func theStartSweepKeepsAResumeAtAlreadyThere() {
        let later = fell + 50
        var t = WorkTask(id: "a", title: "A", state: .inProgress)
        t.resumeFrom = String(repeating: "1", count: 40); t.resumeBranch = "main"; t.resumeAt = fell
        var w = Work(title: "W", terminalId: UUID(), tasks: [t], jobs: [WorkJob(id: "w-a-t1", kind: .loop, label: "A")])
        w.loop = WorkLoopState(state: .running, task: "a", attempt: 1)
        CommandRouter.sweepLeftRunning(&w, now: later)
        #expect(w.tasks[0].state == .open && w.tasks[0].resumeAt == fell)
        #expect(w.loop?.state == .stopped && w.loop?.endedAt == later)
    }

    // (c)
    @Test func anAttemptThatAdoptsNothingClearsResumeAtAndWhatOtherTasksResumedFrom() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt"), task("b", "true")], tries: 1); defer { r.cleanup() }
        // both were left with no commit of their own: nothing to adopt
        let head = try await fall(r, at: fell)
        try await fall(r, task: 1, at: fell)
        final class Seen: @unchecked Sendable { var mine: WorkTask?, other: WorkTask? }
        let seen = Seen(), store = r.store, id = r.work
        await r.host.set("w-task-a-t1", LoopScript(act: { d in
            if let w = try? await store.get(id) { seen.mine = w.tasks[0]; seen.other = w.tasks[1] }
            try await commit("done.txt", "ok\n", in: d)
        }))
        await r.host.set("w-task-b-t1", LoopScript(act: { try await commit("z.txt", "z\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(adoptions(w) == 0)
        #expect(await r.host.summoned == ["w-task-a-t1", "w-task-b-t1"])
        let mine = try #require(seen.mine), other = try #require(seen.other)
        #expect(mine.state == .inProgress && mine.resumeFrom == head && mine.resumeBranch == "main" && mine.resumeAt == nil, "\(mine)")
        #expect(other.resumeFrom == nil && other.resumeBranch == nil && other.resumeAt == nil, "\(other)")
        #expect(w.tasks.allSatisfy { $0.state == .done && $0.resumeFrom == nil && $0.resumeAt == nil }, "\(w.notes.map(\.text))")
    }

    // (d): `%ct` is whole seconds and `resumeAt` has a fraction: the second of `resumeAt` itself is in doubt
    @Test(arguments: [(-1, true), (0, false), (1, false)])
    func aCommitIsAdoptedOnlyWhenMadeBeforeTheSecondOfResumeAt(offset: Int, adopts: Bool) async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")]); defer { r.cleanup() }
        try await fall(r, at: fell + 0.7)
        try await commit("done.txt", at: fell + Double(offset), in: r.repo)
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("more.txt", "x\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(adoptions(w) == (adopts ? 1 : 0))
        #expect(await r.host.summoned == (adopts ? [] : ["w-task-a-t1"]))
        #expect(w.tasks[0].state == .done && w.tasks[0].resumeAt == nil, "\(w.notes.map(\.text))")
    }
}
