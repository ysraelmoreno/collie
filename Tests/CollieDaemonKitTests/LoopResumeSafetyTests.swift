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

/// M2b.1: an adoption (M2.2a) takes only what the fallen attempt left, and one that fails deletes nothing.
@Suite struct LoopResumeSafetyTests {
    /// Task `i` was left mid-attempt at the HEAD of now (or at `from`), on the branch checked out, `at` (default: now).
    /// Returns the sha it resumes from.
    @discardableResult
    private func fall(_ r: LoopRig, task i: Int = 0, from: String? = nil, at: Date? = nil, commit file: String? = nil) async throws -> String {
        let head = try await git(r.repo, "rev-parse", "HEAD"), on = try await git(r.repo, "rev-parse", "--abbrev-ref", "HEAD")
        if let file { try await commit(file, "ok\n", in: r.repo) }
        let left = at ?? Date() + 1   // M2c: a commit of the very second of `resumeAt` is not adopted
        try await r.store.update(r.work) { $0.tasks[i].resumeFrom = from ?? head; $0.tasks[i].resumeBranch = on; $0.tasks[i].resumeAt = left }
        return from ?? head
    }

    private func adopted(_ w: Work) -> Bool { (w.loop?.events ?? []).contains { $0.kind == .adopted } }
    private func resumes(_ t: WorkTask) -> Bool { t.resumeFrom != nil || t.resumeBranch != nil || t.resumeAt != nil }

    // (a)
    @Test func aCommitOfAnotherTaskIsNeverAdoptedNorDeleted() async throws {
        let r = try await LoopRig([task("a", "test -f y.txt"), task("b", "false")], tries: 1); defer { r.cleanup() }
        // B fell at X with no commit of its own; A (reopened by the owner) runs first and commits Y
        let x = try await fall(r, task: 1)
        final class Seen: @unchecked Sendable { var y = "", bCleared = false }
        let seen = Seen(), store = r.store, id = r.work
        await r.host.set("loop-a-1", LoopScript(act: { d in
            if let w = try? await store.get(id) { seen.bCleared = w.tasks[1].resumeFrom == nil && w.tasks[1].resumeAt == nil }
            try await commit("y.txt", "y\n", in: d); seen.y = try await git(d, "rev-parse", "HEAD")
        }))
        await r.host.set("loop-b-1", LoopScript(act: { try await commit("z.txt", "z\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        // B's was cleared when A's attempt began
        #expect(seen.bCleared)
        #expect(await r.host.summoned == ["loop-a-1", "loop-b-1"] && !adopted(w))
        #expect(w.tasks[0].state == .done && w.tasks[1].state == .deferred, "\(w.notes.map(\.text))")
        // B failed and was discarded back to where B began: Y, not X
        #expect(try await git(r.repo, "rev-parse", "HEAD") == seen.y && seen.y != x)
        #expect(FileManager.default.fileExists(atPath: r.repo.appendingPathComponent("y.txt").path))
        #expect(!(await r.host.gits).contains { $0.contains("--hard") && $0.contains(x) })
        #expect(!resumes(w.tasks[0]) && !resumes(w.tasks[1]))
    }

    // (b)
    @Test(arguments: [TaskState.abandoned, .deferred, .done])
    func aStateSetByHandClearsThem(_ state: TaskState) async throws {
        let r = try await LoopRig([task("a", "true")]); defer { r.cleanup() }
        try await fall(r)
        let t = try #require(try await r.store.setTask(r.work, task: "a", state: state, reason: "x", at: Date()))
        #expect(t.state == state && !resumes(t))
        #expect(!resumes(try await r.get().tasks[0]))
    }

    @Test func reopenClearsThem() async throws {
        let r = try await LoopRig([task("a", "true")]); defer { r.cleanup() }
        let sha = try await git(r.repo, "rev-parse", "HEAD")
        // as a file written before M2b.1 may hold: a deferred task still carrying them
        try await r.store.update(r.work) {
            $0.tasks[0].state = .deferred; $0.tasks[0].resumeFrom = sha; $0.tasks[0].resumeBranch = "main"; $0.tasks[0].resumeAt = Date()
        }
        let re = try #require(try await r.store.reopenTask(r.work, task: "a", keepTries: false, at: Date()))
        #expect(re.task.state == .open && !resumes(re.task))
    }

    @Test func anyStateOutOfTheLoopClearsThem() {
        for state in [TaskState.done, .deferred, .abandoned] {
            var t = WorkTask(id: "a", title: "A", state: .inProgress)
            t.resumeFrom = String(repeating: "1", count: 40); t.resumeBranch = "main"; t.resumeAt = Date()
            t.state = .open
            #expect(resumes(t))
            t.state = state
            #expect(!resumes(t), "\(state)")
        }
    }

    // (c)
    @Test func aCommitMadeAfterTheFallIsNotAdopted() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")]); defer { r.cleanup() }
        // the attempt was left an hour ago; the owner committed now
        try await fall(r, at: Date(timeIntervalSinceNow: -3600), commit: "owner.txt")
        let owner = try await git(r.repo, "rev-parse", "HEAD")
        await r.host.set("loop-a-1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(await r.host.summoned == ["loop-a-1"] && !adopted(w))
        #expect(w.tasks[0].state == .done && !resumes(w.tasks[0]), "\(w.notes.map(\.text))")
        // judged from the HEAD of now: the owner's commit is not the attempt's, and it is still there
        #expect(w.tasks[0].evidence?.commits.count == 1)
        #expect(try await git(r.repo, "rev-parse", "HEAD~1") == owner)
    }

    @Test func withoutResumeAtNothingIsAdopted() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")]); defer { r.cleanup() }
        try await fall(r, commit: "done.txt")
        try await r.store.update(r.work) { $0.tasks[0].resumeAt = nil }
        await r.host.set("loop-a-1", LoopScript(act: { try await commit("more.txt", "x\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(await r.host.summoned == ["loop-a-1"] && !adopted(w))
        #expect(w.tasks[0].state == .done)
    }

    // (d)
    @Test func aFailedAdoptionResetsNothingAndStopsTheLoop() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt"), task("b", "true")]); defer { r.cleanup() }
        try await fall(r, commit: "wrong.txt")
        try "mine\n".write(to: r.repo.appendingPathComponent("loose.txt"), atomically: true, encoding: .utf8)   // the owner's, untracked
        let head = try await git(r.repo, "rev-parse", "HEAD"), status = try await git(r.repo, "status", "--porcelain")
        let log = try await git(r.repo, "log", "--format=%H")
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(adopted(w))
        #expect(await r.host.summoned.isEmpty)
        #expect(try await git(r.repo, "rev-parse", "HEAD") == head)
        #expect(try await git(r.repo, "status", "--porcelain") == status)
        #expect(try await git(r.repo, "log", "--format=%H") == log)
        let gits = await r.host.gits
        #expect(!gits.contains { $0.contains("--hard") || $0.first == "checkout" || $0.contains("clean") }, "\(gits)")
        #expect(!FileManager.default.fileExists(atPath: r.host.patchDir(r.work).path))
        #expect(w.loop?.state == .stopped && w.loop?.stopReason?.code == .adoptionFailed)
        #expect(w.tasks[0].state == .open && !resumes(w.tasks[0]) && w.tasks[0].tries == nil)
        #expect(w.tasks[0].lastFailure == "check failed (exit 1)")
        #expect(w.tasks[1].state == .open)   // the loop stopped: no next task
        #expect(w.jobs.map(\.state) == [.finished])
        #expect(w.notes.contains { $0.text == "[loop] adoção de \"Task a\" falhou: check failed (exit 1); nada foi apagado" }, "\(w.notes.map(\.text))")
        #expect(w.notes.last?.text == WorkLoopState.Stop(.adoptionFailed).note)
        #expect(!(w.loop?.events ?? []).contains { $0.kind == .discarded })
    }

    @Test func aFailedGateOfAnAdoptionResetsNothingEither() async throws {
        let r = try await LoopRig([task("a", "true")], gate: "test -f done.txt"); defer { r.cleanup() }
        try await fall(r, commit: "wrong.txt")
        let head = try await git(r.repo, "rev-parse", "HEAD")
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .adoptionFailed && w.tasks[0].state == .open && !resumes(w.tasks[0]))
        #expect(try await git(r.repo, "rev-parse", "HEAD") == head)
        #expect(!(await r.host.gits).contains { $0.contains("--hard") })
    }

    /// The machine: a failed adoption has no discard and no wait for other terminals (there is no reset to protect).
    @Test func theMachineNeverDiscardsAFailedAdoption() {
        typealias M = AttemptMachine
        var (s, fx) = M.reduce(.init(task: "a", n: 1, tries: 1, hasGate: false, before: "0123456789abcdef0123456789abcdef01234567"), .adopted)
        for e in [M.Event.measured(.init(committed: true, dirty: false, judged: "f00")), .checkDone(status: 1, broken: nil),
                  .blocked(nil), .settled(moved: false, reset: false)] {
            (s, fx) = M.reduce(s, e)
        }
        #expect(fx == [.show(nil), .journal(.verdict, "check failed (exit 1)"), .decide])
        (s, fx) = M.reduce(s, .decided(AttemptDecision.decide(s.facts)))
        #expect(s.phase == .finished)
        #expect(fx == [.adoptionFailed(reason: "check failed (exit 1)"), .stopLoop(.init(.adoptionFailed))])
        #expect(!M.Effect.adoptionFailed(reason: "x").answers)
    }

    // (e)
    @Test func anAdoptionOfCommitsMadeBeforeTheFallStillPassesThroughTheGate() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")], gate: "test -f done.txt && echo gate"); defer { r.cleanup() }
        try await fall(r, commit: "done.txt")
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(adopted(w))
        #expect(await r.host.summoned.isEmpty)
        #expect(w.tasks[0].state == .done && !resumes(w.tasks[0]), "\(w.notes.map(\.text))")
        #expect(await r.host.commands == ["test -f done.txt", "test -f done.txt && echo gate"])
    }

    /// What leaves `resumeAt`: the start sweep (a daemon that fell) and a cancelled attempt (`LoopCancelTests`).
    @Test func theStartSweepSaysWhenTheAttemptWasLeft() {
        let now = Date(timeIntervalSince1970: 9)
        var t = WorkTask(id: "a", title: "A", state: .inProgress)
        t.resumeFrom = String(repeating: "1", count: 40); t.resumeBranch = "main"
        var w = Work(title: "W", terminalId: UUID(), tasks: [t, WorkTask(id: "b", title: "B")], jobs: [WorkJob(id: "loop-a-1", kind: .loop, label: "A")])
        w.loop = WorkLoopState(state: .running, task: "a", attempt: 1)
        CommandRouter.sweepLeftRunning(&w, now: now)
        #expect(w.tasks[0].state == .open && w.tasks[0].resumeAt == now && w.tasks[1].resumeAt == nil)
    }

    // (f)
    @Test(arguments: ["--upload-pack=x", "-c", "ABCDEF0123456789ABCDEF0123456789ABCDEF01", String(repeating: "a", count: 39)])
    func aResumeFromThatIsNotAShaIsNeverAGitArgument(_ bad: String) async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")]); defer { r.cleanup() }
        try await fall(r, from: bad, commit: "done.txt")
        await r.host.set("loop-a-1", LoopScript(act: { try await commit("more.txt", "x\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(await r.host.summoned == ["loop-a-1"] && !adopted(w))
        #expect(w.tasks[0].state == .done && !resumes(w.tasks[0]))
        let gits = await r.host.gits
        #expect(!gits.isEmpty)
        #expect(!gits.contains { $0.contains { $0 == bad || $0.hasPrefix(bad + "..") || $0.hasPrefix(bad + "^") } }, "\(gits)")
    }

    // (g)
    @Test(arguments: [#""resumeFrom":7"#, #""resumeFrom":{"x":1}"#, #""resumeBranch":[1]"#, #""resumeAt":"ontem""#, #""resumeAt":{}"#,
                      #""resumeFrom":7,"resumeBranch":false,"resumeAt":[]"#])
    func aResumeFieldOfTheWrongTypeIsNilAndTheTaskSurvives(_ field: String) throws {
        let json = #"{"id":"a","title":"A","state":"open","updatedAt":0,"spec":"/s.md","check":"true","tries":2,"lastFailure":"x",\#(field)}"#
        let t = try JSONDecoder().decode(WorkTask.self, from: Data(json.utf8))
        #expect(t.id == "a" && t.title == "A" && t.state == .open && t.spec == "/s.md" && t.check == "true" && t.tries == 2 && t.lastFailure == "x")
        #expect(t.resumeFrom == nil && t.resumeBranch == nil && t.resumeAt == nil)
        // inside a work too: the work's file still loads
        let work = #"{"id":"\#(UUID().uuidString)","title":"W","terminalId":"\#(UUID().uuidString)","openedAt":0,"tasks":[\#(json)],"jobs":[],"notes":[],"commits":[]}"#
        #expect(try JSONDecoder().decode(Work.self, from: Data(work.utf8)).tasks.count == 1)
    }

    @Test func theFieldsRoundTripAndARequiredOneStillFails() throws {
        var t = WorkTask(id: "a", title: "A")
        t.resumeFrom = String(repeating: "2", count: 40); t.resumeBranch = "main"; t.resumeAt = Date(timeIntervalSince1970: 5)
        #expect(try JSONDecoder().decode(WorkTask.self, from: JSONEncoder().encode(t)) == t)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WorkTask.self, from: Data(#"{"id":"a","state":"open","updatedAt":0}"#.utf8)) }
    }

    @Test func theNewStopCodeDecodesAndAnUnknownOneIsUnknown() throws {
        typealias Code = WorkLoopState.Stop.Code
        #expect(try JSONDecoder().decode(Code.self, from: Data(#""adoptionFailed""#.utf8)) == .adoptionFailed)
        #expect(try JSONDecoder().decode(Code.self, from: Data(#""somethingNewer""#.utf8)) == .unknown)
        #expect(WorkLoopState.Stop(.adoptionFailed).label == "a adoção do commit interrompido falhou; a árvore ficou intocada para você decidir")
    }
}
