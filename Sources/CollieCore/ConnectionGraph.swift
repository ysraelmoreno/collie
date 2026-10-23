import Foundation
import CollieProtocol

public enum ConnectionGraph {
    // Every terminal, Shepherd included, reaches only the peers it is leashed to (undirected; spec §5).
    public static func reachable(from: UUID, in ws: Workspace) -> [TerminalRecord] {
        guard ws.terminals.contains(where: { $0.id == from }) else { return [] }
        let peers = Set(ws.connections.compactMap { $0.a == from ? $0.b : $0.b == from ? $0.a : nil })
        return ws.terminals.filter { $0.id != from && peers.contains($0.id) }
    }

    public static func resolve(name: String, from: UUID, in ws: Workspace) throws(ProtocolError) -> TerminalRecord {
        let same = { (t: TerminalRecord) in t.name.caseInsensitiveCompare(name) == .orderedSame }
        guard ws.terminals.contains(where: same) else {
            throw ProtocolError(code: .notFound, message: "Terminal '\(name)' not found")
        }
        let hits = reachable(from: from, in: ws).filter(same)
        switch hits.count {
        case 0: throw ProtocolError(code: .notConnected, message: "No connection to '\(name)'. Connect the terminals first.")
        case 1: return hits[0]
        default: throw ProtocolError(code: .ambiguous, message: "Multiple connected terminals named '\(name)'")
        }
    }

    /// Canvas panels need a leash to `from` (terminal<->panel is a Connection); docked panels are reachable by every terminal;
    /// a headless one only by its creator (`panel.list` also lists it to a Shepherd leashed to the creator: `listedHeadless`).
    public static func reachablePanels(from: UUID, in ws: Workspace) -> [Panel] {
        let peers = Set(ws.connections.compactMap { $0.a == from ? $0.b : $0.b == from ? $0.a : nil })
        return ws.panels.filter { p in
            switch p.placement {
            case .canvas: return peers.contains(p.id)
            case .headless: return p.createdBy == from
            case .dockLeft, .dockRight, .dockBottom: return true
            }
        }
    }

    /// Listing only (never reach): a Shepherd sees the headless panels of the terminals leashed to it.
    public static func listedHeadless(from: UUID, in ws: Workspace) -> [Panel] {
        guard ws.terminals.contains(where: { $0.id == from && $0.isShepherd }) else { return [] }
        let peers = Set(reachable(from: from, in: ws).map(\.id))
        return ws.panels.filter { $0.placement == .headless && $0.createdBy.map(peers.contains) == true }
    }

    /// `from` nil: the admin (the user / app), which reaches every panel.
    public static func resolvePanel(name: String?, plugin: String, from: UUID?, in ws: Workspace) throws(ProtocolError) -> Panel {
        let reachable = (from.map { reachablePanels(from: $0, in: ws) } ?? ws.panels).filter { $0.pluginId == plugin }
        guard let name else {
            switch reachable.count {
            case 0: throw ProtocolError(code: .notFound, message: "No \(plugin) panel reachable. Open one with `panel open \(plugin)`.")
            case 1: return reachable[0]
            default: throw ProtocolError(code: .ambiguous, message: "Multiple \(plugin) panels reachable; pass --panel <name>")
            }
        }
        let same = { (p: Panel) in p.name.caseInsensitiveCompare(name) == .orderedSame && p.pluginId == plugin }
        guard ws.panels.contains(where: same) else { throw ProtocolError(code: .notFound, message: "Panel '\(name)' not found") }
        guard let hit = reachable.first(where: same) else {
            throw ProtocolError(code: .notConnected, message: "No connection to panel '\(name)'. Connect it first.")
        }
        return hit
    }
}
