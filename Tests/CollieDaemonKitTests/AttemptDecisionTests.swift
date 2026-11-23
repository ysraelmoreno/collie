import Testing
import CollieCore
@testable import CollieDaemonKit

private typealias Facts = AttemptDecision.Facts
private typealias Outcome = AttemptDecision.Outcome

/// Everything fine, attempt 1 of 3, a gate that passed: each row changes what it tests.
private func facts(_ change: (inout Facts) -> Void = { _ in }) -> Facts {
    var f = Facts(checkStatus: 0, committed: true, attempt: 1, tries: 3, hasGate: true)
    change(&f)
    return f
}

private func retry(_ reason: String) -> Outcome { .retry(reason: reason, discard: true) }

/// M1.3: the attempt's decision is a pure function of the measured facts (no host, store, git or clock).
@Suite struct AttemptDecisionTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let name: String, facts: AttemptDecision.Facts, expected: AttemptDecision.Outcome
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(name: "all fine", facts: facts(), expected: .pass),
        Row(name: "all fine, no gate", facts: facts { $0.hasGate = false }, expected: .pass),
        Row(name: "check failed", facts: facts { $0.checkStatus = 1 }, expected: retry("check failed (exit 1)")),
        Row(name: "check timed out", facts: facts { $0.checkStatus = nil }, expected: retry("check timed out")),
        // the status of a check that did not run is not read
        Row(name: "check could not run", facts: facts { $0.broken = "check could not run: no shell"; $0.checkStatus = nil },
            expected: retry("check could not run: no shell")),
        Row(name: "no new commit", facts: facts { $0.committed = false }, expected: retry("no new commit")),
        Row(name: "dirty tree", facts: facts { $0.dirty = true }, expected: retry("tracked files left dirty")),
        Row(name: "gate failed", facts: facts { $0.gate = "gate failed (exit 2)" }, expected: retry("gate failed (exit 2)")),
        Row(name: "check moved HEAD", facts: facts { $0.moves = ["o check moveu o HEAD"] }, expected: retry("o check moveu o HEAD")),
        Row(name: "gate moved HEAD", facts: facts { $0.moves = ["o portão moveu o HEAD"] }, expected: retry("o portão moveu o HEAD")),
        Row(name: "many reasons, today's order",
            facts: facts { $0.checkStatus = 1; $0.gate = "gate timed out"; $0.committed = false; $0.dirty = true; $0.moves = ["o check moveu o HEAD", "o portão moveu o HEAD"] },
            expected: retry("check failed (exit 1); gate timed out; no new commit; tracked files left dirty; o check moveu o HEAD; o portão moveu o HEAD")),
        Row(name: "broken first, then the verdict, then the moves",
            facts: facts { $0.broken = "check could not run: x"; $0.committed = false; $0.moves = ["o check moveu o HEAD"] },
            expected: retry("check could not run: x; no new commit; o check moveu o HEAD")),
        // summon or ask failed: its message alone, whatever else is in the facts
        Row(name: "failure before the check", facts: facts { $0.failure = "summon failed"; $0.checkStatus = 1; $0.committed = false },
            expected: retry("summon failed")),
        Row(name: "2nd of 3 retries", facts: facts { $0.checkStatus = 1; $0.attempt = 2 }, expected: retry("check failed (exit 1)")),
        Row(name: "3rd of 3 defers", facts: facts { $0.checkStatus = 1; $0.attempt = 3 },
            expected: .defer(reason: "check failed (exit 1)", discard: true)),
        Row(name: "past the tries defers", facts: facts { $0.committed = false; $0.attempt = 4 },
            expected: .defer(reason: "no new commit", discard: true)),
        Row(name: "failure on the last try defers", facts: facts { $0.failure = "ask failed"; $0.attempt = 3 },
            expected: .defer(reason: "ask failed", discard: true)),
        Row(name: "blocked stops the loop", facts: facts { $0.checkStatus = 1; $0.blockedBy = "Rex" },
            expected: .stopLoop(.init(.othersWorking, detail: "Rex"), reason: "check failed (exit 1)")),
        Row(name: "blocked on the last try never defers", facts: facts { $0.checkStatus = 1; $0.attempt = 3; $0.blockedBy = "Rex" },
            expected: .stopLoop(.init(.othersWorking, detail: "Rex"), reason: "check failed (exit 1)")),
        Row(name: "blocked, gate did not run", facts: facts { $0.gate = "gate did not run (tree not reset)"; $0.blockedBy = "Rex" },
            expected: .stopLoop(.init(.othersWorking, detail: "Rex"), reason: "gate did not run (tree not reset)")),
        // the task passes; the loop then stops (`attempt()`: `return blocked == nil`), which is not this outcome's to say
        Row(name: "pass with another terminal working", facts: facts { $0.hasGate = false; $0.blockedBy = "Rex" }, expected: .pass),
        // F2 R3: a refusal is one more reason, after the others
        Row(name: "review refused", facts: facts { $0.review = "revisor recusou: x" }, expected: retry("revisor recusou: x")),
        Row(name: "review refused on the last try", facts: facts { $0.review = "revisor recusou: x"; $0.attempt = 3 },
            expected: .defer(reason: "revisor recusou: x", discard: true)),
        Row(name: "review refused twice in a row defers with tries left", facts: facts { $0.review = "revisor recusou: x"; $0.reviewRejectsInRow = 1 },
            expected: .defer(reason: "\(AttemptDecision.twiceRefused); revisor recusou: x", discard: true)),
        Row(name: "a refusal in a row before, approved now: passes", facts: facts { $0.reviewRejectsInRow = 1; $0.reviewNotes = ["n"] }, expected: .pass),
        Row(name: "refused twice while another terminal works: the loop stops, nothing deferred",
            facts: facts { $0.review = "revisor recusou: x"; $0.reviewRejectsInRow = 1; $0.blockedBy = "Rex" },
            expected: .stopLoop(.init(.othersWorking, detail: "Rex"), reason: "revisor recusou: x")),
    ]

    @Test(arguments: rows) func decides(_ row: Row) {
        #expect(AttemptDecision.decide(row.facts) == row.expected)
    }

    @Test func reasonIsNilOnlyWhenItPasses() {
        for row in Self.rows { #expect((AttemptDecision.reason(row.facts) == nil) == (row.expected == .pass), "\(row.name)") }
    }
}
