import Testing
import Foundation
import CoreGraphics
import CollieDevice
import CollieProtocol
@testable import CollieDaemonKit

/// A fake device recording each command name.
private actor Recorder {
    var commands: [String] = []
    func act(_ c: String) -> JSONValue { commands.append(c); return .object(["screen": .object(["sig": .string("s")])]) }
}
private func node(_ ref: String, text: String = "", id: String = "", _ r: CGRect, clickable: Bool = true) -> UINode {
    UINode(ref: ref, cls: "android.widget.Button", text: text, desc: "", id: id, bounds: r, clickable: clickable, depth: 1)
}
/// A screen: a full-screen list holding "Voltar" at the top and "Excluir" below it.
private let screen: [UINode] = [
    node("e1", text: "Lista de pedidos", CGRect(x: 0, y: 0, width: 1080, height: 2400), clickable: false),
    node("e2", text: "Voltar", id: "com.shop:id/back", CGRect(x: 0, y: 0, width: 200, height: 100)),
    node("e3", text: "Excluir", id: "com.shop:id/remove_item", CGRect(x: 0, y: 500, width: 400, height: 120)),
]
private func run(_ json: String, nodes: [UINode] = [], confirmed: Bool = false, _ d: Recorder) async throws -> JSONValue {
    try await FlowRunner(confirmed: confirmed, nodes: { nodes }) { c, _ async throws(ProtocolError) in await d.act(c) }
        .run(try FlowPlan.parse(Data(json.utf8)))
}
private func refused(at: Int) -> JSONValue {
    .object(["ok": .bool(false), "refused": .string("destructive"), "at": .number(Double(at)), "done": .number(Double(at - 1))])
}

/// b3: the server classifies a step as destructive by its target's label, besides the plan's own mark.
struct FlowClassifierTests {
    @Test func unmarkedPagarIsRefusedAfterTheEarlierSteps() async throws {
        let d = Recorder()
        let r = try await run(#"{"steps":[{"action":"key","target":"Home"},{"action":"tap","target":"Pagar"},{"action":"key","target":"Back"}]}"#, d)
        #expect(r == refused(at: 2))
        #expect(await d.commands == ["device.key"])
    }

    @Test func unmarkedFinalizarPedidoIsRefused() async throws {
        let d = Recorder()
        #expect(try await run(#"{"steps":[{"action":"tap","target":"Finalizar pedido"}]}"#, d) == refused(at: 1))
        #expect(await d.commands.isEmpty)
    }

    @Test func idBtnDeleteIsRefusedByItsHumanizedId() async throws {
        let d = Recorder()
        #expect(try await run(#"{"steps":[{"action":"tap","target":"id:btn_delete"}]}"#, d) == refused(at: 1))
        #expect(await d.commands.isEmpty)
    }

    @Test func idOfAnExcluirNodeIsRefused() async throws {
        let d = Recorder()
        let plain = [node("e9", text: "Excluir", id: "com.shop:id/action_x", CGRect(x: 0, y: 0, width: 10, height: 10))]
        #expect(try await run(#"{"steps":[{"action":"tap","target":"id:com.shop:id/action_x"}]}"#, nodes: plain, d) == refused(at: 1))
        #expect(await d.commands.isEmpty)
    }

    @Test func refOfAnExcluirNodeIsRefused() async throws {
        let d = Recorder()
        #expect(try await run(#"{"steps":[{"action":"tap","target":"ref:e3"}]}"#, nodes: screen, d) == refused(at: 1))
        #expect(await d.commands.isEmpty)
        let (c, a) = try FlowRunner.command(FlowPlan.Step(action: "tap", target: "ref:e2"))
        #expect(c == "device.tap" && a == ["ref": .string("e2")])
    }

    @Test func coordinateOnAnExcluirNodeIsRefusedTheSmallestNodeWinning() async throws {
        let d = Recorder()
        #expect(try await run(#"{"steps":[{"action":"tap","target":"200,560"}]}"#, nodes: screen, d) == refused(at: 1))
        #expect(await d.commands.isEmpty)
        // the same screen, a point on "Voltar" (inside the list too): runs
        let ok = try await run(#"{"steps":[{"action":"tap","target":"50,50"}]}"#, nodes: screen, d)
        #expect(ok == .object(["ok": .bool(true), "steps": .number(1)]))
    }

    @Test func coordinateWithoutAReadIsNotClassified() async throws {
        let d = Recorder()
        let r = try await run(#"{"steps":[{"action":"tap","target":"200,560"}]}"#, d)
        #expect(r == .object(["ok": .bool(true), "steps": .number(1)]))
        #expect(await d.commands == ["device.tap"])
    }

    @Test func voltarRuns() async throws {
        let d = Recorder()
        let r = try await run(#"{"steps":[{"action":"tap","target":"Voltar"},{"action":"tap","target":"id:com.shop:id/back"}]}"#, nodes: screen, d)
        #expect(r == .object(["ok": .bool(true), "steps": .number(2)]))
        #expect(await d.commands == ["device.tap", "device.tap"])
    }

    @Test func caseAndAccentDoNotMatterWordsDo() {
        for l in ["PAGAR", "Excluír", "excluir", "Sair da Conta", "SAIR  DA conta", "Délete account", "Place Order", "Sign-out"] {
            #expect(FlowClassifier.destructive(l), "\(l)")
        }
        for l in ["Voltar", "PayPal", "Entrar", "Removido do carrinho", ""] { #expect(!FlowClassifier.destructive(l), "\(l)") }
    }

    @Test func aTextThatFindsADestructiveNodeIsRefused() async throws {
        let d = Recorder()   // "excl" finds the "Excluir" node by containing
        #expect(try await run(#"{"steps":[{"action":"tap","target":"excl"}]}"#, nodes: screen, d) == refused(at: 1))
    }

    @Test func confirmedRunsAClassifiedStep() async throws {
        let d = Recorder()
        let r = try await run(#"{"steps":[{"action":"tap","target":"Pagar"}]}"#, confirmed: true, d)
        #expect(r == .object(["ok": .bool(true), "steps": .number(1)]))
        #expect(await d.commands == ["device.tap"])
    }

    @Test func unknownKeyIsRejectedNamingKeyAndStepAndNothingRuns() async throws {
        let d = Recorder()
        let e = await #expect(throws: ProtocolError.self) {
            try await run(#"{"steps":[{"action":"key","target":"Home"},{"action":"tap","target":"OK","Destructive":true}]}"#, d)
        }
        #expect(e?.message.contains("step 2: unknown key 'Destructive'") == true, "\(e?.message ?? "")")
        #expect(await d.commands.isEmpty)
        let typo = #expect(throws: ProtocolError.self) { try FlowPlan.parse(Data(#"{"steps":[{"action":"tap","target":"OK","expectsig":"s"}]}"#.utf8)) }
        #expect(typo?.message.contains("step 1: unknown key 'expectsig'") == true)
    }

    @Test func theListHoldsTheNamedVerbs() {
        for v in ["pagar", "finalizar", "comprar", "confirmar pedido", "excluir", "apagar", "remover", "deletar", "sair da conta",
                  "pay", "buy", "purchase", "place order", "delete", "remove", "erase", "sign out", "confirm"] {
            #expect(FlowClassifier.destructiveLabels.contains(v), "\(v)")
        }
    }

    @Test func onlyTapsAreClassified() async throws {
        let d = Recorder()
        let r = try await run(#"{"steps":[{"action":"text","target":"","text":"Excluir"},{"action":"key","target":"Delete"}]}"#, d)
        #expect(r == .object(["ok": .bool(true), "steps": .number(2)]))
    }
}
