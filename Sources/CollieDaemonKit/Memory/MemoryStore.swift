import Foundation
import CollieCore

/// Synchronous markdown file store; callers run it on a serial queue.
struct MemoryStore {
    let dir: URL
    /// Private (a lot's store in the app's data dir): every folder from `secureRoot` down is 0700, files 0600, like the
    /// work registry. Folders are made only on the first write: reading a store never creates it.
    let secureRoot: URL?
    init(dir: URL, secureRoot: URL? = nil) { self.dir = dir; self.secureRoot = secureRoot }
    private var secure: Bool { secureRoot != nil }

    func all() -> (records: [MemoryRecord], problems: [(file: String, error: String)]) {
        var records: [MemoryRecord] = [], problems: [(file: String, error: String)] = []
        let base = dir.standardizedFileURL.path + "/"
        let urls = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }
        for u in urls {
            let rel = u.standardizedFileURL.path.replacingOccurrences(of: base, with: "")
            guard let text = try? String(contentsOf: u, encoding: .utf8) else { problems.append((rel, "unreadable")); continue }
            do { records.append(try MemoryFile.parse(text)) } catch { problems.append((rel, error.message)) }
        }
        return (records, problems)
    }

    func write(_ r: MemoryRecord) throws {
        let dest = dir.appendingPathComponent(MemoryFile.fileName(r))
        let folder = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: secure ? [.posixPermissions: 0o700] : nil)
        if let top = secureRoot?.standardizedFileURL.path {
            var d = folder.standardizedFileURL
            while d.path.hasPrefix(top) { chmod(d.path, 0o700); d = d.deletingLastPathComponent() }
        }
        let tmp = folder.appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try Data(MemoryFile.render(r).utf8).write(to: tmp)
            if secure, chmod(tmp.path, 0o600) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if rename(tmp.path, dest.path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch { try? FileManager.default.removeItem(at: tmp); throw error }
        // A changed subject renames the file: drop stale copies of this id.
        for u in files(for: r.id) where u.standardizedFileURL != dest.standardizedFileURL { try FileManager.default.removeItem(at: u) }
    }

    func save(_ new: MemoryRecord) throws -> (saved: MemoryRecord, superseded: MemoryRecord?) {
        var new = new
        let olds = all().records.filter {
            $0.status == .active && $0.id != new.id && $0.kind == new.kind && $0.scope == new.scope
                && $0.paddock == new.paddock && $0.lotId == new.lotId && MemoryRecord.normalize($0.subject) == MemoryRecord.normalize(new.subject)
                && !($0.hits != nil && new.hits == nil)   // a pitfall instance never replaces its class: it bumps it (`enqueuePitfall`)
        }
        new.subject = MemoryRecord.normalize(new.subject)
        if let o = olds.first { new.supersedes = o.id }
        try write(new)   // new first: a crash in between leaves two actives, never a dangling supersededBy
        var first: MemoryRecord?
        for var o in olds {
            o.status = .superseded; o.supersededBy = new.id; o.updatedAt = new.updatedAt; try write(o)
            if first == nil { first = o }
        }
        return (new, first)
    }

    func delete(_ id: UUID) throws {
        for u in files(for: id) { try FileManager.default.removeItem(at: u) }
    }

    /// Files whose frontmatter id == id (name suffix is only a prefilter).
    private func files(for id: UUID) -> [URL] {
        let suffix = "-\(id.uuidString.lowercased().prefix(8)).md"
        return (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []).filter { u in
            guard u.lastPathComponent.hasSuffix(suffix), let t = try? String(contentsOf: u, encoding: .utf8) else { return false }
            return (try? MemoryFile.parse(t))?.id == id
        }
    }
}
