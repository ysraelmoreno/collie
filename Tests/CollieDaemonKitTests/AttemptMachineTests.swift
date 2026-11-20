import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

private typealias M = AttemptMachine

private let agent = UUID()
private let rex = WorkLoopState.Stop(.othersWorking, detail: "Rex")

/// One line of a table: the event, then the phase and the effects `reduce` must answer with.
private struct Step: Sendable {
    let on: M.Event, phase: M.Phase, fx: [M.Effect]
    init(_ on: M.Event, _ phase: M.Phase, _ fx: [M.Effect]) { self.on = on; self.phase = phase; self.fx = fx }
}

private func verdict(_ text: String, then last: M.Effect) -> [M.Effect] { [.show(nil), .journal(.verdict, text), last] }
private func retry(_ reason: String) -> M.Event { .decided(.retry(reason: reason, discard: true)) }
private func retried(_ reason: String, patch: String = "a-1.patch") -> [M.Effect] {
    [.discard, .journal(.discarded, patch), .markOpenOrDeferred(reason: reason, last: false)]
}

/// A turn that ended by hook with a commit, the agent dismissed.
private let turn: [Step] = [
    Step(.started, .summoning, [.journal(.attemptStarted, nil), .summon]),
    Step(.summoned(agent), .turn, [.journal(.agentSummoned, "loop-a-1"), .ask]),
    Step(.turnEnded(source: .hook), .waitingCommit, [.journal(.turnEnded, "hook"), .lookForCommit]),
    Step(.commitSeen("c1"), .waitingCommit, [.journal(.commitSeen, "c1"), .dismiss, .journal(.agentDismissed, nil), .measureFacts]),
]
private let startCheck: [M.Effect] = [.show(.check), .journal(.checkStarted, nil), .runCheck]
private func measured(committed: Bool = true, dirty: Bool = false) -> Step {
    Step(.measured(.init(committed: committed, dirty: dirty, judged: "c1")), .checking, startCheck)
}
/// Through a check that exits `status` on a clean tree, no other terminal working, the tree put back.
private func checked(_ status: Int32? = 0, committed: Bool = true) -> [Step] {
    turn + [
        measured(committed: committed),
        Step(.checkDone(status: status, broken: nil), .checking, [.journal(.checkFinished, status.map { "exit \($0)" } ?? "timeout"), .awaitOthers]),
        Step(.blocked(nil), .checking, [.settle(reset: true)]),
    ]
}
/// Through a gate that started.
private let gating: [Step] = checked() + [
    Step(.settled(moved: false, reset: false), .checking, [.guardGate]),
    Step(.gateClear, .gating, [.show(.gate), .journal(.gateStarted, nil), .runGate]),
]

private struct Path: Sendable, CustomTestStringConvertible {
    let name: String
    var gate = true, n = 1
    let steps: [Step]
    var testDescription: String { name }
    var start: M.State { M.State(task: "a", n: n, tries: 3, hasGate: gate, before: "c0") }
}

private let happy = Path(name: "happy path: idle turn, check and gate pass", steps: [
    Step(.started, .summoning, [.journal(.attemptStarted, nil), .summon]),
    Step(.summoned(agent), .turn, [.journal(.agentSummoned, "loop-a-1"), .ask]),
    Step(.turnEnded(source: .idle), .waitingCommit, [.journal(.turnEnded, "idle"), .waitForCommit]),
    Step(.commitSeen("c1"), .waitingCommit, [.journal(.commitSeen, "c1"), .dismiss, .journal(.agentDismissed, nil), .measureFacts]),
    measured(),
    Step(.checkDone(status: 0, broken: nil), .checking, [.journal(.checkFinished, "exit 0"), .awaitOthers]),
    Step(.blocked(nil), .checking, [.settle(reset: true)]),
    Step(.settled(moved: false, reset: true), .checking, [.journal(.treeReset, nil), .guardGate]),
    Step(.gateClear, .gating, [.show(.gate), .journal(.gateStarted, nil), .runGate]),
    Step(.gateDone(status: 0, broken: nil), .gating, [.journal(.gateFinished, "exit 0"), .awaitOthers]),
    Step(.blocked(nil), .gating, [.settle(reset: true)]),
    Step(.settled(moved: false, reset: true), .deciding, [.journal(.treeReset, nil)] + verdict("passou", then: .decide)),
    Step(.decided(.pass), .finished, [.markDone]),
])

private let paths: [Path] = [
    happy,
    Path(name: "no gate: the check alone", gate: false, steps: checked() + [
        Step(.settled(moved: false, reset: false), .deciding, verdict("passou", then: .decide)),
        Step(.decided(.pass), .finished, [.markDone]),
    ]),
    Path(name: "check fails: no gate, the others asked before the discard, retry", steps: checked(1) + [
        Step(.settled(moved: false, reset: true), .deciding, [.journal(.treeReset, nil)] + verdict("check failed (exit 1)", then: .awaitOthers)),
        Step(.blocked(nil), .deciding, [.decide]),
        Step(retry("check failed (exit 1)"), .finished, retried("check failed (exit 1)")),
    ]),
    Path(name: "check times out", steps: checked(nil) + [
        Step(.settled(moved: false, reset: false), .deciding, verdict("check timed out", then: .awaitOthers)),
        Step(.blocked(nil), .deciding, [.decide]),
        Step(retry("check timed out"), .finished, retried("check timed out")),
    ]),
    Path(name: "check could not run", steps: turn + [
        measured(),
        Step(.checkDone(status: nil, broken: "check could not run: x"), .checking, [.journal(.checkFinished, "não rodou"), .awaitOthers]),
        Step(.blocked(nil), .checking, [.settle(reset: true)]),
        Step(.settled(moved: false, reset: false), .deciding, verdict("check could not run: x", then: .awaitOthers)),
    ]),
    Path(name: "turn timed out: not a failure by itself, the check runs", steps: Array(turn.prefix(2)) + [
        Step(.turnTimedOut, .waitingCommit, [.journal(.turnEnded, "timeout"), .lookForCommit]),
        Step(.waitExpired, .waitingCommit, [.dismiss, .journal(.agentDismissed, nil), .measureFacts]),
        measured(committed: false),
        Step(.checkDone(status: 0, broken: nil), .checking, [.journal(.checkFinished, "exit 0"), .awaitOthers]),
        Step(.blocked(nil), .checking, [.settle(reset: true)]),
        Step(.settled(moved: false, reset: false), .deciding, verdict("no new commit", then: .awaitOthers)),
    ]),
    Path(name: "turn failed: dismissed, no check, deferred on the last try", n: 3, steps: [
        Step(.started, .summoning, [.journal(.attemptStarted, nil), .summon]),
        Step(.summoned(agent), .turn, [.journal(.agentSummoned, "loop-a-3"), .ask]),
        Step(.turnFailed("boom"), .waitingCommit, [.journal(.turnEnded, "erro: boom"), .lookForCommit]),
        Step(.waitExpired, .waitingCommit, [.dismiss, .journal(.agentDismissed, nil), .measureFacts]),
        Step(.measured(nil), .deciding, verdict("boom", then: .awaitOthers)),
        Step(.blocked(nil), .deciding, [.decide]),
        Step(.decided(.defer(reason: "boom", discard: true)), .finished,
             [.discard, .journal(.discarded, "a-3.patch"), .markOpenOrDeferred(reason: "boom", last: true)]),
    ]),
    Path(name: "summon failed: no terminal to dismiss, no check; another terminal working stops the loop", steps: [
        turn[0],
        Step(.summonFailed("no pty"), .summoning, [.measureFacts]),
        Step(.measured(nil), .deciding, verdict("no pty", then: .awaitOthers)),
        Step(.blocked("Rex"), .deciding, [.decide]),
        Step(.decided(.stopLoop(rex, reason: "no pty")), .finished,
             [.markOpenOrDeferred(reason: "no pty", last: false), .note(WorkLoop.blockedNote("Rex")), .stopLoop(rex)]),
    ]),
    Path(name: "blocked after the check: no reset, the gate does not run, the loop stops", steps: Array(checked().dropLast()) + [
        Step(.blocked("Rex"), .checking, [.settle(reset: false)]),
        Step(.settled(moved: false, reset: false), .deciding,
             [.journal(.gateFinished, "não rodou")] + verdict("gate did not run (tree not reset)", then: .decide)),
        Step(.decided(.stopLoop(rex, reason: "gate did not run (tree not reset)")), .finished,
             [.markOpenOrDeferred(reason: "gate did not run (tree not reset)", last: false), .note(WorkLoop.blockedNote("Rex")), .stopLoop(rex)]),
    ]),
    Path(name: "blocked after a check that passed, no gate: the task is done, then the loop stops", gate: false, steps: Array(checked().dropLast()) + [
        Step(.blocked("Rex"), .checking, [.settle(reset: false)]),
        Step(.settled(moved: false, reset: false), .deciding, verdict("passou", then: .decide)),
        Step(.decided(.pass), .finished, [.markDone, .note(WorkLoop.blockedNote("Rex")), .stopLoop(rex)]),
    ]),
    Path(name: "blocked after the gate: no reset", steps: gating + [
        Step(.gateDone(status: 0, broken: nil), .gating, [.journal(.gateFinished, "exit 0"), .awaitOthers]),
        Step(.blocked("Rex"), .gating, [.settle(reset: false)]),
        Step(.settled(moved: false, reset: false), .deciding, verdict("passou", then: .decide)),
    ]),
    Path(name: "gate does not run: no commit", steps: checked(committed: false) + [
        Step(.settled(moved: false, reset: false), .deciding, verdict("no new commit", then: .awaitOthers)),
    ]),
    Path(name: "gate does not run: dirty tree, which is never reset nor asked about before the verdict", steps: turn + [
        measured(dirty: true),
        Step(.checkDone(status: 0, broken: nil), .checking, [.journal(.checkFinished, "exit 0"), .settle(reset: false)]),
        Step(.settled(moved: false, reset: false), .deciding, verdict("tracked files left dirty", then: .awaitOthers)),
    ]),
    Path(name: "gate does not run: the check moved HEAD", steps: checked() + [
        Step(.settled(moved: true, reset: true), .deciding,
             [.journal(.treeReset, "moveu o HEAD")] + verdict("o check moveu o HEAD", then: .awaitOthers)),
    ]),
    Path(name: "gate does not run: the attempt changed a script the gate runs", steps: checked() + [
        Step(.settled(moved: false, reset: false), .checking, [.guardGate]),
        Step(.gateSkipped("a tentativa alterou «lint.sh», que o portão executa"), .deciding,
             [.journal(.gateFinished, "não rodou")] + verdict("a tentativa alterou «lint.sh», que o portão executa", then: .awaitOthers)),
    ]),
    Path(name: "gate fails and moves HEAD", steps: gating + [
        Step(.gateDone(status: 2, broken: nil), .gating, [.journal(.gateFinished, "exit 2"), .awaitOthers]),
        Step(.blocked(nil), .gating, [.settle(reset: true)]),
        Step(.settled(moved: true, reset: true), .deciding,
             [.journal(.treeReset, "moveu o HEAD")] + verdict("gate failed (exit 2); o portão moveu o HEAD", then: .awaitOthers)),
    ]),
    Path(name: "gate times out", steps: gating + [
        Step(.gateDone(status: nil, broken: nil), .gating, [.journal(.gateFinished, "timeout"), .awaitOthers]),
        Step(.blocked(nil), .gating, [.settle(reset: true)]),
        Step(.settled(moved: false, reset: false), .deciding, verdict("gate timed out", then: .awaitOthers)),
    ]),
    Path(name: "gate could not run", steps: gating + [
        Step(.gateDone(status: nil, broken: "gate could not run: x"), .gating, [.journal(.gateFinished, "não rodou"), .awaitOthers]),
        Step(.blocked(nil), .gating, [.settle(reset: true)]),
        Step(.settled(moved: false, reset: false), .deciding, verdict("gate could not run: x", then: .awaitOthers)),
    ]),
]

/// The happy path's state after each of its events (and before the first): every phase but `finished`.
private func alongTheHappyPath() -> [M.State] {
    var s = happy.start, all = [s]
    for step in happy.steps.dropLast() { s = M.reduce(s, step.on).0; all.append(s) }
    return all
}

/// M1.4: the attempt's phases are a pure state machine (no host, git or time): (state, event) → (state, effects).
@Suite struct AttemptMachineTests {
    @Test(arguments: paths) fileprivate func transitions(_ path: Path) {
        var s = path.start
        for (i, step) in path.steps.enumerated() {
            let (next, fx) = M.reduce(s, step.on)
            #expect(fx == step.fx, "step \(i): \(step.on)")
            #expect(next.phase == step.phase, "step \(i): \(step.on)")
            // the interpreter relies on it: only the last effect of a list answers with an event
            #expect(fx.dropLast().allSatisfy { !$0.answers }, "step \(i): \(step.on)")
            #expect(fx.last?.answers == (next.phase != .finished), "step \(i): \(step.on)")
            s = next
        }
    }

    @Test func theStateKeepsWhatTheAttemptLearned() {
        var s = happy.start
        for step in happy.steps { s = M.reduce(s, step.on).0 }
        var facts = AttemptDecision.Facts(checkStatus: 0, committed: true, attempt: 1, tries: 3, hasGate: true)
        #expect(s.facts == facts)
        #expect(s.before == "c0" && s.judged == "c1" && s.agent == nil)
        // a gate that failed after a check that moved nothing
        s = paths[0].start
        for step in gating { s = M.reduce(s, step.on).0 }
        #expect(s.agent == nil)
        s = M.reduce(s, .gateDone(status: 2, broken: nil)).0
        s = M.reduce(s, .blocked("Rex")).0
        s = M.reduce(s, .settled(moved: true, reset: false)).0
        facts.gate = "gate failed (exit 2)"; facts.blockedBy = "Rex"; facts.moves = ["o portão moveu o HEAD"]
        #expect(s.facts == facts)
    }

    @Test func theAgentIsKnownWhileItsTerminalIsOpen() {
        let states = alongTheHappyPath()
        #expect(states.map { $0.agent != nil } == [false, false, true, true] + Array(repeating: false, count: states.count - 4))
    }

    /// Cancelled, work closed, starter gone: in each phase, out with no verdict, nothing discarded, no facts changed.
    @Test func leavesWithNoVerdictInEachPhase() {
        let states = alongTheHappyPath()
        #expect(Set(states.map(\.phase)) == Set(M.Phase.allCases).subtracting([.finished]))
        let ways: [(M.Event, [M.Effect])] = [
            (.cancelled, [.uncount, .stopLoop(.init(.cancelled))]),
            (.workClosed, [.reopen(job: "work closed"), .stopLoop(.init(.workGone))]),
            (.starterGone, [.reopen(job: "starter gone"), .stopLoop(.init(.starterGone))]),
        ]
        for s in states {
            for (event, out) in ways {
                let (next, fx) = M.reduce(s, event)
                // a terminal still open is dismissed first
                let open: [M.Effect] = s.agent == nil ? [] : [.dismiss, .journal(.agentDismissed, nil)]
                #expect(fx == open + out, "\(s.phase), \(event)")
                #expect(next.phase == .finished && next.agent == nil && next.facts == s.facts, "\(s.phase), \(event)")
            }
        }
    }

    @Test func finishedTakesNoEvent() {
        var s = happy.start
        for step in happy.steps { s = M.reduce(s, step.on).0 }
        for e: M.Event in [.started, .cancelled, .workClosed, .starterGone, .decided(.pass), .checkDone(status: 1, broken: nil)] {
            let (next, fx) = M.reduce(s, e)
            #expect(next == s && fx.isEmpty, "\(e)")
        }
    }

    /// M1b.1: the state stays, and the interpreter is told (`fault`) instead of nothing.
    @Test func anEventOfAnotherPhaseChangesNothing() {
        let states = alongTheHappyPath()
        let strays: [M.Event] = [.started, .gateDone(status: 0, broken: nil), .decided(.pass), .turnTimedOut]
        for s in states where s.phase == .checking {
            for e in strays {
                let (next, fx) = M.reduce(s, e)
                #expect(next == s && fx.count == 1, "\(e)")
                if case .fault = fx.first {} else { Issue.record("\(e): \(fx)") }
            }
        }
    }
}
