import Foundation
import CollieCore

/// The agent tree of the Trilho context panel: each Shepherd of a paddock at the root, the terminals leashed to it
/// indented below, the rest at the root after. Pure: it takes `DaemonClient`'s values, never the client.
enum AgentTree {
    struct Row: Equatable, Identifiable {
        var id: UUID
        var name: String
        var preset: Preset
        /// 0: root; 1: under a Shepherd.
        var depth: Int
        /// `DaemonClient.badges[id]`; nil: no badge yet (as `NodeStatus(badge:)` takes it).
        var status: StatusBadge?
        /// Open cards of this terminal.
        var pending: Int
        /// A Shepherd with at least one leashed terminal in this paddock (it gets the disclosure control).
        var isParent: Bool
        var isCollapsed: Bool
    }

    /// The rows of `paddock` (nil: the Pasto), `terminals` being in creation order. A terminal leashed to two Shepherds
    /// goes under the first; a Shepherd is always a root, even when leashed to another. No Shepherd: a flat list.
    static func rows(terminals: [TerminalRecord], connections: [Connection], badges: [UUID: StatusBadge], pending: [UUID: Int],
                     paddock: UUID?, collapsed: Set<UUID>) -> [Row] {
        let here = terminals.filter { $0.paddockId == paddock }
        func row(_ t: TerminalRecord, depth: Int, children: Int = 0) -> Row {
            Row(id: t.id, name: t.name, preset: t.preset, depth: depth, status: badges[t.id], pending: pending[t.id] ?? 0,
                isParent: children > 0, isCollapsed: children > 0 && collapsed.contains(t.id))
        }
        var placed = Set<UUID>(), out: [Row] = []
        for shepherd in here where shepherd.isShepherd {
            let linked = Set(connections.compactMap { $0.a == shepherd.id ? $0.b : $0.b == shepherd.id ? $0.a : nil })
            let children = here.filter { !$0.isShepherd && linked.contains($0.id) && placed.insert($0.id).inserted }
            out.append(row(shepherd, depth: 0, children: children.count))
            if !collapsed.contains(shepherd.id) { out += children.map { row($0, depth: 1) } }
        }
        return out + here.filter { !$0.isShepherd && !placed.contains($0.id) }.map { row($0, depth: 0) }
    }

    /// Open cards per terminal: an access card counts for its terminal, a leash request for the Shepherd that asked
    /// (`from`), an app card for the terminal that asked (`by`; nil is the user: no terminal, not counted).
    static func pending(accessCards: [SandboxDenial], leashRequests: [LeashRequest], appCards: [AppCard]) -> [UUID: Int] {
        (accessCards.map(\.terminal) + leashRequests.map(\.from) + appCards.compactMap(\.by)).reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}
