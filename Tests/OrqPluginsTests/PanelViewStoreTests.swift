import AppKit
import Testing
import Foundation
import OrqCore
import OrqProtocol
@testable import OrqPlugins

@MainActor private final class Probe: PluginPanelView {
    static var received: [String] = []
    static var closed: [UUID] = [], removed: [UUID] = [], reconciled: [[UUID]] = []
    let panel: Panel
    let view = NSView()
    init(panel: Panel, host: PanelHostContext) { self.panel = panel }
    func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        guard command == "echo" else { throw ProtocolError(code: .invalidArgs, message: "bad") }
        return .object(["panel": .string(panel.name)])
    }
    static func panelRemoved(_ panel: Panel, host: PanelHostContext) { removed.append(panel.id) }
    static func reconcile(livePanels: [Panel], host: PanelHostContext) { reconciled.append(livePanels.map(\.id)) }
    func close() { Self.closed.append(panel.id) }
    func receive(event: String, payload: JSONValue) { Self.received.append("\(panel.name):\(event)") }
}

@MainActor @Suite(.serialized) struct PanelViewStoreTests {
    func store(_ ps: [Panel]) -> (PanelViewStore, () -> Void) {
        PluginViews.register("probe", Probe.self)
        var current = ps
        let s = PanelViewStore(panels: { current }) { PanelHostContext(panel: $0, root: URL(fileURLWithPath: "/tmp"), workspaceId: nil, call: { _, _ in .null }, emit: { _, _ in }) }
        return (s, { current = [] })
    }
    let a = Panel(id: UUID(), name: "a", pluginId: "probe", placement: .dockRight)
    let ghost = Panel(id: UUID(), name: "g", pluginId: "nope", placement: .canvas)

    @Test func createsOnDemandAndDispatches() async throws {
        let (s, _) = store([a, ghost])
        let r = try await s.dispatch(a.id, "echo", [:])
        #expect(r == .object(["panel": .string("a")]))
        #expect(s.instance(for: a.id) === s.instance(for: a.id))   // one instance, kept
        do { _ = try await s.dispatch(UUID(), "echo", [:]); Issue.record("expected notFound") }
        catch { #expect(error.code == .notFound) }
        do { _ = try await s.dispatch(ghost.id, "echo", [:]); Issue.record("expected unavailable") }
        catch { #expect(error.code == .unavailable && error.message == "Plug-in indisponível") }
        do { _ = try await s.dispatch(a.id, "x", [:]); Issue.record("expected invalidArgs") }
        catch { #expect(error.code == .invalidArgs) }
    }

    @Test func storeDeliversToLiveView() {
        Probe.received = []
        let b = Panel(id: UUID(), name: "d", pluginId: "probe", placement: .canvas)
        let (s, _) = store([b])
        s.deliver(panel: b.id, event: "x", payload: .null)   // no view yet: dropped, and none is created
        #expect(Probe.received.isEmpty)
        _ = s.instance(for: b.id)
        s.deliver(panel: b.id, event: "x", payload: .null)
        #expect(Probe.received == ["d:x"])
    }

    @Test func releasesWhenPanelIsGone() {
        let (s, clear) = store([a])
        _ = s.instance(for: a.id)
        s.sync([a])
        #expect(!Probe.closed.contains(a.id))
        clear(); s.sync([])
        #expect(Probe.closed.contains(a.id) && Probe.removed.contains(a.id))
        #expect(s.instance(for: a.id) == nil)
    }

    @Test func closeAllClosesWithoutRemoval() {
        let b = Panel(id: UUID(), name: "b", pluginId: "probe", placement: .canvas)
        let (s, _) = store([b])
        _ = s.instance(for: b.id)
        s.closeAll()
        #expect(Probe.closed.contains(b.id) && !Probe.removed.contains(b.id))
    }

    @Test func removalOfNeverInstantiatedPanelCallsStaticHook() {
        let c = Panel(id: UUID(), name: "c", pluginId: "probe", placement: .dockLeft)
        let (s, _) = store([c])
        s.sync([c])   // baseline; no view was ever created
        s.sync([])
        #expect(Probe.removed.contains(c.id) && !Probe.closed.contains(c.id))
    }

    @Test func sessionStartReconcilesOnceWithLivePanels() {
        let d = Panel(id: UUID(), name: "d", pluginId: "probe", placement: .dockLeft)
        let (s, _) = store([d, ghost])
        let before = Probe.reconciled.count
        s.sessionStarted([d, ghost])
        #expect(Probe.reconciled.count == before + 1 && Probe.reconciled.last == [d.id])
    }

    @Test func dispatchWaitsForMirror() async throws {
        PluginViews.register("probe", Probe.self)
        let late = Panel(id: UUID(), name: "late", pluginId: "probe", placement: .dockRight)
        var list: [Panel] = []
        let s = PanelViewStore(panels: { list }) { PanelHostContext(panel: $0, root: URL(fileURLWithPath: "/tmp"), workspaceId: nil, call: { _, _ in .null }, emit: { _, _ in }) }
        Task { try? await Task.sleep(for: .milliseconds(200)); list = [late] }
        let r = try await s.dispatch(late.id, "echo", [:])
        #expect(r == .object(["panel": .string("late")]))
    }
}
