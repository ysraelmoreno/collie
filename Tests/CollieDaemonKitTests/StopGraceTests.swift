import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// C5a: `work stop --now` drops the attempt in course; a plain stop turns into it past `stopGrace`; an agent that ends
/// its turn in time is never cut; nothing lands after the request; an auto-land with a task not done stops as
/// `landTasksNotDone`; a loop whose agent would be a shell (or a custom preset with no command) is refused.
@Suite struct StopGraceTests {
    private typealias Stop = WorkLoopState.Stop
    static let agent = "w-task-a-t1"

    /// One task; its agent commits, then never ends its turn (a `zsh` that took the prompt as a command).
    /// R2: the grace timer sleeps on `clock`, which only moves when the test advances it.
    private static func hanging(grace: Duration, clock: ManualClock, autoLand: Bool = false) async throws -> LoopRig {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "true")], tries: 2, stopGrace: grace, stopClock: clock)
        await r.host.set(agent, LoopScript(act: { try await commit("a.swift", "let a = 1\n", in: $0) },
                                           screen: ["zsh: no matches found: [collie]"]))
        if autoLand {
            try await r.store.update(r.work) { $0.loop?.autoLand = WorkLoopState.AutoLand(gate: "true", ci: "true", timeout: 60) }
            await r.host.setFactory(true)
        }
        return r
    }

    /// Runs the loop, waits for the agent's turn, then `stop`s it; the running loop (`now`: already ended by the stop).
    private static func runAndStop(_ r: LoopRig, now: Bool) async throws -> Task<WorkLoopState.State, Never> {
        let run = Task { await r.run() }
        #expect(await waitFor(20) { await r.host.prompts[agent] != nil }, "the agent never got its prompt")
        await r.loop.stop(work: r.work, now: now)
        return run
    }

    /// The attempt was dropped: agent gone, its commit discarded, the task open, the loop stopped as asked.
    private static func expectDropped(_ r: LoopRig, before: String, _ at: SourceLocation = #_sourceLocation) async throws {
        let w = try await r.get()
        #expect(w.loop?.state == .stopped && w.loop?.stopReason?.code == .requested, "\(String(describing: w.loop))", sourceLocation: at)
        #expect(w.tasks[0].state == .open && w.tasks[0].tries == nil, "\(w.tasks[0])", sourceLocation: at)
        #expect(await r.host.dismissed.contains(agent), sourceLocation: at)
        #expect(w.loop?.events?.contains { $0.kind == .discarded } == true, sourceLocation: at)
        #expect(try await head(r.repo) == before, sourceLocation: at)
        #expect(!FileManager.default.fileExists(atPath: r.repo.appendingPathComponent("a.swift").path), sourceLocation: at)
        #expect(w.jobs.allSatisfy { $0.state != .running }, "\(w.jobs)", sourceLocation: at)
    }

    private static func head(_ dir: URL) async throws -> String {
        try await GitRunner.run(["rev-parse", "HEAD"], in: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func nowEndsTheAttemptAtOnce() async throws {
        let clock = ManualClock()
        let r = try await Self.hanging(grace: .seconds(3600), clock: clock); defer { r.cleanup() }
        let before = try await Self.head(r.repo)
        let end = await (try await Self.runAndStop(r, now: true)).value
        #expect(end == .stopped)
        #expect(clock.now.offset == .zero && clock.sleepers == 0)   // ended with no grace on the clock
        try await Self.expectDropped(r, before: before)
        #expect(try await r.get().notes.allSatisfy { !$0.text.contains("stop forçado depois de") })
        #expect(await r.host.checks == 0)   // nothing was judged
    }

    @Test func aPlainStopIsForcedPastItsGrace() async throws {
        let clock = ManualClock()
        let r = try await Self.hanging(grace: .seconds(300), clock: clock); defer { r.cleanup() }
        let before = try await Self.head(r.repo)
        let run = try await Self.runAndStop(r, now: false)
        await clock.waitForSleepers(1)   // the grace timer is set
        clock.advance(by: .seconds(300) - .milliseconds(1))
        #expect(await r.loop.forcing.isEmpty)   // not forced before its grace
        #expect(try await r.get().notes.allSatisfy { !$0.text.contains("stop forçado") })
        clock.advance(by: .milliseconds(1))
        #expect(await run.value == .stopped)
        try await Self.expectDropped(r, before: before)
        #expect(try await r.get().notes.contains { $0.text.contains("stop forçado depois de") })
    }

    @Test func anAgentThatEndsInTimeIsNotCut() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "true"), WorkTask(id: "b", title: "Task b", check: "true")],
                                  tries: 1, stopGrace: .seconds(30), stopClock: ManualClock())
        defer { r.cleanup() }
        await r.host.set(Self.agent, LoopScript(act: { try await commit("a.swift", "let a = 1\n", in: $0) }))
        let loop = r.loop, id = r.work
        await r.host.setProbe { _ in await loop.stop(work: id) }   // asked while the check runs: the verdict comes first
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.tasks[0].state == .done && w.tasks[1].state == .open, "\(w.tasks)")
        #expect(w.loop?.stopReason?.code == .requested)
        #expect(w.notes.allSatisfy { !$0.text.contains("stop forçado") }, "\(w.notes.map(\.text))")
        #expect(w.loop?.events?.contains { $0.kind == .discarded } != true)
    }

    @Test func nothingLandsAfterAForcedStop() async throws {
        let r = try await Self.hanging(grace: .seconds(3600), clock: ManualClock(), autoLand: true); defer { r.cleanup() }
        let before = try await Self.head(r.repo)
        let end = await (try await Self.runAndStop(r, now: true)).value
        #expect(end == .stopped)
        try await Self.expectDropped(r, before: before)
        #expect(await r.host.lands.isEmpty)
    }

    @Test func aTaskDeferredByARedGateStopsAsLandTasksNotDone() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "true")], tries: 1, gate: "false"); defer { r.cleanup() }
        await r.host.set(Self.agent, LoopScript(act: { try await commit("a.swift", "let a = 1\n", in: $0) }))
        try await r.store.update(r.work) { $0.loop?.autoLand = WorkLoopState.AutoLand(gate: "true", ci: "true", timeout: 60) }
        await r.host.setFactory(true)
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred)
        let stop = try #require(w.loop?.stopReason)
        #expect(stop.code == .landTasksNotDone && stop.detail == "Task a" && !stop.finishes, "\(stop)")
        #expect(stop.label.contains("Task a") && stop.label.contains("nada integrado"), "\(stop.label)")
        #expect(await r.host.lands.isEmpty)
        // work status, the history's note and the owner's summary line name it
        #expect(WorkStatusText.loopLine(w)?.contains("tarefa(s) não feitas (Task a)") == true, "\(String(describing: WorkStatusText.loopLine(w)))")
        #expect(w.notes.contains { $0.text == stop.note }, "\(w.notes.map(\.text))")
        #expect(w.loop?.events?.contains { $0.kind == .stopped } == true)
        let notices = await r.host.ownerNotices
        #expect(notices.count == 1 && notices[0].contains("[landTasksNotDone]"), "\(notices)")
    }

    @Test func allTasksDoneLandsAsBefore() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "true")], tries: 1); defer { r.cleanup() }
        await r.host.set(Self.agent, LoopScript(act: { try await commit("a.swift", "let a = 1\n", in: $0) }))
        try await r.store.update(r.work) { $0.loop?.autoLand = WorkLoopState.AutoLand(gate: "true", ci: "true", timeout: 60) }
        await r.host.setFactory(true)
        _ = await r.run()
        #expect(try await r.get().loop?.stopReason?.code != .landTasksNotDone)
    }

    /// The attempt's agent as the summon resolves it: a shell (given or the Shepherd's) or a custom preset with no command
    /// never ends a turn.
    @Test func aLoopAgentWithNoEndOfTurnIsRefused() {
        func starter(_ p: Preset, _ c: String? = nil) -> TerminalRecord {
            TerminalRecord(id: UUID(), name: "S", preset: p, command: c, cwd: "/", isShepherd: true)
        }
        func refused(_ p: String?, _ c: String?, _ t: TerminalRecord) -> Bool { CommandRouter.loopAgentRefused(preset: p, command: c, shepherd: t) }
        #expect(refused(nil, nil, starter(.shell)))                        // inherited from the Shepherd
        #expect(refused("shell", nil, starter(.claude)))                   // --preset shell
        #expect(refused("custom", nil, starter(.claude)))                  // custom with no --command
        #expect(refused(nil, nil, starter(.custom)))
        #expect(!refused("claude", nil, starter(.shell)))                  // --preset claude on a shell Shepherd
        #expect(!refused(nil, nil, starter(.claude)))                      // claude stays the default
        #expect(!refused("codex", nil, starter(.shell)) && !refused("cursor", nil, starter(.shell)))
        #expect(!refused("custom", "my-agent", starter(.shell)))           // a command is a program the owner named
        #expect(!refused(nil, "cat", starter(.shell)))
        #expect(!refused(nil, nil, starter(.custom, "my-agent")))          // the Shepherd's own command
        #expect(CommandRouter.loopAgentRefusal.contains("passe --preset claude"))
    }
}
