import Foundation
import CollieProtocol

// M3.2. Reused, not reinvented (from `PaddockManager.create`/`delete`, the paddocks' own worktree code):
// - where a worktree lives: `<repoRoot>/<LegacyOrq.repoDirName>/paddocks/<name>` (the repository's root, never the
//   daemon root), kept out of the main tree's `git status` by the same `GitRunner.exclude("<dir>/paddocks/", …)`;
// - how it is born: refuse an existing path, refuse an existing branch (`show-ref --verify --quiet`), then
//   `git worktree add -b <branch> <path> <base>`;
// - how it dies: `git worktree remove --force`, `git worktree prune`, `git branch -D`.
// What differs: git runs through `LoopHost.laneGit` (`loopGit`: the repo's own filters off), never a loose `Process`;
// and a lane is not a paddock (no record, no app, no status).
// M3b.1: like the paddocks' worktrees, a lane is made and removed by the daemon's own git, outside the loop's profile
// (the paddock's strict profile writes neither `<paddocks>/lane-*` nor `<common>/worktrees/lane-*`). So every path
// handed to git here is one this file built (`validate`d task, under the repository's paddocks folder) or checked
// (`ownsPath`); none comes from an agent or a task unchecked.

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

    /// M3.3: `path` has a lane's shape: a `lane-*` folder of a `paddocks` folder. By name only (no file is read): the
    /// same answer for a lane already removed.
    static func isLane(_ path: URL) -> Bool {
        path.lastPathComponent.hasPrefix(dirPrefix) && path.deletingLastPathComponent().lastPathComponent == "paddocks"
    }

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

    /// `path` is a `lane-*` folder directly in the repository's own paddocks folder (symlinks resolved).
    static func ownsPath(_ path: URL, repoRoot: URL) -> Bool {
        let real = URL(fileURLWithPath: SignedAppCheck.realPath(path))
        return real.lastPathComponent.hasPrefix(dirPrefix)
            && real.deletingLastPathComponent().path == SignedAppCheck.realPath(paddocksDir(repoRoot))
    }

    /// The daemon's git through the host (`laneGit`), throwing with stderr on a non-zero exit.
    @discardableResult
    private static func git(_ args: [String], in dir: URL, _ host: some LoopHost) async throws(ProtocolError) -> String {
        let r = try await host.laneGit(args, in: dir)
        guard r.status == 0, !r.truncated else {
            let msg = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw fail("git \(args.prefix(2).joined(separator: " ")) failed: \(msg)")
        }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasBranch(_ branch: String, in repoRoot: URL, _ host: some LoopHost) async throws(ProtocolError) -> Bool {
        try await host.laneGit(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repoRoot).status == 0
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
        let owner = await host.laneOwner()
        guard owner.range(of: "^[A-Za-z0-9._-]{1,64}$", options: .regularExpression) != nil else { throw fail("no daemon id to mark lane \(name) with") }
        try await git(["worktree", "add", "-b", branch, path.path, base], in: repoRoot, host)
        let lane = Lane(repoRoot: repoRoot, path: path, branch: branch, base: base)
        // M3b.5: the daemon's mark, before anything runs in the lane: without it, no sweep ever removes the lane
        do {
            guard let admin = adminDir(of: path, common: common) else { throw fail("git made no worktree dir for \(path.path)") }
            try Data("\(owner) \(work.uuidString.lowercased())\n".utf8).write(to: admin.appendingPathComponent(markerName))
        } catch {
            try? await remove(lane, host: host)
            throw fail("cannot mark lane \(name): \(error)")
        }
        return lane
    }

    /// M3b.5: the file in a lane's own git dir (`<common>/worktrees/<dir>/`) that says which daemon made it and for
    /// which work: "<owner> <work uuid>". Written only here, by the daemon; the lane's profile closes it like `gitdir`.
    static let markerName = "collie-lane"

    /// The git dir in `common/worktrees` whose `gitdir` points at `path/.git` (both closed to the lane), never what the
    /// lane's own `.git` file says (the lane writes that).
    static func adminDir(of path: URL, common: URL) -> URL? {
        let dir = common.appendingPathComponent("worktrees"), want = SignedAppCheck.realPath(path.appendingPathComponent(".git"))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().map { dir.appendingPathComponent($0) }.first { d in
            guard let s = try? String(contentsOf: d.appendingPathComponent("gitdir"), encoding: .utf8) else { return false }
            return SignedAppCheck.realPath(URL(fileURLWithPath: s.trimmingCharacters(in: .whitespacesAndNewlines))) == want
        }
    }

    /// The lane carries this daemon's mark (`owner`) for the work its branch names.
    static func isMarked(_ lane: Lane, owner: String, common: URL) -> Bool {
        guard let admin = adminDir(of: lane.path, common: common),
              let s = try? String(contentsOf: admin.appendingPathComponent(markerName), encoding: .utf8) else { return false }
        let f = s.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        let w8 = String(lane.branch.dropFirst(branchPrefix.count).prefix(8))
        return f.count == 2 && f[0] == owner && UUID(uuidString: f[1]).map(work8) == w8
    }

    /// Removes the lane's worktree, its leftover directory and its branch. Idempotent: what is already gone is skipped.
    /// M3b.5: only for a lane the caller made (the loop's own `dropLane`) or found marked (`sweep`): it checks no mark.
    static func remove(_ lane: Lane, host: some LoopHost) async throws(ProtocolError) {
        guard lane.branch.hasPrefix(branchPrefix) else { throw fail("'\(lane.branch)' is not a lane branch") }
        let root = lane.repoRoot
        // by branch, not by path: a worktree on any other branch is never this lane's
        if let wt = try await worktrees(root, host).first(where: { $0.branch == lane.branch }) {
            // M3b.1: this git runs outside any profile, with --force: never on a path that is not a lane's
            // (a lane's worktree moved elsewhere, or a gitdir pointer rewritten from inside the lane)
            guard ownsPath(URL(fileURLWithPath: wt.path), repoRoot: root) else { throw fail("lane worktree \(wt.path) is not in the paddocks folder") }
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

    /// The lanes (branches under `collie/lane/`) whose work's short id `pick` takes. Empty when git cannot answer.
    static func lanes(repoRoot: URL, host: some LoopHost, _ pick: (String) -> Bool) async -> [Lane] {
        guard let refs = try? await git(["for-each-ref", "--format=%(refname:short)", "refs/heads/\(branchPrefix)"], in: repoRoot, host) else { return [] }
        let listed = (try? await worktrees(repoRoot, host)) ?? []
        return refs.split(separator: "\n").map(String.init).filter { $0.hasPrefix(branchPrefix) }.sorted().compactMap { branch in
            let name = branch.dropFirst(branchPrefix.count)
            guard pick(String(name.prefix(8))) else { return nil }
            // the path `create` gave it (git prints the symlink-free one: /private/var for /var); git's only if it was moved
            var path = paddocksDir(repoRoot).appendingPathComponent(dirPrefix + name)
            if let wt = listed.first(where: { $0.branch == branch }).map({ URL(fileURLWithPath: $0.path) }),
               SignedAppCheck.realPath(wt) != SignedAppCheck.realPath(path) { path = wt }
            return Lane(repoRoot: repoRoot, path: path, branch: branch, base: "")
        }
    }

    /// The lanes whose work is not in `knownWork`.
    static func orphans(repoRoot: URL, knownWork: Set<UUID>, host: some LoopHost) async -> [Lane] {
        let known = Set(knownWork.map(work8))
        return await lanes(repoRoot: repoRoot, host: host) { !known.contains($0) }
    }

    /// The lanes of `work`.
    static func lanes(of work: UUID, repoRoot: URL, host: some LoopHost) async -> [Lane] {
        await lanes(repoRoot: repoRoot, host: host) { $0 == work8(work) }
    }

    /// What a sweep did: `removed`, and `spared` (no mark of this daemon: another daemon's, or the owner's own
    /// `collie/lane/…` branch or worktree; never touched, not even `branch -D`).
    struct Swept: Equatable { var removed: [Lane] = [], spared: [Lane] = [] }

    /// M3b.5: removes each of `lanes` (all of one repository) that this daemon marked (`isMarked`); the rest is spared.
    /// A marked lane git will not remove (moved out of the paddocks folder) is in neither list.
    static func sweep(_ lanes: [Lane], host: some LoopHost) async -> Swept {
        var out = Swept()
        guard let root = lanes.first?.repoRoot,
              let c = try? await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root, host) else { return out }
        let owner = await host.laneOwner(), common = URL(fileURLWithPath: c)
        for lane in lanes {
            guard !owner.isEmpty, isMarked(lane, owner: owner, common: common) else { out.spared.append(lane); continue }
            if (try? await remove(lane, host: host)) != nil { out.removed.append(lane) }
        }
        return out
    }
}
