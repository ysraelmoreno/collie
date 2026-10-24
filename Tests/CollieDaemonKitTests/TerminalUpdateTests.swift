import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let collieBin = root.appendingPathComponent(".build/debug/collie").path
private let fixture = root.appendingPathComponent("Tests/Fixtures/fake-agent.sh").path

private struct Term { var id: String; var token: String }

private func update(_ d: Daemon, _ p: Paths, _ name: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    var a = args; a["name"] = .string(name)
    return try await send(p, Request(id: "u", token: d.adminToken, command: "admin.update", args: a))
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, preset: String = "shell", command: String? = nil) async throws -> Term {
    let s = try await spawn(d, p, name, preset: preset, command: command)
    #expect(s.resp.ok, "spawn \(name): \(s.resp)")
    return Term(id: s.id, token: try await tokenOf(d, s.id, echo: command == nil))
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await send(p, Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }), timeoutSeconds: 30)
}
private func snapshot(_ d: Daemon, _ p: Paths) async throws -> WorkspaceSnapshot {
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "ui.snapshot"))
    return try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(r.result))
}
private func flags(_ r: Response) -> (needed: Bool?, restarted: Bool?) {
    guard case .object(let o)? = r.result else { return (nil, nil) }
    var n: Bool?, d: Bool?
    if case .bool(let b)? = o["restartNeeded"] { n = b }
    if case .bool(let b)? = o["restarted"] { d = b }
    return (n, d)
}

@Suite(.serialized) struct TerminalUpdateTests {
    @Test func promoteToShepherdTakesEffectImmediately() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "a")
            _ = try await spawn(d, p, "b")
            #expect(try await call(p, a, "summon", ["name": "w", "preset": "shell"]).error?.code == .notShepherd)
            let r = try await update(d, p, "a", ["shepherd": .bool(true)])
            #expect(r.ok && flags(r).needed == true && flags(r).restarted == false, "\(r)")
            #expect(try await call(p, a, "summon", ["name": "w", "preset": "shell"]).ok)   // old token, live check
        }
    }

    @Test func demoteRemovesShepherdPowers() async throws {
        try await withDaemon { d, p in
            let m = try await send(p, Request(id: "x", token: d.adminToken, command: "admin.spawn", args: [
                "name": .string("m"), "preset": .string("shell"), "cwd": .string("/tmp"), "shepherd": .bool(true)]))
            guard case .object(let o)? = m.result, case .string(let id)? = o["id"] else { Issue.record("\(m)"); return }
            let t = Term(id: id, token: try await tokenOf(d, id))
            #expect(try await call(p, t, "summon", ["name": "w", "preset": "shell"]).ok)
            #expect(try await update(d, p, "m", ["shepherd": .string("false")]).ok)
            #expect(try await call(p, t, "summon", ["name": "w2", "preset": "shell"]).error?.code == .notShepherd)
        }
    }

    @Test func renameRefusesTakenName() async throws {
        try await withDaemon { d, p in
            _ = try await spawn(d, p, "a"); _ = try await spawn(d, p, "b")
            let pn = try await send(p, Request(id: "p", token: d.adminToken, command: "panel.open", args: ["plugin": .string("browser"), "name": .string("browser-1")]))
            #expect(pn.ok, "\(pn)")
            #expect(try await update(d, p, "a", ["newName": .string("B")]).error?.code == .invalidArgs)
            #expect(try await update(d, p, "a", ["newName": .string("browser-1")]).error?.code == .invalidArgs)
            let r = try await update(d, p, "a", ["newName": .string("A")])
            #expect(r.ok && flags(r).needed == false, "\(r)")
            #expect(try await snapshot(d, p).terminals.map(\.name).sorted() == ["A", "b"])
        }
    }

    @Test func renameKeepsPendingAsk() async throws {
        try await withDaemon { d, p in
            let x = try await term(d, p, "x")
            let a = try await term(d, p, "a", preset: "custom", command: "echo T=$COLLIE_TOKEN; COLLIE_FAKE_HOOK=1 exec sh '\(fixture)'")
            #expect(try await send(p, Request(id: "c", token: d.adminToken, command: "admin.leash", args: ["a": .string("x"), "b": .string("a")])).ok)
            let hook = Task {
                var seen = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(30))
                    let msgs = await d.scrollbackText(UUID(uuidString: a.id)!).matches(of: /<<COLLIE_FAKE_STOP:(.*?)>>/).map { String($0.output.1) }
                    for m in msgs.dropFirst(seen) {
                        _ = try? await send(p, Request(id: "h", terminalId: a.id, token: a.token, command: "turn.completed",
                                                       args: ["message": .string(m), "source": .string("generic")]))
                    }
                    seen = max(seen, msgs.count)
                }
            }
            defer { hook.cancel() }
            async let ans = send(p, Request(id: "a", terminalId: x.id, token: x.token, command: "ask",
                                            args: ["target": .string("a"), "prompt": .string("q")]), timeoutSeconds: 20)
            try await Task.sleep(for: .milliseconds(200))
            #expect(try await update(d, p, "a", ["newName": .string("c")]).ok)
            let r = try await ans
            guard case .object(let o)? = r.result, case .string(let out)? = o["output"] else { Issue.record("\(r)"); return }
            #expect(out == "answer:q")
            guard case .array(let rows)? = try await call(p, x, "list").result else { Issue.record("no list"); return }
            #expect(rows.compactMap { if case .object(let o) = $0, case .string(let n)? = o["name"] { return n }; return nil } == ["c"])
        }
    }

    @Test func updateFromManagedTerminalIsRefused() async throws {
        try await withDaemon { d, p in
            _ = try await spawn(d, p, "b")
            let cmd = "env -u COLLIE_TERMINAL_ID COLLIE_ADMIN_TOKEN_FILE='\(p.adminTokenFile.path)' '\(collieBin)' admin update b --shepherd true; echo RC=$?; exec sleep 300"
            let a = try await spawn(d, p, "a", preset: "custom", command: cmd)
            let id = try #require(UUID(uuidString: a.id))
            #expect(await waitFor(10) { await d.scrollbackText(id).contains("RC=") })
            let text = await d.scrollbackText(id)
            #expect(text.contains("the admin token can't be used from inside a Collie terminal") && text.contains("RC=1"), "\(text)")
            #expect(try await snapshot(d, p).terminals.first { $0.name == "b" }?.isShepherd == false)
        }
    }

    @Test func paddockTerminalRefusesCwd() async throws {
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let wsId = UUID()
        let fl = Paddock(id: UUID(), name: "Feat", repoRoot: "/tmp", path: "/tmp", branch: "collie/feat", baseBranch: "main")
        let ws = Workspace(id: wsId, name: "default", terminals: [
            TerminalRecord(id: UUID(), name: "F", preset: .shell, command: nil, cwd: "/tmp", isShepherd: false, paddockId: fl.id)], paddocks: [fl])
        let file = paths.workspaceDir(wsId).appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ws).write(to: file)
        let d = try Daemon(config: testConfig(paths, wsId))
        try await d.start()
        do {
            let r = try await update(d, paths, "F", ["cwd": .string("/")])
            #expect(r.error?.code == .invalidArgs && r.error?.message == "cwd of a paddock terminal follows its paddock", "\(r)")
        } catch { await d.stop(); throw error }
        await d.stop()
    }

    @Test func shepherdFlagIsStrict() async throws {
        try await withDaemon { d, p in
            _ = try await spawn(d, p, "a")
            for bad in ["yes", "TRUE", "1"] {
                #expect(try await update(d, p, "a", ["shepherd": .string(bad)]).error?.code == .invalidArgs, "\(bad)")
            }
            #expect(try await update(d, p, "a", ["shepherd": .string("true")]).ok)
        }
    }

    @Test func emptyNewNameIsRefused() async throws {
        try await withDaemon { d, p in
            _ = try await spawn(d, p, "a")
            #expect(try await update(d, p, "a", ["newName": .string("")]).error?.code == .invalidArgs)
            #expect(try await update(d, p, "a", ["newName": .string("  ")]).error?.code == .invalidArgs)
            #expect(try await update(d, p, "a", ["newName": .string("  x ")]).ok)
            #expect(try await snapshot(d, p).terminals.contains { $0.name == "x" })
            #expect(try await snapshot(d, p).terminals.map(\.name) == ["x"])
        }
    }

    @Test func customNeedsCommand() async throws {
        try await withDaemon { d, p in
            _ = try await spawn(d, p, "a")
            #expect(try await update(d, p, "a", ["preset": .string("custom")]).error?.code == .invalidArgs)
            #expect(try await update(d, p, "a", ["preset": .string("bogus")]).error?.code == .invalidArgs)
            #expect(try await update(d, p, "a", ["preset": .string("custom"), "command": .string("sleep 5")]).ok)
        }
    }

    @Test func restartFlagRelaunchesInPlace() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "a"); _ = try await spawn(d, p, "b")
            #expect(try await send(p, Request(id: "c", token: d.adminToken, command: "admin.leash", args: ["a": .string("a"), "b": .string("b")])).ok)
            let uid = try #require(UUID(uuidString: a.id))
            let oldPid = try #require(await d.process(uid)).pid
            let r = try await update(d, p, "a", ["preset": .string("custom"), "command": .string("echo hi; sleep 30"), "restart": .bool(true)])
            #expect(r.ok && flags(r).restarted == true && flags(r).needed == false, "\(r)")
            guard case .object(let o)? = r.result else { return }
            #expect(o["id"] == .string(a.id))
            #expect(await waitFor(10) { await d.scrollbackText(uid).contains("hi") })
            #expect(try await #require(await d.process(uid)).pid != oldPid)
            let s = try await snapshot(d, p)
            #expect(s.connections.count == 1 && s.terminals.first { $0.id == uid }?.preset == .custom)
        }
    }

    @Test func updateEmitsTerminalEvent() async throws {
        try await withDaemon { d, p in
            _ = try await spawn(d, p, "a")
            let ev = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            defer { ev.close() }
            #expect(try await update(d, p, "a", ["newName": .string("z")]).ok)
            var got = false
            while !got, case .event(let e)? = try await ev.next(timeoutSeconds: 30) {
                if case .terminal(let r) = e, r.name == "z" { got = true }
            }
            #expect(got)
        }
    }
}
