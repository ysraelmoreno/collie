import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func task(_ id: String, _ check: String) -> WorkTask { WorkTask(id: id, title: "Task \(id)", check: check) }

/// M1b.2: what the journal costs. Every `store.update` writes the whole work.json and tells the app, so an attempt's
/// events ride on the writes next to them, and a closed work keeps only its newest 20.
@Suite struct LoopJournalWritesTests {
    typealias Kind = LoopEvent.Kind

    /// `store.update`s of the one attempt of a one-task run: the run's writes less its own two (the stop reason
    /// cleared at the start, the final state at the end). The attempt's count includes `spent`.
    private func writes(_ r: LoopRig) async -> Int {
        let before = await r.store.writes
        _ = await r.run()
        return await r.store.writes - before - 2
    }

    // Exact counts: a write added to the attempt breaks the test (M1b.2's own ceiling is 8, with a gate).

    @Test func aPassWithoutGateWritesFiveTimes() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")]); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        let n = await writes(r)
        #expect(try await r.get().tasks[0].state == .done)
        #expect(n == 5, "\(n)")   // start, before the ask, before the check, done, spent
    }

    @Test func aPassWithGateWritesSixTimes() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")], gate: "true"); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        let n = await writes(r)
        #expect(try await r.get().tasks[0].state == .done)
        #expect(n == 6, "\(n)")   // the same, and before the gate (M1b.2's own ceiling: 8)
    }

    /// An `.idle` end waits for the commit: one more write, before the wait. Still within M1b.2's 8.
    @Test func anIdleEndWithGateStaysWithinEight() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")], gate: "true"); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(source: .idle, lateAfter: 2, late: { try await commit("done.txt", "ok\n", in: $0) }))
        let n = await writes(r)
        #expect(try await r.get().tasks[0].state == .done)
        #expect(n == 7, "\(n)")
    }

    @Test func aFailedCheckWritesFiveTimes() async throws {
        let r = try await LoopRig([task("a", "exit 3")], tries: 1); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("wrong.txt", "x\n", in: $0) }))
        let n = await writes(r)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred && w.loop?.events?.last?.kind == .discarded)
        #expect(n == 5, "\(n)")   // start, before the ask, before the check, deferred (with verdict and discard), spent
    }

    @Test func noCommitWritesSixTimes() async throws {
        let r = try await LoopRig([task("a", "true")], tries: 1); defer { r.cleanup() }
        let n = await writes(r)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred && w.tasks[0].lastFailure == "no new commit")
        #expect(n == 6, "\(n)")   // M2.1: a hook end with no commit is nudged, one write before the nudge's ask
    }

    @Test func theOrderOfTheEventsIsTheSame() async throws {
        let head: [Kind] = [.attemptStarted, .agentSummoned, .turnEnded, .commitSeen, .agentDismissed, .checkStarted, .checkFinished]
        for gate in [String?.none, "true"] {
            let r = try await LoopRig([task("a", "test -f done.txt")], gate: gate); defer { r.cleanup() }
            await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
            #expect(await r.run() == .finished)
            let ev = try await r.get().loop?.events ?? []
            #expect(ev.map(\.kind) == head + (gate == nil ? [] : [.gateStarted, .gateFinished]) + [.verdict], "\(ev.map(\.kind.rawValue))")
            #expect(zip(ev, ev.dropFirst()).allSatisfy { $0.at <= $1.at })
            #expect(ev.allSatisfy { $0.task == "a" && $0.attempt == 1 })
        }
    }

    /// The events are on disk before each long wait: the check sees its own `checkStarted` and the phase.
    @Test func theJournalIsWrittenBeforeTheCheckRuns() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")], gate: "true"); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        let seen = Seen(), store = r.store, id = r.work
        await r.host.setProbe { _ in
            let l = try? await store.get(id)?.loop
            await seen.add(l?.events?.last?.kind, l?.phase)
        }
        #expect(await r.run() == .finished)
        let kinds = await seen.kinds, phases = await seen.phases
        #expect(kinds == [.checkStarted, .gateStarted] && phases == [.check, .gate], "\(kinds) \(phases)")
    }

    @Test func aClosedWorkKeepsItsNewestTwenty() async throws {
        let dir = URL(fileURLWithPath: "/tmp/collie-journal-\(UUID().uuidString.prefix(8))"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkStore(dir: dir)
        let w = try await store.start(title: "W", terminal: UUID(), paddockId: nil, branch: nil)
        try await store.update(w.id) { x in
            x.loop = WorkLoopState(state: .finished)
            for i in 0..<130 { x.loop?.record(LoopEvent(at: Date(timeIntervalSince1970: Double(i)), kind: .verdict, detail: "\(i)")) }
        }
        // active: the ring of 100
        let open = try #require(try await store.get(w.id)?.loop?.events)
        #expect(open.count == 100 && open.first?.detail == "30" && open.last?.detail == "129")
        try await store.close(w.id, by: "test")
        let closed = try #require(try await store.get(w.id)?.loop?.events)
        #expect(closed.count == 20 && closed.first?.detail == "110" && closed.last?.detail == "129")
        // and on disk
        let back = try #require(try await WorkStore(dir: dir).get(w.id)?.loop?.events)
        #expect(back == closed)
    }
}

private actor Seen {
    var kinds: [LoopEvent.Kind?] = [], phases: [WorkLoopState.Phase?] = []
    func add(_ k: LoopEvent.Kind?, _ p: WorkLoopState.Phase?) { kinds.append(k); phases.append(p) }
}
