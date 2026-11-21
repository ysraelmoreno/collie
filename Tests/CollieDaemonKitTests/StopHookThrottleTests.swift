import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

/// M5.2: Claude's Stop asks for memories only when it makes sense: never while a loop runs the terminal's work, at most
/// once every 20 minutes, and only for real new work (a task done, or a commit that is not a loop attempt's).
@Suite struct StopHookThrottleTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// A work last asked about at `t0` (commit `aaa1111 base`), with `commits` after it.
    func work(_ commits: [String] = [], loop: WorkLoopState.State? = nil) -> Work {
        var w = Work(title: "W", terminalId: UUID(), commits: ["aaa1111 base"] + commits)
        w.capturedAt = t0; w.capturedCommit = "aaa1111 base"; w.askedAt = t0
        if let loop { w.loop = WorkLoopState(state: loop) }
        return w
    }
    func loopTask(_ commits: [String], doneAt: Date) -> WorkTask {
        var t = WorkTask(id: "m", title: "loop task", state: .done, updatedAt: doneAt)
        t.evidence = TaskEvidence(commits: commits, shortstat: "", checkTail: "", seconds: 1, attempt: 1)
        return t
    }

    @Test func loopRunningNeverAsks() {
        var w = work(["bbb2222 owner"], loop: .running)
        w.tasks = [WorkTask(id: "a", title: "a", state: .done, updatedAt: at(30))]
        #expect(!MemoryCapture.shouldAsk(w, now: at(60)))
    }

    @Test func twoAsksInFiveMinutesOnlyFirst() {
        var w = work(["bbb2222 owner"]); w.askedAt = nil
        #expect(MemoryCapture.shouldAsk(w, now: at(1)))
        w.askedAt = at(1)   // the ask went out (capturedAt stays: new work still pending)
        #expect(!MemoryCapture.shouldAsk(w, now: at(5)))
    }

    @Test func afterTwentyMinutesAsksAgain() {
        let w = work(["bbb2222 owner"])
        #expect(!MemoryCapture.shouldAsk(w, now: at(19)))
        #expect(MemoryCapture.shouldAsk(w, now: at(20)))
    }

    @Test func loopCommitDoesNotCount() {
        var w = work(["ccc3333 loop attempt"], loop: .finished)
        w.tasks = [loopTask(["ccc3333 loop attempt"], doneAt: t0.addingTimeInterval(-60))]   // done before the last ask
        #expect(!MemoryCapture.shouldAsk(w, now: at(30)))
        // a commit the loop saw (journal) but never approved: still the loop's
        w.commits.append("ddd4444 failed attempt")
        w.loop?.record(LoopEvent(kind: .commitSeen, task: "m", attempt: 2, detail: "ddd4444"))
        #expect(!MemoryCapture.shouldAsk(w, now: at(30)))
    }

    @Test func ownerCommitCounts() {
        var w = work(["ccc3333 loop attempt", "eee5555 owner fix"], loop: .finished)
        w.tasks = [loopTask(["ccc3333"], doneAt: t0.addingTimeInterval(-60))]
        #expect(MemoryCapture.shouldAsk(w, now: at(30)))
    }

    @Test func loopEndedAsksOnce() {
        var w = work(["ccc3333 loop attempt"], loop: .finished)
        w.tasks = [loopTask(["ccc3333 loop attempt"], doneAt: at(10))]
        #expect(MemoryCapture.shouldAsk(w, now: at(30)))
        w.capturedAt = at(30); w.capturedCommit = w.commits.last; w.askedAt = at(30)   // what stopAsk marks
        #expect(!MemoryCapture.shouldAsk(w, now: at(31)))
        #expect(!MemoryCapture.shouldAsk(w, now: at(90)))   // nothing new since
    }

    @Test func noWorkNoAsk() {
        #expect(!MemoryCapture.shouldAsk(work(), now: at(60)))
    }

    @Test func missingStateNoAsk() {
        #expect(!MemoryCapture.shouldAsk(nil, now: at(60)))
        // a work from before M5.2 (no askedAt) is not throttled, and its old marks still decide
        var w = work(["bbb2222 owner"]); w.askedAt = nil
        #expect(MemoryCapture.shouldAsk(w, now: at(0)))
        let json = try! JSONEncoder().encode(w)
        #expect(try! JSONDecoder().decode(Work.self, from: json).askedAt == nil)
    }

    @Test func askedAtRoundTrips() throws {
        let w = work()
        #expect(try JSONDecoder().decode(Work.self, from: JSONEncoder().encode(w)).askedAt == t0)
    }
}
