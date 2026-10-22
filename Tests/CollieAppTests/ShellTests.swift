import AppKit
import SwiftUI
import Testing
import CollieCanvas
import ColliePlugins
import CollieClient
import CollieCore
import CollieTheme
@testable import CollieApp

@MainActor private final class Counter { var made = 0, dismantled = 0 }

/// Stands in for `CanvasView`: counts its AppKit view's make / dismantle.
private struct Probe: NSViewRepresentable {
    let counter: Counter
    func makeCoordinator() -> Counter { counter }
    func makeNSView(context: Context) -> NSView { counter.made += 1; return NSView() }
    func updateNSView(_ v: NSView, context: Context) {}
    static func dismantleNSView(_ v: NSView, coordinator: Counter) { coordinator.dismantled += 1 }
}

@MainActor @Observable private final class Box { var structure = WindowStructure.compact }

private struct Host: View {
    let box: Box
    let ctx: ShellContext
    let counter: Counter
    var body: some View {
        Shell(structure: box.structure, ctx: ctx) {
            Probe(counter: counter).overlay(alignment: .top) { CanvasChrome(structure: box.structure, ctx: ctx) { EmptyView() } }
        }
    }
}

/// Switching Compacta ↔ Completa must not remake the canvas (nor the docked panels around it).
@MainActor @Test func structureSwitchKeepsContent() {
    let client = DaemonClient(paths: Paths(root: FileManager.default.temporaryDirectory.appendingPathComponent("collie-shell-\(UUID())")))
    let ctx = ShellContext(client: client, canvas: CanvasState(), paddocks: PaddockActions(client: client), usage: UsageFeed(),
                           usageOpen: .constant(false), newTerminal: {}, openPanel: {}, fit: {}, openPalette: {},
                           herds: HerdsModel(call: { _, _ in .null }, nodeName: { _ in nil }), openHerds: { _ in })
    let box = Box(), counter = Counter()
    let host = NSHostingView(rootView: Host(box: box, ctx: ctx, counter: counter))
    host.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
    settle()
    #expect(counter.made == 1)
    for s in [WindowStructure.full, .compact, .full] { box.structure = s; settle() }
    #expect(counter.made == 1 && counter.dismantled == 0)
}

@MainActor @Test func usageSummary() {
    func r(_ id: String, _ ps: [Double?]) -> UsageReport {
        UsageReport(providerId: id, label: id, windows: ps.enumerated().map { WindowValue(label: "w\($0.offset)", usedPercent: $0.element, resetsAt: nil) })
    }
    #expect(UsageFeed.summary([r("claude", [41, 7]), r("codex", [3, 12.4])]) == "41% · 12%")
    #expect(UsageFeed.summary([r("claude", [nil]), r("codex", [])]) == nil)   // no numbers: the button says "uso"
    #expect(UsageFeed.summary([r("claude", [nil]), r("codex", [55])]) == "55%")
}

@MainActor @Test func paletteFilter() {
    let cs = ["Novo terminal", "Ir para o cercado api", "Ações do Pasto"].map { PaletteCommand(id: $0, title: $0, run: {}) }
    #expect(CommandPalette.filter(cs, "cerc").map(\.title) == ["Ir para o cercado api"])
    #expect(CommandPalette.filter(cs, "ACOES").map(\.title) == ["Ações do Pasto"])   // diacritics and case ignored
    #expect(CommandPalette.filter(cs, " ").count == 3)
}
