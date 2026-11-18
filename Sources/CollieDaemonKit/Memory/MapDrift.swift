import Foundation
import CollieCore

/// What changed under one map path between two commits (text files only: a binary change is ignored).
struct PathChange: Equatable, Sendable {
    var added = 0, deleted = 0, files = 0
}

/// A map path as it is on disk now: a file's line count (nil: over `MapDrift.maxReadBytes`) or a directory's tracked files.
struct PathExtent: Equatable, Sendable {
    var isDir: Bool
    var lines: Int?
    var files: Int?
}

/// `changes`: per requested path that changed (absent = unchanged). `anchorGone`: the anchor isn't a commit of this repo
/// (rebased away, shallow clone): re-anchor. `unknown`: git failed, timed out, or the root isn't a repo: judge nothing.
enum MapDriftFacts: Equatable, Sendable {
    case unknown, anchorGone
    case changes([String: PathChange])
}

/// Item 7 of spec 2026-11-17-memory-stage-rules: a map whose file changed a lot since its anchor commit is contested
/// (owner's thresholds: 40 lines or 40% of a file, 5 files or 30% of a directory; binary ignored).
enum MapDrift {
    static let minLines = 40, minFiles = 5
    static let maxReadBytes = 1 << 20
    static let subjectsMax = 5, subjectMax = 120
    /// ponytail: at most 50 maps measured a pass (oldest checked first) and 50 paths per git call; raise if stores grow.
    static let maxPerPass = 50

    static func exceeds(_ c: PathChange, _ x: PathExtent) -> Bool {
        if x.isDir {   // integer ceil: 30% of 100 is 30, not 31
            return c.files > 0 && c.files >= max(minFiles, ((x.files ?? 0) * 3 + 9) / 10)
        }
        let n = c.added + c.deleted
        return n > 0 && n >= max(minLines, ((x.lines ?? 0) * 4 + 9) / 10)
    }

    /// The flag reason's fact (data for the curator): numbers, the path and a short anchor only.
    static func detail(_ path: String, _ c: PathChange, _ x: PathExtent, anchor: String) -> String {
        let since = "desde \(anchor.prefix(8))"
        if x.isDir { return "\(path) \(c.files) de \(x.files.map(String.init) ?? "?") arquivos mudaram \(since)" }
        let pct = x.lines.flatMap { $0 > 0 ? " (\(min(999, (c.added + c.deleted) * 100 / $0))% do arquivo)" : nil } ?? ""
        return "\(path) +\(c.added) −\(c.deleted) linhas \(since)\(pct)"
    }

    /// A full SHA-1 or SHA-256 commit name, nothing git could read as an option or a revision expression.
    static func isCommit(_ s: String) -> Bool {
        (s.count == 40 || s.count == 64) && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// A map path as git's literal pathspec: no trailing slash, repo-relative, never empty.
    static func norm(_ p: String) -> String? {
        var s = p
        while s.hasSuffix("/") { s.removeLast() }
        while s.hasPrefix("./") { s.removeFirst(2) }
        return s.isEmpty || !isRepoRelative(s) ? nil : s
    }

    /// Global options for every drift git call (after `GitRunner`'s hooks/fsmonitor off): no pager, a path is a name
    /// (never a glob or pathspec magic), no external diff. The diff itself adds --no-ext-diff --no-textconv.
    static let safe = ["--no-pager", "--literal-pathspecs", "-c", "diff.external=", "-c", "core.quotePath=false"]
}

extension GitFacts {
    func head() async -> String? { nil }
    func changes(from anchor: String, to head: String, paths: [String]) async -> MapDriftFacts { .unknown }
    func extent(_ rel: String) async -> PathExtent? { nil }
    func subjects(from anchor: String, to head: String, path: String) async -> [String] { [] }
}

extension CommandRouter {
    /// Step (4b) of `lifecyclePass`: each eligible `map` is anchored at HEAD (per text) and, from its next pass, measured
    /// against that anchor; past the threshold it is contested like a failed claim check (a flag of session "claim-check",
    /// re-check queued) but never archived on its own: `enqueueVerify` re-runs `ClaimChecks.check`, which knows no drift,
    /// so with no curator it waits and goes to "Precisa de você" after 14 days. A re-check (or the user) keeping it after
    /// its anchor, or an anchor git no longer has, re-anchors at HEAD. `room`: what is left of the pass's contest cap.
    /// Cost: 1 `rev-parse`, 1 `diff --numstat` per distinct anchor (50 paths a call), 1 `ls-files` per directory measured,
    /// 1 `log` per contest; at most `MapDrift.maxPerPass` maps measured, least recently checked first.
    func mapDriftPass(_ store: RepoMemory, eligible: [MemoryRecord], fresh: Set<UUID>, facts: any GitFacts, room: Int,
                      now: Date, day: String) async {
        let maps = eligible.filter { $0.kind == .map && $0.path.flatMap(MapDrift.norm) != nil }
        guard !maps.isEmpty, let head = await facts.head() else { return }
        let lc = memory.lifecycle, entries = await lc.all(), key = store.key
        var anchor: [UUID: String] = [:]   // id → text hash to anchor at HEAD now
        var due: [(r: MemoryRecord, a: MapAnchor, path: String, checked: Date?)] = []
        for r in maps {
            guard let e = entries[r.id], !e.contestedNow, let p = r.path.flatMap(MapDrift.norm) else { continue }
            let h = LifecycleRules.textHash(r)
            // no anchor in this store for this text, or this store's drift contest is over: anchored at HEAD now
            guard let a = e.mapAnchor(for: h, store: key), !Self.settled(a, e) else { anchor[r.id] = h; continue }
            guard !fresh.contains(r.id), a.commit != head, facts.pathExists(p) else { continue }   // a gone path is `pathMissing`'s
            due.append((r, a, p, e.mapCheckedAt))
        }
        due.sort { ($0.checked ?? .distantPast) < ($1.checked ?? .distantPast) }
        due = Array(due.prefix(MapDrift.maxPerPass))

        var checked: [UUID] = [], contests = 0
        for (commit, group) in Dictionary(grouping: due, by: { $0.a.commit }) {
            switch await facts.changes(from: commit, to: head, paths: group.map(\.path)) {
            case .unknown: continue
            case .anchorGone: for g in group { anchor[g.r.id] = g.a.textHash }
            case .changes(let changes):
                for g in group {
                    checked.append(g.r.id)
                    guard contests < room, let c = changes[g.path], let x = await facts.extent(g.path), MapDrift.exceeds(c, x) else { continue }
                    let subjects = await facts.subjects(from: commit, to: head, path: g.path)
                    let reason = "mapDrift " + MapDrift.detail(g.path, c, x, anchor: commit)
                        + (subjects.isEmpty ? "" : "; commits: " + subjects.joined(separator: " | "))
                    await lc.update(g.r.id, now: now) { e in
                        e.flags.append(LifecycleFlag(verdict: .outdated, session: "claim-check", day: day, reason: String(reason.prefix(CuratorOps.lineMax))))
                        e.contestedNow = true; e.lastContestedAt = now
                        if var x = e.mapAnchor(for: g.a.textHash, store: key) { x.contestedAt = now; e.setMapAnchor(x) }
                    }
                    contests += 1
                    if entries[g.r.id]?.tier == .longTerm { memory.noteLifecycle(.demoted, g.r.id, store: store.key) }
                    _ = await enqueueVerify(g.r.id, kind: .verifyContested)
                }
            }
        }
        let ids = Array(anchor.keys) + checked
        guard !ids.isEmpty else { return }
        await lc.update(ids, now: now) { id, e in
            if let h = anchor[id] { e.setMapAnchor(MapAnchor(textHash: h, commit: head, at: now, store: key)) }
            if checked.contains(id) { e.mapCheckedAt = now }
        }
    }

    /// This store's drift contested the map and that contest is over (a valid re-check, or the user kept it; an invalid
    /// one archived it). No clock compared: the verdict's time and the pass's are different clocks in tests and replays.
    static func settled(_ a: MapAnchor, _ e: LifecycleEntry) -> Bool { a.contestedAt != nil && !e.contestedNow }
}
