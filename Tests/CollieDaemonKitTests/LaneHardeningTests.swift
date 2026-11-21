import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

private func hasBranch(_ b: String, _ repo: URL) async throws -> Bool {
    try await GitRunner.run(["show-ref", "--verify", "--quiet", "refs/heads/\(b)"], in: repo).status == 0
}

private func head(_ repo: URL) async throws -> String {
    try await GitRunner.run(["rev-parse", "HEAD"], in: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Every regular file under `dir` with its bytes.
private func snapshot(_ dir: URL) -> [String: Data] {
    var out: [String: Data] = [:]
    let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
    while let u = e?.nextObject() as? URL {
        if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out[u.path] = (try? Data(contentsOf: u)) ?? Data() }
    }
    return out
}

/// M3c.3 (findings 4, 5 and 6 of the 3b review): the lane's profile keeps its folders in place, `remove` never follows
/// a symlink in a lane's place, a cancelled gate's group dies even after its leader, the mark is the whole work id,
/// and a spared lane is noted once per daemon.
@Suite(.serialized) struct LaneHardeningTests {
    /// Finding 4: the lane's folder and its git dir in `<common>/worktrees` are never renamed nor deleted; what is in
    /// them, and what a commit writes, stays writable.
    @Test func theLaneProfileKeepsTheLaneAndItsGitDirInPlace() throws {
        let f = try FakeHome(git: true, socket: false)
        let lane = f.repo.appendingPathComponent(".collie/paddocks/lane-a")
        try FakeHome.git(["worktree", "add", "-q", "-b", LaneWorktree.branchPrefix + "a", lane.path], in: f.repo)
        var i = f.input(project: lane)
        i.paddockWorktrees = []; i.lanePaddock = f.paddock
        let common = f.repo.appendingPathComponent(".git"), admin = common.appendingPathComponent("worktrees/lane-a")
        #expect(i.worktreeGitDir?.path == admin.path)
        let p = ProfileRules(SandboxProfile.render(i))
        #expect(!p.writes(lane), "the lane's folder can be renamed or deleted")
        #expect(!p.writes(admin), "the lane's git dir can be renamed or deleted")
        for u in [lane.appendingPathComponent("new.txt"), lane.appendingPathComponent("src/deep/x.swift"),
                  admin.appendingPathComponent("index"), admin.appendingPathComponent("HEAD"), admin.appendingPathComponent("logs/HEAD")] {
            #expect(p.writes(u), "writes \(u.path)")
        }
        // the mark and the pointers stay closed as before
        for rel in ["gitdir", "commondir", "config.worktree", LaneWorktree.markerName] { #expect(!p.writes(admin.appendingPathComponent(rel)), "writes \(rel)") }
        // real git: a commit in the lane writes only what the profile opens, never the two folders themselves
        let before = snapshot(common).merging(snapshot(lane)) { a, _ in a }
        try "a\n".write(to: lane.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try FakeHome.git(["add", "."], in: lane)
        try FakeHome.git(["commit", "-qm", "in the lane"], in: lane)
        let after = snapshot(common).merging(snapshot(lane)) { a, _ in a }
        let wrote = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
        #expect(!wrote.isEmpty)
        for path in wrote { #expect(p.writes(URL(fileURLWithPath: path)), "the commit writes \(path)") }
        // a paddock's profile (no lane) gains no such rule
        let paddock = ProfileRules(SandboxProfile.render(f.input(paddockTerminal: true)))
        #expect(paddock.writes(f.paddock.appendingPathComponent("x.txt")))
    }

    /// Finding 4, scenario B: lane X's folder swapped for a symlink to lane Y (another work's). `ownsPath` and `remove`
    /// refuse X; Y keeps its files and branch; the sweep reports X as refused.
    @Test func aSymlinkInTheLanesPlaceIsNeverRemoved() async throws {
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        let host = LoopFakeHost(dir: repo), sha = try await head(repo)
        let wx = UUID(), wy = UUID()
        let x = try await LaneWorktree.create(repoRoot: repo, base: sha, work: wx, task: "x", host: host)
        let y = try await LaneWorktree.create(repoRoot: repo, base: sha, work: wy, task: "y", host: host)
        #expect(LaneWorktree.ownsPath(x.path, repoRoot: repo))
        try FileManager.default.removeItem(at: x.path)
        try FileManager.default.createSymbolicLink(at: x.path, withDestinationURL: y.path)
        #expect(!LaneWorktree.ownsPath(x.path, repoRoot: repo))
        #expect(LaneWorktree.ownsPath(y.path, repoRoot: repo))
        await #expect(throws: ProtocolError.self) { try await LaneWorktree.remove(x, host: host) }
        #expect(exists(y.path.appendingPathComponent("f.txt")), "lane Y's tree was removed through X's symlink")
        #expect(try await hasBranch(y.branch, repo))
        let swept = await LaneWorktree.sweep(await LaneWorktree.lanes(of: wx, repoRoot: repo, host: host), host: host) { $0 == wx }
        #expect(swept.removed.isEmpty && swept.refused.map(\.branch) == [x.branch])
        let yBranch = try await hasBranch(y.branch, repo)
        #expect(exists(y.path.appendingPathComponent("f.txt")) && yBranch)
        // Y itself still goes the normal way
        try await LaneWorktree.remove(y, host: host)
        #expect(!exists(y.path))
        try? FileManager.default.removeItem(at: x.path)
    }

    /// Finding 5: the gate's leader exits at once and leaves a child holding the pipes. A cancel after the leader is
    /// reaped still kills the group: the run ends well before its timeout.
    @Test func aChildThatOutlivesTheLeaderDiesOnCancel() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collie-pgid-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("pids")
        // the child holds stdout/stderr open forever; the leader says both pids (whole, by a rename), then exits
        let script = "tail -f /dev/null & echo \"$$ $!\" > \"$1.tmp\" && mv \"$1.tmp\" \"$1\"; exit 0"
        let run = Task {
            try await BoundedProcess.$killOnCancel.withValue(true) {
                try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), args: ["-c", script, "sh", file.path],
                                             in: dir, env: ["PATH": "/usr/bin:/bin"], timeout: .seconds(120))
            }
        }
        // no sleep: the test yields until the leader has written (a FIFO is closed to a sandboxed check)
        var line = ""
        while line.isEmpty { line = (try? String(contentsOf: file, encoding: .utf8)) ?? ""; await Task.yield() }
        let pids = line.split(whereSeparator: \.isWhitespace).compactMap { pid_t(String($0)) }
        #expect(pids.count == 2)
        guard pids.count == 2 else { run.cancel(); return }
        let (leader, child) = (pids[0], pids[1])
        // the leader is reaped (it leaves the daemon's live set then): only the child is left in the group
        while BoundedProcess.livePids().contains(leader) { await Task.yield() }
        #expect(kill(child, 0) == 0, "the child outlived the leader")
        let start = ContinuousClock.now
        run.cancel()
        let r = try await run.value
        #expect(ContinuousClock.now - start < .seconds(60), "the cancel waited for the timeout")
        #expect(r.status == 0)   // the leader's own exit
    }

    /// Finding 6: two works whose ids share their first 8 characters. Each one's lane is marked for it alone.
    @Test func theMarkIsTheWholeWorkId() async throws {
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        let host = LoopFakeHost(dir: repo), sha = try await head(repo)
        let a = try #require(UUID(uuidString: "12345678-0000-4000-8000-00000000000A"))
        let b = try #require(UUID(uuidString: "12345678-0000-4000-8000-00000000000B"))
        #expect(LaneWorktree.work8(a) == LaneWorktree.work8(b))
        let lane = try await LaneWorktree.create(repoRoot: repo, base: sha, work: a, task: "t", host: host)
        let common = URL(fileURLWithPath: try await GitRunner.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        let owner = await host.laneOwner()
        #expect(LaneWorktree.isMarked(lane, owner: owner, common: common) { $0 == a })
        #expect(!LaneWorktree.isMarked(lane, owner: owner, common: common) { $0 == b })
        // B's loop end finds A's lane by the short id, and spares it
        let byB = await LaneWorktree.sweep(await LaneWorktree.lanes(of: b, repoRoot: repo, host: host), host: host) { $0 == b }
        #expect(byB.removed.isEmpty && byB.spared.map(\.branch) == [lane.branch])
        #expect(exists(lane.path.appendingPathComponent("f.txt")))
        let byA = await LaneWorktree.sweep(await LaneWorktree.lanes(of: a, repoRoot: repo, host: host), host: host) { $0 == a }
        #expect(byA.removed.map(\.branch) == [lane.branch] && !exists(lane.path))
    }

    /// Finding 6: a lane spared (no mark) is noted once per daemon, not at every end of its work's loop.
    @Test func aSparedLaneIsNotedOnce() {
        let repo = URL(fileURLWithPath: "/tmp/collie-noted-\(UUID().uuidString)")
        let l1 = Lane(repoRoot: repo, path: repo.appendingPathComponent(".collie/paddocks/lane-x"), branch: "collie/lane/x", base: "")
        let l2 = Lane(repoRoot: repo, path: repo.appendingPathComponent(".collie/paddocks/lane-y"), branch: "collie/lane/y", base: "")
        let first = CommandRouter.sparedNote(LaneWorktree.Swept(spared: [l1]))
        #expect(first?.contains("collie/lane/x") == true)
        #expect(CommandRouter.sparedNote(LaneWorktree.Swept(spared: [l1])) == nil)
        // a new one is noted, alone
        let second = CommandRouter.sparedNote(LaneWorktree.Swept(spared: [l1], refused: [l2]))
        #expect(second?.contains("collie/lane/y") == true && second?.contains("collie/lane/x") == false)
        #expect(CommandRouter.sparedNote(LaneWorktree.Swept(spared: [l1], refused: [l2])) == nil)
        #expect(CommandRouter.sparedNote(LaneWorktree.Swept()) == nil)
    }
}
