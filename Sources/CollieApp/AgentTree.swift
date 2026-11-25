import Foundation
import CollieCore

/// The agent tree of the Trilho context panel: each Shepherd of a paddock at the root, the terminals leashed to it
/// indented below, the rest at the root after. Pure: it takes `DaemonClient`'s values, never the client.
enum AgentTree {
    struct Row: Equatable, Identifiable {
        var id: UUID
        var name: String
        var preset: Preset
        /// 0: root; 1: under a Shepherd; up to 3 (a worker of a sub-sub-Shepherd).
        var depth: Int
        /// `DaemonClient.badges[id]`; nil: no badge yet (as `NodeStatus(badge:)` takes it).
        var status: StatusBadge?
        /// Open cards of this terminal.
        var pending: Int
        /// A Shepherd with at least one leashed terminal in this paddock (it gets the disclosure control).
        var isParent: Bool
        var isCollapsed: Bool
        /// A sub-Shepherd (a Shepherd summoned by one in this paddock): the name of the one that summoned it.
        var summonedByName: String? = nil
    }

    /// The rows of `paddock` (nil: the Pasto), `terminals` being in creation order. A terminal leashed to two Shepherds
    /// goes under the first. A Shepherd is a root, except a sub-Shepherd (`summonedBy` a Shepherd of this paddock), which
    /// nests under its summoner, its workers under it (depth up to 3). A worker is under the Shepherd that leashed or
    /// summoned it. No Shepherd: a flat list.
    static func rows(terminals: [TerminalRecord], connections: [Connection], badges: [UUID: StatusBadge], pending: [UUID: Int],
                     paddock: UUID?, collapsed: Set<UUID>) -> [Row] {
        let here = terminals.filter { $0.paddockId == paddock }
        let shepherds = Dictionary(here.filter(\.isShepherd).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func summoner(_ t: TerminalRecord) -> TerminalRecord? { t.isShepherd ? t.summonedBy.flatMap { shepherds[$0] } : nil }
        func row(_ t: TerminalRecord, depth: Int, children: Int = 0) -> Row {
            Row(id: t.id, name: t.name, preset: t.preset, depth: depth, status: badges[t.id], pending: pending[t.id] ?? 0,
                isParent: children > 0, isCollapsed: children > 0 && collapsed.contains(t.id), summonedByName: summoner(t)?.name)
        }
        var placed = Set<UUID>(), out: [Row] = []
        // `hidden`: under a collapsed one; still claimed, so it never reappears at the root
        func add(_ shepherd: TerminalRecord, depth: Int, hidden: Bool) {
            let linked = Set(connections.compactMap { $0.a == shepherd.id ? $0.b : $0.b == shepherd.id ? $0.a : nil })
            let children = here.filter {
                !placed.contains($0.id) && ($0.isShepherd ? $0.summonedBy == shepherd.id : linked.contains($0.id) || $0.summonedBy == shepherd.id)
            }
            placed.formUnion(children.map(\.id))
            if !hidden { out.append(row(shepherd, depth: depth, children: children.count)) }
            let below = hidden || collapsed.contains(shepherd.id)
            for c in children {
                if c.isShepherd { add(c, depth: depth + 1, hidden: below) } else if !below { out.append(row(c, depth: depth + 1)) }
            }
        }
        for s in here where s.isShepherd && summoner(s) == nil && placed.insert(s.id).inserted { add(s, depth: 0, hidden: false) }
        return out + here.filter { !placed.contains($0.id) }.map { row($0, depth: 0) }
    }

    /// Open cards per terminal: an access card counts for its terminal, a leash request for the Shepherd that asked
    /// (`from`), an app card for the terminal that asked (`by`; nil is the user: no terminal, not counted).
    static func pending(accessCards: [SandboxDenial], leashRequests: [LeashRequest], appCards: [AppCard]) -> [UUID: Int] {
        (accessCards.map(\.terminal) + leashRequests.map(\.from) + appCards.compactMap(\.by)).reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}
