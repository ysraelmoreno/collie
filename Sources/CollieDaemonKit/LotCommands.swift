import Foundation
import CollieCore
import CollieProtocol

/// `lot.*`: the admin token, or a terminal. Lots never grant reach: a Shepherd groups only itself and the terminals it
/// reaches by leash, any terminal may leave its own lot, and a terminal sees member names only of itself, the terminals
/// it reaches and its own lot's members (lot names and goals are visible to all, like `paddock.list`).
extension CommandRouter {
    func lotCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin (the user / app)
        func refuse(_ m: String) -> ProtocolError { ProtocolError(code: .notShepherd, message: m) }
        /// The target of create/join/leave: anyone for the admin; a Shepherd itself or a terminal it reaches.
        func target(_ name: String) throws(ProtocolError) -> TerminalRecord {
            guard let me = caller else { return try find(name) }
            if me.name.caseInsensitiveCompare(name) == .orderedSame { return me }
            guard me.isShepherd else { throw refuse("'\(r.command)' of another terminal is Shepherd-only") }
            return try ConnectionGraph.resolve(name: name, from: me.id, in: ws)
        }
        /// `--terminal`, or the calling terminal itself.
        func subject() throws(ProtocolError) -> TerminalRecord {
            if let n = str(r, "terminal") { return try target(n) }
            guard let me = caller else { throw ProtocolError(code: .invalidArgs, message: "Missing argument 'terminal'") }
            return me
        }

        switch r.command {
        case "lot.list":
            return .array(ws.lots.map { describe($0, for: caller) })
        case "lot.get":
            if let n = str(r, "lot") { return describe(try findLot(n), for: caller) }
            guard let me = caller else { throw ProtocolError(code: .invalidArgs, message: "Missing argument 'lot'") }
            guard let l = ws.lot(of: me.id) else { throw ProtocolError(code: .notFound, message: "'\(me.name)' is in no lot") }
            return describe(l, for: caller)
        case "lot.create":
            if let me = caller, !me.isShepherd { throw refuse("'lot.create' is Shepherd-only") }
            let name = try need(r, "name").trimmingCharacters(in: .whitespacesAndNewlines)
            let goal = (str(r, "goal") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 64 else { throw ProtocolError(code: .invalidArgs, message: "lot name must be 1-64 characters") }
            guard goal.count <= 500 else { throw ProtocolError(code: .invalidArgs, message: "goal exceeds 500 characters") }
            guard !ws.lots.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw ProtocolError(code: .invalidArgs, message: "lot '\(name)' already exists")
            }
            let paddock = try str(r, "paddock").map { n throws(ProtocolError) in try findPaddock(n).id }
            var ids: [UUID] = []
            for n in names(r, "members") { let t = try target(n); if !ids.contains(t.id) { ids.append(t.id) } }
            let lot = Lot(name: name, goal: goal, paddockId: paddock)
            ws.lots.append(lot)
            try await place(ids, in: lot.id)
            return describe(ws.lots.first { $0.id == lot.id } ?? lot, for: caller)
        case "lot.join":
            if let me = caller, !me.isShepherd { throw refuse("'lot.join' is Shepherd-only") }
            let t = try subject()
            let lot = try findLot(try need(r, "lot"))
            try await place([t.id], in: lot.id)
            return describe(ws.lots.first { $0.id == lot.id } ?? lot, for: caller)
        case "lot.leave":
            let t = try subject()
            guard let cur = ws.lot(of: t.id) else { throw ProtocolError(code: .notFound, message: "'\(t.name)' is in no lot") }
            if let n = str(r, "lot"), try findLot(n).id != cur.id {
                throw ProtocolError(code: .invalidArgs, message: "'\(t.name)' is not in lot '\(n)'")
            }
            try await place([t.id], in: nil)
            return .object([:])
        case "lot.delete":   // the app's: only a lot without terminals (its memories stay on disk)
            guard caller == nil else { throw ProtocolError(code: .unauthorized, message: "'lot.delete' is app-only") }
            let lot = try findLot(try need(r, "lot"))
            guard !lot.members.contains(where: { m in ws.terminals.contains { $0.id == m } }) else {
                throw ProtocolError(code: .invalidArgs, message: "lot '\(lot.name)' still has terminals")
            }
            ws.lots.removeAll { $0.id == lot.id }
            try await persist()
            await hub.emit(.lotRemoved(lot.id))
            return .object([:])
        default: throw ProtocolError(code: .internal, message: "'\(r.command)' not implemented yet")
        }
    }

    func findLot(_ key: String) throws(ProtocolError) -> Lot {
        if let l = ws.lots.first(where: { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame || $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
            return l
        }
        throw ProtocolError(code: .notFound, message: "Lot '\(key)' not found")
    }

    /// Moves `ids` into lot `lot` (nil: out of any lot), out of whichever lot held them; persists, emits each changed lot.
    func place(_ ids: [UUID], in lot: UUID?) async throws {
        var changed = Set<UUID>()
        if let lot { changed.insert(lot) }   // a new lot is emitted even with no members
        for id in ids { if let l = dropFromLot(id) { changed.insert(l.id) } }
        if let lot, let i = ws.lots.firstIndex(where: { $0.id == lot }) { ws.lots[i].members += ids }
        try await persist()
        for l in ws.lots where changed.contains(l.id) { await hub.emit(.lot(l)) }
    }

    /// Takes `terminal` out of its lot (no persist, no event); returns that lot as it is now.
    func dropFromLot(_ terminal: UUID) -> Lot? {
        guard let i = ws.lots.firstIndex(where: { $0.members.contains(terminal) }) else { return nil }
        ws.lots[i].members.removeAll { $0 == terminal }
        return ws.lots[i]
    }

    /// A lot for `caller`: member names limited to what it may see (nil = admin: all).
    private func describe(_ l: Lot, for caller: TerminalRecord?) -> JSONValue {
        let visible: Set<UUID>? = caller.map { me in
            Set([me.id] + ConnectionGraph.reachable(from: me.id, in: ws).map(\.id) + (ws.lot(of: me.id)?.members ?? []))
        }
        let members = l.members.filter { visible?.contains($0) ?? true }.compactMap { m in ws.terminals.first { $0.id == m }?.name }
        var o: [String: JSONValue] = ["id": .string(l.id.uuidString), "name": .string(l.name), "goal": .string(l.goal),
                                      "members": .array(members.map { .string($0) }),
                                      "createdAt": .string(ISO8601DateFormatter().string(from: l.createdAt))]
        if let p = ws.paddocks.first(where: { $0.id == l.paddockId }) { o["paddock"] = .string(p.name) }
        return .object(o)
    }
}
