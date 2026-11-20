import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func task(_ id: String, _ check: String) -> WorkTask { WorkTask(id: id, title: "Task \(id)", check: check) }

/// Holds the loop inside its check, with continuations (no sleep). Unlike a real check it ignores the cancel: the
/// loop stays here until `release`, and the test learns when it arrived (`reached`) and when its `Task` was
/// cancelled (`sawCancel`).
private actor Gate {
    private var parked: CheckedContinuation<Void, Never>?, released = false
    private nonisolated let there = AsyncStream<Void>.makeStream(), cancelled = AsyncStream<Void>.makeStream()

    nonisolated func park() async {
        there.continuation.finish()
        let c = cancelled.continuation
        await withTaskCancellationHandler { await self.hold() } onCancel: { c.finish() }
    }
    private func hold() async {
        if released { return }
        await withCheckedContinuation { parked = $0 }
    }
    nonisolated func reached() async { for await _ in there.stream {} }
    nonisolated func sawCancel() async { for await _ in cancelled.stream {} }
    func release() { released = true; parked?.resume(); parked = nil }
}

/// What ended, in order.
private actor Order {
    var items: [String] = []
    func add(_ s: String) { items.append(s) }
}

private extension CommandRouter {
    /// A loop the router owns, as `startLoop` registers it.
    func own(_ work: UUID, _ engine: WorkLoop, _ task: Task<Void, Never>) { workLoops[work] = (engine, task, false) }
}

/// M2b.2: the wait of the daemon's stop for its cancelled loops (`cancelLoops(wait:)`) is a parameter: the loop's own
/// end is the event, the wait only bounds it. No test here asserts how long anything took.
@Suite(.serialized) struct LoopCancelWaitTests {
    /// A real loop (fake host) the router owns, held in the check of its first attempt. `order` gets "loop" when its
    /// `Task` ends.
    private func heldLoop(_ d: Daemon, _ gate: Gate, _ order: Order) async throws -> (rig: LoopRig, run: Task<Void, Never>) {
        let r = try await LoopRig([task("a", "false")], tries: 1)
        await r.host.set("loop-a-1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        await r.host.setProbe { _ in await gate.park() }
        let loop = r.loop, id = r.work, repo = r.repo
        let run = Task { _ = await loop.run(work: id, dir: repo); await order.add("loop") }
        await d.router.own(id, loop, run)
        await gate.reached()
        return (r, run)
    }

    /// The loop ends before the wait is over: `cancelLoops` returns then (not an hour later), after the loop, and
    /// `cancelled` is already on the disk.
    @Test func aLoopThatEndsBeforeTheWaitHasWrittenCancelledWhenTheStopReturns() async throws {
        try await withDaemon { d, _ in
            let gate = Gate(), order = Order()
            let (r, _) = try await heldLoop(d, gate, order); defer { r.cleanup() }
            let router = d.router
            let stop = Task { await router.cancelLoops(wait: .seconds(3600)); await order.add("stop") }
            await gate.sawCancel()   // the stop cancelled the loop and now waits for it
            await gate.release()
            await stop.value         // an hour's wait: returning at all is returning before it
            #expect(await order.items == ["loop", "stop"])
            let w = try await r.get()   // nothing waited for after the stop: the end is already written
            #expect(w.loop?.state == .stopped && w.loop?.stopReason == .init(.cancelled), "\(String(describing: w.loop))")
            #expect(w.loop?.events?.last?.kind == .stopped)
            #expect(w.tasks.first?.state == .open && w.tasks.first?.tries == nil && w.loop?.used == 0)
            #expect(await d.router.workLoops.isEmpty)
        }
    }

    /// The loop does not end (its check ignores the cancel): the stop gives it up after the wait and goes on. The
    /// loop is still `running` on the disk, for the next start's sweep.
    @Test func aLoopThatDoesNotEndIsAbandonedAfterTheWait() async throws {
        try await withDaemon { d, _ in
            let gate = Gate(), order = Order()
            let (r, run) = try await heldLoop(d, gate, order); defer { r.cleanup() }
            await d.router.cancelLoops(wait: .milliseconds(5))   // returns: the stop does not hang on the loop
            #expect(await order.items.isEmpty)                   // the loop has not ended: nobody let it go
            #expect(try await r.get().loop?.state == .running)
            #expect(await d.router.workLoops.isEmpty)
            await d.router.cancelLoops(wait: .seconds(3600))     // nothing left to wait for: at once
            await gate.release()
            await run.value
        }
    }

    /// The production wait is still 2 s.
    @Test func theDefaultWaitIsTwoSeconds() {
        #expect(CommandRouter.loopCancelWait == .seconds(2))
    }
}
