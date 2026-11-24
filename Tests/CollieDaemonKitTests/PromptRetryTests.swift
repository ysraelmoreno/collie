import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// P2: a prompt not delivered is no timed-out turn: the attempt starts over with a new agent, not counted, at most
/// twice per TASK, and only for the attempt's initial prompt (never a nudge's).
private typealias M = AttemptMachine
private let agent = UUID()
private let lost = "'w-task-a-t1' is still busy with an earlier turn; prompt not delivered"
private func notDelivered(_ m: String = lost) -> ProtocolError { ProtocolError(code: .timeout, message: m) }

/// Feeds `events` from `start`; the last answer.
private func feed(_ start: M.State, _ events: [M.Event]) -> (M.State, [M.Effect]) {
    var s = start, fx: [M.Effect] = []
    for e in events { (s, fx) = M.reduce(s, e) }
    return (s, fx)
}
private func state(retries: Int = 0, precheck: Bool = false) -> M.State {
    M.State(task: "a", n: 1, tries: 3, hasGate: false, before: "c0", precheck: precheck, promptRetries: retries)
}

extension AttemptMachineTests {
    @Test(arguments: [
        ("'x' produced no output yet; prompt not delivered", true),
        ("'x' is not ready yet (no quiet period); prompt not delivered", true),
        ("'x' is still busy with an earlier turn; prompt not delivered", true),
        ("'x' is still working; prompt not delivered", true),
        ("target 'x' is not accepting input", true),
        ("No reply from 'x' within 5s", false),
    ]) func promptNotDeliveredClassifies(_ message: String, _ lost: Bool) {
        #expect(AskCoordinator.promptNotDelivered(ProtocolError(code: .timeout, message: message)) == lost)
    }

    @Test func notRunningIsNotPromptNotDelivered() {
        #expect(!AskCoordinator.promptNotDelivered(ProtocolError(code: .notRunning, message: "prompt not delivered")))
    }

    @Test func initialPromptNotDeliveredRedoesTheAttemptUncounted() {
        let (s, fx) = feed(state(), [.started, .summoned(agent), .promptNotDelivered(lost, load: 21)])
        #expect(s.phase == .summoning && s.agent == nil && s.promptRetries == 1 && s.n == 1 && s.facts.failure == nil)
        #expect(fx == [.journal(.turnEnded, "timeout: " + lost), .dismiss, .journal(.agentDismissed, nil),
                       .journal(.promptRetry, "1/2"), .promptRetry("1/2"), .summon])
        // the new agent gets the same attempt's prompt
        let (again, more) = M.reduce(s, .summoned(UUID()))
        #expect(again.phase == .turn && more.last == .ask)
    }

    @Test func theTasksThirdPromptNotDeliveredCountsAndWarnsTheOwner() {
        let (s, fx) = feed(state(retries: 2), [.started, .summoned(agent), .promptNotDelivered(lost, load: 21.5)])
        #expect(s.phase == .waitingCommit && s.agent == agent && s.promptRetries == 2)
        #expect(fx.first == .journal(.turnEnded, "timeout: " + lost) && fx.last == .lookForCommit)
        guard case .note(let text) = fx[1] else { Issue.record("\(fx)"); return }
        #expect(text.contains("prompt não entregue 3 vezes seguidas; a máquina está sobrecarregada?") && text.contains("21.50"))
    }

    @Test func aNudgesPromptNotDeliveredDoesNotRedo() {
        let (s, fx) = feed(state(), [.started, .summoned(agent), .turnEnded(source: .hook), .waitExpired, .promptNotDelivered(lost, load: 1)])
        #expect(s.nudged && s.phase == .waitingCommit && s.agent == agent && s.promptRetries == 0)
        #expect(fx == [.journal(.turnEnded, "timeout: " + lost), .lookForCommit])
    }

    @Test func aPrecheckNudgesPromptNotDeliveredDoesNotRedo() {
        let (s, fx) = feed(state(precheck: true), [.started, .summoned(agent), .turnEnded(source: .hook), .commitSeen("c1"),
                                                   .precheckDone(status: 1, tail: "x"), .promptNotDelivered(lost, load: 1)])
        #expect(s.prechecked && s.phase == .waitingCommit && s.agent == agent && s.promptRetries == 0)
        #expect(fx == [.journal(.turnEnded, "timeout: " + lost), .lookForCommit])
    }

    @Test func aRealTimeoutIsNotRedone() {
        let real = "No reply from 'w-task-a-t1' within 5s"
        let (s, fx) = feed(state(), [.started, .summoned(agent), .turnTimedOut(real)])
        #expect(s.phase == .waitingCommit && s.agent == agent && s.promptRetries == 0)
        #expect(fx == [.journal(.turnEnded, "timeout: " + real), .lookForCommit])
    }
}

extension WorkLoopTests {
    @Test func aPromptNotDeliveredIsRedoneWithANewAgentUncounted() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "test -f done.txt")]); defer { r.cleanup() }
        await r.host.queueAskErrors("w-task-a-t1", [notDelivered()])
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .done && w.tasks[0].tries == 1 && w.tasks[0].promptRetries == 1)
        #expect(await r.host.summoned == ["w-task-a-t1", "w-task-a-t1"] && w.loop?.used == 1)
        let events = w.loop?.events ?? []
        #expect(events.contains { $0.kind == .promptRetry && $0.detail == "1/2" })
        #expect(events.contains { $0.kind == .turnEnded && $0.detail?.contains("prompt not delivered") == true })
        #expect(w.notes.contains { $0.text.contains("prompt não entregue") && $0.text.contains("refeita 1/2") })
    }

    /// The cap is the task's: two retries in attempt 1, then attempt 2's prompt not delivered counts as a normal attempt.
    @Test func theFreeRetriesAreCappedPerTask() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "test -f done.txt")]); defer { r.cleanup() }
        await r.host.queueAskErrors("w-task-a-t1", [notDelivered(), notDelivered(), notDelivered()])
        await r.host.queueAskErrors("w-task-a-t2", [notDelivered()])
        await r.host.set("w-task-a-t3", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .done && w.tasks[0].tries == 3 && w.tasks[0].promptRetries == 2)
        #expect(await r.host.summoned == ["w-task-a-t1", "w-task-a-t1", "w-task-a-t1", "w-task-a-t2", "w-task-a-t3"])
        #expect((w.loop?.events ?? []).filter { $0.kind == .promptRetry }.count == 2)
        #expect(w.notes.filter { $0.text.contains("prompt não entregue 3 vezes seguidas") }.count == 2)
    }

    @Test func aNudgeNotDeliveredKeepsTheAgentAndTheCheckDecides() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "true")], tries: 1); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(nudgeError: notDelivered()))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred && w.tasks[0].lastFailure == "no new commit" && w.tasks[0].promptRetries == nil)
        #expect(await r.host.summoned == ["w-task-a-t1"] && r.host.nudges.count == 1)
        #expect(!(w.loop?.events ?? []).contains { $0.kind == .promptRetry })
    }

    @Test func aShortBusyTurnsNoteCarriesTheAgentsScreen() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "true")], tries: 1); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(lateAfter: 10_000, tick: 5))
        await r.host.setScreen("w-task-a-t1", ["old"] + (1...20).map { "linha \($0)" } + ["\u{1b}[31mfim\u{1b}[0m"])
        #expect(await r.run() == .finished)
        let note = try #require(try await r.get().notes.first { $0.text.contains("ainda ocupado e sem commit") }?.text)
        #expect(note.contains("tela do agente:\n") && note.hasSuffix("linha 20\nfim") && !note.contains("old") && !note.contains("linha 1\n"))
    }
}
