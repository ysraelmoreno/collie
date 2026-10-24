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
    private let embedder: (any MemoryEmbedder)?

    init(root: URL?, storeDir: URL, dbFile: URL, commonDir: URL?, lotId: UUID? = nil, secureRoot: URL? = nil, embedder: (any MemoryEmbedder)? = nil) {
        self.root = root; self.dbFile = dbFile; self.commonDir = commonDir; self.lotId = lotId; self.embedder = embedder
        store = MemoryStore(dir: storeDir, secureRoot: secureRoot)
        queue = DispatchQueue(label: "collie.memory.\(storeDir.path)")
    }

    var scope: MemoryScope { lotId != nil ? .lot : root == nil ? .global : .project }
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
            do { idx = try MemoryIndex(dbFile: dbFile, store: store, repoRoot: root, embedder: embedder); indexError = nil } catch {
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
    /// Ids injected in a terminal's session, and the lot they were injected for: a change of lot starts over.
    private var injected: [UUID: (lot: UUID?, ids: Set<UUID>)] = [:]
    static let header = "Memória do projeto (Collie) — use `collie memory save` para registrar decisões e `collie memory search` antes de reler código."
    static let relevantHeader = "Memória relacionada (Collie):"

    nonisolated let embedder: (any MemoryEmbedder)?

    init(globalDir: URL, embedder: (any MemoryEmbedder)? = nil) {
        self.globalDir = globalDir; self.embedder = embedder
        lotsDir = globalDir.deletingLastPathComponent().appendingPathComponent("lots")   // beside `work/`
        global = RepoMemory(root: nil, storeDir: globalDir,
                            dbFile: globalDir.deletingLastPathComponent().appendingPathComponent("cache/memory.sqlite"), commonDir: nil,
                            embedder: embedder)
    }

    /// A query's vector: its first 1 000 characters (the prompt hook's 5 s budget); nil without a model for its language.
    nonisolated func embed(_ text: String) -> (lang: String, vector: [Float])? { embedder?.embed(String(text.prefix(1_000))) }

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
                                               commonDir: common, embedder: embedder)
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
                           dbFile: dir.appendingPathComponent("cache/memory.sqlite"), commonDir: nil, lotId: id, secureRoot: lotsDir,
                           embedder: embedder)
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

    func isCached(root: String) -> Bool { byRoot[root] != nil }   // tests

    /// What an agent reads: its lot's memory (if in a lot), its repo's and the global one. Never another lot's.
    func readable(_ cwd: String, lot: UUID? = nil) async -> [RepoMemory] {
        let r = await repo(for: cwd)
        return (lot.map { [lotStore($0)] } ?? []) + (r === global ? [r] : [r, global])
    }

    /// Session summary; its pinned memories count as injected for `terminal` (a new session replaces the old set).
    func context(for terminal: UUID, cwd: String, paddock: String? = nil, lot: UUID? = nil, limit: Int = 4096) async -> String {
        let (text, ids) = await contextText(cwd: cwd, paddock: paddock, lot: lot, limit: limit)
        injected[terminal] = (lot, ids)
        return text
    }

    /// Pinned memories of every readable store in full, then an index (titles) of the rest of the lot's — or, outside a
    /// lot, of the rest of the project's/global; unpinned project memories reach a lot member only by prompt relevance.
    func contextText(cwd: String, paddock: String?, lot: UUID? = nil, limit: Int = 4096) async -> (text: String, ids: Set<UUID>) {
        var pinned: [MemoryRecord] = [], rest: [MemoryRecord] = []
        for s in await readable(cwd, lot: lot) {
            let recs = (try? await s.run { m -> [MemoryRecord] in
                _ = m.index()   // refresh first: resolves two actives a land (or a hand edit) left behind
                try? MemoryCleanup.expireProposals(store: m.store)
                // a map whose path is gone from disk stays out
                return m.store.all().records.filter { $0.status == .active && Self.visible($0, paddock: paddock, lot: m.lotId) && m.present($0) }
            }) ?? []
            pinned += recs.filter(\.pinned)
            if lot == nil || s.lotId != nil { rest += recs.filter { !$0.pinned } }
        }
        return Self.renderContext(pinned, index: rest, limit: limit)
    }

    /// Lot hits weigh ×1.5 over project/global ones.
    static let lotBoost = 1.5

    /// Memories relevant to `prompt` not yet injected in this session; "" when nothing is.
    func relevant(for terminal: UUID, cwd: String, paddock: String? = nil, lot: UUID? = nil, prompt: String, limit: Int = 2048, max: Int = 5) async -> String {
        if let cur = injected[terminal], cur.lot != lot { injected[terminal] = nil }   // moved to another lot: start over
        let q = Self.significantTerms(prompt).joined(separator: " ")
        guard !q.isEmpty, max > 0 else { return "" }
        var hits: [(hit: MemoryHit, store: RepoMemory)] = []
        let vector = embed(prompt)   // once per prompt, for every store
        for s in await readable(cwd, lot: lot) {
            let found = (try? await s.run { m in (m.index()?.search(q, vector: vector, limit: 50) ?? []).filter { m.present($0.record) } }) ?? []
            hits += found.filter { Self.visible($0.record, paddock: paddock, lot: s.lotId) }
                .map { (MemoryHit(record: $0.record, score: $0.score * (s.lotId != nil ? Self.lotBoost : 1)), s) }
        }
        hits.sort { $0.hit.score > $1.hit.score }
        guard let top = hits.first?.hit.score, top > 0 else { return "" }
        let seen = injected[terminal]?.ids ?? []
        // ponytail: relative cut — bm25 scale depends on corpus size (tiny repos clamp idf), so no absolute floor
        let picked = hits.filter { $0.hit.score >= top * Self.minRelativeScore && !seen.contains($0.hit.record.id) }
        var lines = [Self.relevantHeader], used = Self.relevantHeader.utf8.count, chosen: [(hit: MemoryHit, store: RepoMemory)] = []
        for h in picked where chosen.count < max {
            let line = Self.relevantLine(h.hit.record)
            guard used + 1 + line.utf8.count <= limit else { continue }
            lines.append(line); used += 1 + line.utf8.count; chosen.append(h)
        }
        guard !chosen.isEmpty else { return "" }
        injected[terminal, default: (lot, [])].ids.formUnion(chosen.map(\.hit.record.id))
        var stores: [RepoMemory] = []
        for h in chosen where !stores.contains(where: { $0 === h.store }) { stores.append(h.store) }
        for s in stores {
            let ids = chosen.filter { $0.store === s }.map(\.hit.record.id)
            _ = try? await s.run { m in m.index()?.noteRead(ids) }
        }
        return lines.joined(separator: "\n")
    }

    func endSession(_ terminal: UUID) { injected[terminal] = nil }

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

    /// Header, then active decisions (title + first line), the map (`path — title`), pitfalls; pinned first, then newest.
    /// At most `limit` UTF-8 bytes, whole items only (one that doesn't fit is skipped).
    static func renderContext(_ recs: [MemoryRecord], limit: Int) -> (text: String, ids: Set<UUID>) {
        var out = header, ids = Set<UUID>()
        guard out.utf8.count <= limit else { return ("", []) }
        let sections: [(MemoryKind, String)] = [(.decision, "Decisões:"), (.map, "Mapa:"), (.pitfall, "Armadilhas:")]
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
        let label = ["decision": "decisão", "map": "mapa", "pitfall": "armadilha"][r.kind.rawValue] ?? r.kind.rawValue
        let head = r.kind == .map ? (r.path.map { "\(oneLine($0, max: 200)) — " } ?? "") + oneLine(r.title, max: 200) : oneLine(r.title, max: 200)
        let body = oneLine(r.body, max: 300)
        return "- [\(label)] \(head)" + (body.isEmpty ? "" : ": \(body)") + mark(r)
    }
}
