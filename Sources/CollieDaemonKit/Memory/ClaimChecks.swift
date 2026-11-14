import Foundation
import CollieCore

enum BranchState: Sendable { case open, merged, missing }

protocol GitFacts: Sendable {
    func branch(_ name: String) async -> BranchState
    func commitExists(_ sha: String) async -> Bool
    func pathExists(_ rel: String) -> Bool
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

    /// Exit status of `args`, but only when the root is a git repo (checked once, cached); nil = unknown.
    private func checked(_ args: [String]) async -> Int32? {
        if repo.get() == nil {   // only a definitive answer is cached: 0 = repo, 128 = not; a timeout/throw is retried next time
            switch await status(["rev-parse", "--git-dir"]) { case 0: repo.set(true); case 128: repo.set(false); default: break }
        }
        return repo.get() == true ? await status(args) : nil
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
        guard sha.count < 40, let r = try? await GitRunner.run(["rev-parse", "--disambiguate=\(sha)"], in: root, timeout: Self.timeout)
        else { return false }
        return r.status != 0 || !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func pathExists(_ rel: String) -> Bool { repoPathExists(rel, root: root) }
}

struct ClaimFailure: Equatable, Sendable {
    enum Kind: String, Sendable { case pathMissing, branchMerged, branchMissing, commitMissing }
    var kind: Kind
    var detail: String
}

enum ClaimChecks {
    // ponytail: at most 8 branches and 8 SHAs per record, so a body full of hex can't stall the pass; raise if real memories need more
    static let maxPerKind = 8
    static let negations = ["não mergead", "não foi mergead", "pendente", "ainda não", "not merged", "pending"]

    static func check(_ r: MemoryRecord, facts: any GitFacts) async -> [ClaimFailure] {
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
        for s in unique(shas(in: body)).prefix(maxPerKind) where !(await facts.commitExists(s)) { add(.init(kind: .commitMissing, detail: s)) }
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
