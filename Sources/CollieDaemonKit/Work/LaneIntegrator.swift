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
/// M3d.3: except what the gate itself made: the untracked files new after it ran (`left`, when nothing was kept) are
/// recorded with their content, and before the next merge (and at the loop's end, `sweep`) the ones still untracked and
/// unchanged are removed, by name. One the owner changed since is left and named (`spared`). A merge git refuses for an
/// untracked file that is not the gate's in the lane's way stops the loop (`.leftDirty`) instead of redoing the task.
/// M6.3: nothing is removed any more. The gate's files are moved, by name, into a quarantine inside the worktree's git
/// dir (`<gitdir>/collie-gate-leftovers/<n>/`), emptied when the next loop starts: one the owner made while the gate ran
/// is recoverable. Every git that is given file names runs with `--literal-pathspecs` (a `pages/[id].js` is that file,
/// never a glob), and a name with `..`, `.git`, a leading `/` or a backslash is never touched.
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
        /// M3d.3. Files an earlier gate left that the owner changed since: not removed, named in the task's note.
        var spared: [String] = []
        /// M6.3. Files an earlier gate left, moved into the quarantine `quarantine` (not removed).
        var moved: [String] = []
        var quarantine: String? = nil
    }

    /// M6.3. What `sweep` did: `moved` into `at`; `spared` left in the tree (changed since the gate, a name the
    /// integrator refuses to touch, or over the quarantine's limit).
    struct Swept: Sendable, Equatable {
        var moved: [String] = [], spared: [String] = [], at: String? = nil
    }

    /// M6.3. The quarantine's ceiling per loop: past it, the gate's files stay in the tree (named, as spared).
    static let quarantineFiles = 200, quarantineBytes = 5 * 1024 * 1024
    static let quarantineDir = "collie-gate-leftovers"

    /// F3: one integrator per paddock (`PaddockIntegrators`): the loop that takes it `adopt`s it, a field's land lends
    /// its own host for its one integration (`integrate(as:)`).
    private var host: any LoopHost
    private let dir: URL
    /// M7.2. The loop's work: each box it makes carries it (`<n>.work`), and `clearQuarantine` empties only those.
    private var work: UUID?
    private var busy = false, waiters: [CheckedContinuation<Void, Never>] = []
    /// M3d.3. The untracked files the last gates made, by path: their `git hash-object` right after the gate.
    private var gateMade: [String: String] = [:]
    /// M6.3. What this loop's sweeps moved into the quarantine so far.
    private var quarantined = (files: 0, bytes: 0)

    /// `host`: the paddock's (its `othersWorking` is about the paddock's worktree); `dir`: the paddock's worktree;
    /// `work`: the loop's (nil: its boxes carry no mark, and `clearQuarantine` empties nothing).
    init(host: any LoopHost, dir: URL, work: UUID? = nil) { self.host = host; self.dir = dir; self.work = work }

    /// F3: the paddock's integrator taken by a loop: its host and work from now on. ponytail: one loop per paddock and
    /// no field alongside a loop in lanes (`work run --parallel` refuses), so nothing else holds it then.
    /// While a field's land has lent its host (`integrate(as:)`), the loop's host waits in `lentOver` and is the one
    /// restored after it: the lend never undoes an `adopt`.
    func adopt(host: any LoopHost, work: UUID?) {
        if lentOver != nil { lentOver = host } else { self.host = host }
        self.work = work
    }
    /// The integrator's own host while `integrate(as:)` runs with another.
    private var lentOver: (any LoopHost)?

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
    /// Throws only for a branch that is not a lane's (nothing ran). F3: a field's (`collie/field/`) too.
    /// `other`: the host for this integration only (a field's land), in the same queue; the integrator's own after it.
    /// `tip`: the commit merged (a sha of the branch: a field's judged commit), instead of the branch's tip now.
    func integrate(_ lane: Lane, title: String, attempt: Int, tries: Int, gate: String?, gateTimeout: Duration,
                   as other: (any LoopHost)? = nil, tip: String? = nil) async throws(ProtocolError) -> Result {
        guard lane.branch.hasPrefix(LaneWorktree.branchPrefix) || lane.isField else {
            throw ProtocolError(code: .invalidArgs, message: "'\(lane.branch)' is not a lane branch")
        }
        // FIFO: an actor is reentrant at each await, so the turn is handed over explicitly (`busy` stays true)
        if busy { await withCheckedContinuation { queued($0) } } else { busy = true }
        defer { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
        if let tip, tip.range(of: "^[0-9a-f]{40}([0-9a-f]{24})?$", options: .regularExpression) == nil {
            throw ProtocolError(code: .invalidArgs, message: "'\(tip)' is not a commit sha")
        }
        if let other { lentOver = host; host = other }
        defer { if let own = lentOver { host = own; lentOver = nil } }   // runs before the turn is handed over
        return await run(lane, title: title, attempt: attempt, tries: tries, gate: gate, gateTimeout: gateTimeout, merging: tip ?? lane.branch)
    }

    private func run(_ lane: Lane, title: String, attempt: Int, tries: Int, gate: String?, gateTimeout: Duration, merging target: String) async -> Result {
        var f = LaneIntegration.Facts(mergeResult: .noop, gateAfterMerge: .notRun, treeClean: false, othersWorking: nil, attempt: attempt, tries: tries)
        var kept: [String] = [], left: [String] = [], blockedBy: String?, undo: String?, swept = Swept()
        func done(_ f: LaneIntegration.Facts, _ output: String = "") async -> Result {
            .init(outcome: LaneIntegration.decide(f), head: await out(["rev-parse", "HEAD"]) ?? "", output: output,
                  kept: kept, left: left, blockedBy: blockedBy, undo: undo, spared: swept.spared,
                  moved: swept.moved, quarantine: swept.at)
        }
        f.othersWorking = await host.othersWorking()
        // dirt is what the engine calls dirt: a modified tracked file. A status git cannot give counts as dirty.
        let before = await out(["rev-parse", "HEAD"])
        let dirt = await out(["--literal-pathspecs", "status", "--porcelain", "--untracked-files=no"])
        f.treeClean = before != nil && dirt == ""
        guard f.othersWorking == nil, f.treeClean, let before else { return await done(f) }
        swept = await sweep()
        if (try? await host.git(["merge-base", "--is-ancestor", target, "HEAD"], in: dir))?.status == 0 { return await done(f) }
        // M3b.6: cancelled (the loop or the daemon stopping) before its merge: nothing is merged, and it is no verdict
        if Task.isCancelled { return .init(outcome: .retryFromNewBase(Self.cancelled), head: before) }

        let loose = Set(await untracked())   // the owner's untracked files: never removed
        let message = "merge: " + WorkLoop.eventDetail(title)
        let merge = try? await host.git(["merge", "--no-ff", "--no-edit", "-m", message, target], in: dir)
        guard let merge, merge.status == 0, let merged = await out(["rev-parse", "HEAD"]), merged != before else {
            // a conflict, or git refused (an untracked file in the way, no identity): either way nothing stays merged
            _ = try? await host.git(["merge", "--abort"], in: dir)
            let s = await settle(back: before, from: before, loose)
            left = s.left
            if !s.reset { (blockedBy, kept, f.disturbed) = (s.who, s.tracked + s.left, true) }
            f.mergeResult = .conflict
            f.detail = merge.map { Self.firstLine($0.stdout + "\n" + $0.stderr) } ?? "git merge could not run"
            // M3d.3: an untracked file that is not the gate's (it was swept) in the lane's way: no retry fixes that
            let way = await inTheWay(target, from: before)
            if !way.isEmpty {
                (blockedBy, kept, f.disturbed) = (s.who, kept + way.filter { !kept.contains($0) }, true)
                f.detail = "arquivos não rastreados que não são do portão no caminho do merge: "
                    + WorkLoop.eventDetail(way.prefix(10).joined(separator: ", "))
            }
            return await done(f)
        }
        f.mergeResult = .clean
        guard let gate else { return await done(f) }

        var output = "", ran = false
        do throws(ProtocolError) {
            // M3b.6: a cancel ends the gate (its process is killed, or it never starts): the merge is then undone as
            // for a broken gate, under the same rule (only a tree exactly as the merge left it is reset)
            if Task.isCancelled { throw ProtocolError(code: .internal, message: Self.cancelled) }
            let res: ProcessResult
            ran = true
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
        // M3d.3: only a tree as the integrator expects: with anything kept, nothing new is taken as the gate's
        // M6.3: a file the owner made while the gate ran counts as the gate's, but it is moved to the quarantine, never lost
        if ran, kept.isEmpty, !left.isEmpty, let h = await hashes(left) {
            for (file, hash) in zip(left, h) { gateMade[file] = hash }
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

    /// M3d.3: takes away the files the gates made that are still untracked and as the gate left them. M6.3: moved (by
    /// name, never `git clean`) into this sweep's quarantine. Each file is forgotten either way: one spared is the
    /// owner's from then on.
    /// ponytail: the owner may still edit between the hash and the move; a lock on the owner's tree does not exist
    func sweep() async -> Swept {
        guard !gateMade.isEmpty else { return .init() }
        let made = gateMade
        gateMade = [:]
        let still = Set(await untracked()), here = made.keys.filter(still.contains).sorted()
        guard !here.isEmpty else { return .init() }
        guard let now = await hashes(here) else { return .init(spared: here) }
        var out = Swept(), gone: [String] = []
        for (file, hash) in zip(here, now) {
            if made[file] == hash, Self.touchable(file) { gone.append(file) } else { out.spared.append(file) }
        }
        guard !gone.isEmpty else { return out }
        guard let box = await newQuarantine() else { out.spared += gone; return out }
        let fm = FileManager.default
        for file in gone {
            let src = dir.appendingPathComponent(file)
            // M7.2 (A6): a parent swapped for a symlink since the hash would move a file from outside the tree
            guard Self.inside(src, dir) else { out.spared.append(file); continue }
            let size = ((try? fm.attributesOfItem(atPath: src.path))?[.size] as? Int) ?? 0
            guard quarantined.files < Self.quarantineFiles, quarantined.bytes + size <= Self.quarantineBytes else {
                out.spared.append(file); continue
            }
            let dst = box.appendingPathComponent(file)
            do {
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: src, to: dst)
                quarantined = (quarantined.files + 1, quarantined.bytes + size)
                out.moved.append(file)
            } catch { out.spared.append(file) }
        }
        if !out.moved.isEmpty { out.at = box.path } else { try? fm.removeItem(at: box); try? fm.removeItem(at: Self.mark(box)) }
        return out
    }

    /// M7.2 (A6): `src`'s folder, symlinks resolved, is `root`'s real folder or inside it (`src` itself is not
    /// resolved: a symlink the gate left is moved as a link).
    /// ponytail: a swap between this check and the `rename` still wins; only an `openat` walk would close it
    static func inside(_ src: URL, _ root: URL) -> Bool {
        let real = root.resolvingSymlinksInPath().path, parent = src.deletingLastPathComponent().resolvingSymlinksInPath().path
        return parent == real || parent.hasPrefix(real + "/")
    }

    /// M7.2: box `<root>/<n>`'s mark, `<root>/<n>.work`: the id of the work whose loop made it.
    static func mark(_ box: URL) -> URL { box.deletingLastPathComponent().appendingPathComponent(box.lastPathComponent + ".work") }

    /// M6.3: a gate's file name the integrator may move: relative, inside the tree, not git's, no backslash.
    static func touchable(_ file: String) -> Bool {
        let parts = file.split(separator: "/", omittingEmptySubsequences: false)
        return !file.isEmpty && !file.hasPrefix("/") && !file.contains("\\")
            && !parts.contains { $0 == ".." || $0 == "." || $0.isEmpty || $0.lowercased() == ".git" }
    }

    /// M6.3: `<gitdir>/collie-gate-leftovers`, the worktree's own (nil when git cannot say).
    private func quarantineRoot() async -> URL? {
        guard let g = await out(["rev-parse", "--absolute-git-dir"]), !g.isEmpty else { return nil }
        return URL(fileURLWithPath: g).appendingPathComponent(Self.quarantineDir)
    }

    /// M6.3: a new, empty `<root>/<n>` for one sweep (the lowest free n).
    private func newQuarantine() async -> URL? {
        guard let root = await quarantineRoot() else { return nil }
        var n = 1
        while FileManager.default.fileExists(atPath: root.appendingPathComponent("\(n)").path) { n += 1 }
        let box = root.appendingPathComponent("\(n)")
        do { try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true) } catch { return nil }
        if let work { try? Data(work.uuidString.lowercased().utf8).write(to: Self.mark(box)) }
        return box
    }

    /// M6.3: the loop's start empties what the last loop quarantined. M7.2 (A2): only the boxes this loop's work made
    /// (their mark); another work's, maybe of a loop still running, and an unmarked one are never touched.
    /// ponytail: a work that never runs again leaves its boxes; the owner removes them (they are named in its notes)
    func clearQuarantine() async {
        quarantined = (0, 0)
        guard let work, let root = await quarantineRoot() else { return }
        let fm = FileManager.default, me = work.uuidString.lowercased()
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where !name.hasSuffix(".work") {
            let box = root.appendingPathComponent(name)
            guard (try? String(contentsOf: Self.mark(box), encoding: .utf8)) == me else { continue }
            try? fm.removeItem(at: box); try? fm.removeItem(at: Self.mark(box))
        }
        if ((try? fm.contentsOfDirectory(atPath: root.path)) ?? ["?"]).isEmpty { try? fm.removeItem(at: root) }
    }

    /// The contents' hashes of `files`, in order (nil when git cannot say for every one).
    private func hashes(_ files: [String]) async -> [String]? {
        guard let o = await out(["--literal-pathspecs", "hash-object", "--"] + files) else { return nil }
        let h = o.split(separator: "\n").map(String.init)
        return h.count == files.count ? h : nil
    }

    /// Untracked files that the lane's branch adds or changes since `sha`: the ones a merge refuses to overwrite.
    private func inTheWay(_ branch: String, from sha: String) async -> [String] {
        guard let d = await raw(["--literal-pathspecs", "diff", "--name-only", "-z", sha + "..." + branch, "--"]) else { return [] }
        let theirs = Set(d.split(separator: "\0").map(String.init))
        return await untracked().filter(theirs.contains)
    }

    /// Tracked files that differ from `sha`. A diff git cannot give counts as one.
    private func trackedChanges(since sha: String) async -> [String] {
        (await raw(["--literal-pathspecs", "diff", "--name-only", "-z", sha, "--"]))?.split(separator: "\0").map(String.init) ?? ["?"]
    }

    /// Untracked files not in `loose` (not there before the merge).
    private func made(_ loose: Set<String>) async -> [String] { await untracked().filter { !loose.contains($0) } }

    private func untracked() async -> [String] {
        (await raw(["--literal-pathspecs", "ls-files", "-z", "--others", "--exclude-standard"]) ?? "").split(separator: "\0").map(String.init)
    }

    private func out(_ args: [String]) async -> String? {
        (await raw(args))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// M6.3: git's stdout as is (a `-z` listing: a name may start or end with a space or a newline).
    private func raw(_ args: [String]) async -> String? {
        guard let r = try? await host.git(args, in: dir), r.status == 0 else { return nil }
        return r.stdout
    }

    /// Git's first non-empty line, treated like the notes' text (ANSI, control characters, secrets, length).
    private static func firstLine(_ s: String) -> String {
        WorkLoop.eventDetail(s.split(separator: "\n").first { !$0.allSatisfy(\.isWhitespace) }.map(String.init) ?? "git merge failed")
    }
}
