import Foundation
import CollieCore
import CollieProtocol

/// Shepherd-only commands. Leashes are the only permission: every target is resolved within
/// `ConnectionGraph.reachable(from: shepherd)`; no admin power is involved.
extension CommandRouter {
    func shepherd(_ r: Request, from tid: UUID) async throws -> JSONValue {
        guard let me = ws.terminals.first(where: { $0.id == tid }), me.isShepherd else {
            throw ProtocolError(code: .notShepherd, message: "'\(r.command)' is Shepherd-only")
        }
        func peer(_ k: String) throws -> TerminalRecord { try ConnectionGraph.resolve(name: try need(r, k), from: me.id, in: ws) }
        // same rule for panels: within the Shepherd's reach (canvas: leashed to it; dock: always)
        func reachablePanel(_ name: String) throws -> Panel {
            let p = try findPanel(name)
            guard ConnectionGraph.reachablePanels(from: me.id, in: ws).contains(where: { $0.id == p.id }) else {
                throw ProtocolError(code: .notConnected, message: "No connection to panel '\(p.name)'. Connect it first.")
            }
            return p
        }
        switch r.command {
        case "summon": return try await summon(r, by: me)
        case "dismiss":
            let t = try peer("target")
            guard !t.isShepherd else { throw ProtocolError(code: .invalidArgs, message: "cannot dismiss Shepherd '\(t.name)'") }
            try await remove(t)
        case "leash":
            // both ends already within reach: the Shepherd itself doesn't count, leashing it to a stranger would widen its reach
            if let (t, p) = try panelPair(r, terminal: { try ConnectionGraph.resolve(name: $0, from: me.id, in: ws) },
                                          panel: reachablePanel) {
                try await leash(t, p)
            } else {
                try await leash(try peer("a"), try peer("b"))
            }
        case "unleash":
            func peerOrSelf(_ name: String) throws -> TerminalRecord {
                do { return try ConnectionGraph.resolve(name: name, from: me.id, in: ws) } catch {
                    guard error.code == .notConnected && me.name.caseInsensitiveCompare(name) == .orderedSame else { throw error }
                    return me
                }
            }
            if let (t, p) = try panelPair(r, terminal: peerOrSelf, panel: reachablePanel) {
                try await unleash(t, p)
            } else {
                try await unleash(try peerOrSelf(try need(r, "a")), try peerOrSelf(try need(r, "b")))
            }
        case "notify":
            let m = try need(r, "message")
            guard m.count <= 2000 else { throw ProtocolError(code: .invalidArgs, message: "'message' exceeds 2000 characters") }
            await hub.emit(.notify(me.id, message: m))
        default: throw ProtocolError(code: .internal, message: "'\(r.command)' not implemented yet")
        }
        return .object([:])
    }

    private func summon(_ r: Request, by me: TerminalRecord) async throws -> JSONValue {
        let name = try need(r, "name")
        try reserve(name); defer { launching.remove(name.lowercased()) }
        guard let preset = Preset(rawValue: try need(r, "preset")) else {
            throw ProtocolError(code: .invalidArgs, message: "preset must be shell|claude|codex|custom")
        }
        if let t = try lookup(name) { throw ProtocolError(code: .invalidArgs, message: "terminal '\(t.name)' already exists") }
        var paddockId = me.paddockId, cwd = me.cwd
        if let f = str(r, "paddock") {
            let fl = try findPaddock(f)
            // user-created paddocks (createdBy nil) are open only to a Shepherd standing in them
            guard fl.createdBy == me.id || fl.id == me.paddockId else {
                throw ProtocolError(code: .notShepherd, message: "paddock '\(fl.name)' belongs to another Shepherd")
            }
            paddockId = fl.id; cwd = fl.path
        }
        let rec = TerminalRecord(id: UUID(), name: name, preset: preset, command: str(r, "command"),
                                 cwd: str(r, "cwd") ?? cwd, isShepherd: false, paddockId: paddockId)
        var result = try await launch(rec)
        try await ensurePaddock(of: rec)
        do {
            try await leash(me, rec)
            if let l = ws.lot(of: me.id) { try await place([rec.id], in: l.id); result["lot"] = .string(l.name) }   // grouping, never reach
        } catch { try? await remove(rec); throw error }
        if let p = str(r, "prompt"), !p.isEmpty {
            // the summon exists either way: report, don't fail (a retry would hit "already exists")
            do { try await asks.inject(to: rec.id, prompt: p) } catch {
                result["promptError"] = .string("\(error.code.rawValue): \(error.message)")
            }
        }
        return .object(result)
    }
}
