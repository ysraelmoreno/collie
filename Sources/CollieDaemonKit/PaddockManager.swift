import Foundation
import CollieCore
import CollieProtocol

struct LandResult: Codable, Sendable {
    var mode: LandMode
    var commit: String?
    var prURL: String?
}

/// Worktree-based paddocks over a git repo (the "pasture"). No workspace state.
enum PaddockManager {
    static func validate(name: String) throws(ProtocolError) {
        guard name.range(of: "^[a-z0-9][a-z0-9-]{0,39}$", options: .regularExpression) != nil else {
            throw ProtocolError(code: .invalidArgs, message: "invalid paddock name '\(name)' (use a-z, 0-9, '-', max 40)")
        }
    }

    private static func fail(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }

    /// Runs git and throws invalidArgs with stderr on a non-zero exit.
    @discardableResult
    private static func git(_ args: [String], in dir: URL) async throws(ProtocolError) -> String {
        let r = try await GitRunner.run(args, in: dir)
        if r.truncated { throw fail("git \(args.first ?? "") output too large") }
        guard r.status == 0 else {
            let msg = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw fail("git \(args.first ?? "") failed: \(msg)")
        }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func commonDir(_ dir: URL) async throws(ProtocolError) -> URL {
        URL(fileURLWithPath: try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: dir))
    }

    static func repoRoot(of dir: URL) async throws(ProtocolError) -> URL {
        let common = try await commonDir(dir)
        if common.lastPathComponent == ".git" { return common.deletingLastPathComponent() }
        return URL(fileURLWithPath: try await git(["rev-parse", "--show-toplevel"], in: dir))   // bare/odd layouts
    }

    private static func currentBranch(_ dir: URL) async throws(ProtocolError) -> String {
        let r = try await GitRunner.run(["symbolic-ref", "--short", "-q", "HEAD"], in: dir)
        let b = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0, !b.isEmpty else { throw fail("HEAD is detached in \(dir.path)") }
        return b
    }

    static func create(name: String, repoRoot: URL, createdBy: UUID?) async throws(ProtocolError) -> Paddock {
        try validate(name: name)
        let base = try await currentBranch(repoRoot)
        let dir = LegacyOrq.repoDirName(repoRoot: repoRoot)
        let path = repoRoot.appendingPathComponent("\(dir)/paddocks/\(name)")
        let branch = "collie/\(name)"
        if FileManager.default.fileExists(atPath: path.path) { throw fail("paddock '\(name)' already exists") }
        let ref = try await GitRunner.run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repoRoot)
        if ref.status == 0 { throw fail("branch \(branch) already exists") }
        try GitRunner.exclude("\(dir)/paddocks/", commonDir: try await commonDir(repoRoot))
        try await git(["worktree", "add", "-b", branch, path.path, base], in: repoRoot)
        return Paddock(id: UUID(), name: name, repoRoot: repoRoot.path, path: path.path, branch: branch,
                     baseBranch: base, createdBy: createdBy)
    }

    static func land(_ f: inout Paddock, mode: LandMode, message: String?) async throws(ProtocolError) -> LandResult {
        let fl = f
        let pasture = URL(fileURLWithPath: fl.repoRoot), paddock = URL(fileURLWithPath: fl.path)
        let msg = message ?? "Land paddock \(fl.name)"
        try await commitMemory(in: paddock, pasture: pasture)
        if !(try await git(["status", "--porcelain"], in: paddock)).isEmpty { throw fail("paddock has uncommitted changes") }
        // the pasture's own memory files never block a land (they're never auto-committed; a clashing merge refuses itself)
        if !(try await git(["status", "--porcelain", "--", "."] + LegacyOrq.memoryExcludes, in: pasture)).isEmpty {
            throw fail("pasture has uncommitted changes")
        }
        let cur = try await currentBranch(pasture)
        guard cur == fl.baseBranch else { throw fail("pasture is on '\(cur)', expected base branch '\(fl.baseBranch)'") }

        /// On failure: list conflicted files, abort, throw.
        func run(_ args: [String], in dir: URL, abort: [String]) async throws(ProtocolError) {
            let r = try await GitRunner.run(args, in: dir)
            if r.status == 0 { return }
            let d = try await GitRunner.run(["diff", "--name-only", "--diff-filter=U"], in: dir)
            let files = d.stdout.split(separator: "\n").map(String.init)
            _ = try? await GitRunner.run(abort, in: dir)
            if files.isEmpty { throw fail("git \(args.first ?? "") failed: \((r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines))") }
            throw fail("land conflicts: \(files.joined(separator: ", "))" + (d.truncated ? " (truncated)" : ""))
        }

        switch mode {
        case .merge:
            try await run(["merge", "--no-ff", "--no-edit", "-m", msg, fl.branch], in: pasture, abort: ["merge", "--abort"])
        case .squash:
            // a squash leaves no MERGE_HEAD; reset restores the clean pasture
            try await run(["merge", "--squash", fl.branch], in: pasture, abort: ["reset", "--hard", "HEAD"])
            try await run(["commit", "-m", msg], in: pasture, abort: ["reset", "--hard", "HEAD"])
        case .rebase:
            try await run(["rebase", fl.baseBranch], in: paddock, abort: ["rebase", "--abort"])
            try await run(["merge", "--ff-only", fl.branch], in: pasture, abort: ["merge", "--abort"])
        case .pr:
            let remotes = try await GitRunner.run(["remote", "get-url", "origin"], in: pasture)
            if remotes.status != 0 { throw fail("no git remote 'origin' configured") }
            let gh = URL(fileURLWithPath: "/usr/bin/env")
            let probe = try await GitRunner.run(["gh", "--version"], in: pasture, executable: gh)
            if probe.status != 0 { throw fail("gh CLI not available") }
            try await git(["push", "-u", "origin", fl.branch], in: pasture)
            let pr = try await GitRunner.run(["gh", "pr", "create", "--base", fl.baseBranch, "--head", fl.branch, "--fill"],
                                             in: pasture, executable: gh)
            guard pr.status == 0 else { throw fail("gh pr create failed: \(pr.stderr.trimmingCharacters(in: .whitespacesAndNewlines))") }
            let url = pr.stdout.split(separator: "\n").last.map(String.init)
            let commit = try await git(["rev-parse", fl.branch], in: pasture)
            f.status = .done; f.landedAt = Date()
            return LandResult(mode: mode, commit: commit, prURL: url)
        }
        let commit = try await git(["rev-parse", "HEAD"], in: pasture)
        f.status = .done; f.landedAt = Date()
        return LandResult(mode: mode, commit: commit, prURL: nil)
    }

    /// The paddock's memory travels with its land: commits `.collie/memory` (or a legacy `.orq/memory`; only it) when it has changes.
    private static func commitMemory(in paddock: URL, pasture: URL) async throws(ProtocolError) {
        let mem = LegacyOrq.repoDirName(repoRoot: pasture) + "/memory"
        if (try await git(["status", "--porcelain", "--", mem], in: paddock)).isEmpty { return }
        try await git(["add", "--", mem], in: paddock)
        func configured(_ key: String) async throws(ProtocolError) -> Bool {
            let r = try await GitRunner.run(["config", key], in: paddock)
            return r.status == 0 && !r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasName = try await configured("user.name"), hasEmail = try await configured("user.email")
        let identity = hasName && hasEmail ? [] : ["-c", "user.name=Collie", "-c", "user.email=collie@localhost"]
        // the pathspec keeps anything else the user staged out of this commit
        try await git(identity + ["commit", "-m", "collie: memory", "--", mem], in: paddock)
    }

    static func delete(_ f: Paddock, force: Bool) async throws(ProtocolError) {
        let pasture = URL(fileURLWithPath: f.repoRoot)
        let exists = FileManager.default.fileExists(atPath: f.path)
        // a branch deleted by hand: nothing to check or delete (else the paddock could never be deleted)
        let hasBranch = try await GitRunner.run(["show-ref", "--verify", "--quiet", "refs/heads/\(f.branch)"], in: pasture).status == 0
        if hasBranch && !force && f.landedAt == nil {
            let m = try await GitRunner.run(["merge-base", "--is-ancestor", f.branch, f.baseBranch], in: pasture)
            if m.status != 0 { throw fail("paddock branch \(f.branch) is not merged into \(f.baseBranch)") }
        }
        if exists { try await git(["worktree", "remove"] + (force ? ["--force"] : []) + [f.path], in: pasture) }
        else { try await git(["worktree", "prune"], in: pasture) }   // drop stale metadata of a manually removed dir
        if hasBranch { try await git(["branch", force || f.landedAt != nil ? "-D" : "-d", f.branch], in: pasture) }
    }
}
