import Foundation
import CollieCore
import CollieProtocol

/// `paddock.*`: the admin token (same managed-terminal ancestry check as `admin.*`) or a terminal token.
/// Terminals get creator-scoped rights: only the Shepherd that created a paddock lands/deletes it; a `pr` land
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

    func paddockCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin (the user / app)
        func refuse(_ m: String) -> ProtocolError { ProtocolError(code: .notShepherd, message: m) }
        func isCreator(_ f: Paddock) -> Bool { caller.map { $0.isShepherd && f.createdBy == $0.id } ?? true }

        switch r.command {
        case "paddock.list":
            return try isoJSON(ws.paddocks)
        case "paddock.create":
            let name = try need(r, "name")
            try PaddockManager.validate(name: name)
            if let me = caller, !me.isShepherd { throw refuse("'paddock.create' is Shepherd-only") }
            // --folder: a folder paddock there (relative to the CLI's cwd); else a worktree of the repo
            let base = (r.cwd ?? caller?.cwd).map { URL(fileURLWithPath: $0, isDirectory: true) }
            let folder = str(r, "folder").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, relativeTo: base).standardizedFileURL }
            let repo = try caller.map { URL(fileURLWithPath: $0.cwd) } ?? folder ?? URL(fileURLWithPath: try need(r, "repo"))
            if ws.paddocks.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw ProtocolError(code: .invalidArgs, message: "paddock '\(name)' already exists")
            }
            try claim(name); defer { paddockBusy.remove(name.lowercased()) }
            if let folder { return try isoJSON(try await createFolderPaddock(name, folder: folder, createdBy: caller?.id)) }
            return try isoJSON(try await createPaddock(name, repo: repo, createdBy: caller?.id))
        case "paddock.status":
            var f = try findPaddock(try need(r, "name"))
            guard caller == nil || isCreator(f) || caller?.paddockId == f.id else {
                throw refuse("only the paddock's creator Shepherd or its terminals can set its status")
            }
            guard let s = PaddockStatus(rawValue: try need(r, "status")) else {
                throw ProtocolError(code: .invalidArgs, message: "status must be working|blocked|review|done")
            }
            f.status = s
            try await save(f)
            return try isoJSON(f)
        case "paddock.land":
            guard let mode = LandMode(rawValue: str(r, "mode") ?? "merge") else {
                throw ProtocolError(code: .invalidArgs, message: "mode must be merge|squash|rebase|pr")
            }
            if mode == .pr && caller != nil { throw refuse("pr land is user-only") }   // pushes to a remote
            var f = try findPaddock(try need(r, "name"))
            try PaddockManager.refuseFolder(f)
            guard isCreator(f) else { throw refuse("only the Shepherd that created paddock '\(f.name)' can land it") }
            try claim(f.name); defer { paddockBusy.remove(f.name.lowercased()) }
            let res = try await PaddockManager.land(&f, mode: mode, message: str(r, "message"))
            try await save(f)
            if mode != .pr { await closeMerged(f) }   // a pr is not merged yet
            guard case .object(var o) = try isoJSON(res) else { return .null }
            o["paddock"] = try isoJSON(f)
            return .object(o)
        case "paddock.delete":
            let f = try findPaddock(try need(r, "name"))
            guard isCreator(f) else { throw refuse("only the Shepherd that created paddock '\(f.name)' can delete it") }
            try claim(f.name); defer { paddockBusy.remove(f.name.lowercased()) }
            paddockDeleting.insert(f.id); defer { paddockDeleting.remove(f.id) }
            for t in ws.terminals where t.paddockId == f.id {
                if await registry.process(t.id)?.isRunning == true {
                    throw ProtocolError(code: .invalidArgs, message: "paddock has running terminals")
                }
            }
            try await PaddockManager.delete(f, force: flag(r, "force"))   // a folder paddock's folder stays (R2)
            if !f.isFolder { await memory.evict(under: f.path) }   // a folder's memory is the folder's, still in use
            ws.paddocks.removeAll { $0.id == f.id }
            for i in ws.terminals.indices where ws.terminals[i].paddockId == f.id {   // stopped records leave the paddock
                ws.terminals[i].paddockId = nil; ws.terminals[i].cwd = f.repoRoot
            }
            let toPasture = Set(ws.panels.filter { $0.paddockId == f.id }.map(\.id))   // its canvas panels go to pasture
            for i in ws.panels.indices where toPasture.contains(ws.panels[i].id) { ws.panels[i].paddockId = nil }
            try await persist()
            for pn in ws.panels where toPasture.contains(pn.id) { await hub.emit(.panel(pn)) }
            await hub.emit(.paddockRemoved(f.id))
            // its override went with it; its design files are pasture now and take the workspace's system
            return await pasturePaddockFiles(of: f, caller: caller).map { .object(["designSystem": $0]) } ?? .object([:])
        default:
            throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(r.command)'")
        }
    }

    /// Creates paddock `name` off `repo`'s repository, records and persists it, emits `.paddock`. The caller holds `claim(name)`.
    func createPaddock(_ name: String, repo: URL, createdBy: UUID?) async throws -> Paddock {
        let root = try await PaddockManager.repoRoot(of: repo)
        if let me = ws.terminals.first(where: { $0.id == createdBy }), !(try await paddockRepoAllowed(root, for: me)) {
            throw ProtocolError(code: .invalidArgs, message: "the repo \(root.path) is outside your project: a paddock there would be wider than it")
        }
        let f = try await PaddockManager.create(name: name, repoRoot: root, createdBy: createdBy)
        ws.paddocks.append(f)
        do { try await persist() } catch {
            ws.paddocks.removeAll { $0.id == f.id }
            try? await PaddockManager.delete(f, force: true)
            throw error
        }
        await hub.emit(.paddock(f))
        return f
    }

    /// A folder paddock on `folder`: a Shepherd's lies within its project (any existing folder when it started open).
    func createFolderPaddock(_ name: String, folder: URL, createdBy: UUID?) async throws -> Paddock {
        if let me = ws.terminals.first(where: { $0.id == createdBy }), !startedOpen(me),
           !ProjectRoot.contains(folder.path, root: try await projectRoot(of: me)) {
            throw ProtocolError(code: .invalidArgs, message: "a pasta \(folder.path) fica fora do seu projeto: o cercado seria mais largo que ele")
        }
        let f = try PaddockManager.createFolder(name: name, folder: folder, createdBy: createdBy)
        ws.paddocks.append(f)
        do { try await persist() } catch { ws.paddocks.removeAll { $0.id == f.id }; throw error }
        await hub.emit(.paddock(f))
        return f
    }

    /// I1: a terminal's paddock repo (found by git, which knows nothing of R9/R11: a dotfiles `~/.git` is a repo to it)
    /// lies within the terminal's project, or is the pasture of the terminal's own paddock.
    func paddockRepoAllowed(_ root: URL, for me: TerminalRecord) async throws -> Bool {
        if startedOpen(me) { return true }   // started open: no project bound (L1)
        if ProjectRoot.contains(root.path, root: try await projectRoot(of: me)) { return true }
        guard let pasture = ws.paddocks.first(where: { $0.id == me.paddockId }).map({ URL(fileURLWithPath: $0.repoRoot) }) else { return false }
        return SignedAppCheck.realPath(pasture) == SignedAppCheck.realPath(root)
    }

    /// Paddock by name (case-insensitive); refuses one with a create/land/delete in flight.
    func findPaddock(_ name: String) throws(ProtocolError) -> Paddock {
        let hits = ws.paddocks.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard hits.count <= 1 else { throw ProtocolError(code: .ambiguous, message: "Multiple paddocks named '\(name)'") }
        guard let f = hits.first else { throw ProtocolError(code: .notFound, message: "Paddock '\(name)' not found") }
        if paddockBusy.contains(f.name.lowercased()) { throw ProtocolError(code: .invalidArgs, message: "paddock '\(f.name)' is busy") }
        return f
    }

    /// After a launch's awaits: if its paddock was deleted (or is being deleted) meanwhile, undo the launch.
    func ensurePaddock(of rec: TerminalRecord) async throws {
        guard let fid = rec.paddockId, paddockDeleting.contains(fid) || !ws.paddocks.contains(where: { $0.id == fid }) else { return }
        try? await remove(rec)
        throw ProtocolError(code: .notFound, message: "Paddock of '\(rec.name)' was deleted")
    }

    func claim(_ name: String) throws(ProtocolError) {
        guard paddockBusy.insert(name.lowercased()).inserted else {
            throw ProtocolError(code: .invalidArgs, message: "paddock '\(name)' is busy")
        }
    }

    /// Writes `f` back over the current record (re-read after any await), persists, emits `.paddock`.
    private func save(_ f: Paddock) async throws {
        guard let i = ws.paddocks.firstIndex(where: { $0.id == f.id }) else {
            throw ProtocolError(code: .notFound, message: "Paddock '\(f.name)' not found")
        }
        ws.paddocks[i].status = f.status; ws.paddocks[i].landedAt = f.landedAt
        try await persist()
        await hub.emit(.paddock(ws.paddocks[i]))
    }

    /// JSON for agents: dates as ISO-8601 strings (persistence keeps Swift's default date coding).
    func isoJSON(_ v: some Encodable) throws -> JSONValue {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: e.encode(v))
    }
}
