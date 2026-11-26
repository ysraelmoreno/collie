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
    /// Other terminals were summoned by this one (the daemon's `summonedBy`): "Encerrar ramo" has something to cascade to.
    var hasBranch = false
    init(id: UUID, name: String, kind: Kind) { self.id = id; self.name = name; self.kind = kind }

    var isTerminal: Bool { if case .terminal = kind { true } else { false } }
}

/// An action of a node's menu. `.lot` and `.move` carry their choice when run (see `NodeBatch`).
enum NodeAction: Hashable, Sendable {
    case fullscreen, edit, restart, kill, endBranch, saveMemory, lot, close
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
            if single && first.hasBranch { out.append(.endBranch) }
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
        guard let first = items.first else { return nil }
        if action == .endBranch {
            return Confirmation(title: tr("Encerrar o ramo de \(first.name)?", "End \(first.name)'s branch?"),
                                detail: tr("\(first.name) e todos os terminais que ele convocou, e os que eles convocaram, serão encerrados.", "\(first.name) and every terminal it summoned, and the ones they summoned, will be ended."),
                                button: tr("Encerrar ramo", "End branch"))
        }
        guard action == .close else { return nil }
        let isolated = items.contains { if case .panel(_, _, true) = $0.kind { true } else { false } }
        let note = isolated ? tr(" Os dados isolados dos painéis serão apagados.", " The panels' isolated data will be erased.") : ""
        if items.count == 1 {
            let detail = first.isTerminal ? tr("O terminal será encerrado.", "The terminal will be ended.") : isolated ? tr("O painel será fechado e os dados isolados dele serão apagados.", "The panel will be closed and its isolated data erased.") : tr("O painel será fechado.", "The panel will be closed.")
            return Confirmation(title: tr("Fechar \(first.name)?", "Close \(first.name)?"), detail: detail, button: first.isTerminal ? tr("Fechar nó", "Close node") : tr("Fechar painel", "Close panel"))
        }
        let t = items.filter(\.isTerminal).count, p = items.count - t
        var parts: [String] = []
        if t > 0 { parts.append(t == 1 ? tr("1 terminal será encerrado", "1 terminal will be ended") : tr("\(t) terminais serão encerrados", "\(t) terminals will be ended")) }
        if p > 0 { parts.append(p == 1 ? tr("1 painel será fechado", "1 panel will be closed") : tr("\(p) painéis serão fechados", "\(p) panels will be closed")) }
        return Confirmation(title: tr("Fechar \(items.count) itens?", "Close \(items.count) items?"), detail: parts.joined(separator: tr(" e ", " and ")) + "." + note, button: tr("Fechar \(items.count) itens", "Close \(items.count) items"))
    }
}
