import Testing
import Foundation
import CoreGraphics
import CollieDevice
import CollieProtocol
@testable import CollieDaemonKit

/// A fake device the way `DeviceService` keeps it: `nodes` are the refs of the last read; a dump reads the current screen,
/// `drift` changes the screen by itself (a timer: no action). A tap resolves its ref in `nodes` at tap time and calls
/// `FlowClassifier.checkPin` there, as `device.tap --ref` does on iOS and Android; `concurrent` is a `device screen` of
/// another client that rewrites the refs between the classification and the tap.
private actor Device {
    var screens: [[UINode]]
    var shown = 0
    var nodes: [UINode]
    var dumps = 0
    var touched: [UINode] = []
    var concurrent: [UINode]?
    init(_ screens: [[UINode]]) { self.screens = screens; nodes = screens[0] }
    func act(_ c: String, _ a: [String: JSONValue]) throws(ProtocolError) -> JSONValue {
        if let c = concurrent { nodes = c }
        if c == "device.tap", case .string(let ref)? = a["ref"] {
            guard let n = nodes.first(where: { $0.ref == ref }) else { throw ProtocolError(code: .notFound, message: "Unknown ref \(ref)") }
            try FlowClassifier.checkPin(a, n)
            touched.append(n)
        }
        shown = min(shown + 1, screens.count - 1)
        return .object([:])
    }
    func drift() { shown = min(shown + 1, screens.count - 1) }
    func rewrite(_ n: [UINode]) { concurrent = n }
    func dump() -> [UINode] { dumps += 1; nodes = screens[shown]; return nodes }
    /// `DeviceService.flowDestructive` over this device.
    func resolve(_ s: FlowPlan.Step) async throws(ProtocolError) -> (destructive: Bool, step: FlowPlan.Step) {
        try await FlowClassifier.resolve(s, nodes: nodes, dump: { () throws(ProtocolError) -> [UINode] in dump() })
    }
}
private func node(_ ref: String, cls: String = "android.view.View", text: String = "", id: String = "", _ r: CGRect,
                  clickable: Bool = false, depth: Int) -> UINode {
    UINode(ref: ref, cls: cls, text: text, desc: "", id: id, bounds: r, clickable: clickable, depth: depth)
}
private func run(_ json: String, _ d: Device) async throws(ProtocolError) -> JSONValue {
    let plan: FlowPlan = try FlowPlan.parse(Data(json.utf8))
    return try await FlowRunner(resolve: { s async throws(ProtocolError) in try await d.resolve(s) }) { c, a async throws(ProtocolError) in
        try await d.act(c, a)
    }.run(plan)
}
private func refused(at: Int) -> JSONValue {
    .object(["ok": .bool(false), "refused": .string("destructive"), "at": .number(Double(at)), "done": .number(Double(at - 1))])
}
private func ran(_ n: Int) -> JSONValue { .object(["ok": .bool(true), "steps": .number(Double(n))]) }
private let full = CGRect(x: 0, y: 0, width: 1080, height: 2400)

/// A container neither clickable nor under a clickable node (`cls`), holding a clickable `label` at its centre.
private func group(_ cls: String, leaf: String, label: String) -> [UINode] {
    [node("e1", cls: cls, full, depth: 0),
     node("e2", cls: cls, CGRect(x: 0, y: 1800, width: 1080, height: 400), depth: 1),
     node("e3", cls: leaf, text: label, CGRect(x: 340, y: 1950, width: 400, height: 100), clickable: true, depth: 2)]
}

/// we1 (review `.collie/briefs/rev-device-flows-onda-d.md`, findings 1-3): the tap touches what was classified.
struct FlowTapPinTests {
    @Test func aScreenThatChangesByItselfIsTappedOnTheNodeClassifiedInTheNewRead() async throws {
        let home = [node("e1", full, depth: 0), node("e2", text: "Voltar", CGRect(x: 0, y: 0, width: 200, height: 100), clickable: true, depth: 1)]
        let pay = [node("e1", full, depth: 0), node("e2", text: "Pagar", CGRect(x: 0, y: 0, width: 200, height: 100), clickable: true, depth: 1),
                   node("e3", text: "Voltar", CGRect(x: 0, y: 900, width: 200, height: 100), clickable: true, depth: 1)]
        let d = Device([home, pay])
        await d.drift()   // a timer: the screen is "pay" now, the cached read (fresh by generation) is "home"
        #expect(try await run(#"{"steps":[{"action":"tap","target":"Voltar"}]}"#, d) == ran(1))
        #expect(await d.dumps == 1)
        #expect(await d.touched.map(\.text) == ["Voltar"])   // e3, where "Voltar" is now; never "Pagar" at the old place
        #expect(await d.touched.map(\.ref) == ["e3"])
    }

    @Test func aScreenThatChangesByItselfToADestructiveNodeIsRefused() async throws {
        let home = [node("e1", full, depth: 0), node("e2", text: "Voltar", CGRect(x: 0, y: 0, width: 200, height: 100), clickable: true, depth: 1)]
        let pay = [node("e1", full, depth: 0), node("e2", CGRect(x: 0, y: 0, width: 1080, height: 200), clickable: true, depth: 1),
                   node("e3", text: "Voltar", CGRect(x: 0, y: 0, width: 300, height: 100), depth: 2),
                   node("e4", text: "Pagar agora", CGRect(x: 600, y: 0, width: 300, height: 100), depth: 2)]
        let d = Device([home, pay])
        await d.drift()
        #expect(try await run(#"{"steps":[{"action":"tap","target":"Voltar"}]}"#, d) == refused(at: 1))
        #expect(await d.touched.isEmpty)
    }

    @Test func aRefOfANonClickableIOSGroupWithFinalizarPedidoAtItsCentreIsRefused() async throws {
        let d = Device([group("XCUIElementTypeOther", leaf: "XCUIElementTypeButton", label: "Finalizar pedido")])
        #expect(try await run(#"{"steps":[{"action":"tap","target":"ref:e2"}]}"#, d) == refused(at: 1))
        #expect(await d.touched.isEmpty)
        #expect(await d.dumps == 0)   // a ref keeps the refs it names
    }

    @Test func aRefOfANonClickableAndroidLinearLayoutWithFinalizarPedidoAtItsCentreIsRefused() async throws {
        let d = Device([group("android.widget.LinearLayout", leaf: "android.widget.TextView", label: "Finalizar pedido")])
        #expect(try await run(#"{"steps":[{"action":"tap","target":"ref:e2"}]}"#, d) == refused(at: 1))
        #expect(await d.touched.isEmpty)
    }

    @Test func aRefCountsTheOverlayUnderItsCentreAndItsClickableAncestor() async throws {
        // an empty card with a "Finalizar pedido" overlay over its centre (a sibling, not a descendant)
        let overlay = [node("e1", full, depth: 0), node("e2", CGRect(x: 0, y: 1800, width: 1080, height: 400), depth: 1),
                       node("e3", text: "Finalizar pedido", CGRect(x: 240, y: 1900, width: 600, height: 200), clickable: true, depth: 1)]
        #expect(try await run(#"{"steps":[{"action":"tap","target":"ref:e2"}]}"#, Device([overlay])) == refused(at: 1))
        // a label inside a clickable row whose other child is "Excluir": the click acts for the whole row
        let row = [node("e1", full, depth: 0), node("e2", CGRect(x: 0, y: 1000, width: 1080, height: 200), clickable: true, depth: 1),
                   node("e3", text: "Item 3", CGRect(x: 40, y: 1040, width: 400, height: 100), depth: 2),
                   node("e4", text: "Excluir", CGRect(x: 800, y: 1040, width: 200, height: 100), depth: 2)]
        #expect(try await run(#"{"steps":[{"action":"tap","target":"ref:e3"}]}"#, Device([row])) == refused(at: 1))
    }

    @Test func aConcurrentScreenRewritingTheRefsRefusesTheTapInsteadOfTouchingAnotherNode() async throws {
        let home = [node("e1", full, depth: 0), node("e2", text: "Voltar", CGRect(x: 0, y: 0, width: 200, height: 100), clickable: true, depth: 1)]
        let other = [node("e1", full, depth: 0), node("e2", text: "Pagar", CGRect(x: 0, y: 0, width: 200, height: 100), clickable: true, depth: 1)]
        for target in ["Voltar", "ref:e2"] {
            let d = Device([home])
            await d.rewrite(other)   // another client's `device screen` between resolve and the tap: e2 is "Pagar" now
            let e = await #expect(throws: ProtocolError.self) { try await run(#"{"steps":[{"action":"tap","target":"\#(target)"}]}"#, d) }
            #expect(e?.code == .conflict, "\(target)")
            #expect(e?.message.contains("no longer the node classified") == true, "\(e?.message ?? "")")
            #expect(await d.touched.isEmpty, "\(target)")
        }
    }

    @Test func aPinnedTapWhoseNodeIsUnchangedRuns() async throws {
        let home = [node("e1", full, depth: 0), node("e2", text: "Voltar", CGRect(x: 0, y: 0, width: 200, height: 100), clickable: true, depth: 1)]
        let d = Device([home, home])
        #expect(try await run(#"{"steps":[{"action":"tap","target":"Voltar"},{"action":"tap","target":"ref:e2"}]}"#, d) == ran(2))
        #expect(await d.touched.map(\.ref) == ["e2", "e2"])
    }

    @Test func oneReadPerStepAndNoneForARef() async throws {
        let s = [node("e1", full, depth: 0), node("e2", text: "Voltar", id: "back", CGRect(x: 0, y: 0, width: 200, height: 100), clickable: true, depth: 1)]
        let d = Device([s, s, s, s, s])
        let plan = #"{"steps":[{"action":"tap","target":"Voltar"},{"action":"tap","target":"id:back"},{"action":"swipe","target":"540,1500,540,300"},{"action":"tap","target":"ref:e2"}]}"#
        #expect(try await run(plan, d) == ran(4))
        #expect(await d.dumps == 3)
    }

    @Test func aRefWithNoNodeInTheReadIsRefused() async throws {
        let d = Device([[node("e1", full, depth: 0)]])
        #expect(try await run(#"{"steps":[{"action":"tap","target":"ref:e9"}]}"#, d) == refused(at: 1))
        #expect(await d.touched.isEmpty)
    }

    @Test func checkPinComparesClassTextIdAndBounds() throws {
        let n = node("e2", cls: "android.widget.Button", text: "Voltar", id: "back", CGRect(x: 0, y: 0, width: 200, height: 100), clickable: true, depth: 1)
        try FlowClassifier.checkPin(["ref": .string("e2")], n)   // no pin: an agent's own --ref, unchecked
        try FlowClassifier.checkPin(["ref": .string("e2"), "pin": FlowClassifier.identity(n)], n)
        var moved = n; moved.bounds.origin.y = 900
        var renamed = n; renamed.text = "Pagar"
        var other = n; other.cls = "android.widget.TextView"
        for m in [moved, renamed, other] {
            #expect(throws: ProtocolError.self) { try FlowClassifier.checkPin(["ref": .string("e2"), "pin": FlowClassifier.identity(n)], m) }
        }
        var step = FlowPlan.Step(action: "tap", target: "ref:e2"); step.pin = n
        #expect(try FlowRunner.command(step).1["pin"] == FlowClassifier.identity(n))
    }
}
