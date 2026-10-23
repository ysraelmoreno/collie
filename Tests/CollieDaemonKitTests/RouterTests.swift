import Testing
import Foundation
import Darwin
import CollieCore
import CollieProtocol
import CollieTerminal
@testable import CollieDaemonKit

/// Hermetic config: plain /bin/sh, not the developer's $SHELL. An interactive oh-my-zsh + nvm zsh takes
/// 1-1.6 s to print its first prompt alone and 7-10 s when the parallel suite starts ~30 at once.
func testConfig(_ paths: Paths, _ ws: UUID = UUID()) -> DaemonConfig {
    var c = DaemonConfig(paths: paths, collieExecutable: URL(fileURLWithPath: "/tmp/collie"), workspaceId: ws)
    c.shell = "/bin/sh"
    // never the real simctl/AXe (nor the developer's simulators); the fake xcrun lists none unless a test sets it up
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    c.xcrunPath = fixtures.appendingPathComponent("fake-xcrun.sh")
    c.axePath = fixtures.appendingPathComponent("fake-axe.sh")
    c.captureUserEnv = false   // never the developer's rc files
    c.localModel = FakeModel(.unavailable)   // never the real on-device model (tests that want one set it)
    return c
}
private func makeDaemon(_ configure: (inout DaemonConfig) -> Void = { _ in }) throws -> (Daemon, Paths) {
    let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))"))
    var c = testConfig(paths); configure(&c)
    return (try Daemon(config: c), paths)
}
/// Starts a daemon, always stops it and removes its root, even when the body throws or fails.
func withDaemon(configure: (inout DaemonConfig) -> Void = { _ in }, _ body: (Daemon, Paths) async throws -> Void) async throws {
    let (d, p) = try makeDaemon(configure)
    defer { try? FileManager.default.removeItem(at: p.root) }
    do { try await d.start(); try await body(d, p) } catch { await d.stop(); throw error }
    await d.stop()
}
func send(_ p: Paths, _ r: Request, timeoutSeconds: Double = 10) async throws -> Response {
    try await UnixSocketClient.send(r, to: p.socket, timeoutSeconds: timeoutSeconds)
}
func spawn(_ d: Daemon, _ p: Paths, _ name: String, preset: String = "shell", command: String? = nil) async throws -> (id: String, resp: Response) {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string(preset), "cwd": .string("/tmp")]
    if let command { args["command"] = .string(command) }
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args))
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { return ("", r) }
    return (id, r)
}

@Suite struct RouterTests {
    @Test func rejectsWrongVersion() async throws {
        try await withDaemon { d, p in
        let r = try await send(p, Request(v: 99, id: "1", command: "list"))
        #expect(!r.ok && r.error?.code == .unsupportedVersion)
    }
    }

    @Test func rejectsBadToken() async throws {
        try await withDaemon { d, p in
        let a = try await spawn(d, p, "A")
        let r = try await send(p, Request(id: "1", terminalId: a.id, token: "nope", command: "list"))
        #expect(r.error?.code == .unauthorized)
        let r2 = try await send(p, Request(id: "2", token: "nope", command: "admin.spawn"))
        #expect(r2.error?.code == .unauthorized)
    }
    }

    @Test func snapshotRefusesNonAdminToken() async throws {
        try await withDaemon { d, p in
            let a = try await spawn(d, p, "A")
            for (tid, tok) in [(nil, "nope"), (nil, nil), (a.id, "nope")] as [(String?, String?)] {
                let r = try await send(p, Request(id: "x", terminalId: tid, token: tok, command: "ui.snapshot"))
                #expect(!r.ok && r.error?.code == .unauthorized, "\(r)")
            }
            let ok = try await send(p, Request(id: "y", token: d.adminToken, command: "ui.snapshot"))
            let snap = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(ok.result))
            #expect(snap.terminals.map(\.name) == ["A"])
        }
    }

    @Test func adminSpawnAndList() async throws {
        try await withDaemon { d, p in
        let a = try await spawn(d, p, "A"); let b = try await spawn(d, p, "B"); _ = try await spawn(d, p, "C")
        #expect(a.resp.ok && b.resp.ok)
        let c = try await send(p, Request(id: "c", token: d.adminToken, command: "admin.leash",
                                          args: ["a": .string("A"), "b": .string("b")]))
        #expect(c.ok)
        // A's token is only obtainable from its env; read it back through the shell
        let tok = try await tokenOf(d, a.id)
        let l = try await send(p, Request(id: "l", terminalId: a.id, token: tok, command: "list"))
        guard case .array(let rows)? = l.result else { Issue.record("no list: \(l)"); return }
        #expect(rows == [.object(["name": .string("B"), "preset": .string("shell"), "running": .bool(true), "isShepherd": .bool(false)])])
    }
    }

    @Test func shepherdWithoutLeashesListsNothing() async throws {
        try await withDaemon { d, p in
        let m = try await send(p, Request(id: "m", token: d.adminToken, command: "admin.spawn", args: [
            "name": .string("M"), "preset": .string("shell"), "cwd": .string("/tmp"), "shepherd": .bool(true)]))
        guard case .object(let o)? = m.result, case .string(let mid)? = o["id"] else { Issue.record("spawn \(m)"); return }
        _ = try await spawn(d, p, "B")
        let tok = try await tokenOf(d, mid)
        let l = try await send(p, Request(id: "l", terminalId: mid, token: tok, command: "list"))
        #expect(l.ok && l.result == .array([]), "\(l)")
    }
    }

    @Test func injectsEnvironment() async throws {
        try await withDaemon { d, p in
        let a = try await spawn(d, p, "A")
        let tokA = try await tokenOf(d, a.id)
        let e = try await spawn(d, p, "E", preset: "custom", command: "env")
        _ = await waitFor(20) {
            let t = await d.scrollbackText(UUID(uuidString: e.id)!)
            return t.contains("TERM_PROGRAM=Collie") && t.contains("COLLIE_TERMINAL_ID=")
        }
        let text = await d.scrollbackText(UUID(uuidString: e.id)!)
        #expect(text.contains("COLLIE_TERMINAL_ID=\(e.id)"))
        #expect(text.contains("TERM_PROGRAM=Collie"))
        #expect(!text.contains(tokA))
    }
    }

    @Test func adminTokenFileIsPrivate() async throws {
        try await withDaemon { d, p in
        var st = stat()
        stat(p.adminTokenFile.path, &st); #expect(st.st_mode & 0o777 == 0o600)
        stat(p.runDir.path, &st); #expect(st.st_mode & 0o777 == 0o700)
        let onDisk = try String(contentsOf: p.adminTokenFile, encoding: .utf8)
        #expect(onDisk == d.adminToken)
    }
    }

    @Test func ambiguousAndMissingNames() async throws {
        // spawn refuses a live duplicate name, so duplicates can only come from an older workspace.json
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))")), wsId = UUID()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let rec = { (n: String) in TerminalRecord(id: UUID(), name: n, preset: .shell, command: nil, cwd: "/tmp", isShepherd: false) }
        try await WorkspaceStore(paths: paths).save(Workspace(id: wsId, name: "default", terminals: [rec("Dup"), rec("dup")]))
        let d = try Daemon(config: testConfig(paths, wsId))
        try await d.start()
        do {
            let p = paths
            _ = try await spawn(d, p, "Solo")
            let again = try await spawn(d, p, "solo")
            #expect(again.resp.error?.code == .invalidArgs)
            let respawn = try await spawn(d, p, "DUP")
            #expect(respawn.resp.error?.code == .ambiguous)
            let amb = try await send(p, Request(id: "1", token: d.adminToken, command: "admin.leash", args: ["a": .string("DUP"), "b": .string("Solo")]))
            #expect(amb.error?.code == .ambiguous)
            let kill = try await send(p, Request(id: "2", token: d.adminToken, command: "admin.kill", args: ["target": .string("dup")]))
            #expect(kill.error?.code == .ambiguous)
            let miss = try await send(p, Request(id: "3", token: d.adminToken, command: "admin.kill", args: ["target": .string("nope")]))
            #expect(miss.error?.code == .notFound)
        } catch { await d.stop(); throw error }
        await d.stop()
    }

    @Test func spawnFailureIsInvalidArgs() async throws {
        try await withDaemon { d, p in
        let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn",
                                          args: ["name": .string("X"), "preset": .string("shell"), "cwd": .string("/nonexistent-dir")]))
        #expect(!r.ok && r.error?.code == .invalidArgs)
    }
    }
}

@Suite struct RecordLifecycleTests {
    func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String]) async throws -> Response {
        try await send(p, Request(id: "x", token: d.adminToken, command: "admin.\(cmd)", args: args.mapValues { .string($0) }))
    }
    func names(_ d: Daemon, _ p: Paths, from id: String) async throws -> [String] {
        let l = try await send(p, Request(id: "l", terminalId: id, token: try await tokenOf(d, id), command: "list"))
        guard case .array(let rows)? = l.result else { return ["<\(l)>"] }
        return rows.compactMap { if case .object(let o) = $0, case .string(let n)? = o["name"] { return n }; return nil }
    }
    func saved(_ p: Paths, _ d: Daemon) throws -> Workspace {
        let dir = try FileManager.default.contentsOfDirectory(at: p.root.appendingPathComponent("workspaces"), includingPropertiesForKeys: nil)[0]
        return try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: dir.appendingPathComponent("workspace.json")))
    }

    @Test func exitedRecordIsReplacedInPlaceKeepingConnections() async throws {
        try await withDaemon { d, p in
            let a = try await spawn(d, p, "A", preset: "custom", command: "exit 0")
            let b = try await spawn(d, p, "B")
            #expect(try await admin(d, p, "leash", ["a": "A", "b": "B"]).ok)
            #expect(await waitFor(3) { await d.process(UUID(uuidString: a.id)!)?.isRunning == false })
            let a2 = try await spawn(d, p, "a")
            #expect(a2.resp.ok && a2.id == a.id)
            #expect(try await names(d, p, from: b.id) == ["a"])
            let ws = try saved(p, d)
            #expect(ws.terminals.count == 2 && ws.connections.count == 1)
        }
    }

    @Test func respawnOfRunningNameIsRejected() async throws {
        try await withDaemon { d, p in
            _ = try await spawn(d, p, "A")
            let r = try await spawn(d, p, "A")
            #expect(r.resp.error?.code == .invalidArgs)
            #expect(r.resp.error?.message == "terminal 'A' is already running")
        }
    }

    @Test func killRemovesRecordAndItsConnections() async throws {
        try await withDaemon { d, p in
            let a = try await spawn(d, p, "A"), b = try await spawn(d, p, "B")
            #expect(try await admin(d, p, "leash", ["a": "A", "b": "B"]).ok)
            #expect(try await admin(d, p, "kill", ["target": "A"]).ok)
            #expect(try await admin(d, p, "kill", ["target": "A"]).error?.code == .notFound)
            #expect(try saved(p, d).terminals.map(\.name) == ["B"] && saved(p, d).connections.isEmpty)
            #expect(try await names(d, p, from: b.id) == [])
            let a2 = try await spawn(d, p, "A")
            #expect(a2.resp.ok && a2.id != a.id)
            #expect(try await admin(d, p, "leash", ["a": "A", "b": "B"]).ok)
            #expect(try await names(d, p, from: b.id) == ["A"])
        }
    }

    @Test func selfConnectRejectedAndEdgesNotDuplicated() async throws {
        try await withDaemon { d, p in
            _ = try await spawn(d, p, "A"); _ = try await spawn(d, p, "B")
            #expect(try await admin(d, p, "leash", ["a": "A", "b": "a"]).error?.code == .invalidArgs)
            for (x, y) in [("A", "B"), ("A", "B"), ("B", "A")] {
                #expect(try await admin(d, p, "leash", ["a": x, "b": y]).ok)
            }
            #expect(try saved(p, d).connections.count == 1)
        }
    }

    @Test func restartReloadsRecordsAndAskNamesTheTarget() async throws {
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let cfg = testConfig(paths)
        let d1 = try Daemon(config: cfg)
        try await d1.start()
        _ = try await spawn(d1, paths, "A"); _ = try await spawn(d1, paths, "B")
        _ = try await admin(d1, paths, "leash", ["a": "A", "b": "B"])
        await d1.stop()
        let d2 = try Daemon(config: cfg)
        try await d2.start()
        do {
            let b = try await spawn(d2, paths, "B")
            #expect(b.resp.ok)
            #expect(try await admin(d2, paths, "leash", ["a": "A", "b": "B"]).ok)
            let r = try await send(paths, Request(id: "a", terminalId: b.id, token: try await tokenOf(d2, b.id), command: "ask",
                                                  args: ["target": .string("A"), "prompt": .string("hi")]))
            #expect(r.error?.code == .notRunning)
            #expect(r.error?.message == "Terminal 'A' is not running")
            #expect(try saved(paths, d2).terminals.count == 2)
        } catch { await d2.stop(); throw error }
        await d2.stop()
    }
}

/// Test helper: reads a terminal's token out of its own environment via the scrollback.
/// `echo`: types the echo into the shell, resending every second (a fresh login shell may drop typeahead).
func tokenOf(_ d: Daemon, _ id: String, echo: Bool = true) async throws -> String {
    let u = UUID(uuidString: id)!
    let pty = await d.process(u)!
    for i in 0..<200 {   // 20 s: a fresh shell under full-suite load can take seconds to print
        if echo && i % 10 == 0 { try pty.write(Data("echo T=$COLLIE_TOKEN\n".utf8)) }
        try await Task.sleep(for: .milliseconds(100))
        let t = await d.scrollbackText(u)
        if let r = t.range(of: #"T=[0-9a-f]{64}"#, options: .regularExpression) { return String(t[r].dropFirst(2)) }
    }
    throw ProtocolError(code: .internal, message: "no token; running=\(pty.isRunning) scrollback=\(String(reflecting: await d.scrollbackText(u)))")
}

/// Waits for a positive condition. `seconds` is floored at 20 s: every caller waits for something that must
/// happen, so a generous deadline costs nothing when it passes and absorbs a loaded machine running all suites at once.
func waitFor(_ seconds: Double, _ cond: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(max(seconds, 20))
    while ContinuousClock.now < deadline { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
    return await cond()
}
