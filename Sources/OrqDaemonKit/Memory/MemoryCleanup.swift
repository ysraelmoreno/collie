import Foundation
import OrqCore
import OrqProtocol

struct CleanupItem: Codable, Sendable, Equatable {
    enum Action: String, Codable, Sendable { case archiveCold, archiveMissingPath, mergeDuplicate }
    var action: Action
    var id: UUID
    var into: UUID?      // the record kept in a merge
    var reason: String
}

/// Reversible cleanup: plan is pure, apply only flips status/supersededBy (never deletes), restore undoes it.
enum MemoryCleanup {
    static let coldAge: TimeInterval = 60 * 86400, missingAge: TimeInterval = 7 * 86400
    static let halfLife: TimeInterval = 30 * 86400, coldScore = 0.25, jaccardMin = 0.9

    static func plan(records: [MemoryRecord], stats: [UUID: MemoryStats], now: Date) -> [CleanupItem] {
        func days(_ t: TimeInterval) -> Int { Int(t / 86400) }
        var items: [CleanupItem] = []
        var rest: [MemoryRecord] = []
        for r in records where r.status == .active && !r.pinned {
            let s = stats[r.id]
            if let m = s?.missingSince, now.timeIntervalSince(m) >= missingAge {
                items.append(CleanupItem(action: .archiveMissingPath, id: r.id, into: nil,
                                         reason: "caminho sumiu há \(days(now.timeIntervalSince(m))) dias"))
                continue
            }
            let age = now.timeIntervalSince(s?.lastReadAt ?? r.createdAt)
            if age >= coldAge, pow(0.5, age / halfLife) <= coldScore {
                items.append(CleanupItem(action: .archiveCold, id: r.id, into: nil, reason: "não lida há \(days(age)) dias"))
                continue
            }
            rest.append(r)
        }
        // Duplicates: newest (updatedAt, then id) is kept; later ones merge into it.
        rest.sort { ($0.updatedAt, $1.id.uuidString) > ($1.updatedAt, $0.id.uuidString) }
        var gone = Set<UUID>()
        for (i, keep) in rest.enumerated() where !gone.contains(keep.id) {
            for other in rest[(i + 1)...] where !gone.contains(other.id) && isDuplicate(keep, other) {
                gone.insert(other.id)
                items.append(CleanupItem(action: .mergeDuplicate, id: other.id, into: keep.id,
                                         reason: "duplicata de \"\(keep.title)\""))
            }
        }
        return items
    }

    /// Returns the records that changed. Items whose record is gone or no longer active are skipped (stale plan).
    static func apply(_ items: [CleanupItem], store: MemoryStore) throws -> [MemoryRecord] {
        let byId = Dictionary(store.all().records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changed: [MemoryRecord] = []
        for item in items {
            guard var r = byId[item.id], r.status == .active, !r.pinned else { continue }
            switch item.action {
            case .archiveCold, .archiveMissingPath: r.status = .archived
            case .mergeDuplicate:
                guard let into = item.into, into != item.id, byId[into]?.status == .active else { continue }
                r.status = .superseded; r.supersededBy = into
            }
            try store.write(r)
            changed.append(r)
        }
        return changed
    }

    /// Back to active; any other active record with the same key (as in `MemoryStore.save`) is superseded by it.
    static func restore(_ id: UUID, store: MemoryStore, index: MemoryIndex? = nil) throws -> MemoryRecord {
        let all = store.all().records
        guard var r = all.first(where: { $0.id == id }) else {
            throw ProtocolError(code: .invalidArgs, message: "memory \(id.uuidString.lowercased()) not found")
        }
        r.status = .active; r.supersededBy = nil
        try store.write(r)   // restored first: a crash in between leaves two actives, never a dangling supersededBy
        for var o in all where o.status == .active && o.id != id && o.kind == r.kind && o.scope == r.scope
            && o.floor == r.floor && MemoryRecord.normalize(o.subject) == MemoryRecord.normalize(r.subject) {
            o.status = .superseded; o.supersededBy = id
            try store.write(o)
        }
        index?.touch(id)
        return r
    }

    private static func isDuplicate(_ a: MemoryRecord, _ b: MemoryRecord) -> Bool {
        guard a.kind == b.kind, a.scope == b.scope, a.floor == b.floor, a.kind != .map || a.path == b.path else { return false }
        let ab = MemoryRecord.normalize(a.body)
        if !ab.isEmpty, ab == MemoryRecord.normalize(b.body) { return true }
        let wa = words(a), wb = words(b)
        guard wa.count >= 3, wb.count >= 3 else { return false }
        return Double(wa.intersection(wb).count) / Double(wa.union(wb).count) >= jaccardMin
    }

    private static func words(_ r: MemoryRecord) -> Set<String> {
        Set("\(r.title) \(r.body)".lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
    }
}
