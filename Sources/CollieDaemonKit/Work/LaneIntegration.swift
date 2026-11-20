/// M3.4. What integrating a lane into the paddock's branch ends as, decided from facts `LaneIntegrator` already
/// measured. Pure: no host, git or clock.
enum LaneIntegration {
    enum Merge: Sendable, Equatable {
        case clean, conflict
        /// Nothing to merge (the lane's branch is already in the paddock's), or no merge was tried.
        case noop
    }

    enum Gate: Sendable, Equatable {
        case passed
        /// It exited non-zero, timed out, could not run or moved HEAD: all the same to the decision.
        case failed
        /// There is no gate, or the merge did not get that far.
        case notRun
    }

    struct Facts: Sendable, Equatable {
        var mergeResult: Merge
        var gateAfterMerge: Gate
        /// No tracked file of the paddock's worktree was modified before the merge.
        var treeClean: Bool
        /// Another terminal in a turn in the paddock's worktree: its name.
        var othersWorking: String?
        var attempt: Int
        var tries: Int
        /// Git's or the gate's own words, appended to the reason.
        var detail: String?
    }

    enum Outcome: Sendable, Equatable {
        case integrated
        /// Conflict, or the gate broke on the merged tree, with tries left: the merge is undone and the task redoes its
        /// attempt from the paddock's new HEAD.
        case retryFromNewBase(String)
        /// The same on the last try: the task is deferred.
        case `defer`(String)
        /// Another terminal works in the paddock's worktree, or it is dirty: nothing was touched or undone; the caller
        /// waits or stops, as the engine does. Never a `defer`: it is not the task's fault.
        case wait(String)
        case noop
    }

    static func decide(_ f: Facts) -> Outcome {
        if let who = f.othersWorking { return .wait("'\(who)' is working in the paddock's worktree") }
        guard f.treeClean else { return .wait("the paddock's worktree has uncommitted changes") }
        let why: String
        switch (f.mergeResult, f.gateAfterMerge) {
        case (.noop, _): return .noop
        case (.clean, .passed), (.clean, .notRun): return .integrated
        case (.conflict, _): why = "merge conflict"
        case (.clean, .failed): why = "gate broke after the merge"
        }
        let reason = [why, f.detail].compactMap { $0 }.joined(separator: ": ")
        return f.attempt >= f.tries ? .defer(reason) : .retryFromNewBase(reason)
    }
}
