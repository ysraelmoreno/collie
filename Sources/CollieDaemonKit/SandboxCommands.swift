import Foundation
import CollieCore
import CollieProtocol

/// `access.*`: the sandbox's access cards and the user's grants. A terminal asks (`access.request`, shown as a card) and
/// reads its own grants (`access.list`); only the app (admin token from the signed app, never from inside a terminal)
/// grants, denies and revokes — nothing is opened without the user's click. A grant restarts the terminal with the
/// wider profile, resuming the conversation (Claude `--continue`); a revoke restarts the running terminals it narrows.
extension CommandRouter {
    func accessCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin (the app)
        func appOnly() throws(ProtocolError) {
            guard caller == nil else {
                throw ProtocolError(code: .unauthorized, message: "'\(r.command)' is app-only: only the user opens the sandbox (só o usuário, no app)")
            }
        }
        switch r.command {
        case "access.request":
            guard let me = caller else { throw ProtocolError(code: .invalidArgs, message: "'access.request' is sent from a terminal") }
            guard sandboxed(me) else { throw ProtocolError(code: .invalidArgs, message: "'\(me.name)' has no sandbox (terminal livre)") }
            let read = flag(r, "read"), write = flag(r, "write")
            guard read != write else { throw ProtocolError(code: .invalidArgs, message: "pass one of --read or --write") }
            let base = URL(fileURLWithPath: r.cwd ?? me.cwd, isDirectory: true)
            let path = SignedAppCheck.realPath(URL(fileURLWithPath: try need(r, "path"), relativeTo: base).absoluteURL)
            let secrets = await auth.secrets()
            let reason = str(r, "reason").map { LotBoards.clean(LotBoards.scrub($0, secrets: secrets), max: 300) }.flatMap { $0.isEmpty ? nil : $0 }
            await raise(SandboxDenial(terminal: me.id, op: write ? "write" : "read", path: path, requested: true, reason: reason))
            return .object(["shown": .bool(true), "message": .string("Pedido mostrado ao usuário no app; nada é liberado sem o clique dele.")])
        case "access.list":
            if let me = caller { return try isoJSON(SandboxGrantStore.applicable(sandboxGrants, terminal: me.id, lot: ws.lot(of: me.id)?.id)) }
            return .object(["grants": try isoJSON(sandboxGrants), "cards": try isoJSON(accessCards.all),
                            "detection": sandboxDetection.map(JSONValue.bool) ?? .null, "dropped": .number(Double(accessCards.dropped))])
        case "access.grant":
            try appOnly()
            let t = try accessTerminal(r)
            guard t.sandbox == .sandboxed else { throw ProtocolError(code: .invalidArgs, message: "'\(t.name)' é um terminal livre: não tem sandbox") }
            guard let access = SandboxGrant.Access(rawValue: try need(r, "access")) else {
                throw ProtocolError(code: .invalidArgs, message: "access must be read or write")
            }
            guard let scope = SandboxGrant.Scope(rawValue: str(r, "scope") ?? "terminal") else {
                throw ProtocolError(code: .invalidArgs, message: "scope must be terminal or lot")
            }
            let raw = try need(r, "path")
            guard raw.hasPrefix("/") else { throw ProtocolError(code: .invalidArgs, message: "'path' must be absolute") }
            var path = SignedAppCheck.realPath(URL(fileURLWithPath: raw))
            if flag(r, "folder") { path = (path as NSString).deletingLastPathComponent }   // Liberar a pasta
            if let why = SandboxGrantStore.refusal(path, op: access.rawValue, home: sandboxHomeDir, collie: config.paths.root) {
                throw ProtocolError(code: .invalidArgs, message: why)
            }
            let owner: UUID
            if scope == .lot {
                guard let l = ws.lot(of: t.id) else { throw ProtocolError(code: .invalidArgs, message: "'\(t.name)' não está em um lote") }
                owner = l.id
            } else { owner = t.id }
            try reserve(t.name); defer { launching.remove(t.name.lowercased()) }
            let g = SandboxGrant(path: path, access: access, scope: scope, owner: owner)
            if !sandboxGrants.contains(where: { $0.path == g.path && $0.scope == g.scope && $0.owner == g.owner && ($0.access == .write || g.access == .read) }) {
                let before = sandboxGrants
                sandboxGrants.append(g)
                do { try saveGrants() } catch { sandboxGrants = before; throw error }
            }
            let members = scope == .lot ? ws.lots.first { $0.id == owner }?.members ?? [] : [t.id]
            for m in members { accessCards.removeCovered(terminal: m, by: g) }
            // ponytail: the lot's other running members get it at their next start (only the card's terminal restarts)
            let running = await registry.process(t.id)?.isRunning == true
            if running { _ = try await relaunch(t, resume: true) }
            return .object(["grant": try isoJSON(g), "restarted": .bool(running), "resumed": .bool(running && t.resumesConversation)])
        case "access.deny":
            try appOnly()
            let t = try accessTerminal(r)
            let path = try need(r, "path")
            accessCards.deny(SandboxCards.Key(terminal: t.id, op: try need(r, "op"), folder: (path as NSString).deletingLastPathComponent))
            return .object([:])
        case "access.revoke":
            try appOnly()
            guard let id = UUID(uuidString: try need(r, "id")), let g = sandboxGrants.first(where: { $0.id == id }) else {
                throw ProtocolError(code: .notFound, message: "No grant '\(str(r, "id") ?? "")'")
            }
            let before = sandboxGrants
            sandboxGrants.removeAll { $0.id == id }
            do { try saveGrants() } catch { sandboxGrants = before; throw error }
            // narrowing takes a restart: every running terminal the grant reached starts again without it
            var restarted: [JSONValue] = []
            for t in ws.terminals where g.scope == .terminal ? t.id == g.owner : ws.lot(of: t.id)?.id == g.owner {
                guard sandboxed(t), await registry.process(t.id)?.isRunning == true, (try? reserve(t.name)) != nil else { continue }
                // ponytail: a terminal mid-launch (name reserved) is skipped; it may keep the grant until its next start
                let ok = (try? await relaunch(t, resume: true)) != nil
                launching.remove(t.name.lowercased())
                if ok { restarted.append(.string(t.name)) }
            }
            return .object(["restarted": .array(restarted)])
        default: throw ProtocolError(code: .internal, message: "'\(r.command)' not implemented yet")
        }
    }

    /// `terminal`: an id (the app's) or a name.
    private func accessTerminal(_ r: Request) throws(ProtocolError) -> TerminalRecord {
        let s = try need(r, "terminal")
        if let u = UUID(uuidString: s), let t = ws.terminals.first(where: { $0.id == u }) { return t }
        return try find(s)
    }

    var sandboxHomeDir: URL { config.sandboxHome ?? URL(fileURLWithPath: NSHomeDirectory()) }

    func saveGrants() throws { try SandboxGrantStore(root: config.paths.root).save(sandboxGrants) }

    /// A denial (from the log) or a request → a card for the app. A tag naming no terminal this daemon rendered a profile
    /// for is dropped (R5: a forged or stale tag).
    func raise(_ denial: SandboxDenial) async {
        guard sandboxKnown.contains(denial.terminal) else { return }
        let home = sandboxHomeDir, collie = config.paths.root
        let c = accessCards.add(denial) { d in   // a card to show: what can't be released, and why
            d.refusal = SandboxGrantStore.refusal(d.path, op: d.op, home: home, collie: collie)
            d.folderRefusal = d.refusal ?? SandboxGrantStore.refusal(d.folder, op: d.op, home: home, collie: collie)
        }
        if let c { await hub.emit(.sandboxDenied(c)) }
    }

    /// A removed terminal: its cards, its known id and its own grants go (a lot's grants stay with the lot).
    func sandboxGone(_ id: UUID) async {
        accessCards.forget(terminal: id)
        sandboxKnown.remove(id)
        let before = sandboxGrants
        sandboxGrants.removeAll { $0.scope == .terminal && $0.owner == id }
        if sandboxGrants != before { try? saveGrants() }
    }

    func startSandboxWatch(_ source: @escaping @Sendable () -> AsyncStream<String>, base: Duration) {
        sandboxWatch = Task { [weak self] in
            await SandboxWatcher.supervise(source: source, base: base, max: .seconds(60),
                                           state: { [weak self] ok in await self?.detectionChanged(ok) },
                                           line: { [weak self] l in
                                               await self?.raise(SandboxDenial(terminal: l.terminal, op: l.op, path: l.path, count: l.count))
                                           })
        }
    }
    func stopSandboxWatch() { sandboxWatch?.cancel(); sandboxWatch = nil }

    private func detectionChanged(_ ok: Bool) async {
        guard sandboxDetection != ok else { return }
        sandboxDetection = ok
        await hub.emit(.sandboxDetection(available: ok))
    }
}
