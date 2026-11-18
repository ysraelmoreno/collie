import Foundation
import CollieCore

enum BranchState: Sendable { case open, merged, missing }

protocol GitFacts: Sendable {
    func branch(_ name: String) async -> BranchState
    func commitExists(_ sha: String) async -> Bool
    func pathExists(_ rel: String) -> Bool
    // Map drift (spec 2026-11-17-memory-stage-rules, item 7); defaults in MapDrift.swift: nothing known, the check is off.
    func head() async -> String?
    func changes(from anchor: String, to head: String, paths: [String]) async -> MapDriftFacts
    func extent(_ rel: String) async -> PathExtent?
    func subjects(from anchor: String, to head: String, path: String) async -> [String]
}

/// Git and disk facts for a repo root. A git error, timeout or non-repo root is "unknown", never a failure.
struct GitFactsLive: GitFacts {
    var root: URL
    private static let timeout: Duration = .seconds(10)
    private let repo = RepoProbe()

    private final class RepoProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: Bool?
        func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return cached }
        func set(_ v: Bool) { lock.lock(); cached = v; lock.unlock() }
    }

    init(root: URL) { self.root = root }

    private func status(_ args: [String]) async -> Int32? {
        (try? await GitRunner.run(args, in: root, timeout: Self.timeout))?.status
    }

    /// The root is a git repo (checked once, cached); false also when unknown.
    private func inRepo() async -> Bool {
        if repo.get() == nil {   // only a definitive answer is cached: 0 = repo, 128 = not; a timeout/throw is retried next time
            switch await status(["rev-parse", "--git-dir"]) { case 0: repo.set(true); case 128: repo.set(false); default: break }
        }
        return repo.get() == true
    }

    /// Exit status of `args`, but only when the root is a git repo; nil = unknown.
    private func checked(_ args: [String]) async -> Int32? {
        await inRepo() ? await status(args) : nil
    }

    /// `args`' whole output (exit 0, not truncated by `GitRunner`'s 1 MiB cap), only in a git repo; nil = unknown.
    private func output(_ args: [String]) async -> ProcessResult? {
        guard await inRepo(), let r = try? await GitRunner.run(args, in: root, timeout: Self.timeout), r.status == 0, !r.truncated else { return nil }
        return r
    }

    /// true = ref exists (0), false = absent (1), nil = anything else.
    private func refExists(_ ref: String) async -> Bool? {
        switch await checked(["show-ref", "--verify", "--quiet", ref]) { case 0: true; case 1: false; default: nil }
    }

    func branch(_ name: String) async -> BranchState {
        var exists = false
        for ref in ["refs/heads/\(name)", "refs/remotes/origin/\(name)"] {
            guard let has = await refExists(ref) else { return .open }
            if has { exists = true; break }
        }
        guard exists else { return .missing }
        guard let hasMain = await refExists("refs/heads/main") else { return .open }
        switch await checked(["merge-base", "--is-ancestor", name, hasMain ? "main" : "master"]) {
        case 0: return .merged
        default: return .open   // 1 = not an ancestor; anything else = unknown
        }
    }

    func commitExists(_ sha: String) async -> Bool {
        // rev-parse --verify --quiet: 0 = exists, 1 = absent (cat-file -e exits 128 for an unknown name, same as a fatal error)
        guard await checked(["rev-parse", "--verify", "--quiet", "\(sha)^{commit}"]) == 1 else { return true }
        // exit 1 is also what an ambiguous abbreviation gives: any candidate object means "unknown", not absent
        guard sha.count < 40 else { return false }
        guard let r = try? await GitRunner.run(["rev-parse", "--disambiguate=\(sha)"], in: root, timeout: Self.timeout) else { return true }
        return r.status != 0 || !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func pathExists(_ rel: String) -> Bool { repoPathExists(rel, root: root) }
}

/// Map drift (item 7): commit against commit only, never the working tree (no clean/smudge filter runs), with
/// `MapDrift.safe` and no diff driver, textconv or signature check: the repo's config may be an agent's.
extension GitFactsLive {
    func head() async -> String? {
        guard let r = await output(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]) else { return nil }
        let h = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return MapDrift.isCommit(h) ? h : nil
    }

    func changes(from anchor: String, to head: String, paths: [String]) async -> MapDriftFacts {
        guard MapDrift.isCommit(anchor), MapDrift.isCommit(head), await inRepo() else { return .unknown }
        switch await checked(["rev-parse", "--verify", "--quiet", "\(anchor)^{commit}"]) {
        case 0: break
        case 1: return .anchorGone
        default: return .unknown
        }
        let ps = Array(Set(paths.compactMap(MapDrift.norm))).sorted()
        var out: [String: PathChange] = [:]
        for chunk in stride(from: 0, to: ps.count, by: MapDrift.maxPerPass).map({ Array(ps[$0..<min($0 + MapDrift.maxPerPass, ps.count)]) }) {
            guard let r = await output(MapDrift.safe + ["diff", "--numstat", "-z", "--no-ext-diff", "--no-textconv", "--no-renames",
                                                        "--no-color", anchor, head, "--"] + chunk) else { return .unknown }
            for rec in r.stdout.split(separator: "\0") {
                let f = rec.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard f.count == 3, let a = Int(f[0]), let d = Int(f[1]) else { continue }   // "-\t-": binary, ignored
                let file = String(f[2])
                for p in chunk where file == p || file.hasPrefix(p + "/") {
                    var c = out[p] ?? PathChange()
                    c.added += a; c.deleted += d; c.files += 1
                    out[p] = c
                }
            }
        }
        return .changes(out)
    }

    func extent(_ rel: String) async -> PathExtent? {
        guard let p = MapDrift.norm(rel) else { return nil }
        let u = root.appendingPathComponent(p)
        // never through a symlink, at the end or on the way (it could point anywhere)
        let base = root.resolvingSymlinksInPath().path
        guard u.resolvingSymlinksInPath().path.hasPrefix(base + "/") else { return nil }
        var st = stat()
        guard lstat(u.path, &st) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            let files = await output(MapDrift.safe + ["ls-files", "-z", "--", p]).map { $0.stdout.split(separator: "\0").count }
            return PathExtent(isDir: true, lines: nil, files: files)
        case S_IFREG:
            guard st.st_size <= MapDrift.maxReadBytes, let data = try? Data(contentsOf: u) else { return PathExtent(isDir: false, lines: nil, files: nil) }
            let n = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } + (data.last.map { $0 == 0x0A ? 0 : 1 } ?? 0)
            return PathExtent(isDir: false, lines: n, files: nil)
        default: return nil
        }
    }

    func subjects(from anchor: String, to head: String, path: String) async -> [String] {
        guard MapDrift.isCommit(anchor), MapDrift.isCommit(head), let p = MapDrift.norm(path),
              let r = await output(MapDrift.safe + ["log", "--no-show-signature", "--no-mailmap", "--format=%s", "-n", "\(MapDrift.subjectsMax)",
                                                    "\(anchor)..\(head)", "--", p]) else { return [] }
        return r.stdout.split(separator: "\n").map { CuratorOps.clean(String($0), cap: MapDrift.subjectMax, multiline: false) }.filter { !$0.isEmpty }
    }
}

struct ClaimFailure: Equatable, Sendable {
    /// `mapDrift`: never from `check` (a drift is soft); only a fact for the curator (`enqueueVerify`).
    enum Kind: String, Sendable { case pathMissing, branchMerged, branchMissing, commitMissing, mapDrift }
    var kind: Kind
    var detail: String
}

enum ClaimChecks {
    // ponytail: at most 8 branches and 8 SHAs per record, so a body full of hex can't stall the pass; raise if real memories need more
    static let maxPerKind = 8
    static let negations = ["não mergead", "não foi mergead", "pendente", "ainda não", "not merged", "pending"]

    /// `knownIds`: the store's record ids; a hex run that starts one (an `[a1b2c3d4]` short id) is not read as a SHA.
    static func check(_ r: MemoryRecord, facts: any GitFacts, knownIds: some Sequence<UUID> = [UUID]()) async -> [ClaimFailure] {
        var out: [ClaimFailure] = []
        func add(_ f: ClaimFailure) { if !out.contains(f) { out.append(f) } }
        if let p = r.path, !p.isEmpty, !facts.pathExists(p) { add(.init(kind: .pathMissing, detail: p)) }
        let body = r.body
        if negations.contains(where: { body.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
            for b in unique(branches(in: body)).prefix(maxPerKind) {
                switch await facts.branch(b) {
                case .merged: add(.init(kind: .branchMerged, detail: b))
                case .missing: add(.init(kind: .branchMissing, detail: b))
                case .open: break
                }
            }
        }
        let ids = knownIds.map { $0.uuidString.lowercased() }
        for s in unique(shas(in: body).filter { s in !ids.contains { $0.hasPrefix(s) } }).prefix(maxPerKind) where !(await facts.commitExists(s)) { add(.init(kind: .commitMissing, detail: s)) }
        return out
    }

    private static func unique(_ a: [String]) -> [String] { var seen = Set<String>(); return a.filter { seen.insert($0).inserted } }

    private static let branchRx = try! NSRegularExpression(pattern: #"(?<![\w=/-])(?:feat|fix|spike|docs|chore)/[A-Za-z0-9._/-]+"#)
    private static let shaRx = try! NSRegularExpression(pattern: #"\b[0-9a-f]{7,40}\b"#)

    static func branches(in s: String) -> [String] {
        let ns = s as NSString
        return branchRx.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).trimmingCharacters(in: CharacterSet(charactersIn: "./-"))
        }
    }

    /// 7-40 hex with a digit and a letter, not touching `-` (UUID fragments).
    static func shas(in s: String) -> [String] {
        let ns = s as NSString
        return shaRx.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let t = ns.substring(with: m.range)
            guard t.contains(where: \.isNumber), t.contains(where: \.isLetter) else { return nil }
            if m.range.location > 0, ns.character(at: m.range.location - 1) == 0x2D { return nil }
            let end = m.range.location + m.range.length
            if end < ns.length, ns.character(at: end) == 0x2D { return nil }
            return t
        }
    }
}
