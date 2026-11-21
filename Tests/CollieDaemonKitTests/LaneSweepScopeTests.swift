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

private extension CommandRouter {
    func addSweepPaddock(_ repo: URL) -> UUID {
        let p = Paddock(id: UUID(), name: "feat", repoRoot: repo.path, path: repo.path, branch: "main", baseBranch: "main")
        ws.paddocks.append(p)
        return p.id
    }
}

/// M3b.5: a sweep removes only lanes this daemon marked (its install id in the lane's own git dir), and the loop's end
/// only its own work's. Another daemon's lanes, and the owner's own `collie/lane/…` branches and worktrees, stay.
@Suite(.serialized) struct LaneSweepScopeTests {
    /// The owner's worktree on a `collie/lane/x` branch, in the paddocks folder, with uncommitted work: no mark.
    private func ownersLane(_ repo: URL, _ name: String) async throws -> URL {
        let dir = repo.appendingPathComponent(".collie/paddocks/lane-\(name)")
        let r = try await GitRunner.run(["worktree", "add", "-b", "collie/lane/\(name)", dir.path], in: repo)
        #expect(r.status == 0, "\(r.stderr)")
        try "mine\n".write(to: dir.appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8)
        return dir
    }

    // (a) (d): the loop's end removes its own work's lanes, not another work's nor another daemon's
    @Test func theLoopsEndRemovesOnlyItsOwnWorksLanes() async throws {
        try await withDaemon { d, _ in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            let paddock = await d.router.addSweepPaddock(repo), sha = try await head(repo)
            let me = LoopFakeHost(dir: repo), them = LoopFakeHost(dir: repo)
            await me.setOwner(try await d.router.remoteInstallId())
            await them.setOwner("other-daemon")
            let w = try await d.router.work.start(title: "looping", terminal: UUID(), paddockId: paddock, branch: nil)
            let other = try await d.router.work.start(title: "another", terminal: UUID(), paddockId: paddock, branch: nil)
            try await d.router.work.update(w.id) { $0.loop = WorkLoopState(state: .stopped, attempt: 1, max: 9, tasks: ["a"], parallel: 2) }
            let mine = try await LaneWorktree.create(repoRoot: repo, base: sha, work: w.id, task: "a", host: me)
            let othersWork = try await LaneWorktree.create(repoRoot: repo, base: sha, work: other.id, task: "z", host: me)
            let otherDaemon = try await LaneWorktree.create(repoRoot: repo, base: sha, work: UUID(), task: "y", host: them)
            // the other daemon's lane of a work with the same short id as ours: still not ours
            let sameWork8 = try await LaneWorktree.create(repoRoot: repo, base: sha, work: w.id, task: "b", host: them)

            await d.router.loopEnded(w.id, starter: UUID(), paddock: paddock)
            #expect(!exists(mine.path))
            #expect(try await !hasBranch(mine.branch, repo))
            for l in [othersWork, otherDaemon, sameWork8] {
                #expect(exists(l.path.appendingPathComponent("f.txt")), "\(l.branch) was removed")
                #expect(try await hasBranch(l.branch, repo))
            }
            let notes = try #require(try await d.router.work.get(w.id)).notes.map(\.text)
            #expect(notes.contains { $0.contains(sameWork8.branch) }, "\(notes)")
        }
    }

    // (b): the owner's `collie/lane/…` worktree survives the loop's end and the start sweep, with a note
    @Test func anOwnersLaneBranchWithoutTheMarkSurvivesWithANote() async throws {
        try await withDaemon { d, _ in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            let paddock = await d.router.addSweepPaddock(repo)
            let w = try await d.router.work.start(title: "looping", terminal: UUID(), paddockId: paddock, branch: nil)
            try await d.router.work.update(w.id) { $0.loop = WorkLoopState(state: .stopped, attempt: 1, max: 9, tasks: ["a"], parallel: 2) }
            // one named like this work's lane, one like no work's
            let w8 = LaneWorktree.work8(w.id)
            let hand = try await ownersLane(repo, "\(w8)-hand"), loose = try await ownersLane(repo, "x")
            await d.router.loopEnded(w.id, starter: UUID(), paddock: paddock)
            await d.router.stopLoopsLeftRunning()
            for (dir, b) in [(hand, "collie/lane/\(w8)-hand"), (loose, "collie/lane/x")] {
                #expect(exists(dir.appendingPathComponent("wip.txt")), "the owner's uncommitted work in \(b) is gone")
                #expect(try await hasBranch(b, repo))
            }
            let notes = try #require(try await d.router.work.get(w.id)).notes.map(\.text)
            #expect(notes.contains { $0.contains("collie/lane/\(w8)-hand") && $0.contains("não removida") }, "\(notes)")
        }
    }

    // (c): at start, an orphan this daemon marked (work unknown) goes; another daemon's orphan stays
    @Test func theStartSweepRemovesOnlyThisDaemonsOrphans() async throws {
        try await withDaemon { d, _ in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            _ = await d.router.addSweepPaddock(repo)
            let sha = try await head(repo)
            let me = LoopFakeHost(dir: repo), them = LoopFakeHost(dir: repo)
            await me.setOwner(try await d.router.remoteInstallId())
            await them.setOwner("other-daemon")
            let mine = try await LaneWorktree.create(repoRoot: repo, base: sha, work: UUID(), task: "a", host: me)
            let theirs = try await LaneWorktree.create(repoRoot: repo, base: sha, work: UUID(), task: "a", host: them)
            await d.router.stopLoopsLeftRunning()
            #expect(!exists(mine.path))
            #expect(try await !hasBranch(mine.branch, repo))
            #expect(exists(theirs.path.appendingPathComponent("f.txt")))
            #expect(try await hasBranch(theirs.branch, repo))
        }
    }

    // (e): `worktree remove --force` and `branch -D` run only on a marked lane
    @Test func forceAndBranchDeleteRunOnlyWithTheMark() async throws {
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        let sha = try await head(repo)
        let host = LoopFakeHost(dir: repo), them = LoopFakeHost(dir: repo)
        await them.setOwner("other-daemon")
        let theirs = try await LaneWorktree.create(repoRoot: repo, base: sha, work: UUID(), task: "t", host: them)
        let loose = try await ownersLane(repo, "x")
        let mine = try await LaneWorktree.create(repoRoot: repo, base: sha, work: UUID(), task: "m", host: host)
        // the mark is in the lane's own git dir, as the daemon wrote it
        let common = URL(fileURLWithPath: try await GitRunner.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: repo)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        let admin = try #require(LaneWorktree.adminDir(of: mine.path, common: common))
        #expect(exists(admin.appendingPathComponent(LaneWorktree.markerName)))
        #expect(LaneWorktree.adminDir(of: loose, common: common).map { exists($0.appendingPathComponent(LaneWorktree.markerName)) } == false)

        let before = await host.gits.count
        let swept = await LaneWorktree.sweep(await LaneWorktree.orphans(repoRoot: repo, knownWork: [], host: host), host: host)
        #expect(swept.removed.map(\.branch) == [mine.branch])
        #expect(Set(swept.spared.map(\.branch)) == [theirs.branch, "collie/lane/x"])
        let ran = Array(await host.gits.dropFirst(before))
        let destructive = ran.filter { ($0.prefix(2) == ["worktree", "remove"]) || ($0.prefix(2) == ["branch", "-D"]) }
        let spared = [theirs.branch, "collie/lane/x", theirs.path.lastPathComponent, loose.lastPathComponent]
        #expect(!destructive.contains { args in args.contains { a in spared.contains { a.hasSuffix($0) } } }, "\(destructive)")
        #expect(destructive.contains { $0.prefix(2) == ["branch", "-D"] })
        #expect(exists(theirs.path.appendingPathComponent("f.txt")) && exists(loose.appendingPathComponent("wip.txt")))
        #expect(try await hasBranch(theirs.branch, repo))
        #expect(try await hasBranch("collie/lane/x", repo))
    }

    /// The lane cannot write its own mark (nor any lane's): its profile closes the file like `gitdir`, while the rest
    /// of its own git dir stays writable.
    @Test func theLaneProfileClosesTheMark() throws {
        let f = try FakeHome(git: true, socket: false)
        let lane = f.repo.appendingPathComponent(".collie/paddocks/" + LaneWorktree.dirPrefix + "a")
        try FakeHome.git(["worktree", "add", "-q", "-b", LaneWorktree.branchPrefix + "a", lane.path], in: f.repo)
        var i = f.input(project: lane)
        i.paddockWorktrees = []; i.lanePaddock = f.paddock
        let p = ProfileRules(SandboxProfile.render(i)), git = f.repo.appendingPathComponent(".git/worktrees")
        #expect(p.writes(git.appendingPathComponent("lane-a/index")))
        for rel in ["lane-a/" + LaneWorktree.markerName, "lane-a/gitdir", "lane-b/" + LaneWorktree.markerName] {
            #expect(!p.writes(git.appendingPathComponent(rel)), "writes \(rel)")
        }
    }
}
