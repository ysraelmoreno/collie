import Foundation
import CollieCore
import CollieProtocol

/// `memory.*`: the admin token (same managed-terminal ancestry check as `admin.*`) or a terminal token.
/// Memory isn't leash-gated: a terminal reads/writes the memory of its cwd's repo (plus the global one);
/// review/restore/pin/cleanup/purge/repos are admin-only. The admin picks the store with `repo` (default: its cwd).
/// A terminal in a lot also reads/writes that lot's store, never another lot's: `--lot`/`--all` reach another lot only for
/// the admin, or a Shepherd over lots whose every live member it reaches (`mayEnter`, as `lot.join`); else `notFound`.
extension CommandRouter {
    /// `memory.*` commands that change no record (the rest re-render the skills dirs).
    static let memoryReads: Set<String> = ["memory.search", "memory.list", "memory.get", "memory.context", "memory.hookContext",
                                           "memory.hookRelevant", "memory.task", "memory.mcp-profile", "memory.digest", "memory.repos", "memory.curator", "memory.stats", "memory.doc-search"]

    func memoryCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin
        if let me = caller { memory.events.noteAgent(me.id, Self.agentName(me)) }   // the events of this terminal say who it runs
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        let paddockName = caller?.paddockId.flatMap { id in ws.paddocks.first { $0.id == id }?.name }
        let myLot = caller.flatMap { ws.lot(of: $0.id) }
        let project: RepoMemory
        if let me = caller {
            project = await memory.repo(for: me.cwd)
        } else if let p = str(r, "repo") {
            guard try await memory.global.run({ _ in FileManager.default.fileExists(atPath: p) }) else { throw invalid("repo '\(p)' does not exist") }
            project = await memory.repo(for: p)
        } else {
            project = await memory.repo(for: r.cwd ?? memory.global.path)
        }
        /// A lot the caller may read: unknown and out-of-reach lots look the same (no leak).
        func enterable(_ l: Lot) -> Bool { caller.map { mayEnter(l, $0) } ?? true }
        let lotArg = try str(r, "lot").map { n throws(ProtocolError) -> Lot in
            guard let l = try? findLot(n), enterable(l) else { throw ProtocolError(code: .notFound, message: "Lot '\(n)' not found") }
            return l
        }
        let repo = if let lotArg { await memory.lotStore(lotArg.id) } else { project }
        // agents read their lot + repo + the global memory; the admin (or an explicit --lot) works on exactly that store
        var stores = [repo]
        if caller != nil, lotArg == nil {
            stores = (repo === memory.global ? [] : [repo]) + [memory.global]
            if let myLot { stores.insert(await memory.lotStore(myLot.id), at: 0) }
        }
        let adminCommands: Set<String> = ["memory.review", "memory.restore", "memory.pin", "memory.unpin",
                                          "memory.cleanup", "memory.purge", "memory.repos", "memory.curator",
                                          "memory.digest", "memory.undo", "memory.resolve", "memory.confirm", "memory.consolidate", "memory.doc-add",
                                          "memory.trust", "memory.untrusted", "memory.provenance-status", "memory.cursor-mode"]
        if caller != nil, adminCommands.contains(r.command) {
            throw ProtocolError(code: .unauthorized, message: "'\(r.command)' is admin-only")
        }
        func id() throws(ProtocolError) -> UUID {
            guard let u = UUID(uuidString: try need(r, "id")) else { throw invalid("'id' must be a memory id") }
            return u
        }
        /// Runs `change` on the record `id` in `repo`'s store (refuses an unknown id).
        func update(_ id: UUID, _ change: @escaping @Sendable (inout MemoryRecord, RepoMemory) throws -> Void) async throws -> JSONValue {
            let rec = try await repo.run { m -> MemoryRecord in
                guard var rec = m.store.all().records.first(where: { $0.id == id }) else {
                    throw ProtocolError(code: .notFound, message: "memory \(id.uuidString.lowercased()) not found")
                }
                try change(&rec, m)
                return rec
            }
            return try memJSON(rec, repo)
        }

        switch r.command {
        case "memory.save":
            // feedback is the user's (a correction, the app): an agent can't save one
            guard let kind = MemoryKind(rawValue: try need(r, "kind")), caller == nil || kind != .feedback else {
                throw invalid("kind must be decision|map|pitfall|procedure")
            }
            let lot = lotArg ?? myLot
            guard let scope = MemoryScope(rawValue: str(r, "scope") ?? (lot != nil ? "lot" : "project")) else {
                throw invalid("scope must be lot|project|paddock|global")
            }
            let origin = caller.map { "\($0.name) (\($0.preset.rawValue))" } ?? "app"
            let (saved, target, old) = try await saveMemory(kind, scope: scope, subject: try need(r, "subject"), title: try need(r, "title"),
                                                            body: str(r, "body") ?? "", path: str(r, "path"), repo: project,
                                                            paddock: paddockName, lot: lot, origin: origin,
                                                            proposed: caller != nil && kind == .procedure)
            if kind == .pitfall { await enqueuePitfall(saved.id, store: target) }
            var ev = MemoryEvent(type: .created, terminal: caller?.id, ids: [saved.id], kinds: [kind.rawValue], scopes: [saved.scope.rawValue],
                                 source: caller == nil ? "user" : "agent")
            ev.place(store: target.key)
            memory.events.emit(ev)
            return try memJSON(saved, target, ["superseded": old.map { .string($0.id.uuidString) } ?? .null])

        case "memory.search":
            let query = try need(r, "query")
            let limit = Int(try num(r, "limit", max: 50) ?? 10), inactive = flag(r, "inactive")
            if flag(r, "all") {
                guard lotArg == nil else { throw invalid("--lot and --all are exclusive") }
                for l in ws.lots where l.id != myLot?.id && enterable(l) { stores.insert(await memory.lotStore(l.id), at: 0) }
            }
            let vector = await memory.embed(query), factors = await memory.scores.all()
            var cands: [MemoryIndex.Candidate] = [], from: [UUID: RepoMemory] = [:]
            for s in stores {
                // over-fetch: paddock memories of other paddocks are filtered out below
                // the picked repo's index must work; a broken global one only drops its hits
                let required = s === repo && s.exists   // a lot with no memories yet has no index: no hits
                let found = try await s.run { m in
                    (required ? try m.requireIndex() : m.index())?.candidates(query, vector: vector, limit: limit * 2 + 10, includeInactive: inactive) ?? []
                }
                for var c in found where caller == nil || MemoryService.visible(c.record, paddock: paddockName, lot: s.lotId) {
                    c.m *= factors[c.record.id] ?? 1
                    cands.append(c); from[c.record.id] = s
                }
            }
            let hits = MemoryIndex.rank(cands, lang: vector?.lang).prefix(limit).map { (hit: $0, store: from[$0.record.id]!) }   // one scale (R10)
            if let me = caller { searched(me, ids: hits.map(\.hit.record.id), lot: myLot?.id, project: project.root?.path) }
            for s in stores {
                let ids = hits.filter { $0.store === s }.map(\.hit.record.id)
                if !ids.isEmpty { _ = try? await s.run { m in m.index()?.noteRead(ids) } }
            }
            return .array(try hits.map { try memJSON($0.hit.record, $0.store, ["score": .number($0.hit.score)]) })

        case "memory.doc-add":
            // ponytail: no copy of the file is kept; the chunks live in the index only (delete the cache: re-ingest the file)
            let given = try need(r, "path")
            let url = URL(fileURLWithPath: given, relativeTo: r.cwd.map { URL(fileURLWithPath: $0) }).standardizedFileURL
            let chunks: [(heading: String, body: String)]
            do {
                chunks = DocIngest.chunk(LotBoards.scrub(try DocIngest.extract(url)))
            } catch let f as DocIngest.Failure { throw invalid(f.message) }
            guard !chunks.isEmpty else { throw invalid("no text in \(url.lastPathComponent)") }
            let source = url.lastPathComponent, tag = str(r, "paddock")
            let ids = try await repo.run { m in try m.requireIndex().replaceChunks(source: source, paddock: tag, chunks) }
            Task.detached { await repo.fillVectors(opening: false) }   // the meaning vectors arrive after the words
            let jobs = await enqueueDocTerms(store: repo, source: source, chunks: zip(ids, chunks).map { ($0, $1.heading, $1.body) })
            return .object(["source": .string(source), "chunks": .number(Double(ids.count)), "termJobs": .number(Double(jobs))])

        case "memory.doc-search":
            let query = try need(r, "query"), limit = Int(try num(r, "limit", max: 20) ?? 5)
            let vector = await memory.embed(query)
            var found: [MemoryIndex.ChunkHit] = []
            for s in stores {
                found += (try? await s.run { m in m.index()?.searchChunks(query, vector: vector, paddock: paddockName, limit: limit) }) ?? []
            }
            return .array(found.sorted { $0.score > $1.score }.prefix(limit).map {
                .object(["source": .string($0.source), "heading": .string($0.heading), "text": .string($0.body), "score": .number($0.score)])
            })

        case "memory.list":
            let kind = try str(r, "kind").map { k throws(ProtocolError) -> MemoryKind in
                guard let v = MemoryKind(rawValue: k) else { throw invalid("kind must be feedback|decision|map|pitfall|procedure") }
                return v
            }
            guard let status = MemoryStatus(rawValue: str(r, "status") ?? "active") else {
                throw invalid("status must be active|proposed|superseded|archived|discarded")
            }
            let unreviewed = flag(r, "unreviewed"), candidates = flag(r, "candidates"), (keep, asked) = await proposalState()
            var rows: [JSONValue] = [], problems: [JSONValue] = [], rowHits: [Int] = []
            for s in stores {
                let (recs, probs, missing) = try await s.run { m in
                    let idx = m.index()   // refresh first: resolves two actives a land (or a hand edit) left behind
                    try? MemoryCleanup.expireProposals(store: m.store, keep: keep, asked: asked)
                    let all = m.store.all()
                    let recs = all.records.filter {
                        $0.status == status && (kind == nil || $0.kind == kind) && (!unreviewed || !$0.reviewed)
                            && (!candidates || $0.isEnforceCandidate)
                    }.sorted { $0.updatedAt > $1.updatedAt }
                    var missing: [UUID: Date] = [:]
                    for r in recs where r.kind == .map { if let d = idx?.stats(r.id)?.missingSince { missing[r.id] = d } }
                    return (recs, all.problems, missing)
                }
                for rec in recs where caller == nil || MemoryService.visible(rec, paddock: paddockName, lot: s.lotId) {
                    rows.append(try memJSON(rec, s, missing[rec.id].map { ["missingSince": .string(isoString($0))] } ?? [:]))
                    rowHits.append(rec.hits ?? 0)
                }
                problems += probs.map { .object(["file": .string(s.store.dir.appendingPathComponent($0.file).path), "error": .string($0.error)]) }
            }
            // --candidates: the most repeated first, across the stores (each store's rows come newest first)
            if candidates { rows = zip(rows, rowHits).enumerated().sorted { ($1.element.1, $0.offset) < ($0.element.1, $1.offset) }.map(\.element.0) }
            return .object(["records": .array(rows), "problems": .array(problems)])

        case "memory.get":
            let id = try id()
            for s in stores {
                let found = try await s.run { m -> (MemoryRecord, MemoryStats?)? in
                    guard let rec = m.store.all().records.first(where: { $0.id == id }) else { return nil }
                    return (rec, m.index()?.stats(id))
                }
                guard let (rec, st) = found, caller == nil || MemoryService.visible(rec, paddock: paddockName, lot: s.lotId) else { continue }
                var extra: [String: JSONValue] = ["reads": .number(Double(st?.reads ?? 0)), "score": .number(await memory.scores.factor(id))]
                if let d = st?.lastReadAt { extra["lastReadAt"] = .string(isoString(d)) }
                if let d = st?.missingSince { extra["missingSince"] = .string(isoString(d)) }
                _ = try? await s.run { m in m.index()?.noteRead([id]) }
                if let me = caller { searched(me, ids: [rec.id], lot: myLot?.id, project: project.root?.path); await memory.noteGet(me.id, record: rec) }
                return try memJSON(rec, s, extra)
            }
            throw ProtocolError(code: .notFound, message: "memory \(id.uuidString.lowercased()) not found")

        case "memory.context":
            let cwd = caller?.cwd ?? project.root?.path ?? memory.global.path
            return .object(["output": .string(await memory.contextText(cwd: cwd, paddock: paddockName, lot: (lotArg ?? myLot)?.id).text)])

        case "memory.checklist":
            let cwd = caller?.cwd ?? project.root?.path ?? memory.global.path
            let text = await memory.checklist(cwd: cwd, lot: (lotArg ?? myLot)?.id).text
            return .object(["output": .string(text.isEmpty ? "Nenhuma armadilha registrada neste projeto." : text)])

        case "memory.hookContext", "memory.hookRelevant":
            guard let me = caller else { throw ProtocolError(code: .unauthorized, message: "'\(r.command)' is for terminals only") }
            if let tr = str(r, "transcript") { await memory.noteSession(me.id, transcript: tr) }   // the session its events name
            let text: String
            if r.command == "memory.hookContext" {
                await asks.sessionHooked(me.id)
                // compact/resume: the work state (first), the board's handoff and status posts, then the memory index, in one 4096-byte budget
                let recall = ["compact", "resume"].contains(str(r, "source") ?? "")
                var head: [String] = []
                if recall {
                    if let w = try? await work.active(terminal: me.id) { head.append(WorkStatusText.recall(w)) }
                    if let myLot { head.append(await boards.recall(to: me.id, lot: myLot, limit: 1_200)) }
                    head = head.filter { !$0.isEmpty }
                }
                let used = head.reduce(0) { $0 + $1.utf8.count + 2 }
                // only Claude and Cursor run this hook
                let cursor = Self.agentName(me) == "cursor"
                let mode: CursorMemoryMode = cursor ? CollieSettings.load(config.paths.root).cursorMemoryMode : .start
                // PRD B3 req. 4: a Shepherd hears of the recurring pitfalls no check enforces yet
                var candidates = 0
                if me.isShepherd {
                    for s in stores {
                        candidates += ((try? await s.run { m in m.store.all().records.filter(\.isEnforceCandidate) }) ?? [])
                            .filter { MemoryService.visible($0, paddock: paddockName, lot: s.lotId) }.count
                    }
                }
                let orientation = CollieOrientation.text(
                    terminal: me.name, isShepherd: me.isShepherd, paddock: paddockName,
                    peers: ConnectionGraph.reachable(from: me.id, in: ws).map(\.name),
                    panels: ConnectionGraph.reachablePanels(from: me.id, in: ws).map { ($0.name, $0.pluginId) },
                    paddockPanels: ws.panels.filter { $0.paddockId != nil && $0.paddockId == me.paddockId }.map { ($0.name, $0.pluginId) },
                    designFirst: ws.designFirst, lot: myLot.map { ($0.name, $0.goal) }, morePanels: !PluginRegistry.externalSpecs.isEmpty,
                    agent: cursor ? "cursor" : "claude",
                    sharedFolder: await sharedFolder(me),
                    figcraftAvailable: { if case .installed = engineState() { true } else { false } }(), memoryTask: cursor && mode == .full, candidates: candidates)
                if cursor && mode == .off { text = orientation; return .object(["output": .string(text)]) }   // "Desligada": no memory block
                // Cursor `full`: the time line (≤ 70 B) and the focus block, all under `cursorCap` with the orientation
                let stamp = cursor && mode == .full ? "memória de \(Self.hourMinute.string(from: Date())); novidades e memória da tarefa: memory_task" : ""
                let total = Self.cursorCap - orientation.utf8.count - 2 - (stamp.isEmpty ? 0 : stamp.utf8.count + 2)
                await refreshSkills(me.id)   // a session (re)starts: its skills as the stores are now (a hand edit, a pull)
                let w = try? await work.active(terminal: me.id)
                await memory.resetDocs(me.id)
                let docs = await memory.docsLine(cwd: me.cwd, paddock: paddockName, lot: myLot?.id)
                let docsRoom = docs.isEmpty ? 0 : docs.utf8.count + 2
                let rest = await memory.context(for: me.id, cwd: me.cwd, paddock: paddockName, lot: myLot?.id, work: w?.id,
                                                limit: Swift.min(4096, total) - used - docsRoom,
                                                source: str(r, "source"), workTitle: w?.title,
                                                openTasks: (w?.tasks ?? []).filter { [.open, .inProgress].contains($0.state) }.map(\.title),
                                                lotGoal: myLot?.goal,
                                                focusBlock: mode == .full && cursor ? (Self.focusBudget, Self.focusMax, total - used - docsRoom) : nil)
                let mem = (head + [rest == MemoryService.header ? "" : rest, docs]).filter { !$0.isEmpty }.joined(separator: "\n\n")
                    // P2: a secret in a memory (a hand-written file skips `memory.save`'s hiding) never reaches the agent
                    .scrubbed(await auth.secrets())
                // ponytail: the bare header (no memories) counts as empty
                var full = mem.isEmpty || mem == MemoryService.header ? orientation : orientation + "\n\n" + mem
                if !stamp.isEmpty { full += "\n\n" + stamp }
                // the hard cap (B1: no client check on sessionStart, the server's limit unknown): whole lines off the end,
                // never the orientation. ponytail: the budgets above keep it from firing; this is the guard
                text = cursor ? Self.capped(full, keep: orientation, max: Self.cursorCap) : full
            } else {
                // one 2048-byte budget: retractions, the rules pushed to the caller, board posts addressed to it (newest
                // first), the user's comments on its pages, then memories
                let prompt = HookPayload.boundedPrompt(try need(r, "prompt"))
                // a likely correction goes to the curator detached: the hook never waits for it
                // R12: taken at every submit (it starts over); the user's own keystrokes, or a proposal at most
                await asks.promptSubmitted(me.id)
                let (user, likely) = asks.provenance.submit(me.id, prompt: prompt)
                let correction = CorrectionDetector.isCorrection(prompt, lastTurn: lastTurn[me.id])
                await memory.resolvePending(for: me.id, correction: correction)   // the last prompt's hits, before this one's search
                if correction || CorrectionDetector.isProcedure(prompt) {
                    Task { await self.enqueueCorrection(terminal: me.id, prompt: prompt, user: user, likely: likely && correction) }
                }
                text = await promptBlock(me, paddock: paddockName, lot: myLot, query: prompt, pull: false)
            }
            return .object(["output": .string(text)])

        case "memory.untrusted":
            // spec 2026-11-17 cursor memory §7 (Confiar): every memory that isn't what the daemon wrote, in the workspace's
            // stores, with the daemon's last text for it (`before`; absent: it never wrote this id) and the text now
            var out: [JSONValue] = []
            var seen: [RepoMemory] = []
            for cwd in ws.terminals.map(\.cwd) + ws.paddocks.flatMap({ [$0.repoRoot, $0.path] }) {
                let m = await memory.repo(for: cwd)
                if !seen.contains(where: { $0 === m }) { seen.append(m) }
            }
            if !seen.contains(where: { $0 === memory.global }) { seen.append(memory.global) }
            var lots: [(RepoMemory, Lot)] = []
            for l in ws.lots { lots.append((await memory.lotStore(l.id), l)) }
            let prov = memory.provenance
            for (s, lot) in seen.map({ ($0, Lot?.none) }) + lots.map({ ($0.0, Optional($0.1)) }) {
                let recs = (try? await s.run { m in m.store.all().records.filter { !prov.isVerified($0) } }) ?? []
                for rec in recs {
                    var o: [String: JSONValue] = ["id": .string(rec.id.uuidString.lowercased()), "kind": .string(rec.kind.rawValue),
                                                  "title": .string(rec.title), "status": .string(rec.status.rawValue),
                                                  "after": .string(MemoryFile.render(rec)), "file": .string(s.file(rec))]
                    if let lot { o["lot"] = .string(lot.name) } else { o["repo"] = .string(s.path) }
                    if let t = prov.entry(rec.id)?.text { o["before"] = .string(t) }
                    out.append(.object(o))
                }
            }
            return .array(out)

        case "memory.provenance-status":
            return .object(["restarted": .bool(memory.provenance.restartedAt != nil), "adopted": .number(Double(memory.provenance.adoptedCount))]
                .merging(memory.provenance.restartedAt.map { ["restartedAt": .string(isoString($0))] } ?? [:]) { a, _ in a })

        case "memory.cursor-mode":
            // Preferências › Memória › "Memória no Cursor"; for sessions started after the change
            var s = CollieSettings.load(config.paths.root)
            if let v = str(r, "value") {
                guard let m = CursorMemoryMode(rawValue: v) else { throw invalid("value must be full|start|off") }
                s.cursorMemory = m.rawValue
                do { try s.save(config.paths.root) } catch { throw ProtocolError(code: .internal, message: "preferences.json: \(error)") }
            }
            return .object(["mode": .string(s.cursorMemoryMode.rawValue)])

        case "memory.mcp-profile":
            // spec 2026-11-17 cursor memory §4: memory_task and its MCP instructions only for a hookless agent with the
            // preference on (Claude has the prompt hook: the tool would be tokens for nothing)
            guard let me = caller else { throw ProtocolError(code: .unauthorized, message: "'memory.mcp-profile' is for terminals only") }
            let agent = Self.agentName(me)
            let on = ["cursor", "codex"].contains(agent) && CollieSettings.load(config.paths.root).cursorMemoryMode == .full
            return .object(["agent": .string(agent), "memoryTask": .bool(on)])

        case "memory.task":
            // spec 2026-11-17 cursor memory §3: what a prompt would bring, pulled by an agent with no prompt hook (Cursor,
            // Codex). The text is the agent's: no provenance, no correction capture, no pending uses (B3)
            guard let me = caller else { throw ProtocolError(code: .unauthorized, message: "'memory.task' is for terminals only") }
            let text = await promptBlock(me, paddock: paddockName, lot: myLot, query: HookPayload.boundedPrompt(try need(r, "task")), pull: true)
            return .object(["output": .string(text.isEmpty ? "Nada novo para esta tarefa." : text)])

        case "memory.review":
            let id = try id()
            let action = try need(r, "action")
            guard ["approve", "discard", "archive"].contains(action) else { throw invalid("action must be approve|discard|archive") }
            let title = str(r, "title"), body = str(r, "body"), subject = str(r, "subject").map(MemoryRecord.normalize)
            if title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true || subject?.isEmpty == true {
                throw invalid("subject and title must not be blank")
            }
            let edited = title != nil || body != nil || subject != nil
            let wasProposed = try await repo.run { m in m.store.all().records.first { $0.id == id }?.status == .proposed }
            let out = try await update(id) { rec, m in
                let store = m.store
                if let title { rec.title = title }
                if let body { rec.body = body }
                let resubject = subject.map { $0 != rec.subject } ?? false
                let prev = rec.supersedes
                if let subject { rec.subject = subject }
                if edited { rec.updatedAt = Date() }
                rec.reviewed = true
                let wasActive = rec.status == .active
                let id = rec.id
                /// The decision `rec` replaced becomes current again (if it is still the one replaced by `rec`).
                func restorePrevious() throws {
                    if let prev, store.all().records.contains(where: { $0.id == prev && $0.status == .superseded && $0.supersededBy == id }) {
                        _ = try MemoryCleanup.restore(prev, store: store, index: m.index())
                    }
                }
                if action == "archive" {
                    // out of injections, restorable, never purged; a replaced decision stays replaced
                    rec.status = .archived
                    try store.write(rec)
                } else if action == "discard" {
                    rec.status = .discarded
                    try store.write(rec)
                    // discarding the current one makes the decision it replaced current again
                    if wasActive { try restorePrevious() }
                } else if rec.status == .proposed {
                    // approving a proposal makes it current: it replaces the active one of its key
                    rec.status = .active
                    rec = try store.save(rec).saved
                } else if resubject, rec.status == .active {
                    rec.supersedes = nil   // it no longer replaces anything under the old subject
                    rec = try store.save(rec).saved   // new chain key: replaces that subject's active one
                    try restorePrevious()   // the old subject's previous decision is current again
                } else {
                    try store.write(rec)
                }
            }
            if edited, caller == nil { await memory.scores.penalize(id, ScoreStore.userEdit, reason: "editada pelo usuário") }
            if action != "approve" || wasProposed {   // approving a proposal (a procedure too) makes it: created by the user
                var ev = MemoryEvent(type: action == "approve" ? .created : action == "archive" ? .archived : .retracted, ids: [id], source: "user")
                ev.place(store: repo.key)
                memory.events.emit(ev)
            }
            // L3: the user decided on a waiting quote: its correction job is moot (never a second rule)
            await cancelCorrection(quote: id)
            return out

        case "memory.trust":
            // P1 "Confiar": the memory as it reads now becomes the daemon's (the file is left as the user edited it)
            let id = try id()
            let rec = try await repo.run { m -> MemoryRecord in
                guard let rec = m.store.all().records.first(where: { $0.id == id }) else {
                    throw ProtocolError(code: .notFound, message: "memory \(id.uuidString.lowercased()) not found")
                }
                return rec
            }
            memory.provenance.record(rec)
            return .object(["id": .string(id.uuidString.lowercased()), "trusted": .bool(true)])

        case "memory.promote":
            let id = try id()
            guard lotArg != nil || myLot != nil else { throw invalid("'memory.promote' moves a lot memory: you are in no lot (app: --lot)") }
            let src = lotArg != nil ? repo : stores[0]
            let target = project
            let old = try await src.run { m -> MemoryRecord in
                guard let rec = m.store.all().records.first(where: { $0.id == id && $0.status == .active }) else {
                    throw ProtocolError(code: .notFound, message: "memory \(id.uuidString.lowercased()) not found")
                }
                return rec
            }
            // a feedback is the user's rule: only the app (or the curator) moves it
            if caller != nil, MemoryLearning.usersKind(old.kind) {
                throw ProtocolError(code: .unauthorized, message: "a \(old.kind.rawValue) memory is the user's: only the app can promote it")
            }
            let rec = MemoryRecord(kind: old.kind, scope: target === memory.global ? .global : .project, subject: old.subject,
                                   title: old.title, body: old.body, path: old.path, reviewed: caller == nil && old.reviewed, pinned: caller == nil && old.pinned,   // an agent's promotion is unreviewed and unpinned
                                   supersedes: old.id, origin: old.origin, aliases: old.aliases)
            let saved = try await target.run { m in try m.store.save(rec).saved }   // replaces the project's active one of that subject
            try await src.run { m in
                var o = old; o.status = .superseded; o.supersededBy = saved.id; o.updatedAt = saved.updatedAt
                try m.store.write(o)
            }
            return try memJSON(saved, target, ["promotedFrom": .string(id.uuidString)])

        case "memory.supersede":   // DX backlog 9: a stale memory retired by a newer one (memory restore undoes it)
            let id = try id()
            guard let by = UUID(uuidString: try need(r, "by")) else { throw invalid("'by' must be a memory id") }
            guard by != id else { throw invalid("a memory can't supersede itself") }
            return try await update(id) { rec, m in
                guard m.store.all().records.contains(where: { $0.id == by && $0.status == .active }) else {
                    throw ProtocolError(code: .notFound, message: "active memory \(by.uuidString.lowercased()) not found")
                }
                rec.status = .superseded; rec.supersededBy = by
                try m.store.write(rec)
            }

        case "memory.enforce":   // PRD B3: a check now enforces this pitfall/decision, so it leaves the injection (not the search)
            let id = try id(), clear = flag(r, "clear"), by = str(r, "by")
            guard clear != (by != nil) else { throw invalid("diga --by <caminho> ou --clear") }
            if let by {
                // the caller's worktree (the app: --repo or its cwd)
                guard let root = project.root else { throw invalid("--by precisa de um repositório git") }
                guard !by.isEmpty, isRepoRelative(by) else { throw invalid("--by: caminho relativo à raiz do repo, sem '..'") }
                guard try await project.run({ _ in repoPathExists(by, root: root) }) else { throw invalid("--by: '\(by)' não existe nesta worktree") }
            }
            let agent = caller != nil
            for s in stores {
                let rec = try await s.run { m -> MemoryRecord? in
                    guard var rec = m.store.all().records.first(where: { $0.id == id }),
                          !agent || MemoryService.visible(rec, paddock: paddockName, lot: m.lotId) else { return nil }
                    guard rec.kind == .pitfall || rec.kind == .decision else {
                        throw ProtocolError(code: .invalidArgs, message: "só armadilha (pitfall) ou decisão pode ser imposta por checagem; esta é \(rec.kind.rawValue)")
                    }
                    rec.enforcedBy = by
                    try m.store.write(rec)
                    return rec
                }
                guard let rec else { continue }
                var ev = MemoryEvent(type: .enforced, terminal: caller?.id, ids: [id], kinds: [rec.kind.rawValue], scopes: [rec.scope.rawValue],
                                     source: caller == nil ? "user" : "agent", reason: by, mode: clear ? "clear" : "set")
                ev.place(store: s.key)
                memory.events.emit(ev)
                return try memJSON(rec, s)
            }
            throw ProtocolError(code: .notFound, message: "memory \(id.uuidString.lowercased()) not found")

        case "memory.restore":
            let id = try id()
            let rec = try await repo.run { m in try MemoryCleanup.restore(id, store: m.store, index: m.index()) }
            await memory.scores.reset(id)   // a restored memory starts over
            await memory.lifecycle.userKept(id, now: Date())
            return try memJSON(rec, repo)

        case "memory.pin", "memory.unpin":
            let pinned = r.command == "memory.pin"
            return try await update(try id()) { rec, m in rec.pinned = pinned; try m.store.write(rec) }

        case "memory.flag":   // the agent's judgement of a memory injected into its own session (admin token: no session, refused)
            let verdicts = ["useful", "wrong", "outdated"].filter { flag(r, $0) || str(r, "verdict") == $0 }
            guard verdicts.count == 1, str(r, "verdict").map({ verdicts.contains($0) }) ?? true, let verdict = FlagVerdict(rawValue: verdicts[0]) else {
                throw invalid("diga um veredito: --useful, --wrong ou --outdated")
            }
            let (session, target) = try await memory.flagTarget(caller?.id, prefix: try need(r, "id"))
            let reason = String(LotBoards.scrub(str(r, "reason") ?? "", secrets: await auth.secrets())
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            var rec: MemoryRecord?
            for s in stores where rec == nil { rec = try await s.run { m in m.store.all().records.first { $0.id == target } } }
            let (contested, queued) = try await memory.applyFlag(session: session, id: target, record: rec, verdict: verdict, reason: reason, terminal: caller?.id)
            return .object(["id": .string(target.uuidString.lowercased()), "contested": .bool(contested), "queued": .bool(queued)])

        case "memory.cleanup":
            let apply = flag(r, "apply"), scores = await memory.scores.all()
            let (items, changed) = try await repo.run { m -> ([CleanupItem], [UUID]) in
                let index = try m.requireIndex()
                let records = m.store.all().records
                var stats: [UUID: MemoryStats] = [:]
                for rec in records { if let s = index.stats(rec.id) { stats[rec.id] = s } }
                let items = MemoryCleanup.plan(records: records, stats: stats, scores: scores, now: Date())
                return (items, apply ? try MemoryCleanup.apply(items, store: m.store).map(\.id) : [])
            }
            return .object(["items": try isoJSON(items), "applied": .array(changed.map { .string($0.uuidString) })])

        case "memory.digest":
            let since = try str(r, "since").map { s throws(ProtocolError) -> Date in
                guard let d = ISO8601DateFormatter().date(from: s) else { throw invalid("since must be an ISO 8601 date") }
                return d
            } ?? .distantPast
            await settleConfirms()
            var entries = digest.since(since, openAsks: true)
            // the panel names a store with `repo`: that store's learnings and the lots' (a lot is shared by projects), never another project's
            if str(r, "repo") != nil { entries = entries.filter { $0.store == repo.key || $0.store.hasPrefix("lot:") } }
            return .object(["entries": try isoJSON(entries), "curator": try isoJSON(await curator.status())])

        case "memory.undo", "memory.resolve":
            guard let e = UUID(uuidString: try need(r, "entry")) else { throw invalid("'entry' must be a digest entry id") }
            if r.command == "memory.undo" { return try isoJSON(try await undoDigest(e)) }
            let keep = try need(r, "keep")
            guard ["newer", "older"].contains(keep) else { throw invalid("keep must be newer|older") }
            return try isoJSON(try await resolveAsk(e, keepNewer: keep == "newer"))

        case "memory.confirm":   // "Parece uma correção sua — confirmar?": Confirmar | Descartar (the app only)
            guard let e = UUID(uuidString: try need(r, "entry")) else { throw invalid("'entry' must be a digest entry id") }
            let action = try need(r, "action")
            guard ["confirm", "discard"].contains(action) else { throw invalid("action must be confirm|discard") }
            return try isoJSON(try await confirmLikely(e, confirm: action == "confirm"))

        case "memory.consolidate":   // run now: the store's cleanup (in the digest) and its cluster job queued
            await consolidate(repo)
            return .object(["queued": .number(Double(await curator.queued(kind: .consolidate).filter { $0.store == repo.key }.count))])

        case "memory.capture":   // a terminal: its own conversation; the app: --terminal <name>
            let t: TerminalRecord
            if let me = caller { t = me } else {
                let n = try need(r, "terminal")
                guard let x = ws.terminals.first(where: { $0.name == n }) else { throw ProtocolError(code: .notFound, message: "Terminal '\(n)' not found") }
                t = x
            }
            guard await captureConversationNow(t.id) else {
                throw ProtocolError(code: .notFound, message: "no Claude conversation seen for '\(t.name)' yet")
            }
            return .object(["queued": .number(Double(await curator.queued(kind: .conversation).count))])

        case "memory.stats":
            return try await memoryStats(r, caller: caller, myLot: myLot, lotArg: lotArg, project: project, stores: stores, paddock: paddockName)

        case "memory.curator":   // admin-only (the app's Preferências): cap, consent, provider/model, test, testCall
            func provider(_ k: String) throws(ProtocolError) -> CuratorProvider? {
                guard let v = str(r, k) else { return nil }
                guard let p = CuratorProvider(rawValue: v) else {
                    throw invalid("'\(k)' must be one of \(CuratorProvider.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                return p
            }
            if let n = try num(r, "cap", max: 10_000) { await curator.setCap(Int(n)) }
            if let p = try provider("consent") { await curator.consent(p) }   // the sheet was accepted: before the switch
            if let p = try provider("provider") { try await curator.setProvider(p, model: str(r, "model")) }
            var extra: [String: JSONValue] = [:]
            if flag(r, "test") {
                let t = await curator.test()
                extra["test"] = .object(["availability": .string(t.availability), "models": .array(t.models.map { .string($0) })])
            }
            if flag(r, "cursorLogin") {   // the Preferences' "Entrar": the app opens a terminal with this line, on a click only
                guard let exe = BinaryLocator.locate("cursor-agent", env: await userEnv.current(), home: NSHomeDirectory()) else {
                    throw ProtocolError(code: .unavailable, message: CursorCuratorRunner.missing)
                }
                do { extra["cursorLogin"] = .string(try CursorCuratorRunner.prepareLogin(root: config.paths.root, exe: exe)) }
                catch { throw ProtocolError(code: .internal, message: "curator: \(error.localizedDescription)") }
            }
            if flag(r, "testCall") {
                extra["testCall"] = .array(try await curator.testCalls().map {
                    .object(["format": .string($0.format), "result": .string($0.result)])
                })
            }
            guard case .object(var o) = try isoJSON(await curator.status()) else { throw ProtocolError(code: .internal, message: "curator status") }
            o.merge(extra) { _, new in new }
            return .object(o)

        case "memory.purge":
            let n = try await repo.run { m -> Int in
                let gone = m.store.all().records.filter { $0.status == .discarded }
                for rec in gone { try m.store.delete(rec.id) }
                return gone.count
            }
            return .object(["deleted": .number(Double(n))])

        case "memory.repos":
            var seen: [RepoMemory] = []
            for cwd in ws.terminals.map(\.cwd) + ws.paddocks.flatMap({ [$0.repoRoot, $0.path] }) {
                let m = await memory.repo(for: cwd)
                if m !== memory.global, !seen.contains(where: { $0 === m }) { seen.append(m) }
            }
            seen.append(memory.global)
            return .array(seen.map { m in
                var o: [String: JSONValue] = ["path": .string(m.path), "scope": .string(m.scope.rawValue)]
                if let f = ws.paddocks.first(where: { $0.path == m.root?.path }) {
                    o["paddock"] = .string(f.name)
                }
                return .object(o)
            })

        default:
            throw invalid("Unknown command '\(r.command)'")
        }
    }

    /// `memory.save`'s validation and store choice: `repo` is the caller's (its cwd's), `paddock` its paddock's name.
    /// Returns the saved record, the store it went to and the record it replaced (same subject).
    /// `proposed`: written as a proposal (R12: an agent's procedure waits for the user), replacing nothing.
    func saveMemory(_ kind: MemoryKind, scope: MemoryScope, subject rawSubject: String, title rawTitle: String, body: String,
                    path rawPath: String?, repo: RepoMemory, paddock paddockName: String?, lot: Lot? = nil,
                    origin: String, proposed: Bool = false) async throws -> (MemoryRecord, RepoMemory, MemoryRecord?) {
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        // memory is never secret-bearing: a live token pasted in is hidden
        let secrets = await auth.secrets()
        func hide(_ x: String) -> String { secrets.reduce(x) { $0.replacingOccurrences(of: $1, with: "[hidden]") } }
        let subject = MemoryRecord.normalize(hide(rawSubject))
        let title = hide(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = hide(body)
        guard !subject.isEmpty, !title.isEmpty else { throw invalid("subject and title must not be blank") }
        guard subject.count <= 300, title.count <= 300, body.utf8.count <= 64 * 1024 else {
            throw invalid("subject/title are limited to 300 characters and body to 64 KiB")
        }
        var target = repo, effective = scope, paddock: String?, lotId: UUID?
        switch scope {
        case .lot:
            guard let lot else { throw invalid("scope 'lot' needs a terminal in a lot (app: --lot)") }
            target = await memory.lotStore(lot.id); lotId = lot.id
        case .paddock:
            guard let paddockName, repo.root != nil else { throw invalid("scope 'paddock' needs a terminal on a paddock") }
            paddock = paddockName
        case .global: target = memory.global
        case .project: if repo.root == nil { effective = .global }   // outside git: the global store
        }
        var path = rawPath
        if let p = path, let root = target.root?.path, p.hasPrefix(root + "/") { path = String(p.dropFirst(root.count + 1)) }
        if let p = path, !isRepoRelative(p) { throw invalid("path must be relative to the repo root (no '..')") }
        let rec = MemoryRecord(kind: kind, scope: effective, paddock: paddock, lotId: lotId, subject: subject, title: title, body: body,
                               path: path, status: proposed ? .proposed : .active, origin: origin)
        let (saved, old) = try await target.run { m -> (saved: MemoryRecord, superseded: MemoryRecord?) in
            if proposed { try m.store.write(rec); return (rec, nil) }
            return try m.store.save(rec)
        }
        return (saved, target, old)
    }

    /// A project decision, saved as `memory.save` would for a caller whose cwd is `cwd` (nil: the global store);
    /// a later one with the same subject replaces it. `by`: the record's origin.
    @discardableResult
    func saveDecision(subject: String, title: String, body: String, cwd: String?, by: String) async throws -> MemoryRecord {
        var repo = memory.global
        if let cwd { repo = await memory.repo(for: cwd) }
        return try await saveMemory(.decision, scope: .project, subject: subject, title: title, body: body, path: nil,
                                    repo: repo, paddock: nil, origin: by).0
    }

    /// A record for agents/the app: ISO dates plus where it lives (`file`) and extras.
    private func memJSON(_ rec: MemoryRecord, _ s: RepoMemory, _ extra: [String: JSONValue] = [:]) throws -> JSONValue {
        guard case .object(var o) = try isoJSON(rec) else { return .null }
        o["file"] = .string(s.file(rec))
        if let id = s.lotId { o["lot"] = .string(ws.lots.first { $0.id == id }?.name ?? id.uuidString.lowercased()) }
        if let p = rec.enforcedBy { o["enforced"] = .string("imposta por \(p)") }   // what `memory get`/`search` show the reader
        o.merge(extra) { _, b in b }
        return .object(o)
    }

    private func isoString(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    private func searched(_ me: TerminalRecord, ids: [UUID], lot: UUID?, project: String?) {
        memory.events.emit(MemoryEvent(type: .searched, terminal: me.id, lot: lot, project: project, ids: ids, hits: ids.count))
    }

    /// `memory.stats`: the period's events (and 30 days before it, for dead memories and repeats) in the caller's scope —
    /// an agent: its lot's, its project's and the global ones, never another lot's; the app: all, or `--project`/`--lot`;
    /// `--terminal` narrows to one terminal's. Records (dead memories, age, score) come from the stores in that scope.
    private func memoryStats(_ r: Request, caller: TerminalRecord?, myLot: Lot?, lotArg: Lot?, project: RepoMemory, stores: [RepoMemory],
                             paddock: String?) async throws -> JSONValue {
        let now = Date()
        guard let since = MemoryObservability.since(str(r, "since") ?? "7d", now: now) else {
            throw ProtocolError(code: .invalidArgs, message: "since must be like 7d, 24h, 2w or an ISO 8601 date")
        }
        if caller != nil, let l = lotArg, l.id != myLot?.id { throw ProtocolError(code: .notFound, message: "Lot '\(l.name)' not found") }
        let tid = try str(r, "terminal").map { n throws(ProtocolError) -> UUID in
            guard let t = ws.terminals.first(where: { $0.name == n }) else { throw ProtocolError(code: .notFound, message: "Terminal '\(n)' not found") }
            return t.id
        }
        let projectArg = caller == nil ? str(r, "project") : nil
        let mine = project.root?.path
        func placed(lot: UUID?, project p: String?) -> Bool {
            if let l = lotArg, lot != l.id { return false }
            if caller != nil {
                if let lot, lot != myLot?.id { return false }
                if let p, p != mine { return false }
            } else if let projectArg, p != projectArg { return false }
            return true
        }
        let from = min(since, now.addingTimeInterval(-Double(MemoryObservability.deadAfterDays) * 86_400))
        let events = memory.events.read(since: from).filter { placed(lot: $0.lot, project: $0.project) && (tid == nil || $0.terminal == tid) }
        var scoped = stores
        if let projectArg { scoped = [await memory.repo(for: projectArg)] }
        var records: [MemoryRecord] = []
        for s in scoped {
            records += try await s.run { m in m.store.all().records.filter { $0.status == .active } }
                .filter { caller == nil || MemoryService.visible($0, paddock: paddock, lot: s.lotId) }
        }
        let open = digest.since(.distantPast, openAsks: true).filter {
            var e = MemoryEvent(type: .asked); e.place(store: $0.store)
            return placed(lot: e.lot, project: e.project)
        }
        let report = MemoryObservability.compute(events: events, since: since, now: now, records: records, scores: await memory.scores.all(),
                                         openDigest: open, curator: await curator.status(), lifecycle: await memory.lifecycle.all())
        return try isoJSON(report)
    }
}

private extension String {
    /// `LotBoards.scrub` (live tokens, key=/password=/Bearer/sk-) on injected memory text.
    func scrubbed(_ secrets: Set<String>) -> String { LotBoards.scrub(self, secrets: secrets) }
}

extension CommandRouter {
    /// The agent a terminal runs: its preset, or the program its command starts (`custom`): claude|cursor|codex|other.
    static func agentName(_ t: TerminalRecord) -> String {
        if AgentLaunch.isClaude(t) { return "claude" }
        let program = t.command.flatMap(EssentialPaths.commandAgent)?.name
        if t.preset == .cursor || program == "cursor-agent" { return "cursor" }
        if t.preset == .codex || program == "codex" { return "codex" }
        return "other"
    }

    /// Cursor's sessionStart (spec 2026-11-17 cursor memory §1–2): the whole text, the focus block's bytes and memories.
    static let cursorCap = 9_000, focusBudget = 2_500, focusMax = 8
    static let hourMinute: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"; return f }()

    /// `text` in at most `max` UTF-8 bytes: whole lines dropped from the end, never into `keep` (its prefix).
    static func capped(_ text: String, keep: String, max: Int) -> String {
        guard text.utf8.count > max else { return text }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        while lines.joined(separator: "\n").utf8.count > max, lines.joined(separator: "\n").utf8.count > keep.utf8.count { lines.removeLast() }
        let out = lines.joined(separator: "\n")
        return out.utf8.count <= max ? out : String(decoding: Array(keep.utf8.prefix(max)), as: UTF8.self)
    }

    /// One 2048-byte budget: retractions, the rules pushed to the caller (`pull`: also the user's rules changed since its
    /// session started), board posts addressed to it (newest first), the user's comments on its pages, then memories
    /// relevant to `query` and document chunks; scrubbed. `pull`: `memory.task` (relevance leaves the pending uses alone).
    fileprivate func promptBlock(_ me: TerminalRecord, paddock: String?, lot myLot: Lot?, query: String, pull: Bool) async -> String {
        var left = 2048, parts: [String] = []
        func add(_ s: String) { if !s.isEmpty { parts.append(s); left -= s.utf8.count + 2 } }
        let ret = await memory.retractions(for: me.id, paddock: paddock, lot: myLot?.id, limit: left)
        add(ret)
        await refreshSkills(me.id, force: !ret.isEmpty)   // a retracted procedure leaves its dir; a new lot, its set
        // ponytail: retractions that overflowed hold the rest for the next prompt (titles are one line: no "\n…" inside)
        if ret.contains("\n… e mais ") { left = 0 }
        add(await memory.pushedRules(for: me.id, cwd: me.cwd, paddock: paddock, lot: myLot?.id, limit: left))
        if pull, left > 0 { add(await memory.newRules(for: me.id, cwd: me.cwd, paddock: paddock, lot: myLot?.id, limit: left)) }
        if let myLot, left > 0 { add(await boards.inject(to: me.id, lot: myLot, limit: left)) }
        if left > 0 { add(await commentsInject(to: me.id, limit: left)) }   // the user's comments on its pages, also outside a lot
        let w = try? await work.active(terminal: me.id)
        if left > 0 { add(await memory.relevant(for: me.id, cwd: me.cwd, paddock: paddock, lot: myLot?.id, work: w?.id, prompt: query, limit: left, pull: pull)) }
        if left > 0 { add(await memory.docHits(for: me.id, cwd: me.cwd, paddock: paddock, lot: myLot?.id, prompt: query, limit: min(left, 1_800))) }
        return parts.joined(separator: "\n\n").scrubbed(await auth.secrets())
    }
}
