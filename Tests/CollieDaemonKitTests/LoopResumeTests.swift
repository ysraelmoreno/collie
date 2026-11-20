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

/// M2.2a: a daemon that fell mid-attempt left the task `open` with `resumeFrom`/`resumeBranch`; when the commit is
/// already there, the next run judges it (an adoption) instead of calling a fresh agent.
@Suite struct LoopResumeTests {
    /// The fall: the task carries `from` (default: the HEAD now) and `branch` (default: the one checked out), and
    /// `file` (if any) is committed after it, as the dead agent did. Returns the sha the task resumes from.
    @discardableResult
    private func fall(_ r: LoopRig, from: String? = nil, branch: String? = nil, tries: Int? = nil, commit file: String? = "done.txt") async throws -> String {
        let head = try await git(r.repo, "rev-parse", "HEAD"), on = try await git(r.repo, "rev-parse", "--abbrev-ref", "HEAD")
        if let file { try await commit(file, "ok\n", in: r.repo) }
        try await r.store.update(r.work) { $0.tasks[0].resumeFrom = from ?? head; $0.tasks[0].resumeBranch = branch ?? on; $0.tasks[0].tries = tries
            $0.tasks[0].resumeAt = Date()   // M2b.1: left after the dead agent's commit
        }
        return from ?? head
    }

    private func adopted(_ w: Work) -> Bool { (w.loop?.events ?? []).contains { $0.kind == .adopted } }

    @Test func aCommitLeftByTheFallIsAdoptedWithoutAnAgent() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")], max: 2); defer { r.cleanup() }
        let from = try await fall(r, tries: 1)
        #expect(await r.run() == .finished)
        let w = try await r.get(), ev = w.loop?.events ?? []
        #expect(await r.host.summoned.isEmpty)
        #expect(await r.host.dismissed.isEmpty)
        #expect(await r.host.prompts.isEmpty)
        // it counts as the next attempt: of the task's tries and of `--max`
        #expect(w.tasks[0].state == .done && w.tasks[0].tries == 2, "\(w.notes.map(\.text))")
        #expect(w.loop?.used == 1 && w.jobs.map(\.id) == ["loop-a-2"] && w.jobs[0].state == .finished)
        #expect(await r.host.checks == 1)
        // the usual evidence, measured from the sha it resumed from
        #expect(w.tasks[0].evidence?.commits.count == 1 && w.tasks[0].evidence?.attempt == 2)
        let i = try #require(ev.firstIndex { $0.kind == .adopted })
        #expect(ev[i].task == "a" && ev[i].attempt == 2 && ev[i].detail == String(from.prefix(7)))
        #expect(ev.map(\.kind) == [.attemptStarted, .adopted, .checkStarted, .checkFinished, .verdict], "\(ev.map(\.kind.rawValue))")
        #expect(w.tasks[0].resumeFrom == nil && w.tasks[0].resumeBranch == nil)
    }

    @Test func anAdoptionGoesThroughTheGateToo() async throws {
        let r = try await LoopRig([task("a", "true")], gate: "test -f done.txt"); defer { r.cleanup() }
        try await fall(r)
        #expect(await r.run() == .finished)
        #expect(try await r.get().tasks[0].state == .done)
        #expect(await r.host.commands == ["true", "test -f done.txt"])
        #expect(await r.host.summoned.isEmpty)
    }

    /// M2b.1 changed this on purpose: a failed adoption used to be discarded (`reset --hard` to the sha it resumed
    /// from) and tried again with an agent; it now deletes nothing and stops the loop (`LoopResumeSafetyTests`).
    @Test func anAdoptionWhoseCheckFailsStopsTheLoopAndDiscardsNothing() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")]); defer { r.cleanup() }
        try await fall(r, commit: "wrong.txt")
        let head = try await git(r.repo, "rev-parse", "HEAD")
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(await r.host.summoned.isEmpty)
        #expect(w.loop?.stopReason?.code == .adoptionFailed)
        #expect(w.tasks[0].state == .open && w.tasks[0].lastFailure == "check failed (exit 1)", "\(w.notes.map(\.text))")
        // the adopted commit is still there, and no patch was written
        #expect(try await git(r.repo, "rev-parse", "HEAD") == head)
        #expect(!FileManager.default.fileExists(atPath: r.host.patchDir(r.work).appendingPathComponent("a-1.patch").path))
        #expect((w.loop?.events ?? []).filter { $0.kind == .adopted }.map(\.attempt) == [1])
        #expect(w.tasks[0].resumeFrom == nil && w.tasks[0].resumeBranch == nil)
    }

    @Test func anotherBranchIsIgnoredAndCleared() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")]); defer { r.cleanup() }
        try await fall(r, branch: "some-other-branch")
        await r.host.set("loop-a-1", LoopScript(act: { try await commit("more.txt", "x\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(await r.host.summoned == ["loop-a-1"] && !adopted(w))
        #expect(w.tasks[0].state == .done && w.tasks[0].resumeFrom == nil && w.tasks[0].resumeBranch == nil)
        // judged from the HEAD of now: only the agent's own commit is the attempt's
        #expect(w.tasks[0].evidence?.commits.count == 1)
    }

    @Test func aHeadThatIsNotAheadIsIgnored() async throws {
        let r = try await LoopRig([task("a", "true")], tries: 1); defer { r.cleanup() }
        try await fall(r, commit: nil)
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(await r.host.summoned == ["loop-a-1"] && !adopted(w))
        #expect(w.tasks[0].state == .deferred && w.tasks[0].lastFailure == "no new commit" && w.tasks[0].resumeFrom == nil)
    }

    @Test func aDirtyTreeIsIgnoredAndStopsTheLoopAsBefore() async throws {
        let r = try await LoopRig([task("a", "true")]); defer { r.cleanup() }
        try await fall(r)
        try "dirty\n".write(to: r.repo.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .dirtyTree && !adopted(w))
        #expect(await r.host.summoned.isEmpty)
        #expect(await r.host.checks == 0)
        #expect(w.tasks[0].state == .open && w.tasks[0].resumeFrom == nil && w.tasks[0].resumeBranch == nil)
        #expect(try String(contentsOf: r.repo.appendingPathComponent("done.txt"), encoding: .utf8) == "dirty\n")
    }

    /// A tampered `resumeFrom` never becomes a git argument: it is checked as a 40-character hex sha first.
    @Test(arguments: ["--upload-pack=touch /tmp/collie-pwned;xxxxxxxxx", "abc123", "HEAD", "ABCDEF0123456789ABCDEF0123456789ABCDEF01",
                      String(repeating: "g", count: 40), "main", ""])
    func aResumeFromThatIsNotAShaNeverReachesGit(_ bad: String) async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")]); defer { r.cleanup() }
        try await fall(r, from: bad)
        await r.host.set("loop-a-1", LoopScript(act: { try await commit("more.txt", "x\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(await r.host.summoned == ["loop-a-1"] && !adopted(w))
        #expect(w.tasks[0].state == .done && w.tasks[0].resumeFrom == nil)
        if !bad.isEmpty, bad != "HEAD", bad != "main" {   // those two are the loop's own arguments
            #expect(!(await r.host.gits).contains { $0.contains { $0.contains(bad) } })
        }
    }

    @Test func aShaThatIsNotInTheRepositoryIsIgnored() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")]); defer { r.cleanup() }
        let ghost = String(repeating: "a", count: 40)
        try await fall(r, from: ghost)
        await r.host.set("loop-a-1", LoopScript(act: { try await commit("more.txt", "x\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(await r.host.summoned == ["loop-a-1"] && !adopted(w))
        #expect(w.tasks[0].state == .done && w.tasks[0].resumeFrom == nil)
        // it was only asked about, never a base for a diff, a reset or a log
        #expect(!(await r.host.gits).contains { $0.first != "cat-file" && $0.contains { $0.contains(ghost) } })
    }

    @Test func aTaskWithoutResumeFromRunsAsBeforeAndCarriesItOnlyDuringTheAttempt() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")]); defer { r.cleanup() }
        let head = try await git(r.repo, "rev-parse", "HEAD"), on = try await git(r.repo, "rev-parse", "--abbrev-ref", "HEAD")
        final class Seen: @unchecked Sendable { var from: String?, branch: String? }
        let seen = Seen(), store = r.store, id = r.work
        // while the attempt runs (here: at its check) the work's file says where a fall would resume from
        await r.host.setProbe { _ in
            let t = (try? await store.get(id))?.tasks[0]
            seen.from = t?.resumeFrom; seen.branch = t?.resumeBranch
        }
        await r.host.set("loop-a-1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(seen.from == head && seen.branch == on)
        #expect(await r.host.summoned == ["loop-a-1"] && !adopted(w))
        #expect(w.tasks[0].state == .done && w.tasks[0].tries == 1 && w.tasks[0].resumeFrom == nil && w.tasks[0].resumeBranch == nil)
    }

    @Test func aFailedAttemptClearsIt() async throws {
        let r = try await LoopRig([task("a", "false")], tries: 1); defer { r.cleanup() }
        await r.host.set("loop-a-1", LoopScript(act: { try await commit("x.txt", "x\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred && w.tasks[0].resumeFrom == nil && w.tasks[0].resumeBranch == nil)
    }

    /// `stopLoopsLeftRunning`'s write: the interrupted task is open again and still says where to resume from.
    @Test func theStartSweepKeepsResumeFrom() {
        let sha = String(repeating: "1", count: 40)
        var t = WorkTask(id: "a", title: "A", state: .inProgress)
        t.resumeFrom = sha; t.resumeBranch = "main"
        var w = Work(title: "W", terminalId: UUID(), tasks: [t], jobs: [WorkJob(id: "loop-a-1", kind: .loop, label: "A")])
        w.loop = WorkLoopState(state: .running, task: "a", attempt: 1)
        CommandRouter.sweepLeftRunning(&w, now: Date(timeIntervalSince1970: 9))
        #expect(w.tasks[0].state == .open && w.tasks[0].resumeFrom == sha && w.tasks[0].resumeBranch == "main")
        #expect(w.loop?.stopReason?.code == .daemonRestart && w.jobs[0].state == .gone)
    }

    @Test func anOldFileDecodesAndTheFieldsRoundTrip() throws {
        let old = #"{"id":"a","title":"A","state":"open","updatedAt":0}"#
        var t = try JSONDecoder().decode(WorkTask.self, from: Data(old.utf8))
        #expect(t.resumeFrom == nil && t.resumeBranch == nil)
        t.resumeFrom = String(repeating: "2", count: 40); t.resumeBranch = "main"
        #expect(try JSONDecoder().decode(WorkTask.self, from: JSONEncoder().encode(t)) == t)
        #expect(try JSONDecoder().decode(LoopEvent.Kind.self, from: Data(#""adopted""#.utf8)) == .adopted)
    }

    @Test func onlyAFullLowercaseHexShaIsOne() {
        #expect(WorkLoop.isSha("0123456789abcdef0123456789abcdef01234567"))
        for bad in ["", "abc", "0123456789abcdef0123456789abcdef0123456", "0123456789abcdef0123456789abcdef012345678",
                    "0123456789ABCDEF0123456789abcdef01234567", "-123456789abcdef0123456789abcdef01234567",
                    "０123456789abcdef0123456789abcdef0123456", "0123456789abcdef0123456789abcdef0123456\n"] {
            #expect(!WorkLoop.isSha(bad), "\(bad)")
        }
    }

    /// The machine: an adoption skips the agent and goes straight to the facts, then on as any attempt.
    @Test func theMachineAdoptsStraightToTheFacts() {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        let (s, fx) = AttemptMachine.reduce(.init(task: "a", n: 2, tries: 3, hasGate: false, before: sha), .adopted)
        #expect(s.phase == .waitingCommit && s.agent == nil)
        #expect(fx == [.journal(.attemptStarted, nil), .journal(.adopted, "0123456"), .measureFacts])
        let (c, more) = AttemptMachine.reduce(s, .measured(.init(committed: true, dirty: false, judged: "f00")))
        #expect(c.phase == .checking && more == [.show(.check), .journal(.checkStarted, nil), .runCheck])
        // only an attempt's first event
        let (turn, _) = AttemptMachine.reduce(.init(task: "a", n: 1, tries: 3, hasGate: false, before: sha), .summoned(UUID()))
        #expect(AttemptMachine.reduce(turn, .adopted).1 == [.fault("turn × adopted")])
    }
}
