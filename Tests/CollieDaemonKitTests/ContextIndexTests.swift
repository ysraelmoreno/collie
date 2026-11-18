import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

private func dec(_ title: String, body: String = "", pinned: Bool = false, age: TimeInterval = 0) -> MemoryRecord {
    MemoryRecord(kind: .decision, subject: title, title: title, body: body, pinned: pinned, createdAt: Date().addingTimeInterval(-age))
}
private func pit(_ title: String) -> MemoryRecord {
    MemoryRecord(kind: .pitfall, subject: title, title: title, body: "exemplo de \(title)", hits: 3)
}
private func uses(_ n: Int) -> LifecycleEntry {
    var e = LifecycleEntry(tier: .provisional, tierSince: Date())
    e.usefulUses = Set((0..<n).map { UseKey(day: "2026-11-\(10 + $0)", session: "s\($0)") })
    return e
}
private func indexLines(_ text: String) -> [String] {
    guard let r = text.range(of: MemoryService.indexTitle) else { return [] }
    return text[r.upperBound...].split(separator: "\n").map { String($0.dropFirst(2)) }
}

/// Item 5 (leva 2): the session-start index ordered by use, and a cap on pinned memories.
@Suite struct ContextIndexTests {
    @Test func indexOrderedByUseThenRecency() {
        let most = dec("Mais usada", age: 900), less = dec("Menos usada", age: 10), zeroNew = dec("Zero nova", age: 5)
        let zeroOld = dec("Zero velha", age: 500), noEntry = dec("Sem entrada", age: 0)
        let entries = [most.id: uses(3), less.id: uses(1), zeroNew.id: uses(0), zeroOld.id: uses(0)]
        var out = MemoryService.header
        MemoryService.appendIndex(&out, [noEntry, zeroOld, less, zeroNew, most], limit: 4096, entries: entries)
        #expect(indexLines(out) == ["Mais usada", "Menos usada", "Zero nova", "Zero velha", "Sem entrada"], "\(out)")
    }

    @Test func indexSkipsWhatDoesNotFitAndKeepsGoing() {
        let long = dec(String(repeating: "L", count: 190)), short = dec("Curta", age: 10)
        var out = MemoryService.header
        let room = out.utf8.count + ("\n\n" + MemoryService.indexTitle).utf8.count + 60
        MemoryService.appendIndex(&out, [long, short], limit: room, entries: [long.id: uses(2)])
        #expect(indexLines(out) == ["Curta"], "\(out)")
    }

    @Test func pinnedCappedKeepChecklistAndIndex4096() async throws {
        let repo = try await makeRepo()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ci-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let mem = MemoryService(globalDir: root.appendingPathComponent("memory"))
        let store = await mem.repo(for: repo.path)
        let pinned = (0..<20).map { dec("Fixada \($0)", body: String(repeating: "corpo fixo ", count: 25), pinned: true, age: Double($0)) }
        let plain = (0..<10).map { dec("Comum \($0)", age: Double(100 + $0)) }
        try await store.run { m in for r in pinned + plain + [pit("Armadilha A"), pit("Armadilha B")] { try m.store.write(r) } }
        let (text, ids) = await mem.contextText(cwd: repo.path, paddock: nil)
        #expect(text.utf8.count <= 4096, "\(text.utf8.count)")
        let head = text.components(separatedBy: "\n\n" + MemoryService.checklistHeader).first ?? text
        #expect(head.utf8.count <= 4096 - MemoryService.pinnedReserve, "\(head.utf8.count)")
        #expect(MemoryService.pinnedLimit(4096) == 1_600 && MemoryService.pinnedLimit(100) == 100
                && MemoryService.pinnedLimit(2_600) == MemoryService.header.utf8.count)   // never below the header
        #expect(text.contains(MemoryService.checklistHeader) && text.contains("Armadilha A"), "\(text)")
        let index = indexLines(text)
        let full = pinned.filter { ids.contains($0.id) }, over = pinned.filter { !ids.contains($0.id) }
        #expect(!full.isEmpty && !over.isEmpty)
        #expect(full.allSatisfy { text.contains("] \($0.title): corpo fixo") })   // pinned in full, inside the cap
        // what doesn't fit becomes a marked index line, before the rest; never in full
        #expect(index.first == "\(over[0].title)\(MemoryService.pinnedOverflowMark)", "\(index)")
        #expect(over.allSatisfy { !text.contains("] \($0.title): ") })
        #expect(index.contains { $0.hasPrefix("Comum ") }, "\(index)")
    }
}
