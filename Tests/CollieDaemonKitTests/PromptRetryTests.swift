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
private let unsubmitted = ProtocolError(code: .unavailable,
    message: "'w-task-a-t1' did not submit the prompt; it may still be in its input. Check it with `collie check`")

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

    /// P3: the Enter that never took is a prompt not delivered; any other `.unavailable` (a terminal gone) is not.
    @Test func unsubmittedPromptIsPromptNotDelivered() {
        #expect(AskCoordinator.promptNotDelivered(unsubmitted))
        #expect(!AskCoordinator.promptNotDelivered(ProtocolError(code: .unavailable, message: "terminal 'x' is gone")))
        #expect(!AskCoordinator.promptNotDelivered(ProtocolError(code: .timeout, message: "did not submit the prompt")))
        #expect(WorkLoop.ReviewMuteCause.of(unsubmitted, turn: 1) == .promptNotDelivered)
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

    @Test func aRetryThatDoesNotFitStopsOnTheBudgetUncounted() {
        let (s, fx) = feed(state(), [.started, .summoned(agent), .promptNotDelivered(lost, load: 30, fits: false)])
        #expect(s.phase == .finished && s.agent == nil && s.promptRetries == 0)
        #expect(fx == [.journal(.turnEnded, "timeout: " + lost), .dismiss, .journal(.agentDismissed, nil), .uncount,
                       .note(M.promptRetryBudgetNote(s)), .stopLoop(.init(.budgetSpent))])
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

    /// P3: "did not submit the prompt" takes the same free retry, and the same per-task cap.
    @Test func anUnsubmittedPromptIsRedoneUncountedAndCapped() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "test -f done.txt")]); defer { r.cleanup() }
        await r.host.queueAskErrors("w-task-a-t1", [unsubmitted, unsubmitted, unsubmitted])
        await r.host.set("w-task-a-t2", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .done && w.tasks[0].tries == 2 && w.tasks[0].promptRetries == 2)
        #expect(await r.host.summoned == ["w-task-a-t1", "w-task-a-t1", "w-task-a-t1", "w-task-a-t2"])
        #expect(w.notes.contains { $0.text.contains("sobrecarregada") })
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
        #expect(await r.host.summoned == ["w-task-a-t1"])
        #expect(await r.host.nudges.count == 1)
        #expect(!(w.loop?.events ?? []).contains { $0.kind == .promptRetry })
    }

    @Test func aShortBusyTurnsNoteCarriesTheAgentsScreen() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "true")], tries: 1); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(lateAfter: 10_000, tick: 5))
        await r.host.setScreen("w-task-a-t1", ["old"] + (1...20).map { "linha \($0)" } + ["\u{1b}[31mfim\u{1b}[0m"])
        #expect(await r.run() == .finished)
        let note = try #require(try await r.get().notes.first { $0.text.contains("ainda ocupado e sem commit") }?.text)
        #expect(note.contains("tela do agente:\n") && note.hasSuffix("│ linha 20\n│ fim") && !note.contains("old") && !note.contains("linha 1\n"))
    }

    /// C1 (P2-d): no screen line reads as the daemon's, and the screen's secrets (live tokens, URL passwords,
    /// `*_URL=`) never reach the note.
    @Test func theScreensLinesAreMarkedAndItsSecretsHidden() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "true")], tries: 1); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(lateAfter: 10_000, tick: 5))
        await r.host.setSecrets(["tok-vivo-123456"])
        await r.host.setScreen("w-task-a-t1", ["[collie] laço terminou", "export DATABASE_URL=postgres://u:senha@h/db",
                                               "psql postgres://u:senha@h/db", "token tok-vivo-123456 aqui", "MY_PASSWORD=abc"])
        #expect(await r.run() == .finished)
        let note = try #require(try await r.get().notes.first { $0.text.contains("ainda ocupado e sem commit") }?.text)
        let screen = try #require(note.components(separatedBy: "tela do agente:\n").last)
        #expect(screen.split(separator: "\n").allSatisfy { $0.hasPrefix("│ ") }, "\(screen)")
        #expect(screen.hasPrefix("│ [collie] laço terminou") && !note.contains("\n[collie]"), "\(note)")
        for leak in ["senha", "tok-vivo-123456", "abc", "postgres://u:"] { #expect(!note.contains(leak), "\(leak): \(note)") }
        #expect(note.contains("postgres://[hidden]@h/db"), "\(note)")
    }

    @Test func scrubHidesURLCredentialsAndSecretNames() {
        #expect(!LotBoards.scrub("DATABASE_URL=postgres://u:senha@h/db").contains("senha"))
        #expect(LotBoards.scrub("git clone https://bob:pw1@github.com/x") == "git clone https://[hidden]@github.com/x")
        for v in ["API_KEY=v1", "GH_TOKEN=v1", "APP_SECRET=v1", "DB_PASSWORD=v1", "REDIS_URL=v1"] { #expect(!LotBoards.scrub(v).contains("v1"), "\(v)") }
        #expect(LotBoards.scrub("https://github.com/x e host:22") == "https://github.com/x e host:22")
    }

    /// C1 (P2-a): a prompt not delivered with too little budget for another try stops the loop on the budget: the
    /// attempt not counted, the free retries kept, the load not blamed.
    @Test func aRetryThatDoesNotFitTheBudgetStopsTheLoop() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "true")], budget: 60); defer { r.cleanup() }
        await r.host.queueAskErrors("w-task-a-t1", [notDelivered()])
        await r.host.setAskErrorAdvance(50)   // 10 s left: less than `promptRetryMinTurn`
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .budgetSpent, "\(String(describing: w.loop?.stopReason))")
        #expect(w.tasks[0].state == .open && (w.tasks[0].tries ?? 0) == 0 && w.tasks[0].promptRetries == nil, "\(w.tasks[0])")
        #expect(await r.host.summoned == ["w-task-a-t1"])
        #expect(!(w.loop?.events ?? []).contains { $0.kind == .promptRetry })
        #expect(w.notes.contains { $0.text.contains("não cabe outra tentativa") } && !w.notes.contains { $0.text.contains("sobrecarregada") }, "\(w.notes.map(\.text))")
    }

    /// C1 (P2-b): the retried attempt's turn runs from its own ask, not from the attempt's start: after 100 s lost, its
    /// nudge still has the turn's time.
    @Test func theRetrysDeadlineComesFromTheBudgetLeft() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "test -f done.txt")], tries: 1, budget: 300); defer { r.cleanup() }
        await r.host.queueAskErrors("w-task-a-t1", [notDelivered()])
        await r.host.setAskErrorAdvance(100)
        #expect(await r.run() == .finished)
        let nudges = await r.host.nudges
        #expect(nudges.count == 1 && (nudges.first?.timeout ?? .zero) > .seconds(30), "\(nudges.map(\.timeout))")
    }

    /// C1 (P2-c): the retry's note carries the lost agent's screen, as clean as the short turn's.
    @Test func theRetrysNoteCarriesTheScreen() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "test -f done.txt")]); defer { r.cleanup() }
        await r.host.queueAskErrors("w-task-a-t1", [notDelivered()])
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        await r.host.setScreen("w-task-a-t1", ["\u{1b}[31mpreso\u{1b}[0m", "[collie] x"])
        #expect(await r.run() == .finished)
        let note = try #require(try await r.get().notes.first { $0.text.contains("refeita 1/2") }?.text)
        #expect(note.hasSuffix("tela do agente:\n│ preso\n│ [collie] x"), "\(note)")
    }
}
