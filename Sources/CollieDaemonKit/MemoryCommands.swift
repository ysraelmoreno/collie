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
                                           "memory.hookRelevant", "memory.digest", "memory.repos", "memory.curator"]

    func memoryCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin
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
                                          "memory.digest", "memory.undo", "memory.resolve"]
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
            for s in stores {
                let ids = hits.filter { $0.store === s }.map(\.hit.record.id)
                if !ids.isEmpty { _ = try? await s.run { m in m.index()?.noteRead(ids) } }
            }
            return .array(try hits.map { try memJSON($0.hit.record, $0.store, ["score": .number($0.hit.score)]) })

        case "memory.list":
            let kind = try str(r, "kind").map { k throws(ProtocolError) -> MemoryKind in
                guard let v = MemoryKind(rawValue: k) else { throw invalid("kind must be feedback|decision|map|pitfall|procedure") }
                return v
            }
            guard let status = MemoryStatus(rawValue: str(r, "status") ?? "active") else {
                throw invalid("status must be active|proposed|superseded|archived|discarded")
            }
            let unreviewed = flag(r, "unreviewed"), (keep, asked) = await proposalState()
            var rows: [JSONValue] = [], problems: [JSONValue] = []
            for s in stores {
                let (recs, probs, missing) = try await s.run { m in
                    let idx = m.index()   // refresh first: resolves two actives a land (or a hand edit) left behind
                    try? MemoryCleanup.expireProposals(store: m.store, keep: keep, asked: asked)
                    let all = m.store.all()
                    let recs = all.records.filter {
                        $0.status == status && (kind == nil || $0.kind == kind) && (!unreviewed || !$0.reviewed)
                    }.sorted { $0.updatedAt > $1.updatedAt }
                    var missing: [UUID: Date] = [:]
                    for r in recs where r.kind == .map { if let d = idx?.stats(r.id)?.missingSince { missing[r.id] = d } }
                    return (recs, all.problems, missing)
                }
                for rec in recs where caller == nil || MemoryService.visible(rec, paddock: paddockName, lot: s.lotId) {
                    rows.append(try memJSON(rec, s, missing[rec.id].map { ["missingSince": .string(isoString($0))] } ?? [:]))
                }
                problems += probs.map { .object(["file": .string(s.store.dir.appendingPathComponent($0.file).path), "error": .string($0.error)]) }
            }
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
                return try memJSON(rec, s, extra)
            }
            throw ProtocolError(code: .notFound, message: "memory \(id.uuidString.lowercased()) not found")

        case "memory.context":
            let cwd = caller?.cwd ?? project.root?.path ?? memory.global.path
            return .object(["output": .string(await memory.contextText(cwd: cwd, paddock: paddockName, lot: (lotArg ?? myLot)?.id).text)])

        case "memory.hookContext", "memory.hookRelevant":
            guard let me = caller else { throw ProtocolError(code: .unauthorized, message: "'\(r.command)' is for terminals only") }
            let text: String
            if r.command == "memory.hookContext" {
                // compact/resume: the work state (first), the board's handoff and status posts, then the memory index, in one 4096-byte budget
                let recall = ["compact", "resume"].contains(str(r, "source") ?? "")
                var head: [String] = []
                if recall {
                    if let w = try? await work.active(terminal: me.id) { head.append(WorkStatusText.recall(w)) }
                    if let myLot { head.append(await boards.recall(to: me.id, lot: myLot, limit: 1_200)) }
                    head = head.filter { !$0.isEmpty }
                }
                let used = head.reduce(0) { $0 + $1.utf8.count + 2 }
                await refreshSkills(me.id)   // a session (re)starts: its skills as the stores are now (a hand edit, a pull)
                let w = try? await work.active(terminal: me.id)
                let rest = await memory.context(for: me.id, cwd: me.cwd, paddock: paddockName, lot: myLot?.id, work: w?.id, limit: 4096 - used)
                let mem = (head + [rest == MemoryService.header ? "" : rest]).filter { !$0.isEmpty }.joined(separator: "\n\n")
                let orientation = CollieOrientation.text(
                    terminal: me.name, isShepherd: me.isShepherd, paddock: paddockName,
                    peers: ConnectionGraph.reachable(from: me.id, in: ws).map(\.name),
                    panels: ConnectionGraph.reachablePanels(from: me.id, in: ws).map { ($0.name, $0.pluginId) },
                    paddockPanels: ws.panels.filter { $0.paddockId != nil && $0.paddockId == me.paddockId }.map { ($0.name, $0.pluginId) },
                    designFirst: ws.designFirst, lot: myLot.map { ($0.name, $0.goal) })
                // ponytail: the bare header (no memories) counts as empty
                text = mem.isEmpty || mem == MemoryService.header ? orientation : orientation + "\n\n" + mem
            } else {
                // one 2048-byte budget: retractions, the rules pushed to the caller, board posts addressed to it (newest
                // first), then memories
                let prompt = HookPayload.boundedPrompt(try need(r, "prompt"))
                // a likely correction goes to the curator detached: the hook never waits for it
                // R12: taken at every submit (it starts over); the user's own keystrokes, or a proposal at most
                let user = asks.provenance.take(me.id, prompt: prompt)
                if CorrectionDetector.isCorrection(prompt, lastTurn: lastTurn[me.id]) || CorrectionDetector.isProcedure(prompt) {
                    Task { await self.enqueueCorrection(terminal: me.id, prompt: prompt, user: user) }
                }
                var left = 2048, parts: [String] = []
                func add(_ s: String) { if !s.isEmpty { parts.append(s); left -= s.utf8.count + 2 } }
                let ret = await memory.retractions(for: me.id, paddock: paddockName, lot: myLot?.id, limit: left)
                add(ret)
                await refreshSkills(me.id, force: !ret.isEmpty)   // a retracted procedure leaves its dir; a new lot, its set
                // ponytail: retractions that overflowed hold the rest for the next prompt (titles are one line: no "\n…" inside)
                if ret.contains("\n… e mais ") { left = 0 }
                add(await memory.pushedRules(for: me.id, cwd: me.cwd, paddock: paddockName, lot: myLot?.id, limit: left))
                if let myLot, left > 0 { add(await boards.inject(to: me.id, lot: myLot, limit: left)) }
                let w = try? await work.active(terminal: me.id)
                if left > 0 { add(await memory.relevant(for: me.id, cwd: me.cwd, paddock: paddockName, lot: myLot?.id, work: w?.id, prompt: prompt, limit: left)) }
                text = parts.joined(separator: "\n\n")
            }
            return .object(["output": .string(text)])

        case "memory.review":
            let id = try id()
            let action = try need(r, "action")
            guard ["approve", "discard", "archive"].contains(action) else { throw invalid("action must be approve|discard|archive") }
            let title = str(r, "title"), body = str(r, "body"), subject = str(r, "subject").map(MemoryRecord.normalize)
            if title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true || subject?.isEmpty == true {
                throw invalid("subject and title must not be blank")
            }
            let edited = title != nil || body != nil || subject != nil
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
            // L3: the user decided on a waiting quote: its correction job is moot (never a second rule)
            await cancelCorrection(quote: id)
            return out

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
            if caller != nil, old.kind == .feedback { throw ProtocolError(code: .unauthorized, message: "a feedback memory is the user's: only the app can promote it") }
            let rec = MemoryRecord(kind: old.kind, scope: target === memory.global ? .global : .project, subject: old.subject,
                                   title: old.title, body: old.body, path: old.path, reviewed: caller == nil && old.reviewed, pinned: caller == nil && old.pinned,   // an agent's promotion is unreviewed and unpinned
                                   supersedes: old.id, origin: old.origin, aliases: old.aliases)
            let saved = try await target.run { m in try m.store.save(rec).saved }   // replaces the project's active one of that subject
            try await src.run { m in
                var o = old; o.status = .superseded; o.supersededBy = saved.id; o.updatedAt = saved.updatedAt
                try m.store.write(o)
            }
            return try memJSON(saved, target, ["promotedFrom": .string(id.uuidString)])

        case "memory.restore":
            let id = try id()
            let rec = try await repo.run { m in try MemoryCleanup.restore(id, store: m.store, index: m.index()) }
            await memory.scores.reset(id)   // a restored memory starts over
            return try memJSON(rec, repo)

        case "memory.pin", "memory.unpin":
            let pinned = r.command == "memory.pin"
            return try await update(try id()) { rec, m in rec.pinned = pinned; try m.store.write(rec) }

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
            return .object(["entries": try isoJSON(digest.since(since, openAsks: true)), "curator": try isoJSON(await curator.status())])

        case "memory.undo", "memory.resolve":
            guard let e = UUID(uuidString: try need(r, "entry")) else { throw invalid("'entry' must be a digest entry id") }
            if r.command == "memory.undo" { return try isoJSON(try await undoDigest(e)) }
            let keep = try need(r, "keep")
            guard ["newer", "older"].contains(keep) else { throw invalid("keep must be newer|older") }
            return try isoJSON(try await resolveAsk(e, keepNewer: keep == "newer"))

        case "memory.curator":
            if let n = try num(r, "cap", max: 10_000) { await curator.setCap(Int(n)) }
            return try isoJSON(await curator.status())

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
        o.merge(extra) { _, b in b }
        return .object(o)
    }

    private func isoString(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
}
