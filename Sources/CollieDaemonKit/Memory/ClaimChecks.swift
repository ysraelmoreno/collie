import Foundation
import CollieCore

enum BranchState: Sendable { case open, merged, missing }

protocol GitFacts: Sendable {
    func branch(_ name: String) async -> BranchState
    func commitExists(_ sha: String) async -> Bool
    func pathExists(_ rel: String) -> Bool
}

/// Git and disk facts for a repo root. A git error or timeout is "unknown", never a failure.
struct GitFactsLive: GitFacts {
    var root: URL
    private static let timeout: Duration = .seconds(10)

    private func ok(_ args: [String]) async -> Bool? {
        guard let r = try? await GitRunner.run(args, in: root, timeout: Self.timeout) else { return nil }
        return r.status == 0
    }

    func branch(_ name: String) async -> BranchState {
        var exists = false
        for ref in ["refs/heads/\(name)", "refs/remotes/origin/\(name)"] {
            guard let has = await ok(["show-ref", "--verify", "--quiet", ref]) else { return .open }
            if has { exists = true; break }
        }
        guard exists else { return .missing }
        var base = "main"
        if await ok(["show-ref", "--verify", "--quiet", "refs/heads/main"]) != true { base = "master" }
        return await ok(["merge-base", "--is-ancestor", name, base]) == true ? .merged : .open
    }

    func commitExists(_ sha: String) async -> Bool { await ok(["cat-file", "-e", "\(sha)^{commit}"]) ?? true }
    func pathExists(_ rel: String) -> Bool { repoPathExists(rel, root: root) }
}

struct ClaimFailure: Equatable, Sendable {
    enum Kind: String, Sendable { case pathMissing, branchMerged, branchMissing, commitMissing }
    var kind: Kind
    var detail: String
}

enum ClaimChecks {
    static let negations = ["não mergead", "não foi mergead", "pendente", "ainda não", "not merged", "pending"]

    static func check(_ r: MemoryRecord, facts: any GitFacts) async -> [ClaimFailure] {
        var out: [ClaimFailure] = []
        func add(_ f: ClaimFailure) { if !out.contains(f) { out.append(f) } }
        if let p = r.path, !p.isEmpty, !facts.pathExists(p) { add(.init(kind: .pathMissing, detail: p)) }
        let body = r.body
        if negations.contains(where: { body.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
            for b in branches(in: body) {
                switch await facts.branch(b) {
                case .merged: add(.init(kind: .branchMerged, detail: b))
                case .missing: add(.init(kind: .branchMissing, detail: b))
                case .open: break
                }
            }
        }
        for s in shas(in: body) where !(await facts.commitExists(s)) { add(.init(kind: .commitMissing, detail: s)) }
        return out
    }

    private static let branchRx = try! NSRegularExpression(pattern: #"\b(?:feat|fix|spike|docs|chore)/[A-Za-z0-9._/-]+"#)
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
