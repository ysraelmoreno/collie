import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private typealias M = AttemptMachine

private let agent = UUID()
private func task(_ id: String, _ check: String) -> WorkTask { WorkTask(id: id, title: "Task \(id)", check: check) }

/// One line of a table: the event, then the phase and the effects `reduce` must answer with.
private struct Step: Sendable {
    let on: M.Event, phase: M.Phase, fx: [M.Effect]
    init(_ on: M.Event, _ phase: M.Phase, _ fx: [M.Effect]) { self.on = on; self.phase = phase; self.fx = fx }
}

private let summoned: [Step] = [
    Step(.started, .summoning, [.journal(.attemptStarted, nil), .summon]),
    Step(.summoned(agent), .turn, [.journal(.agentSummoned, "loop-a-1"), .ask]),
]
private let hook = Step(.turnEnded(source: .hook), .waitingCommit, [.journal(.turnEnded, "hook"), .lookForCommit])
private let toCheck: [M.Effect] = [.dismiss, .journal(.agentDismissed, nil), .measureFacts]
private let seen = Step(.commitSeen("c1"), .waitingCommit, [.journal(.commitSeen, "c1")] + toCheck)
/// A turn that ended by hook with no new commit: the nudge goes.
private let nudged: [Step] = summoned + [hook, Step(.waitExpired, .turn, [.nudge])]

private struct Path: Sendable, CustomTestStringConvertible {
    let name: String, steps: [Step]
    var testDescription: String { name }
}

private let paths: [Path] = [
    Path(name: "hook with no commit: one nudge; a second hook with no commit goes to the check", steps: nudged + [
        hook,
        Step(.waitExpired, .waitingCommit, toCheck),
        Step(.measured(.init(committed: false, dirty: false, judged: "c0")), .checking, [.show(.check), .journal(.checkStarted, nil), .runCheck]),
    ]),
    Path(name: "the nudged agent commits", steps: nudged + [hook, seen]),
    Path(name: "hook with a commit: no nudge", steps: summoned + [hook, seen]),
    Path(name: "idle with no commit: no nudge (it already waited for the commit)", steps: summoned + [
        Step(.turnEnded(source: .idle), .waitingCommit, [.journal(.turnEnded, "idle"), .waitForCommit]),
        Step(.waitExpired, .waitingCommit, toCheck),
    ]),
    Path(name: "turn past its timeout: no nudge", steps: summoned + [
        Step(.turnTimedOut, .waitingCommit, [.journal(.turnEnded, "timeout"), .lookForCommit]),
        Step(.waitExpired, .waitingCommit, toCheck),
    ]),
    Path(name: "ask failed: no nudge", steps: summoned + [
        Step(.turnFailed("boom"), .waitingCommit, [.journal(.turnEnded, "erro: boom"), .lookForCommit]),
        Step(.waitExpired, .waitingCommit, toCheck),
    ]),
    Path(name: "cancelled during the nudge: the terminal is dismissed, no verdict, the attempt is not counted", steps: nudged + [
        Step(.cancelled, .finished, [.dismiss, .journal(.agentDismissed, nil), .uncount, .stopLoop(.init(.cancelled))]),
    ]),
    Path(name: "the nudge did not go (no time left, the loop stopping): the check, as before", steps: nudged + [
        Step(.waitExpired, .waitingCommit, toCheck),
    ]),
    Path(name: "the nudge's turn ends idle: the same wait for the commit", steps: nudged + [
        Step(.turnEnded(source: .idle), .waitingCommit, [.journal(.turnEnded, "idle"), .waitForCommit]),
        Step(.waitExpired, .waitingCommit, toCheck),
    ]),
    Path(name: "the nudge's turn times out: the check", steps: nudged + [
        Step(.turnTimedOut, .waitingCommit, [.journal(.turnEnded, "timeout"), .lookForCommit]),
        Step(.waitExpired, .waitingCommit, toCheck),
    ]),
]

/// M2.1: a turn that ends by hook with no new commit is nudged once, in the same attempt.
@Suite struct LoopNudgeTests {
    // MARK: the machine's table

    @Test(arguments: paths) private func theMachineNudgesOnce(_ p: Path) {
        var s = M.State(task: "a", n: 1, tries: 3, hasGate: false, before: "c0")
        for (i, step) in p.steps.enumerated() {
            let (next, fx) = M.reduce(s, step.on)
            #expect(next.phase == step.phase && fx == step.fx, "step \(i) (\(step.on)): \(next.phase) \(fx)")
            #expect(fx.dropLast().allSatisfy { !$0.answers }, "step \(i): only the last effect answers")
            s = next
        }
    }

    @Test func aFailedNudgeAskFailsNothing() {
        var s = M.State(task: "a", n: 1, tries: 3, hasGate: false, before: "c0")
        for step in nudged { s = M.reduce(s, step.on).0 }
        let (next, fx) = M.reduce(s, .turnFailed("did not submit the prompt"))
        // judged as if the nudge had not gone: by the commit and the check, never by the nudge's error
        #expect(next.facts.failure == nil && next.phase == .waitingCommit)
        #expect(fx == [.journal(.turnEnded, "erro: did not submit the prompt"), .lookForCommit])
    }

    @Test func theNudgeAnswersWithAnEvent() { #expect(M.Effect.nudge.answers) }

    @Test func nudgedKindDecodesTolerantly() throws {
        let e = LoopEvent(at: Date(timeIntervalSince1970: 1), kind: .nudged, task: "a", attempt: 1, detail: "hook")
        #expect(try JSONDecoder().decode(LoopEvent.self, from: JSONEncoder().encode(e)) == e)
        #expect(try JSONDecoder().decode(LoopEvent.Kind.self, from: Data(#""nudged""#.utf8)) == .nudged)
        // a reader that does not know a kind (an older daemon reading `nudged`) keeps the journal: `unknown`
        #expect(try JSONDecoder().decode(LoopEvent.Kind.self, from: Data(#""nudgedTwice""#.utf8)) == .unknown)
    }

    // MARK: with the fake host

    @Test func anAgentThatCommitsOnlyAfterTheNudgePassesOnItsFirstAttempt() async throws {
        let r = try await LoopRig([task("a", "test -f done.txt")], max: 1); defer { r.cleanup() }
        await r.host.set("loop-a-1", LoopScript(nudged: { try await commit("done.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get(), ev = w.loop?.events ?? []
        #expect(w.tasks[0].state == .done && w.tasks[0].tries == 1, "\(w.notes.map(\.text))")
        // the same attempt: one terminal, one of `--max`, one try
        #expect(w.loop?.used == 1 && w.jobs.map(\.id) == ["loop-a-1"])
        #expect(await r.host.summoned == ["loop-a-1"])
        #expect(await r.host.dismissed == ["loop-a-1"])
        let kinds = ev.map(\.kind)
        let i = try #require(kinds.firstIndex(of: .nudged))
        #expect(ev[i].detail == "hook" && ev[i].task == "a" && ev[i].attempt == 1)
        #expect(kinds.filter { $0 == .nudged }.count == 1)
        // the turn ended, the nudge, the nudge's turn ended, the commit
        #expect(Array(kinds[(i - 1)...(i + 2)]) == [.turnEnded, .nudged, .turnEnded, .commitSeen], "\(kinds.map(\.rawValue))")
        let nudges = await r.host.nudges
        #expect(nudges.count == 1 && nudges[0].name == "loop-a-1" && nudges[0].prompt == WorkLoop.nudgePrompt)
        // what is left of the turn (60 s in the rig)
        #expect(nudges[0].timeout >= .seconds(1) && nudges[0].timeout <= .seconds(60))
        // the attempt's own prompt is not the nudge
        #expect(await r.host.prompts["loop-a-1"]?.contains("Tarefa \"Task a\"") == true)
    }

    @Test func theNudgeIsTheConstant() {
        #expect(WorkLoop.nudgePrompt == "Você encerrou o turno sem fazer commit. Ninguém vai responder perguntas neste laço: decida sozinho. Faça commit do que escreveu (ou diga em uma linha o que impede) e encerre.")
    }

    @Test func anAgentThatIgnoresTheNudgeFailsAsBefore() async throws {
        let r = try await LoopRig([task("a", "true")], tries: 2); defer { r.cleanup() }
        #expect(await r.run() == .finished)
        let w = try await r.get(), ev = w.loop?.events ?? []
        #expect(w.tasks[0].state == .deferred && w.tasks[0].tries == 2 && w.tasks[0].lastFailure == "no new commit")
        // once per attempt, never twice in one
        #expect(await r.host.nudges.map(\.name) == ["loop-a-1", "loop-a-2"])
        #expect(ev.filter { $0.kind == .nudged }.map(\.attempt) == [1, 2])
        #expect(w.loop?.used == 2)
        #expect(await r.host.checks == 2)
    }

    @Test func aTurnThatEndedWithACommitIsNotNudged() async throws {
        let r = try await LoopRig([task("a", "true")]); defer { r.cleanup() }
        await r.host.set("loop-a-1", LoopScript(act: { try await commit("a.txt", "x\n", in: $0) }))
        #expect(await r.run() == .finished)
        #expect(try await r.get().tasks[0].state == .done)
        #expect(await r.host.nudges.isEmpty)
        #expect(!(try await r.get().loop?.events ?? []).contains { $0.kind == .nudged })
    }

    @Test func anIdleEndIsNotNudged() async throws {
        let r = try await LoopRig([task("a", "true")]); defer { r.cleanup() }
        await r.host.set("loop-a-1", LoopScript(source: .idle, lateAfter: 2, late: { try await commit("a.txt", "x\n", in: $0) }))
        #expect(await r.run() == .finished)
        #expect(try await r.get().tasks[0].state == .done)
        #expect(await r.host.nudges.isEmpty)
    }

    @Test(arguments: [ErrorCode.timeout, .internal]) func aTurnPastItsTimeoutOrAFailedAskIsNotNudged(_ code: ErrorCode) async throws {
        let r = try await LoopRig([task("a", "true")], tries: 1); defer { r.cleanup() }
        await r.host.set("loop-a-1", LoopScript(askError: ProtocolError(code: code, message: "boom")))
        #expect(await r.run() == .finished)
        #expect(try await r.get().tasks[0].state == .deferred)
        #expect(await r.host.nudges.isEmpty)
    }

    @Test func aLoopAskedToStopDoesNotNudge() async throws {
        let r = try await LoopRig([task("a", "true")]); defer { r.cleanup() }
        let loop = r.loop, id = r.work
        await r.host.set("loop-a-1", LoopScript(act: { _ in await loop.stop(work: id) }))
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        // the attempt still has its verdict, as before
        #expect(w.loop?.stopReason == .init(.requested) && w.tasks[0].lastFailure == "no new commit")
        #expect(await r.host.nudges.isEmpty)
    }

    @Test func aNudgeThatCouldNotBeAskedLeavesTheVerdictToTheCommit() async throws {
        let r = try await LoopRig([task("a", "true")], tries: 1); defer { r.cleanup() }
        await r.host.set("loop-a-1", LoopScript(nudgeError: ProtocolError(code: .internal, message: "did not submit the prompt")))
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred && w.tasks[0].lastFailure == "no new commit")
        #expect(await r.host.nudges.count == 1)
        #expect(await r.host.checks == 1)
    }
}
