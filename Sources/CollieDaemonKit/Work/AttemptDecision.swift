import CollieCore

/// What a loop attempt ends as, decided from facts `WorkLoop.attempt()` already measured. Pure: no host, store, git or
/// clock. `attempt()` measures, calls `decide` and carries the outcome out (reset, patch, note, evidence, store).
enum AttemptDecision {
    struct Facts: Sendable, Equatable {
        /// Summon or ask failed before the check: the reason is this alone, the check's facts are not read.
        var failure: String?
        /// The check could not run (its `checkStatus` is then not read).
        var broken: String?
        /// The check's exit status; nil: it timed out.
        var checkStatus: Int32?
        /// The gate's result: nil when it passed, did not need to run or there is none.
        var gate: String?
        /// F3: the runtime acceptance's result: nil when it passed, did not need to run or the task has none.
        var accept: String?
        var committed = false
        var dirty = false
        /// The check or the gate moved HEAD, in that order.
        var moves: [String] = []
        /// Another terminal of the paddock is working: no reset under it, the loop stops.
        var blockedBy: String?
        var attempt: Int
        var tries: Int
        /// The loop has a gate. No rule reads it today (a gate that did not run is in `gate`); here for the machine (M1.4).
        var hasGate = false
        /// F2 R3: the review refused (`revisor recusou: ...`); nil when it approved, did not run or there is none.
        var review: String?
        /// F2 R3: minor/nit of an approving review, for the attempt's note.
        var reviewNotes: [String] = []
        /// F2 R3: refusals by the review of this task in a row BEFORE this attempt (the caller keeps it between attempts).
        var reviewRejectsInRow = 0
    }

    enum Outcome: Sendable, Equatable {
        /// The task is done. With `blockedBy` it is still `.pass`: the task passed and keeps its evidence, and it is
        /// `attempt()` that then stops the loop instead of going on (what `return blocked == nil` did), with nothing
        /// to discard. So `.pass` does not say whether the loop goes on: `Facts.blockedBy` does.
        case pass
        /// Failed with tries left: the task reopens. `discard`: the attempt's work becomes a patch and the tree goes
        /// back; always true today (the only reason not to discard is another terminal working, which is `.stopLoop`).
        case retry(reason: String, discard: Bool)
        /// Failed on its last try: the task is deferred. Never with `blockedBy`: a stopped loop defers nothing.
        case `defer`(reason: String, discard: Bool)
        /// Failed while another terminal works: nothing discarded, the task reopens (even on its last try), the loop stops.
        case stopLoop(WorkLoopState.Stop, reason: String)
    }

    /// Why the attempt fails, exactly the text the loop records (`broken`, the verdict, `moves`, joined by `; `);
    /// nil = it passes.
    static func reason(_ f: Facts) -> String? {
        if let failure = f.failure { return failure }
        let v = WorkLoop.verdict(checkStatus: f.broken == nil ? f.checkStatus : 0, gate: f.gate, committed: f.committed, dirty: f.dirty)
        let reasons = [f.broken, v, f.accept].compactMap { $0 } + f.moves + [f.review].compactMap { $0 }
        return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }

    static var twiceRefused: String { tr("recusada duas vezes pela revisão: chame o dono", "refused twice by review: call the owner") }

    static func decide(_ f: Facts) -> Outcome {
        guard let reason = reason(f) else { return .pass }
        if let who = f.blockedBy { return .stopLoop(.init(.othersWorking, detail: who), reason: reason) }
        // F2 R3: the second refusal in a row is the owner's call, whatever tries are left
        if f.review != nil, f.reviewRejectsInRow >= 1 { return .defer(reason: "\(twiceRefused); \(reason)", discard: true) }
        return f.attempt >= f.tries ? .defer(reason: reason, discard: true) : .retry(reason: reason, discard: true)
    }
}
