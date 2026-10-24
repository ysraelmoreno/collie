import Foundation
import SQLite3
import CollieCore
import CollieProtocol

struct MemoryHit: Sendable { var record: MemoryRecord; var score: Double }
struct MemoryStats: Sendable, Equatable { var reads: Int; var lastReadAt: Date?; var missingSince: Date? }

/// Derived SQLite FTS5 index over a `MemoryStore`. The markdown files are the source of truth;
/// only `stats` is index-owned (it survives `refresh(force: true)`).
/// Not Sendable: used only from the repo's serial queue.
final class MemoryIndex {
    private let db: OpaquePointer
    private let store: MemoryStore
    private let repoRoot: URL?
    static let maxTerms = 32, maxTermLength = 64, halfLife: Double = 30 * 86400

    init(dbFile: URL, store: MemoryStore, repoRoot: URL?) throws {
        self.store = store; self.repoRoot = repoRoot
        try? FileManager.default.createDirectory(at: dbFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        var h: OpaquePointer?
        let rc = sqlite3_open_v2(dbFile.path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "rc \(rc)"
            sqlite3_close(h)
            throw ProtocolError(code: .internal, message: "memory index: cannot open \(dbFile.path): \(msg)")
        }
        db = h
        // Half-life decay on age in seconds (future dates clamp to 1).
        let fn = sqlite3_create_function_v2(db, "collie_recency", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil, { ctx, _, argv in
            let age = max(sqlite3_value_double(argv![0]!), 0)
            sqlite3_result_double(ctx, pow(0.5, age / MemoryIndex.halfLife))
        }, nil, nil, nil)
        guard fn == SQLITE_OK else { throw fail("create function") }
        // v1: docs rows say `paddock` (an index from before the herding vocabulary said `floor`): rebuilt from the files
        var version = 0
        try query("PRAGMA user_version", []) { version = Int(sqlite3_column_int64($0, 0)) }
        if version < 1 { try exec("DROP TABLE IF EXISTS docs; DROP TABLE IF EXISTS fts; PRAGMA user_version = 1;") }
        try exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS docs(id TEXT PRIMARY KEY, file TEXT NOT NULL, mtime REAL NOT NULL, size INTEGER NOT NULL,
              kind TEXT NOT NULL, scope TEXT NOT NULL, paddock TEXT, subject TEXT NOT NULL, status TEXT NOT NULL,
              pinned INTEGER NOT NULL, updatedAt REAL NOT NULL, path TEXT, json TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS docs_file ON docs(file);
            CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(title, subject, body, path, tokenize='unicode61 remove_diacritics 2');
            CREATE TABLE IF NOT EXISTS stats(id TEXT PRIMARY KEY, reads INTEGER NOT NULL DEFAULT 0, lastReadAt REAL, missingSince REAL);
            """)
    }

    deinit { sqlite3_close_v2(db) }

    // MARK: refresh

    @discardableResult
    func refresh(force: Bool = false) throws -> [(file: String, error: String)] {
        var problems: [(file: String, error: String)] = []
        try exec("BEGIN IMMEDIATE")
        do {
            if force { try exec("DELETE FROM docs; DELETE FROM fts;") }
            var known: [String: (mtime: Double, size: Int)] = [:]
            try query("SELECT file, mtime, size FROM docs", []) { known[text($0, 0)] = (sqlite3_column_double($0, 1), Int(sqlite3_column_int64($0, 2))) }
            let onDisk = files()
            for (file, meta) in onDisk {
                if let k = known[file], k.mtime == meta.mtime, k.size == meta.size { continue }
                let url = store.dir.appendingPathComponent(file)
                do {
                    guard let t = try? String(contentsOf: url, encoding: .utf8) else { throw ProtocolError(code: .invalidArgs, message: "unreadable") }
                    try put(try MemoryFile.parse(t), file: file, mtime: meta.mtime, size: meta.size)
                } catch {
                    try removeFile(file)
                    problems.append((file, (error as? ProtocolError)?.message ?? "\(error)"))
                }
            }
            for file in known.keys where onDisk[file] == nil { try removeFile(file) }
            try resolveConflicts()
            try markMissingMaps()
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
        return problems
    }

    /// 2+ active with the same kind+subject+scope/paddock: newest `updatedAt` stays, the rest are written as superseded.
    private func resolveConflicts() throws {
        var keys: [[String]] = []
        try query("""
            SELECT kind, subject, scope, coalesce(paddock, '') FROM docs WHERE status = 'active'
            GROUP BY 1, 2, 3, 4 HAVING count(*) > 1
            """, []) { keys.append([text($0, 0), text($0, 1), text($0, 2), text($0, 3)]) }
        for k in keys {
            var recs: [MemoryRecord] = []
            try query("""
                SELECT json FROM docs WHERE status = 'active' AND kind = ? AND subject = ? AND scope = ? AND coalesce(paddock, '') = ?
                ORDER BY updatedAt DESC, id
                """, k) { if let r = decode(text($0, 0)) { recs.append(r) } }
            guard let keep = recs.first else { continue }
            for var r in recs.dropFirst() {
                r.status = .superseded; r.supersededBy = keep.id
                try store.write(r)
                let file = MemoryFile.fileName(r)
                guard let meta = stat(store.dir.appendingPathComponent(file)) else { continue }
                try put(r, file: file, mtime: meta.mtime, size: meta.size)
            }
        }
    }

    private func markMissingMaps() throws {
        guard let repoRoot else { return }
        var maps: [(String, String)] = []
        try query("SELECT id, path FROM docs WHERE kind = 'map' AND path IS NOT NULL", []) { maps.append((text($0, 0), text($0, 1))) }
        let now = Date().timeIntervalSince1970
        for (id, path) in maps {
            if repoPathExists(path, root: repoRoot) {
                try query("UPDATE stats SET missingSince = NULL WHERE id = ?", [id]) { _ in }
            } else {
                try query("""
                    INSERT INTO stats(id, missingSince) VALUES(?, ?)
                    ON CONFLICT(id) DO UPDATE SET missingSince = coalesce(missingSince, excluded.missingSince)
                    """, [id, now]) { _ in }
            }
        }
    }

    private func put(_ r: MemoryRecord, file: String, mtime: Double, size: Int) throws {
        try query("DELETE FROM fts WHERE rowid IN (SELECT rowid FROM docs WHERE id = ? OR file = ?)", [key(r.id), file]) { _ in }
        try query("DELETE FROM docs WHERE id = ? OR file = ?", [key(r.id), file]) { _ in }
        let json = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        try query("""
            INSERT INTO docs(id, file, mtime, size, kind, scope, paddock, subject, status, pinned, updatedAt, path, json)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [key(r.id), file, mtime, size, r.kind.rawValue, r.scope.rawValue, r.paddock, r.subject, r.status.rawValue,
                  r.pinned, r.updatedAt.timeIntervalSince1970, r.path, json]) { _ in }
        try query("INSERT INTO fts(rowid, title, subject, body, path) VALUES(?, ?, ?, ?, ?)",
                  [Int(sqlite3_last_insert_rowid(db)), r.title, r.subject, r.body, r.path ?? ""]) { _ in }
    }

    private func removeFile(_ file: String) throws {
        try query("DELETE FROM fts WHERE rowid IN (SELECT rowid FROM docs WHERE file = ?)", [file]) { _ in }
        try query("DELETE FROM docs WHERE file = ?", [file]) { _ in }
    }

    /// Relative path -> (mtime, size) of every .md under the store dir.
    private func files() -> [String: (mtime: Double, size: Int)] {
        let base = store.dir.resolvingSymlinksInPath().path + "/"
        var out: [String: (mtime: Double, size: Int)] = [:]
        let urls = FileManager.default.enumerator(at: store.dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])?
            .compactMap { $0 as? URL } ?? []
        for u in urls where u.pathExtension == "md" {
            let p = u.resolvingSymlinksInPath().path
            guard p.hasPrefix(base), let m = stat(u) else { continue }
            out[String(p.dropFirst(base.count))] = m
        }
        return out
    }

    private func stat(_ u: URL) -> (mtime: Double, size: Int)? {
        guard let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let d = v.contentModificationDate, let s = v.fileSize else { return nil }
        return (d.timeIntervalSince1970, s)
    }

    // MARK: search & stats

    /// Up to 32 terms of `[\p{L}\p{N}_./-]{2,}` containing a letter or digit; the rest of the text is ignored.
    static func ftsTerms(_ text: String) -> [String] {
        var terms: [String] = [], cur = ""
        func flush() {
            if cur.count >= 2, cur.contains(where: { $0.isLetter || $0.isNumber }) {
                terms.append(String(cur.prefix(maxTermLength)))   // ponytail: long tokens truncated, they'd never match anyway
            }
            cur = ""
        }
        for ch in text {
            if ch.isLetter || ch.isNumber || "_./-".contains(ch) { cur.append(ch) } else { flush() }
            if terms.count == maxTerms { return terms }
        }
        flush()
        return Array(terms.prefix(maxTerms))
    }

    /// Each term quoted (no `"` can survive `ftsTerms`), OR-joined; path-like terms also prefix-match `path`.
    static func ftsQuery(_ text: String) -> String? {
        let terms = ftsTerms(text)
        guard !terms.isEmpty else { return nil }
        return terms.map { t in
            let pathLike = t.contains("/") || (t.dropFirst().contains(".") && !t.hasSuffix("."))
            return pathLike ? "\"\(t)\" OR path:\"\(t)\"*" : "\"\(t)\""
        }.joined(separator: " OR ")
    }

    func search(_ query: String, limit: Int, kinds: Set<MemoryKind>? = nil, includeInactive: Bool = false) -> [MemoryHit] {
        guard limit > 0, let match = MemoryIndex.ftsQuery(query) else { return [] }
        if let kinds, kinds.isEmpty { return [] }
        let kindList = kinds.map { $0.map(\.rawValue).sorted() } ?? []
        let kindFilter = kindList.isEmpty ? "" : "AND d.kind IN (\(kindList.map { _ in "?" }.joined(separator: ", ")))"
        // Pinned memories don't decay: ×1.5 instead of the recency factor. Rank and LIMIT in the inner query on small columns; bodies (json) are read only for the winners.
        let sql = """
            SELECT d.json, t.score FROM (
              SELECT fts.rowid AS rid,
                -bm25(fts) * (1 + 0.1 * min(coalesce(s.reads, 0), 10)) * (CASE WHEN d.pinned THEN 1.5 ELSE collie_recency(? - d.updatedAt) END) AS score
              FROM fts JOIN docs d ON d.rowid = fts.rowid LEFT JOIN stats s ON s.id = d.id
              WHERE fts MATCH ? AND (? OR d.status = 'active') \(kindFilter)
              ORDER BY score DESC LIMIT ?
            ) t JOIN docs d ON d.rowid = t.rid ORDER BY t.score DESC
            """
        var hits: [MemoryHit] = []
        let args: [Any?] = [Date().timeIntervalSince1970, match, includeInactive] + kindList.map { $0 as Any? } + [limit]
        try? self.query(sql, args) { row in
            if let r = decode(text(row, 0)) { hits.append(MemoryHit(record: r, score: sqlite3_column_double(row, 1))) }
        }
        return hits
    }

    /// The indexed records among `ids`, any status (a hand-edited or deleted file shows here after `refresh`).
    func records(_ ids: [UUID]) -> [UUID: MemoryRecord] {
        guard !ids.isEmpty else { return [:] }
        var out: [UUID: MemoryRecord] = [:]
        try? query("SELECT json FROM docs WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ", ")))", ids.map { key($0) as Any? }) { row in
            if let r = decode(text(row, 0)) { out[r.id] = r }
        }
        return out
    }

    func noteRead(_ ids: [UUID]) {
        let now = Date().timeIntervalSince1970
        for id in ids {
            try? query("""
                INSERT INTO stats(id, reads, lastReadAt) VALUES(?, 1, ?)
                ON CONFLICT(id) DO UPDATE SET reads = reads + 1, lastReadAt = excluded.lastReadAt
                """, [key(id), now]) { _ in }
        }
    }

    /// Counts as a fresh read and clears `missingSince` (used when a cleanup is restored, so the next plan doesn't undo it).
    func touch(_ id: UUID) {
        try? query("""
            INSERT INTO stats(id, reads, lastReadAt, missingSince) VALUES(?, 0, ?, NULL)
            ON CONFLICT(id) DO UPDATE SET lastReadAt = excluded.lastReadAt, missingSince = NULL
            """, [key(id), Date().timeIntervalSince1970]) { _ in }
    }

    func stats(_ id: UUID) -> MemoryStats? {
        var out: MemoryStats?
        try? query("SELECT reads, lastReadAt, missingSince FROM stats WHERE id = ?", [key(id)]) { row in
            func date(_ i: Int32) -> Date? {
                sqlite3_column_type(row, i) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(row, i))
            }
            out = MemoryStats(reads: Int(sqlite3_column_int64(row, 0)), lastReadAt: date(1), missingSince: date(2))
        }
        return out
    }

    // MARK: sqlite helpers

    private func key(_ id: UUID) -> String { id.uuidString.lowercased() }
    private func decode(_ json: String) -> MemoryRecord? { try? JSONDecoder().decode(MemoryRecord.self, from: Data(json.utf8)) }
    private func text(_ row: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(row, i).map { String(cString: $0) } ?? "" }
    private func fail(_ what: String) -> ProtocolError {
        ProtocolError(code: .internal, message: "memory index: \(what): \(String(cString: sqlite3_errmsg(db)))")
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw fail("exec") }
    }

    /// Prepares, binds (never interpolates values), steps every row through `row`, finalizes.
    private func query(_ sql: String, _ args: [Any?], _ row: (OpaquePointer) throws -> Void) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { throw fail("prepare") }
        defer { sqlite3_finalize(st) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(st, n)
            case let v as String: sqlite3_bind_text(st, n, v, -1, transient)
            case let v as Bool: sqlite3_bind_int(st, n, v ? 1 : 0)
            case let v as Int: sqlite3_bind_int64(st, n, Int64(v))
            case let v as Double: sqlite3_bind_double(st, n, v)
            default: throw ProtocolError(code: .internal, message: "memory index: unsupported bind \(type(of: a))")
            }
        }
        while true {
            let rc = sqlite3_step(st)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else { throw fail("step") }
            try row(st)
        }
    }
}
