import Testing
import Foundation
import SQLite3
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Words map to fixed concept axes (teste/suíte/filter… → axis 0, cor/botão → 1, postgres/banco → 2); any other word adds
/// a little weight on a hashed axis. `lang == nil`: a language with no model (embeds nothing). Labelled `en` by default:
/// only English vectors bring vector-only hits (R3); `pt` ones only re-rank word hits.
struct ConceptEmbedder: MemoryEmbedder {
    var dim = 8
    var lang: String? = "en"
    static let concepts: [String: Int] = [
        "teste": 0, "testes": 0, "test": 0, "tests": 0, "suíte": 0, "suite": 0, "filter": 0, "rodo": 0, "rodar": 0,
        "cor": 1, "botão": 1, "azul": 1, "postgres": 2, "banco": 2,
    ]
    func embed(_ text: String) -> (lang: String, vector: [Float])? {
        guard let lang else { return nil }
        var v = [Float](repeating: 0, count: dim)
        for w in text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            if let a = Self.concepts[String(w)] { v[a] += 1; continue }
            let h = w.unicodeScalars.reduce(5381) { ($0 &* 33 &+ Int($1.value)) & 0xFFFFFF }   // stable across runs
            v[3 + h % (dim - 3)] += 0.2
        }
        return v.allSatisfy { $0 == 0 } ? nil : (lang, v)
    }
}

private func cosine(_ a: [Float], _ b: [Float]) -> Double {
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in a.indices { dot += Double(a[i]) * Double(b[i]); na += Double(a[i]) * Double(a[i]); nb += Double(b[i]) * Double(b[i]) }
    return dot / (na.squareRoot() * nb.squareRoot())
}

private func rec(_ title: String, body: String = "", kind: MemoryKind = .decision, scope: MemoryScope = .project,
                 paddock: String? = nil, lot: UUID? = nil, path: String? = nil, pinned: Bool = false) -> MemoryRecord {
    MemoryRecord(kind: kind, scope: scope, paddock: paddock, lotId: lot, subject: title, title: title, body: body, path: path, pinned: pinned)
}

private func tempRoot() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("collie-hybrid-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Suite struct HybridSearchTests {
    let prompt = "como rodo os testes?"

    /// Review Focus 4 (mechanics, with an `en`-labelled model): no shared word, found by meaning (prompt hook and
    /// `memory.search`). With the real pt model this is aliases' job (R3, `ptOnlyReranks`).
    @Test func meaningMatchesPortuguese() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memory")
        let suite = rec("Suíte: só swift test --filter", body: "Nunca a inteira."), button = rec("Cor do botão", body: "azul")
        let mem = MemoryService(globalDir: dir, embedder: ConceptEmbedder())
        try await mem.global.run { m in for r in [suite, button] { try m.store.write(r) } }
        await mem.global.fillVectors()
        let text = await mem.relevant(for: UUID(), cwd: dir.path, prompt: prompt)
        #expect(text.contains("Suíte: só swift test --filter") && !text.contains("Cor do botão"), "\(text)")
        // bm25 alone finds nothing: it is the vector
        let plain = MemoryService(globalDir: root.appendingPathComponent("plain/memory"))
        try await plain.global.run { m in try m.store.write(suite) }
        #expect(await plain.relevant(for: UUID(), cwd: root.appendingPathComponent("plain/memory").path, prompt: prompt).isEmpty)

        let repo = try await makeRepo()
        try await withDaemon(configure: { $0.embedder = ConceptEmbedder() }) { d, p in
            let save = try await send(p, Request(id: "x", token: d.adminToken, command: "memory.save", args: [
                "kind": .string("decision"), "subject": .string("testes"), "title": .string("Suíte: só swift test --filter"),
                "repo": .string(repo.path)]))
            #expect(save.ok, "\(save)")
            // vectors fill in the background: the search finds it once they are in
            #expect(await waitFor(10) {
                let r = try? await send(p, Request(id: "y", token: d.adminToken, command: "memory.search",
                                                   args: ["query": .string(prompt), "repo": .string(repo.path)]))
                guard case .array(let rows)? = r?.result, case .object(let o)? = rows.first, case .string(let t)? = o["title"] else { return false }
                return t == "Suíte: só swift test --filter"
            })
        }
    }

    /// Like the real pt model: every cosine bunched high, an unrelated memory the highest. pt vectors only re-rank word
    /// hits: the unrelated one is never a candidate, the word hits are ordered by meaning.
    @Test func ptOnlyReranks() async throws {
        struct Bunched: MemoryEmbedder {
            func embed(_ text: String) -> (lang: String, vector: [Float])? {
                let t = text.lowercased()
                let v: [Float] = t.contains("botão") ? [1, 0.3, 0] : t.contains("lentos") ? [1, 0.3, 0.05] : t.contains("rodar") ? [1, 0, 0.6] : [1, 0.3, 0]
                return ("pt", v)
            }
        }
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memory")
        let near = rec("Testes lentos", body: "testes"), far = rec("Rodar testes", body: "testes"), unrelated = rec("Cor do botão", body: "azul")
        let mem = MemoryService(globalDir: dir, embedder: Bunched())
        try await mem.global.run { m in for r in [near, far, unrelated] { try m.store.write(r) } }
        await mem.global.fillVectors()
        let text = await mem.relevant(for: UUID(), cwd: dir.path, prompt: prompt)
        #expect(text.contains(near.title) && text.contains(far.title) && !text.contains(unrelated.title), "\(text)")
        let ids = try await mem.global.run { m in try m.requireIndex().search("testes", vector: Bunched().embed(prompt), limit: 10).map(\.record.id) }
        #expect(ids == [near.id, far.id])   // equal bm25: the nearer meaning first
    }

    @Test func bm25StillWins() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(dir: root.appendingPathComponent("memory")), e = ConceptEmbedder()
        let exact = rec("Rodar testes", body: "swift test --filter"), similar = rec("Suíte: só swift test --filter")
        try store.write(exact); try store.write(similar)
        let idx = try MemoryIndex(dbFile: root.appendingPathComponent("i.sqlite"), store: store, repoRoot: nil, embedder: e)
        try idx.refresh(); idx.fillVectors()
        let hits = idx.search("rodo testes", vector: e.embed(prompt), limit: 10)
        #expect(hits.map(\.record.id) == [exact.id, similar.id])
    }

    /// `m × (0.6 × b / bTop + 0.4 × max(cos, 0))`; vector-only candidates need cos ≥ 0.55.
    @Test func blendFormula() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(dir: root.appendingPathComponent("memory")), e = ConceptEmbedder()
        // pinned: m is exactly 1.5 (no recency, no reads)
        let recs = [rec("Testes rápidos", body: "testes testes banco", pinned: true), rec("Testes", body: "cor do botão azul", pinned: true),
                    rec("Suíte swift filter", pinned: true), rec("Cor do botão", body: "azul", pinned: true)]
        for r in recs { try store.write(r) }
        let idx = try MemoryIndex(dbFile: root.appendingPathComponent("i.sqlite"), store: store, repoRoot: nil, embedder: e)
        try idx.refresh(); idx.fillVectors()
        let plain = Dictionary(uniqueKeysWithValues: idx.search("testes", limit: 10).map { ($0.record.id, $0.score / 1.5) })   // raw b
        #expect(plain.count == 2)
        let q = try #require(e.embed("testes"))
        let bTop = try #require(plain.values.max())
        var expected: [UUID: Double] = [:]
        for r in recs {
            let cos = cosine(q.vector, try #require(e.embed(MemoryIndex.vectorText(r))).vector)
            if let b = plain[r.id] { expected[r.id] = 1.5 * (0.6 * b / bTop + 0.4 * max(cos, 0)) }
            else if cos >= 0.55 { expected[r.id] = 1.5 * 0.4 * cos }
        }
        #expect(expected.count == 3)   // the button one is neither a word nor a meaning match
        let hits = idx.search("testes", vector: q, limit: 10)
        #expect(Set(hits.map(\.record.id)) == Set(expected.keys))
        for h in hits { #expect(abs(h.score - expected[h.record.id]!) < 1e-9, "\(h.record.title): \(h.score) vs \(expected[h.record.id]!)") }
        #expect(hits.map(\.score) == hits.map(\.score).sorted(by: >))
    }

    @Test func otherLanguageFallsBack() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let recs = [rec("Rodar testes", body: "swift test --filter"), rec("Suíte: só swift test"), rec("Use Postgres", body: "banco testes")]
        var outs: [String] = []
        for (name, embedder) in [("none", nil), ("other", ConceptEmbedder(lang: nil))] as [(String, (any MemoryEmbedder)?)] {
            let dir = root.appendingPathComponent("\(name)/memory")
            let mem = MemoryService(globalDir: dir, embedder: embedder)
            try await mem.global.run { m in for r in recs { try m.store.write(r) } }
            await mem.global.fillVectors()
            let ids = try await mem.global.run { m in try m.requireIndex().search("rodo testes", vector: embedder?.embed("rodo testes"), limit: 10).map(\.record.id) }
            #expect(Set(ids) == [recs[0].id, recs[2].id])
            outs.append(await mem.relevant(for: UUID(), cwd: dir.path, prompt: prompt))
        }
        #expect(outs[0] == outs[1] && !outs[0].isEmpty)
    }

    @Test func vectorsRebuiltWithIndex() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(dir: root.appendingPathComponent("memory")), db = root.appendingPathComponent("i.sqlite"), e = ConceptEmbedder()
        let suite = rec("Suíte: só swift test --filter"), other = rec("Use Postgres", body: "banco")
        try store.write(suite); try store.write(other)
        do {
            let v1 = try MemoryIndex(dbFile: db, store: store, repoRoot: nil)
            try v1.refresh()
            v1.noteRead([suite.id])
        }
        // what a v1 index looks like: no vecs; a stale docs row (same mtime/size: a plain refresh would keep it)
        var h: OpaquePointer?
        #expect(sqlite3_open(db.path, &h) == SQLITE_OK)
        #expect(sqlite3_exec(h, "DROP TABLE vecs; UPDATE docs SET json = replace(json, 'Suíte', 'Velho'); PRAGMA user_version = 1;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(h)
        let v2 = try MemoryIndex(dbFile: db, store: store, repoRoot: nil, embedder: e)
        try v2.refresh(); v2.fillVectors()
        let hits = v2.search("como", vector: e.embed(prompt), limit: 10)   // no word match: vectors only
        #expect(hits.map(\.record.title) == ["Suíte: só swift test --filter"])
        #expect(v2.search("postgres", limit: 10).map(\.record.id) == [other.id])
        #expect(v2.stats(suite.id)?.reads == 1)
    }

    /// A vector-only hit is filtered like a word hit: `visible`, `present`, and only the caller's own lot.
    @Test func onlyVisibleByVector() async throws {
        let repo = try await makeRepo()
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let mem = MemoryService(globalDir: root.appendingPathComponent("memory"), embedder: ConceptEmbedder())
        let lotA = UUID(), lotB = UUID()
        let ok = rec("Suíte: só swift test --filter")
        let gone = rec("Suíte runner", kind: .map, path: "gone/Runner.swift")
        let otherPaddock = rec("Suíte do outro cercado", scope: .paddock, paddock: "outro")
        let inLotA = rec("Suíte do lote", scope: .lot, lot: lotA)
        try await mem.repo(for: repo.path).run { m in for r in [ok, gone, otherPaddock] { try m.store.write(r) } }
        try await mem.lotStore(lotA).run { m in try m.store.write(inLotA) }
        _ = await mem.lotStore(lotB)
        await mem.repo(for: repo.path).fillVectors(); await mem.lotStore(lotA).fillVectors()
        let b = await mem.relevant(for: UUID(), cwd: repo.path, lot: lotB, prompt: prompt)
        #expect(b.contains(ok.title), "\(b)")
        for r in [gone, otherPaddock, inLotA] { #expect(!b.contains(r.title), "\(b)") }
        let a = await mem.relevant(for: UUID(), cwd: repo.path, lot: lotA, prompt: prompt)
        #expect(a.contains(inLotA.title) && !a.contains(gone.title) && !a.contains(otherPaddock.title), "\(a)")
    }

    /// Review Focus 5 (R7: 500 memories, run alone): every one a word and a vector candidate (dimension 512).
    @Test func hybridSearchFast() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memory")
        let mem = MemoryService(globalDir: dir, embedder: ConceptEmbedder(dim: 512))
        try await mem.global.run { m in
            for i in 0..<500 { try m.store.write(rec("Memória \(i) sobre testes", body: "rodar testes item\(i) " + String(repeating: "detalhe\(i % 37) ", count: 30))) }
        }
        _ = await mem.relevant(for: UUID(), cwd: dir.path, prompt: prompt)   // first open: index built
        await mem.global.fillVectors()
        let clock = ContinuousClock()
        let t = try await clock.measure {
            _ = try await mem.global.run { m in try m.requireIndex().search("rodo testes", vector: ConceptEmbedder(dim: 512).embed(prompt), limit: 50) }
        }
        #expect(t < .milliseconds(300), "\(t)")
        let whole = await clock.measure { #expect(!(await mem.relevant(for: UUID(), cwd: dir.path, prompt: prompt)).isEmpty) }
        #expect(whole < .milliseconds(300), "\(whole)")
    }

    /// R7: a prompt refreshes the index only when a store folder changed (or every `refreshEvery`).
    @Test func refreshOnlyWhenChanged() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memory")
        let mem = MemoryService(globalDir: dir)
        try await mem.global.run { m in try m.store.write(rec("Rodar testes")) }
        for _ in 0..<3 { _ = await mem.relevant(for: UUID(), cwd: dir.path, prompt: "rodar testes") }
        #expect(try await mem.global.run { $0.refreshes } == 1)
        let added = rec("Testes lentos")
        try await mem.global.run { m in try m.store.write(added) }
        #expect(await mem.relevant(for: UUID(), cwd: dir.path, prompt: "testes lentos").contains(added.title))
        #expect(try await mem.global.run { $0.refreshes } == 2)
    }

    /// R6: the first prompt after a (re)build never waits on embedding: word search works at once, vectors come after.
    @Test func vectorsFillInBackground() async throws {
        final class Slow: MemoryEmbedder, @unchecked Sendable {
            let lock = NSLock(); var calls = 0
            func embed(_ text: String) -> (lang: String, vector: [Float])? {
                lock.withLock { calls += 1 }
                Thread.sleep(forTimeInterval: 0.05)
                return ConceptEmbedder().embed(text)
            }
        }
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memory"), slow = Slow()
        let mem = MemoryService(globalDir: dir, embedder: slow)
        let target = rec("Suíte: só swift test --filter")
        try await mem.global.run { m in
            try m.store.write(target)
            for i in 0..<60 { try m.store.write(rec("Item \(i) qualquer")) }
        }
        let clock = ContinuousClock()
        var text = ""
        let first = await clock.measure { text = await mem.relevant(for: UUID(), cwd: dir.path, prompt: "item qualquer") }
        #expect(first < .seconds(1), "\(first)")   // 61 embeds × 50 ms would be 3 s
        #expect(text.contains("qualquer"))
        #expect(slow.lock.withLock { slow.calls } < 61)
        await mem.global.fillVectors()
        #expect(try await mem.global.run { m in try m.requireIndex().missingVectors(limit: 1).isEmpty })
        let hits = try await mem.global.run { m in try m.requireIndex().search("como", vector: ConceptEmbedder().embed(prompt), limit: 5).map(\.record.id) }
        #expect(hits.contains(target.id))   // its vector is in: found with no word
    }

    /// R10: stores merge on one scale: bTop is the strongest word hit across every store read, not each store's own.
    @Test func storesOnOneScale() async throws {
        struct Mixed: MemoryEmbedder {
            func embed(_ text: String) -> (lang: String, vector: [Float])? {
                let t = text.lowercased()
                return t.contains("lote") ? ("en", [0.3, 0.95, 0]) : t.contains("global") ? ("pt", [1, 0, 0]) : ("en", [1, 0, 0])
            }
        }
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memory"), lot = UUID()
        let mem = MemoryService(globalDir: dir, embedder: Mixed())
        // strong word hit in the global store (a pt record: no comparable vector), a weak one in the lot (an en record)
        let strong = rec("Webhook retries webhook retries global"), weak = rec("Webhook do lote", body: String(repeating: "texto longo ", count: 40),
                                                                             scope: .lot, lot: lot)
        try await mem.global.run { m in try m.store.write(strong) }
        try await mem.lotStore(lot).run { m in try m.store.write(weak) }
        await mem.global.fillVectors(); await mem.lotStore(lot).fillVectors()
        let text = await mem.relevant(for: UUID(), cwd: dir.path, lot: lot, prompt: "webhook retries")
        let a = try #require(text.range(of: strong.title)), b = try #require(text.range(of: "Webhook do lote"))
        #expect(a.lowerBound < b.lowerBound, "\(text)")
    }

    /// R10: a cold model (seconds to load) never holds the prompt: after 150 ms it is words only.
    @Test func promptEmbedWaitBounded() async throws {
        struct Cold: MemoryEmbedder {
            func embed(_ text: String) -> (lang: String, vector: [Float])? {
                if text.contains("rodar") { return ConceptEmbedder().embed(text) }   // records: at once
                Thread.sleep(forTimeInterval: 1); return ConceptEmbedder().embed(text)
            }
        }
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("memory")
        let mem = MemoryService(globalDir: dir, embedder: Cold())
        try await mem.global.run { m in try m.store.write(rec("Testes: rodar só o filtro")) }
        await mem.global.fillVectors()
        var text = ""
        let t = await ContinuousClock().measure { text = await mem.relevant(for: UUID(), cwd: dir.path, prompt: "testes lentos") }
        #expect(t < .milliseconds(700), "\(t)")
        #expect(text.contains("Testes: rodar só o filtro"))
    }

    /// R10: a store closed (evicted) during a background fill is not reopened by it.
    @Test func fillSkipsClosedStore() async throws {
        struct Slow: MemoryEmbedder {
            func embed(_ text: String) -> (lang: String, vector: [Float])? { Thread.sleep(forTimeInterval: 0.02); return ConceptEmbedder().embed(text) }
        }
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let mem = MemoryService(globalDir: root.appendingPathComponent("memory"), embedder: Slow())
        try await mem.global.run { m in for i in 0..<60 { try m.store.write(rec("Item \(i)")) } }
        try await mem.global.run { m in _ = m.index(); m.closeIndex() }   // the refresh starts the fill; then evicted
        try await Task.sleep(for: .seconds(2))
        #expect(try await mem.global.run { $0.isOpen } == false)
    }

    /// R8: a pt cosine (bunched, re-rank only) is min-max normalized over the candidates and moves a hit by at most 15%
    /// of its word score; a hit with no comparable vector keeps its word score. Scores stay on the bm25 × m scale.
    @Test func ptRerankBounded() throws {
        struct Bunched: MemoryEmbedder {
            func embed(_ text: String) -> (lang: String, vector: [Float])? {
                let t = text.lowercased()
                if t.contains("english") { return ("en", [1, 0, 0]) }
                return ("pt", t.contains("perto") ? [1, 0.3, 0.02] : t.contains("longe") ? [1, 0, 0.3] : [1, 0.3, 0])
            }
        }
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(dir: root.appendingPathComponent("memory")), e = Bunched()
        let strong = rec("Testes testes testes", body: "english", pinned: true)
        let near = rec("Testes perto", body: "um texto mais comprido sobre outra coisa qualquer", pinned: true)
        let far = rec("Testes longe", body: "um texto mais comprido sobre outra coisa qualquer", pinned: true)
        for r in [strong, near, far] { try store.write(r) }
        let idx = try MemoryIndex(dbFile: root.appendingPathComponent("i.sqlite"), store: store, repoRoot: nil, embedder: e)
        try idx.refresh(); idx.fillVectors()
        let plain = Dictionary(uniqueKeysWithValues: idx.search("testes", limit: 10).map { ($0.record.id, $0.score) })
        let q = try #require(e.embed(prompt))
        let cos = [near.id, far.id].map { cosine(q.vector, e.embed(MemoryIndex.vectorText($0 == near.id ? near : far))!.vector) }
        let lo = cos.min()!, hi = cos.max()!
        let expected = [strong.id: plain[strong.id]!, near.id: plain[near.id]! * (1 + 0.15 * (cos[0] - lo) / (hi - lo)),
                        far.id: plain[far.id]! * (1 + 0.15 * (cos[1] - lo) / (hi - lo))]
        let hits = idx.search("testes", vector: q, limit: 10)
        #expect(hits.first?.record.id == strong.id)   // the strongest word hit, an `en` memory, keeps first place
        #expect(hits.count == 3)
        for h in hits { #expect(abs(h.score - expected[h.record.id]!) < 1e-9, "\(h.record.title): \(h.score) vs \(expected[h.record.id]!)") }
    }

    /// Task 6: a curator alias widens what search finds (the text never says it); a v2 index is rebuilt for the column.
    @Test func aliasMatches() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MemoryStore(dir: root.appendingPathComponent("memory")), db = root.appendingPathComponent("i.sqlite")
        var m = rec("Rodar só o filtro", body: "swift test --filter X"); m.aliases = ["suíte"]
        let other = rec("Cor do botão", body: "azul")
        try store.write(m); try store.write(other)
        do {
            let v2 = try MemoryIndex(dbFile: db, store: store, repoRoot: nil)
            try v2.refresh()
            v2.noteRead([m.id])
        }
        // what a v2 index looks like: fts without `aliases`
        var h: OpaquePointer?
        #expect(sqlite3_open(db.path, &h) == SQLITE_OK)
        #expect(sqlite3_exec(h, "DROP TABLE fts; CREATE VIRTUAL TABLE fts USING fts5(title, subject, body, path, tokenize='unicode61 remove_diacritics 2'); PRAGMA user_version = 2;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(h)
        let v3 = try MemoryIndex(dbFile: db, store: store, repoRoot: nil)
        try v3.refresh()
        #expect(v3.search("qual suíte?", limit: 10).map(\.record.id) == [m.id])
        #expect(v3.search("suite", limit: 10).map(\.record.id) == [m.id])   // diacritics folded, like the other columns
        #expect(v3.stats(m.id)?.reads == 1)   // stats kept
    }
}
