import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

@Suite struct MemoryIndexTests {
    struct Env {
        let root: URL, store: MemoryStore, index: MemoryIndex
        var dbFile: URL { root.appendingPathComponent("index.sqlite") }
    }
    func env() throws -> Env {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collie-idx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MemoryStore(dir: root.appendingPathComponent("memory"))
        return Env(root: root, store: store, index: try MemoryIndex(dbFile: root.appendingPathComponent("index.sqlite"), store: store, repoRoot: root))
    }
    func rec(_ kind: MemoryKind = .decision, _ subject: String, title: String = "t", body: String = "", path: String? = nil,
             status: MemoryStatus = .active, at t: TimeInterval = Date().timeIntervalSince1970) -> MemoryRecord {
        MemoryRecord(kind: kind, subject: subject, title: title, body: body, path: path, status: status, createdAt: Date(timeIntervalSince1970: t))
    }

    @Test func searchFindsByTitleBodyAndPath() throws {
        let e = try env(); defer { try? FileManager.default.removeItem(at: e.root) }
        let a = rec(.decision, "db", title: "Use Postgres", body: "chosen for jsonb")
        let b = rec(.map, "router", title: "Router", body: "dispatches commands", path: "Sources/CollieDaemonKit/CommandRouter.swift")
        try e.store.write(a); try e.store.write(b)
        #expect(try e.index.refresh().isEmpty)
        #expect(e.index.search("postgres", limit: 10).map(\.record.id) == [a.id])
        #expect(e.index.search("jsonb", limit: 10).map(\.record.id) == [a.id])
        #expect(e.index.search("Sources/CollieDaemonKit/Command", limit: 10).map(\.record.id) == [b.id])
        #expect(e.index.search("CommandRouter.swift", limit: 10).map(\.record.id) == [b.id])
        #expect(e.index.search("postgres", limit: 10, kinds: [.map]).isEmpty)
        #expect(e.index.search("((( ** \"", limit: 10).isEmpty)
        let hit = try #require(e.index.search("postgres", limit: 10).first)
        #expect(hit.record == a && hit.score > 0)
    }

    @Test func ftsQueryIsSanitized() throws {
        let e = try env(); defer { try? FileManager.default.removeItem(at: e.root) }
        try e.store.write(rec(.decision, "q", title: "near alpha", body: "beta"))
        _ = try e.index.refresh()
        #expect(e.index.search("\"alpha* NEAR(beta) OR (", limit: 10).count == 1)
        #expect(e.index.search("NEAR", limit: 10).count == 1)
        var big = ""; big.reserveCapacity(1 << 20)
        while big.utf8.count < 1 << 20 { big += "w\(big.utf8.count) \"*( NEAR " }
        let start = Date()
        #expect(e.index.search(big, limit: 10).count == 1)   // "NEAR" is just a word
        #expect(Date().timeIntervalSince(start) < 1)
        let terms = MemoryIndex.ftsTerms(big)
        #expect(terms.count == 32 && terms.first == "w0")
        #expect(MemoryIndex.ftsTerms("a \"b\" -- ./ xy") == ["xy"])
        #expect(MemoryIndex.ftsTerms("a -- ./ * (") == [])
    }

    @Test func inactiveExcludedByDefault() throws {
        let e = try env(); defer { try? FileManager.default.removeItem(at: e.root) }
        let old = rec(.decision, "a", title: "zebra", status: .archived)
        try e.store.write(old)
        _ = try e.index.refresh()
        #expect(e.index.search("zebra", limit: 10).isEmpty)
        #expect(e.index.search("zebra", limit: 10, includeInactive: true).map(\.record.id) == [old.id])
    }

    @Test func refreshPicksUpEditsAndDeletes() throws {
        let e = try env(); defer { try? FileManager.default.removeItem(at: e.root) }
        var r = rec(.pitfall, "flaky", title: "first")
        try e.store.write(r); _ = try e.index.refresh()
        #expect(e.index.search("first", limit: 5).count == 1)
        r.title = "second edited"
        try e.store.write(r); _ = try e.index.refresh()
        #expect(e.index.search("first", limit: 5).isEmpty)
        #expect(e.index.search("second", limit: 5).first?.record.title == "second edited")
        try e.store.delete(r.id); _ = try e.index.refresh()
        #expect(e.index.search("second", limit: 5).isEmpty)
    }

    @Test func statsSurviveForcedRebuild() throws {
        let e = try env(); defer { try? FileManager.default.removeItem(at: e.root) }
        let r = rec(.decision, "s", title: "kept")
        try e.store.write(r); _ = try e.index.refresh()
        #expect(e.index.stats(r.id) == nil)
        e.index.noteRead([r.id]); e.index.noteRead([r.id])
        _ = try e.index.refresh(force: true)
        let s = try #require(e.index.stats(r.id))
        #expect(s.reads == 2 && s.lastReadAt != nil)
        #expect(e.index.search("kept", limit: 5).count == 1)
        // Reopening the same db keeps them too.
        let again = try MemoryIndex(dbFile: e.dbFile, store: e.store, repoRoot: e.root)
        #expect(again.stats(r.id)?.reads == 2)
    }

    @Test func twoActiveSameSubjectKeepsNewest() throws {
        let e = try env(); defer { try? FileManager.default.removeItem(at: e.root) }
        let old = rec(.decision, "cache", title: "use redis", at: 1_700_000_000)
        let new = rec(.decision, "Cache", title: "use memcached", at: 1_700_000_900)
        let otherFloor = MemoryRecord(kind: .decision, scope: .floor, floor: "f1", subject: "cache", title: "floor one", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try e.store.write(old); try e.store.write(new); try e.store.write(otherFloor)
        _ = try e.index.refresh()
        let recs = Dictionary(uniqueKeysWithValues: e.store.all().records.map { ($0.id, $0) })
        #expect(recs[old.id]?.status == .superseded && recs[old.id]?.supersededBy == new.id)
        #expect(recs[new.id]?.status == .active && recs[otherFloor.id]?.status == .active)
        #expect(e.index.search("redis", limit: 5).isEmpty)
        #expect(e.index.search("redis", limit: 5, includeInactive: true).first?.record.status == .superseded)
        // Rewritten file is not re-reported as changed.
        #expect(try e.index.refresh().isEmpty)
    }

    @Test func corruptFileIsSkippedAndReported() throws {
        let e = try env(); defer { try? FileManager.default.removeItem(at: e.root) }
        let good = rec(.decision, "ok", title: "healthy")
        try e.store.write(good)
        let bad = e.store.dir.appendingPathComponent("decision/broken-12345678.md")
        try "---\n<<<<<<< HEAD\nid: x\n=======\nid: y\n>>>>>>> other\n---\n\nbody\n".write(to: bad, atomically: true, encoding: .utf8)
        let problems = try e.index.refresh()
        #expect(problems.count == 1 && problems.first?.file == "decision/broken-12345678.md")
        #expect(problems.first?.error.contains("conflict") == true)
        #expect(e.index.search("healthy", limit: 5).count == 1)
    }

    @Test func missingMapPathIsMarked() throws {
        let e = try env(); defer { try? FileManager.default.removeItem(at: e.root) }
        let m = rec(.map, "x", title: "x file", path: "src/x.swift")
        try e.store.write(m); _ = try e.index.refresh()
        #expect(e.index.stats(m.id)?.missingSince != nil)
        try FileManager.default.createDirectory(at: e.root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "".write(to: e.root.appendingPathComponent("src/x.swift"), atomically: true, encoding: .utf8)
        _ = try e.index.refresh()
        #expect(e.index.stats(m.id)?.missingSince == nil)
    }

    @Test func readsAndRecencyAffectScore() throws {
        let e = try env(); defer { try? FileManager.default.removeItem(at: e.root) }
        let now = Date().timeIntervalSince1970
        let a = rec(.decision, "a", title: "widget", at: now), b = rec(.decision, "b", title: "widget", at: now)
        let old = rec(.decision, "c", title: "widget", at: now - 60 * 86400)
        try e.store.write(a); try e.store.write(b); try e.store.write(old)
        _ = try e.index.refresh()
        e.index.noteRead([b.id])
        let hits = e.index.search("widget", limit: 10)
        #expect(hits.map(\.record.id) == [b.id, a.id, old.id])
        let s = Dictionary(uniqueKeysWithValues: hits.map { ($0.record.id, $0.score) })
        #expect(abs(s[b.id]! / s[a.id]! - 1.1) < 0.01)
        #expect(abs(s[old.id]! / s[a.id]! - 0.25) < 0.01)
        #expect(e.index.search("widget", limit: 1).map(\.record.id) == [b.id])
        let pin = MemoryRecord(kind: .decision, subject: "d", title: "widget", pinned: true)
        try e.store.write(pin); _ = try e.index.refresh()
        let p = e.index.search("widget", limit: 10)
        #expect(p.first?.record.id == pin.id && abs(p[0].score / p.first { $0.record.id == a.id }!.score - 1.5) < 0.01)
    }

    @Test func pinnedDoesNotDecay() throws {
        let e = try env(); defer { try? FileManager.default.removeItem(at: e.root) }
        let old = Date(timeIntervalSince1970: Date().timeIntervalSince1970 - 60 * 86400)
        let pin = MemoryRecord(kind: .decision, subject: "p", title: "gadget", pinned: true, createdAt: old)
        let plain = MemoryRecord(kind: .decision, subject: "q", title: "gadget", createdAt: old)
        try e.store.write(pin); try e.store.write(plain); _ = try e.index.refresh()
        let h = e.index.search("gadget", limit: 10)
        #expect(h.map(\.record.id) == [pin.id, plain.id])
        #expect(abs(h[0].score / h[1].score - 1.5 / 0.25) < 0.01)   // ×1.5, no 60-day decay
    }

    @Test func unopenableDbThrows() throws {
        let store = MemoryStore(dir: URL(fileURLWithPath: "/nonexistent-collie/memory"))
        #expect(throws: (any Error).self) { try MemoryIndex(dbFile: URL(fileURLWithPath: "/nonexistent-collie/x/index.sqlite"), store: store, repoRoot: nil) }
    }
}
