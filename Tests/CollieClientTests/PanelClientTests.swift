import Testing
import Foundation
import CollieCanvas
import CollieCore
import CollieProtocol
@testable import CollieClient

@MainActor @Suite(.serialized) struct PanelClientTests {
    let dock = Panel(id: UUID(), name: "d", pluginId: "browser", placement: .dockRight)
    let canvas = Panel(id: UUID(), name: "c", pluginId: "browser", placement: .canvas, paddockId: nil)

    @Test func appliesPanelEvents() {
        let c = DaemonClient()
        c.apply(.panel(dock)); c.apply(.panel(canvas))
        #expect(c.panels == [dock, canvas])
        var moved = dock; moved.placement = .dockLeft
        c.apply(.panel(moved))   // upsert
        #expect(c.panels == [moved, canvas])
        let t = UUID()
        c.apply(.connected(Connection(a: t, b: canvas.id)))   // a panel end is fine
        #expect(c.connections.count == 1)
        c.apply(.panelRemoved(canvas.id))
        #expect(c.panels == [moved] && c.connections.isEmpty)
        c.apply(.pluginEvent(panel: dock.id, name: "x", payload: .null))   // ignored
        #expect(c.panels == [moved])
    }

    @Test func pluginCallsGetTheirOwnTimeoutPlusMargin() {
        // past the daemon's own deadline (the spec's less 2 s): its typed timeout arrives first
        for c in ["design.system.create", "design.system.publish", "design.system.use", "design.system.undo", "design.system.revert"] {
            #expect(DaemonClient.adminTimeout(c) == 125, "\(c)")
        }
        #expect(DaemonClient.adminTimeout("design.new") == 65 && DaemonClient.adminTimeout("design.files") == 15)
        #expect(DaemonClient.adminTimeout("not.a.command") == 30 && DaemonClient.adminTimeout("paddock.list") == 30)
    }

    @Test func visiblePanelsFiltersCanvasByPaddock() {
        let f = UUID()
        var onPaddock = canvas; onPaddock.paddockId = f
        let all = [dock, canvas, onPaddock]
        #expect(visiblePanels(all, paddock: nil) == [dock, canvas])
        #expect(visiblePanels(all, paddock: f) == [dock, onPaddock])
        #expect(visiblePanels(all, paddock: UUID()) == [dock])   // docks always
    }

    @Test func layoutKeepsPanelFrames() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("collie-\(UUID().uuidString)/layout.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let f = LayoutFile(offset: .zero, zoom: 1, frames: [canvas.id: CGRect(x: 10, y: 20, width: 640, height: 400)])
        try LayoutStore.save(f, to: url)
        #expect(LayoutStore.load(url) == f)
    }

    @Test func clientForwardsPluginEvents() {
        let c = DaemonClient(paths: Paths(root: URL(fileURLWithPath: "/tmp/none")))
        var got: [(UUID, String, JSONValue)] = []
        c.pluginEventHandler = { got.append(($0, $1, $2)) }
        let id = UUID()
        c.apply(.pluginEvent(panel: id, name: "artifact.imported", payload: .object(["id": .string("a")])))
        #expect(got.count == 1 && got[0].0 == id && got[0].1 == "artifact.imported" && got[0].2 == .object(["id": .string("a")]))
    }

    @Test func mirrorsPanelsAndRoutesHostCalls() async throws {
        let d = Collied(); defer { d.cleanup() }
        try await d.start()
        let c = DaemonClient(paths: d.paths)
        c.panelHandler = { panel, command, args, _ throws(ProtocolError) in
            .object(["cmd": .string(command), "panel": .string(panel.uuidString)])
        }
        c.start(); defer { c.stop() }
        #expect(await poll(5) { c.state == .connected && c.hostStatus == .connected })
        #expect(c.workspaceId != nil)
        try await c.openPanel(plugin: "browser", name: "web", placement: .dockLeft, url: "https://x.dev", storage: .workspace)
        #expect(await poll(2) { c.panels.map(\.name) == ["web"] })
        let p = try #require(c.panels.first)
        #expect(p.placement == .dockLeft && p.state["storage"] == .string("workspace") && p.state["url"] == .string("https://x.dev"))
        // the daemon forwards a plugin command to the handler
        let token = try DaemonClient.readToken(d.paths)
        let r = try await UnixSocketClient.send(Request(id: "x", token: token, command: "browser.snapshot", args: ["panel": .string("web")]),
                                                to: d.paths.socket, timeoutSeconds: 10)
        #expect(r.result == .object(["cmd": .string("browser.snapshot"), "panel": .string(p.id.uuidString)]), "\(r)")
        try await c.movePanel("web", to: .canvas)
        #expect(await poll(2) { c.panels.first?.placement == .canvas })
        try await c.closePanel("web")
        #expect(await poll(2) { c.panels.isEmpty })
    }

    @Test func secondClientReplacesHostAndResumeTakesItBack() async throws {
        let d = Collied(); defer { d.cleanup() }
        try await d.start()
        let a = DaemonClient(paths: d.paths); a.start(); defer { a.stop() }
        #expect(await poll(5) { a.hostStatus == .connected })
        let b = DaemonClient(paths: d.paths); b.start(); defer { b.stop() }
        #expect(await poll(5) { a.hostStatus == .replaced && b.hostStatus == .connected })
        a.resumeHost()
        #expect(await poll(5) { a.hostStatus == .connected && b.hostStatus == .replaced })
    }
}
