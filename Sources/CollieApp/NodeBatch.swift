import AppKit
import SwiftUI
import CollieCanvas
import CollieClient
import CollieCore
import ColliePlugins
import CollieProtocol

extension Notification.Name {
    /// A terminal was restarted from outside its node (a menu on the selection): the canvas reattaches its stream
    /// for a fresh replay, as the node's own Reiniciar does. `object`: the terminal's UUID.
    static let collieReattachTerminal = Notification.Name("collie.reattachTerminal")
}

/// The wiring of the selection's menu (canvas nodes and side-panel rows): what the selected items are, the menu, and
/// each action through the same `DaemonClient` calls the one-item menus use. The rules live in `NodeActions`/`Selecting`.
@MainActor enum NodeBatch {
    /// The selected items of the current paddock (terminals, then panels), as the menu rules see them.
    static func infos(_ ids: Set<UUID>, client: DaemonClient) -> [NodeInfo] {
        let terms = visibleTerminals(client.terminals, paddock: client.currentPaddock).filter { ids.contains($0.id) }
            .map { t in
                var i = NodeInfo(id: t.id, name: t.name, kind: .terminal(isClaude: t.preset == .claude))
                i.hasBranch = client.terminals.contains { $0.summonedBy == t.id }
                return i
            }
        let panels = visiblePanels(client.panels, paddock: client.currentPaddock).filter { ids.contains($0.id) }.map { p in
            NodeInfo(id: p.id, name: p.name, kind: .panel(placement: p.placement,
                                                           allowed: PluginRegistry.spec(p.pluginId)?.placements ?? NodeActions.order,
                                                           isolatedStorage: p.state["storage"] == .string("isolated")))
        }
        return terms + panels
    }

    /// The right-click menu for `ids`; nil when none of them is live.
    static func menu(ids: Set<UUID>, client: DaemonClient, canvas: CanvasState, edit: @escaping (UUID) -> Void) -> NSMenu? {
        let items = infos(ids, client: client)
        let actions = NodeActions.available(for: items)
        guard !items.isEmpty else { return nil }
        let live = Set(items.map(\.id))
        let m = NSMenu()
        func add(_ title: String, _ run: @escaping () -> Void) { m.addItem(ActionItem(title) { run() }) }
        func go(_ a: NodeAction) { run(a, ids: live, client: client, canvas: canvas, edit: edit) }
        if items.count > 1 {
            let h = NSMenuItem(title: tr("\(items.count) itens selecionados", "\(items.count) items selected"), action: nil, keyEquivalent: ""); h.isEnabled = false
            m.addItem(h); m.addItem(.separator())
        }
        if actions.contains(.fullscreen) { add(tr("Tela cheia", "Fullscreen")) { go(.fullscreen) }; m.addItem(.separator()) }
        if actions.contains(.edit) { add(tr("Editar…", "Edit…")) { go(.edit) } }
        if actions.contains(.restart) { add(tr("Reiniciar", "Restart")) { go(.restart) } }
        if actions.contains(.kill) { add(tr("Matar", "Kill")) { go(.kill) } }
        if actions.contains(.endBranch) { add(tr("Encerrar ramo…", "End branch…")) { go(.endBranch) } }
        if actions.contains(.saveMemory) { add(tr("Salvar na memória", "Save to memory")) { go(.saveMemory) } }
        if actions.contains(.lot) {
            let lots = NSMenuItem(title: tr("Lote", "Lot"), action: nil, keyEquivalent: ""), sub = NSMenu()
            let mine = Set(live.map { client.lot(of: $0)?.id })   // one element: they all share it
            for choice in LotChoice.all(client.lots) {
                let item = ActionItem(choice.title) { setLot(choice.lot, ids: live, client: client) }
                item.state = mine == [choice.lot?.id] ? .on : .off
                sub.addItem(item)
            }
            lots.submenu = sub
            m.addItem(lots)
        }
        let moves = actions.compactMap { a -> PanelPlacement? in if case .move(let p) = a { p } else { nil } }
        if !moves.isEmpty {
            let sub = NSMenu(), parent = NSMenuItem(title: tr("Mover para", "Move to"), action: nil, keyEquivalent: "")
            for p in moves { sub.addItem(ActionItem(PanelMenu.labels[p] ?? p.rawValue) { go(.move(p)) }) }
            parent.submenu = sub
            m.addItem(parent)
        }
        if m.items.last?.isSeparatorItem == false { m.addItem(.separator()) }
        let title = items.count > 1 ? tr("Fechar \(items.count) itens…", "Close \(items.count) items…") : items[0].isTerminal ? tr("Fechar nó…", "Close node…") : tr("Fechar…", "Close…")
        add(title) { go(.close) }
        return m
    }

    static func run(_ action: NodeAction, ids: Set<UUID>, client: DaemonClient, canvas: CanvasState, edit: @escaping (UUID) -> Void) {
        let items = infos(ids, client: client)
        guard let first = items.first, actions(items).contains(action) else { return }
        let terminals = items.filter(\.isTerminal).map(\.name), panels = items.filter { !$0.isTerminal }.map(\.name)
        switch action {
        case .fullscreen: canvas.toggleFullscreen(first.id)
        case .edit: edit(first.id)
        case .restart:
            // admin.update with restart relaunches a running terminal too (admin.restart refuses those)
            Task {
                for i in items where i.isTerminal {
                    do { try await client.update(i.name, restart: true) } catch { Log.canvas.error("restart \(i.name): \(error)") }
                    NotificationCenter.default.post(name: .collieReattachTerminal, object: i.id)
                }
            }
        case .kill: kill(terminals, client: client)
        case .saveMemory:
            Task { for n in terminals { do { try await client.captureMemory(n) } catch { Log.canvas.error("memory capture \(n): \(error)") } } }
        case .lot: break   // runs with its choice: `setLot`
        case .move(let p):
            Task { for n in panels { do { try await client.movePanel(n, to: p) } catch { Log.canvas.error("move \(n): \(error)") } } }
        case .endBranch:
            confirm(.endBranch, items: items) { kill(terminals, client: client, branch: true) }
        case .close:
            confirm(.close, items: items) {
                kill(terminals, client: client)
                Task { for n in panels { do { try await client.closePanel(n) } catch { Log.canvas.error("close \(n): \(error)") } } }
                canvas.selectionState = Selecting.pruned(canvas.selectionState, keeping: canvas.selection.subtracting(items.map(\.id)))
            }
        }
    }

    /// The confirmation sheet of `action` (`NodeActions.confirmation`); `go` runs on the confirming button.
    private static func confirm(_ action: NodeAction, items: [NodeInfo], go: @escaping () -> Void) {
        guard let c = NodeActions.confirmation(for: action, items: items) else { return }
        let a = NSAlert()
        a.messageText = c.title; a.informativeText = c.detail
        a.addButton(withTitle: c.button); a.addButton(withTitle: tr("Cancelar", "Cancel"))
        if let w = NSApp.keyWindow { a.beginSheetModal(for: w) { if $0 == .alertFirstButtonReturn { go() } } }
        else if a.runModal() == .alertFirstButtonReturn { go() }
    }

    private static func actions(_ items: [NodeInfo]) -> [NodeAction] { NodeActions.available(for: items) }

    private static func kill(_ names: [String], client: DaemonClient, branch: Bool = false) {
        Task { for n in names { do { try await client.kill(n, branch: branch) } catch { Log.canvas.error("kill \(n): \(error)") } } }
    }

    private static func setLot(_ lot: Lot?, ids: Set<UUID>, client: DaemonClient) {
        let names = visibleTerminals(client.terminals, paddock: client.currentPaddock).filter { ids.contains($0.id) }.map(\.name)
        Task { for n in names { do { try await client.setLot(n, lot?.name) } catch { Log.canvas.error("lot \(n): \(error)") } } }
    }
}

/// A press on a node, for its title bar and body: ⌘ flips the node in the selection, ⇧ adds it, a plain press selects only
/// it, except on a node of a larger selection, which keeps it for a group drag and collapses on release if it stayed a click.
@MainActor final class NodePress {
    private var collapse = false

    func down(_ id: UUID, canvas: CanvasState, modifiers m: NSEvent.ModifierFlags) {
        collapse = false
        if m.contains(.command) { canvas.selectionState = Selecting.toggle(canvas.selectionState, id) }
        else if m.contains(.shift) { canvas.selectionState = Selecting.extend(canvas.selectionState, id) }
        else if canvas.selection.contains(id), canvas.selection.count > 1 { collapse = true }
        else { canvas.selectionState = Selecting.click(id) }
    }
    func dragged() { collapse = false }
    func up(_ id: UUID, canvas: CanvasState) {
        if collapse { canvas.selectionState = Selecting.click(id) }
        collapse = false
    }
}

/// Catches only right-clicks (every other event falls through to the SwiftUI view below), so a row can pop an AppKit menu
/// after switching the selection.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: (NSEvent, NSView) -> Void
    func makeNSView(context: Context) -> Catcher { Catcher() }
    func updateNSView(_ v: Catcher, context: Context) { v.handler = onRightClick }

    final class Catcher: NSView {
        var handler: (NSEvent, NSView) -> Void = { _, _ in }
        override func hitTest(_ p: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent, e.type == .rightMouseDown || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
            else { return nil }
            return super.hitTest(p)
        }
        override func rightMouseDown(with e: NSEvent) { handler(e, self) }
        override func mouseDown(with e: NSEvent) { handler(e, self) }   // ⌃-click
    }
}
