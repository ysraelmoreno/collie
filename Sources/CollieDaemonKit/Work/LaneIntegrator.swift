import Foundation
import CollieProtocol

/// M3.4. The loop's single integrator: joins a lane that passed its check and gate to the paddock's branch, one lane at
/// a time, in the order they asked. In the paddock's worktree `dir`, clean and with no other terminal working in it:
/// `git merge --no-ff`, the gate again on the merged tree, and on a conflict or a broken gate the merge is undone
/// (the tree is back at exactly the HEAD of before) before anything is returned. It never pushes and never touches a
/// branch other than the one checked out in `dir`. Git runs through `LoopHost.git`, the gate through `LoopHost.check`.
actor LaneIntegrator {
    struct Result: Sendable, Equatable {
        var outcome: LaneIntegration.Outcome
        /// The paddock's HEAD after this integration: the base of the next lanes ("" when git could not say).
        var head: String
        /// The gate's output on the merged tree ("" when it did not run), for the task's note.
        var output = ""
    }

    private let host: any LoopHost, dir: URL
    private var busy = false, waiters: [CheckedContinuation<Void, Never>] = []

    /// `host`: the paddock's (its `othersWorking` is about the paddock's worktree); `dir`: the paddock's worktree.
    init(host: any LoopHost, dir: URL) { self.host = host; self.dir = dir }

    /// Integrations waiting for the one running.
    var waiting: Int { waiters.count }

    /// `gateTimeout`: the engine's conditions, measured by the caller (`min(checkTimeout, what is left of the budget)`).
    /// Throws only for a branch that is not a lane's (nothing ran).
    func integrate(_ lane: Lane, title: String, attempt: Int, tries: Int, gate: String?, gateTimeout: Duration) async throws(ProtocolError) -> Result {
        guard lane.branch.hasPrefix(LaneWorktree.branchPrefix) else {
            throw ProtocolError(code: .invalidArgs, message: "'\(lane.branch)' is not a lane branch")
        }
        // FIFO: an actor is reentrant at each await, so the turn is handed over explicitly (`busy` stays true)
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
        defer { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
        return await run(lane, title: title, attempt: attempt, tries: tries, gate: gate, gateTimeout: gateTimeout)
    }

    private func run(_ lane: Lane, title: String, attempt: Int, tries: Int, gate: String?, gateTimeout: Duration) async -> Result {
        var f = LaneIntegration.Facts(mergeResult: .noop, gateAfterMerge: .notRun, treeClean: false, othersWorking: nil, attempt: attempt, tries: tries)
        func done(_ f: LaneIntegration.Facts, _ output: String = "") async -> Result {
            .init(outcome: LaneIntegration.decide(f), head: await out(["rev-parse", "HEAD"]) ?? "", output: output)
        }
        f.othersWorking = await host.othersWorking()
        // dirt is what the engine calls dirt: a modified tracked file. A status git cannot give counts as dirty.
        let before = await out(["rev-parse", "HEAD"])
        let dirt = await out(["status", "--porcelain", "--untracked-files=no"])
        f.treeClean = before != nil && dirt == ""
        guard f.othersWorking == nil, f.treeClean, let before else { return await done(f) }
        if (try? await host.git(["merge-base", "--is-ancestor", lane.branch, "HEAD"], in: dir))?.status == 0 { return await done(f) }

        let loose = Set(await untracked())   // the owner's untracked files: never removed
        let message = "merge: " + WorkLoop.eventDetail(title)
        let merge = try? await host.git(["merge", "--no-ff", "--no-edit", "-m", message, lane.branch], in: dir)
        guard let merge, merge.status == 0, let merged = await out(["rev-parse", "HEAD"]), merged != before else {
            // a conflict, or git refused (an untracked file in the way, no identity): either way nothing stays merged
            _ = try? await host.git(["merge", "--abort"], in: dir)
            await restore(before, loose)
            f.mergeResult = .conflict
            f.detail = merge.map { Self.firstLine($0.stdout + "\n" + $0.stderr) } ?? "git merge could not run"
            return await done(f)
        }
        f.mergeResult = .clean
        guard let gate else { return await done(f) }

        var output = ""
        do {
            let res = try await host.check(gate, in: dir, timeout: gateTimeout)
            output = res.stdout + res.stderr
            f.detail = WorkLoop.failure("gate", res.status)
        } catch where error.code == .timeout {
            f.detail = WorkLoop.failure("gate", nil)
        } catch { f.detail = WorkLoop.eventDetail("gate could not run: \(error.message)") }
        // like the engine: a gate that moved HEAD does not pass
        if f.detail == nil, await out(["rev-parse", "HEAD"]) != merged { f.detail = "gate moved HEAD" }
        f.gateAfterMerge = f.detail == nil ? .passed : .failed
        // the gate's own edits and files never stay: back to the merge when it passed, to before the merge when not
        await restore(f.detail == nil ? merged : before, loose)
        return await done(f, output)
    }

    /// The tree at exactly `sha`: tracked files restored, untracked files not in `loose` removed. Ignored files stay.
    private func restore(_ sha: String, _ loose: Set<String>) async {
        _ = try? await host.git(["reset", "-q", "--hard", sha], in: dir)
        let made = await untracked().filter { !loose.contains($0) }
        // ponytail: one git call, as the engine's `settle`; chunk if a gate ever leaves tens of thousands of files
        if !made.isEmpty { _ = try? await host.git(["--literal-pathspecs", "clean", "-q", "-f", "--"] + made, in: dir) }
    }

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
