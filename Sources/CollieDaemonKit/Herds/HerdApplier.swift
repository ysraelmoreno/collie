import Foundation
import CollieCore
import CollieProtocol

/// `herd.apply`: all or nothing. Every step that succeeds goes into the journal; any failure undoes the journal
/// backwards, removing only what this application created. Applied by a Shepherd it grants no new power: the
/// herd's Shepherd is the applier, everything it creates is leashed to it, paddocks and panels follow their v1 rules.
extension CommandRouter {
    // ponytail: the journal lives in memory; if the daemon dies mid-apply, what was created stays (README says so). A
    // journal on disk replayed at start-up if partial teams ever matter.
    private struct ApplyJournal {
        var paddock: Paddock?
        var terminals: [(key: String, rec: TerminalRecord)] = []
        var panels: [(key: String, panel: Panel)] = []
        /// Design files this application created (left in place by the undo, with a warning).
        var designFiles: [String] = []
    }

    func applyHerd(_ r: Request, caller: TerminalRecord?) async throws -> JSONValue {
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        let id = try need(r, "id"), applyName = try need(r, "name")
        try refuseFree(r)   // a herd's terminals are always sandboxed
        if let me = caller { try refuseFreeSummoner(me) }
        guard let pt = await herds.get(id) else { throw ProtocolError(code: .notFound, message: "rebanho '\(id)' não existe") }
        // one application at a time per workspace: the next waits
        // ponytail: 100 ms polling; a continuation queue if many ever wait at once
        while applyingHerd { try await Task.sleep(for: .milliseconds(100)) }
        applyingHerd = true; defer { applyingHerd = false }

        // MARK: preflight: nothing is created when any of it fails
        if let expect = str(r, "expect"), expect != HerdFormat.digest(pt) {
            throw invalid("o rebanho mudou desde a prévia; confira de novo")
        }
        try HerdFormat.validate(pt)
        let wantsPaddock: Bool
        switch r.args["paddock"] {
        case nil, .null?: wantsPaddock = pt.wantsPaddock
        case .bool(let b)?: wantsPaddock = b
        case .string("true")?: wantsPaddock = true
        case .string("false")?: wantsPaddock = false
        default: throw invalid("paddock deve ser true ou false")
        }
        // the paddock it is applied on: the app's (the one on screen), a Shepherd's own
        var onPaddock: Paddock?
        if let n = str(r, "onPaddock"), !n.isEmpty {
            do { onPaddock = try findPaddock(n) } catch { throw invalid("cercado \(n) não existe ou está ocupado") }
            if let me = caller, onPaddock?.id != me.paddockId { throw invalid("um Pastor aplica rebanhos só no seu próprio cercado") }
        }
        let cwd: String
        if let me = caller {
            if let c = str(r, "cwd"), URL(fileURLWithPath: c).standardizedFileURL != URL(fileURLWithPath: me.cwd).standardizedFileURL {
                throw invalid("um Pastor aplica rebanhos só no seu próprio cwd")
            }
            cwd = me.cwd
        } else if let c = str(r, "cwd") { cwd = c } else if let f = onPaddock { cwd = f.path } else { cwd = try need(r, "cwd") }
        let allowed: URL? = if let me = caller { try await projectRoot(of: me) } else { nil }   // the applier's project bounds the herd's
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else { throw invalid("pasta \(cwd) não existe") }

        // the applying Shepherd plays the herd's Shepherd: that terminal is not created
        let played = caller == nil ? nil : pt.terminals.first(where: \.isShepherd)?.key
        let made = pt.terminals.filter { $0.key != played }
        func member(_ key: String) -> String { HerdFormat.memberName(apply: applyName, key: key) }
        func taken(_ n: String) -> Bool {
            ws.terminals.contains { $0.name.caseInsensitiveCompare(n) == .orderedSame } || panel(named: n) != nil
                || ws.paddocks.contains { $0.name.caseInsensitiveCompare(n) == .orderedSame }
        }
        var reserved: [String] = [], claimed: String?
        defer {
            for n in reserved { launching.remove(n.lowercased()) }
            if let claimed { paddockBusy.remove(claimed.lowercased()) }
        }
        for n in made.map({ member($0.key) }) + pt.panels.map({ member($0.key) }) {
            if taken(n) { throw invalid("o nome \(n) já está em uso") }
            do { try reserve(n) } catch { throw invalid("o nome \(n) está sendo criado agora") }
            reserved.append(n)
        }
        var repo: URL?
        if wantsPaddock {
            let slug = HerdFormat.slug(applyName), name = slug.isEmpty ? "rebanho" : slug
            do { try PaddockManager.validate(name: name) } catch { throw invalid("nome de cercado inválido: \(name)") }
            if taken(name) { throw invalid("o cercado \(name) já existe") }
            do { try claim(name) } catch { throw invalid("o cercado \(name) está ocupado") }
            claimed = name
            let root: URL
            do { root = try await PaddockManager.repoRoot(of: URL(fileURLWithPath: cwd)) } catch {
                throw invalid("\(cwd) não está num repositório git: um cercado precisa de um")
            }
            if let me = caller, !(try await paddockRepoAllowed(root, for: me)) {
                throw invalid("o repositório \(root.path) fica fora do seu projeto: o cercado seria mais largo que ele")
            }
            // what PaddockManager.create would refuse, refused here in Portuguese
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("\(LegacyOrq.repoDirName(repoRoot: root))/paddocks/\(name)").path) {
                throw invalid("o cercado \(name) já existe")
            }
            for b in ["collie/\(name)", LegacyOrq.branchPrefix + name] {   // an Orq paddock's branch too
                if try await GitRunner.run(["show-ref", "--verify", "--quiet", "refs/heads/\(b)"], in: root).status == 0 {
                    throw invalid("a branch \(b) já existe")
                }
            }
            repo = root
        }
        for p in pt.panels {
            guard let spec = PluginRegistry.spec(p.pluginId), spec.placements.contains(p.placement) else {
                throw invalid("plug-in \(p.pluginId) não está disponível")
            }
            // headless panels belong to the terminal that opens them, never to a herd
            guard p.placement != .headless else { throw invalid("painel \(p.key): headless não vale em rebanho") }
        }
        // the PATH the agents get (the user's, else the daemon's)
        let path = UserEnvironment.merge(user: await userEnv.current(), collie: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"],
                                         collieBin: config.collieExecutable.deletingLastPathComponent().path)["PATH"] ?? ""
        for preset in [Preset.claude, .codex] where made.contains(where: { $0.preset == preset && $0.command == nil }) {
            // ponytail: a few stat calls on the actor
            guard path.split(separator: ":").contains(where: { FileManager.default.isExecutableFile(atPath: "\($0)/\(preset.rawValue)") }) else {
                throw invalid("\(preset.rawValue) não encontrado")
            }
        }

        var j = ApplyJournal()
        var warnings: [String] = []
        do {
            try await runApply(pt, made: made, played: played, member: member, cwd: cwd, paddock: claimed.map { ($0, repo!) },
                               onPaddock: caller == nil ? onPaddock?.name : nil, caller: caller, allowed: allowed, journal: &j, warnings: &warnings)
        } catch {
            let e = error as? ProtocolError ?? ProtocolError(code: .internal, message: error is CancellationError ? "aplicação cancelada" : "\(error)")
            // detached: runs to the end even when the request was cancelled
            let undo = await Task { await self.undoApply(j) }.value
            let all = warnings + undo
            throw ProtocolError(code: e.code, message: e.message + (all.isEmpty ? "" : " (" + all.joined(separator: "; ") + ")"))
        }

        // one lot for the herd: its terminals, and the applying Shepherd when it is in no lot yet (join would move it)
        let base = String((j.paddock?.name ?? applyName).prefix(64))
        var lotName = base, n = 2   // unique after the 64-character cut
        while ws.lots.contains(where: { $0.name.caseInsensitiveCompare(lotName) == .orderedSame }) {
            let s = "-\(n)"; lotName = String(base.prefix(64 - s.count)) + s; n += 1
        }
        let lot = Lot(name: lotName, goal: String(pt.summary.prefix(500)),
                      paddockId: j.paddock?.id ?? caller?.paddockId ?? onPaddock?.id)
        var members = j.terminals.map(\.rec.id)
        if let me = caller, ws.lot(of: me.id) == nil { members.insert(me.id, at: 0) }
        let lotsBefore = ws.lots
        ws.lots.append(lot)
        do { try await place(members, in: lot.id) } catch { ws.lots = lotsBefore; warnings.append("lote \(lot.name) não foi salvo") }   // the herd stands either way

        // the app places the nodes; frames are relative to the herd's corner (the applier stands at its Shepherd's)
        var frames: [String: HerdFrame] = [:]
        var ids: [String: UUID] = Dictionary(uniqueKeysWithValues: j.terminals.map { ($0.key, $0.rec.id) } + j.panels.map { ($0.key, $0.panel.id) })
        if let played, let me = caller { ids[played] = me.id }
        let placed = pt.withGridFrames   // frameless items (a Shepherd's save) still get a cell
        for t in placed.terminals { if let f = t.frame, let i = ids[t.key] { frames[i.uuidString] = f } }
        for p in placed.panels { if let f = p.frame, let i = ids[p.key] { frames[i.uuidString] = f } }
        await hub.emit(.herdApplied(by: caller?.id, anchor: played == nil ? nil : caller?.id, frames: frames, paddock: j.paddock?.id))

        var out: [String: JSONValue] = [
            "terminals": .array(j.terminals.map { .object(["key": .string($0.key), "id": .string($0.rec.id.uuidString), "name": .string($0.rec.name)]) }),
            "panels": .array(j.panels.map { .object(["key": .string($0.key), "id": .string($0.panel.id.uuidString), "name": .string($0.panel.name)]) }),
            "frames": try isoJSON(frames),
            "warnings": .array(warnings.map { .string($0) }),
        ]
        if let f = j.paddock { out["paddock"] = .object(["id": .string(f.id.uuidString), "name": .string(f.name)]) }
        if ws.lots.contains(where: { $0.id == lot.id }) { out["lot"] = .object(["id": .string(lot.id.uuidString), "name": .string(lot.name)]) }
        return .object(out)
    }

    /// Steps 1–6, each journaled as it succeeds: paddock, terminals, readiness, terminal leashes, panels (and their leashes), roles.
    private func runApply(_ pt: Herd, made: [HerdTerminal], played: String?, member: (String) -> String, cwd: String,
                          paddock: (name: String, repo: URL)?, onPaddock: String?, caller: TerminalRecord?, allowed: URL?,
                          journal j: inout ApplyJournal, warnings: inout [String]) async throws {
        // the app's apply on a paddock: that paddock (re-found by name: it may have gone meanwhile)
        let base: UUID? = try caller?.paddockId ?? onPaddock.map { n throws(ProtocolError) in try findPaddock(n).id }
        if let paddock {
            do { j.paddock = try await createPaddock(paddock.name, repo: paddock.repo, createdBy: caller?.id) }
            catch let e as ProtocolError { throw ProtocolError(code: e.code, message: "cercado \(paddock.name): \(e.message)") }
        }

        let fl = j.paddock ?? ws.paddocks.first { $0.id == base }
        let at = caller == nil ? j.paddock?.path ?? cwd : SignedAppCheck.realPath(URL(fileURLWithPath: j.paddock?.path ?? cwd))   // a Shepherd's: as checked
        // a paddock this application made bounds its own terminals, like a Shepherd's `summon --paddock`
        let root = try allowed.map { a throws(ProtocolError) in
            try childProject(cwd: at, paddock: fl, allowed: j.paddock.map { ProjectRoot.resolve(cwd: $0.path, paddock: $0) } ?? a, open: caller.map(startedOpen) ?? false)
        } ?? ProjectRoot.resolve(cwd: at, paddock: fl, home: sandboxHomeDir)
        for t in made {
            try Task.checkCancellation()
            let rec = TerminalRecord(id: UUID(), name: member(t.key), preset: t.preset, command: t.command, cwd: at,
                                     isShepherd: t.isShepherd, paddockId: j.paddock?.id ?? base, projectRoot: root.path)
            j.terminals.append((t.key, rec))   // before the launch: a launch that fails halfway is undone too
            _ = try await launch(rec)
            try await ensurePaddock(of: rec)
        }

        let wait = config.herdReady
        let late = await withTaskGroup(of: String?.self) { g in
            for (_, rec) in j.terminals { g.addTask { [asks] in await asks.waitReady(rec.id, timeout: wait) ? nil : rec.name } }
            var late = Set<String>()
            for await n in g { if let n { late.insert(n) } }
            return late
        }
        for (_, rec) in j.terminals where late.contains(rec.name) {
            if await registry.process(rec.id)?.isRunning != true { throw ProtocolError(code: .notRunning, message: "terminal \(rec.name) saiu") }
            throw ProtocolError(code: .timeout, message: "terminal \(rec.name) não ficou pronto em \(wait.components.seconds) s")
        }
        // readyMax latches a terminal sitting at a prompt (trust folder, login): typing a role there would answer it
        // ponytail: early and redundant (fails before leashes and panels are made); the guarded inject decides at the write
        func atApproval(_ rec: TerminalRecord) -> ProtocolError {
            ProtocolError(code: .unavailable, message: "terminal \(rec.name) está pedindo aprovação; papel não entregue")
        }
        func approvalPending(_ rec: TerminalRecord) async throws {
            if await asks.hasPendingApproval(rec.id) { throw atApproval(rec) }
        }
        for (_, rec) in j.terminals { try await approvalPending(rec) }

        var recs = Dictionary(uniqueKeysWithValues: j.terminals.map { ($0.key, $0.rec) })
        if let played, let me = caller { recs[played] = me }
        if let me = caller { for (_, rec) in j.terminals { try await leash(me, rec) } }   // like summon
        for c in pt.leashes { if let a = recs[c[0]], let b = recs[c[1]] { try await leash(a, b) } }

        for p in pt.panels {
            try Task.checkCancellation()
            let name = member(p.key)
            var state: [String: JSONValue] = ["storage": p.state["storage"] ?? .string(StorageScope.isolated.rawValue)]
            if let u = p.state["url"] { state["url"] = u }
            if p.pluginId == "diagram", let f = p.state["file"] { state["file"] = f }   // the file in the applier's project
            var file: String?
            if p.pluginId == "design" { if case .string(let s)? = p.state["file"] { file = s } else { file = name } }
            do {
                let fl = try j.paddock?.id ?? canvasPaddock(onPaddock, caller: caller)
                let (panel, warn, created) = try await openPanel(name: name, pluginId: p.pluginId, placement: p.placement, state: state,
                                                                 file: file, paddock: fl, caller: caller)
                if created, let file { j.designFiles.append(file) }
                j.panels.append((p.key, panel))
                if case .string(let w)? = warn["designSystemError"] { warnings.append("painel \(name): \(w)") }
            } catch let e as ProtocolError { throw ProtocolError(code: e.code, message: "painel \(name): \(e.message)") }
        }
        let panels = Dictionary(uniqueKeysWithValues: j.panels.map { ($0.key, $0.panel) })
        for c in pt.leashes {
            if let t = recs[c[0]], let p = panels[c[1]] { try await leash(t, p) } else if let t = recs[c[1]], let p = panels[c[0]] { try await leash(t, p) }
        }

        // the only tokens spent: the roles the herd defines (the app showed them before confirming)
        for (key, rec) in j.terminals {
            guard let role = pt.terminals.first(where: { $0.key == key })?.role, !role.isEmpty else { continue }
            try Task.checkCancellation()
            try await approvalPending(rec)
            do { try await asks.inject(to: rec.id, prompt: role) }   // R10: guarded, refused at an approval prompt
            catch where error == AskCoordinator.awaitingApproval(rec.name) { throw atApproval(rec) }
            catch { throw ProtocolError(code: error.code, message: "terminal \(rec.name): papel não entregue: \(error.message)") }
        }
    }

    /// Backwards: panels, then terminals (their leashes go with them; every leash made has a created end), then the paddock,
    /// only while its branch has no commits beyond the base. Failures become warnings.
    private func undoApply(_ j: ApplyJournal) async -> [String] {
        var warnings: [String] = []
        for (_, p) in j.panels.reversed() where ws.panels.contains(where: { $0.id == p.id }) {
            do { try await remove(p) } catch { warnings.append("painel \(p.name) não foi removido") }
        }
        // through the normal remove: the work registry closes their works as "removed"; one never launched has nothing to remove
        var stillRunning = false
        for (_, t) in j.terminals.reversed() where ws.terminals.contains(where: { $0.id == t.id }) {
            do { try await remove(t) } catch { stillRunning = true; warnings.append("terminal \(t.name) não foi removido") }
        }
        // ponytail: a design file is never deleted (panel.close keeps them too); the user is told it stays
        for name in j.designFiles { warnings.append("arquivo de design \(name) mantido") }
        guard let f = j.paddock else { return warnings }
        // a terminal that may still run in the worktree keeps it (ours that failed to go, or one opened there meanwhile)
        guard !stillRunning, !ws.terminals.contains(where: { $0.paddockId == f.id }) else {
            warnings.append("cercado \(f.name) mantido: há terminal nele"); return warnings
        }
        do {
            let n = try await GitRunner.run(["rev-list", "--count", "\(f.baseBranch)..\(f.branch)"], in: URL(fileURLWithPath: f.repoRoot))
            guard n.status == 0 else { warnings.append("cercado \(f.name) mantido: o git não respondeu"); return warnings }
            guard n.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0" else {
                warnings.append("cercado \(f.name) mantido: tem commits"); return warnings
            }
            // only an empty paddock goes: anything uncommitted, ignored files included (build output, .env), keeps it; but
            // Collie's own memory files
            let st = try await GitRunner.run(["status", "--porcelain", "--ignored=matching", "--", "."] + LegacyOrq.memoryExcludes,
                                             in: URL(fileURLWithPath: f.path))
            guard st.status == 0, st.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                warnings.append("cercado \(f.name) mantido: tem alterações"); return warnings
            }
            try await PaddockManager.delete(f, force: true)
            await memory.evict(under: f.path)
            ws.paddocks.removeAll { $0.id == f.id }
            try await persist()
            await hub.emit(.paddockRemoved(f.id))
        } catch { warnings.append("cercado \(f.name) mantido: não foi possível removê-lo") }
        return warnings
    }
}
