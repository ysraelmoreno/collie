import Testing
import Foundation
import OrqCore
import OrqProtocol
@testable import OrqDaemonKit

@Suite struct WorkStoreTests {
    private func tmp() -> URL { URL(fileURLWithPath: "/tmp/orq-work-\(UUID().uuidString.prefix(8))") }
    private func archived(_ dir: URL) -> [[String: Any]] {
        guard let s = try? String(contentsOf: dir.appendingPathComponent("work-archive.jsonl"), encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    @Test func startCloseReopen() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir), t = UUID()
        let w = try await s.start(title: "A", terminal: t, floorId: nil, branch: "orq/a")
        #expect(try await s.active(terminal: t)?.id == w.id)
        try await s.update(w.id) { $0.tasks.append(WorkTask(id: "1", title: "x", state: .inProgress)) }
        try await s.close(w.id, by: "app")
        let c = try #require(try await s.get(w.id))
        #expect(c.closedAt != nil && c.closedBy == "app" && c.tasks.first?.state == .inProgress)
        #expect(try await s.active(terminal: t) == nil)
        #expect(try await s.list(includeClosed: false).isEmpty)
        #expect(try await s.list(includeClosed: true).count == 1)
        try await s.reopen(w.id)
        let r = try #require(try await s.get(w.id))
        #expect(r.closedAt == nil && r.closedBy == nil)
        let perm = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("work.json").path)[.posixPermissions] as? Int
        #expect(perm == 0o600)
    }

    @Test func oneActivePerTerminal() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir), t = UUID()
        let w = try await s.start(title: "A", terminal: t, floorId: nil, branch: nil)
        await #expect(throws: ProtocolError.self) { try await s.start(title: "B", terminal: t, floorId: nil, branch: nil) }
        do { _ = try await s.start(title: "B", terminal: t, floorId: nil, branch: nil) }
        catch let e as ProtocolError { #expect(e.code == .invalidArgs && e.message == "work already open: A") }
        _ = try await s.start(title: "C", terminal: UUID(), floorId: nil, branch: nil)   // another terminal is free
        try await s.close(w.id, by: "app")
        _ = try await s.start(title: "D", terminal: t, floorId: nil, branch: nil)
    }

    @Test func persistsAcrossReload() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let w = try await s.start(title: "A", terminal: UUID(), floorId: UUID(), branch: "b")
        try await s.update(w.id) {
            $0.tasks.append(WorkTask(id: "1", title: "t")); $0.notes.append(WorkNote(text: "n", decision: true))
            $0.jobs.append(WorkJob(id: "j", kind: .shell, label: "l", pid: 42)); $0.commits.append("abc subject")
        }
        let again = WorkStore(dir: dir)
        let r = try #require(try await again.get(w.id))
        #expect(r.title == "A" && r.branch == "b" && r.tasks.map(\.id) == ["1"] && r.notes.first?.decision == true)
        #expect(r.jobs.first?.pid == 42 && r.commits == ["abc subject"])
    }

    @Test func limitsHold() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let w = try await s.start(title: "A", terminal: UUID(), floorId: nil, branch: nil)
        let base = Date(timeIntervalSince1970: 1_000_000)
        try await s.update(w.id) {
            // 300 done, 300 open; the oldest 100 done go first
            for i in 0..<600 {
                $0.tasks.append(WorkTask(id: "\(i)", title: "t", state: i % 2 == 0 ? .done : .open, updatedAt: base + Double(i)))
            }
            for i in 0..<250 { $0.jobs.append(WorkJob(id: "j\(i)", kind: .subagent, label: "l", state: i < 10 ? .running : .finished, startedAt: base + Double(i))) }
            for i in 0..<250 { $0.notes.append(WorkNote(at: base + Double(i), text: "n\(i)")) }
            for i in 0..<210 { $0.commits.append("c\(i) s") }
        }
        let g = try #require(try await s.get(w.id))
        #expect(g.tasks.count == 500 && g.jobs.count == 200 && g.notes.count == 200)
        #expect(g.commits.count == 200 && g.commits.first == "c10 s" && archived(dir).filter { $0["kind"] as? String == "commit" }.count == 10)
        #expect(g.tasks.filter { $0.state == .done }.count == 200 && g.notes.first?.text == "n50")
        #expect(g.jobs.prefix(10).allSatisfy { $0.state == .running })   // running ones outlive finished
        let a = archived(dir)
        #expect(a.filter { $0["kind"] as? String == "task" }.count == 100)
        #expect(a.filter { $0["kind"] as? String == "job" }.count == 50 && a.filter { $0["kind"] as? String == "note" }.count == 50)
        // no done task left over when open ones are evicted: 300 open + 0 done > 500? (only past the done ones)
        try await s.update(w.id) { for i in 0..<400 { $0.tasks.append(WorkTask(id: "o\(i)", title: "t", updatedAt: base + 10_000 + Double(i))) } }
        let h = try #require(try await s.get(w.id))
        #expect(h.tasks.count == 500 && !h.tasks.contains { $0.state == .done })

        // closed works: 250 -> 200 in work.json, 50 in the archive
        let dir2 = tmp(); defer { try? FileManager.default.removeItem(at: dir2) }
        let s2 = WorkStore(dir: dir2)
        for i in 0..<250 { let c = try await s2.start(title: "W\(i)", terminal: UUID(), floorId: nil, branch: nil); try await s2.close(c.id, by: "app") }
        let keep = try await s2.list(includeClosed: true)
        #expect(keep.count == 200 && keep.first?.title == "W50")
        #expect(archived(dir2).filter { $0["kind"] as? String == "work" }.count == 50)
        #expect(try await WorkStore(dir: dir2).list(includeClosed: true).count == 200)
        let ap = dir2.appendingPathComponent("work-archive.jsonl").path
        #expect(try FileManager.default.attributesOfItem(atPath: ap)[.posixPermissions] as? Int == 0o600)
        // clearHistory empties the archive too; active works stay
        let live = try await s2.start(title: "live", terminal: UUID(), floorId: nil, branch: nil)
        try await s2.clearHistory()
        #expect(archived(dir2).isEmpty)
        #expect(try await s2.list(includeClosed: true).map(\.id) == [live.id])
    }

    @Test func clearHistory() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let a = try await s.start(title: "A", terminal: UUID(), floorId: nil, branch: nil)
        let b = try await s.start(title: "B", terminal: UUID(), floorId: nil, branch: nil)
        try await s.close(a.id, by: "app")
        try await s.clearHistory()
        #expect(try await s.get(a.id) == nil)
        #expect(try await s.get(b.id) != nil)
        #expect(try await WorkStore(dir: dir).list(includeClosed: true).map(\.title) == ["B"])
    }

    @Test func unreadableStoreIsNeverOverwritten() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let w = try await WorkStore(dir: dir).start(title: "A", terminal: UUID(), floorId: nil, branch: nil)
        let f = dir.appendingPathComponent("work.json")
        guard getuid() != 0 else { return }
        let before = try Data(contentsOf: f)
        chmod(f.path, 0o000); defer { chmod(f.path, 0o600) }
        let s = WorkStore(dir: dir)
        await #expect(throws: ProtocolError.self) { try await s.list(includeClosed: true) }
        await #expect(throws: ProtocolError.self) { try await s.start(title: "B", terminal: UUID(), floorId: nil, branch: nil) }
        chmod(f.path, 0o600)
        #expect(try Data(contentsOf: f) == before)
        #expect(try await WorkStore(dir: dir).get(w.id) != nil)
    }

    @Test func concurrentUpdatesAreAllKept() async throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = WorkStore(dir: dir)
        let w = try await s.start(title: "A", terminal: UUID(), floorId: nil, branch: nil)
        try await withThrowingTaskGroup(of: Void.self) { g in
            for i in 0..<50 { g.addTask { try await s.update(w.id) { $0.tasks.append(WorkTask(id: "t\(i)", title: "t")) } } }
            try await g.waitForAll()
        }
        let want = Set((0..<50).map { "t\($0)" })
        #expect(Set(try #require(try await s.get(w.id)).tasks.map(\.id)) == want)
        #expect(Set(try #require(try await WorkStore(dir: dir).get(w.id)).tasks.map(\.id)) == want)
    }
}
