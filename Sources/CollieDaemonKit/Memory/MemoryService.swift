import Foundation
import CollieCore
import CollieProtocol

/// One memory store (a repo's `.collie/memory`, a lot's, or the global one) with its derived index.
/// All store/index/SQLite work runs on its serial `queue` (through `run`), never on the cooperative pool.
final class RepoMemory: @unchecked Sendable {   // the mutable state below is touched only on `queue`
    let root: URL?          // git toplevel (a paddock's worktree for paddock terminals); nil = global or a lot
    let lotId: UUID?        // a lot's store (in the app's data dir, beside the work registry)
    let store: MemoryStore
    private let dbFile: URL
    private let commonDir: URL?
    private let queue: DispatchQueue
    private var excluded = false
    private var lastOpenAttempt: Date?
    private var idx: MemoryIndex?
    private(set) var indexError: String?

    init(root: URL?, storeDir: URL, dbFile: URL, commonDir: URL?, lotId: UUID? = nil, secureRoot: URL? = nil) {
        self.root = root; self.dbFile = dbFile; self.commonDir = commonDir; self.lotId = lotId
        store = MemoryStore(dir: storeDir, secureRoot: secureRoot)
        queue = DispatchQueue(label: "collie.memory.\(storeDir.path)")
    }

    var scope: MemoryScope { lotId != nil ? .lot : root == nil ? .global : .project }
    /// `MemoryService.store(key:)` finds the store again: "lot:<id>", the repo root path, or "global".
    var key: String { lotId.map { "lot:\($0.uuidString.lowercased())" } ?? root?.path ?? "global" }
    /// Where results say the memory lives: the repo root, or the global store dir.
    var path: String { root?.path ?? store.dir.path }
    func file(_ r: MemoryRecord) -> String { store.dir.appendingPathComponent(MemoryFile.fileName(r)).path }

    func run<T: Sendable>(_ body: @escaping @Sendable (RepoMemory) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            queue.async { c.resume(with: Result { try self.refuseSymlinks(); return try body(self) }) }
        }
    }

    /// Queue only: a symlinked store or cache dir could point the files and the index anywhere.
    private func refuseSymlinks() throws(ProtocolError) {
        for dir in [store.dir, dbFile.deletingLastPathComponent()] {
            if (try? FileManager.default.attributesOfItem(atPath: dir.path))?[.type] as? FileAttributeType == .typeSymbolicLink {
                throw ProtocolError(code: .unavailable, message: "\(dir.path) is a symlink; refusing to use it as memory storage")
            }
        }
    }

    /// Queue only: false for a map whose path is gone (or points outside the repo).
    func present(_ r: MemoryRecord) -> Bool {
        guard r.kind == .map, let p = r.path, let root else { return true }
        return repoPathExists(p, root: root)
    }

    static let reopenDelay: TimeInterval = 5

    /// Queue only. Opened on first use (the cache dir is excluded from git first), refreshed on every call;
    /// nil when it can't open (`indexError` says why; retried at most every `reopenDelay`) — the store still works.
    func index() -> MemoryIndex? {
        if lotId != nil, !exists { return nil }   // a lot that never saved a memory: no index (nor its dirs) yet
        if let commonDir, !excluded {
            do { try GitRunner.exclude(dbFile.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent + "/cache/", commonDir: commonDir); excluded = true } catch { memoryLog(error.message) }
        }
        if idx == nil, lastOpenAttempt.map({ Date().timeIntervalSince($0) >= Self.reopenDelay }) ?? true {
            lastOpenAttempt = Date()
            do { idx = try MemoryIndex(dbFile: dbFile, store: store, repoRoot: root); indexError = nil } catch {
                indexError = (error as? ProtocolError)?.message ?? "\(error)"
                memoryLog(indexError ?? "")
            }
        }
        guard let idx else { return nil }
        do { try idx.refresh() } catch { memoryLog("refresh \(path): \(error)") }   // stale but usable
        return idx
    }

    /// A lot's store exists once its first memory is written (repo/global stores: always).
    var exists: Bool { lotId == nil || FileManager.default.fileExists(atPath: store.dir.path) }

    /// Queue only: closes the SQLite handle (reopened on next use).
    func closeIndex() { idx = nil; lastOpenAttempt = nil }

    /// Queue only: the index or a clear error.
    func requireIndex() throws(ProtocolError) -> MemoryIndex {
        guard let i = index() else {
            throw ProtocolError(code: .unavailable, message: "memory index unavailable for \(path): \(indexError ?? "unknown error")")
        }
        return i
    }
}

/// A memory `path` is relative to its repo: not absolute, no `..` component.
func isRepoRelative(_ p: String) -> Bool { !p.hasPrefix("/") && !p.split(separator: "/").contains("..") }
/// Existence inside `root` only: a path that would escape it counts as missing.
func repoPathExists(_ p: String, root: URL) -> Bool {
    isRepoRelative(p) && FileManager.default.fileExists(atPath: root.appendingPathComponent(p).path)
}

func memoryLog(_ m: String) { FileHandle.standardError.write(Data("collied: memory: \(m)\n".utf8)) }

/// Memory per repository (git toplevel of a cwd; global outside git), per lot, and what each terminal's session already got.
actor MemoryService {
    let global: RepoMemory
    private let globalDir: URL
    private let lotsDir: URL
    private var byCwd: [String: RepoMemory] = [:]    // repos only: outside git (or on a git failure) is asked again next time
    private var byRoot: [String: RepoMemory] = [:]
    private var byLot: [UUID: RepoMemory] = [:]
    /// Ids injected in a terminal's session (→ the `key` of their store), and the lot they were injected for: a change of
    /// lot starts over. ponytail: in the actor only — lost on a daemon restart, when the terminals restart too.
    private var injected: [UUID: (lot: UUID?, ids: [UUID: String])] = [:]
    /// Rules pushed to a terminal (its correction became one), emitted ahead of its next prompt's hits.
    private var pending: [UUID: [UUID]] = [:]
    static let header = "Memória do projeto (Collie) — use `collie memory save` para registrar decisões e `collie memory search` antes de reler código."
    static let relevantHeader = "Memória relacionada (Collie):"
    static let rulesHeader = "Regra nova do usuário (Collie):"
    static let retractedHeader = "Memória retirada (Collie):"

    init(globalDir: URL) {
        self.globalDir = globalDir
        lotsDir = globalDir.deletingLastPathComponent().appendingPathComponent("lots")   // beside `work/`
        global = RepoMemory(root: nil, storeDir: globalDir,
                            dbFile: globalDir.deletingLastPathComponent().appendingPathComponent("cache/memory.sqlite"), commonDir: nil)
    }

    func repo(for cwd: String) async -> RepoMemory {
        if let r = byCwd[cwd] { return r }
        // only a found repo is cached: a cwd outside git may `git init` later, and a git failure may be transient
        guard cwd != globalDir.path, let g = try? await GitRunner.run(
            ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"], in: URL(fileURLWithPath: cwd)),
              g.status == 0 else { return global }
        let lines = g.stdout.split(separator: "\n").map(String.init)
        guard lines.count == 2 else { return global }
        let top = URL(fileURLWithPath: lines[0])
        // the folder is the pasture's (a paddock's commonDir is `<pasture>/.git`), so a paddock of an Orq repo keeps `.orq`
        let common = URL(fileURLWithPath: lines[1])
        let dir = LegacyOrq.repoDirName(repoRoot: common.lastPathComponent == ".git" ? common.deletingLastPathComponent() : top)
        let r = byRoot[top.path] ?? RepoMemory(root: top, storeDir: top.appendingPathComponent("\(dir)/memory"),
                                               dbFile: top.appendingPathComponent("\(dir)/cache/memory.sqlite"),
                                               commonDir: common)
        byRoot[top.path] = r
        byCwd[cwd] = r
        return r
    }

    /// The store of lot `id`: `<root>/lots/<id>/memory` (0700, like the work registry); the lot's memories outlive the lot.
    /// Nothing is created on disk until the first memory is saved.
    func lotStore(_ id: UUID) -> RepoMemory {
        if let r = byLot[id] { return r }
        let dir = lotsDir.appendingPathComponent(id.uuidString.lowercased())
        let r = RepoMemory(root: nil, storeDir: dir.appendingPathComponent("memory"),
                           dbFile: dir.appendingPathComponent("cache/memory.sqlite"), commonDir: nil, lotId: id, secureRoot: lotsDir)
        byLot[id] = r
        return r
    }

    /// Forgets a deleted lot's store (closing its index); the files stay on disk.
    func evictLot(_ id: UUID) async {
        guard let r = byLot.removeValue(forKey: id) else { return }
        try? await r.run { $0.closeIndex() }
    }

    /// Drops the stores of `path` and below (a deleted paddock), closing their indexes.
    func evict(under path: String) async {
        let gone = byRoot.filter { $0.key == path || $0.key.hasPrefix(path + "/") }
        for (k, _) in gone { byRoot[k] = nil }
        byCwd = byCwd.filter { _, r in !gone.values.contains { $0 === r } }
        for r in gone.values { try? await r.run { $0.closeIndex() } }
    }

    /// A store by its `RepoMemory.key`; a repo not opened in this run (a queued job after a restart) is opened if the
    /// path is still that repo's root.
    func store(key: String) async -> RepoMemory? {
        if key == "global" { return global }
        if key.hasPrefix("lot:") { return UUID(uuidString: String(key.dropFirst(4))).map { lotStore($0) } }
        if let r = byRoot[key] { return r }
        guard key.hasPrefix("/") else { return nil }
        let r = await repo(for: key)
        return r.key == key ? r : nil
    }

    func isCached(root: String) -> Bool { byRoot[root] != nil }   // tests

    /// What an agent reads: its lot's memory (if in a lot), its repo's and the global one. Never another lot's.
    func readable(_ cwd: String, lot: UUID? = nil) async -> [RepoMemory] {
        let r = await repo(for: cwd)
        return (lot.map { [lotStore($0)] } ?? []) + (r === global ? [r] : [r, global])
    }

    /// Session summary; its pinned memories count as injected for `terminal` (a new session replaces the old set).
    func context(for terminal: UUID, cwd: String, paddock: String? = nil, lot: UUID? = nil, limit: Int = 4096) async -> String {
        let c = await contextParts(cwd: cwd, paddock: paddock, lot: lot, limit: limit)
        injected[terminal] = (lot, c.ids)
        return c.text
    }

    /// Pinned memories of every readable store in full, then an index (titles) of the rest of the lot's — or, outside a
    /// lot, of the rest of the project's/global; unpinned project memories reach a lot member only by prompt relevance.
    func contextText(cwd: String, paddock: String?, lot: UUID? = nil, limit: Int = 4096) async -> (text: String, ids: Set<UUID>) {
        let c = await contextParts(cwd: cwd, paddock: paddock, lot: lot, limit: limit)
        return (c.text, Set(c.ids.keys))
    }

    /// `contextText`, with each injected id's store key.
    private func contextParts(cwd: String, paddock: String?, lot: UUID?, limit: Int) async -> (text: String, ids: [UUID: String]) {
        var pinned: [MemoryRecord] = [], rest: [MemoryRecord] = [], owner: [UUID: String] = [:]
        for s in await readable(cwd, lot: lot) {
            let recs = (try? await s.run { m -> [MemoryRecord] in
                _ = m.index()   // refresh first: resolves two actives a land (or a hand edit) left behind
                try? MemoryCleanup.expireProposals(store: m.store)
                // a map whose path is gone from disk stays out
                return m.store.all().records.filter { $0.status == .active && Self.visible($0, paddock: paddock, lot: m.lotId) && m.present($0) }
            }) ?? []
            pinned += recs.filter(\.pinned)
            for r in recs where r.pinned { owner[r.id] = s.key }
            if lot == nil || s.lotId != nil { rest += recs.filter { !$0.pinned } }
        }
        let (text, ids) = Self.renderContext(pinned, index: rest, limit: limit)
        return (text, owner.filter { ids.contains($0.key) })
    }

    /// Lot hits weigh ×1.5 over project/global ones.
    static let lotBoost = 1.5

    /// Pushed rules first (`pushedRules`), then the memories relevant to `prompt` not yet injected in this session;
    /// "" when nothing is.
    func relevant(for terminal: UUID, cwd: String, paddock: String? = nil, lot: UUID? = nil, prompt: String, limit: Int = 2048, max: Int = 5) async -> String {
        let rules = await pushedRules(for: terminal, cwd: cwd, paddock: paddock, lot: lot, limit: limit)
        let left = rules.isEmpty ? limit : limit - rules.utf8.count - 2
        let mem = await hits(for: terminal, cwd: cwd, paddock: paddock, lot: lot, prompt: prompt, limit: left, max: max)
        return [rules, mem].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Moved to another lot: the session's set starts over.
    private func sync(_ terminal: UUID, lot: UUID?) {
        if let cur = injected[terminal], cur.lot != lot { injected[terminal] = nil }
    }

    func pushRule(_ id: UUID, to terminal: UUID) {
        if pending[terminal]?.contains(id) != true { pending[terminal, default: []].append(id) }
    }

    /// The rules pushed to `terminal` that are active, visible to it and not yet injected, in push order, marked injected;
    /// one that doesn't fit `limit` waits for the next prompt.
    func pushedRules(for terminal: UUID, cwd: String, paddock: String? = nil, lot: UUID? = nil, limit: Int) async -> String {
        sync(terminal, lot: lot)
        guard let ids = pending.removeValue(forKey: terminal), !ids.isEmpty else { return "" }
        let seen = injected[terminal]?.ids ?? [:]
        var found: [UUID: (rec: MemoryRecord, key: String)] = [:]
        for s in await readable(cwd, lot: lot) {
            let recs = (try? await s.run { m in m.index()?.records(ids) ?? [:] }) ?? [:]
            for r in recs.values where found[r.id] == nil && r.status == .active && seen[r.id] == nil
                && Self.visible(r, paddock: paddock, lot: s.lotId) && s.present(r) { found[r.id] = (r, s.key) }
        }
        var out = Self.rulesHeader, chosen: [UUID: String] = [:], wait: [UUID] = []
        for id in ids {
            guard let f = found[id] else { continue }   // gone, inactive or already seen: dropped
            let line = "\n" + Self.relevantLine(f.rec)
            guard out.utf8.count + line.utf8.count <= limit else { wait.append(id); continue }
            out += line; chosen[id] = f.key
        }
        if !wait.isEmpty { pending[terminal] = wait + (pending[terminal] ?? []) }
        guard !chosen.isEmpty else { return "" }
        injected[terminal, default: (lot, [:])].ids.merge(chosen) { a, _ in a }
        return out
    }

    /// The ids injected in `terminal`'s session that are no longer active (superseded, archived — a curator's change or a
    /// hand edit, the index sees both), one line each, removed from the set once said; over `limit`, `… e mais <n>` and
    /// the rest wait for the next prompt. "" when there is none.
    func retractions(for terminal: UUID, limit: Int) async -> String {
        guard let cur = injected[terminal], !cur.ids.isEmpty else { return "" }
        var byKey: [String: [UUID]] = [:]
        for (id, k) in cur.ids { byKey[k, default: []].append(id) }
        var stores: [RepoMemory] = [], gone: [MemoryRecord] = []
        for (k, ids) in byKey.sorted(by: { $0.key < $1.key }) {
            guard let s = await store(key: k) else { continue }
            stores.append(s)
            let recs = (try? await s.run { m in m.index()?.records(ids) ?? [:] }) ?? [:]
            gone += recs.values.filter { $0.status != .active }   // a record the index lacks (file gone) is left alone
        }
        guard !gone.isEmpty else { return "" }
        gone.sort { ($0.updatedAt, $0.id.uuidString) < ($1.updatedAt, $1.id.uuidString) }
        // the replacement: usually in the same store; a promotion's in another of the session's stores
        let wanted = Array(Set(gone.compactMap(\.supersededBy)))
        var next: [UUID: MemoryRecord] = [:]
        for s in stores where !wanted.isEmpty {
            let recs = (try? await s.run { m in m.index()?.records(wanted) ?? [:] }) ?? [:]
            next.merge(recs.filter { $0.value.status == .active }) { a, _ in a }
        }
        var out = Self.retractedHeader, said: [UUID] = []
        for (i, r) in gone.enumerated() {
            let use = r.supersededBy.flatMap { next[$0] }.map { " Use: \(Self.oneLine($0.title, max: 60))." } ?? ""
            let line = "\nNão vale mais: \(Self.oneLine(r.title, max: 60)).\(use)"
            let tail = i + 1 < gone.count ? "\n… e mais \(gone.count - i - 1)".utf8.count : 0
            guard out.utf8.count + line.utf8.count + tail <= limit else { break }
            out += line; said.append(r.id)
        }
        guard !said.isEmpty else { return "" }
        if said.count < gone.count { out += "\n… e mais \(gone.count - said.count)" }
        for id in said { injected[terminal]?.ids[id] = nil }
        return out
    }

    private func hits(for terminal: UUID, cwd: String, paddock: String?, lot: UUID?, prompt: String, limit: Int, max: Int) async -> String {
        sync(terminal, lot: lot)
        let q = Self.significantTerms(prompt).joined(separator: " ")
        guard !q.isEmpty, max > 0 else { return "" }
        var hits: [(hit: MemoryHit, store: RepoMemory)] = []
        for s in await readable(cwd, lot: lot) {
            let found = (try? await s.run { m in (m.index()?.search(q, limit: 50) ?? []).filter { m.present($0.record) } }) ?? []
            hits += found.filter { Self.visible($0.record, paddock: paddock, lot: s.lotId) }
                .map { (MemoryHit(record: $0.record, score: $0.score * (s.lotId != nil ? Self.lotBoost : 1)), s) }
        }
        hits.sort { $0.hit.score > $1.hit.score }
        guard let top = hits.first?.hit.score, top > 0 else { return "" }
        let seen = injected[terminal]?.ids ?? [:]
        // ponytail: relative cut — bm25 scale depends on corpus size (tiny repos clamp idf), so no absolute floor
        let picked = hits.filter { $0.hit.score >= top * Self.minRelativeScore && seen[$0.hit.record.id] == nil }
        var lines = [Self.relevantHeader], used = Self.relevantHeader.utf8.count, chosen: [(hit: MemoryHit, store: RepoMemory)] = []
        for h in picked where chosen.count < max {
            let line = Self.relevantLine(h.hit.record)
            guard used + 1 + line.utf8.count <= limit else { continue }
            lines.append(line); used += 1 + line.utf8.count; chosen.append(h)
        }
        guard !chosen.isEmpty else { return "" }
        injected[terminal, default: (lot, [:])].ids.merge(chosen.map { ($0.hit.record.id, $0.store.key) }) { a, _ in a }
        var stores: [RepoMemory] = []
        for h in chosen where !stores.contains(where: { $0 === h.store }) { stores.append(h.store) }
        for s in stores {
            let ids = chosen.filter { $0.store === s }.map(\.hit.record.id)
            _ = try? await s.run { m in m.index()?.noteRead(ids) }
        }
        return lines.joined(separator: "\n")
    }

    func endSession(_ terminal: UUID) { injected[terminal] = nil; pending[terminal] = nil }

    // MARK: text

    static let minRelativeScore = 0.25
    private static let stopwords: Set<String> = [
        "the", "and", "for", "you", "are", "not", "but", "can", "how", "why", "what", "when", "where", "which", "this",
        "that", "with", "from", "have", "has", "was", "were", "will", "would", "should", "could", "there", "their",
        "about", "into", "your", "please", "make", "does", "did", "que", "não", "nao", "uma", "com", "por", "dos",
        "das", "nos", "mas", "como", "para", "porque", "quando", "onde", "isso", "esse", "essa", "este", "esta",
        "pelo", "pela", "mais", "muito", "também", "então", "sobre", "fazer", "faz", "ser", "tem", "sua", "seu",
    ]

    /// Prompt terms worth matching: ≥ 3 characters, not a common EN/PT word.
    static func significantTerms(_ prompt: String) -> [String] {
        MemoryIndex.ftsTerms(prompt).filter { $0.count >= 3 && !stopwords.contains($0.lowercased()) }
    }

    /// `lot`: the lot of the store the record came from (nil for a repo/global store, where no lot memory is visible).
    static func visible(_ r: MemoryRecord, paddock: String?, lot: UUID?) -> Bool {
        switch r.scope {
        case .paddock: paddock != nil && r.paddock == paddock
        case .lot: lot != nil && r.lotId == lot && r.unknownScope == nil
        case .project, .global: r.unknownScope == nil
        }
    }

    private static func oneLine(_ s: String, max: Int) -> String {
        let l = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return l.count <= max ? l : String(l.prefix(max)) + "…"
    }
    private static func firstLine(_ body: String) -> String {
        oneLine(String(body.split(separator: "\n", omittingEmptySubsequences: true).first ?? ""), max: 200)
    }
    private static func mark(_ r: MemoryRecord) -> String { r.reviewed ? "" : " (não revisada, \(r.origin))" }

    static let indexTitle = "Índice (só títulos; `collie memory search` traz o resto):"

    /// `full` as `renderContext(_:limit:)`, then one line per `index` record (title only, newest first) in what is left.
    /// Only `full` ids count as injected: an index line can still bring its body by prompt relevance.
    static func renderContext(_ full: [MemoryRecord], index: [MemoryRecord], limit: Int) -> (text: String, ids: Set<UUID>) {
        var (out, ids) = renderContext(full, limit: limit)
        guard !out.isEmpty else { return (out, ids) }
        var started = false
        for r in index.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let add = (started ? "" : "\n\n\(indexTitle)") + "\n- " + (r.kind == .map ? r.path.map { "\(oneLine($0, max: 200)) — " } ?? "" : "") + oneLine(r.title, max: 200)
            guard out.utf8.count + add.utf8.count <= limit else { break }
            out += add; started = true
        }
        return (out, ids)
    }

    /// Header, then active user rules (feedback), decisions (title + first line), the map (`path — title`), pitfalls; pinned first, then newest.
    /// At most `limit` UTF-8 bytes, whole items only (one that doesn't fit is skipped).
    static func renderContext(_ recs: [MemoryRecord], limit: Int) -> (text: String, ids: Set<UUID>) {
        var out = header, ids = Set<UUID>()
        guard out.utf8.count <= limit else { return ("", []) }
        let sections: [(MemoryKind, String)] = [(.feedback, "Regras do usuário:"), (.decision, "Decisões:"), (.map, "Mapa:"), (.pitfall, "Armadilhas:")]
        for (kind, title) in sections {
            let items = recs.filter { $0.kind == kind }.sorted { ($0.pinned ? 1 : 0, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.updatedAt) }
            var started = false
            for r in items {
                let t = oneLine(r.title, max: 200)
                let line: String
                if kind == .map {
                    line = "- " + (r.path.map { "\(oneLine($0, max: 200)) — \(t)" } ?? t) + mark(r)
                } else {
                    let first = firstLine(r.body)
                    line = "- " + t + (first.isEmpty ? "" : ": \(first)") + mark(r)
                }
                let add = (started ? "" : "\n\n\(title)") + "\n" + line
                guard out.utf8.count + add.utf8.count <= limit else { continue }
                out += add; started = true; ids.insert(r.id)
            }
        }
        return (out, ids)
    }

    private static func relevantLine(_ r: MemoryRecord) -> String {
        let label = ["feedback": "regra", "decision": "decisão", "map": "mapa", "pitfall": "armadilha"][r.kind.rawValue] ?? r.kind.rawValue
        let head = r.kind == .map ? (r.path.map { "\(oneLine($0, max: 200)) — " } ?? "") + oneLine(r.title, max: 200) : oneLine(r.title, max: 200)
        let body = oneLine(r.body, max: 300)
        return "- [\(label)] \(head)" + (body.isEmpty ? "" : ": \(body)") + mark(r)
    }
}
