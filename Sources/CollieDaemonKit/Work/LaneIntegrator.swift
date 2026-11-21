import Foundation
import CollieProtocol

/// M3.4. The loop's single integrator: joins a lane that passed its check and gate to the paddock's branch, one lane at
/// a time, in the order they asked. In the paddock's worktree `dir`, clean and with no other terminal working in it:
/// `git merge --no-ff`, the gate again on the merged tree, and on a conflict or a broken gate the merge is undone
/// (the tree is back at exactly the HEAD of before) before anything is returned. It never pushes and never touches a
/// branch other than the one checked out in `dir`. Git runs through `LoopHost.git`, the gate through `LoopHost.check`.
/// M3b.2: the gate may take half an hour, and the worktree is the owner's: before anything is reset or removed, who
/// works there (the starter included) and what changed are measured again, and a tree that is not as the integrator
/// left it is left alone (`.leftDirty`, or `.integrated` with `kept`). The integrator cannot tell the gate's own
/// leftovers from the owner's edits, so those stay too.
/// M3c.2: only the tracked files (their diff from what the integrator left) and who works there decide; a new untracked
/// file (a gate's report, coverage) never stops a reset nor the loop: `git reset --hard` does not touch it, and it is
/// never removed, only named (`left`).
actor LaneIntegrator {
    struct Result: Sendable, Equatable {
        var outcome: LaneIntegration.Outcome
        /// The paddock's HEAD after this integration: the base of the next lanes ("" when git could not say).
        var head: String
        /// The gate's output on the merged tree ("" when it did not run), for the task's note.
        var output = ""
        /// M3b.2. What was in the tree and not the integrator's when it would have reset: left there, by name. M3c.2:
        /// never empty only because of untracked files (those are in `left`): a gate that passed with `kept` stops the loop.
        var kept: [String] = []
        /// M3c.2. The untracked files that were not there before the merge (the gate's, or the owner's meanwhile): never
        /// removed, named in the task's note.
        var left: [String] = []
        /// M3b.2. Who was in a turn in the worktree then (the starter included).
        var blockedBy: String? = nil
        /// M3b.2. A merge whose gate broke was left in the branch: the HEAD of before it (`git reset --hard` to undo).
        var undo: String? = nil
    }

    private let host: any LoopHost, dir: URL
    private var busy = false, waiters: [CheckedContinuation<Void, Never>] = []

    /// `host`: the paddock's (its `othersWorking` is about the paddock's worktree); `dir`: the paddock's worktree.
    init(host: any LoopHost, dir: URL) { self.host = host; self.dir = dir }

    /// Integrations waiting for the one running.
    var waiting: Int { waiters.count }

    /// M3b.6: returns once `n` integrations wait for the one running (a continuation, no clock: the tests' wait).
    private var watchers: [(n: Int, c: CheckedContinuation<Void, Never>)] = []
    func untilWaiting(_ n: Int) async {
        guard waiters.count < n else { return }
        await withCheckedContinuation { watchers.append((n, $0)) }
    }
    private func queued(_ c: CheckedContinuation<Void, Never>) {
        waiters.append(c)
        let ready = watchers.filter { $0.n <= waiters.count }
        watchers.removeAll { $0.n <= waiters.count }
        for w in ready { w.c.resume() }
    }

    /// `gateTimeout`: the engine's conditions, measured by the caller (`min(checkTimeout, what is left of the budget)`).
    /// Throws only for a branch that is not a lane's (nothing ran).
    func integrate(_ lane: Lane, title: String, attempt: Int, tries: Int, gate: String?, gateTimeout: Duration) async throws(ProtocolError) -> Result {
        guard lane.branch.hasPrefix(LaneWorktree.branchPrefix) else {
            throw ProtocolError(code: .invalidArgs, message: "'\(lane.branch)' is not a lane branch")
        }
        // FIFO: an actor is reentrant at each await, so the turn is handed over explicitly (`busy` stays true)
        if busy { await withCheckedContinuation { queued($0) } } else { busy = true }
        defer { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
        return await run(lane, title: title, attempt: attempt, tries: tries, gate: gate, gateTimeout: gateTimeout)
    }

    private func run(_ lane: Lane, title: String, attempt: Int, tries: Int, gate: String?, gateTimeout: Duration) async -> Result {
        var f = LaneIntegration.Facts(mergeResult: .noop, gateAfterMerge: .notRun, treeClean: false, othersWorking: nil, attempt: attempt, tries: tries)
        var kept: [String] = [], left: [String] = [], blockedBy: String?, undo: String?
        func done(_ f: LaneIntegration.Facts, _ output: String = "") async -> Result {
            .init(outcome: LaneIntegration.decide(f), head: await out(["rev-parse", "HEAD"]) ?? "", output: output,
                  kept: kept, left: left, blockedBy: blockedBy, undo: undo)
        }
        f.othersWorking = await host.othersWorking()
        // dirt is what the engine calls dirt: a modified tracked file. A status git cannot give counts as dirty.
        let before = await out(["rev-parse", "HEAD"])
        let dirt = await out(["status", "--porcelain", "--untracked-files=no"])
        f.treeClean = before != nil && dirt == ""
        guard f.othersWorking == nil, f.treeClean, let before else { return await done(f) }
        if (try? await host.git(["merge-base", "--is-ancestor", lane.branch, "HEAD"], in: dir))?.status == 0 { return await done(f) }
        // M3b.6: cancelled (the loop or the daemon stopping) before its merge: nothing is merged, and it is no verdict
        if Task.isCancelled { return .init(outcome: .retryFromNewBase(Self.cancelled), head: before) }

        let loose = Set(await untracked())   // the owner's untracked files: never removed
        let message = "merge: " + WorkLoop.eventDetail(title)
        let merge = try? await host.git(["merge", "--no-ff", "--no-edit", "-m", message, lane.branch], in: dir)
        guard let merge, merge.status == 0, let merged = await out(["rev-parse", "HEAD"]), merged != before else {
            // a conflict, or git refused (an untracked file in the way, no identity): either way nothing stays merged
            _ = try? await host.git(["merge", "--abort"], in: dir)
            let s = await settle(back: before, from: before, loose)
            left = s.left
            if !s.reset { (blockedBy, kept, f.disturbed) = (s.who, s.tracked + s.left, true) }
            f.mergeResult = .conflict
            f.detail = merge.map { Self.firstLine($0.stdout + "\n" + $0.stderr) } ?? "git merge could not run"
            return await done(f)
        }
        f.mergeResult = .clean
        guard let gate else { return await done(f) }

        var output = ""
        do throws(ProtocolError) {
            // M3b.6: a cancel ends the gate (its process is killed, or it never starts): the merge is then undone as
            // for a broken gate, under the same rule (only a tree exactly as the merge left it is reset)
            if Task.isCancelled { throw ProtocolError(code: .internal, message: Self.cancelled) }
            let res: ProcessResult
            do { res = try await BoundedProcess.$killOnCancel.withValue(true) { try await host.check(gate, in: dir, timeout: gateTimeout) } }
            catch { throw (error as? ProtocolError) ?? ProtocolError(code: .internal, message: "\(error)") }
            output = res.stdout + res.stderr
            f.detail = WorkLoop.failure("gate", res.status)
        } catch where error.code == .timeout {
            f.detail = WorkLoop.failure("gate", nil)
        } catch { f.detail = WorkLoop.eventDetail("gate could not run: \(error.message)") }
        // like the engine: a gate that moved HEAD does not pass
        if f.detail == nil, await out(["rev-parse", "HEAD"]) != merged { f.detail = "gate moved HEAD" }
        f.gateAfterMerge = f.detail == nil ? .passed : .failed
        // measured again, the gate may have taken long: only a tree whose tracked files are as the merge left them, with
        // nobody in it, is reset (to before the merge, when the gate broke). A gate that passed leaves nothing to restore:
        // what it leaves stops the loop only when a tracked file changed (the next merge would find the tree dirty).
        // ponytail: someone can still start between this and the reset; integrating outside the owner's tree ends it
        if f.detail == nil {
            let tracked = await trackedChanges(since: merged)
            left = await made(loose)
            kept = tracked.isEmpty ? [] : tracked + left
        } else {
            let s = await settle(back: before, from: merged, loose)
            left = s.left
            if !s.reset { (blockedBy, kept, undo, f.disturbed) = (s.who, s.tracked + s.left, before, true) }
        }
        return await done(f, output)
    }

    /// M3b.6: why an integration that was cancelled did not go on.
    static let cancelled = "integração cancelada: o laço parou"

    /// M3c.2: the tracked files back at `sha` (`reset --hard`) when nobody is in a turn in the worktree (`anyoneWorking`:
    /// not the starter only waiting on this work) and they are as the integrator left them (`at`). Untracked files are
    /// never removed: the new ones (not in `loose`) are named in `left`.
    private func settle(back sha: String, from at: String, _ loose: Set<String>) async -> (who: String?, tracked: [String], left: [String], reset: Bool) {
        let who = await host.anyoneWorking(), tracked = await trackedChanges(since: at)
        let reset = who == nil && tracked.isEmpty
        if reset { _ = try? await host.git(["reset", "-q", "--hard", sha], in: dir) }
        return (who, tracked, await made(loose), reset)
    }

    /// Tracked files that differ from `sha`. A diff git cannot give counts as one.
    private func trackedChanges(since sha: String) async -> [String] {
        (await out(["diff", "--name-only", "-z", sha, "--"]))?.split(separator: "\0").map(String.init) ?? ["?"]
    }

    /// Untracked files not in `loose` (not there before the merge).
    private func made(_ loose: Set<String>) async -> [String] { await untracked().filter { !loose.contains($0) } }

    private func untracked() async -> [String] {
        (await out(["ls-files", "-z", "--others", "--exclude-standard"]) ?? "").split(separator: "\0").map(String.init)
    }

    private func out(_ args: [String]) async -> String? {
        guard let r = try? await host.git(args, in: dir), r.status == 0 else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Git's first non-empty line, treated like the notes' text (ANSI, control characters, secrets, length).
    private static func firstLine(_ s: String) -> String {
        WorkLoop.eventDetail(s.split(separator: "\n").first { !$0.allSatisfy(\.isWhitespace) }.map(String.init) ?? "git merge failed")
    }
}
