import Foundation
import CollieCore
import CollieProtocol

/// `memory.*`: the admin token (same managed-terminal ancestry check as `admin.*`) or a terminal token.
/// Memory isn't cord-gated: a terminal reads/writes the memory of its cwd's repo (plus the global one);
/// review/restore/pin/cleanup/purge/repos are admin-only. The admin picks the store with `repo` (default: its cwd).
extension CommandRouter {
    func memoryCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)   // nil = admin
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        let floorName = caller?.floorId.flatMap { id in ws.floors.first { $0.id == id }?.name }
        let repo: RepoMemory
        if let me = caller {
            repo = await memory.repo(for: me.cwd)
        } else if let p = str(r, "repo") {
            guard try await memory.global.run({ _ in FileManager.default.fileExists(atPath: p) }) else { throw invalid("repo '\(p)' does not exist") }
            repo = await memory.repo(for: p)
        } else {
            repo = await memory.repo(for: r.cwd ?? memory.global.path)
        }
        // agents read their repo + the global memory; the admin works on exactly the store it picked
        let stores = caller == nil || repo === memory.global ? [repo] : [repo, memory.global]
        let adminCommands: Set<String> = ["memory.review", "memory.restore", "memory.pin", "memory.unpin",
                                          "memory.cleanup", "memory.purge", "memory.repos"]
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
            guard let kind = MemoryKind(rawValue: try need(r, "kind")) else { throw invalid("kind must be decision|map|pitfall") }
            guard let scope = MemoryScope(rawValue: str(r, "scope") ?? "project") else { throw invalid("scope must be project|floor|global") }
            let origin = caller.map { "\($0.name) (\($0.preset.rawValue))" } ?? "app"
            let (saved, target, old) = try await saveMemory(kind, scope: scope, subject: try need(r, "subject"), title: try need(r, "title"),
                                                            body: str(r, "body") ?? "", path: str(r, "path"), repo: repo,
                                                            floor: floorName, origin: origin)
            return try memJSON(saved, target, ["superseded": old.map { .string($0.id.uuidString) } ?? .null])

        case "memory.search":
            let query = try need(r, "query")
            let limit = Int(try num(r, "limit", max: 50) ?? 10), all = flag(r, "all")
            var hits: [(hit: MemoryHit, store: RepoMemory)] = []
            for s in stores {
                // over-fetch: floor memories of other floors are filtered out below
                // the picked repo's index must work; a broken global one only drops its hits
                let required = s === repo
                let found = try await s.run { m in
                    (required ? try m.requireIndex() : m.index())?.search(query, limit: limit * 2 + 10, includeInactive: all) ?? []
                }
                hits += found.filter { caller == nil || MemoryService.visible($0.record, floor: floorName) }.map { ($0, s) }
            }
            hits.sort { $0.hit.score > $1.hit.score }
            hits = Array(hits.prefix(limit))
            for s in stores {
                let ids = hits.filter { $0.store === s }.map(\.hit.record.id)
                if !ids.isEmpty { _ = try? await s.run { m in m.index()?.noteRead(ids) } }
            }
            return .array(try hits.map { try memJSON($0.hit.record, $0.store, ["score": .number($0.hit.score)]) })

        case "memory.list":
            let kind = try str(r, "kind").map { k throws(ProtocolError) -> MemoryKind in
                guard let v = MemoryKind(rawValue: k) else { throw invalid("kind must be decision|map|pitfall") }
                return v
            }
            guard let status = MemoryStatus(rawValue: str(r, "status") ?? "active") else {
                throw invalid("status must be active|superseded|archived|discarded")
            }
            let unreviewed = flag(r, "unreviewed")
            var rows: [JSONValue] = [], problems: [JSONValue] = []
            for s in stores {
                let (recs, probs, missing) = try await s.run { m in
                    let idx = m.index()   // refresh first: resolves two actives a land (or a hand edit) left behind
                    let all = m.store.all()
                    let recs = all.records.filter {
                        $0.status == status && (kind == nil || $0.kind == kind) && (!unreviewed || !$0.reviewed)
                    }.sorted { $0.updatedAt > $1.updatedAt }
                    var missing: [UUID: Date] = [:]
                    for r in recs where r.kind == .map { if let d = idx?.stats(r.id)?.missingSince { missing[r.id] = d } }
                    return (recs, all.problems, missing)
                }
                for rec in recs where caller == nil || MemoryService.visible(rec, floor: floorName) {
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
                guard let (rec, st) = found, caller == nil || MemoryService.visible(rec, floor: floorName) else { continue }
                var extra: [String: JSONValue] = ["reads": .number(Double(st?.reads ?? 0))]
                if let d = st?.lastReadAt { extra["lastReadAt"] = .string(isoString(d)) }
                if let d = st?.missingSince { extra["missingSince"] = .string(isoString(d)) }
                _ = try? await s.run { m in m.index()?.noteRead([id]) }
                return try memJSON(rec, s, extra)
            }
            throw ProtocolError(code: .notFound, message: "memory \(id.uuidString.lowercased()) not found")

        case "memory.context":
            let cwd = caller?.cwd ?? repo.root?.path ?? memory.global.path
            return .object(["output": .string(await memory.contextText(cwd: cwd, floor: floorName).text)])

        case "memory.hookContext", "memory.hookRelevant":
            guard let me = caller else { throw ProtocolError(code: .unauthorized, message: "'\(r.command)' is for terminals only") }
            let text: String
            if r.command == "memory.hookContext" {
                let mem = await memory.context(for: me.id, cwd: me.cwd, floor: floorName)
                let orientation = CollieOrientation.text(
                    terminal: me.name, isMaestro: me.isMaestro, floor: floorName,
                    peers: ConnectionGraph.reachable(from: me.id, in: ws).map(\.name),
                    panels: ConnectionGraph.reachablePanels(from: me.id, in: ws).map { ($0.name, $0.pluginId) })
                // ponytail: the bare header (no memories) counts as empty
                text = mem.isEmpty || mem == MemoryService.header ? orientation : orientation + "\n\n" + mem
            } else {
                text = await memory.relevant(for: me.id, cwd: me.cwd, floor: floorName, prompt: HookPayload.boundedPrompt(try need(r, "prompt")))
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
            return try await update(id) { rec, m in
                let store = m.store
                let edited = title != nil || body != nil || subject != nil
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
                } else if resubject, rec.status == .active {
                    rec.supersedes = nil   // it no longer replaces anything under the old subject
                    rec = try store.save(rec).saved   // new chain key: replaces that subject's active one
                    try restorePrevious()   // the old subject's previous decision is current again
                } else {
                    try store.write(rec)
                }
            }

        case "memory.restore":
            let id = try id()
            let rec = try await repo.run { m in try MemoryCleanup.restore(id, store: m.store, index: m.index()) }
            return try memJSON(rec, repo)

        case "memory.pin", "memory.unpin":
            let pinned = r.command == "memory.pin"
            return try await update(try id()) { rec, m in rec.pinned = pinned; try m.store.write(rec) }

        case "memory.cleanup":
            let apply = flag(r, "apply")
            let (items, changed) = try await repo.run { m -> ([CleanupItem], [UUID]) in
                let index = try m.requireIndex()
                let records = m.store.all().records
                var stats: [UUID: MemoryStats] = [:]
                for rec in records { if let s = index.stats(rec.id) { stats[rec.id] = s } }
                let items = MemoryCleanup.plan(records: records, stats: stats, now: Date())
                return (items, apply ? try MemoryCleanup.apply(items, store: m.store).map(\.id) : [])
            }
            return .object(["items": try isoJSON(items), "applied": .array(changed.map { .string($0.uuidString) })])

        case "memory.purge":
            let n = try await repo.run { m -> Int in
                let gone = m.store.all().records.filter { $0.status == .discarded }
                for rec in gone { try m.store.delete(rec.id) }
                return gone.count
            }
            return .object(["deleted": .number(Double(n))])

        case "memory.repos":
            var seen: [RepoMemory] = []
            for cwd in ws.terminals.map(\.cwd) + ws.floors.flatMap({ [$0.repoRoot, $0.path] }) {
                let m = await memory.repo(for: cwd)
                if m !== memory.global, !seen.contains(where: { $0 === m }) { seen.append(m) }
            }
            seen.append(memory.global)
            return .array(seen.map { m in
                var o: [String: JSONValue] = ["path": .string(m.path), "scope": .string(m.scope.rawValue)]
                if let f = ws.floors.first(where: { $0.path == m.root?.path }) {
                    o["floor"] = .string(f.name)
                }
                return .object(o)
            })

        default:
            throw invalid("Unknown command '\(r.command)'")
        }
    }

    /// `memory.save`'s validation and store choice: `repo` is the caller's (its cwd's), `floor` its floor's name.
    /// Returns the saved record, the store it went to and the record it replaced (same subject).
    func saveMemory(_ kind: MemoryKind, scope: MemoryScope, subject rawSubject: String, title rawTitle: String, body: String,
                    path rawPath: String?, repo: RepoMemory, floor floorName: String?,
                    origin: String) async throws -> (MemoryRecord, RepoMemory, MemoryRecord?) {
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        let subject = MemoryRecord.normalize(rawSubject)
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty, !title.isEmpty else { throw invalid("subject and title must not be blank") }
        guard subject.count <= 300, title.count <= 300, body.utf8.count <= 64 * 1024 else {
            throw invalid("subject/title are limited to 300 characters and body to 64 KiB")
        }
        var target = repo, effective = scope, floor: String?
        switch scope {
        case .floor:
            guard let floorName, repo.root != nil else { throw invalid("scope 'floor' needs a terminal on a floor") }
            floor = floorName
        case .global: target = memory.global
        case .project: if repo.root == nil { effective = .global }   // outside git: the global store
        }
        var path = rawPath
        if let p = path, let root = target.root?.path, p.hasPrefix(root + "/") { path = String(p.dropFirst(root.count + 1)) }
        if let p = path, !isRepoRelative(p) { throw invalid("path must be relative to the repo root (no '..')") }
        let rec = MemoryRecord(kind: kind, scope: effective, floor: floor, subject: subject, title: title, body: body,
                               path: path, origin: origin)
        let (saved, old) = try await target.run { m in try m.store.save(rec) }
        return (saved, target, old)
    }

    /// A project decision, saved as `memory.save` would for a caller whose cwd is `cwd` (nil: the global store);
    /// a later one with the same subject replaces it. `by`: the record's origin.
    @discardableResult
    func saveDecision(subject: String, title: String, body: String, cwd: String?, by: String) async throws -> MemoryRecord {
        var repo = memory.global
        if let cwd { repo = await memory.repo(for: cwd) }
        return try await saveMemory(.decision, scope: .project, subject: subject, title: title, body: body, path: nil,
                                    repo: repo, floor: nil, origin: by).0
    }

    /// A record for agents/the app: ISO dates plus where it lives (`file`) and extras.
    private func memJSON(_ rec: MemoryRecord, _ s: RepoMemory, _ extra: [String: JSONValue] = [:]) throws -> JSONValue {
        guard case .object(var o) = try isoJSON(rec) else { return .null }
        o["file"] = .string(s.file(rec))
        o.merge(extra) { _, b in b }
        return .object(o)
    }

    private func isoString(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
}
