import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String }

/// A fake home in a temp dir (R2): `<home>/repo` (git, with `sub/` and `out` -> `<home>/other`), `<home>/other` (git).
private struct Tree {
    let home = URL(fileURLWithPath: SignedAppCheck.realPath(URL(fileURLWithPath: "/tmp/collie-sb-\(UUID().uuidString.prefix(8))")))
    var repo: URL { home.appendingPathComponent("repo") }
    var other: URL { home.appendingPathComponent("other") }
    init() throws {
        let fm = FileManager.default
        for d in [repo.appendingPathComponent("sub"), other] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        for d in [repo, other] { #expect(ProjectRootGit.initRepo(d)) }
        try fm.createSymbolicLink(at: repo.appendingPathComponent("out"), withDestinationURL: other)
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }
}

private enum ProjectRootGit {
    static func initRepo(_ d: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", d.path, "init", "-q"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit(); return p.terminationStatus == 0
    }
}

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue]) async throws -> Response {
    try await send(p, Request(id: "x", token: d.adminToken, command: "admin.\(cmd)", args: args), timeoutSeconds: 60)
}
private func spawnTerm(_ d: Daemon, _ p: Paths, _ name: String, cwd: String, shepherd: Bool = false, sandbox: String? = nil) async throws -> Term {
    var a: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string(cwd), "shepherd": .bool(shepherd)]
    if let sandbox { a["sandbox"] = .string(sandbox) }
    let r = try await admin(d, p, "spawn", a)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args), to: p.socket, timeoutSeconds: 120)
}
private func terminals(_ d: Daemon, _ p: Paths) async throws -> [TerminalRecord] {
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "ui.snapshot"))
    return try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(r.result)).terminals
}

@Suite(.serialized) struct SandboxRootsTests {
    @Test func defaultIsSandboxed() throws {
        let id = UUID()
        let old = #"{"id":"\#(id)","name":"a","preset":"shell","cwd":"/tmp","isShepherd":false}"#
        let t = try JSONDecoder().decode(TerminalRecord.self, from: Data(old.utf8))
        #expect(t.sandbox == .sandboxed && t.projectRoot == nil)
        let odd = #"{"id":"\#(id)","name":"a","preset":"shell","cwd":"/tmp","isShepherd":false,"sandbox":"off"}"#
        #expect(try JSONDecoder().decode(TerminalRecord.self, from: Data(odd.utf8)).sandbox == .sandboxed)   // fail closed
        var f = t; f.sandbox = .free; f.projectRoot = "/tmp"
        #expect(try JSONDecoder().decode(TerminalRecord.self, from: JSONEncoder().encode(f)) == f)
    }

    @Test func projectRootIsGitToplevel() throws {
        let tr = try Tree(); defer { tr.cleanup() }
        #expect(ProjectRoot.resolve(cwd: tr.repo.appendingPathComponent("sub").path, paddock: nil).path == tr.repo.path)
        let plain = tr.home.appendingPathComponent("plain dir é")   // not git, spaces and unicode
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(ProjectRoot.resolve(cwd: plain.path, paddock: nil).path == plain.path)
        let link = tr.home.appendingPathComponent("link")   // a project that is itself a symlink
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tr.repo)
        #expect(ProjectRoot.resolve(cwd: link.path, paddock: nil).path == tr.repo.path)
        #expect(ProjectRoot.resolve(cwd: tr.home.appendingPathComponent("gone/x").path, paddock: nil).path == tr.home.path + "/gone/x")
        #expect(ProjectRoot.contains(tr.repo.appendingPathComponent("sub/new").path, root: tr.repo))
        #expect(!ProjectRoot.contains(tr.home.path + "/repo2", root: tr.repo))   // components, not string prefix
        #expect(!ProjectRoot.contains(tr.repo.appendingPathComponent("out/x").path, root: tr.repo))   // symlink pointing out
        #expect(ProjectRoot.contains("/tmp/x", root: URL(fileURLWithPath: "/private/tmp")))
    }

    @Test func paddockRootIsWorktree() throws {
        let tr = try Tree(); defer { tr.cleanup() }
        let wt = tr.repo.appendingPathComponent(".collie/paddocks/p")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        let fl = Paddock(id: UUID(), name: "p", repoRoot: tr.repo.path, path: wt.path, branch: "collie/p", baseBranch: "main")
        #expect(ProjectRoot.resolve(cwd: tr.repo.path, paddock: fl).path == wt.path)
    }

    @Test func summonCwdOutsideProjectRefused() async throws {
        let tr = try Tree(); defer { tr.cleanup() }
        let wt = tr.repo.appendingPathComponent(".collie/paddocks/p")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        let paths = Paths(root: tr.home.appendingPathComponent("collie")), wsId = UUID(), mid = UUID()
        let fl = Paddock(id: UUID(), name: "p", repoRoot: tr.repo.path, path: wt.path, branch: "collie/p", baseBranch: "main")
        // a record from before the sandbox: no projectRoot, computed at first use
        let ws = Workspace(id: wsId, name: "default", terminals: [
            TerminalRecord(id: mid, name: "M", preset: .shell, command: nil, cwd: tr.repo.appendingPathComponent("sub").path, isShepherd: true)],
            paddocks: [fl])
        let file = paths.workspaceDir(wsId).appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ws).write(to: file)
        let d = try Daemon(config: testConfig(paths, wsId))
        try await d.start()
        do {
            #expect(try await admin(d, paths, "restart", ["name": .string("M")]).ok)
            let m = Term(id: mid.uuidString, token: try await tokenOf(d, mid.uuidString))
            for (i, bad) in [tr.home.path, "/", tr.other.path, tr.repo.appendingPathComponent("out").path].enumerated() {
                let r = try await call(paths, m, "summon", ["name": .string("W\(i)"), "preset": .string("shell"), "cwd": .string(bad)])
                #expect(r.error?.code == .invalidArgs && r.error?.message.contains("--cwd") == true
                        && r.error?.message.contains(tr.repo.path) == true, "\(bad): \(r)")
            }
            // a pasture terminal never lands in a paddock's worktree through --cwd
            let inPaddock = try await call(paths, m, "summon", ["name": .string("P"), "preset": .string("shell"), "cwd": .string(wt.path)])
            #expect(inPaddock.error?.message.contains("--paddock") == true, "\(inPaddock)")
            let ok = try await call(paths, m, "summon", ["name": .string("ok"), "preset": .string("shell"), "cwd": .string(tr.repo.path)])
            #expect(ok.ok, "\(ok)")
            let ts = try await terminals(d, paths)
            #expect(ts.map(\.name).sorted() == ["M", "ok"])
            #expect(ts.allSatisfy { $0.projectRoot == tr.repo.path && $0.sandbox == .sandboxed }, "\(ts)")
        } catch { await d.stop(); throw error }
        await d.stop()
    }

    @Test func herdCwdOutsideProjectRefused() async throws {
        let tr = try Tree(); defer { tr.cleanup() }
        let fx = try FakeAgents(); defer { fx.cleanup() }
        try await withDaemon(configure: fx.configure) { d, p in
            let m = try await spawnTerm(d, p, "M", cwd: tr.repo.appendingPathComponent("sub").path, shepherd: true)
            for bad in ["/", tr.other.path, tr.home.path] {
                let r = try await call(p, m, "herd.apply", ["id": .string("investigar-bug"), "name": .string("y"), "cwd": .string(bad)])
                #expect(r.error?.code == .invalidArgs, "\(bad): \(r)")
            }
            let free = try await call(p, m, "herd.apply", ["id": .string("investigar-bug"), "name": .string("y"), "sandbox": .string("free")])
            #expect(free.error?.code == .unauthorized, "\(free)")
            #expect(try await terminals(d, p).map(\.name) == ["M"])
            let r = try await call(p, m, "herd.apply", ["id": .string("investigar-bug"), "name": .string("x")])
            #expect(r.ok, "\(r)")
            let ts = try await terminals(d, p)
            #expect(ts.count == 3 && ts.allSatisfy { $0.projectRoot == tr.repo.path && $0.sandbox == .sandboxed }, "\(ts)")
        }
    }

    @Test func freeOnlyFromApp() async throws {
        try await withDaemon { d, p in
            let m = try await spawnTerm(d, p, "M", cwd: "/tmp", shepherd: true)
            for args: [String: JSONValue] in [["sandbox": .string("free")], ["free": .bool(true)], ["sandbox": .null]] {
                let r = try await call(p, m, "summon", args.merging(["name": .string("W"), "preset": .string("shell")]) { a, _ in a })
                #expect(r.error?.code == .unauthorized, "\(args): \(r)")
            }
            // a terminal's own token is no admin token
            let spawn = try await call(p, m, "admin.spawn", ["name": .string("F"), "preset": .string("shell"), "cwd": .string("/tmp"),
                                                            "sandbox": .string("free")])
            #expect(spawn.error?.code == .unauthorized, "\(spawn)")
            #expect(try await call(p, m, "summon", ["name": .string("W"), "preset": .string("shell")]).ok)
            #expect(try await admin(d, p, "spawn", ["name": .string("X"), "preset": .string("shell"), "sandbox": .string("off")]).error?.code == .invalidArgs)
            _ = try await spawnTerm(d, p, "F", cwd: "/tmp", sandbox: "free")
            let ts = try await terminals(d, p)
            #expect(Dictionary(uniqueKeysWithValues: ts.map { ($0.name, $0.sandbox) }) == ["M": .sandboxed, "W": .sandboxed, "F": .free])
            #expect(ts.first { $0.name == "F" }?.projectRoot == "/private/tmp")
        }
    }

    @Test func leashToFreeRefused() async throws {
        try await withDaemon { d, p in
            let m = try await spawnTerm(d, p, "M", cwd: "/tmp", shepherd: true)
            let f = try await spawnTerm(d, p, "F", cwd: "/tmp", sandbox: "free")
            #expect(try await call(p, m, "summon", ["name": .string("W"), "preset": .string("shell")]).ok)
            let app = try await admin(d, p, "leash", ["a": .string("M"), "b": .string("F")])
            #expect(app.error?.code == .notConnected, "\(app)")
            for (cmd, args) in [("leash", ["a": "W", "b": "F"]), ("ask", ["target": "F", "prompt": "hi"]), ("check", ["target": "F"]),
                                ("dismiss", ["target": "F"])] {
                let r = try await call(p, m, cmd, args.mapValues { .string($0) })
                #expect(r.error?.code == .notConnected, "\(cmd): \(r)")
            }
            // the free terminal reaches nobody either
            #expect(try await call(p, f, "ask", ["target": .string("M"), "prompt": .string("hi")]).error?.code == .notConnected)
            #expect(try await call(p, f, "list").result == .array([]))
            #expect(try await terminals(d, p).count == 3)
        }
    }

    @Test func freeSurvivesRestart() async throws {
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))")), wsId = UUID()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let d1 = try Daemon(config: testConfig(paths, wsId))
        try await d1.start()
        do {
            _ = try await spawnTerm(d1, paths, "F", cwd: "/tmp", sandbox: "free")
            _ = try await spawnTerm(d1, paths, "M", cwd: "/tmp", shepherd: true)
            #expect(try await admin(d1, paths, "spawn", ["name": .string("W"), "preset": .string("shell"), "cwd": .string("/tmp")]).ok)
            #expect(try await admin(d1, paths, "leash", ["a": .string("M"), "b": .string("W")]).ok)
        } catch { await d1.stop(); throw error }
        await d1.stop()
        let d2 = try Daemon(config: testConfig(paths, wsId))
        try await d2.start()
        do {
            #expect(try await admin(d2, paths, "restart", ["name": .string("F")]).ok)
            #expect(try await admin(d2, paths, "restart", ["name": .string("M")]).ok)
            let ts = try await terminals(d2, paths)
            #expect(ts.first { $0.name == "F" }?.sandbox == .free && ts.first { $0.name == "M" }?.sandbox == .sandboxed)
            #expect(try await admin(d2, paths, "leash", ["a": .string("M"), "b": .string("F")]).error?.code == .notConnected)
            // the stopped, leashed W relaunched free in place: its leashes go
            #expect(try await admin(d2, paths, "spawn", ["name": .string("W"), "preset": .string("shell"), "cwd": .string("/tmp"),
                                                         "sandbox": .string("free")]).ok)
            let r = try await send(paths, Request(id: "s", token: d2.adminToken, command: "ui.snapshot"))
            #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(r.result)).connections.isEmpty)
        } catch { await d2.stop(); throw error }
        await d2.stop()
    }

    // MARK: - fix round 1

    /// R9: a planted `core.worktree` must not widen the project (no git process is asked).
    @Test func plantedWorktreeDoesNotWiden() throws {
        let tr = try Tree(); defer { tr.cleanup() }
        let x = tr.repo.appendingPathComponent("x")
        try FileManager.default.createDirectory(at: x, withIntermediateDirectories: true)
        #expect(ProjectRootGit.initRepo(x))
        try "[core]\n\tworktree = \(tr.home.path)\n".write(to: x.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        #expect(ProjectRoot.resolve(cwd: x.appendingPathComponent("deep").path, paddock: nil).path == x.path)
        // a worktree's `.git` file counts too
        let wt = tr.home.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: wt.appendingPathComponent("a"), withIntermediateDirectories: true)
        try "gitdir: /nowhere\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(ProjectRoot.resolve(cwd: wt.appendingPathComponent("a").path, paddock: nil).path == wt.path)
    }

    /// R6: a free terminal is in no lot: join refused, old membership ignored and dropped on a free relaunch, no board `--to`.
    @Test func freeNeverInLot() async throws {
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))")), wsId = UUID()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let fid = UUID(), aid = UUID(), wid = UUID()
        var ws = Workspace(id: wsId, name: "default", terminals: [
            TerminalRecord(id: fid, name: "F", preset: .shell, command: nil, cwd: "/tmp", isShepherd: false, sandbox: .free),
            TerminalRecord(id: aid, name: "A", preset: .shell, command: nil, cwd: "/tmp", isShepherd: false),
            TerminalRecord(id: wid, name: "W", preset: .shell, command: nil, cwd: "/tmp", isShepherd: false)])
        ws.lots = [Lot(name: "l", members: [fid, aid, wid])]   // F's membership from before: ignored
        let file = paths.workspaceDir(wsId).appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ws).write(to: file)
        let d = try Daemon(config: testConfig(paths, wsId))
        try await d.start()
        do {
            for n in ["F", "A"] { #expect(try await admin(d, paths, "restart", ["name": .string(n)]).ok) }
            let f = Term(id: fid.uuidString, token: try await tokenOf(d, fid.uuidString))
            let a = Term(id: aid.uuidString, token: try await tokenOf(d, aid.uuidString))
            let post = try await call(paths, a, "lot.post", ["kind": .string("handoff"), "text": .string("run this"), "to": .string("F")])
            #expect(post.error?.code == .notFound, "\(post)")
            #expect(try await call(paths, f, "lot.get").error?.code == .notFound)
            #expect(try await call(paths, f, "lot.board").error?.code == .notFound)
            let join = try await send(paths, Request(id: "j", token: d.adminToken, command: "lot.join",
                                                     args: ["lot": .string("l"), "terminal": .string("F")]))
            #expect(join.error?.code == .invalidArgs, "\(join)")
            let create = try await send(paths, Request(id: "c", token: d.adminToken, command: "lot.create",
                                                       args: ["name": .string("m"), "members": .string("F")]))
            #expect(create.error?.code == .invalidArgs, "\(create)")
            // the stopped W relaunched free leaves its lot
            #expect(try await admin(d, paths, "spawn", ["name": .string("W"), "preset": .string("shell"), "cwd": .string("/tmp"),
                                                        "sandbox": .string("free")]).ok)
            let r = try await send(paths, Request(id: "s", token: d.adminToken, command: "ui.snapshot"))
            let lots = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(r.result)).lots
            #expect(lots.first { $0.name == "l" }.map { !$0.members.contains(wid) } == true, "\(lots)")
        } catch { await d.stop(); throw error }
        await d.stop()
    }

    /// I3: a free terminal holds no panel leash either.
    @Test func freeNoPanelLeash() async throws {
        try await withDaemon { d, p in
            let f = try await spawnTerm(d, p, "F", cwd: "/tmp", shepherd: true, sandbox: "free")
            for placement in ["canvas", "headless"] {
                let r = try await call(p, f, "panel.open", ["plugin": .string("browser"), "placement": .string(placement), "name": .string("b-\(placement)")])
                #expect(r.error?.code == .notConnected, "\(placement): \(r)")
            }
            let mv = try await call(p, f, "panel.open", ["plugin": .string("browser"), "placement": .string("dock.right"), "name": .string("mine")])
            #expect(mv.ok, "\(mv)")   // docked: no leash
            let r = try await call(p, f, "panel.move", ["name": .string("mine"), "placement": .string("canvas")])
            #expect(r.error?.code == .notConnected, "\(r)")
            let s = try await send(p, Request(id: "s", token: d.adminToken, command: "ui.snapshot"))
            #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(s.result)).connections.isEmpty)
        }
    }

    /// R8: a restart keeps the saved project; a paddock that is gone is refused, never widened to the pasture.
    @Test func restartKeepsRootAndRefusesGonePaddock() async throws {
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))")), wsId = UUID()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let gone = paths.root.appendingPathComponent(".collie/paddocks/gone").path
        let kept = paths.root.appendingPathComponent("kept")
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        let ws = Workspace(id: wsId, name: "default", terminals: [
            TerminalRecord(id: UUID(), name: "P", preset: .shell, command: nil, cwd: gone, isShepherd: false, paddockId: UUID(), projectRoot: gone),
            TerminalRecord(id: UUID(), name: "K", preset: .shell, command: nil, cwd: "/tmp", isShepherd: false, projectRoot: kept.path)])
        let file = paths.workspaceDir(wsId).appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ws).write(to: file)
        let d = try Daemon(config: testConfig(paths, wsId))
        try await d.start()
        do {
            let r = try await admin(d, paths, "restart", ["name": .string("P")])
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("não existe mais") == true, "\(r)")
            #expect(try await admin(d, paths, "restart", ["name": .string("K")]).ok)
            let ts = try await terminals(d, paths)
            #expect(ts.first { $0.name == "P" }?.projectRoot == gone && ts.first { $0.name == "P" }?.cwd == gone)
            #expect(ts.first { $0.name == "K" }?.projectRoot == kept.path)
        } catch { await d.stop(); throw error }
        await d.stop()
    }

    /// M1: the summoned terminal starts in the resolved cwd that was checked.
    @Test func summonSpawnsResolvedCwd() async throws {
        let tr = try Tree(); defer { tr.cleanup() }
        try FileManager.default.createSymbolicLink(at: tr.repo.appendingPathComponent("lnk"), withDestinationURL: tr.repo.appendingPathComponent("sub"))
        try await withDaemon { d, p in
            let m = try await spawnTerm(d, p, "M", cwd: tr.repo.path, shepherd: true)
            #expect(try await call(p, m, "summon", ["name": .string("W"), "preset": .string("shell"),
                                                    "cwd": .string(tr.repo.appendingPathComponent("lnk").path)]).ok)
            #expect(try await terminals(d, p).first { $0.name == "W" }?.cwd == tr.repo.appendingPathComponent("sub").path)
        }
    }

    /// M2 + M4: a free Shepherd's summon is refused before anything launches; rerail of a free terminal by a Shepherd misses it.
    @Test func freeShepherdAndRerail() async throws {
        try await withDaemon { d, p in
            let f = try await spawnTerm(d, p, "F", cwd: "/tmp", shepherd: true, sandbox: "free")
            let r = try await call(p, f, "summon", ["name": .string("W"), "preset": .string("shell")])
            #expect(r.error?.code == .notConnected && r.error?.message.contains("can't summon") == true, "\(r)")
            let h = try await call(p, f, "herd.apply", ["id": .string("investigar-bug"), "name": .string("x")])
            #expect(h.error?.code == .notConnected && h.error?.message.contains("can't summon") == true, "\(h)")
            let m = try await spawnTerm(d, p, "M", cwd: "/tmp", shepherd: true)
            #expect(try await call(p, m, "work.rerail", ["terminal": .string("F")]).error?.code == .notFound)
            #expect(try await terminals(d, p).map(\.name).sorted() == ["F", "M"])
        }
    }

    /// M5: a relaunch as free that fails keeps the old leashes.
    @Test func failedFreeRelaunchKeepsLeashes() async throws {
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))")), wsId = UUID()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let wid = UUID(), mid = UUID()
        var ws = Workspace(id: wsId, name: "default", terminals: [
            TerminalRecord(id: mid, name: "M", preset: .shell, command: nil, cwd: "/tmp", isShepherd: true),
            TerminalRecord(id: wid, name: "W", preset: .shell, command: nil, cwd: "/tmp", isShepherd: false)])
        ws.connections = [Connection(a: mid, b: wid)]
        let file = paths.workspaceDir(wsId).appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ws).write(to: file)
        let d = try Daemon(config: testConfig(paths, wsId))
        try await d.start()
        do {
            let r = try await admin(d, paths, "spawn", ["name": .string("W"), "preset": .string("shell"), "cwd": .string("/nonexistent-dir"),
                                                        "sandbox": .string("free")])
            #expect(!r.ok, "\(r)")
            let s = try await send(paths, Request(id: "s", token: d.adminToken, command: "ui.snapshot"))
            #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(s.result)).connections.count == 1)
        } catch { await d.stop(); throw error }
        await d.stop()
    }
}
