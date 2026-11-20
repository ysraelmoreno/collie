import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Whether this process may apply a sandbox (inside an agent's sandboxed shell it may not: Seatbelt does not nest).
private let sandboxApplies: Bool = {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    p.arguments = ["-p", "(version 1)(allow default)", "/usr/bin/true"]
    p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
}()

/// A profile's file rules read as Seatbelt reads them: every rule in order, the last one that matches decides
/// (`(allow default)` first). Enough of SBPL for what `SandboxProfile.render` writes: `subpath`, `literal`, `regex`.
private struct ProfileRules {
    struct Rule { let allow: Bool, ops: [String], filters: [(kind: String, arg: String)], other: Bool }
    let rules: [Rule]

    /// `text` split on blanks outside strings and parentheses; with `forms`, only the top-level `( … )`, comments dropped.
    private static func split(_ text: String, forms: Bool) -> [String] {
        var out: [String] = [], cur = "", depth = 0, inStr = false, esc = false, comment = false
        func flush() { if !cur.isEmpty { out.append(cur); cur = "" } }
        for c in text {
            if comment { if c == "\n" { comment = false }; continue }
            if inStr {
                cur.append(c)
                if esc { esc = false } else if c == "\\" { esc = true } else if c == "\"" { inStr = false }
                continue
            }
            if c == ";" { comment = true; continue }
            if c == "\"" { inStr = true; cur.append(c); continue }
            if c == "(" { depth += 1; cur.append(c); continue }
            if c == ")" { depth -= 1; cur.append(c); if depth == 0 { flush() }; continue }
            if depth == 0, c.isWhitespace { if forms { cur = "" } else { flush() }; continue }
            cur.append(c)
        }
        if !forms { flush() }
        return out
    }
    private static func inner(_ form: String) -> [String] { split(String(form.dropFirst().dropLast()), forms: false) }
    private static func unquote(_ s: String) -> String {
        var out = "", esc = false
        for c in s.dropFirst().dropLast() { if esc { out.append(c); esc = false } else if c == "\\" { esc = true } else { out.append(c) } }
        return out
    }

    init(_ profile: String) {
        rules = Self.split(profile, forms: true).compactMap { form in
            let p = Self.inner(form)
            guard let verb = p.first, verb == "allow" || verb == "deny" else { return nil }
            var filters: [(kind: String, arg: String)] = [], other = false
            for f in p.dropFirst() where f.hasPrefix("(") {
                let q = Self.inner(f)
                if ["subpath", "literal", "regex"].contains(q[0]), q.count == 2 { filters.append((q[0], Self.unquote(q[1]))) }
                else if q[0] != "with" { other = true }   // a socket, a signal target: never a file path
            }
            return Rule(allow: verb == "allow", ops: p.dropFirst().filter { !$0.hasPrefix("(") }, filters: filters, other: other)
        }
    }

    /// `op` is `file-read*` or `file-write*`.
    func allows(_ op: String, _ path: String) -> Bool {
        var verdict = false
        for r in rules where r.ops.contains(op) || r.ops.contains("default") {
            let hit = r.filters.isEmpty ? !r.other : r.filters.contains { f in
                switch f.kind {
                case "subpath": return path == f.arg || path.hasPrefix(f.arg + "/")
                case "literal": return path == f.arg
                default: return path.range(of: f.arg, options: .regularExpression) != nil
                }
            }
            if hit { verdict = r.allow }
        }
        return verdict
    }
    func reads(_ u: URL) -> Bool { allows("file-read*", u.path) }
    func writes(_ u: URL) -> Bool { allows("file-write*", u.path) }
}

private extension CommandRouter {
    func laneTestsAdd(_ p: Paddock) { ws.paddocks.append(p) }
    func laneTestsProfile(_ rec: TerminalRecord) throws -> String { try String(contentsOf: prepareSandbox(rec), encoding: .utf8) }
}

/// A fake home with the paddock `p` of its repository, two lanes of one work (`a`, `b`) cut from the paddock's HEAD,
/// and a daemon (never started) that sandboxes terminals (`sandboxed`) or not.
private struct Rig {
    let f: FakeHome, d: Daemon, work = UUID(), starter = UUID(), paddock: Paddock, a: Lane, b: Lane
    let host: RouterLoopHost

    init(sandboxed: Bool = true) async throws {
        f = try FakeHome(git: true, socket: false)
        var c = testConfig(Paths(root: f.collie)); if sandboxed { c.sandboxHome = f.home }
        d = try Daemon(config: c)
        paddock = Paddock(id: UUID(), name: "p", repoRoot: f.repo.path, path: f.paddock.path, branch: "collie/p", baseBranch: "main")
        await d.router.laneTestsAdd(paddock)
        let sha = try await GitRunner.run(["rev-parse", "HEAD"], in: f.paddock).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let fake = LoopFakeHost(dir: f.repo)
        a = try await LaneWorktree.create(repoRoot: f.repo, base: sha, work: work, task: "a", host: fake)
        b = try await LaneWorktree.create(repoRoot: f.repo, base: sha, work: work, task: "b", host: fake)
        host = RouterLoopHost(router: d.router, starter: starter, root: f.collie, work: work, paddock: paddock.id, dir: f.paddock,
                              sandbox: sandboxed ? (f.home, "/bin/zsh") : nil)
    }

    func laneProfile(_ lane: Lane) async throws -> String {
        try String(contentsOf: try await d.router.prepareLoopSandbox(work, paddock: paddock, lane: lane), encoding: .utf8)
    }
    func term(_ name: String, _ cwd: URL, paddock pid: UUID? = nil, project: URL? = nil) -> TerminalRecord {
        TerminalRecord(id: UUID(), name: name, preset: .shell, command: nil, cwd: cwd.path, isShepherd: false,
                       paddockId: pid ?? paddock.id, projectRoot: project?.path)
    }
}

/// What a lane's profile must say, whoever rendered it: the lane open, its paddock's worktree and the other lanes
/// (one that does not exist yet too) closed for reading and writing.
private func expectLaneProfile(_ text: String, _ r: Rig, at: SourceLocation = #_sourceLocation) {
    let p = ProfileRules(text)
    #expect(p.reads(r.a.path.appendingPathComponent("README")) && p.writes(r.a.path.appendingPathComponent("new.txt")), sourceLocation: at)
    #expect(p.reads(r.a.path) && p.writes(r.a.path.appendingPathComponent("Sources/x.swift")), sourceLocation: at)
    let later = r.a.path.deletingLastPathComponent().appendingPathComponent("lane-later-c")
    for tree in [r.b.path, r.f.paddock, later] {
        for u in [tree, tree.appendingPathComponent("README"), tree.appendingPathComponent("deep/er/x")] {
            #expect(!p.reads(u), "reads \(u.path)", sourceLocation: at)
            #expect(!p.writes(u), "writes \(u.path)", sourceLocation: at)
        }
    }
    // the rest is the paddock's strict profile: reads open but secrets, writes closed outside the project, git pointers closed
    #expect(p.reads(r.f.other.appendingPathComponent("x")) && !p.writes(r.f.other.appendingPathComponent("x")), sourceLocation: at)
    #expect(!p.reads(r.f.home.appendingPathComponent(".ssh/id_ed25519")) && !p.writes(r.f.home.appendingPathComponent("Documents/x")), sourceLocation: at)
    #expect(!p.writes(r.a.path.appendingPathComponent(".git")) && !p.writes(r.a.path.appendingPathComponent("sub/.git/config")), sourceLocation: at)
    #expect(!p.reads(r.f.collie.appendingPathComponent("admin.token")), sourceLocation: at)
}

/// M3.3: a host per lane and the lane's own sandbox profile. The barrier is proved from the profile's own rules
/// (`ProfileRules`): `sandbox-exec` does not nest inside an agent's sandbox, where the loop's check runs these.
@Suite(.serialized) struct LaneHostTests {
    @Test func everyHostHasItsOwnDirPatchDirAndSandboxId() async throws {
        let r = try await Rig()
        let a = r.host.forLane(r.a), b = r.host.forLane(r.b)
        #expect(r.host.dir == r.f.paddock && a.dir == r.a.path && b.dir == r.b.path)
        #expect(r.host.lane == nil && a.lane == r.a && b.lane == r.b)
        // the paddock's host: where it always was
        let base = r.f.collie.appendingPathComponent("work-loops").appendingPathComponent(r.work.uuidString.lowercased())
        #expect(r.host.patchDir(r.work) == base)
        #expect(a.patchDir(r.work) == base.appendingPathComponent("lanes").appendingPathComponent(r.a.path.lastPathComponent))
        #expect(Set([r.host.patchDir(r.work), a.patchDir(r.work), b.patchDir(r.work)]).count == 3)
        #expect(r.host.sandboxId == r.work)
        #expect(Set([r.work, a.sandboxId, b.sandboxId]).count == 3)
        #expect(a.sandboxId == r.host.forLane(r.a).sandboxId, "found again from the work and the lane alone")
        #expect(a.sandboxId != CommandRouter.laneSandboxId(UUID(), r.a), "another work's lane of the same name: another id")
    }

    /// The host's `dir` is where its git, its check and its `exists` land: each lane's own tree and branch.
    @Test func gitCheckAndExistsLandInTheHostsLane() async throws {
        let r = try await Rig()
        let a = r.host.forLane(r.a), b = r.host.forLane(r.b)
        try "a\n".write(to: r.a.path.appendingPathComponent("only-a.txt"), atomically: true, encoding: .utf8)
        for (h, lane) in [(a, r.a), (b, r.b)] {
            let top = try await RouterLoopHost.loopGit(["rev-parse", "--show-toplevel"], in: h.dir, profile: nil)
            #expect(top.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == SignedAppCheck.realPath(lane.path))
            let br = try await RouterLoopHost.loopGit(["symbolic-ref", "--short", "HEAD"], in: h.dir, profile: nil)
            #expect(br.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == lane.branch)
            let pwd = try await RouterLoopHost.runCheck("pwd -P", in: h.dir, profile: nil, env: ["PATH": "/usr/bin:/bin"], timeout: .seconds(20))
            #expect(pwd.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == SignedAppCheck.realPath(lane.path))
        }
        let top = try await RouterLoopHost.loopGit(["symbolic-ref", "--short", "HEAD"], in: r.host.dir, profile: nil)
        #expect(top.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "collie/p")
        #expect(await a.exists("only-a.txt", in: a.dir))
        let inB = await b.exists("only-a.txt", in: b.dir), inPaddock = await r.host.exists("only-a.txt", in: r.host.dir)
        #expect(!inB && !inPaddock)
    }

    /// The loop's own profile for lane A (its git and its check).
    @Test func laneProfileIsClosedToThePaddockAndTheOtherLanes() async throws {
        let r = try await Rig()
        let text = try await r.laneProfile(r.a)
        expectLaneProfile(text, r)
        // under the lane's own id, next to (never over) the paddock's
        let a = r.host.forLane(r.a)
        #expect(FileManager.default.fileExists(atPath: SandboxLaunch.profileFile(a.sandboxId, root: r.f.collie).path))
        #expect(!FileManager.default.fileExists(atPath: SandboxLaunch.profileFile(r.work, root: r.f.collie).path))
        #expect(try a.profile() == SandboxLaunch.profileFile(a.sandboxId, root: r.f.collie))
        // and lane B's is the mirror: A closed, B open
        let pb = ProfileRules(try await r.laneProfile(r.b))
        #expect(pb.reads(r.b.path.appendingPathComponent("README")) && pb.writes(r.b.path.appendingPathComponent("x")))
        #expect(!pb.reads(r.a.path.appendingPathComponent("README")) && !pb.writes(r.a.path.appendingPathComponent("x")))
    }

    /// The lane's agent (its terminal's profile): the same barrier, from its record alone, and neither the workspace's
    /// open mode nor a write grant over the whole repository opens it.
    @Test func laneAgentProfileIsClosedWhateverTheModeOrAGrant() async throws {
        let r = try await Rig()
        let real = URL(fileURLWithPath: SignedAppCheck.realPath(r.a.path))
        let agent = r.term("loop-a", real, project: real)
        #expect(await r.d.router.lanePaddock(of: agent)?.path == r.f.paddock.path)
        expectLaneProfile(try await r.d.router.laneTestsProfile(agent), r)
        // a terminal of the paddock itself is no lane agent: its profile has no lane rule
        let own = r.term("dev", r.f.paddock, project: r.f.paddock)
        #expect(await r.d.router.lanePaddock(of: own) == nil)
        #expect(!(try await r.d.router.laneTestsProfile(own)).contains(";; lane:"))

        var i = r.f.input(project: real)
        i.paddockWorktrees = []; i.lanePaddock = r.f.paddock; i.mode = .open
        i.grants = [SandboxGrant(path: r.f.repo.path, access: .write, scope: .terminal, owner: i.terminal, project: real.path, by: nil)]
        expectLaneProfile(SandboxProfile.render(i), r)
    }

    /// A lane's host counts only the terminals that reach its lane.
    @Test func othersWorkingCountsOnlyWhatReachesTheLane() async throws {
        let r = try await Rig()
        let a = r.host.forLane(r.a)
        let starter = TerminalRecord(id: r.starter, name: "S", preset: .shell, command: nil, cwd: r.a.path.path, isShepherd: true, paddockId: r.paddock.id)
        let all = [starter, r.term("inB", r.b.path), r.term("inPaddock", r.f.paddock), r.term("inA", r.a.path.appendingPathComponent("Sources")),
                   r.term("stranger", r.a.path, paddock: UUID())]
        func reach(_ h: RouterLoopHost) -> [String] {
            CommandRouter.loopReaching(all, paddock: h.paddock, starter: h.starter, dir: h.dir).map(\.name)
        }
        #expect(reach(a) == ["inA"])
        #expect(reach(r.host.forLane(r.b)) == ["inB"])
        #expect(reach(r.host) == ["inPaddock"], "the paddock's host: as before, what is in its worktree")
        #expect(await a.othersWorking() == nil)
    }

    /// Regression: a host with no lane renders the profile `prepareLoopSandbox` always rendered, text for text.
    @Test func hostWithoutALaneRendersTheSameProfileAsBefore() async throws {
        let r = try await Rig()
        let text = try String(contentsOf: try await r.d.router.prepareLoopSandbox(r.work, paddock: r.paddock), encoding: .utf8)
        let project = r.f.paddock, git = SandboxInput.gitDirs(of: project)
        let before = SandboxInput(terminal: r.work, project: project, mainGitDir: git.common, worktreeGitDir: git.worktree,
                                  paddockWorktrees: await r.d.router.closedPaddocks(project), home: r.f.home, collieRoot: r.f.collie, ownFiles: [],
                                  terminalDir: SandboxLaunch.dir(r.work, root: r.f.collie), socket: Paths(root: r.f.collie).socket,
                                  agent: .shell, command: nil, grants: [], appBundle: SandboxInput.appBundle(of: URL(fileURLWithPath: "/tmp/collie")),
                                  mode: .strict)
        #expect(text == SandboxProfile.render(before))
        #expect(!text.contains(";; lane:"))
        #expect(try r.host.profile() == SandboxLaunch.profileFile(r.work, root: r.f.collie))
        // the paddock's profile reads its own lanes (they are its repository's); only a lane's is closed to the others
        #expect(ProfileRules(text).reads(r.a.path.appendingPathComponent("README")))
    }

    /// The daemon sandboxes no terminal: the paddock's host runs bare, as always; a lane's host refuses.
    @Test func laneHostRefusesWithoutTheSandbox() async throws {
        let r = try await Rig(sandboxed: false)
        let a = r.host.forLane(r.a)
        #expect(try r.host.profile() == nil)
        let bare = try await r.host.check("true", in: r.host.dir, timeout: .seconds(20))
        #expect(bare.status == 0)
        #expect(throws: ProtocolError.self) { try a.profile() }
        await #expect(throws: ProtocolError.self) { try await a.check("true", in: a.dir, timeout: .seconds(5)) }
        await #expect(throws: ProtocolError.self) { try await a.git(["status"], in: a.dir) }
        await #expect(throws: ProtocolError.self) { try await a.summon(name: "loop-a", for: Work(title: "W", terminalId: r.starter), loop: WorkLoopState()) }
        #expect(await !r.d.router.loopAgentSandboxed(UUID(), lane: r.a.path))
    }

    /// Sandboxed, with the paddock's profile there and the lane's not: the lane never borrows the paddock's.
    @Test func laneHostNeverFallsBackToThePaddocksProfile() async throws {
        let r = try await Rig()
        _ = try await r.d.router.prepareLoopSandbox(r.work, paddock: r.paddock)
        let a = r.host.forLane(r.a)
        #expect(try r.host.profile() != nil)
        #expect(throws: ProtocolError.self) { try a.profile() }
        await #expect(throws: ProtocolError.self) { try await a.check("true", in: a.dir, timeout: .seconds(5)) }
        await #expect(throws: ProtocolError.self) { try await a.git(["status"], in: a.dir) }
    }

    /// No profile is guessed for what is not a lane of the paddock's repository.
    @Test func onlyALaneOfThePaddocksRepositoryGetsALaneProfile() async throws {
        let r = try await Rig()
        let fm = FileManager.default
        let plain = r.f.repo.appendingPathComponent(".collie/paddocks/lane-plain")   // the name, but no worktree
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        let inside = r.f.paddock.appendingPathComponent("paddocks/lane-in")   // inside the paddock's worktree
        try fm.createDirectory(at: inside, withIntermediateDirectories: true)
        for path in [r.f.paddock, r.f.other, r.f.repo, plain, inside] {
            let lane = Lane(repoRoot: r.f.repo, path: path, branch: r.a.branch, base: "")
            await #expect(throws: ProtocolError.self, "\(path.path)") { _ = try await r.d.router.prepareLoopSandbox(r.work, paddock: r.paddock, lane: lane) }
        }
        #expect(!fm.fileExists(atPath: SandboxLaunch.profileFile(r.host.forLane(r.a).sandboxId, root: r.f.collie).path))
    }

    /// The real thing, where a sandbox can be applied: the check of lane A under its profile.
    @Test(.enabled(if: sandboxApplies, "sandbox-exec is refused here (a nested sandbox): run outside an agent's terminal"))
    func checkOfALaneRunsUnderTheLaneProfile() async throws {
        let r = try await Rig()
        _ = try await r.laneProfile(r.a)
        let a = r.host.forLane(r.a)
        func check(_ c: String) async throws -> Int32 { try await a.check(c, in: a.dir, timeout: .seconds(20)).status }
        #expect(try await check("echo x > in.txt && cat README") == 0)
        #expect(try await check("cat '\(r.f.paddock.path)/README'") != 0)
        #expect(try await check("cat '\(r.b.path.path)/README'") != 0)
        #expect(try await check("ls '\(r.b.path.path)'") != 0)
        #expect(try await check("echo x > '\(r.b.path.path)/x.txt'") != 0)
        #expect(try await check("echo x > '\(r.f.paddock.path)/x.txt'") != 0)
        #expect(!FileManager.default.fileExists(atPath: r.b.path.appendingPathComponent("x.txt").path))
        #expect(!FileManager.default.fileExists(atPath: r.f.paddock.appendingPathComponent("x.txt").path))
        let st = try await a.git(["status", "--porcelain"], in: a.dir)
        #expect(st.status == 0 && st.stdout.contains("in.txt"), "\(st.stderr)")
    }
}
