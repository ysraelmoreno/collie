import Foundation
import CollieCore
import CollieProtocol

/// What the menu needs to know about one selected item.
struct NodeInfo: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case terminal(isClaude: Bool)
        /// `placement`: where it is now; `allowed`: where its plug-in lets it go; `isolatedStorage`: closing deletes its data.
        case panel(placement: PanelPlacement, allowed: [PanelPlacement], isolatedStorage: Bool)
    }
    var id: UUID
    var name: String
    var kind: Kind
    init(id: UUID, name: String, kind: Kind) { self.id = id; self.name = name; self.kind = kind }

    var isTerminal: Bool { if case .terminal = kind { true } else { false } }
}

/// An action of a node's menu. `.lot` and `.move` carry their choice when run (see `NodeBatch`).
enum NodeAction: Hashable, Sendable {
    case fullscreen, edit, restart, kill, saveMemory, lot, close
    case move(PanelPlacement)
}

enum NodeActions {
    static let order: [PanelPlacement] = [.dockLeft, .dockRight, .dockBottom, .canvas]

    /// The menu of `items` (in the order shown): only what is valid for every one of them. One item: its whole menu.
    /// "Tela cheia" and "Editar…" are single-item; a docked panel has no fullscreen.
    static func available(for items: [NodeInfo]) -> [NodeAction] {
        guard let first = items.first else { return [] }
        let single = items.count == 1
        var out: [NodeAction] = []
        if single {
            if case .panel(let p, _, _) = first.kind, p != .canvas {} else { out.append(.fullscreen) }
            if first.isTerminal { out.append(.edit) }
        }
        if items.allSatisfy(\.isTerminal) {
            out += [.restart, .kill]
            if items.allSatisfy({ if case .terminal(let c) = $0.kind { c } else { false } }) { out.append(.saveMemory) }
            out.append(.lot)
        }
        let panels = items.compactMap { i -> (PanelPlacement, [PanelPlacement])? in
            if case .panel(let p, let a, _) = i.kind { (p, a) } else { nil }
        }
        if panels.count == items.count {
            out += order.filter { to in panels.allSatisfy { $0.1.contains(to) } && panels.contains { $0.0 != to } }.map(NodeAction.move)
        }
        out.append(.close)
        return out
    }

    /// The one confirmation (Fechar): says how many. nil for actions that do not ask (as for one item today).
    struct Confirmation: Equatable, Sendable {
        var title: String, detail: String, button: String
    }

    static func confirmation(for action: NodeAction, items: [NodeInfo]) -> Confirmation? {
        guard action == .close, let first = items.first else { return nil }
        let isolated = items.contains { if case .panel(_, _, true) = $0.kind { true } else { false } }
        let note = isolated ? " Os dados isolados dos painéis serão apagados." : ""
        if items.count == 1 {
            let detail = first.isTerminal ? "O terminal será encerrado." : isolated ? "O painel será fechado e os dados isolados dele serão apagados." : "O painel será fechado."
            return Confirmation(title: "Fechar \(first.name)?", detail: detail, button: first.isTerminal ? "Fechar nó" : "Fechar painel")
        }
        let t = items.filter(\.isTerminal).count, p = items.count - t
        var parts: [String] = []
        if t > 0 { parts.append(t == 1 ? "1 terminal será encerrado" : "\(t) terminais serão encerrados") }
        if p > 0 { parts.append(p == 1 ? "1 painel será fechado" : "\(p) painéis serão fechados") }
        return Confirmation(title: "Fechar \(items.count) itens?", detail: parts.joined(separator: " e ") + "." + note, button: "Fechar \(items.count) itens")
    }
}
