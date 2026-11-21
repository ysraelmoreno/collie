import Testing
import Foundation
import CollieProtocol
@testable import CollieDaemonKit

private func git(_ dir: URL, _ args: String...) async throws -> String {
    let r = try await GitRunner.run(args, in: dir)
    #expect(r.status == 0, "git \(args): \(r.stderr)")
    return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

private func hasBranch(_ b: String, _ repo: URL) async throws -> Bool {
    try await GitRunner.run(["show-ref", "--verify", "--quiet", "refs/heads/\(b)"], in: repo).status == 0
}

/// M3.2: the lane's worktree, in temporary git repositories, with git through the host (`LoopFakeHost.git`).
@Suite struct LaneWorktreeTests {
    @Test func createCutsFromTheShaIntoThePaddocksFolder() async throws {
        let repo = try await makeRepo(), host = LoopFakeHost(dir: repo)
        let first = try await git(repo, "rev-parse", "HEAD")
        try await commit("later.txt", "two\n", in: repo)
        let work = UUID()
        let lane = try await LaneWorktree.create(repoRoot: repo, base: first, work: work, task: "M3.2", host: host)
        let w8 = String(work.uuidString.lowercased().prefix(8))
        #expect(lane.branch == "collie/lane/\(w8)-M3.2")
        #expect(lane.path.path == repo.appendingPathComponent(".collie/paddocks/lane-\(w8)-M3.2").path)
        #expect(lane.base == first)
        #expect(exists(lane.path.appendingPathComponent("f.txt")))
        #expect(!exists(lane.path.appendingPathComponent("later.txt")), "cut from the sha, not from HEAD")
        #expect(try await git(lane.path, "rev-parse", "HEAD") == first)
        #expect(try await git(lane.path, "symbolic-ref", "--short", "HEAD") == lane.branch)
        #expect(!(await host.gits).isEmpty, "git ran through the host")
    }

    @Test func laneIsNotAChangeInTheMainTree() async throws {
        let repo = try await makeRepo(), host = LoopFakeHost(dir: repo)
        let sha = try await git(repo, "rev-parse", "HEAD")
        _ = try await LaneWorktree.create(repoRoot: repo, base: sha, work: UUID(), task: "t", host: host)
        #expect(try await git(repo, "status", "--porcelain") == "")
    }

    @Test func secondCreateFailsAndKeepsTheFirst() async throws {
        let repo = try await makeRepo(), host = LoopFakeHost(dir: repo)
        let sha = try await git(repo, "rev-parse", "HEAD"), work = UUID()
        let lane = try await LaneWorktree.create(repoRoot: repo, base: sha, work: work, task: "t", host: host)
        try "mine\n".write(to: lane.path.appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8)
        await #expect(throws: ProtocolError.self) {
            _ = try await LaneWorktree.create(repoRoot: repo, base: sha, work: work, task: "t", host: host)
        }
        #expect(exists(lane.path.appendingPathComponent("wip.txt")))
        #expect(try await hasBranch(lane.branch, repo))
        #expect(try await git(lane.path, "rev-parse", "HEAD") == sha)
    }

    @Test func existingBranchOrPathAloneIsRefused() async throws {
        let repo = try await makeRepo(), host = LoopFakeHost(dir: repo)
        let sha = try await git(repo, "rev-parse", "HEAD"), work = UUID(), w8 = LaneWorktree.work8(work)
        try await commit("later.txt", "two\n", in: repo)
        let head = try await git(repo, "rev-parse", "HEAD")
        // only the branch exists
        _ = try await git(repo, "branch", "collie/lane/\(w8)-b", head)
        await #expect(throws: ProtocolError.self) {
            _ = try await LaneWorktree.create(repoRoot: repo, base: sha, work: work, task: "b", host: host)
        }
        #expect(try await git(repo, "rev-parse", "collie/lane/\(w8)-b") == head, "the branch was not moved")
        // only the path exists
        let dir = repo.appendingPathComponent(".collie/paddocks/lane-\(w8)-p")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "keep\n".write(to: dir.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)
        await #expect(throws: ProtocolError.self) {
            _ = try await LaneWorktree.create(repoRoot: repo, base: sha, work: work, task: "p", host: host)
        }
        #expect(exists(dir.appendingPathComponent("keep.txt")))
        #expect(!(try await hasBranch("collie/lane/\(w8)-p", repo)))
    }

    @Test func invalidTaskOrBaseIsRefusedBeforeGit() async throws {
        let repo = try await makeRepo(), host = LoopFakeHost(dir: repo)
        let sha = try await git(repo, "rev-parse", "HEAD")
        for task in ["..", "a..b", "a/b", "/abs", "", String(repeating: "x", count: 41), "a b", "a\nb"] {
            await #expect(throws: ProtocolError.self, "task '\(task)'") {
                _ = try await LaneWorktree.create(repoRoot: repo, base: sha, work: UUID(), task: task, host: host)
            }
        }
        for base in ["", "main", "--detach", "HEAD"] {
            await #expect(throws: ProtocolError.self, "base '\(base)'") {
                _ = try await LaneWorktree.create(repoRoot: repo, base: base, work: UUID(), task: "t", host: host)
            }
        }
        #expect((await host.gits).isEmpty, "no git ran")
        #expect(!exists(repo.appendingPathComponent(".collie")))
        // the longest valid one passes
        _ = try await LaneWorktree.create(repoRoot: repo, base: sha, work: UUID(), task: String(repeating: "x", count: 40), host: host)
    }

    @Test func removeIsIdempotentAndDropsBranchAndFolder() async throws {
        let repo = try await makeRepo(), host = LoopFakeHost(dir: repo)
        let sha = try await git(repo, "rev-parse", "HEAD")
        let lane = try await LaneWorktree.create(repoRoot: repo, base: sha, work: UUID(), task: "t", host: host)
        // dirty and with an untracked file: a lane is thrown away whole
        try "x\n".write(to: lane.path.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try "y\n".write(to: lane.path.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try await LaneWorktree.remove(lane, host: host)
        #expect(!exists(lane.path))
        #expect(!(try await hasBranch(lane.branch, repo)))
        #expect(!(try await git(repo, "worktree", "list", "--porcelain")).contains("lane-"))
        try await LaneWorktree.remove(lane, host: host)   // twice: no error
        #expect(try await git(repo, "status", "--porcelain") == "")
    }

    @Test func removeDeletesAFolderGitNoLongerOwns() async throws {
        let repo = try await makeRepo(), host = LoopFakeHost(dir: repo)
        let sha = try await git(repo, "rev-parse", "HEAD")
        let lane = try await LaneWorktree.create(repoRoot: repo, base: sha, work: UUID(), task: "t", host: host)
        _ = try await git(repo, "worktree", "remove", "--force", lane.path.path)
        try FileManager.default.createDirectory(at: lane.path, withIntermediateDirectories: true)
        try "junk\n".write(to: lane.path.appendingPathComponent("junk.txt"), atomically: true, encoding: .utf8)
        try await LaneWorktree.remove(lane, host: host)
        #expect(!exists(lane.path))
        #expect(!(try await hasBranch(lane.branch, repo)))
    }

    @Test func removeRefusesWhatIsNotALane() async throws {
        let repo = try await makeRepo(), host = LoopFakeHost(dir: repo)
        let pad = repo.appendingPathComponent(".collie/paddocks/foo")
        _ = try await git(repo, "worktree", "add", "-b", "collie/foo", pad.path)
        await #expect(throws: ProtocolError.self) {
            try await LaneWorktree.remove(Lane(repoRoot: repo, path: pad, branch: "collie/foo", base: ""), host: host)
        }
        #expect(exists(pad.appendingPathComponent("f.txt")))
        #expect(try await hasBranch("collie/foo", repo))
    }

    @Test func orphansAndSweepTouchOnlyLanesOfInactiveWork() async throws {
        let repo = try await makeRepo(), host = LoopFakeHost(dir: repo)
        let sha = try await git(repo, "rev-parse", "HEAD")
        let active = UUID(), dead = UUID()
        let keep = try await LaneWorktree.create(repoRoot: repo, base: sha, work: active, task: "t1", host: host)
        let o1 = try await LaneWorktree.create(repoRoot: repo, base: sha, work: dead, task: "t1", host: host)
        let o2 = try await LaneWorktree.create(repoRoot: repo, base: sha, work: dead, task: "t-2", host: host)
        // a lane whose folder is already gone: only its branch is left
        let o3 = try await LaneWorktree.create(repoRoot: repo, base: sha, work: dead, task: "t3", host: host)
        _ = try await git(repo, "worktree", "remove", "--force", o3.path.path)
        // fake paddocks: one plain, one whose name starts with "lane-"; and a loose branch
        let pad = repo.appendingPathComponent(".collie/paddocks/foo"), pad2 = repo.appendingPathComponent(".collie/paddocks/lane-fake")
        _ = try await git(repo, "worktree", "add", "-b", "collie/foo", pad.path)
        _ = try await git(repo, "worktree", "add", "-b", "collie/lane-fake", pad2.path)
        _ = try await git(repo, "branch", "feature/collie/lane/x")

        let orphans = await LaneWorktree.orphans(repoRoot: repo, knownWork: [active], host: host)
        #expect(Set(orphans.map(\.branch)) == [o1.branch, o2.branch, o3.branch])
        #expect(Set(orphans.map(\.path.path)) == [o1.path.path, o2.path.path, o3.path.path])

        // M3b.5: o3's mark went with its worktree: its branch is spared, never `branch -D` without the mark
        let swept = await LaneWorktree.sweep(orphans, host: host)
        #expect(Set(swept.removed.map(\.branch)) == [o1.branch, o2.branch] && swept.spared.map(\.branch) == [o3.branch])
        for o in [o1, o2] {
            #expect(!exists(o.path))
            #expect(!(try await hasBranch(o.branch, repo)))
        }
        #expect(try await hasBranch(o3.branch, repo))
        #expect(exists(keep.path.appendingPathComponent("f.txt")))
        #expect(try await hasBranch(keep.branch, repo))
        for (p, b) in [(pad, "collie/foo"), (pad2, "collie/lane-fake")] {
            #expect(exists(p.appendingPathComponent("f.txt")))
            #expect(try await hasBranch(b, repo))
            #expect(try await git(p, "symbolic-ref", "--short", "HEAD") == b)
        }
        #expect(try await hasBranch("feature/collie/lane/x", repo))
        #expect(try await hasBranch("main", repo))
        let left = await LaneWorktree.orphans(repoRoot: repo, knownWork: [active], host: host)
        #expect(left.map(\.branch) == [o3.branch])
        #expect(await LaneWorktree.sweep(left, host: host).removed.isEmpty)
        #expect(try await git(repo, "status", "--porcelain") == "")
    }
}
