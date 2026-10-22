import Foundation
import OrqCore
import OrqProtocol

/// Maestro-only commands. Cords are the only permission: every target is resolved within
/// `ConnectionGraph.reachable(from: maestro)`; no admin power is involved.
extension CommandRouter {
    func maestro(_ r: Request, from tid: UUID) async throws -> JSONValue {
        guard let me = ws.terminals.first(where: { $0.id == tid }), me.isMaestro else {
            throw ProtocolError(code: .notMaestro, message: "'\(r.command)' is Maestro-only")
        }
        func peer(_ k: String) throws -> TerminalRecord { try ConnectionGraph.resolve(name: try need(r, k), from: me.id, in: ws) }
        // same rule for panels: within the Maestro's reach (canvas: corded to it; dock: always)
        func reachablePanel(_ name: String) throws -> Panel {
            let p = try findPanel(name)
            guard ConnectionGraph.reachablePanels(from: me.id, in: ws).contains(where: { $0.id == p.id }) else {
                throw ProtocolError(code: .notConnected, message: "No connection to panel '\(p.name)'. Connect it first.")
            }
            return p
        }
        switch r.command {
        case "recruit": return try await recruit(r, by: me)
        case "dismiss":
            let t = try peer("target")
            guard !t.isMaestro else { throw ProtocolError(code: .invalidArgs, message: "cannot dismiss Maestro '\(t.name)'") }
            try await remove(t)
        case "connect":
            // both ends already within reach: the Maestro itself doesn't count, cording it to a stranger would widen its reach
            if let (t, p) = try panelPair(r, terminal: { try ConnectionGraph.resolve(name: $0, from: me.id, in: ws) },
                                          panel: reachablePanel) {
                try await cord(t, p)
            } else {
                try await cord(try peer("a"), try peer("b"))
            }
        case "disconnect":
            func peerOrSelf(_ name: String) throws -> TerminalRecord {
                do { return try ConnectionGraph.resolve(name: name, from: me.id, in: ws) } catch {
                    guard error.code == .notConnected && me.name.caseInsensitiveCompare(name) == .orderedSame else { throw error }
                    return me
                }
            }
            if let (t, p) = try panelPair(r, terminal: peerOrSelf, panel: reachablePanel) {
                try await uncord(t, p)
            } else {
                try await uncord(try peerOrSelf(try need(r, "a")), try peerOrSelf(try need(r, "b")))
            }
        case "notify":
            let m = try need(r, "message")
            guard m.count <= 2000 else { throw ProtocolError(code: .invalidArgs, message: "'message' exceeds 2000 characters") }
            await hub.emit(.notify(me.id, message: m))
        default: throw ProtocolError(code: .internal, message: "'\(r.command)' not implemented yet")
        }
        return .object([:])
    }

    private func recruit(_ r: Request, by me: TerminalRecord) async throws -> JSONValue {
        let name = try need(r, "name")
        try reserve(name); defer { launching.remove(name.lowercased()) }
        guard let preset = Preset(rawValue: try need(r, "preset")) else {
            throw ProtocolError(code: .invalidArgs, message: "preset must be shell|claude|codex|custom")
        }
        if let t = try lookup(name) { throw ProtocolError(code: .invalidArgs, message: "terminal '\(t.name)' already exists") }
        var floorId = me.floorId, cwd = me.cwd
        if let f = str(r, "floor") {
            let fl = try findFloor(f)
            // user-created floors (createdBy nil) are open only to a Maestro standing in them
            guard fl.createdBy == me.id || fl.id == me.floorId else {
                throw ProtocolError(code: .notMaestro, message: "floor '\(fl.name)' belongs to another Maestro")
            }
            floorId = fl.id; cwd = fl.path
        }
        let rec = TerminalRecord(id: UUID(), name: name, preset: preset, command: str(r, "command"),
                                 cwd: str(r, "cwd") ?? cwd, isMaestro: false, floorId: floorId)
        var result = try await launch(rec)
        try await ensureFloor(of: rec)
        do { try await cord(me, rec) } catch { try? await remove(rec); throw error }
        if let p = str(r, "prompt"), !p.isEmpty {
            // the recruit exists either way: report, don't fail (a retry would hit "already exists")
            do { try await asks.inject(to: rec.id, prompt: p) } catch {
                result["promptError"] = .string("\(error.code.rawValue): \(error.message)")
            }
        }
        return .object(result)
    }
}
