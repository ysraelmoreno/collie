import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let collieBin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build/debug/collie").path

private struct Term { var id: String; var token: String }

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue]) async throws -> Response {
    try await send(p, Request(id: "x", token: d.adminToken, command: "admin.\(cmd)", args: args))
}
private func shepherd(_ d: Daemon, _ p: Paths, _ name: String) async throws -> Term {
    let r = try await admin(d, p, "spawn", ["name": .string(name), "preset": .string("shell"), "cwd": .string("/tmp"),
                                            "shepherd": .bool(true)])
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func term(_ d: Daemon, _ p: Paths, _ name: String) async throws -> Term {
    let s = try await spawn(d, p, name)
    return Term(id: s.id, token: try await tokenOf(d, s.id))
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 30)
}
private func names(_ p: Paths, _ t: Term) async throws -> [String] {
    guard case .array(let rows)? = try await call(p, t, "list").result else { return ["<no list>"] }
    return rows.compactMap { if case .object(let o) = $0, case .string(let n)? = o["name"] { return n }; return nil }.sorted()
}
private func snapshot(_ d: Daemon, _ p: Paths) async throws -> WorkspaceSnapshot {
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "ui.snapshot"))
    return try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(r.result))
}

@Suite(.serialized) struct ShepherdTests {
    @Test func nonShepherdIsRefused() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            for cmd in ["summon", "dismiss", "leash", "unleash", "notify"] {
                let r = try await call(p, a, cmd, ["name": "W", "preset": "shell", "target": "A", "a": "A", "b": "A", "message": "x"])
                #expect(r.error?.code == .notShepherd && r.error?.message == "'\(cmd)' is Shepherd-only", "\(r)")
            }
            #expect(try await snapshot(d, p).terminals.map(\.name) == ["A"])
        }
    }

    @Test func summonCreatesLeashAndInherits() async throws {
        try await withDaemon { d, p in
            let m = try await shepherd(d, p, "M")
            let r = try await call(p, m, "summon", ["name": "W", "preset": "shell"])
            guard case .object(let o)? = r.result, case .string(let wid)? = o["id"] else { Issue.record("\(r)"); return }
            #expect(o["name"] == .string("W"))
            #expect(try await names(p, m) == ["W"])
            let w = try #require(try await snapshot(d, p).terminals.first { $0.id.uuidString == wid })
            #expect(!w.isShepherd && w.cwd == "/tmp" && w.paddockId == nil)
            #expect(try await call(p, m, "summon", ["name": "w", "preset": "shell"]).error?.code == .invalidArgs)
            #expect(try await call(p, m, "summon", ["name": "X", "preset": "shell", "paddock": "nope"]).error?.code == .notFound)
        }
    }

    /// Paddocks can't be created yet (Task 4): seed one, and a Shepherd standing on it, into workspace.json.
    @Test func summonPaddockSetsPaddockAndCwd() async throws {
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let paddockDir = paths.root.appendingPathComponent("paddock-f")
        try FileManager.default.createDirectory(at: paddockDir, withIntermediateDirectories: true)
        let wsId = UUID(), mid = UUID()
        let fl = Paddock(id: UUID(), name: "Feat", repoRoot: "/tmp", path: paddockDir.path, branch: "collie/feat", baseBranch: "main")
        let ws = Workspace(id: wsId, name: "default", terminals: [
            TerminalRecord(id: mid, name: "M", preset: .shell, command: nil, cwd: "/tmp", isShepherd: true, paddockId: fl.id)], paddocks: [fl])
        let file = paths.workspaceDir(wsId).appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ws).write(to: file)
        let d = try Daemon(config: testConfig(paths, wsId))
        try await d.start()
        do {
            #expect(try await admin(d, paths, "restart", ["name": .string("M")]).ok)
            let m = Term(id: mid.uuidString, token: try await tokenOf(d, mid.uuidString))
            #expect(try await call(paths, m, "summon", ["name": "A", "preset": "shell", "paddock": "feat"]).ok)
            #expect(try await call(paths, m, "summon", ["name": "B", "preset": "shell", "cwd": "/"]).error?.code == .invalidArgs)   // outside its paddock
            #expect(try await call(paths, m, "summon", ["name": "B", "preset": "shell", "cwd": paddockDir.path]).ok)
            let ts = try await snapshot(d, paths).terminals
            let a = try #require(ts.first { $0.name == "A" }), b = try #require(ts.first { $0.name == "B" })
            #expect(a.paddockId == fl.id && a.cwd == paddockDir.path)
            #expect(b.paddockId == fl.id && b.cwd == paddockDir.path)   // inherits the Shepherd's paddock
        } catch { await d.stop(); throw error }
        await d.stop()
    }

    /// Seeds workspace.json with `terminals` and `paddocks`, starts a daemon, restarts every terminal, runs `body`.
    private func seeded(_ terminals: [TerminalRecord], _ paddocks: [Paddock] = [], root: URL? = nil,
                        _ body: (Daemon, Paths) async throws -> Void) async throws {
        let paths = Paths(root: root ?? URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let wsId = UUID()
        let file = paths.workspaceDir(wsId).appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Workspace(id: wsId, name: "default", terminals: terminals, paddocks: paddocks)).write(to: file)
        let d = try Daemon(config: testConfig(paths, wsId))
        try await d.start()
        do { try await body(d, paths) } catch { await d.stop(); throw error }
        await d.stop()
    }

    /// Final-review I2: `summon --paddock` only into the Shepherd's own paddocks (created by it, or the one it stands in).
    @Test func summonPaddockRequiresOwnership() async throws {
        let m1 = UUID(), m2 = UUID(), dir = URL(fileURLWithPath: "/tmp")
        let mine = Paddock(id: UUID(), name: "mine", repoRoot: "/tmp", path: dir.path, branch: "collie/mine", baseBranch: "main", createdBy: m1)
        let user = Paddock(id: UUID(), name: "user", repoRoot: "/tmp", path: dir.path, branch: "collie/user", baseBranch: "main")
        try await seeded([TerminalRecord(id: m1, name: "M1", preset: .shell, command: nil, cwd: "/tmp", isShepherd: true),
                          TerminalRecord(id: m2, name: "M2", preset: .shell, command: nil, cwd: "/tmp", isShepherd: true)],
                         [mine, user]) { d, p in
            for n in ["M1", "M2"] { #expect(try await admin(d, p, "restart", ["name": .string(n)]).ok) }
            let t1 = Term(id: m1.uuidString, token: try await tokenOf(d, m1.uuidString))
            let t2 = Term(id: m2.uuidString, token: try await tokenOf(d, m2.uuidString))
            let r = try await call(p, t2, "summon", ["name": "X", "preset": "shell", "paddock": "mine"])
            #expect(r.error == ProtocolError(code: .notShepherd, message: "paddock 'mine' belongs to another Shepherd"), "\(r)")
            #expect(try await call(p, t1, "summon", ["name": "Y", "preset": "shell", "paddock": "user"]).error?.code == .notShepherd)
            #expect(try await call(p, t1, "summon", ["name": "Z", "preset": "shell", "paddock": "mine"]).ok)
            #expect(try await snapshot(d, p).terminals.map(\.name).sorted() == ["M1", "M2", "Z"])
        }
    }

    /// Final-review I3: restarting a record whose paddock is gone relaunches it in the pasture, never in the missing dir.
    @Test func restartWithPaddockGoneFallsBackToPasture() async throws {
        let root = URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))"), id = UUID()
        let gone = root.appendingPathComponent(".collie/paddocks/gone").path
        try await seeded([TerminalRecord(id: id, name: "W", preset: .shell, command: nil, cwd: gone, isShepherd: false, paddockId: UUID())],
                         root: root) { d, p in
            let r = try await admin(d, p, "restart", ["name": .string("W")])
            #expect(r.ok, "\(r)")
            let w = try #require(try await snapshot(d, p).terminals.first)
            #expect(w.paddockId == nil && w.cwd == root.path, "\(w)")
        }
    }

    @Test func summonPromptIsInjected() async throws {
        try await withDaemon { d, p in
            let m = try await shepherd(d, p, "M")
            let r = try await call(p, m, "summon", ["name": "w", "preset": "shell", "prompt": "echo hi-from-shepherd"])
            guard case .object(let o)? = r.result, case .string(let wid)? = o["id"] else { Issue.record("\(r)"); return }
            #expect(await waitFor(10) { await d.scrollbackText(UUID(uuidString: wid)!).contains("hi-from-shepherd") })
        }
    }

    /// The injected prompt's turn holds the FIFO: an ask sent right after gets its own output, not the inject's.
    @Test func injectedTurnHoldsQueue() async throws {
        // idle window injected at 5 s (production 2 s): a loaded machine can stretch `sleep 1` plus its spawn past 2 s
        try await withDaemon(configure: { $0.idleQuietSeconds = 5 }) { d, p in
            let m = try await shepherd(d, p, "M")
            // sleep 1 < idleQuiet (5 s): the injected turn isn't over until INJ-DONE has printed and gone quiet
            #expect(try await call(p, m, "summon", ["name": "w", "preset": "shell", "prompt": "sleep 1; echo INJ-DONE"]).ok)
            let r = try await call(p, m, "ask", ["target": "w", "prompt": "echo ASK-OUT"])
            guard case .object(let o)? = r.result, case .string(let out)? = o["output"] else { Issue.record("\(r)"); return }
            #expect(out.contains("ASK-OUT") && !out.contains("INJ-DONE"), "\(out)")
        }
    }

    /// R10: a summon's first prompt is never typed into a pending approval prompt (its Enter would answer it).
    @Test func summonPromptNeverAnswersAPrompt() async throws {
        try await withDaemon { d, p in
            let m = try await shepherd(d, p, "M")
            let r = try await call(p, m, "summon", ["name": "w", "preset": "claude",
                                                     "command": "printf 'Do you trust the files in this folder?\\n'; read l; echo \"GOT:$l\"; exec cat",
                                                     "prompt": "hi"])
            guard case .object(let o)? = r.result, case .string(let wid)? = o["id"], case .string(let e)? = o["promptError"] else {
                Issue.record("\(r)"); return
            }
            #expect(e.contains("waiting for an approval"), "\(e)")
            try await Task.sleep(for: .milliseconds(500))
            #expect(!(await d.scrollbackText(UUID(uuidString: wid)!)).contains("GOT:"))
        }
    }

    @Test func summonPromptFailureStillSucceeds() async throws {
        try await withDaemon { d, p in
            let m = try await shepherd(d, p, "M")
            let r = try await call(p, m, "summon", ["name": "w", "preset": "custom", "command": "exit 3", "prompt": "hi"])
            guard case .object(let o)? = r.result, case .string(let e)? = o["promptError"] else { Issue.record("\(r)"); return }
            #expect(e.hasPrefix("notRunning"), "\(e)")
            #expect(try await names(p, m) == ["w"])
        }
    }

    @Test func concurrentSummonsOfOneNameYieldOne() async throws {
        try await withDaemon { d, p in
            let m = try await shepherd(d, p, "M")
            async let a = call(p, m, "summon", ["name": "w", "preset": "shell"])
            async let b = call(p, m, "summon", ["name": "W", "preset": "shell"])
            let rs = try await [a, b]
            #expect(rs.filter(\.ok).count == 1 && rs.contains { $0.error?.code == .invalidArgs }, "\(rs)")
            #expect(try await snapshot(d, p).terminals.count == 2)
        }
    }

    @Test func connectCannotExtendReach() async throws {
        try await withDaemon { d, p in
            let m = try await shepherd(d, p, "M")
            _ = try await spawn(d, p, "A"); _ = try await spawn(d, p, "B")
            #expect(try await admin(d, p, "leash", ["a": .string("M"), "b": .string("A")]).ok)
            #expect(try await call(p, m, "leash", ["a": "A", "b": "B"]).error?.code == .notConnected)
            #expect(try await call(p, m, "leash", ["a": "M", "b": "B"]).error?.code == .notConnected)
            #expect(try await call(p, m, "unleash", ["a": "A", "b": "B"]).error?.code == .notConnected)
            #expect(try await snapshot(d, p).connections.count == 1)
            // within reach: two summons can be leashed, and the Shepherd can drop its own leash
            _ = try await call(p, m, "summon", ["name": "R", "preset": "shell"])
            #expect(try await call(p, m, "leash", ["a": "A", "b": "R"]).ok)
            #expect(try await snapshot(d, p).connections.count == 3)
            #expect(try await call(p, m, "unleash", ["a": "m", "b": "A"]).ok)
            #expect(try await names(p, m) == ["R"])
        }
    }

    @Test func dismissNeedsLeash() async throws {
        try await withDaemon { d, p in
            let m = try await shepherd(d, p, "M")
            let x = try await spawn(d, p, "X")
            let ev = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            defer { ev.close() }
            #expect(try await call(p, m, "dismiss", ["target": "X"]).error?.code == .notConnected)
            #expect(try await call(p, m, "dismiss", ["target": "M"]).error?.code == .notConnected)
            #expect(try await admin(d, p, "leash", ["a": .string("M"), "b": .string("X")]).ok)
            #expect(try await call(p, m, "dismiss", ["target": "x"]).ok)
            #expect(try await snapshot(d, p).terminals.map(\.name) == ["M"])
            var removed = false
            while !removed, case .event(let e)? = try await ev.next(timeoutSeconds: 30) {
                if e == .removed(UUID(uuidString: x.id)!) { removed = true }
            }
            #expect(removed)
        }
    }

    @Test func dismissRefusesShepherdTarget() async throws {
        try await withDaemon { d, p in
            let m1 = try await shepherd(d, p, "M1"); _ = try await shepherd(d, p, "M2")
            #expect(try await admin(d, p, "leash", ["a": .string("M1"), "b": .string("M2")]).ok)
            #expect(try await call(p, m1, "dismiss", ["target": "M2"]).error?.code == .invalidArgs)
        }
    }

    @Test func parallelShepherdsAreIsolated() async throws {
        try await withDaemon { d, p in
            let m1 = try await shepherd(d, p, "M1"), m2 = try await shepherd(d, p, "M2")
            #expect(try await call(p, m1, "summon", ["name": "A1", "preset": "shell"]).ok)
            #expect(try await call(p, m2, "summon", ["name": "A2", "preset": "shell"]).ok)
            #expect(try await names(p, m1) == ["A1"])
            #expect(try await names(p, m2) == ["A2"])
            #expect(try await call(p, m1, "dismiss", ["target": "A2"]).error?.code == .notConnected)
            #expect(try await call(p, m1, "leash", ["a": "A1", "b": "A2"]).error?.code == .notConnected)
            #expect(try await call(p, m1, "unleash", ["a": "M2", "b": "A2"]).error?.code == .notConnected)
            #expect(try await snapshot(d, p).connections.count == 2)
        }
    }

    @Test func notifyEmitsEvent() async throws {
        try await withDaemon { d, p in
            let m = try await shepherd(d, p, "M")
            let ev = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            defer { ev.close() }
            #expect(try await call(p, m, "notify", ["message": String(repeating: "x", count: 2001)]).error?.code == .invalidArgs)
            #expect(try await call(p, m, "notify", ["message": "done"]).ok)
            var got = false
            while !got, case .event(let e)? = try await ev.next(timeoutSeconds: 30) {
                if e == .notify(UUID(uuidString: m.id)!, message: "done") { got = true }
            }
            #expect(got)
        }
    }

    /// 1A regression: a Shepherd holds no admin power; a process inside it presenting the admin token is refused.
    @Test func adminTokenFromShepherdStillRefused() async throws {
        try await withDaemon { d, p in
            _ = try await spawn(d, p, "B")
            let cmd = "echo M=$COLLIE_SHEPHERD; env -u COLLIE_TERMINAL_ID COLLIE_ADMIN_TOKEN_FILE='\(p.adminTokenFile.path)' '\(collieBin)' admin leash M B; echo RC=$?; exec sleep 300"
            let r = try await admin(d, p, "spawn", ["name": .string("M"), "preset": .string("custom"), "cwd": .string("/tmp"),
                                                    "command": .string(cmd), "shepherd": .bool(true)])
            guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { Issue.record("\(r)"); return }
            #expect(await waitFor(10) { await d.scrollbackText(UUID(uuidString: id)!).contains("RC=") })
            let text = await d.scrollbackText(UUID(uuidString: id)!)
            #expect(text.contains("M=1") && text.contains("the admin token can't be used from inside a Collie terminal")
                    && text.contains("RC=1"), "\(text)")
            #expect(try await snapshot(d, p).connections.isEmpty)
        }
    }
}
