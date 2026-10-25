import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String }

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
private func panelNames(_ r: Response) -> [String] {
    guard case .array(let rows)? = r.result else { return ["<\(r)>"] }
    return rows.compactMap { if case .object(let o) = $0, case .string(let n)? = o["name"] { return n }; return nil }.sorted()
}
private func eventsOf(_ r: Response) -> (seq: Int, events: [[String: JSONValue]]) {
    guard case .object(let o)? = r.result, case .number(let s)? = o["seq"], case .array(let es)? = o["events"] else { return (-1, []) }
    return (Int(s), es.compactMap { if case .object(let e) = $0 { return e }; return nil })
}
private func leashed(_ s: WorkspaceSnapshot, _ a: UUID, _ b: UUID) -> Bool {
    s.connections.contains { Set([$0.a, $0.b]) == Set([a, b]) }
}

@Suite(.serialized) struct PanelCommandTests {
    @Test func shepherdOpensCanvasPanelWithLeash() async throws {
        try await withDaemon { d, p in
            let m = try await term(d, p, "M", shepherd: true)
            let r = try await call(p, m, "panel.open", ["plugin": "browser", "placement": "canvas", "url": "https://x.dev"])
            guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
            #expect(o["name"] == .string("browser-1") && o["placement"] == .string("canvas"), "\(r)")
            let s = try await snapshot(d, p)
            let pn = try #require(s.panels.first)
            #expect(pn.createdBy?.uuidString == m.id && pn.state["url"] == .string("https://x.dev")
                    && pn.state["storage"] == .string("isolated"))
            #expect(leashed(s, UUID(uuidString: m.id)!, pn.id))
            #expect(panelNames(try await call(p, m, "panel.list")) == ["browser-1"])
            // next default name takes the lowest free n
            #expect(panelNames(try await admin(d, p, "panel.list")) == ["browser-1"])
            let r2 = try await call(p, m, "panel.open", ["plugin": "browser"])
            guard case .object(let o2)? = r2.result else { Issue.record("\(r2)"); return }
            #expect(o2["name"] == .string("browser-2") && o2["placement"] == .string("dock.right"))
            #expect(try await call(p, m, "panel.open", ["plugin": "nope"]).error?.code == .notFound)
            #expect(try await call(p, m, "panel.open", ["plugin": "browser", "storage": "x"]).error?.code == .invalidArgs)
        }
    }

    /// A Diagram panel carries its project (`root`) and the requested file; the app resolves the file in it.
    @Test func diagramPanelCarriesProjectRoot() async throws {
        try await withDaemon { d, p in
            #expect(try await admin(d, p, "panel.open", ["plugin": "diagram"]).error?.code == .invalidArgs)   // no project yet
            let m = try await term(d, p, "M", shepherd: true)
            let r = try await call(p, m, "panel.open", ["plugin": "diagram", "file": "docs/a.drawio"])
            #expect(r.error == nil, "\(r)")
            let tmp = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path
            let s = try await snapshot(d, p)
            let pn = try #require(s.panels.first { $0.pluginId == "diagram" })
            #expect(pn.state["file"] == .string("docs/a.drawio") && pn.placement == .canvas)
            // R9: a bad --file is refused at open (outside the project, wrong extension), nothing opened
            for bad in ["../x.drawio", "/etc/x.drawio", "notes.txt"] {
                let e = try await call(p, m, "panel.open", ["plugin": "diagram", "file": bad]).error
                #expect(e?.code == .invalidArgs && (e?.message.contains("projeto") == true || e?.message.contains(".drawio") == true), "\(bad): \(String(describing: e))")
            }
            #expect(try await snapshot(d, p).panels.count(where: { $0.pluginId == "diagram" }) == 1)
            guard case .string(let root)? = pn.state["root"] else { Issue.record("no root: \(pn.state)"); return }
            #expect(URL(fileURLWithPath: root).resolvingSymlinksInPath().path == tmp, "\(root)")
            let r2 = try await admin(d, p, "panel.open", ["plugin": "diagram", "placement": "dock.right"])   // the pasture terminal's project
            #expect(r2.error == nil, "\(r2)")
            let s2 = try await snapshot(d, p)
            #expect(s2.panels.filter { $0.pluginId == "diagram" }.allSatisfy { $0.state["root"] != nil })
        }
    }

    @Test func adminCanvasPanelTakesPaddockArg() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            #expect(try await admin(d, p, "paddock.create", ["name": "f1", "repo": repo.path]).ok)
            let fid = try #require(try await snapshot(d, p).paddocks.first?.id)
            #expect(try await admin(d, p, "panel.open", ["plugin": "browser", "name": "w1", "placement": "canvas", "paddock": "f1"]).ok)
            #expect(try await admin(d, p, "panel.open", ["plugin": "browser", "name": "w2", "placement": "canvas"]).ok)
            #expect(try await admin(d, p, "panel.open", ["plugin": "browser", "name": "w3", "placement": "canvas", "paddock": "nope"]).error?.code == .notFound)
            #expect(try await admin(d, p, "panel.open", ["plugin": "browser", "name": "w4"]).ok)
            #expect(try await admin(d, p, "panel.move", ["name": "w4", "placement": "canvas", "paddock": "f1"]).ok)
            let byName = Dictionary(uniqueKeysWithValues: try await snapshot(d, p).panels.map { ($0.name, $0.paddockId) })
            #expect(byName["w1"] == fid && byName["w2"] == .some(nil) && byName["w4"] == fid, "\(byName)")
        }
    }

    @Test func paddockDeleteMovesItsCanvasPanelsToPasture() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            #expect(try await admin(d, p, "paddock.create", ["name": "f1", "repo": repo.path]).ok)
            #expect(try await admin(d, p, "panel.open", ["plugin": "browser", "name": "w1", "placement": "canvas", "paddock": "f1"]).ok)
            #expect(try await snapshot(d, p).panels.first?.paddockId != nil)
            #expect(try await admin(d, p, "paddock.delete", ["name": "f1"]).ok)
            let s = try await snapshot(d, p)
            #expect(s.paddocks.isEmpty && s.panels.map(\.name) == ["w1"] && s.panels.first?.paddockId == nil, "\(s.panels)")
        }
    }

    @Test func loadMovesPanelsOnMissingPaddocksToPasture() async throws {
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let wsId = UUID()
        let d1 = try Daemon(config: testConfig(paths, wsId))
        try await d1.start()
        do {
            #expect(try await admin(d1, paths, "panel.open", ["plugin": "browser", "name": "web", "placement": "canvas"]).ok)
        } catch { await d1.stop(); throw error }
        await d1.stop()
        let file = paths.workspaceDir(wsId).appendingPathComponent("workspace.json")
        var ws = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: file))
        ws.panels[0].paddockId = UUID()   // a paddock that doesn't exist (pre-fix paddock.delete)
        try JSONEncoder().encode(ws).write(to: file)
        let d2 = try Daemon(config: testConfig(paths, wsId))
        try await d2.start()
        do {
            let s = try await snapshot(d2, paths)
            #expect(s.panels.map(\.name) == ["web"] && s.panels.first?.paddockId == nil, "\(s.panels)")
        } catch { await d2.stop(); throw error }
        await d2.stop()
    }

    @Test func creatorMovingDockPanelOntoCanvasGetsLeash() async throws {
        try await withDaemon { d, p in
            let m = try await term(d, p, "M", shepherd: true)
            #expect(try await call(p, m, "panel.open", ["plugin": "browser", "name": "web"]).ok)
            #expect(try await snapshot(d, p).connections.isEmpty)
            let r = try await call(p, m, "panel.move", ["name": "web", "placement": "canvas"])
            #expect(r.ok, "\(r)")
            let s = try await snapshot(d, p)
            let pn = try #require(s.panels.first)
            #expect(pn.placement == .canvas && leashed(s, UUID(uuidString: m.id)!, pn.id))
            #expect(panelNames(try await call(p, m, "panel.list")) == ["web"])
        }
    }

    @Test func dockPanelIsGlobal() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            #expect(try await admin(d, p, "panel.open", ["plugin": "browser", "name": "web"]).ok)
            #expect(panelNames(try await call(p, a, "panel.list")) == ["web"])
            #expect(try await snapshot(d, p).connections.isEmpty)
        }
    }

    @Test func canvasPanelNeedsLeash() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            #expect(try await admin(d, p, "panel.open", ["plugin": "browser", "name": "web", "placement": "canvas"]).ok)
            #expect(panelNames(try await call(p, a, "panel.list")) == [])
            #expect(try await call(p, a, "events", ["panel": "web"]).error?.code == .notConnected)
            #expect(try await admin(d, p, "admin.leash", ["a": "web", "b": "A"]).ok)
            #expect(panelNames(try await call(p, a, "panel.list")) == ["web"])
        }
    }

    @Test func nonShepherdCannotOpen() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            #expect(try await admin(d, p, "panel.open", ["plugin": "browser", "name": "web"]).ok)
            for (cmd, args) in [("panel.open", ["plugin": "memory"]), ("panel.close", ["name": "web"]),
                                ("panel.move", ["name": "web", "placement": "canvas"])] {
                let r = try await call(p, a, cmd, args)
                #expect(r.error?.code == .notShepherd, "\(cmd): \(r)")
            }
            #expect(try await snapshot(d, p).panels.map(\.name) == ["web"])
        }
    }

    @Test func panelNameCollidesWithTerminal() async throws {
        try await withDaemon { d, p in
            let m = try await term(d, p, "M", shepherd: true)
            #expect(try await call(p, m, "panel.open", ["plugin": "browser", "name": "m"]).error?.code == .invalidArgs)
            #expect(try await call(p, m, "panel.open", ["plugin": "browser", "name": "web"]).ok)
            #expect(try await call(p, m, "panel.open", ["plugin": "browser", "name": "WEB"]).error?.code == .invalidArgs)
            // and the other way: a terminal can't take a panel's name
            #expect(try await call(p, m, "summon", ["name": "Web", "preset": "shell"]).error?.code == .invalidArgs)
            #expect(try await admin(d, p, "admin.spawn", ["name": "web", "preset": "shell"]).error?.code == .invalidArgs)
            #expect(try await snapshot(d, p).terminals.map(\.name) == ["M"])
        }
    }

    @Test func placementMustBeAllowed() async throws {
        try await withDaemon { d, p in
            let bad = try await admin(d, p, "panel.open", ["plugin": "browser", "placement": "floating"])
            #expect(bad.error?.code == .invalidArgs)
            #expect(try await admin(d, p, "panel.open", ["plugin": "browser", "name": "web"]).ok)
            #expect(try await admin(d, p, "panel.move", ["name": "web", "placement": "nowhere"]).error?.code == .invalidArgs)
            #expect(try await admin(d, p, "panel.move", ["name": "web", "placement": "dock.bottom"]).ok)
            #expect(try await snapshot(d, p).panels.first?.placement == .dockBottom)
        }
    }

    @Test func connectTerminalToCanvasPanel() async throws {
        try await withDaemon { d, p in
            let m = try await term(d, p, "M", shepherd: true)
            #expect(try await call(p, m, "summon", ["name": "W", "preset": "shell"]).ok)
            #expect(try await call(p, m, "panel.open", ["plugin": "browser", "name": "web", "placement": "canvas"]).ok)
            #expect(try await admin(d, p, "admin.spawn", ["name": "X", "preset": "shell"]).ok)
            // Shepherd: both ends must be in reach
            #expect(try await call(p, m, "leash", ["a": "X", "b": "web"]).error?.code == .notConnected)
            #expect(try await call(p, m, "leash", ["a": "W", "b": "web"]).ok)
            var s = try await snapshot(d, p)
            let w = try #require(s.terminals.first { $0.name == "W" }), pn = try #require(s.panels.first)
            #expect(leashed(s, w.id, pn.id))
            #expect(try await call(p, m, "unleash", ["a": "web", "b": "W"]).ok)
            s = try await snapshot(d, p)
            #expect(!leashed(s, w.id, pn.id))
            // admin: panel<->panel refused
            #expect(try await admin(d, p, "panel.open", ["plugin": "browser", "name": "web2", "placement": "canvas"]).ok)
            #expect(try await admin(d, p, "admin.leash", ["a": "web", "b": "web2"]).error?.code == .invalidArgs)
            #expect(try await admin(d, p, "admin.leash", ["a": "X", "b": "web2"]).ok)
            #expect(try await admin(d, p, "admin.unleash", ["a": "X", "b": "web2"]).ok)
        }
    }

    @Test func dockPanelRefusesLeash() async throws {
        try await withDaemon { d, p in
            _ = try await term(d, p, "A")
            #expect(try await admin(d, p, "panel.open", ["plugin": "browser", "name": "web"]).ok)
            let r = try await admin(d, p, "admin.leash", ["a": "A", "b": "web"])
            #expect(r.error == ProtocolError(code: .invalidArgs, message: "dock panels need no leash"), "\(r)")
        }
    }

    @Test func closeRemovesLeashesAndEmits() async throws {
        try await withDaemon { d, p in
            let ev = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            defer { ev.close() }
            let m1 = try await term(d, p, "M1", shepherd: true)
            let m2 = try await term(d, p, "M2", shepherd: true)
            #expect(try await call(p, m1, "panel.open", ["plugin": "browser", "name": "web", "placement": "canvas"]).ok)
            let pid = try #require(try await snapshot(d, p).panels.first?.id)
            // another Shepherd, neither creator nor leashed, can't close or move it
            #expect(try await call(p, m2, "panel.close", ["name": "web"]).error?.code == .notShepherd)
            #expect(try await call(p, m2, "panel.move", ["name": "web", "placement": "dock.left"]).error?.code == .notShepherd)
            #expect(try await call(p, m1, "panel.close", ["name": "web"]).ok)
            let s = try await snapshot(d, p)
            #expect(s.panels.isEmpty && s.connections.isEmpty)
            var gone = false, cut = false
            while !gone, case .event(let e)? = try await ev.next(timeoutSeconds: 30) {
                if case .disconnected(let c) = e, c.a == pid || c.b == pid { cut = true }
                if case .panelRemoved(let id) = e, id == pid { gone = true }
            }
            #expect(gone && cut)
            #expect(try await call(p, m1, "panel.close", ["name": "web"]).error?.code == .notFound)
            // admin.kill also closes panels
            #expect(try await admin(d, p, "panel.open", ["plugin": "browser", "name": "dock"]).ok)
            #expect(try await admin(d, p, "admin.kill", ["target": "dock"]).ok)
            #expect(try await snapshot(d, p).panels.isEmpty)
        }
    }

    @Test func panelsSurviveRestart() async throws {
        let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let wsId = UUID()
        let d1 = try Daemon(config: testConfig(paths, wsId))
        try await d1.start()
        do {
            #expect(try await admin(d1, paths, "panel.open", ["plugin": "browser", "name": "web", "url": "https://a.b"]).ok)
        } catch { await d1.stop(); throw error }
        await d1.stop()
        let d2 = try Daemon(config: testConfig(paths, wsId))
        try await d2.start()
        do {
            let s = try await snapshot(d2, paths)
            #expect(s.panels.map(\.name) == ["web"] && s.panels.first?.state["url"] == .string("https://a.b"))
        } catch { await d2.stop(); throw error }
        await d2.stop()
    }

    @Test func eventsRingIsBoundedAndFiltered() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            #expect(try await admin(d, p, "panel.open", ["plugin": "browser", "name": "dock"]).ok)
            #expect(try await admin(d, p, "panel.open", ["plugin": "browser", "name": "web", "placement": "canvas"]).ok)
            let s = try await snapshot(d, p)
            let dock = try #require(s.panels.first { $0.name == "dock" }), web = try #require(s.panels.first { $0.name == "web" })
            for i in 0..<250 { await d.router.record(panel: web.id, name: "browser.console", payload: .number(Double(i))) }
            await d.router.record(panel: dock.id, name: "browser.loaded", payload: .object(["url": .string("u")]))
            let all = eventsOf(try await admin(d, p, "events"))
            #expect(all.seq == 251 && all.events.count == 201)
            let webEvents = all.events.filter { $0["panel"] == .string("web") }
            #expect(webEvents.count == 200 && webEvents.first?["payload"] == .number(50) && webEvents.first?["seq"] == .number(51))
            // terminal without a leash sees only the dock panel's event
            let mine = eventsOf(try await call(p, a, "events"))
            #expect(mine.seq == 251 && mine.events.count == 1 && mine.events.first?["name"] == .string("browser.loaded"))
            #expect(eventsOf(try await call(p, a, "events", ["since": "251"])).events.isEmpty)
            #expect(try await admin(d, p, "admin.leash", ["a": "A", "b": "web"]).ok)
            #expect(eventsOf(try await call(p, a, "events", ["since": "240", "panel": "web"])).events.count == 10)
        }
    }
}

@Test func snapshotReportsBuildStably() async throws {
    try await withDaemon(configure: { $0.build = "0123456789abcdef" }) { d, p in
        let a = try await snapshot(d, p), b = try await snapshot(d, p)
        #expect(a.build == "0123456789abcdef" && a.build == b.build)
    }
}
