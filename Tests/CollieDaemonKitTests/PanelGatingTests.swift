import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Tester browsers: a non-Shepherd terminal opens browsers only (headless by default, `--visible` on the canvas),
/// leashed to it, at most 8; headless ones are seen only by their creator, the admin and the creator's leashed
/// Shepherd, and close with their creator.
private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, shepherd: Bool = false) async throws -> Term {
    let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn",
        args: ["name": .string(name), "preset": .string("shell"), "cwd": .string("/tmp"), "shepherd": .bool(shepherd)]),
        to: p.socket, timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func snapshot(_ d: Daemon, _ p: Paths) async throws -> WorkspaceSnapshot {
    let r = try await admin(d, p, "ui.snapshot")
    return try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(r.result))
}
private func names(_ r: Response) -> [String] {
    guard case .array(let rows)? = r.result else { return ["<\(r)>"] }
    return rows.compactMap { if case .object(let o) = $0, case .string(let n)? = o["name"] { return n }; return nil }.sorted()
}
private func leashed(_ s: WorkspaceSnapshot, _ a: UUID, _ b: UUID) -> Bool { s.connections.contains { Set([$0.a, $0.b]) == Set([a, b]) } }

@Suite(.serialized) struct PanelGatingTests {
    @Test func testerOpensHeadlessBrowser() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            let r = try await call(p, a, "panel.open", ["plugin": "browser", "name": "qa", "url": "https://x.dev"])
            guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
            #expect(o["placement"] == .string("headless"), "\(r)")
            let s = try await snapshot(d, p), pn = try #require(s.panels.first)
            #expect(pn.placement == .headless && pn.paddockId == nil && pn.createdBy == a.uuid && pn.state["url"] == .string("https://x.dev"))
            #expect(leashed(s, a.uuid, pn.id))
            #expect(names(try await call(p, a, "panel.list")) == ["qa"])
            // nobody else can leash to it; it never moves
            _ = try await term(d, p, "B")
            #expect(try await admin(d, p, "admin.leash", ["a": "B", "b": "qa"]).error?.code == .invalidArgs)
            #expect(try await call(p, a, "panel.move", ["name": "qa", "placement": "canvas"]).error?.code == .invalidArgs)
            // the admin has no terminal to close it with
            #expect(try await admin(d, p, "panel.open", ["plugin": "browser", "placement": "headless"]).error?.code == .invalidArgs)
            #expect(try await call(p, a, "panel.close", ["name": "qa"]).ok)
            #expect(try await snapshot(d, p).panels.isEmpty)
        }
    }

    @Test func testerOpensVisibleBrowserLeashed() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            #expect(try await admin(d, p, "paddock.create", ["name": "f1", "repo": repo.path]).ok)
            let fid = try #require(try await snapshot(d, p).paddocks.first?.id)
            let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn",
                args: ["name": .string("A"), "preset": .string("shell"), "paddock": .string("f1")]), to: p.socket, timeoutSeconds: 60)
            guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { Issue.record("\(r)"); return }
            let a = Term(id: id, token: try await tokenOf(d, id))
            #expect(try await call(p, a, "panel.open", ["plugin": "browser", "name": "qa", "visible": "true"]).ok)
            let s = try await snapshot(d, p), pn = try #require(s.panels.first)
            #expect(pn.placement == .canvas && pn.paddockId == fid && leashed(s, a.uuid, pn.id), "\(pn)")
            // its own: moves on the canvas only, closes
            #expect(try await call(p, a, "panel.move", ["name": "qa", "placement": "dock.left"]).error?.code == .notShepherd)
            #expect(try await call(p, a, "panel.move", ["name": "qa", "placement": "canvas"]).ok)
            // a tester can't pick a dock
            #expect(try await call(p, a, "panel.open", ["plugin": "browser", "placement": "dock.right"]).error?.code == .notShepherd)
            // a visible one stays when its terminal exits (only headless ones go)
            try await d.process(a.uuid)?.write(Data("exit\n".utf8))
            #expect(await waitFor(10) { await d.process(a.uuid)?.isRunning == false })
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await snapshot(d, p).panels.map(\.name) == ["qa"])
        }
    }

    @Test func testerCannotOpenOtherPlugins() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            for plugin in ["design", "device", "memory"] {
                let r = try await call(p, a, "panel.open", ["plugin": plugin, "file": "F"])
                #expect(r.error?.code == .notShepherd, "\(plugin): \(r)")
            }
            #expect(try await snapshot(d, p).panels.isEmpty)
        }
    }

    @Test func testerSeesOnlyOwnHeadless() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A"), b = try await term(d, p, "B")
            let m = try await term(d, p, "M", shepherd: true), m2 = try await term(d, p, "M2", shepherd: true)
            #expect(try await admin(d, p, "admin.leash", ["a": "M", "b": "A"]).ok)
            #expect(try await call(p, a, "panel.open", ["plugin": "browser", "name": "qa"]).ok)
            #expect(names(try await call(p, b, "panel.list")) == [])
            #expect(names(try await call(p, m2, "panel.list")) == [])
            #expect(names(try await call(p, m, "panel.list")) == ["qa"])   // the creator's leashed Shepherd
            #expect(names(try await admin(d, p, "panel.list")) == ["qa"])
            // B can't drive or close it; A's other browsers don't count against B
            #expect(try await call(p, b, "browser.snapshot", ["panel": "qa"]).error?.code == .notConnected)
            #expect(try await call(p, b, "panel.close", ["name": "qa"]).error?.code == .notShepherd)
            #expect(try await call(p, m, "panel.close", ["name": "qa"]).error?.code == .notShepherd)
            #expect(try await call(p, b, "panel.open", ["plugin": "browser", "name": "qb"]).ok)
            #expect(names(try await call(p, b, "panel.list")) == ["qb"])
            #expect(names(try await call(p, a, "panel.list")) == ["qa"])
        }
    }

    @Test func testerCap8() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            for i in 0..<4 { #expect(try await call(p, a, "panel.open", ["plugin": "browser", "name": "h\(i)"]).ok) }
            for i in 0..<4 { #expect(try await call(p, a, "panel.open", ["plugin": "browser", "name": "v\(i)", "visible": "true"]).ok) }
            let r = try await call(p, a, "panel.open", ["plugin": "browser", "name": "h9"])
            #expect(r.error?.code == .tooMany, "\(r)")
            #expect(try await call(p, a, "panel.close", ["name": "h0"]).ok)
            #expect(try await call(p, a, "panel.open", ["plugin": "browser", "name": "h9"]).ok)
            #expect(try await snapshot(d, p).panels.count == 8)
        }
    }

    @Test func headlessClosesWithCreator() async throws {
        try await withDaemon { d, p in
            let ev = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            defer { ev.close() }
            let a = try await term(d, p, "A"), b = try await term(d, p, "B")
            #expect(try await call(p, a, "panel.open", ["plugin": "browser", "name": "qa"]).ok)
            #expect(try await call(p, b, "panel.open", ["plugin": "browser", "name": "qb"]).ok)
            let s = try await snapshot(d, p)
            let qa = try #require(s.panels.first { $0.name == "qa" }), qb = try #require(s.panels.first { $0.name == "qb" })
            let screens = p.root.appendingPathComponent("screens")
            try FileManager.default.createDirectory(at: screens, withIntermediateDirectories: true)
            let shotA = screens.appendingPathComponent("\(qa.id.uuidString)-1.png"), shotB = screens.appendingPathComponent("\(qb.id.uuidString)-1.png")
            let other = screens.appendingPathComponent("\(UUID().uuidString)-1.png")
            for f in [shotA, shotB, other] { try Data("png".utf8).write(to: f) }
            // removed
            #expect(try await admin(d, p, "admin.kill", ["target": "A"]).ok)
            #expect(try await snapshot(d, p).panels.map(\.name) == ["qb"])
            #expect(!FileManager.default.fileExists(atPath: shotA.path))
            var gone = false
            while !gone, case .event(let e)? = try await ev.next(timeoutSeconds: 30) { if case .panelRemoved(let id) = e, id == qa.id { gone = true } }
            #expect(gone)
            // its process exits
            try await d.process(b.uuid)?.write(Data("exit\n".utf8))
            #expect(await waitFor(10) { (try? await snapshot(d, p).panels.isEmpty) == true })
            #expect(!FileManager.default.fileExists(atPath: shotB.path) && FileManager.default.fileExists(atPath: other.path))
            #expect(try await snapshot(d, p).connections.isEmpty)
        }
    }

    @Test func shepherdRulesUnchanged() async throws {
        try await withDaemon { d, p in
            let m = try await term(d, p, "M", shepherd: true), m2 = try await term(d, p, "M2", shepherd: true)
            // any plugin, default placement (dock), canvas leashed, no cap
            for i in 0..<9 { #expect(try await call(p, m, "panel.open", ["plugin": "browser", "name": "d\(i)"]).ok) }
            #expect(try await call(p, m, "panel.open", ["plugin": "memory", "name": "mem"]).ok)
            #expect(try await call(p, m, "panel.open", ["plugin": "browser", "name": "c", "placement": "canvas"]).ok)
            var s = try await snapshot(d, p)
            #expect(s.panels.first { $0.name == "d0" }?.placement == .dockRight)
            #expect(leashed(s, m.uuid, try #require(s.panels.first { $0.name == "c" }).id))
            // and headless on request: listed to it, not to another Shepherd; closed with it
            #expect(try await call(p, m, "panel.open", ["plugin": "browser", "name": "h", "placement": "headless"]).ok)
            #expect(names(try await call(p, m, "panel.list")).contains("h"))
            #expect(!names(try await call(p, m2, "panel.list")).contains("h"))
            #expect(try await call(p, m2, "panel.close", ["name": "c"]).error?.code == .notShepherd)
            #expect(try await call(p, m2, "panel.move", ["name": "d0", "placement": "dock.left"]).error?.code == .notShepherd)
            #expect(try await call(p, m, "panel.move", ["name": "d0", "placement": "dock.left"]).ok)
            #expect(try await admin(d, p, "admin.kill", ["target": "M"]).ok)
            s = try await snapshot(d, p)
            #expect(s.panels.count == 11 && !s.panels.contains { $0.name == "h" }, "\(s.panels.map(\.name))")
        }
    }

    @Test func loadDropsHeadlessAndToleratesUnknownPlacement() async throws {
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let wsId = UUID()
        let d1 = try Daemon(config: testConfig(paths, wsId))
        try await d1.start()
        do {
            let a = try await term(d1, paths, "A")
            #expect(try await call(paths, a, "panel.open", ["plugin": "browser", "name": "qa"]).ok)
            #expect(try await admin(d1, paths, "panel.open", ["plugin": "browser", "name": "web"]).ok)
        } catch { await d1.stop(); throw error }
        await d1.stop()
        let file = paths.workspaceDir(wsId).appendingPathComponent("workspace.json")
        // a newer build's placement
        var json = try String(contentsOf: file, encoding: .utf8)
        json = json.replacingOccurrences(of: #""dock.right""#, with: #""floating""#)
        #expect(json.contains("floating"))
        try json.write(to: file, atomically: true, encoding: .utf8)
        let d2 = try Daemon(config: testConfig(paths, wsId))
        try await d2.start()
        do {
            let s = try await snapshot(d2, paths)
            #expect(s.panels.map(\.name) == ["web"] && s.panels.first?.placement == .canvas, "\(s.panels)")
            #expect(s.connections.isEmpty)   // the headless panel's leash went with it
        } catch { await d2.stop(); throw error }
        await d2.stop()
    }
}
