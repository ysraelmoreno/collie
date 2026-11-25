import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private extension CommandRouter {
    func fieldTestsAdd(_ p: Paddock) { ws.paddocks.append(p) }
    func fieldTestsInsert(_ t: TerminalRecord) { ws.terminals.append(t) }
    func fieldTestsRecord(_ name: String) -> TerminalRecord? { ws.terminals.first { $0.name == name } }
    func fieldTestsSetField(_ id: UUID, _ f: FieldRef?) {
        if let i = ws.terminals.firstIndex(where: { $0.id == id }) { ws.terminals[i].field = f }
    }
}

private func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

/// A daemon over a fake home, the paddock `p` of its repository on record, and a Shepherd S standing in it. S is a
/// record the router serves directly (no process): `sandbox-exec` does not nest inside an agent's own sandbox, and the
/// commands read only the record. `sandbox`: the daemon sandboxes terminals (`--field` exists only then; a summoned
/// agent's process may die at once here, its record stays); without it a field is cut by hand (`cut`), to land, drop
/// and dismiss through the paddock's own git.
private final class Rig {
    let f: FakeHome, paths: Paths, paddock: Paddock, ws = UUID()
    var d: Daemon
    var s: TerminalRecord!

    init(sandbox: Bool = true) async throws {
        f = try FakeHome(git: true, socket: false)
        paths = Paths(root: f.collie)
        var c = testConfig(paths, ws); if sandbox { c.sandboxHome = f.home }
        d = try Daemon(config: c)
        paddock = Paddock(id: UUID(), name: "p", repoRoot: f.repo.path, path: f.paddock.path, branch: "collie/p", baseBranch: "main")
        try await d.start()
        await d.router.fieldTestsAdd(paddock)
        s = await shepherd("S")
    }
    func stop() async { await d.stop() }

    func shepherd(_ name: String) async -> TerminalRecord {
        let path = SignedAppCheck.realPath(f.paddock)
        let t = TerminalRecord(id: UUID(), name: name, preset: .shell, command: nil, cwd: path, isShepherd: true, paddockId: paddock.id, projectRoot: path)
        await d.router.fieldTestsInsert(t)
        return t
    }
    func call(_ t: TerminalRecord, _ cmd: String, _ args: [String: JSONValue] = [:]) async -> Response {
        do { return Response(id: "m", ok: true, result: try await d.router.shepherd(Request(id: "m", terminalId: t.id.uuidString, command: cmd, args: args), from: t.id)) }
        catch let e as ProtocolError { return Response(id: "m", ok: false, error: e) }
        catch { return Response(id: "m", ok: false, error: ProtocolError(code: .internal, message: "\(error)")) }
    }
    /// S summons `name` running `/bin/cat` (an agent preset, never a shell), with `extra` (`--field` unless given).
    func summon(_ name: String, _ extra: [String: JSONValue] = ["field": .bool(true)]) async -> Response {
        var a: [String: JSONValue] = ["name": .string(name), "preset": .string("custom"), "command": .string("/bin/cat")]
        a.merge(extra) { $1 }
        return await call(s, "summon", a)
    }
    /// Without the sandbox: S summons `name` as always, then its field is cut by the daemon's git and put on its record.
    func cut(_ name: String) async throws -> TerminalRecord {
        let out = await summon(name, [:])
        #expect(out.ok, "\(out)")
        let rec = try #require(await rec(name))
        let base = try await head(f.paddock)
        let lane = try await LaneWorktree.createField(repoRoot: f.repo, base: base, name: name, owner: rec.id, host: await d.router.fieldGit(paddock))
        await d.router.fieldTestsSetField(rec.id, FieldRef(name: name, branch: lane.branch, base: base, path: SignedAppCheck.realPath(lane.path)))
        return rec
    }
    func rec(_ name: String) async -> TerminalRecord? { await d.router.fieldTestsRecord(name) }
    func field(_ name: String) -> URL { f.repo.appendingPathComponent(".collie/paddocks/field-\(name)") }
    func hasBranch(_ b: String) async throws -> Bool {
        try await GitRunner.run(["show-ref", "--verify", "--quiet", "refs/heads/\(b)"], in: f.repo).status == 0
    }
    func head(_ dir: URL) async throws -> String {
        try await GitRunner.run(["rev-parse", "HEAD"], in: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func commit(_ file: String, _ text: String, in dir: URL) throws {
        try text.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try FakeHome.git(["add", "."], in: dir)
        try FakeHome.git(["commit", "-qm", file], in: dir)
    }
    func config(_ json: String, commit: Bool) throws {
        try json.write(to: f.paddock.appendingPathComponent("collie-work.json"), atomically: true, encoding: .utf8)
        if commit { try FakeHome.git(["add", "collie-work.json"], in: f.paddock); try FakeHome.git(["commit", "-qm", "cfg"], in: f.paddock) }
    }
}

/// Runs `body` on a fresh rig, always stopping its daemon.
private func withRig(sandbox: Bool = true, _ body: (Rig) async throws -> Void) async throws {
    let r = try await Rig(sandbox: sandbox)
    do { try await body(r) } catch { await r.stop(); throw error }
    await r.stop()
}

/// F4: `summon --field`, `field list|land|drop`, and the dismissal of a field's agent (spec "Comandos", "Dispensa").
@Suite(.serialized, .timeLimit(.minutes(5))) struct FieldCommandsTests {
    @Test func summonFieldCreatesAndLaunches() async throws {
        try await withRig { r in
            let out = await r.summon("bob")
            #expect(out.ok, "\(out)")
            let rec = try #require(await r.rec("bob"))
            let path = SignedAppCheck.realPath(r.field("bob"))
            #expect(rec.cwd == path && rec.projectRoot == path, "the agent's folder and project are the field")
            let base = try await r.head(r.f.paddock)
            #expect(rec.field == FieldRef(name: "bob", branch: "collie/field/bob", base: base, path: path))
            #expect(rec.startMode == .strict, "a field's agent is strict, as a lane's")
            let branch = try await r.hasBranch("collie/field/bob")
            #expect(exists(r.field("bob")) && branch)
            guard case .object(let o)? = out.result, case .object(let fo)? = o["field"] else { Issue.record("\(out)"); return }
            #expect(fo["branch"] == .string("collie/field/bob"))
            // the daemon comes back: the field with it, nothing removed
            await r.stop()
            var c = testConfig(r.paths, r.ws); c.sandboxHome = r.f.home
            r.d = try Daemon(config: c)
            try await r.d.start()
            let back = await r.rec("bob")
            #expect(back?.field?.path == path && exists(r.field("bob")))
        }
    }

    @Test func summonWithoutFlagUnchanged() async throws {
        try await withRig { r in
            #expect(await r.summon("bob", [:]).ok)
            let rec = try #require(await r.rec("bob"))
            #expect(rec.field == nil && rec.cwd == SignedAppCheck.realPath(r.f.paddock))
            #expect(!exists(r.field("bob")))
        }
    }

    @Test func defaultFromHeadConfig() async throws {
        try await withRig { r in
            let on = #"{"version": 1, "fields": {"default": true}}"#
            try r.config(on, commit: false)   // only in the tree: an agent's edit turns nothing on
            #expect(await r.summon("a", [:]).ok)
            let a = await r.rec("a")
            #expect(a?.field == nil && !exists(r.field("a")))
            try r.config(on, commit: true)
            #expect(await r.summon("b", [:]).ok)
            let b = await r.rec("b")
            #expect(b?.field?.name == "b" && exists(r.field("b")))
            // the default only where --field would be allowed: a shell still summons, with no field
            #expect(await r.call(r.s, "summon", ["name": .string("sh"), "preset": .string("shell")]).ok)
            #expect(await r.rec("sh")?.field == nil)
        }
    }

    @Test func noFieldOverrides() async throws {
        try await withRig { r in
            try r.config(#"{"version": 1, "fields": {"default": true}}"#, commit: true)
            #expect(await r.summon("bob", ["no-field": .bool(true)]).ok)
            let bob = await r.rec("bob")
            #expect(bob?.field == nil && !exists(r.field("bob")))
            let both = await r.summon("x", ["field": .bool(true), "no-field": .bool(true)])
            #expect(both.error?.message.contains("juntos") == true, "\(both)")
        }
    }

    @Test func maxReached() async throws {
        try await withRig { r in
            try r.config(#"{"version": 1, "fields": {"max": 1}}"#, commit: true)
            #expect(await r.summon("a").ok)
            let second = await r.summon("b")
            #expect(second.error?.code == .invalidArgs && second.error?.message.contains("1 de 1") == true, "\(second)")
            let b = await r.rec("b")
            #expect(b == nil && !exists(r.field("b")))
            // the other refusals, before anything is made
            for (args, why) in [(["field": JSONValue.bool(true), "preset": .string("shell")], "shell"),
                                (["field": .bool(true), "cwd": .string(r.f.paddock.path)], "--cwd"),
                                (["field": .bool(true), "shepherd": .bool(true)], "--shepherd")] {
                let out = await r.summon("c", args)
                #expect(out.error?.message.contains(why) == true, "\(out)")
            }
            let bad = await r.summon("Bad")
            #expect(bad.error?.message.contains("nome de field inválido") == true, "\(bad)")
            #expect(!exists(r.field("c")) && !exists(r.field("Bad")))
        }
    }

    @Test func refusedWithLaneLoop() async throws {
        try await withRig { r in
            let w = try await r.d.router.work.start(title: "lanes", terminal: r.s.id, paddockId: r.paddock.id, branch: nil)
            try await r.d.router.work.update(w.id) { $0.loop = WorkLoopState(state: .running, parallel: 2) }
            let out = await r.summon("bob")
            #expect(out.error?.message.contains("laço em faixas") == true, "\(out)")
            let branch = try await r.hasBranch("collie/field/bob")
            #expect(!exists(r.field("bob")) && !branch)
            // a loop without lanes lives beside fields
            try await r.d.router.work.update(w.id) { $0.loop = WorkLoopState(state: .running) }
            #expect(await r.summon("bob").ok)
        }
    }

    @Test func dismissKeepsBranchAndWritesWip() async throws {
        try await withRig(sandbox: false) { r in
            _ = try await r.cut("bob")
            let dir = r.field("bob")
            try "changed\n".write(to: dir.appendingPathComponent("README"), atomically: true, encoding: .utf8)
            try "brand new\n".write(to: dir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
            try "*.log\n".write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            try "ignored\n".write(to: dir.appendingPathComponent("junk.log"), atomically: true, encoding: .utf8)
            let out = await r.call(r.s, "dismiss", ["target": .string("bob")])
            #expect(out.ok, "\(out)")
            let gone = await r.rec("bob")
            #expect(gone == nil && !exists(dir), "the worktree went")
            #expect(try await r.hasBranch("collie/field/bob"), "the branch stays")
            let wip = r.f.collie.appendingPathComponent("fields/bob-wip.patch")
            let text = try String(contentsOf: wip, encoding: .utf8)
            #expect(text.contains("+changed") && text.contains("+brand new") && text.contains("+*.log"), "\(text)")
            #expect(!text.contains("junk.log"), "ignored files stay out")
            #expect(try FileManager.default.attributesOfItem(atPath: wip.path)[.posixPermissions] as? Int == 0o600)
            // the patch applies on the field's branch: nothing lost
            let check = try await GitRunner.run(["apply", "--check", wip.path], in: r.f.paddock)
            #expect(check.status == 0, "\(check.stderr)")
        }
    }

    @Test func dropRemovesBranchUnlessKeep() async throws {
        try await withRig(sandbox: false) { r in
            _ = try await r.cut("a")
            try r.commit("a.txt", "from a\n", in: r.field("a"))
            let kept = await r.call(r.s, "field.drop", ["name": .string("a"), "keep-branch": .bool(true)])
            #expect(kept.ok, "\(kept)")
            let a = await r.rec("a"), aBranch = try await r.hasBranch("collie/field/a")
            #expect(a == nil && !exists(r.field("a")) && aBranch)
            // its agent gone, the branch is still dropped by name
            let later = await r.call(r.s, "field.drop", ["name": .string("a")])
            let aLater = try await r.hasBranch("collie/field/a")
            #expect(later.ok && !aLater, "\(later)")

            _ = try await r.cut("b")
            try r.commit("b.txt", "from b\n", in: r.field("b"))
            let out = await r.call(r.s, "field.drop", ["name": .string("b")])
            #expect(out.ok, "\(out)")
            let b = await r.rec("b"), bBranch = try await r.hasBranch("collie/field/b")
            #expect(b == nil && !exists(r.field("b")) && !bBranch)
            let patch = r.f.collie.appendingPathComponent("fields/b-1.patch")
            #expect(try String(contentsOf: patch, encoding: .utf8).contains("+from b"))
            let none = await r.call(r.s, "field.drop", ["name": .string("b")])
            #expect(none.error?.code == .notFound, "\(none)")
        }
    }

    @Test func landDelegatesToIntegrator() async throws {
        try await withRig(sandbox: false) { r in
            _ = try await r.cut("bob")
            try r.commit("bob.txt", "from bob\n", in: r.field("bob"))
            let list = await r.call(r.s, "field.list")
            guard case .object(let lo)? = list.result, case .array(let rows)? = lo["fields"], case .object(let row)? = rows.first else { Issue.record("\(list)"); return }
            #expect(row["agent"] == .string("bob") && row["commits"] == .number(1) && row["state"] == .string("working"), "\(row)")
            let out = await r.call(r.s, "field.land", ["name": .string("bob")])
            guard case .object(let o)? = out.result else { Issue.record("\(out)"); return }
            let head = try await r.head(r.f.paddock)
            #expect(o["outcome"] == .string("landed") && o["sha"] == .string(head), "\(out)")
            #expect(exists(r.f.paddock.appendingPathComponent("bob.txt")), "merged into the paddock's branch")
            #expect(await r.rec("bob")?.field?.state == .landed)
        }
    }

    @Test func onlySummonerLands() async throws {
        try await withRig(sandbox: false) { r in
            _ = try await r.cut("bob")
            let other = await r.shepherd("T")
            for cmd in ["field.land", "field.drop"] {
                let out = await r.call(other, cmd, ["name": .string("bob")])
                #expect(out.error?.code == .notShepherd, "\(cmd): \(out)")
            }
            let branch = try await r.hasBranch("collie/field/bob")
            #expect(exists(r.field("bob")) && branch)
        }
    }

    /// F3 note (1): an agent in a field writes objects and its own `collie/field/<name>`, never another field's,
    /// a lane's or the paddock's; it reads neither the paddock's worktree nor another field.
    @Test func fieldProfileWritesOnlyItsOwnBranch() throws {
        let f = try FakeHome(git: true, socket: false)
        let paddocks = f.repo.appendingPathComponent(".collie/paddocks")
        let a = paddocks.appendingPathComponent("field-a"), b = paddocks.appendingPathComponent("field-b"), lane = paddocks.appendingPathComponent("lane-x")
        for (branch, path) in [("collie/field/a", a), ("collie/field/b", b), ("collie/lane/x", lane)] {
            try FakeHome.git(["worktree", "add", "-q", "-b", branch, path.path], in: f.repo)
        }
        var i = f.input(project: a)
        i.paddockWorktrees = []; i.lanePaddock = f.paddock
        let p = ProfileRules(SandboxProfile.render(i))
        let git = f.repo.appendingPathComponent(".git")
        for rel in ["objects/ab/cdef", "refs/heads/collie/field/a", "refs/heads/collie/field/a.lock", "logs/refs/heads/collie/field/a",
                    "worktrees/field-a/index", "worktrees/field-a/HEAD"] {
            #expect(p.writes(git.appendingPathComponent(rel)), "writes \(rel)")
        }
        for rel in ["refs/heads/main", "refs/heads/collie/p", "refs/heads/collie/field/b", "refs/heads/collie/lane/x", "packed-refs",
                    "worktrees/field-b/HEAD", "worktrees/field-a/gitdir", "worktrees/field-a/collie-lane", "config", "hooks/pre-commit"] {
            #expect(!p.writes(git.appendingPathComponent(rel)), "writes \(rel)")
        }
        #expect(p.writes(a.appendingPathComponent("x.swift")) && p.reads(a.appendingPathComponent("README")))
        for other in [b, lane, f.paddock] {
            #expect(!p.reads(other.appendingPathComponent("README")) && !p.writes(other.appendingPathComponent("x")), "\(other.lastPathComponent)")
        }
    }
}
