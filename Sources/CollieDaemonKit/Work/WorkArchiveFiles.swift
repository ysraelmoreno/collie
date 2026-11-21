import Foundation
import CollieCore

/// T6.1: `<root>/work-archive/` (0700): one `WorkArchive` per close, `<work id>.json`, then `<work id>-2.json`, … for a
/// work reopened and closed again. Each file is written once (a temp file hard-linked to its name: an existing name is
/// never replaced) and the newest `keep` files stay. Called on `WorkStore`'s disk queue only.
enum WorkArchiveFiles {
    static let keep = 200

    /// The archive of `w` (closed) written under its next free name, its timeline following the work's last archive.
    /// Returns the file; nil: it could not be written (the close itself already is: a summary never fails it).
    @discardableResult
    static func write(_ w: Work, paddock: String?, terminal: String?, loopSummary: String, dir: URL, keep: Int = keep) -> URL? {
        let id = w.id.uuidString.lowercased()
        let previous = files(of: id, in: dir).last.flatMap { (try? Data(contentsOf: $0.url)).flatMap(WorkArchive.decoded) }
        let a = WorkArchive.make(w, paddock: paddock, terminal: terminal, loopSummary: loopSummary, previous: previous?.timeline ?? [])
        guard let data = try? a.encoded(), data.count <= WorkArchive.maxBytes else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".\(id).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
        defer { unlink(tmp.path) }
        var n = (files(of: id, in: dir).last?.n ?? 0) + 1
        while n < 10_000 {
            let url = dir.appendingPathComponent(n == 1 ? "\(id).json" : "\(id)-\(n).json")
            if link(tmp.path, url.path) == 0 { prune(dir, keep: keep, sparing: url); return url }
            guard errno == EEXIST else { return nil }
            n += 1   // written meanwhile (never by this daemon: one disk queue): the next name
        }
        return nil
    }

    /// Every archive in `dir`, the newest file of each work only, with when it was written (`closedAt` keeps whole
    /// seconds: two closes in one second are told apart by it). ponytail: reads every file (at most `keep`, each at
    /// most 1 MB) per call; an index file if `work.history` gets slow.
    static func latest(in dir: URL) -> [String: (archive: WorkArchive, written: Date)] {
        var newest: [String: (n: Int, url: URL)] = [:]
        for (url, id, n) in all(in: dir) where newest[id].map({ $0.n < n }) ?? true { newest[id] = (n, url) }
        return newest.compactMapValues { f in
            (try? Data(contentsOf: f.url)).flatMap(WorkArchive.decoded).map { ($0, mtime(f.url)) }
        }
    }

    static func mtime(_ u: URL) -> Date { (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast }

    /// The archives of `dir` (`<id>.json` is number 1), unsorted.
    private static func all(in dir: URL) -> [(url: URL, id: String, n: Int)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { return nil }
            let stem = String(name.dropLast(5))
            guard stem.count >= 36, UUID(uuidString: String(stem.prefix(36))) != nil else { return nil }
            let rest = stem.dropFirst(36)
            let n = rest.isEmpty ? 1 : rest.hasPrefix("-") ? Int(rest.dropFirst()) : nil
            guard let n, n >= 1 else { return nil }
            return (dir.appendingPathComponent(name), String(stem.prefix(36)), n)
        }
    }

    private static func files(of id: String, in dir: URL) -> [(url: URL, n: Int)] {
        all(in: dir).filter { $0.id == id }.map { ($0.url, $0.n) }.sorted { $0.n < $1.n }
    }

    /// Past `keep` files, the oldest (by modification time, then name) are deleted; never `sparing`.
    static func prune(_ dir: URL, keep: Int, sparing: URL) {
        let files = all(in: dir).map(\.url)
        guard files.count > keep else { return }
        let old = files.filter { $0.lastPathComponent != sparing.lastPathComponent }
            .map { ($0, mtime($0)) }.sorted { ($0.1, $0.0.lastPathComponent) < ($1.1, $1.0.lastPathComponent) }
        for (u, _) in old.prefix(files.count - keep) { unlink(u.path) }
    }
}
