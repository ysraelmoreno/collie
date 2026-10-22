import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

@Suite struct MemoryCleanupTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func ago(_ d: Double) -> Date { now.addingTimeInterval(-d * 86400) }
    func tmpDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("collie-clean-\(UUID().uuidString)") }
    func rec(_ subject: String, kind: MemoryKind = .decision, body: String = "", title: String = "t", created: Double = 1,
             updated: Double? = nil, pinned: Bool = false, path: String? = nil) -> MemoryRecord {
        MemoryRecord(kind: kind, subject: subject, title: title, body: body, path: path, pinned: pinned,
                     createdAt: ago(created), updatedAt: updated.map(ago))
    }
    func mdCount(_ d: URL) -> Int { (FileManager.default.enumerator(at: d, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "md" }.count }

    @Test func coldUnpinnedIsArchived() {
        let r = rec("a", body: "x1", created: 100)
        let p = MemoryCleanup.plan(records: [r], stats: [:], now: now)
        #expect(p.count == 1 && p[0].action == .archiveCold && p[0].id == r.id && p[0].reason == "não lida há 100 dias")
    }

    @Test func pinnedNeverDecays() {
        let r = rec("a", created: 500, pinned: true)
        #expect(MemoryCleanup.plan(records: [r], stats: [r.id: MemoryStats(reads: 0, lastReadAt: nil, missingSince: ago(30))], now: now).isEmpty)
    }

    @Test func recentReadKeepsWarm() {
        let r = rec("a", created: 500)
        let s = [r.id: MemoryStats(reads: 3, lastReadAt: ago(10), missingSince: nil)]
        #expect(MemoryCleanup.plan(records: [r], stats: s, now: now).isEmpty)
    }

    @Test func missingPathAfter7Days() {
        let r = rec("m", kind: .map, path: "a.swift")
        func plan(_ d: Double) -> [CleanupItem] {
            MemoryCleanup.plan(records: [r], stats: [r.id: MemoryStats(reads: 0, lastReadAt: nil, missingSince: ago(d))], now: now)
        }
        #expect(plan(6).isEmpty)
        let p = plan(9)
        #expect(p.count == 1 && p[0].action == .archiveMissingPath && p[0].reason == "caminho sumiu há 9 dias")
    }

    @Test func duplicatesMergeIntoNewest() {
        let old = rec("a", body: "Use  SQLite for the index", created: 10, updated: 10)
        let new = rec("b", body: "use sqlite for the INDEX", created: 5, updated: 2)
        let near = rec("c", body: "w1 w2 w3 w4 w5 w6 w7 w8 w9 w10 w11", title: "x", created: 9, updated: 9)
        let near2 = rec("d", body: "w1 w2 w3 w4 w5 w6 w7 w8 w9 w10", title: "x", created: 8, updated: 8)
        let other = rec("e", kind: .pitfall, body: "use sqlite for the index", created: 1)
        let p = MemoryCleanup.plan(records: [old, new, near, near2, other], stats: [:], now: now)
        #expect(Set(p.map(\.id)) == [old.id, near.id])
        #expect(p.first { $0.id == old.id }?.into == new.id && p.first { $0.id == near.id }?.into == near2.id)
        #expect(p.allSatisfy { $0.action == .mergeDuplicate })
    }

    @Test func applyNeverDeletesFiles() throws {
        let s = MemoryStore(dir: tmpDir()); defer { try? FileManager.default.removeItem(at: s.dir) }
        let cold = rec("cold", created: 100), a = rec("a", body: "same body", updated: 2), b = rec("b", body: "same body", updated: 3)
        for r in [cold, a, b] { try s.write(r) }
        let before = mdCount(s.dir)
        let items = MemoryCleanup.plan(records: s.all().records, stats: [:], now: now)
        let changed = try MemoryCleanup.apply(items, store: s)
        #expect(changed.count == 2 && mdCount(s.dir) == before)
        let all = s.all().records
        #expect(all.first { $0.id == cold.id }?.status == .archived)
        #expect(all.first { $0.id == b.id }?.status == .superseded && all.first { $0.id == b.id }?.supersededBy == a.id)
        #expect(all.first { $0.id == a.id }?.status == .active)
    }

    @Test func restoreBringsBackAndResupersedes() throws {
        let s = MemoryStore(dir: tmpDir()); defer { try? FileManager.default.removeItem(at: s.dir) }
        let a = rec("db", created: 100)
        try s.write(a)
        _ = try MemoryCleanup.apply([CleanupItem(action: .archiveCold, id: a.id, into: nil, reason: "r")], store: s)
        let b = try s.save(rec("DB", created: 1)).saved
        let r = try MemoryCleanup.restore(a.id, store: s)
        #expect(r.status == .active && r.supersededBy == nil)
        let all = s.all().records
        #expect(all.first { $0.id == a.id } == r)
        #expect(all.first { $0.id == b.id }?.status == .superseded && all.first { $0.id == b.id }?.supersededBy == a.id)
        #expect(all.filter { $0.status == .active }.count == 1)
    }

    @Test func duplicatesRespectScopePaddockAndPath() {
        func r(_ scope: MemoryScope, _ paddock: String? = nil, kind: MemoryKind = .decision, path: String? = nil) -> MemoryRecord {
            MemoryRecord(kind: kind, scope: scope, paddock: paddock, subject: UUID().uuidString, title: "t", body: "same body here", path: path, createdAt: ago(1))
        }
        #expect(MemoryCleanup.plan(records: [r(.paddock, "a"), r(.paddock, "b"), r(.project), r(.global)], stats: [:], now: now).isEmpty)
        #expect(MemoryCleanup.plan(records: [r(.project, kind: .map, path: "a"), r(.project, kind: .map, path: "b")], stats: [:], now: now).isEmpty)
        #expect(MemoryCleanup.plan(records: [r(.project, kind: .map, path: "a"), r(.project, kind: .map, path: "a")], stats: [:], now: now).count == 1)
    }

    @Test func shortTextsOnlyMergeOnIdenticalBody() {
        let a = rec("a", body: "", title: "same title"), b = rec("b", body: "", title: "same title")
        #expect(MemoryCleanup.plan(records: [a, b], stats: [:], now: now).isEmpty)
    }

    @Test func staleAndPinnedItemsAreSkipped() throws {
        let s = MemoryStore(dir: tmpDir()); defer { try? FileManager.default.removeItem(at: s.dir) }
        let keep = rec("k", body: "x"), gone = rec("g", body: "y"), pin = rec("p", created: 100, pinned: true)
        var arch = rec("z"); arch.status = .archived
        for r in [keep, gone, pin, arch] { try s.write(r) }
        let items = [
            CleanupItem(action: .mergeDuplicate, id: gone.id, into: arch.id, reason: ""),     // target not active
            CleanupItem(action: .mergeDuplicate, id: gone.id, into: gone.id, reason: ""),     // self
            CleanupItem(action: .archiveCold, id: pin.id, into: nil, reason: ""),             // pinned
            CleanupItem(action: .archiveCold, id: UUID(), into: nil, reason: ""),             // unknown
            CleanupItem(action: .archiveCold, id: arch.id, into: nil, reason: "")]            // not active
        #expect(try MemoryCleanup.apply(items, store: s).isEmpty)
        #expect(s.all().records.sorted { $0.subject < $1.subject }.map(\.status) == [.active, .active, .active, .archived])
    }

    @Test func restoredColdRecordIsNotReplanned() throws {
        let root = tmpDir(); defer { try? FileManager.default.removeItem(at: root) }
        let s = MemoryStore(dir: root.appendingPathComponent("mem"))
        let idx = try MemoryIndex(dbFile: root.appendingPathComponent("i.sqlite"), store: s, repoRoot: nil)
        let r = MemoryRecord(kind: .decision, subject: "old", title: "t", createdAt: Date(timeIntervalSinceNow: -100 * 86400))
        try s.write(r)
        let item = MemoryCleanup.plan(records: [r], stats: [:], now: Date())
        #expect(item.count == 1)
        _ = try MemoryCleanup.apply(item, store: s)
        let back = try MemoryCleanup.restore(r.id, store: s, index: idx)
        let st = idx.stats(r.id)
        #expect(st?.missingSince == nil && st?.lastReadAt != nil && st?.reads == 0)
        #expect(MemoryCleanup.plan(records: [back], stats: [r.id: st!], now: Date()).isEmpty)
    }
}
