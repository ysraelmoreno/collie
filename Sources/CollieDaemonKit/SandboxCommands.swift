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
            if startedOpen(me) {   // open mode: nothing to ask; Collie's internals never open
                let collieOwn = [config.paths.root, SandboxInput.appBundle(of: config.collieExecutable)].compactMap { $0 }
                    .contains { ProjectRoot.contains(path, root: URL(fileURLWithPath: SignedAppCheck.realPath($0))) }
                return .object(["shown": .bool(false), "message": .string(collieOwn
                    ? "Nunca liberado: dados e app do Collie ficam fechados também no modo aberto."
                    : "O sandbox está no modo aberto: acesso já liberado.")])
            }
            if read {   // 2Q: reads are open but for what no click opens: no card, the answer says which
                let why = SandboxGrantStore.readRefusal(path, home: sandboxHomeDir, collie: config.paths.root)
                return .object(["shown": .bool(false), "message": .string(why.map { "Nunca liberado: \($0)" }
                    ?? "Leitura fora do projeto já é livre no sandbox: nada a pedir. Se a leitura falhou, é um caminho que nunca é liberado (segredos, perfis de navegador, e-mail, dados do Collie).")])
            }
            let secrets = await auth.secrets()
            let reason = str(r, "reason").map { LotBoards.clean(LotBoards.scrub($0, secrets: secrets), max: 300) }.flatMap { $0.isEmpty ? nil : $0 }
            let d = SandboxDenial(terminal: me.id, op: "write", path: path, requested: true, reason: reason)
            let absorbed = accessCards.cards[SandboxCards.key(d)] != nil
            await raise(d)
            return .object(["shown": .bool(!absorbed), "message": .string(absorbed
                ? "Já há um aviso aberto no app para essa pasta; o pedido foi somado a ele. Nada é liberado sem o clique do usuário."
                : "Pedido mostrado ao usuário no app; nada é liberado sem o clique dele.")])
        case "access.list":
            if let me = caller { return try isoJSON(SandboxGrantStore.applicable(sandboxGrants, terminal: me.id, project: me.projectRoot, lot: ws.lot(of: me.id)?.id)) }
            return .object(["grants": try isoJSON(sandboxGrants), "cards": try isoJSON(accessCards.all),
                            "detection": sandboxDetection.map(JSONValue.bool) ?? .null, "dropped": .number(Double(accessCards.dropped)),
                            "silent": .object(Dictionary(uniqueKeysWithValues: accessCards.silent.map { ($0.key.uuidString, .number(Double($0.value))) }))])
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
            // R26: exactly the card's path (the kernel's, already resolved), or its folder: never resolved here. One that
            // no longer resolves to itself (a symlink swapped in since the card) is refused, not followed
            let path = flag(r, "folder") ? (raw as NSString).deletingLastPathComponent : raw   // Liberar a pasta
            guard SignedAppCheck.realPath(URL(fileURLWithPath: path)) == path else {
                throw ProtocolError(code: .invalidArgs, message: "O caminho mudou desde o cartão (agora é um link): nada foi liberado.")
            }
            if let why = SandboxGrantStore.refusal(path, op: access.rawValue, home: sandboxHomeDir, collie: config.paths.root,
                                                   app: SandboxInput.appBundle(of: config.collieExecutable), closed: closedPaddocks(sandboxProject(t))) {
                throw ProtocolError(code: .invalidArgs, message: why)
            }
            let owner: UUID
            if scope == .lot {
                guard let l = ws.lot(of: t.id) else { throw ProtocolError(code: .invalidArgs, message: "'\(t.name)' não está em um lote") }
                owner = l.id
            } else { owner = t.id }
            try reserve(t.name); defer { launching.remove(t.name.lowercased()) }
            let g = SandboxGrant(path: path, access: access, scope: scope, owner: owner,
                                 project: scope == .terminal ? try await projectRoot(of: t).path : nil)
            if !sandboxGrants.contains(where: { $0.path == g.path && $0.scope == g.scope && $0.owner == g.owner && $0.project == g.project && ($0.access == .write || g.access == .read) }) {
                let before = sandboxGrants
                sandboxGrants.append(g)
                do { try saveGrants() } catch { sandboxGrants = before; throw error }
            }
            let members = scope == .lot ? ws.lots.first { $0.id == owner }?.members ?? [] : [t.id]
            for m in members { accessCards.removeCovered(terminal: m, by: g) }
            // ponytail: the lot's other running members get it at their next start (only the card's terminal restarts)
            let running = await registry.process(t.id)?.isRunning == true
            if running { _ = try await relaunch(t, resume: true) }
            let env = await agentEnv(t)
            return .object(["grant": try isoJSON(g), "restarted": .bool(running), "resumed": .bool(running && t.resumesConversation && AgentLaunch.hasClaudeConversation(cwd: t.cwd, home: sandboxHomeDir, env: env))])
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

    /// The mode of terminals started from now on: the Collie-wide preference, else the daemon's default (open).
    var sandboxMode: SandboxMode { sandboxPref ?? config.defaultSandboxMode }
    /// `t`'s last sandboxed start was open (its profile, its cards, its cwd bounds: L1).
    func startedOpen(_ t: TerminalRecord) -> Bool { t.sandbox == .sandboxed && t.startMode == .open }

    /// `admin.sandbox`: nil reads; otherwise saved (running terminals keep theirs until they start again).
    func setSandboxMode(_ v: String?) async throws -> JSONValue {
        if let v {
            guard let m = SandboxMode(rawValue: v) else { throw ProtocolError(code: .invalidArgs, message: "mode must be open or strict") }
            var s = CollieSettings.load(config.paths.root); s.terminalSandbox = m
            try s.save(config.paths.root)
            sandboxPref = m
        }
        return .object(["mode": .string(sandboxMode.rawValue)])
    }

    var sandboxHomeDir: URL { config.sandboxHome ?? URL(fileURLWithPath: NSHomeDirectory()) }

    func saveGrants() throws { try SandboxGrantStore(root: config.paths.root).save(sandboxGrants) }

    /// A denial (from the log) or a request → a card for the app. A tag naming no terminal this daemon rendered a profile
    /// for is dropped (R5: a forged or stale tag).
    func raise(_ denial: SandboxDenial) async {
        guard sandboxKnown.contains(denial.terminal) else { return }
        if ws.terminals.first(where: { $0.id == denial.terminal }).map(startedOpen) == true { accessCards.hush(denial); return }   // open mode: Collie's internals, counted only
        let home = sandboxHomeDir, collie = config.paths.root, app = SandboxInput.appBundle(of: config.collieExecutable)
        let closed = ws.terminals.first { $0.id == denial.terminal }.map { closedPaddocks(sandboxProject($0)) } ?? []
        let c = accessCards.add(denial) { d in   // a card to show: what can't be released, and why
            d.refusal = SandboxGrantStore.refusal(d.path, op: d.op, home: home, collie: collie, app: app, closed: closed)
            d.folderRefusal = d.refusal ?? SandboxGrantStore.refusal(d.folder, op: d.op, home: home, collie: collie, app: app, closed: closed)
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

/// Collie-wide preferences the daemon keeps (`<root>/preferences.json`, closed to every terminal with the data root).
struct CollieSettings: Codable {
    var terminalSandbox: SandboxMode?
    /// "Baixar fontes do Google Fonts"; nil: on.
    var googleFonts: Bool?
    static func file(_ root: URL) -> URL { root.appendingPathComponent("preferences.json") }
    /// A missing file: nothing set; one that can't be read: strict (fail closed).
    static func load(_ root: URL) -> CollieSettings {
        guard let data = try? Data(contentsOf: file(root)) else {
            return FileManager.default.fileExists(atPath: file(root).path) ? CollieSettings(terminalSandbox: .strict, googleFonts: false) : CollieSettings()
        }
        return (try? JSONDecoder().decode(CollieSettings.self, from: data)) ?? CollieSettings(terminalSandbox: .strict, googleFonts: false)
    }
    func save(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: Self.file(root), options: [.atomic])
    }
}
