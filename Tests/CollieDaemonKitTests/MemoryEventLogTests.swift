import Testing
import Foundation
import Synchronization
@testable import CollieDaemonKit

private func tempDir() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("mev-\(UUID().uuidString)") }
private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

@Suite struct MemoryEventLogTests {
    @Test func appendsOffTheCallerOneLinePerEvent() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let q = DispatchQueue(label: "test.events")
        let at = date("2026-10-20T12:00:00Z")
        let log = MemoryEventLog(dir: dir, now: { at }, queue: q)
        q.suspend()
        log.emit(MemoryEvent(type: .noHit, terminal: UUID()))
        let file = dir.appendingPathComponent("memory-\(MemoryEventLog.day(at)).jsonl")
        #expect(!FileManager.default.fileExists(atPath: file.path))   // emit returned without writing: the hook never waits
        q.resume()
        log.emit(MemoryEvent(type: .injected, bytes: 10, tokens: MemoryEvent.estimate(bytes: 10), where: "prompt"))
        log.flush()
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(!lines[0].contains("bytes"))   // unused fields are left out
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int) == 0o700)
        let back = log.read(since: .distantPast)
        #expect(back.map(\.type) == [.noHit, .injected] && back[1].tokens == 3 && back[1].at == at)
    }

    @Test func rotatesDailyAndKeeps90Days() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Mutex(date("2026-06-01T12:00:00Z"))
        let log = MemoryEventLog(dir: dir, now: { clock.withLock { $0 } })
        log.emit(MemoryEvent(type: .searched, hits: 1))
        clock.withLock { $0 = date("2026-06-02T12:00:00Z") }
        log.emit(MemoryEvent(type: .searched, hits: 2))
        log.flush()
        let names = { (try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()) ?? [] }
        #expect(names().count == 2)
        #expect(log.read(since: date("2026-06-02T00:00:00Z")).map(\.hits) == [2])
        clock.withLock { $0 = date("2026-09-15T12:00:00Z") }   // 105 days after the first: both expire
        log.emit(MemoryEvent(type: .searched, hits: 3))
        log.flush()
        #expect(names() == ["memory-\(MemoryEventLog.day(date("2026-09-15T12:00:00Z"))).jsonl"])
    }

    @Test func placeReadsStoreKeys() {
        let lot = UUID()
        var a = MemoryEvent(type: .created); a.place(store: "lot:\(lot.uuidString.lowercased())")
        var b = MemoryEvent(type: .created); b.place(store: "/repo")
        var c = MemoryEvent(type: .created); c.place(store: "global")
        #expect(a.lot == lot && a.project == nil && b.project == "/repo" && c.lot == nil && c.project == nil)
    }
}
