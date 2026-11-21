import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private typealias M = AttemptMachine

private let agent = UUID()
private func task(_ id: String, _ check: String) -> WorkTask { WorkTask(id: id, title: "Task \(id)", check: check) }

private struct Step: Sendable {
    let on: M.Event, phase: M.Phase, fx: [M.Effect]
    init(_ on: M.Event, _ phase: M.Phase, _ fx: [M.Effect]) { self.on = on; self.phase = phase; self.fx = fx }
}

private struct Path: Sendable, CustomTestStringConvertible {
    let name: String, precheck: Bool, steps: [Step]
    var testDescription: String { name }
}

private let summoned: [Step] = [
    Step(.started, .summoning, [.journal(.attemptStarted, nil), .summon]),
    Step(.summoned(agent), .turn, [.journal(.agentSummoned, "trabalho-a-t1"), .ask]),
    Step(.turnEnded(source: .hook), .waitingCommit, [.journal(.turnEnded, "hook"), .lookForCommit]),
]
private let toCheck: [M.Effect] = [.dismiss, .journal(.agentDismissed, nil), .measureFacts]
private let seenPre = Step(.commitSeen("c1"), .waitingCommit, [.journal(.commitSeen, "c1"), .runPrecheck])
private let failedOnce: [Step] = summoned + [seenPre,
    Step(.precheckDone(status: 1, tail: "error: x"), .turn, [.journal(.precheckFailed, "exit 1"), .precheckNudge("error: x")])]

private let paths: [Path] = [
    Path(name: "pre-check passes: the check", precheck: true, steps: summoned + [seenPre,
        Step(.precheckDone(status: 0, tail: ""), .waitingCommit, [.journal(.precheckPassed, "exit 0")] + toCheck)]),
    Path(name: "fails the 1st time: nudge, then judged again and passes", precheck: true, steps: failedOnce + [
        Step(.turnEnded(source: .hook), .waitingCommit, [.journal(.turnEnded, "hook"), .lookForCommit]),
        Step(.commitSeen("c2"), .waitingCommit, [.journal(.commitSeen, "c2"), .runPrecheck]),
        Step(.precheckDone(status: 0, tail: ""), .waitingCommit, [.journal(.precheckPassed, "exit 0")] + toCheck)]),
    Path(name: "fails the 2nd time: the check, no new nudge", precheck: true, steps: failedOnce + [
        Step(.turnEnded(source: .hook), .waitingCommit, [.journal(.turnEnded, "hook"), .lookForCommit]),
        Step(.commitSeen("c2"), .waitingCommit, [.journal(.commitSeen, "c2"), .runPrecheck]),
        Step(.precheckDone(status: 2, tail: "error: y"), .waitingCommit, [.journal(.precheckFailed, "exit 2")] + toCheck)]),
    Path(name: "a timed-out pre-check is a failure", precheck: true, steps: summoned + [seenPre,
        Step(.precheckDone(status: nil, tail: "passou de 180 s"), .turn, [.journal(.precheckFailed, "timeout"), .precheckNudge("passou de 180 s")])]),
    Path(name: "the pre-check's nudge did not go: the check", precheck: true, steps: failedOnce + [
        Step(.waitExpired, .waitingCommit, toCheck)]),
    Path(name: "no pre-check: as today", precheck: false, steps: summoned + [
        Step(.commitSeen("c1"), .waitingCommit, [.journal(.commitSeen, "c1")] + toCheck)]),
]

/// M10.2: the turn's rules in the prompt and the pre-check, told once to the same agent.
@Suite struct TurnSafetyTests {
    @Test(arguments: paths) private func theTable(_ p: Path) {
        var s = M.State(task: "a", n: 1, tries: 3, hasGate: false, before: "c0", precheck: p.precheck)
        for (i, step) in p.steps.enumerated() {
            let (next, fx) = M.reduce(s, step.on)
            #expect(next.phase == step.phase && fx == step.fx, "step \(i) (\(step.on)): \(next.phase) \(fx)")
            #expect(fx.dropLast().allSatisfy { !$0.answers }, "step \(i): only the last effect answers")
            s = next
        }
    }

    @Test func withoutAPrecheckItsEventIsStray() {
        var s = M.State(task: "a", n: 1, tries: 3, hasGate: false, before: "c0")
        for step in summoned { s = M.reduce(s, step.on).0 }
        #expect(M.reduce(s, .precheckDone(status: 0, tail: "")).1 == [.fault("waitingCommit × precheckDone")])
    }

    @Test func aFailedPrecheckNudgeFailsNothing() {
        var s = M.State(task: "a", n: 1, tries: 3, hasGate: false, before: "c0", precheck: true)
        for step in failedOnce { s = M.reduce(s, step.on).0 }
        let (next, _) = M.reduce(s, .turnFailed("did not submit"))
        #expect(next.facts.failure == nil && next.phase == .waitingCommit)
    }

    @Test func thePromptHasTheTurnRulesAndFits() {
        let t = WorkTask(id: "m10-2", title: "M10.2 Regra de turno e pré-check", check: "scripts/laco-check.sh M10.2")
        let dir = URL(fileURLWithPath: "/Users/someone/Documents/codes/my-orchestrator-memory/.collie/paddocks/collie")
        let p = WorkLoop.prompt(task: t, spec: nil, attempt: 1, tries: 3, dir: dir, notes: [],
                                gate: "scripts/ci/lint.sh && scripts/ci/check-architecture.sh", map: "docs/feature-map.md")
        #expect(p.contains("Rode build e testes em primeiro plano; não encerre o turno com comando em segundo plano nem monitor pendente."))
        #expect(p.contains("`swift build` não compila os testes: use `swift build --build-tests` ou `swift test --filter`."))
        #expect(p.count <= 1500, "\(p.count)")
    }

    @Test func theTailIsTheLast40LinesUpTo3K() {
        let out = (1...100).map { "linha \($0)" }.joined(separator: "\n")
        let tail = WorkLoop.evidenceTail(check: out, gate: nil, lines: WorkLoop.precheckLines, chars: WorkLoop.precheckChars)
        #expect(tail.split(separator: "\n").count == 40 && tail.hasPrefix("linha 61") && tail.hasSuffix("linha 100"))
        let long = String(repeating: "x", count: 10_000)
        #expect(WorkLoop.evidenceTail(check: long, gate: nil, lines: 40, chars: WorkLoop.precheckChars).count == 3000)
    }

    @Test func theCardShowsThePrecheck() throws {
        let w = Work(title: "W", terminalId: UUID())
        let text = try #require(CommandRouter.loopCardText(w, [task("a", "true")], WorkLoopState(max: 3, precheck: "swift build --build-tests"), paddock: "p"))
        #expect(text.contains("pré-check no fim de cada turno: «swift build --build-tests»."))
        #expect(CommandRouter.loopCardText(w, [task("a", "true")], WorkLoopState(max: 3), paddock: "p")?.contains("pré-check") == false)
    }

    @Test func precheckDecodesAndOldFilesLackIt() throws {
        let l = WorkLoopState(precheck: "make")
        #expect(try JSONDecoder().decode(WorkLoopState.self, from: JSONEncoder().encode(l)).precheck == "make")
        #expect(try JSONDecoder().decode(WorkLoopState.self, from: JSONEncoder().encode(WorkLoopState())).precheck == nil)
    }

    // MARK: with the fake host

    @Test func theAgentFixesAfterTheNudgeAndPassesOnItsFirstAttempt() async throws {
        let pre = "test -f fixed.txt || { echo FALTA fixed.txt; exit 1; }"
        let r = try await LoopRig([task("a", "test -f fixed.txt")], max: 1, precheck: pre); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("a.txt", "x\n", in: $0) },
                                                   prechecked: { try await commit("fixed.txt", "ok\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get(), kinds = (w.loop?.events ?? []).map(\.kind)
        #expect(w.tasks[0].state == .done && w.tasks[0].tries == 1 && w.loop?.used == 1, "\(w.notes.map(\.text))")
        #expect(await r.host.summoned == ["w-task-a-t1"])
        let nudges = await r.host.precheckNudges
        #expect(nudges.count == 1 && nudges[0].prompt.hasPrefix(WorkLoop.precheckPromptHead) && nudges[0].prompt.contains("FALTA fixed.txt"))
        #expect(await r.host.commands == [pre, pre, "test -f fixed.txt"])
        #expect(kinds.filter { $0 == .precheckFailed }.count == 1 && kinds.filter { $0 == .precheckPassed }.count == 1)
        let f = try #require(kinds.firstIndex(of: .precheckFailed)), p = try #require(kinds.firstIndex(of: .precheckPassed))
        #expect(f < p && p < (kinds.firstIndex(of: .checkStarted) ?? 0), "\(kinds.map(\.rawValue))")
    }

    @Test func aSecondFailureGoesToTheCheckWithoutAnotherNudge() async throws {
        let r = try await LoopRig([task("a", "true")], max: 1, precheck: "false"); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("a.txt", "x\n", in: $0) }))
        #expect(await r.run() == .finished)
        let w = try await r.get(), kinds = (w.loop?.events ?? []).map(\.kind)
        #expect(w.tasks[0].state == .done)
        #expect(await r.host.precheckNudges.count == 1)
        #expect(await r.host.commands == ["false", "false", "true"])
        #expect(kinds.filter { $0 == .precheckFailed }.count == 2)
    }

    @Test func withoutAPrecheckNothingChanges() async throws {
        let r = try await LoopRig([task("a", "true")], max: 1); defer { r.cleanup() }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("a.txt", "x\n", in: $0) }))
        #expect(await r.run() == .finished)
        let kinds = (try await r.get().loop?.events ?? []).map(\.kind)
        let cmds = await r.host.commands, nudges = await r.host.precheckNudges
        #expect(cmds == ["true"] && nudges.isEmpty)
        #expect(!kinds.contains(.precheckFailed) && !kinds.contains(.precheckPassed))
    }
}
