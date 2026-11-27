import Foundation
import CollieCanvas
import CollieClient
import CollieCore

/// The single sidebar's rows: the paddock list (Pasto + paddocks, each with its state in words) and the current
/// paddock's tree (agents via `AgentTree`, each agent's panels under it). Pure: it takes `DaemonClient`'s values, never
/// the client.
enum SidebarModel {
    /// What a paddock row says. Waiting beats working: a request is the one thing the user must act on.
    enum Activity: Equatable {
        case waiting, working(Int), idle

        var text: String {
            switch self {
            case .waiting: tr("espera você", "waiting for you")
            case .working(let n): tr("\(n) trabalhando", "\(n) working")
            case .idle: tr("parado", "idle")
            }
        }
        /// The dot drawn next to the words (the words carry the state; the dot never does alone).
        var dot: NodeStatus {
            switch self { case .waiting: .attention; case .working: .working; case .idle: .idle }
        }
    }

    struct PaddockRow: Equatable, Identifiable {
        /// nil: the Pasto.
        var id: UUID?
        var name: String
        /// Branch (`branch ← base`) or folder path; nil for the Pasto.
        var branch: String?
        var activity: Activity
        /// Open requests of this paddock's agents (sandbox, leash, app).
        var needs: Int
        var isCurrent: Bool
        var status: String { activity.text }
    }

    struct TreeRow: Equatable, Identifiable {
        enum Kind: Equatable { case agent(AgentTree.Row), panel(Panel) }
        var kind: Kind
        /// 0: root; an agent's panels sit one deeper than it.
        var depth: Int
        /// "Pastor" for a Shepherd; nil otherwise. Only the sidebar shows the role.
        var role: String?
        var id: UUID {
            switch kind { case .agent(let r): r.id; case .panel(let p): p.id }
        }
    }

    /// Pasto first (while `showsPasto`), then the paddocks in the daemon's order (the rail's order).
    static func paddockRows(paddocks: [Paddock], terminals: [TerminalRecord], badges: [UUID: StatusBadge],
                            pending: [UUID: Int], current: UUID?, panels: [Panel] = []) -> [PaddockRow] {
        func row(_ p: Paddock?) -> PaddockRow {
            let here = terminals.filter { $0.paddockId == p?.id }
            let needs = here.reduce(0) { $0 + (pending[$1.id] ?? 0) }
            let working = here.count { badges[$0.id] == .working }
            let activity: Activity = needs > 0 || here.contains { badges[$0.id] == .attention } ? .waiting
                : working > 0 ? .working(working) : .idle
            return PaddockRow(id: p?.id, name: p?.name ?? tr("Pasto", "Pasture"),
                              branch: p.map { $0.isFolder ? $0.path : "\($0.branch) ← \($0.baseBranch)" },
                              activity: activity, needs: needs, isCurrent: p?.id == current)
        }
        let pasto = showsPasto(hasContent: pastoHasContent(terminals: terminals, panels: panels), hasPaddocks: !paddocks.isEmpty, current: current)
        return (pasto ? [row(nil)] : []) + paddocks.map { row($0) }
    }

    /// The current paddock's tree: `AgentTree.rows` (Shepherds with their workers nested), each agent followed by the
    /// panels it opened (`createdBy`), then the panels without a visible owner. A panel whose owner is hidden under a
    /// collapsed Shepherd hides with it.
    static func tree(terminals: [TerminalRecord], connections: [Connection], badges: [UUID: StatusBadge], pending: [UUID: Int],
                     panels: [Panel], paddock: UUID?, collapsed: Set<UUID>) -> [TreeRow] {
        let agents = AgentTree.rows(terminals: terminals, connections: connections, badges: badges, pending: pending,
                                    paddock: paddock, collapsed: collapsed)
        let here = visiblePanels(panels, paddock: paddock)
        let shepherds = Set(terminals.filter(\.isShepherd).map(\.id))
        let inPaddock = Set(terminals.filter { $0.paddockId == paddock }.map(\.id))
        var out: [TreeRow] = []
        for a in agents {
            out.append(TreeRow(kind: .agent(a), depth: a.depth, role: shepherds.contains(a.id) ? tr("Pastor", "Shepherd") : nil))
            out += here.filter { $0.createdBy == a.id }.map { TreeRow(kind: .panel($0), depth: a.depth + 1) }
        }
        // ownerless: opened by the app, or by an agent that is not in this paddock (gone, elsewhere)
        out += here.filter { $0.createdBy.map { !inPaddock.contains($0) } ?? true }.map { TreeRow(kind: .panel($0), depth: 0) }
        return out
    }

    /// Two letters for the collapsed sidebar: the first letters of the first two words (split on spaces, hyphens,
    /// underscores, dots), else the first two letters of the single word; uppercased. "?" when there is none.
    static func initials(_ name: String) -> String {
        let words = name.split { !($0.isLetter || $0.isNumber) }
        let letters = words.count >= 2 ? words.prefix(2).compactMap(\.first).map(String.init).joined() : String(words.first?.prefix(2) ?? "")
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    // ponytail: moved from `PaddockRail` (deleted in L3); its copies go with it.

    /// Whether the Pasto (terminals and canvas panels outside any paddock) has anything in it. Docked panels belong to every paddock.
    static func pastoHasContent(terminals: [TerminalRecord], panels: [Panel]) -> Bool {
        terminals.contains { $0.paddockId == nil } || panels.contains { $0.placement == .canvas && $0.paddockId == nil }
    }

    /// The Pasto is not a paddock: it is listed only while it holds something, while it is the selection, or when there
    /// is no paddock to show instead.
    static func showsPasto(hasContent: Bool, hasPaddocks: Bool, current: UUID?) -> Bool {
        hasContent || !hasPaddocks || current == nil
    }
}
