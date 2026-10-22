import Testing
import Foundation
import OrqProtocol
@testable import OrqCore

@Suite struct PanelModelTests {
    func panel(_ n: String, _ pl: PanelPlacement) -> Panel { Panel(id: UUID(), name: n, pluginId: "browser", placement: pl) }
    func term(_ n: String) -> TerminalRecord { TerminalRecord(id: UUID(), name: n, preset: .shell, command: nil, cwd: "/", isMaestro: false) }

    @Test func decodesV2WorkspaceWithoutPanels() throws {
        let id = UUID()
        let json = #"{"schemaVersion":2,"id":"\#(id)","name":"w","terminals":[],"connections":[],"floors":[]}"#
        let w = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        #expect(w.panels == [])
        #expect(String(decoding: try JSONEncoder().encode(w), as: UTF8.self).contains("\"schemaVersion\":3"))
        let snap = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(#"{"terminals":[],"connections":[],"badges":{}}"#.utf8))
        #expect(snap.panels == [])
    }

    @Test func panelEventsRoundTrip() throws {
        var p = panel("web", .dockRight); p.state = ["url": .string("https://x.dev")]; p.createdBy = UUID()
        let events: [WorkspaceEvent] = [.panel(p), .panelRemoved(p.id), .pluginEvent(panel: p.id, name: "browser.loaded", payload: .object(["url": .string("u")]))]
        for e in events {
            let data = try JSONEncoder().encode(e)
            #expect(try JSONDecoder().decode(WorkspaceEvent.self, from: data) == e)
        }
        let t = String(decoding: try JSONEncoder().encode(events[2]), as: UTF8.self)
        #expect(t.contains("\"t\":\"pluginEvent\""))
        let w = Workspace(id: UUID(), name: "w", panels: [p])
        #expect(try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(w)) == w)
    }

    @Test func canvasPanelReachableOnlyWithCord() {
        let a = term("A"), b = term("B"), c = panel("web", .canvas)
        var w = Workspace(id: UUID(), name: "w", terminals: [a, b], panels: [c])
        #expect(ConnectionGraph.reachablePanels(from: a.id, in: w).isEmpty)
        w.connections = [Connection(a: c.id, b: a.id)]
        #expect(ConnectionGraph.reachablePanels(from: a.id, in: w) == [c])
        #expect(ConnectionGraph.reachablePanels(from: b.id, in: w).isEmpty)
    }

    @Test func dockPanelReachableByAll() {
        let a = term("A"), d = panel("dock", .dockLeft)
        let w = Workspace(id: UUID(), name: "w", terminals: [a], panels: [d])
        #expect(ConnectionGraph.reachablePanels(from: a.id, in: w) == [d])
    }

    @Test func resolvePanelWithoutNameNeedsSingleCandidate() throws {
        let a = term("A"), d1 = panel("one", .dockRight), d2 = panel("two", .dockBottom), far = panel("far", .canvas)
        var w = Workspace(id: UUID(), name: "w", terminals: [a], panels: [far])
        func code(_ n: String?) -> ErrorCode? {
            do { _ = try ConnectionGraph.resolvePanel(name: n, plugin: "browser", from: a.id, in: w); return nil } catch { return error.code }
        }
        #expect(code(nil) == .notFound)
        #expect(code("far") == .notConnected)
        #expect(code("nope") == .notFound)
        w.panels.append(d1)
        #expect(try ConnectionGraph.resolvePanel(name: nil, plugin: "browser", from: a.id, in: w) == d1)
        #expect(try ConnectionGraph.resolvePanel(name: "ONE", plugin: "browser", from: a.id, in: w) == d1)
        w.panels.append(d2)
        #expect(code(nil) == .ambiguous)
        #expect(try ConnectionGraph.resolvePanel(name: "two", plugin: "browser", from: a.id, in: w) == d2)
    }
}
