import Foundation

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
