import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// C5c: the loop's first phase, the "check já passa" pre-check, run by the engine (a fake host, real checks in a temp
/// repo): its own ceiling (past it: red), a green check stops the loop with `checkAlreadyGreen` and no attempt,
/// `--green-ok` skips it, `work stop` cancels it at once.
@Suite struct PreCheckTests {
    private static func rig(_ tasks: [WorkTask], ceiling: Duration = .seconds(30)) async throws -> (LoopRig, WorkLoop) {
        let r = try await LoopRig(tasks, tries: 1)
        try await r.store.update(r.work) { $0.loop?.greenPreCheck = true }
        let loop = WorkLoop(store: r.store, host: r.host, poll: .milliseconds(10), checkTimeout: .seconds(30), othersWait: .milliseconds(50),
                            promptRetryWait: .zero, preCheckTimeout: ceiling)
        return (r, loop)
    }

    @Test func aSlowCheckPastTheCeilingCountsRed() async throws {
        // green, but only after 20 s: past the 300 ms ceiling it is red, and the attempt runs (and passes)
        let (r, loop) = try await Self.rig([WorkTask(id: "a", title: "Task a", check: "test -f a.swift || { sleep 20; true; }")], ceiling: .milliseconds(300))
        defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("a.swift", "let a = 1\n", in: $0) }))
        let t0 = ContinuousClock.now
        #expect(await loop.run(work: r.work, dir: r.repo) == .finished)
        #expect(ContinuousClock.now - t0 < .seconds(15))
        let w = try await r.get()
        #expect(w.tasks[0].state == .done && w.loop?.stopReason == nil, "\(String(describing: w.loop?.stopReason))")
        let kinds = w.loop?.events?.map(\.kind) ?? []
        #expect(kinds.first == .preCheckStarted && kinds.contains(.preCheckFinished) && kinds.contains(.attemptStarted), "\(kinds)")
        #expect(w.loop?.events?.first { $0.kind == .preCheckFinished }?.detail == "0 de 1 já passa(m)")
    }

    @Test func aGreenCheckStopsTheLoopBeforeAnyAttempt() async throws {
        let (r, loop) = try await Self.rig([WorkTask(id: "a", title: "Trivial", check: "true"), WorkTask(id: "b", title: "Real", check: "false")])
        defer { r.cleanup() }
        #expect(await loop.run(work: r.work, dir: r.repo) == .stopped)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .checkAlreadyGreen && w.loop?.stopReason?.finishes == false)
        #expect(w.loop?.stopReason?.detail == "Trivial", "\(String(describing: w.loop?.stopReason))")
        #expect(w.loop?.used == 0 && !(w.loop?.events?.contains { $0.kind == .attemptStarted } ?? true))
        #expect(w.tasks.allSatisfy { $0.state == .open })
        let note = try #require(w.notes.first { $0.text.contains(GreenCheck.reason) })
        #expect(note.text.contains("\"Trivial\" [a] check «true»") && !note.text.contains("Real") && note.text.contains("--green-ok"), "\(note.text)")
        #expect(w.notes.last?.text == WorkLoopState.Stop(.checkAlreadyGreen, detail: "Trivial").note)
        let notices = await r.host.ownerNotices
        #expect(notices.count == 1 && notices[0].contains(GreenCheck.reason) && notices[0].contains("Trivial"), "\(notices)")
    }

    @Test func greenOkSkipsThePreCheck() async throws {
        let (r, loop) = try await Self.rig([WorkTask(id: "a", title: "Task a", check: "true", greenOk: true)])
        defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("a.swift", "let a = 1\n", in: $0) }))
        #expect(await loop.run(work: r.work, dir: r.repo) == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .done && !(w.loop?.events?.contains { $0.kind == .preCheckStarted } ?? true))
    }

    @Test func aWorkStopDuringThePreCheckCancelsIt() async throws {
        let (r, loop) = try await Self.rig([WorkTask(id: "a", title: "Task a", check: "sleep 30")])
        defer { r.cleanup() }
        let store = r.store, id = r.work
        let run = Task { await loop.run(work: id, dir: r.repo) }
        #expect(await waitFor(10) { (try? await store.get(id))?.loop?.phase == .preCheck })
        let t0 = ContinuousClock.now
        await loop.stop(work: id)
        #expect(await run.value == .stopped)
        #expect(ContinuousClock.now - t0 < .seconds(10))
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .requested && w.loop?.phase == nil && w.loop?.used == 0, "\(String(describing: w.loop))")
    }

    @Test func atMostFourChecksRunAtOnce() async throws {
        let tasks = (1...6).map { WorkTask(id: "t\($0)", title: "T\($0)", check: "sleep 1; false") }
        let (r, loop) = try await Self.rig(tasks)
        defer { r.cleanup() }
        let t0 = ContinuousClock.now
        let green = await WorkLoop.greens(tasks, host: r.host, dir: r.repo, timeout: .seconds(10))
        let took = ContinuousClock.now - t0
        _ = loop
        // six of 1 s, four at a time: two rounds (not one, not six)
        #expect(green.isEmpty && took >= .seconds(2) && took < .seconds(5), "\(took)")
    }
}
