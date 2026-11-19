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

    static let reasonPrefix = "mapDrift ", subjectsMark = "; commits: "
    /// The flag reason of a memory whose `enforcedBy` check is gone (`enforcedGonePass`): this prefix and the path.
    static let enforcedGonePrefix = "enforcedBy gone: "

    /// A path plain enough to stand among the curator's verified facts: letters, digits and `._/@+-`, no spaces, ≤ 200.
    /// Anything else (a sentence as a file name, an instruction) is the memory's text, shown apart and unverified.
    static func safePath(_ p: String) -> Bool {
        !p.isEmpty && p.count <= 200 && p.unicodeScalars.allSatisfy { safeScalars.contains($0) }
    }
    private static let safeScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/@+-")

    /// A drift flag's reason as written by `mapDriftPass` (`mapDrift <numbers>; commits: a | b`): the numbers (the daemon's,
    /// a fact) and the commit subjects (an agent's text, never a fact). nil: not a drift reason.
    static func split(_ reason: String) -> (numbers: String, subjects: [String])? {
        guard reason.hasPrefix(reasonPrefix) else { return nil }
        let rest = reason.dropFirst(reasonPrefix.count)
        guard let r = rest.range(of: subjectsMark) else { return (String(rest), []) }
        let subjects = rest[r.upperBound...].components(separatedBy: " | ").filter { !$0.isEmpty }
        return (String(rest[..<r.lowerBound]), subjects)
    }

    enum LineCount: Equatable { case lines(Int), tooBig, failed }
    static let maxInterrupts = 8

    /// The lines of what `fd` reads, at most `maxReadBytes` (more: `tooBig`, a file that grew after its fstat).
    /// `read` is injectable so a test can stage an interrupted read.
    static func countLines(_ fd: Int32, read: (Int32, UnsafeMutableRawPointer?, Int) -> Int = { Darwin.read($0, $1, $2) }) -> LineCount {
        var lines = 0, total = 0, last: UInt8 = 0x0A, chunk = [UInt8](repeating: 0, count: 64 << 10), interrupted = 0
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            // a signal interrupted it: read again, at most `maxInterrupts` in a row (never spin forever)
            if n < 0, errno == EINTR, interrupted < maxInterrupts { interrupted += 1; continue }
            guard n >= 0 else { return .failed }
            interrupted = 0
            if n == 0 { break }
            total += n
            guard total <= maxReadBytes else { return .tooBig }
            for b in chunk[0..<n] where b == 0x0A { lines += 1 }
            last = chunk[n - 1]
        }
        return .lines(lines + (total > 0 && last != 0x0A ? 1 : 0))
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
    func existed(at commit: String, _ path: String) async -> Bool? { nil }
}

extension CommandRouter {
    /// Step (4b) of `lifecyclePass`: each eligible `map` is anchored at HEAD (per text) and, from its next pass, measured
    /// against that anchor; past the threshold it is contested like a failed claim check (a flag of session "claim-check",
    /// re-check queued) but never archived on its own: `enqueueVerify` re-runs `ClaimChecks.check`, which knows no drift,
    /// so with no curator it waits and goes to "Precisa de você" after 14 days. A re-check (or the user) keeping it after
    /// its anchor, or an anchor git no longer has, re-anchors at HEAD. `room`: what is left of the pass's contest cap.
    /// Cost: 1 `rev-parse`, 1 `diff --numstat` per distinct anchor (50 paths a call), 1 `ls-files` per directory measured,
    /// 1 `log` per contest; at most `MapDrift.maxPerPass` maps measured, least recently checked first.
    /// `live`: the keys of the stores Collie knows (`knownStores`); an entry written here drops other stores' anchors.
    func mapDriftPass(_ store: RepoMemory, eligible: [MemoryRecord], fresh: Set<UUID>, facts: any GitFacts, room: Int,
                      now: Date, day: String, live: Set<String>? = nil) async {
        await enforcedGonePass(store, facts: facts, now: now, day: day)
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
        // no contest left this pass: nothing measured (git not run), nothing marked checked
        due = room > 0 ? Array(due.prefix(MapDrift.maxPerPass)) : []

        // `checked`: measured this pass (an unknown answer too: round robin past the 50 cap); a drift with no room to
        // contest stays unchecked, so it is first next pass
        var checked: [UUID] = [], contests = 0
        for (commit, group) in Dictionary(grouping: due, by: { $0.a.commit }) {
            switch await facts.changes(from: commit, to: head, paths: group.map(\.path)) {
            case .unknown: checked += group.map(\.r.id)
            case .anchorGone: for g in group { anchor[g.r.id] = g.a.textHash }
            case .changes(let changes):
                for g in group {
                    guard let c = changes[g.path], let x = await facts.extent(g.path), MapDrift.exceeds(c, x) else { checked.append(g.r.id); continue }
                    guard contests < room else { continue }
                    checked.append(g.r.id)
                    // not in the anchor's tree (committed after it): nothing it could have drifted from, so it anchors here
                    switch await facts.existed(at: commit, g.path) {
                    case false?: anchor[g.r.id] = g.a.textHash; continue
                    case nil: continue
                    case true?: break
                    }
                    let subjects = await facts.subjects(from: commit, to: head, path: g.path)
                    let reason = MapDrift.reasonPrefix + MapDrift.detail(g.path, c, x, anchor: commit)
                        + (subjects.isEmpty ? "" : MapDrift.subjectsMark + subjects.joined(separator: " | "))
                    // re-read when written (one actor step): a flag, a verdict or the user's keep that landed while git ran wins
                    var wrote = false
                    let was = entries[g.r.id]
                    await lc.update(g.r.id, now: now) { e in
                        guard !e.contestedNow, e.recheckedAt == was?.recheckedAt, e.mapAnchor(for: g.a.textHash, store: key) == g.a else { return }
                        e.flags.append(LifecycleFlag(verdict: .outdated, session: "claim-check", day: day, reason: String(reason.prefix(CuratorOps.lineMax))))
                        e.contestedNow = true; e.lastContestedAt = now
                        var x = g.a; x.contestedAt = now; e.setMapAnchor(x)
                        wrote = true
                    }
                    guard wrote else { continue }
                    contests += 1
                    if entries[g.r.id]?.tier == .longTerm { memory.noteLifecycle(.demoted, g.r.id, store: store.key) }
                    _ = await enqueueVerify(g.r.id, kind: .verifyContested)
                }
            }
        }
        let ids = Array(anchor.keys) + checked
        guard !ids.isEmpty else { return }
        let keep = live.map { $0.union([key]) }   // nil: prune nothing
        await lc.update(ids, now: now) { id, e in
            // anchors of stores no longer known (a deleted paddock) and storeless ones go, so live stores never evict each other
            if let keep { e.mapAnchors?.removeAll { a in a.store.map { !keep.contains($0) } ?? true } }
            // only over the anchor this pass decided from (another writer's newer one stays)
            if let h = anchor[id], e.mapAnchor(for: h, store: key) == entries[id]?.mapAnchor(for: h, store: key) {
                e.setMapAnchor(MapAnchor(textHash: h, commit: head, at: now, store: key))
            }
            if checked.contains(id) { e.mapCheckedAt = now }
        }
    }

    /// PRD B3 requirement 5: an active memory whose `enforcedBy` check is gone goes back to the injection. Gone = git says
    /// the path is not in HEAD's tree and it is not on disk either (a check `git rm --cached` but still there counts;
    /// `memory enforce --by` itself only takes a file tracked in HEAD). `enforcedBy` is cleared, an outdated "claim-check" flag
    /// records why, and an `enforced` event of mode `gone` goes to the log. No contest and no re-check: the memory's text
    /// is not in doubt, only its check. git unavailable (no HEAD, or an unknown answer for the path): nothing changes.
    /// Every active record of the store is looked at, pinned and reviewed too: a dead check must not hide them for good.
    /// Cost: 1 `rev-parse` per pass with enforced memories, plus 1 per enforced memory.
    func enforcedGonePass(_ store: RepoMemory, facts: any GitFacts, now: Date, day: String) async {
        let enforced = ((try? await store.run { $0.store.all().records }) ?? []).filter { $0.status == .active && $0.enforcedBy != nil }
        guard !enforced.isEmpty, let head = await facts.head() else { return }
        for r in enforced {
            guard let by = r.enforcedBy, await facts.existed(at: head, by) == false, !facts.pathExists(by) else { continue }
            // re-read when written: a `memory enforce` that landed while git ran wins
            let cleared = try? await store.run { m -> Bool in
                guard var rec = m.store.all().records.first(where: { $0.id == r.id }), rec.enforcedBy == by else { return false }
                rec.enforcedBy = nil
                try m.store.write(rec)
                return true
            }
            guard cleared == true else { continue }
            let reason = String((MapDrift.enforcedGonePrefix + by).prefix(CuratorOps.lineMax))
            await memory.lifecycle.update(r.id, now: now) { e in
                e.flags.append(LifecycleFlag(verdict: .outdated, session: "claim-check", day: day, reason: reason))
            }
            var ev = MemoryEvent(type: .enforced, ids: [r.id], kinds: [r.kind.rawValue], scopes: [r.scope.rawValue],
                                 source: "lifecycle", reason: by, mode: "gone")
            ev.place(store: store.key)
            memory.events.emit(ev)
        }
    }

    /// This store's drift contested the map and that contest is over (a valid re-check, or the user kept it; an invalid
    /// one archived it). No clock compared: the verdict's time and the pass's are different clocks in tests and replays.
    static func settled(_ a: MapAnchor, _ e: LifecycleEntry) -> Bool { a.contestedAt != nil && !e.contestedNow }
}
