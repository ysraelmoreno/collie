import Foundation
import CollieCore
import CollieProtocol

/// `floor.*`: the admin token (same managed-terminal ancestry check as `admin.*`) or a terminal token.
/// Terminals get creator-scoped rights: only the Maestro that created a floor lands/deletes it; a `pr` land
/// pushes to a remote and stays with the user.
extension CommandRouter {
    /// The caller: nil = admin (the user / app; `adminOnly` checks), otherwise the verified terminal.
    func principal(_ r: Request, peer: pid_t) async throws -> TerminalRecord? {
        if r.terminalId == nil {
            try await adminOnly(r, peer: peer)
            return nil
        }
        guard let tid = UUID(uuidString: r.terminalId ?? ""), let t = r.token, await auth.verify(terminal: tid, token: t),
              let me = ws.terminals.first(where: { $0.id == tid }) else {
            throw ProtocolError(code: .unauthorized, message: "Invalid terminal credentials")
        }
        return me
    }

    func floorCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin (the user / app)
        func refuse(_ m: String) -> ProtocolError { ProtocolError(code: .notMaestro, message: m) }
        func isCreator(_ f: Floor) -> Bool { caller.map { $0.isMaestro && f.createdBy == $0.id } ?? true }

        switch r.command {
        case "floor.list":
            return try isoJSON(ws.floors)
        case "floor.create":
            let name = try need(r, "name")
            try FloorManager.validate(name: name)
            let repo: URL
            if let me = caller {
                guard me.isMaestro else { throw refuse("'floor.create' is Maestro-only") }
                repo = URL(fileURLWithPath: me.cwd)
            } else {
                repo = URL(fileURLWithPath: try need(r, "repo"))
            }
            if ws.floors.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw ProtocolError(code: .invalidArgs, message: "floor '\(name)' already exists")
            }
            try claim(name); defer { floorBusy.remove(name.lowercased()) }
            return try isoJSON(try await createFloor(name, repo: repo, createdBy: caller?.id))
        case "floor.status":
            var f = try findFloor(try need(r, "name"))
            guard caller == nil || isCreator(f) || caller?.floorId == f.id else {
                throw refuse("only the floor's creator Maestro or its terminals can set its status")
            }
            guard let s = FloorStatus(rawValue: try need(r, "status")) else {
                throw ProtocolError(code: .invalidArgs, message: "status must be working|blocked|review|done")
            }
            f.status = s
            try await save(f)
            return try isoJSON(f)
        case "floor.land":
            guard let mode = LandMode(rawValue: str(r, "mode") ?? "merge") else {
                throw ProtocolError(code: .invalidArgs, message: "mode must be merge|squash|rebase|pr")
            }
            if mode == .pr && caller != nil { throw refuse("pr land is user-only") }   // pushes to a remote
            var f = try findFloor(try need(r, "name"))
            guard isCreator(f) else { throw refuse("only the Maestro that created floor '\(f.name)' can land it") }
            try claim(f.name); defer { floorBusy.remove(f.name.lowercased()) }
            let res = try await FloorManager.land(&f, mode: mode, message: str(r, "message"))
            try await save(f)
            if mode != .pr { await closeMerged(f) }   // a pr is not merged yet
            guard case .object(var o) = try isoJSON(res) else { return .null }
            o["floor"] = try isoJSON(f)
            return .object(o)
        case "floor.delete":
            let f = try findFloor(try need(r, "name"))
            guard isCreator(f) else { throw refuse("only the Maestro that created floor '\(f.name)' can delete it") }
            try claim(f.name); defer { floorBusy.remove(f.name.lowercased()) }
            floorDeleting.insert(f.id); defer { floorDeleting.remove(f.id) }
            for t in ws.terminals where t.floorId == f.id {
                if await registry.process(t.id)?.isRunning == true {
                    throw ProtocolError(code: .invalidArgs, message: "floor has running terminals")
                }
            }
            try await FloorManager.delete(f, force: flag(r, "force"))
            await memory.evict(under: f.path)
            ws.floors.removeAll { $0.id == f.id }
            for i in ws.terminals.indices where ws.terminals[i].floorId == f.id {   // stopped records leave the floor
                ws.terminals[i].floorId = nil; ws.terminals[i].cwd = f.repoRoot
            }
            let grounded = Set(ws.panels.filter { $0.floorId == f.id }.map(\.id))   // its canvas panels go to ground
            for i in ws.panels.indices where grounded.contains(ws.panels[i].id) { ws.panels[i].floorId = nil }
            try await persist()
            for pn in ws.panels where grounded.contains(pn.id) { await hub.emit(.panel(pn)) }
            await hub.emit(.floorRemoved(f.id))
            // its override went with it; its design files are ground now and take the workspace's system
            return await groundFloorFiles(of: f, caller: caller).map { .object(["designSystem": $0]) } ?? .object([:])
        default:
            throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(r.command)'")
        }
    }

    /// Creates floor `name` off `repo`'s repository, records and persists it, emits `.floor`. The caller holds `claim(name)`.
    func createFloor(_ name: String, repo: URL, createdBy: UUID?) async throws -> Floor {
        let f = try await FloorManager.create(name: name, repoRoot: try await FloorManager.repoRoot(of: repo), createdBy: createdBy)
        ws.floors.append(f)
        do { try await persist() } catch {
            ws.floors.removeAll { $0.id == f.id }
            try? await FloorManager.delete(f, force: true)
            throw error
        }
        await hub.emit(.floor(f))
        return f
    }

    /// Floor by name (case-insensitive); refuses one with a create/land/delete in flight.
    func findFloor(_ name: String) throws(ProtocolError) -> Floor {
        let hits = ws.floors.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard hits.count <= 1 else { throw ProtocolError(code: .ambiguous, message: "Multiple floors named '\(name)'") }
        guard let f = hits.first else { throw ProtocolError(code: .notFound, message: "Floor '\(name)' not found") }
        if floorBusy.contains(f.name.lowercased()) { throw ProtocolError(code: .invalidArgs, message: "floor '\(f.name)' is busy") }
        return f
    }

    /// After a launch's awaits: if its floor was deleted (or is being deleted) meanwhile, undo the launch.
    func ensureFloor(of rec: TerminalRecord) async throws {
        guard let fid = rec.floorId, floorDeleting.contains(fid) || !ws.floors.contains(where: { $0.id == fid }) else { return }
        try? await remove(rec)
        throw ProtocolError(code: .notFound, message: "Floor of '\(rec.name)' was deleted")
    }

    func claim(_ name: String) throws(ProtocolError) {
        guard floorBusy.insert(name.lowercased()).inserted else {
            throw ProtocolError(code: .invalidArgs, message: "floor '\(name)' is busy")
        }
    }

    /// Writes `f` back over the current record (re-read after any await), persists, emits `.floor`.
    private func save(_ f: Floor) async throws {
        guard let i = ws.floors.firstIndex(where: { $0.id == f.id }) else {
            throw ProtocolError(code: .notFound, message: "Floor '\(f.name)' not found")
        }
        ws.floors[i].status = f.status; ws.floors[i].landedAt = f.landedAt
        try await persist()
        await hub.emit(.floor(ws.floors[i]))
    }

    /// JSON for agents: dates as ISO-8601 strings (persistence keeps Swift's default date coding).
    func isoJSON(_ v: some Encodable) throws -> JSONValue {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: e.encode(v))
    }
}
