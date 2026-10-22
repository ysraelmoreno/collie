import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

@Suite struct MemoryStoreTests {
    func tmpDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("collie-mem-\(UUID().uuidString)") }
    func rec(_ kind: MemoryKind = .decision, _ subject: String = "db", scope: MemoryScope = .project, paddock: String? = nil,
             at t: TimeInterval = 1_700_000_000) -> MemoryRecord {
        MemoryRecord(kind: kind, scope: scope, paddock: paddock, subject: subject, title: "t", createdAt: Date(timeIntervalSince1970: t))
    }

    @Test func saveSupersedesSameSubject() throws {
        let s = MemoryStore(dir: tmpDir()); defer { try? FileManager.default.removeItem(at: s.dir) }
        let a = try s.save(rec(.decision, "Use  DB")).saved
        let r = try s.save(rec(.decision, "use db", at: 1_700_000_500))
        #expect(r.superseded?.id == a.id && r.superseded?.status == .superseded && r.superseded?.supersededBy == r.saved.id)
        #expect(r.saved.supersedes == a.id && r.saved.status == .active)
        let all = s.all()
        #expect(all.problems.isEmpty && all.records.count == 2)
        #expect(all.records.first { $0.id == a.id }?.status == .superseded)
        #expect(all.records.first { $0.id == r.saved.id }?.supersedes == a.id)
    }

    @Test func differentKindOrScopeDoesNotSupersede() throws {
        let s = MemoryStore(dir: tmpDir()); defer { try? FileManager.default.removeItem(at: s.dir) }
        _ = try s.save(rec(.decision, "db"))
        #expect(try s.save(rec(.pitfall, "db")).superseded == nil)
        #expect(try s.save(rec(.decision, "db", scope: .global)).superseded == nil)
        #expect(try s.save(rec(.decision, "db", scope: .paddock, paddock: "a")).superseded == nil)
        #expect(try s.save(rec(.decision, "db", scope: .paddock, paddock: "b")).superseded == nil)
        #expect(s.all().records.allSatisfy { $0.status == .active })
    }

    @Test func corruptFileGoesToProblems() throws {
        let s = MemoryStore(dir: tmpDir()); defer { try? FileManager.default.removeItem(at: s.dir) }
        try s.write(rec())
        let bad = s.dir.appendingPathComponent("decision/bad.md")
        try "<<<<<<< HEAD\nnope\n".write(to: bad, atomically: true, encoding: .utf8)
        let all = s.all()
        #expect(all.records.count == 1 && all.problems.count == 1 && all.problems[0].file == "decision/bad.md")
    }

    @Test func writeIsAtomic() throws {
        let s = MemoryStore(dir: tmpDir()); defer { try? FileManager.default.removeItem(at: s.dir) }
        var r = rec()
        for i in 0..<20 { r.title = "v\(i)"; try s.write(r) }
        let files = FileManager.default.enumerator(atPath: s.dir.path)!.compactMap { $0 as? String }
        #expect(!files.contains { $0.hasSuffix(".tmp") })
        let all = s.all()
        #expect(all.problems.isEmpty && all.records == [r])
    }

    @Test func deleteRemovesFile() throws {
        let s = MemoryStore(dir: tmpDir()); defer { try? FileManager.default.removeItem(at: s.dir) }
        let r = rec(); try s.write(r)
        try s.delete(r.id)
        #expect(s.all().records.isEmpty)
    }

    @Test func subjectChangeKeepsSingleFile() throws {
        let s = MemoryStore(dir: tmpDir()); defer { try? FileManager.default.removeItem(at: s.dir) }
        var r = rec(.decision, "old subject"); try s.write(r)
        r.subject = "new subject"; try s.write(r)
        #expect(s.all().records.count == 1)
        #expect(FileManager.default.enumerator(atPath: s.dir.path)!.compactMap { $0 as? String }.filter { $0.hasSuffix(".md") }.count == 1)
    }

    @Test func saveSupersedesAllMatching() throws {
        let s = MemoryStore(dir: tmpDir()); defer { try? FileManager.default.removeItem(at: s.dir) }
        try s.write(rec(.decision, "db")); try s.write(rec(.decision, "db"))
        let r = try s.save(rec(.decision, "db", at: 1_700_000_900))
        #expect(r.superseded != nil)
        #expect(s.all().records.filter { $0.status == .active }.map(\.id) == [r.saved.id])
    }
}
