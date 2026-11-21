import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Every regular file under `dir`, by path.
private func snapshot(_ dir: URL) -> [String: Data] {
    var out: [String: Data] = [:]
    let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
    while let u = e?.nextObject() as? URL {
        if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out[u.path] = (try? Data(contentsOf: u)) ?? Data() }
    }
    return out
}

/// A fake home with the paddock `p` and two lanes of its repository, `a` and `b`, as `LaneWorktree.create` makes them
/// (`<paddocks>/lane-<name>` on `collie/lane/<name>`).
private struct Rig {
    let f: FakeHome, a: URL, b: URL, common: URL

    init() throws {
        f = try FakeHome(git: true, socket: false)
        let paddocks = f.repo.appendingPathComponent(".collie/paddocks")
        a = paddocks.appendingPathComponent(LaneWorktree.dirPrefix + "a")
        b = paddocks.appendingPathComponent(LaneWorktree.dirPrefix + "b")
        for (name, path) in [("a", a), ("b", b)] {
            try FakeHome.git(["worktree", "add", "-q", "-b", LaneWorktree.branchPrefix + name, path.path], in: f.repo)
        }
        common = f.repo.appendingPathComponent(".git")
    }

    func laneInput(_ lane: URL) -> SandboxInput {
        var i = f.input(project: lane)
        i.paddockWorktrees = []; i.lanePaddock = f.paddock
        return i
    }
    func laneRules(_ lane: URL) -> ProfileRules { ProfileRules(SandboxProfile.render(laneInput(lane))) }
    func git(_ rel: String) -> URL { common.appendingPathComponent(rel) }

    /// The files of the common dir that `body` created, changed or removed.
    func touched(by body: () throws -> Void) rethrows -> [String] {
        let before = snapshot(common)
        try body()
        let after = snapshot(common)
        return Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
    }
}

/// M3b.3 (finding 3 of the wave 3 review): a lane's profile writes its own branch and nothing else of the
/// repository's refs. Proved from the profile's rules (`ProfileRules`), with the paths taken from what real git writes.
@Suite(.serialized) struct LaneRefsProfileTests {
    @Test func laneWritesOnlyItsOwnBranchInTheCommonDir() throws {
        let r = try Rig()
        let p = r.laneRules(r.a)
        let open = ["objects/ab/cdef", "objects/pack/pack-1.pack", "refs/heads/collie/lane/a", "refs/heads/collie/lane/a.lock",
                    "logs/refs/heads/collie/lane/a", "worktrees/lane-a/index", "worktrees/lane-a/HEAD", "worktrees/lane-a/logs/HEAD",
                    "worktrees/lane-a/COMMIT_EDITMSG"]
        for rel in open { #expect(p.writes(r.git(rel)), "writes \(rel)") }
        let closed = ["refs/heads/main", "refs/heads/main.lock", "refs/heads/collie/p", "refs/heads/collie/p.lock",
                      "refs/heads/collie/lane/b", "refs/heads/collie/lane/b.lock", "refs/heads/collie/lane/a2",
                      "refs/heads/collie/lane/a/x", "refs/heads/collie/lane", "refs/heads/collie", "refs/heads", "refs",
                      "packed-refs", "packed-refs.lock", "logs", "logs/HEAD", "logs/refs/heads/main", "logs/refs/heads/collie/p",
                      "logs/refs/heads/collie/lane/b", "logs/refs/heads/collie/lane", "refs/stash", "logs/refs/stash",
                      "refs/tags/v1", "refs/remotes/origin/main", "hooks", "hooks/pre-commit", "config", "HEAD", "index",
                      "worktrees/lane-b/index", "worktrees/lane-b/HEAD", "worktrees/p/HEAD", "worktrees/lane-a/gitdir",
                      "worktrees/lane-a/commondir"]
        for rel in closed { #expect(!p.writes(r.git(rel)), "writes \(rel)") }
        // what git needs to read stays readable: every branch's commits are in the one object store
        for rel in ["packed-refs", "refs/heads/main", "refs/heads/collie/p", "objects/ab/cdef", "config", "HEAD"] {
            #expect(p.reads(r.git(rel)), "reads \(rel)")
        }
        // lane B's profile is the mirror
        let pb = r.laneRules(r.b)
        #expect(pb.writes(r.git("refs/heads/collie/lane/b")) && !pb.writes(r.git("refs/heads/collie/lane/a")))
        #expect(pb.writes(r.git("logs/refs/heads/collie/lane/b")) && !pb.writes(r.git("logs/refs/heads/collie/lane/a")))
    }

    /// Neither the workspace's open mode nor a write grant over the whole repository opens the refs again.
    @Test func modeAndGrantOpenNoRef() throws {
        let r = try Rig()
        var i = r.laneInput(r.a)
        i.mode = .open
        i.grants = [SandboxGrant(path: r.f.repo.path, access: .write, scope: .terminal, owner: i.terminal, project: r.a.path, by: nil)]
        let p = ProfileRules(SandboxProfile.render(i))
        #expect(p.writes(r.git("refs/heads/collie/lane/a")))
        for rel in ["refs/heads/main", "refs/heads/collie/p", "refs/heads/collie/lane/b", "packed-refs", "logs/refs/heads/main", "logs/HEAD"] {
            #expect(!p.writes(r.git(rel)), "writes \(rel)")
        }
    }

    /// Real git in lane A: everything `add` and `commit` write in the common dir is a path the lane's profile writes.
    @Test func commitInTheLaneWritesOnlyWhatTheProfileOpens() throws {
        let r = try Rig()
        let p = r.laneRules(r.a)
        let wrote = try r.touched {
            try "a\n".write(to: r.a.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
            try FakeHome.git(["add", "."], in: r.a)
            try FakeHome.git(["commit", "-qm", "in the lane"], in: r.a)
        }
        #expect(wrote.contains(r.git("refs/heads/collie/lane/a").path), "the commit moved the lane's branch: \(wrote)")
        #expect(wrote.contains(r.git("logs/refs/heads/collie/lane/a").path), "and wrote its reflog: \(wrote)")
        #expect(wrote.contains { $0.hasPrefix(r.git("objects").path + "/") })
        for path in wrote { #expect(p.writes(URL(fileURLWithPath: path)), "the commit writes \(path)") }
        // the lock git takes on the branch (gone by now)
        #expect(p.writes(r.git("refs/heads/collie/lane/a.lock")))
        // a second commit, and a reset of the lane's own branch (what the loop's git does there): the same paths
        let again = try r.touched {
            try "b\n".write(to: r.a.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
            try FakeHome.git(["commit", "-qam", "again"], in: r.a)
            try FakeHome.git(["reset", "-q", "--hard", "HEAD~1"], in: r.a)
        }
        #expect(!again.isEmpty)
        for path in again { #expect(p.writes(URL(fileURLWithPath: path)), "commit and reset write \(path)") }
    }

    /// Real git in lane A moving what is not the lane's: every one of them writes a path the profile closes.
    @Test func movingAnotherRefWritesWhatTheProfileCloses() throws {
        let r = try Rig()
        let p = r.laneRules(r.a)
        func denied(_ paths: [String]) -> [String] { paths.filter { !p.writes(URL(fileURLWithPath: $0)) } }
        try "a\n".write(to: r.a.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        try FakeHome.git(["add", "."], in: r.a)
        try FakeHome.git(["commit", "-qm", "in the lane"], in: r.a)
        for ref in ["refs/heads/main", "refs/heads/collie/p", "refs/heads/collie/lane/b", "refs/heads/other"] {
            let wrote = try r.touched { try FakeHome.git(["update-ref", ref, "HEAD"], in: r.a) }
            #expect(denied(wrote).contains(r.git(ref).path), "update-ref \(ref) wrote \(wrote)")
        }
        let stash = try r.touched {
            try "wip\n".write(to: r.a.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
            try FakeHome.git(["stash"], in: r.a)
        }
        #expect(denied(stash).contains(r.git("refs/stash").path), "stash wrote \(stash)")
        let packed = try r.touched { try FakeHome.git(["pack-refs", "--all"], in: r.a) }
        #expect(denied(packed).contains(r.git("packed-refs").path), "pack-refs wrote \(packed)")
    }

    /// Regression by text: a paddock's profile (no lane) still opens `refs`, `logs` and `packed-refs` whole, in the
    /// rule it always did, and names no lane branch.
    @Test func paddockProfileIsTheSameAsBefore() throws {
        let r = try Rig()
        let i = r.f.input(paddockTerminal: true)
        let text = SandboxProfile.render(i)
        let c = r.common.path, w = r.git("worktrees/p").path
        let block = ["(subpath \"\(c)/objects\")", "(subpath \"\(c)/refs\")", "(subpath \"\(c)/logs\")", "(literal \"\(c)/packed-refs\")",
                     "(literal \"\(c)/packed-refs.lock\")", "(subpath \"\(w)\")"].joined(separator: "\n  ")
        #expect(text.contains(block), "\(text)")
        #expect(!text.contains(LaneWorktree.branchPrefix) && !text.contains(";; lane:"))
        let p = ProfileRules(text)
        for rel in ["refs/heads/collie/p", "refs/heads/main", "logs/HEAD", "packed-refs", "refs/stash", "worktrees/p/index"] {
            #expect(p.writes(r.git(rel)), "writes \(rel)")
        }
        #expect(!p.writes(r.git("hooks/pre-commit")) && !p.writes(r.git("config")))
        // a lane's profile differs from it in the rules of the common dir
        #expect(!SandboxProfile.render(r.laneInput(r.a)).contains("(subpath \"\(c)/refs\")"))
    }

    /// The lane's name comes from its folder: whatever is in it stays one literal path, never a pattern or a new rule.
    @Test(arguments: ["a.b", ".*", "a|main", "[a-z]+", "x\") (allow file-write*) (literal \"", "a\\", "(a)", "a$", "^a", "a b"])
    func laneNameWithSpecialCharactersOpensOnlyItself(name: String) throws {
        let r = try Rig()
        var i = r.laneInput(r.a)
        i.project = r.a.deletingLastPathComponent().appendingPathComponent(LaneWorktree.dirPrefix + name)
        let text = SandboxProfile.render(i)
        let p = ProfileRules(text)
        #expect(p.writes(r.git("refs/heads/collie/lane/" + name)) && p.writes(r.git("logs/refs/heads/collie/lane/" + name)))
        for rel in ["refs/heads/main", "refs/heads/collie/p", "refs/heads/collie/lane/a", "refs/heads/collie/lane/axb",
                    "refs/heads/collie/lane/b", "refs/heads/collie/lane/x", "packed-refs", "logs/refs/heads/main", "refs/stash", "config"] {
            #expect(!p.writes(r.git(rel)), "'\(name)' writes \(rel)")
        }
        #expect(!p.writes(r.f.home.appendingPathComponent("Documents/x")) && !p.writes(r.f.paddock.appendingPathComponent("x")))
        // no rule of the common dir's refs is a regex
        #expect(!text.split(separator: "\n").contains { $0.contains("(regex") && $0.contains("refs/heads") })
    }

    /// A lane profile over a folder that is no `lane-*` (never rendered by the daemon): no ref is opened at all.
    @Test func noLaneNameOpensNoRef() throws {
        let r = try Rig()
        var i = r.laneInput(r.a)
        for folder in ["plain", LaneWorktree.dirPrefix] {
            i.project = r.a.deletingLastPathComponent().appendingPathComponent(folder)
            let p = ProfileRules(SandboxProfile.render(i))
            for rel in ["refs/heads/collie/lane/a", "refs/heads/collie/lane/plain", "refs/heads/collie/lane", "refs/heads/collie/lane/",
                        "refs/heads/main", "packed-refs"] {
                #expect(!p.writes(r.git(rel)), "'\(folder)' writes \(rel)")
            }
            #expect(p.writes(r.git("objects/ab/cdef")))
        }
    }
}
