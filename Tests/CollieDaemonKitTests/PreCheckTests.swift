import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// C5c: the loop's first phase, the "check já passa" pre-check, run by the engine (a fake host whose checks a test can
/// hold or time out, no wall clock): its own ceiling (past it: red), a green check stops the loop with
/// `checkAlreadyGreen` and no attempt, `--green-ok` skips it, `work stop` cancels it, at most four at once.
@Suite struct PreCheckTests {
    private static func rig(_ tasks: [WorkTask], ceiling: Duration = .seconds(30)) async throws -> (LoopRig, WorkLoop) {
        let r = try await LoopRig(tasks, tries: 1)
        try await r.store.update(r.work) { $0.loop?.greenPreCheck = true }
        let loop = WorkLoop(store: r.store, host: r.host, poll: .milliseconds(10), checkTimeout: .seconds(30), othersWait: .milliseconds(50),
                            promptRetryWait: .zero, preCheckTimeout: ceiling)
        return (r, loop)
    }

    @Test func aSlowCheckPastTheCeilingCountsRed() async throws {
        // a green check that outlives the pre-check's ceiling: the host answers it as `BoundedProcess` does past its
        // timeout (the fake clock moved on by the ceiling, `.timeout` thrown), no wall clock; red, so the attempt runs
        let (r, loop) = try await Self.rig([WorkTask(id: "a", title: "Task a", check: "true")], ceiling: WorkLoop.defaultPreCheckTimeout)
        defer { r.cleanup() }
        let host = r.host, ceilings = Box<[Duration]>([])
        await host.setCheckStub { _, timeout throws(ProtocolError) in
            guard timeout == WorkLoop.defaultPreCheckTimeout else { return nil }   // the attempt's own check runs for real
            ceilings.value.append(timeout); host.advance(Double(timeout.components.seconds))
            throw ProtocolError(code: .timeout, message: "bash timed out")
        }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("a.swift", "let a = 1\n", in: $0) }))
        #expect(await loop.run(work: r.work, dir: r.repo) == .finished)
        #expect(ceilings.value == [.seconds(120)])
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
        let (r, loop) = try await Self.rig([WorkTask(id: "a", title: "Task a", check: "true")])
        defer { r.cleanup() }
        // the check never ends by itself: only the cancel of `work stop` wakes it
        let (entered, inside) = AsyncStream<Void>.makeStream(), cancelled = Box(false)
        await r.host.setCheckStub { _, _ in
            inside.yield()
            try? await Task.sleep(for: .seconds(3600))
            cancelled.value = Task.isCancelled
            return ProcessResult(status: 143, stdout: "", stderr: "", truncated: false)
        }
        let store = r.store, id = r.work
        let run = Task { await loop.run(work: id, dir: r.repo) }
        for await _ in entered { break }
        #expect((try? await store.get(id))?.loop?.phase == .preCheck)
        await loop.stop(work: id)
        #expect(await run.value == .stopped)
        #expect(cancelled.value, "the check was not cancelled")
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .requested && w.loop?.phase == nil && w.loop?.used == 0, "\(String(describing: w.loop))")
    }

    /// C5d: the loop's Task cancelled by another path than `work stop` cancels the checks; the loop ends without them.
    @Test(.timeLimit(.minutes(1))) func cancellingTheLoopsTaskCancelsTheChecks() async throws {
        let (r, loop) = try await Self.rig([WorkTask(id: "a", title: "Task a", check: "true")])
        defer { r.cleanup() }
        let (entered, inside) = AsyncStream<Void>.makeStream(), cancelled = Box(false)
        await r.host.setCheckStub { _, _ in
            inside.yield()
            try? await Task.sleep(for: .seconds(3600))
            cancelled.value = Task.isCancelled
            return ProcessResult(status: 143, stdout: "", stderr: "", truncated: false)
        }
        let id = r.work
        let run = Task { await loop.run(work: id, dir: r.repo) }
        for await _ in entered { break }
        run.cancel()
        #expect(await run.value == .stopped)
        #expect(cancelled.value, "the check was not cancelled")
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .cancelled && w.loop?.used == 0, "\(String(describing: w.loop?.stopReason))")
    }

    /// C5d: with `--auto-land`, a green check tells the owner once (the run's summary), not twice.
    @Test func aGreenCheckWithAutoLandNotifiesOnce() async throws {
        let (r, loop) = try await Self.rig([WorkTask(id: "a", title: "Trivial", check: "true")])
        defer { r.cleanup() }
        try await r.store.update(r.work) { $0.loop?.autoLand = WorkLoopState.AutoLand(gate: "true", ci: "true", timeout: 60) }
        await r.host.setFactory(true)
        #expect(await loop.run(work: r.work, dir: r.repo) == .stopped)
        #expect(try await r.get().loop?.stopReason?.code == .checkAlreadyGreen)
        let notices = await r.host.ownerNotices
        #expect(notices.count == 1 && notices[0].contains("Trivial"), "\(notices)")
    }

    @Test func atMostFourChecksRunAtOnce() async throws {
        let tasks = (1...6).map { WorkTask(id: "t\($0)", title: "T\($0)", check: "false") }
        let (r, _) = try await Self.rig(tasks)
        defer { r.cleanup() }
        // each check waits for the test to let it go: release one at a time once as many as can be in are in
        let held = HeldChecks()
        await r.host.setCheckStub { _, _ in
            await held.enter()
            return ProcessResult(status: 1, stdout: "", stderr: "", truncated: false)
        }
        let greens = Task { await WorkLoop.greens(tasks, host: r.host, dir: r.repo, timeout: .seconds(10)) }
        for left in stride(from: 6, to: 0, by: -1) {
            #expect(await waitFor(10) { await held.waiting >= min(WorkLoop.preCheckParallel, left) }, "\(left) left")
            await held.releaseOne()
        }
        #expect(await greens.value.isEmpty)
        let most = await held.most, entered = await held.entered
        #expect(most == 4 && entered == 6, "most \(most), entered \(entered)")
    }
}

/// A check held until the test lets it go: how many wait now, the most seen at once, how many came.
private actor HeldChecks {
    private(set) var most = 0, entered = 0
    private var parked: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { parked.count }
    func enter() async {
        entered += 1
        await withCheckedContinuation { parked.append($0); most = Swift.max(most, parked.count) }
    }
    func releaseOne() { if !parked.isEmpty { parked.removeFirst().resume() } }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    var value: T { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
}
