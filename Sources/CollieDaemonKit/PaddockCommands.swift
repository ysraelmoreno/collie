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
            if let me = caller, me.summonedBy != nil { throw refuse("a sub-Shepherd stays in its summoner's paddock: no paddock create") }
            // --folder: a folder paddock there (relative to the CLI's cwd); else a worktree of the repo
            let base = (r.cwd ?? caller?.cwd).map { URL(fileURLWithPath: $0, isDirectory: true) }
            let folder = str(r, "folder").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, relativeTo: base).standardizedFileURL }
            let repo = try caller.map { URL(fileURLWithPath: $0.cwd) } ?? folder ?? URL(fileURLWithPath: try need(r, "repo"))
            if ws.paddocks.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw ProtocolError(code: .invalidArgs, message: "paddock '\(name)' already exists")
            }
            let factory = flag(r, "factory")
            if factory {   // A2: the owner's alone, and only over a profile the doctor passes
                guard caller == nil else { throw Self.factoryCreateOwnerOnly }
                // ponytail: checked on the source (the folder, or the repo's working tree) before the worktree exists;
                // a profile changed but not committed can differ from the new branch's. `paddock factory on` reads the paddock itself
                let source: URL; if let folder { source = folder } else { source = try await PaddockManager.repoRoot(of: repo) }
                if let why = FactoryDoctorReader.factoryRefusal(root: source) { throw Self.factoryRefused(why) }
            }
            try claim(name); defer { paddockBusy.remove(name.lowercased()) }
            if let folder { return try isoJSON(try await createFolderPaddock(name, folder: folder, createdBy: caller?.id, factory: factory)) }
            return try isoJSON(try await createPaddock(name, repo: repo, createdBy: caller?.id, factory: factory))
        case "paddock.factory":   // A2: the owner's alone (the admin principal); never an agent's terminal, never MCP
            guard caller == nil else { throw Self.factoryOwnerOnly }
            let f = try findPaddock(try need(r, "name"))
            guard let state = str(r, "state"), state == "on" || state == "off" else {
                throw ProtocolError(code: .invalidArgs, message: "state must be on|off")
            }
            if state == "on" {
                // B1: the loop reads the profile at HEAD; a worktree's file that differs from it (or is not committed) refuses,
                // so the doctor's verdict over the tree is the verdict over HEAD. A folder paddock runs no loop: its tree
                if !f.isFolder, let why = await Self.factoryDirty(URL(fileURLWithPath: f.path)) { throw Self.factoryRefused(why) }
                if let why = FactoryDoctorReader.factoryRefusal(root: URL(fileURLWithPath: f.path)) { throw Self.factoryRefused(why) }
            }
            return try isoJSON(try await setFactory(f.id, state == "on"))
        case "paddock.status":
            var f = try findPaddock(try need(r, "name"))
            if let status = str(r, "status") {   // omitted: only shows the paddock
                guard caller == nil || isCreator(f) || caller?.paddockId == f.id else {
                    throw refuse("only the paddock's creator Shepherd or its terminals can set its status")
                }
                guard let s = PaddockStatus(rawValue: status) else {
                    throw ProtocolError(code: .invalidArgs, message: "status must be working|blocked|review|idle|done")
                }
                f.status = s
                try await save(f)
            }
            guard case .object(var o) = try isoJSON(f) else { return .null }
            if f.trustLoops == true { o["loops"] = .string(tr("laços sem cartão: sim", "loops without card: yes")) }
            return .object(o)
        case "paddock.land":
            guard let mode = LandMode(rawValue: str(r, "mode") ?? "merge") else {
                throw ProtocolError(code: .invalidArgs, message: "mode must be merge|squash|rebase|pr")
            }
            if mode == .pr && caller != nil { throw refuse("pr land is user-only") }   // pushes to a remote
            var f = try findPaddock(try need(r, "name"))
            try PaddockManager.refuseFolder(f)
            guard isCreator(f) else { throw refuse("only the Shepherd that created paddock '\(f.name)' can land it") }
            let res = try await landPaddock(&f, mode: mode, message: str(r, "message"))
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
            if f.apps?.isEmpty == false { await publishPlugins() }   // its approved apps leave with it (services stop)
            try? FileManager.default.removeItem(at: AppLog.file(root: config.paths.root, paddock: f.id, app: "-").deletingLastPathComponent())
            // its override went with it; its design files are pasture now and take the workspace's system
            return await pasturePaddockFiles(of: f, caller: caller).map { .object(["designSystem": $0]) } ?? .object([:])
        default:
            throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(r.command)'")
        }
    }

    /// Creates paddock `name` off `repo`'s repository, records and persists it, emits `.paddock`. The caller holds `claim(name)`.
    func createPaddock(_ name: String, repo: URL, createdBy: UUID?, factory: Bool = false) async throws -> Paddock {
        let root = try await PaddockManager.repoRoot(of: repo)
        if let me = ws.terminals.first(where: { $0.id == createdBy }), !(try await paddockRepoAllowed(root, for: me)) {
            throw ProtocolError(code: .invalidArgs, message: "the repo \(root.path) is outside your project: a paddock there would be wider than it")
        }
        var f = try await PaddockManager.create(name: name, repoRoot: root, createdBy: createdBy)
        f.factory = factory
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
    func createFolderPaddock(_ name: String, folder: URL, createdBy: UUID?, factory: Bool = false) async throws -> Paddock {
        if let me = ws.terminals.first(where: { $0.id == createdBy }), !startedOpen(me),
           !ProjectRoot.contains(folder.path, root: try await projectRoot(of: me)) {
            throw ProtocolError(code: .invalidArgs, message: tr("a pasta \(folder.path) fica fora do seu projeto: o cercado seria mais largo que ele", "folder \(folder.path) is outside your project: the paddock would be wider than it"))
        }
        var f = try PaddockManager.createFolder(name: name, folder: folder, createdBy: createdBy)
        f.factory = factory
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

    /// C6 (S8): `paddock create --factory` by an agent: what it asked is to create, not to switch on or off.
    static var factoryCreateOwnerOnly: ProtocolError { ProtocolError(code: .unauthorized, message: tr("cercado fábrica: só o dono pode criar como fábrica (o app ou a CLI do dono), nunca um agente", "factory paddock: only the owner can create it as a factory (the app or the owner's CLI), never an agent")) }
    static var factoryOwnerOnly: ProtocolError { ProtocolError(code: .unauthorized, message: tr("cercado fábrica: só o dono liga ou desliga (o app ou a CLI do dono), nunca um agente", "factory paddock: only the owner can turn it on or off (the app or the owner's CLI), never an agent")) }
    static func factoryRefused(_ why: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: tr("cercado fábrica não ligado: \(why)", "factory paddock not enabled: \(why)")) }

    /// B1: why the worktree's `collie-work.json` is not HEAD's, in one line; nil: it is (or git says so).
    /// C1 (B1-b): an ignored file is no change to `git status`, yet HEAD may lack it or hold another: refused.
    static func factoryDirty(_ dir: URL) async -> String? {
        let name = ProjectWorkConfig.fileName
        if let ig = try? await GitRunner.run(["check-ignore", "-q", "--", name], in: dir, timeout: .seconds(30)), ig.status == 0 {
            return tr("o perfil está no .gitignore: o motor lê o commit base, não a árvore", "the profile is in .gitignore: the engine reads the base commit, not the tree")
        }
        guard let st = try? await GitRunner.run(["--literal-pathspecs", "status", "--porcelain", "--untracked-files=all", "--", name], in: dir, timeout: .seconds(30)),
              st.status == 0 else { return tr("\(name) não pôde ser comparado com o commit HEAD (git status falhou)", "\(name) could not be compared with the HEAD commit (git status failed)") }
        return st.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil
            : tr("\(name) difere do commit HEAD (o que o laço lê); próxima ação: commite ou descarte a mudança e ligue de novo", "\(name) differs from the HEAD commit (what the loop reads); next: commit or discard the change and turn it on again")
    }

    /// A2: marks (or unmarks) the paddock cercado fábrica, saved and told to the app.
    func setFactory(_ id: UUID, _ on: Bool) async throws -> Paddock {
        guard let i = ws.paddocks.firstIndex(where: { $0.id == id }) else { throw ProtocolError(code: .notFound, message: "Paddock not found") }
        ws.paddocks[i].factory = on
        try await persist()
        await hub.emit(.paddock(ws.paddocks[i]))
        return ws.paddocks[i]
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

    /// `paddock land` once the caller may: claimed, landed (`PaddockManager.land`), saved, its apps' approvals ended and
    /// its works closed by merge. A4: also the loop's `--auto-land` (`loopLand`), always `.merge`.
    func landPaddock(_ f: inout Paddock, mode: LandMode, message: String?) async throws -> LandResult {
        let (res, late) = try await landPaddockKeepingLate(&f, mode: mode, message: message, stopAtLate: true)
        if let late { throw late }
        return res
    }

    /// C2: `landPaddock`, with a failure AFTER the merge (the save) given back as `late` instead of thrown: the base moved
    /// and the caller (`loopLand`) records it. `stopAtLate`: as `landPaddock` always did, nothing more runs after it.
    /// C3b: `base` (the auto-land's), the base's commit the merge must still find under the claim (`PaddockManager.land`).
    func landPaddockKeepingLate(_ f: inout Paddock, mode: LandMode, message: String?, stopAtLate: Bool = false, base: String? = nil) async throws -> (LandResult, (any Error)?) {
        try claim(f.name); defer { paddockBusy.remove(f.name.lowercased()) }
        let res = try await PaddockManager.land(&f, mode: mode, message: message, base: base, failAfterMerge: landFailsAfterMerge)
        let id = f.id, i = ws.paddocks.firstIndex { $0.id == id }
        let apps = mode != .pr && i.map { ws.paddocks[$0].apps?.isEmpty == false } == true
        if apps, let i { ws.paddocks[i].apps = nil }   // landed: its apps' approvals end (their services stop) with it
        var late: (any Error)?
        do { try await saveAfterLand(f) } catch { late = error; if stopAtLate { return (res, late) } }
        if mode != .pr { await closeMerged(f) }   // a pr is not merged yet
        if apps { await publishPlugins() }
        return (res, late)
    }

    /// C2: the save after a land; the tests' seam (`landSaveFails`) fails it, as a full disk would.
    private func saveAfterLand(_ f: Paddock) async throws {
        if landSaveFails { throw ProtocolError(code: .internal, message: tr("a gravação do cercado falhou (teste)", "saving the paddock failed (test)")) }
        try await save(f)
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

/// A2: the human line of a paddock in `collie paddock list` / `status`: the name, "fábrica" beside it when marked, the status.
public enum PaddockText {
    public static func line(_ o: [String: JSONValue]) -> String {
        func str(_ k: String) -> String { if case .string(let s)? = o[k] { s } else { "" } }
        var l = str("name") + (o["factory"] == .bool(true) ? tr(" (fábrica)", " (factory)") : "") + "\t" + str("status")
        if case .string(let b)? = o["branch"], !b.isEmpty { l += "\t" + b }
        if case .string(let x)? = o["path"], !x.isEmpty { l += "\t" + x }   // B1: docs/referencia.md promises the paths
        if case .string(let x)? = o["loops"] { l += "\t" + x }
        return l
    }
}
