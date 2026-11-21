import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

private func hasBranch(_ b: String, _ repo: URL) async throws -> Bool {
    try await GitRunner.run(["show-ref", "--verify", "--quiet", "refs/heads/\(b)"], in: repo).status == 0
}

private extension CommandRouter {
    func intentTestsAdd(_ p: Paddock) { ws.paddocks.append(p) }
}

/// Every lane git the host ran, with the profile it ran under.
private actor LaneGitLog {
    var calls: [(args: [String], profile: URL?)] = []
    func add(_ args: [String], _ profile: URL?) { calls.append((args, profile)) }
    func ran(_ verb: [String]) -> Bool { calls.contains { Array($0.args.prefix(verb.count)) == verb } }
}

/// A fake home whose daemon sandboxes terminals (the only mode that takes `--parallel`), the paddock `p` of its
/// repository on record, and the daemon's real host for a loop of `work` there, its lane git recorded.
private struct Rig {
    let f: FakeHome, d: Daemon, work = UUID(), paddock: Paddock, sha: String, log = LaneGitLog()
    let host: RouterLoopHost

    init() async throws {
        f = try FakeHome(git: true, socket: false)
        var c = testConfig(Paths(root: f.collie)); c.sandboxHome = f.home
        d = try Daemon(config: c)
        paddock = Paddock(id: UUID(), name: "p", repoRoot: f.repo.path, path: f.paddock.path, branch: "collie/p", baseBranch: "main")
        await d.router.intentTestsAdd(paddock)
        sha = try await GitRunner.run(["rev-parse", "HEAD"], in: f.paddock).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let log = log
        let recorded: LaneGit = { (args, dir, profile) async throws(ProtocolError) in
            await log.add(args, profile)
            return try await RouterLoopHost.loopGit(args, in: dir, profile: profile)
        }
        host = RouterLoopHost(router: d.router, starter: UUID(), root: f.collie, work: work, paddock: paddock.id, dir: f.paddock,
                              sandbox: (f.home, "/bin/zsh"), laneRunner: recorded)
    }

    func cut(_ task: String) async throws -> Lane {
        try await LaneWorktree.create(repoRoot: f.repo, base: sha, work: work, task: task, host: host)
    }
    func paddockProfile() async throws -> URL { try await d.router.prepareLoopSandbox(work, paddock: paddock) }
    func laneProfile(_ lane: Lane) async throws -> URL { try await d.router.prepareLoopSandbox(work, paddock: paddock, lane: lane) }
}

/// Where a git operation of the loop runs: the daemon's own git (no profile), the paddock's strict profile (the
/// loop's own), or a lane's.
private enum Runs { case daemon, paddock, lane }

/// One row of the intent table: an operation, the git that does it, what it writes, and where it must run.
private struct Intent {
    let op: String, git: [String], runs: Runs, writes: [URL]
}

/// A host with the sandbox on, as the loop sees it: `git` is the paddock's strict profile, which refuses what that
/// profile refuses (a lane's birth and removal: the bug of finding 1); `laneGit` is the daemon's own. Both recorded.
private actor StrictFake: LoopHost {
    nonisolated let dir: URL
    var strict: [[String]] = [], daemon: [[String]] = []
    init(dir: URL) { self.dir = dir }
    func git(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult {
        strict.append(args)
        if args.first == "worktree", ["add", "remove", "prune"].contains(args.dropFirst().first ?? "") {
            throw ProtocolError(code: .internal, message: "Operation not permitted (the paddock's profile)")
        }
        return try await GitRunner.run(args, in: dir)
    }
    func laneGit(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult {
        daemon.append(args)
        return try await GitRunner.run(args, in: dir)
    }
    func laneHost(_ lane: Lane) async throws(ProtocolError) -> any LoopHost { self }
    func summon(name: String, for work: Work, loop: WorkLoopState) async throws(ProtocolError) -> UUID { UUID() }
    func ask(_ terminal: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> AskResult.Source { .hook }
    func working(_ terminal: UUID) async -> Bool { false }
    func dismiss(_ terminal: UUID) async {}
    func othersWorking() async -> String? { nil }
    func starterAlive() async -> Bool { true }
    func check(_ command: String, in dir: URL, timeout: Duration) async throws(ProtocolError) -> ProcessResult {
        throw ProtocolError(code: .internal, message: "no check here")
    }
    func readSpec(_ path: String) async -> String? { nil }
    func exists(_ path: String, in dir: URL) async -> Bool { false }
    nonisolated func patchDir(_ work: UUID) -> URL { dir.appendingPathComponent(".patches") }
    nonisolated func now() -> Date { Date() }
}

/// M3b.1 (finding 1 of the wave 3 review): a lane is born and dies under the real profile. The paddock's strict
/// profile cannot write a sibling `lane-*` worktree nor `<common>/worktrees/lane-*`, so the lanes' own git is the
/// daemon's, outside it; what runs inside a lane stays under the lane's profile. Proved from the profiles' own rules
/// (`ProfileRules`): `sandbox-exec` does not nest inside an agent's sandbox, where the loop's check runs these.
@Suite(.serialized) struct LaneProfileIntentTests {
    /// The table: for each git operation of the parallel loop, what it writes and which profile it runs under.
    @Test func everyLaneOperationRunsWhereItsWritesAreAllowed() async throws {
        let r = try await Rig()
        let a = try await r.cut("a"), b = try await r.cut("b")
        let paddockFile = try await r.paddockProfile(), laneFile = try await r.laneProfile(a)
        let paddock = ProfileRules(try String(contentsOf: paddockFile, encoding: .utf8))
        let lane = ProfileRules(try String(contentsOf: laneFile, encoding: .utf8))
        let common = try #require(SandboxInput.gitDirs(of: r.f.paddock).common)
        let paddockGit = try #require(SandboxInput.gitDirs(of: r.f.paddock).worktree)
        let name = a.path.lastPathComponent, laneGit = common.appendingPathComponent("worktrees/\(name)")
        let laneRef = common.appendingPathComponent("refs/heads/\(a.branch)")
        // a lane that does not exist yet: what `worktree add` is about to write
        let next = a.path.deletingLastPathComponent().appendingPathComponent("lane-\(LaneWorktree.work8(r.work))-next")
        let nextGit = common.appendingPathComponent("worktrees/\(next.lastPathComponent)")

        let table: [Intent] = [
            Intent(op: "create a lane", git: ["worktree", "add"], runs: .daemon,
                   writes: [next, next.appendingPathComponent("README"), next.appendingPathComponent(".git"),
                            nextGit, nextGit.appendingPathComponent("HEAD"), nextGit.appendingPathComponent("gitdir")]),
            Intent(op: "remove a lane", git: ["worktree", "remove"], runs: .daemon,
                   writes: [a.path, a.path.appendingPathComponent("README"), a.path.appendingPathComponent(".git"),
                            laneGit, laneGit.appendingPathComponent("index")]),
            Intent(op: "prune", git: ["worktree", "prune"], runs: .daemon, writes: [laneGit, laneGit.appendingPathComponent("gitdir")]),
            Intent(op: "the integrator's merge and commit", git: ["merge"], runs: .paddock,
                   writes: [r.f.paddock.appendingPathComponent("README"), paddockGit.appendingPathComponent("index"),
                            paddockGit.appendingPathComponent("MERGE_HEAD"), common.appendingPathComponent("objects/ab/cdef"),
                            common.appendingPathComponent("refs/heads/collie/p"), common.appendingPathComponent("logs/refs/heads/collie/p")]),
            Intent(op: "the agent's git in its lane", git: ["commit"], runs: .lane,
                   writes: [a.path.appendingPathComponent("Sources/x.swift"), laneGit.appendingPathComponent("index"),
                            laneGit.appendingPathComponent("COMMIT_EDITMSG"), common.appendingPathComponent("objects/ab/cdef"), laneRef]),
        ]

        // removal and prune through the same host, so the log holds every lane verb
        try await LaneWorktree.remove(b, host: r.host)
        let calls = await r.log.calls
        let hostPaddock = try r.host.profile(), hostLane = try r.host.forLane(a).profile()
        for row in table {
            switch row.runs {
            case .daemon:
                // the old path failed: the paddock's strict profile writes none of what makes or removes a lane
                for u in row.writes {
                    #expect(!paddock.writes(u), "\(row.op): the paddock's profile writes \(u.path)")
                    // nor does another lane's profile: a lane's agent never makes or removes a lane
                    if !u.path.hasPrefix(a.path.path), !u.path.hasPrefix(laneGit.path) { #expect(!lane.writes(u), "\(row.op): a lane's profile writes \(u.path)") }
                }
                // the new path does not go through it: the daemon's git, no profile
                let mine = calls.filter { Array($0.args.prefix(row.git.count)) == row.git }
                #expect(!mine.isEmpty, "\(row.op): never ran through the lane git")
                #expect(mine.allSatisfy { $0.profile == nil }, "\(row.op): ran under a profile")
            case .paddock:
                for u in row.writes { #expect(paddock.writes(u), "\(row.op): the paddock's profile refuses \(u.path)") }
                #expect(hostPaddock == paddockFile, "\(row.op): the paddock's host runs git under the paddock's profile")
                #expect(!calls.contains { $0.args.first == row.git[0] }, "\(row.op): went through the lane git")
            case .lane:
                for u in row.writes { #expect(lane.writes(u), "\(row.op): the lane's profile refuses \(u.path)") }
                #expect(hostLane == laneFile && hostLane != paddockFile, "\(row.op): the lane's host runs git under the lane's profile")
                #expect(!calls.contains { $0.args.first == row.git[0] }, "\(row.op): went through the lane git")
            }
        }
        // every git `LaneWorktree` ran was the daemon's: none under a profile, though both profiles were there
        #expect(!calls.isEmpty && calls.allSatisfy { $0.profile == nil })
        // and the barrier that matters stays: the lane's profile is closed to the paddock's worktree and the other lanes
        #expect(!lane.writes(r.f.paddock.appendingPathComponent("x")) && !lane.writes(b.path.appendingPathComponent("x")))
    }

    /// Real git, no `sandbox-exec`: the daemon's host makes and removes a lane with no profile on disk at all. The
    /// loop's own git (`git`) refuses there (it never runs unsandboxed), which is the path the lanes no longer take.
    @Test func theDaemonsGitMakesAndRemovesALaneWithNoProfile() async throws {
        let r = try await Rig()
        #expect(!exists(SandboxLaunch.profileFile(r.work, root: r.f.collie)))
        #expect(throws: ProtocolError.self) { try r.host.profile() }
        let lane = try await r.cut("t1")
        #expect(exists(lane.path.appendingPathComponent("README")))
        #expect(LaneWorktree.ownsPath(lane.path, repoRoot: r.f.repo))
        let born = try await hasBranch(lane.branch, r.f.repo)
        #expect(born)
        let head = try await GitRunner.run(["symbolic-ref", "--short", "HEAD"], in: lane.path)
        #expect(head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == lane.branch)
        let common = try #require(SandboxInput.gitDirs(of: r.f.paddock).common)
        #expect(exists(common.appendingPathComponent("worktrees/\(lane.path.lastPathComponent)")))

        try await LaneWorktree.remove(lane, host: r.host)
        #expect(!exists(lane.path))
        #expect(!exists(common.appendingPathComponent("worktrees/\(lane.path.lastPathComponent)")))
        let left = try await hasBranch(lane.branch, r.f.repo)
        #expect(!left)
        for verb in [["worktree", "add"], ["worktree", "remove"], ["worktree", "prune"], ["branch", "-D"]] {
            let ran = await r.log.ran(verb)
            #expect(ran, "\(verb) did not run through the lane git")
        }
        let calls = await r.log.calls
        #expect(calls.allSatisfy { $0.profile == nil })
        #expect(!exists(SandboxLaunch.profileFile(r.work, root: r.f.collie)), "no profile was made to make or remove a lane")
        // the paddock's worktree and branch: untouched
        #expect(exists(r.f.paddock.appendingPathComponent("README")))
        let paddockBranch = try await hasBranch("collie/p", r.f.repo)
        #expect(paddockBranch)
    }

    /// The loop's end and the start sweep (`removeLanes`): the same git, with the sandbox on and no profile made.
    @Test func removeLanesNeedsNoProfile() async throws {
        let r = try await Rig()
        let w = try await r.d.router.work.start(title: "looping", terminal: UUID(), paddockId: r.paddock.id, branch: nil)
        try await r.d.router.work.update(w.id) { $0.loop = WorkLoopState(state: .running, attempt: 1, max: 9, tasks: ["a"], parallel: 2) }
        let lane = try await LaneWorktree.create(repoRoot: r.f.repo, base: r.sha, work: w.id, task: "a", host: r.host)
        #expect(exists(lane.path))
        let fresh = try #require(try await r.d.router.work.get(w.id))
        await r.d.router.removeLanes(of: fresh)
        #expect(!exists(lane.path))
        let left = try await hasBranch(lane.branch, r.f.repo)
        #expect(!left)
        #expect(!exists(SandboxLaunch.profileFile(w.id, root: r.f.collie)), "the sweep makes no profile: its git runs outside it")
        #expect(exists(r.f.paddock.appendingPathComponent("README")))
    }

    /// Regression (finding 1): with the sandbox on, `cut` makes the lane and `dropLane` removes it. The loop's own
    /// git (the paddock's profile) is asked only for HEAD; the worktree is the daemon's git's.
    @Test func cutMakesTheLaneWithTheSandboxOn() async throws {
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        let storeDir = URL(fileURLWithPath: "/tmp/collie-intent-\(UUID().uuidString.prefix(8))"); defer { try? FileManager.default.removeItem(at: storeDir) }
        let host = StrictFake(dir: repo), work = UUID()
        let loop = WorkLoop(store: WorkStore(dir: storeDir), host: host)
        let (lane, _) = try await loop.cut(work, "a", dir: repo, root: repo)
        #expect(exists(lane.path.appendingPathComponent("f.txt")))
        let born = try await hasBranch(lane.branch, repo)
        #expect(born)
        let strictAtCut = await host.strict, daemonAtCut = await host.daemon
        #expect(strictAtCut == [["rev-parse", "HEAD"]], "only HEAD is read under the paddock's profile")
        #expect(daemonAtCut.contains { $0.prefix(2) == ["worktree", "add"] })

        await loop.dropLane(lane)
        #expect(!exists(lane.path))
        let left = try await hasBranch(lane.branch, repo)
        #expect(!left)
        let strict = await host.strict, daemon = await host.daemon
        #expect(strict == [["rev-parse", "HEAD"]], "removal asks nothing of the paddock's profile")
        #expect(daemon.contains { $0.prefix(2) == ["worktree", "remove"] } && daemon.contains { $0.prefix(2) == ["worktree", "prune"] })
    }

    /// The daemon's git runs with `--force` and no profile: only on a lane's own folder in the paddocks folder.
    @Test func removeRefusesALaneWorktreeOutsideThePaddocksFolder() async throws {
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        let host = StrictFake(dir: repo)
        let sha = try await GitRunner.run(["rev-parse", "HEAD"], in: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let lane = try await LaneWorktree.create(repoRoot: repo, base: sha, work: UUID(), task: "a", host: host)
        let moved = repo.deletingLastPathComponent().appendingPathComponent("moved-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: moved) }
        let mv = try await GitRunner.run(["worktree", "move", lane.path.path, moved.path], in: repo)
        #expect(mv.status == 0, "\(mv.stderr)")
        #expect(!LaneWorktree.ownsPath(moved, repoRoot: repo) && LaneWorktree.ownsPath(lane.path, repoRoot: repo))
        await #expect(throws: ProtocolError.self) { try await LaneWorktree.remove(lane, host: host) }
        #expect(exists(moved.appendingPathComponent("f.txt")), "a worktree outside the paddocks folder is never force-removed")
        let swept = await LaneWorktree.sweep(await LaneWorktree.orphans(repoRoot: repo, knownWork: [], host: host), host: host)
        #expect(swept.removed.isEmpty && exists(moved.appendingPathComponent("f.txt")))
    }
}
