import Testing
import Foundation
import OrqCore
import OrqProtocol
@testable import OrqDaemonKit

private let orqBin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent(".build/debug/orq").path

private struct Term { var id: String; var token: String }

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue]) async throws -> Response {
    try await send(p, Request(id: "x", token: d.adminToken, command: "admin.\(cmd)", args: args))
}
private func maestro(_ d: Daemon, _ p: Paths, _ name: String) async throws -> Term {
    let r = try await admin(d, p, "spawn", ["name": .string(name), "preset": .string("shell"), "cwd": .string("/tmp"),
                                            "maestro": .bool(true)])
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

@Suite(.serialized) struct MaestroTests {
    @Test func nonMaestroIsRefused() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            for cmd in ["recruit", "dismiss", "connect", "disconnect", "notify"] {
                let r = try await call(p, a, cmd, ["name": "W", "preset": "shell", "target": "A", "a": "A", "b": "A", "message": "x"])
                #expect(r.error?.code == .notMaestro && r.error?.message == "'\(cmd)' is Maestro-only", "\(r)")
            }
            #expect(try await snapshot(d, p).terminals.map(\.name) == ["A"])
        }
    }

    @Test func recruitCreatesCordAndInherits() async throws {
        try await withDaemon { d, p in
            let m = try await maestro(d, p, "M")
            let r = try await call(p, m, "recruit", ["name": "W", "preset": "shell"])
            guard case .object(let o)? = r.result, case .string(let wid)? = o["id"] else { Issue.record("\(r)"); return }
            #expect(o["name"] == .string("W"))
            #expect(try await names(p, m) == ["W"])
            let w = try #require(try await snapshot(d, p).terminals.first { $0.id.uuidString == wid })
            #expect(!w.isMaestro && w.cwd == "/tmp" && w.floorId == nil)
            #expect(try await call(p, m, "recruit", ["name": "w", "preset": "shell"]).error?.code == .invalidArgs)
            #expect(try await call(p, m, "recruit", ["name": "X", "preset": "shell", "floor": "nope"]).error?.code == .notFound)
        }
    }

    /// Floors can't be created yet (Task 4): seed one, and a Maestro standing on it, into workspace.json.
    @Test func recruitFloorSetsFloorAndCwd() async throws {
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/orq-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let floorDir = paths.root.appendingPathComponent("floor-f")
        try FileManager.default.createDirectory(at: floorDir, withIntermediateDirectories: true)
        let wsId = UUID(), mid = UUID()
        let fl = Floor(id: UUID(), name: "Feat", repoRoot: "/tmp", path: floorDir.path, branch: "orq/feat", baseBranch: "main")
        let ws = Workspace(id: wsId, name: "default", terminals: [
            TerminalRecord(id: mid, name: "M", preset: .shell, command: nil, cwd: "/tmp", isMaestro: true, floorId: fl.id)], floors: [fl])
        let file = paths.workspaceDir(wsId).appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ws).write(to: file)
        let d = try Daemon(config: testConfig(paths, wsId))
        try await d.start()
        do {
            #expect(try await admin(d, paths, "restart", ["name": .string("M")]).ok)
            let m = Term(id: mid.uuidString, token: try await tokenOf(d, mid.uuidString))
            #expect(try await call(paths, m, "recruit", ["name": "A", "preset": "shell", "floor": "feat"]).ok)
            #expect(try await call(paths, m, "recruit", ["name": "B", "preset": "shell", "cwd": "/"]).ok)
            let ts = try await snapshot(d, paths).terminals
            let a = try #require(ts.first { $0.name == "A" }), b = try #require(ts.first { $0.name == "B" })
            #expect(a.floorId == fl.id && a.cwd == floorDir.path)
            #expect(b.floorId == fl.id && b.cwd == "/")   // inherits the Maestro's floor
        } catch { await d.stop(); throw error }
        await d.stop()
    }

    /// Seeds workspace.json with `terminals` and `floors`, starts a daemon, restarts every terminal, runs `body`.
    private func seeded(_ terminals: [TerminalRecord], _ floors: [Floor] = [], root: URL? = nil,
                        _ body: (Daemon, Paths) async throws -> Void) async throws {
        let paths = Paths(root: root ?? URL(fileURLWithPath: "/tmp/orq-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let wsId = UUID()
        let file = paths.workspaceDir(wsId).appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Workspace(id: wsId, name: "default", terminals: terminals, floors: floors)).write(to: file)
        let d = try Daemon(config: testConfig(paths, wsId))
        try await d.start()
        do { try await body(d, paths) } catch { await d.stop(); throw error }
        await d.stop()
    }

    /// Final-review I2: `recruit --floor` only into the Maestro's own floors (created by it, or the one it stands in).
    @Test func recruitFloorRequiresOwnership() async throws {
        let m1 = UUID(), m2 = UUID(), dir = URL(fileURLWithPath: "/tmp")
        let mine = Floor(id: UUID(), name: "mine", repoRoot: "/tmp", path: dir.path, branch: "orq/mine", baseBranch: "main", createdBy: m1)
        let user = Floor(id: UUID(), name: "user", repoRoot: "/tmp", path: dir.path, branch: "orq/user", baseBranch: "main")
        try await seeded([TerminalRecord(id: m1, name: "M1", preset: .shell, command: nil, cwd: "/tmp", isMaestro: true),
                          TerminalRecord(id: m2, name: "M2", preset: .shell, command: nil, cwd: "/tmp", isMaestro: true)],
                         [mine, user]) { d, p in
            for n in ["M1", "M2"] { #expect(try await admin(d, p, "restart", ["name": .string(n)]).ok) }
            let t1 = Term(id: m1.uuidString, token: try await tokenOf(d, m1.uuidString))
            let t2 = Term(id: m2.uuidString, token: try await tokenOf(d, m2.uuidString))
            let r = try await call(p, t2, "recruit", ["name": "X", "preset": "shell", "floor": "mine"])
            #expect(r.error == ProtocolError(code: .notMaestro, message: "floor 'mine' belongs to another Maestro"), "\(r)")
            #expect(try await call(p, t1, "recruit", ["name": "Y", "preset": "shell", "floor": "user"]).error?.code == .notMaestro)
            #expect(try await call(p, t1, "recruit", ["name": "Z", "preset": "shell", "floor": "mine"]).ok)
            #expect(try await snapshot(d, p).terminals.map(\.name).sorted() == ["M1", "M2", "Z"])
        }
    }

    /// Final-review I3: restarting a record whose floor is gone relaunches it in the ground, never in the missing dir.
    @Test func restartWithFloorGoneFallsBackToGround() async throws {
        let root = URL(fileURLWithPath: "/tmp/orq-\(UUID().uuidString.prefix(8))"), id = UUID()
        let gone = root.appendingPathComponent(".orq/floors/gone").path
        try await seeded([TerminalRecord(id: id, name: "W", preset: .shell, command: nil, cwd: gone, isMaestro: false, floorId: UUID())],
                         root: root) { d, p in
            let r = try await admin(d, p, "restart", ["name": .string("W")])
            #expect(r.ok, "\(r)")
            let w = try #require(try await snapshot(d, p).terminals.first)
            #expect(w.floorId == nil && w.cwd == root.path, "\(w)")
        }
    }

    @Test func recruitPromptIsInjected() async throws {
        try await withDaemon { d, p in
            let m = try await maestro(d, p, "M")
            let r = try await call(p, m, "recruit", ["name": "w", "preset": "shell", "prompt": "echo hi-from-maestro"])
            guard case .object(let o)? = r.result, case .string(let wid)? = o["id"] else { Issue.record("\(r)"); return }
            #expect(await waitFor(10) { await d.scrollbackText(UUID(uuidString: wid)!).contains("hi-from-maestro") })
        }
    }

    /// The injected prompt's turn holds the FIFO: an ask sent right after gets its own output, not the inject's.
    @Test func injectedTurnHoldsQueue() async throws {
        // idle window injected at 5 s (production 2 s): a loaded machine can stretch `sleep 1` plus its spawn past 2 s
        try await withDaemon(configure: { $0.idleQuietSeconds = 5 }) { d, p in
            let m = try await maestro(d, p, "M")
            // sleep 1 < idleQuiet (5 s): the injected turn isn't over until INJ-DONE has printed and gone quiet
            #expect(try await call(p, m, "recruit", ["name": "w", "preset": "shell", "prompt": "sleep 1; echo INJ-DONE"]).ok)
            let r = try await call(p, m, "ask", ["target": "w", "prompt": "echo ASK-OUT"])
            guard case .object(let o)? = r.result, case .string(let out)? = o["output"] else { Issue.record("\(r)"); return }
            #expect(out.contains("ASK-OUT") && !out.contains("INJ-DONE"), "\(out)")
        }
    }

    /// R10: a recruit's first prompt is never typed into a pending approval prompt (its Enter would answer it).
    @Test func recruitPromptNeverAnswersAPrompt() async throws {
        try await withDaemon { d, p in
            let m = try await maestro(d, p, "M")
            let r = try await call(p, m, "recruit", ["name": "w", "preset": "claude",
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

    @Test func recruitPromptFailureStillSucceeds() async throws {
        try await withDaemon { d, p in
            let m = try await maestro(d, p, "M")
            let r = try await call(p, m, "recruit", ["name": "w", "preset": "custom", "command": "exit 3", "prompt": "hi"])
            guard case .object(let o)? = r.result, case .string(let e)? = o["promptError"] else { Issue.record("\(r)"); return }
            #expect(e.hasPrefix("notRunning"), "\(e)")
            #expect(try await names(p, m) == ["w"])
        }
    }

    @Test func concurrentRecruitsOfOneNameYieldOne() async throws {
        try await withDaemon { d, p in
            let m = try await maestro(d, p, "M")
            async let a = call(p, m, "recruit", ["name": "w", "preset": "shell"])
            async let b = call(p, m, "recruit", ["name": "W", "preset": "shell"])
            let rs = try await [a, b]
            #expect(rs.filter(\.ok).count == 1 && rs.contains { $0.error?.code == .invalidArgs }, "\(rs)")
            #expect(try await snapshot(d, p).terminals.count == 2)
        }
    }

    @Test func connectCannotExtendReach() async throws {
        try await withDaemon { d, p in
            let m = try await maestro(d, p, "M")
            _ = try await spawn(d, p, "A"); _ = try await spawn(d, p, "B")
            #expect(try await admin(d, p, "connect", ["a": .string("M"), "b": .string("A")]).ok)
            #expect(try await call(p, m, "connect", ["a": "A", "b": "B"]).error?.code == .notConnected)
            #expect(try await call(p, m, "connect", ["a": "M", "b": "B"]).error?.code == .notConnected)
            #expect(try await call(p, m, "disconnect", ["a": "A", "b": "B"]).error?.code == .notConnected)
            #expect(try await snapshot(d, p).connections.count == 1)
            // within reach: two recruits can be corded, and the Maestro can drop its own cord
            _ = try await call(p, m, "recruit", ["name": "R", "preset": "shell"])
            #expect(try await call(p, m, "connect", ["a": "A", "b": "R"]).ok)
            #expect(try await snapshot(d, p).connections.count == 3)
            #expect(try await call(p, m, "disconnect", ["a": "m", "b": "A"]).ok)
            #expect(try await names(p, m) == ["R"])
        }
    }

    @Test func dismissNeedsCord() async throws {
        try await withDaemon { d, p in
            let m = try await maestro(d, p, "M")
            let x = try await spawn(d, p, "X")
            let ev = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            defer { ev.close() }
            #expect(try await call(p, m, "dismiss", ["target": "X"]).error?.code == .notConnected)
            #expect(try await call(p, m, "dismiss", ["target": "M"]).error?.code == .notConnected)
            #expect(try await admin(d, p, "connect", ["a": .string("M"), "b": .string("X")]).ok)
            #expect(try await call(p, m, "dismiss", ["target": "x"]).ok)
            #expect(try await snapshot(d, p).terminals.map(\.name) == ["M"])
            var removed = false
            while !removed, case .event(let e)? = try await ev.next(timeoutSeconds: 30) {
                if e == .removed(UUID(uuidString: x.id)!) { removed = true }
            }
            #expect(removed)
        }
    }

    @Test func dismissRefusesMaestroTarget() async throws {
        try await withDaemon { d, p in
            let m1 = try await maestro(d, p, "M1"); _ = try await maestro(d, p, "M2")
            #expect(try await admin(d, p, "connect", ["a": .string("M1"), "b": .string("M2")]).ok)
            #expect(try await call(p, m1, "dismiss", ["target": "M2"]).error?.code == .invalidArgs)
        }
    }

    @Test func parallelMaestrosAreIsolated() async throws {
        try await withDaemon { d, p in
            let m1 = try await maestro(d, p, "M1"), m2 = try await maestro(d, p, "M2")
            #expect(try await call(p, m1, "recruit", ["name": "A1", "preset": "shell"]).ok)
            #expect(try await call(p, m2, "recruit", ["name": "A2", "preset": "shell"]).ok)
            #expect(try await names(p, m1) == ["A1"])
            #expect(try await names(p, m2) == ["A2"])
            #expect(try await call(p, m1, "dismiss", ["target": "A2"]).error?.code == .notConnected)
            #expect(try await call(p, m1, "connect", ["a": "A1", "b": "A2"]).error?.code == .notConnected)
            #expect(try await call(p, m1, "disconnect", ["a": "M2", "b": "A2"]).error?.code == .notConnected)
            #expect(try await snapshot(d, p).connections.count == 2)
        }
    }

    @Test func notifyEmitsEvent() async throws {
        try await withDaemon { d, p in
            let m = try await maestro(d, p, "M")
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

    /// 1A regression: a Maestro holds no admin power; a process inside it presenting the admin token is refused.
    @Test func adminTokenFromMaestroStillRefused() async throws {
        try await withDaemon { d, p in
            _ = try await spawn(d, p, "B")
            let cmd = "echo M=$ORQ_MAESTRO; ORQ_ADMIN_TOKEN_FILE='\(p.adminTokenFile.path)' '\(orqBin)' admin connect M B; echo RC=$?; exec sleep 300"
            let r = try await admin(d, p, "spawn", ["name": .string("M"), "preset": .string("custom"), "cwd": .string("/tmp"),
                                                    "command": .string(cmd), "maestro": .bool(true)])
            guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { Issue.record("\(r)"); return }
            #expect(await waitFor(10) { await d.scrollbackText(UUID(uuidString: id)!).contains("RC=") })
            let text = await d.scrollbackText(UUID(uuidString: id)!)
            #expect(text.contains("M=1") && text.contains("admin commands are not allowed from managed terminals")
                    && text.contains("RC=1"), "\(text)")
            #expect(try await snapshot(d, p).connections.isEmpty)
        }
    }
}
