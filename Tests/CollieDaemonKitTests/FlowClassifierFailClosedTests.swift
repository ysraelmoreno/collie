import Testing
import Foundation
import CoreGraphics
import CollieDevice
import CollieProtocol
@testable import CollieDaemonKit

/// A fake device: the screen shown (an action moves to the next one), each tap's args kept. The runner classifies the
/// screen shown with `FlowClassifier.labels` (`FlowRunner(nodes:)`); reading and touching are `DeviceService`'s
/// (`FlowGuardTests`, `FlowGuardRefTests`).
private actor Device {
    let screens: [[UINode]]
    var shown = 0
    var taps: [[String: JSONValue]] = []
    init(_ screens: [[UINode]]) { self.screens = screens }
    func act(_ c: String, _ a: [String: JSONValue]) -> JSONValue {
        if c == "device.tap" { taps.append(a) }
        shown = min(shown + 1, screens.count - 1)
        return .object([:])
    }
    func current() -> [UINode] { screens[shown] }
}
private func node(_ ref: String, cls: String = "android.view.View", text: String = "", id: String = "", _ r: CGRect,
                  clickable: Bool = false, depth: Int) -> UINode {
    UINode(ref: ref, cls: cls, text: text, desc: "", id: id, bounds: r, clickable: clickable, depth: depth)
}
private func run(_ json: String, _ d: Device) async throws -> JSONValue {
    try await FlowRunner(nodes: { await d.current() }) { c, a async throws(ProtocolError) in
        await d.act(c, a)
    }.run(try FlowPlan.parse(Data(json.utf8)))
}
private func refused(at: Int) -> JSONValue {
    .object(["ok": .bool(false), "refused": .string("destructive"), "at": .number(Double(at)), "done": .number(Double(at - 1))])
}
private func ran(_ n: Int) -> JSONValue { .object(["ok": .bool(true), "steps": .number(Double(n))]) }
private let full = CGRect(x: 0, y: 0, width: 1080, height: 2400)

/// A container neither clickable nor under a clickable node (`cls`), id `id`, holding `label` at its centre.
private func container(_ cls: String, leaf: String, id: String, label: String) -> [UINode] {
    [node("e1", cls: cls, full, depth: 0),
     node("e2", cls: cls, id: id, CGRect(x: 0, y: 1800, width: 1080, height: 400), depth: 1),
     node("e3", cls: leaf, text: label, CGRect(x: 340, y: 1950, width: 400, height: 100), clickable: true, depth: 2)]
}

/// wd1: the destructive classification fails closed (review `.collie/briefs/rev-device-flows-final.md`, security 1-4 and 6).
struct FlowClassifierFailClosedTests {
    @Test func anIdOfANonClickableIOSGroupHoldingFinalizarPedidoIsRefused() async throws {
        let d = Device([container("XCUIElementTypeOther", leaf: "XCUIElementTypeButton", id: "checkout", label: "Finalizar pedido")])
        #expect(try await run(#"{"steps":[{"action":"tap","target":"id:checkout"}]}"#, d) == refused(at: 1))
        #expect(await d.taps.isEmpty)
    }

    @Test func anIdOfANonClickableAndroidLinearLayoutHoldingFinalizarPedidoIsRefused() async throws {
        let d = Device([container("android.widget.LinearLayout", leaf: "android.widget.TextView", id: "com.shop:id/footer",
                                  label: "Finalizar pedido")])
        #expect(try await run(#"{"steps":[{"action":"tap","target":"id:com.shop:id/footer"}]}"#, d) == refused(at: 1))
        #expect(await d.taps.isEmpty)
    }

    @Test func whatLiesUnderTheCentreOfANonClickableTargetCountsEvenOutsideItsSubtree() async throws {
        // an empty card, and a "Finalizar pedido" overlay drawn over its centre (a sibling, not a descendant)
        let s = [node("e1", full, depth: 0),
                 node("e2", id: "com.shop:id/card", CGRect(x: 0, y: 1800, width: 1080, height: 400), depth: 1),
                 node("e3", text: "Finalizar pedido", CGRect(x: 240, y: 1900, width: 600, height: 200), clickable: true, depth: 1)]
        let d = Device([s])
        #expect(try await run(#"{"steps":[{"action":"tap","target":"id:com.shop:id/card"}]}"#, d) == refused(at: 1))
    }

    @Test func aSwipeOnTheThumbOfANonClickableDesliceParaPagarSliderIsRefused() async throws {
        let s = [node("e1", full, depth: 0),
                 node("e2", cls: "XCUIElementTypeOther", CGRect(x: 0, y: 2000, width: 1080, height: 200), depth: 1),
                 node("e3", cls: "XCUIElementTypeImage", CGRect(x: 0, y: 2000, width: 200, height: 200), depth: 2),
                 node("e4", cls: "XCUIElementTypeStaticText", text: "Deslize para pagar", CGRect(x: 300, y: 2050, width: 500, height: 100), depth: 2)]
        let d = Device([s])
        #expect(try await run(#"{"steps":[{"action":"swipe","target":"100,2100,1000,2100"}]}"#, d) == refused(at: 1))
        #expect(await d.taps.isEmpty)
        // a scroll on the bare screen above it runs: the screen itself does not bring every label on it
        #expect(try await run(#"{"steps":[{"action":"swipe","target":"540,1500,540,300"}]}"#, d) == ran(1))
    }

    @Test func aPointWhoseSmallestNodeIsBenignUnderALargerExcluirContaOverlayIsRefused() async throws {
        let s = [node("e1", full, depth: 0),
                 node("e2", text: "Ver detalhes", CGRect(x: 0, y: 1000, width: 1080, height: 100), clickable: true, depth: 1),
                 node("e3", text: "Excluir conta", CGRect(x: 0, y: 900, width: 1080, height: 400), clickable: true, depth: 1)]
        let d = Device([s])
        #expect(try await run(#"{"steps":[{"action":"tap","target":"540,1050"}]}"#, d) == refused(at: 1))
        #expect(await d.taps.isEmpty)
    }

    // wf2: a stale read, an OCR-only text and a text nothing finds are the tap's own read (`FlowGuardTests`: the changed
    // screen, the OCR labels, the OCR node with no label; a text no read finds is `device.tap`'s notFound, nothing touched).

    @Test func theWiderListIsRefusedAndVoltarIsNot() async throws {
        let forms = ["cancelar assinatura", "cancel subscription", "encerrar conta", "close account", "limpar dados", "clear data",
                     "redefinir", "reset", "desativar", "deactivate"]
        for v in forms { #expect(FlowClassifier.destructiveLabels.contains(v), "\(v)") }
        for l in ["Cancelar Assinatura", "CANCEL SUBSCRIPTION", "Encerrar conta", "Close account", "Limpar dados", "Clear data",
                  "Redefinir senha", "Reset", "Desativar", "Deactivate"] {
            #expect(FlowClassifier.destructive(l), "\(l)")
            let d = Device([[node("e1", full, depth: 0), node("e2", text: l, CGRect(x: 0, y: 1000, width: 1080, height: 200), clickable: true, depth: 1)]])
            #expect(try await run(#"{"steps":[{"action":"tap","target":"540,1100"}]}"#, d) == refused(at: 1), "\(l)")
        }
        for l in ["Voltar", "Cancelar", "Assinatura", "Dados"] { #expect(!FlowClassifier.destructive(l), "\(l)") }
        let d = Device([[node("e1", full, depth: 0), node("e2", text: "Voltar", CGRect(x: 0, y: 0, width: 200, height: 100), clickable: true, depth: 1)]])
        #expect(try await run(#"{"steps":[{"action":"tap","target":"Voltar"}]}"#, d) == ran(1))
    }
}
