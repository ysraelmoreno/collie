import Foundation
import CollieProtocol

// M3.2. Reused, not reinvented (from `PaddockManager.create`/`delete`, the paddocks' own worktree code):
// - where a worktree lives: `<repoRoot>/<LegacyOrq.repoDirName>/paddocks/<name>` (the repository's root, never the
//   daemon root), kept out of the main tree's `git status` by the same `GitRunner.exclude("<dir>/paddocks/", …)`;
// - how it is born: refuse an existing path, refuse an existing branch (`show-ref --verify --quiet`), then
//   `git worktree add -b <branch> <path> <base>`;
// - how it dies: `git worktree remove --force`, `git worktree prune`, `git branch -D`.
// What differs: git runs through `LoopHost.git` (`loopGit`: the repo's own filters off, sandboxed when the daemon
// sandboxes), never a loose `Process`; and a lane is not a paddock (no record, no app, no status).

/// A lane: a temporary worktree of the loop, one per task running in parallel. `base` is the sha it was cut from
/// ("" for a lane found by `orphans`: git does not keep it, and an orphan is only ever removed).
struct Lane: Codable, Sendable, Equatable {
    var repoRoot: URL
    var path: URL
    var branch: String
    var base: String
}

enum LaneWorktree {
    /// Every lane's branch starts with this; nothing without it is ever removed here. A paddock's branch is
    /// `collie/<name>` with no second slash, so it never matches.
    static let branchPrefix = "collie/lane/"
    /// ponytail: a paddock may legally be named `lane-…`; then `create` refuses the taken path, it never overwrites.
    static let dirPrefix = "lane-"

    private static func fail(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }

    static func validate(task: String) throws(ProtocolError) {
        guard task.range(of: "^[A-Za-z0-9._-]{1,40}$", options: .regularExpression) != nil, !task.contains("..") else {
            throw fail("invalid lane task '\(task)' (use A-Z, a-z, 0-9, '.', '_', '-', max 40, no '..')")
        }
    }

    static func work8(_ work: UUID) -> String { String(work.uuidString.lowercased().prefix(8)) }

    private static func paddocksDir(_ repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent("\(LegacyOrq.repoDirName(repoRoot: repoRoot))/paddocks")
    }

    /// Git through the host, throwing with stderr on a non-zero exit.
    @discardableResult
    private static func git(_ args: [String], in dir: URL, _ host: some LoopHost) async throws(ProtocolError) -> String {
        let r = try await host.git(args, in: dir)
        guard r.status == 0, !r.truncated else {
            let msg = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw fail("git \(args.prefix(2).joined(separator: " ")) failed: \(msg)")
        }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasBranch(_ branch: String, in repoRoot: URL, _ host: some LoopHost) async throws(ProtocolError) -> Bool {
        try await host.git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repoRoot).status == 0
    }

    /// The repository's worktrees that sit on a branch: (path as git prints it, short branch name).
    private static func worktrees(_ repoRoot: URL, _ host: some LoopHost) async throws(ProtocolError) -> [(path: String, branch: String)] {
        var out: [(path: String, branch: String)] = [], path: String?
        for line in try await git(["worktree", "list", "--porcelain"], in: repoRoot, host).split(separator: "\n") {
            if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
            else if line.hasPrefix("branch refs/heads/"), let p = path { out.append((p, String(line.dropFirst(18)))) }
        }
        return out
    }

    /// A new worktree on the new branch `collie/lane/<work8>-<task>`, cut from the sha `base`. An existing branch or
    /// path is an error: nothing is ever overwritten.
    static func create(repoRoot: URL, base: String, work: UUID, task: String, host: some LoopHost) async throws(ProtocolError) -> Lane {
        try validate(task: task)
        guard base.range(of: "^[0-9a-f]{7,64}$", options: .regularExpression) != nil else { throw fail("lane base '\(base)' is not a commit sha") }
        let name = "\(work8(work))-\(task)", dir = paddocksDir(repoRoot)
        let path = dir.appendingPathComponent(dirPrefix + name), branch = branchPrefix + name
        // no lane is born outside the repository, even through a symlinked paddocks folder
        guard SignedAppCheck.realPath(dir).hasPrefix(SignedAppCheck.realPath(repoRoot) + "/") else {
            throw fail("lane folder \(dir.path) is outside the repository")
        }
        if FileManager.default.fileExists(atPath: path.path) { throw fail("lane path \(path.path) already exists") }
        if try await hasBranch(branch, in: repoRoot, host) { throw fail("branch \(branch) already exists") }
        let common = URL(fileURLWithPath: try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repoRoot, host))
        try GitRunner.exclude("\(LegacyOrq.repoDirName(repoRoot: repoRoot))/paddocks/", commonDir: common)
        try await git(["worktree", "add", "-b", branch, path.path, base], in: repoRoot, host)
        return Lane(repoRoot: repoRoot, path: path, branch: branch, base: base)
    }

    /// Removes the lane's worktree, its leftover directory and its branch. Idempotent: what is already gone is skipped.
    static func remove(_ lane: Lane, host: some LoopHost) async throws(ProtocolError) {
        guard lane.branch.hasPrefix(branchPrefix) else { throw fail("'\(lane.branch)' is not a lane branch") }
        let root = lane.repoRoot
        // by branch, not by path: a worktree on any other branch is never this lane's
        if let wt = try await worktrees(root, host).first(where: { $0.branch == lane.branch }) {
            try await git(["worktree", "remove", "--force", wt.path], in: root, host)
        }
        // what is left on disk: only a `lane-…` folder of the paddocks folder that no worktree owns
        let real = SignedAppCheck.realPath(lane.path)
        let ours = lane.path.lastPathComponent.hasPrefix(dirPrefix)
            && lane.path.deletingLastPathComponent().standardizedFileURL.path == paddocksDir(root).standardizedFileURL.path
        if ours, FileManager.default.fileExists(atPath: lane.path.path),
           !(try await worktrees(root, host)).contains(where: { SignedAppCheck.realPath(URL(fileURLWithPath: $0.path)) == real }) {
            do { try FileManager.default.removeItem(at: lane.path) } catch { throw fail("cannot delete lane folder \(lane.path.path): \(error)") }
        }
        try await git(["worktree", "prune"], in: root, host)
        if try await hasBranch(lane.branch, in: root, host) { try await git(["branch", "-D", lane.branch], in: root, host) }
    }

    /// The lanes (branches under `collie/lane/`) whose work is not in `knownWork`. Empty when git cannot answer.
    static func orphans(repoRoot: URL, knownWork: Set<UUID>, host: some LoopHost) async -> [Lane] {
        guard let refs = try? await git(["for-each-ref", "--format=%(refname:short)", "refs/heads/\(branchPrefix)"], in: repoRoot, host) else { return [] }
        let known = Set(knownWork.map(work8)), listed = (try? await worktrees(repoRoot, host)) ?? []
        return refs.split(separator: "\n").map(String.init).filter { $0.hasPrefix(branchPrefix) }.sorted().compactMap { branch in
            let name = branch.dropFirst(branchPrefix.count)
            if known.contains(String(name.prefix(8))) { return nil }
            let path = listed.first { $0.branch == branch }.map { URL(fileURLWithPath: $0.path) }
                ?? paddocksDir(repoRoot).appendingPathComponent(dirPrefix + name)
            return Lane(repoRoot: repoRoot, path: path, branch: branch, base: "")
        }
    }

    /// Removes every orphan lane (the daemon's start-up sweep, M3.6). Returns the ones removed.
    @discardableResult
    static func sweep(repoRoot: URL, active: Set<UUID>, host: some LoopHost) async -> [Lane] {
        var removed: [Lane] = []
        for lane in await orphans(repoRoot: repoRoot, knownWork: active, host: host) where (try? await remove(lane, host: host)) != nil {
            removed.append(lane)
        }
        return removed
    }
}
