import Testing
import Foundation
import CoreGraphics
import CollieDevice
import CollieProtocol
@testable import CollieDaemonKit

/// A fake device the way `DeviceService` keeps it: the last read (`nodes`), fresh until an action; an action moves to
/// the next screen, a dump reads the current one.
private actor Device {
    var screens: [[UINode]]
    var shown = 0
    var nodes: [UINode]
    var fresh = true
    var dumps = 0
    var commands: [String] = []
    var failDump = false
    init(_ screens: [[UINode]], read: Bool = true) { self.screens = screens; nodes = read ? screens[0] : []; fresh = read }
    func act(_ c: String) -> JSONValue {
        commands.append(c); fresh = false; shown = min(shown + 1, screens.count - 1)
        return .object([:])
    }
    func dump() throws(ProtocolError) -> [UINode] {
        if failDump { throw ProtocolError(code: .internal, message: "uiautomator died") }
        dumps += 1; nodes = screens[shown]; fresh = true
        return nodes
    }
    func setFailDump() { failDump = true }
    /// `DeviceService.flowDestructive` over this device.
    func classify(_ s: FlowPlan.Step) async throws(ProtocolError) -> Bool {
        try await FlowClassifier.classify(s, nodes: nodes) { () throws(ProtocolError) -> [UINode] in try dump() }
    }
}
private func node(_ ref: String, text: String = "", id: String = "", _ r: CGRect, clickable: Bool = false, depth: Int = 1) -> UINode {
    UINode(ref: ref, cls: "android.view.View", text: text, desc: "", id: id, bounds: r, clickable: clickable, depth: depth)
}
private func run(_ json: String, _ d: Device) async throws -> JSONValue {
    try await FlowRunner(classify: { s async throws(ProtocolError) in try await d.classify(s) }) { c, _ async throws(ProtocolError) in
        await d.act(c)
    }.run(try FlowPlan.parse(Data(json.utf8)))
}
private func refused(at: Int) -> JSONValue {
    .object(["ok": .bool(false), "refused": .string("destructive"), "at": .number(Double(at)), "done": .number(Double(at - 1))])
}
private func ran(_ n: Int) -> JSONValue { .object(["ok": .bool(true), "steps": .number(Double(n))]) }

/// A clickable container with no label of its own (a typical Android row), its label a child.
private func row(_ ref: String, id: String, child: String, y: CGFloat) -> [UINode] {
    [node(ref, id: id, CGRect(x: 0, y: y, width: 1080, height: 200), clickable: true, depth: 2),
     node(ref + "t", text: child, CGRect(x: 40, y: y + 40, width: 400, height: 100), depth: 3)]
}
private let root = node("e1", CGRect(x: 0, y: 0, width: 1080, height: 2400), depth: 1)

/// c1: the classification runs on the node the tap acts on, resolved as `device.tap` resolves it, and its descendants.
struct FlowClassifierServiceTests {
    @Test func aTextFindingTheLabelOfAContainerIsRefusedByTheContainersDescendant() async throws {
        let d = Device([[root] + row("e2", id: "com.shop:id/x7", child: "Pagar", y: 1700)])
        #expect(try await run(#"{"steps":[{"action":"tap","target":"agar"}]}"#, d) == refused(at: 1))
        #expect(await d.commands.isEmpty)
        #expect(await d.dumps == 1)   // we1: read again even when fresh (one read per step)
    }

    @Test func aCoordinateAfterAnUncheckedTapIsClassifiedOnAFreshDump() async throws {
        let cart = [root] + row("e2", id: "com.shop:id/c", child: "Carrinho", y: 300)
        let bag = [root] + row("e2", id: "com.shop:id/r", child: "Excluir", y: 1700)
        let d = Device([cart, bag])
        let r = try await run(#"{"steps":[{"action":"tap","target":"Carrinho"},{"action":"tap","target":"540,1800"}]}"#, d)
        #expect(r == refused(at: 2))
        #expect(await d.commands == ["device.tap"])
        #expect(await d.dumps >= 1)
    }

    @Test func anOpaqueIdOfAContainerHoldingFinalizarPedidoIsRefused() async throws {
        let d = Device([[root] + row("e2", id: "com.shop:id/a9f", child: "Finalizar pedido", y: 2000)])
        #expect(try await run(#"{"steps":[{"action":"tap","target":"id:com.shop:id/a9f"}]}"#, d) == refused(at: 1))
        #expect(await d.commands.isEmpty)
    }

    @Test func aSwipeStartingOnDeslizeParaPagarIsRefused() async throws {
        let d = Device([[root] + row("e2", id: "com.bank:id/slider", child: "Deslize para pagar", y: 2000)])
        #expect(try await run(#"{"steps":[{"action":"swipe","target":"100,2100,1000,2100"}]}"#, d) == refused(at: 1))
        #expect(await d.commands.isEmpty)
        // a scroll elsewhere on the same screen runs
        #expect(try await run(#"{"steps":[{"action":"swipe","target":"540,1500,540,300"}]}"#, d) == ran(1))
    }

    @Test func theNewFormsAreRefused() async throws {
        for l in ["Pague agora", "Pagamento", "Confirmar", "Concluir", "Sair", "Transferir", "Enviar", "Submit", "Order now",
                  "Send", "Transfer", "Confirm", "Pay", "Buy", "Purchase", "Log out", "Erase"] {
            #expect(FlowClassifier.destructive(l), "\(l)")
            let d = Device([[root] + row("e2", id: "com.shop:id/b", child: l, y: 1000)])
            #expect(try await run(#"{"steps":[{"action":"tap","target":"1000,1100"}]}"#, d) == refused(at: 1), "\(l)")
        }
        for v in ["pagar", "pague", "pagamento", "finalizar", "concluir", "comprar", "confirmar", "excluir", "apagar", "remover",
                  "deletar", "sair", "transferir", "enviar", "pay", "buy", "purchase", "order", "place order", "delete", "remove",
                  "erase", "sign out", "log out", "submit", "send", "transfer", "confirm"] {
            #expect(FlowClassifier.destructiveLabels.contains(v), "\(v)")
        }
    }

    @Test func voltarCarrinhoAndCancelarRun() async throws {
        let s = [root] + row("e2", id: "com.shop:id/a", child: "Voltar", y: 100) + row("e3", id: "com.shop:id/b", child: "Carrinho", y: 500)
            + row("e4", id: "com.shop:id/c", child: "Cancelar", y: 900)
        let d = Device([s, s, s, s])
        let r = try await run(#"{"steps":[{"action":"tap","target":"Voltar"},{"action":"tap","target":"id:com.shop:id/b"},{"action":"tap","target":"540,1000"}]}"#, d)
        #expect(r == ran(3))
        #expect(await d.commands == ["device.tap", "device.tap", "device.tap"])
        for l in ["Voltar", "Carrinho", "Cancelar"] { #expect(!FlowClassifier.destructive(l), "\(l)") }
    }

    @Test func aRefOfAContainerHoldingPagarIsRefusedWithoutANewRead() async throws {
        let d = Device([[root] + row("e2", id: "com.shop:id/x", child: "Pagar", y: 1700)])
        await d.act("device.key")   // stale: still the refs the ref names, no dump (it would renumber them)
        #expect(try await run(#"{"steps":[{"action":"tap","target":"ref:e2"}]}"#, d) == refused(at: 1))
        #expect(await d.dumps == 0)
    }

    @Test func aStaleReadIsReadAgainBeforeATextTap() async throws {
        let home = [root] + row("e2", id: "com.shop:id/h", child: "Início", y: 300)
        let pay = [root] + row("e2", id: "com.shop:id/p", child: "Pagar", y: 300)
        let d = Device([home, pay])
        // the first tap moves the screen to "Pagar"; "ar" is only "contained" there, and only a new read sees it
        let r = try await run(#"{"steps":[{"action":"tap","target":"Início"},{"action":"tap","target":"ar"}]}"#, d)
        #expect(r == refused(at: 2))
        #expect(await d.dumps == 2)
    }

    @Test func aBlankPointOnAScreenWithADestructiveButtonElsewhereRuns() async throws {
        let d = Device([[root] + row("e2", id: "com.shop:id/r", child: "Excluir", y: 1700)])
        #expect(try await run(#"{"steps":[{"action":"tap","target":"540,600"}]}"#, d) == ran(1))
    }

    @Test func aFailingReadStopsThePlanNamingTheStep() async throws {
        let d = Device([[root]], read: false)
        await d.setFailDump()
        let e = await #expect(throws: ProtocolError.self) { try await run(#"{"steps":[{"action":"tap","target":"540,600"}]}"#, d) }
        #expect(e?.message.contains("step 1 (tap 540,600): uiautomator died") == true, "\(e?.message ?? "")")
        #expect(await d.commands.isEmpty)
    }

    /// Out of this wave: a key or a typed newline is not classified by any label (see FlowClassifier's ponytail).
    @Test func keysAndTypingAreNotClassified() async throws {
        let d = Device([[root] + row("e2", id: "com.shop:id/p", child: "Pagar", y: 300)])
        let r = try await run(#"{"steps":[{"action":"key","target":"Enter"},{"action":"text","target":"","text":"Pagar\n"}]}"#, d)
        #expect(r == ran(2))
        #expect(await d.dumps == 0)
    }
}
