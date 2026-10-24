import Foundation
import CollieCore

/// A path the user opened to one terminal (or its lot) by an explicit click (Task 4 stores and offers them).
public struct SandboxGrant: Codable, Sendable, Equatable {
    public enum Access: String, Codable, Sendable { case read, write }
    public enum Scope: String, Codable, Sendable { case terminal, lot }
    public var path: String
    public var access: Access
    public var scope: Scope
    public var createdAt: Date
    public init(path: String, access: Access, scope: Scope, createdAt: Date = Date()) {
        self.path = path; self.access = access; self.scope = scope; self.createdAt = createdAt
    }
}

/// Everything one terminal's profile depends on. Paths may be unresolved: `render` resolves each one (Seatbelt
/// matches the vnode path, `/private/tmp`, never `/tmp`).
struct SandboxInput {
    var terminal: UUID
    var project: URL
    /// The git common dir (a plain repo's `.git`, a worktree's main `.git`); nil: not a git project.
    var mainGitDir: URL?
    /// A worktree's own git dir (`<main .git>/worktrees/<name>`); nil for a plain repo.
    var worktreeGitDir: URL? = nil
    /// Never writable (a pasture terminal: the paddock worktrees nested in its project).
    var paddockWorktrees: [URL] = []
    var home: URL
    var collieRoot: URL
    /// Collie's generated files for this terminal (settings/hooks/MCP config): readable inside the closed Collie dir.
    var ownFiles: [URL] = []
    /// `<collieRoot>/sandbox/<id>`: readable (shims, zsh startup); only its `state/` is writable.
    var terminalDir: URL
    var socket: URL
    var agent: Preset
    /// The custom command (a `cursor-agent` one gets `~/.cursor`, R19).
    var command: String? = nil
    var grants: [SandboxGrant] = []
    var userTemp = SandboxInput.darwinDir(_CS_DARWIN_USER_TEMP_DIR)
    var userCache = SandboxInput.darwinDir(_CS_DARWIN_USER_CACHE_DIR)

    static func darwinDir(_ name: Int32) -> URL {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(name, &buf, buf.count)
        return URL(fileURLWithPath: n > 0 ? String(cString: buf) : NSTemporaryDirectory())
    }

    /// The git dirs of `project`: `.git` a directory → (it, nil); a `.git` file (`gitdir: X`) of a worktree → (X's
    /// `commondir`, X); of a submodule → (X, nil). Read from files the profile keeps unwritable. A common dir whose
    /// name isn't `*.git` or under `.git/modules/` (a hand-made pointer at `~`) counts as no git.
    static func gitDirs(of project: URL) -> (common: URL?, worktree: URL?) {
        let dotgit = URL(fileURLWithPath: SignedAppCheck.realPath(project)).appendingPathComponent(".git")
        func real(_ u: URL) -> URL { URL(fileURLWithPath: SignedAppCheck.realPath(u)) }
        func plausible(_ c: URL) -> Bool { c.lastPathComponent.hasSuffix(".git") || c.path.contains(".git/modules/") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotgit.path, isDirectory: &isDir) else { return (nil, nil) }
        if isDir.boolValue { return (real(dotgit), nil) }
        guard let text = try? String(contentsOf: dotgit, encoding: .utf8), text.hasPrefix("gitdir:") else { return (nil, nil) }
        let raw = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let gitdir = real(URL(fileURLWithPath: raw, relativeTo: project).absoluteURL)
        if let c = try? String(contentsOf: gitdir.appendingPathComponent("commondir"), encoding: .utf8) {
            let common = real(URL(fileURLWithPath: c.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitdir.appendingPathComponent("x")).absoluteURL)
            guard plausible(common), gitdir.deletingLastPathComponent().path == common.appendingPathComponent("worktrees").path else { return (nil, nil) }
            return (common, gitdir)
        }
        return plausible(gitdir) ? (gitdir, nil) : (nil, nil)
    }
}

/// The per-terminal Seatbelt profile: `(allow default)`, then deny rules and allow-backs where the last matching rule
/// wins (Task 1's shape). Every path is resolved and inlined as an escaped SBPL string; the ones inside regexes are
/// regex-escaped too. Every deny that should raise a card carries `(with message "collie-term:<id>")` (Task 4).
enum SandboxProfile {
    static let tagPrefix = "collie-term:"

    static func render(_ i: SandboxInput) -> String {
        func real(_ u: URL) -> String { SignedAppCheck.realPath(u) }
        let home = real(i.home), project = real(i.project), collie = real(i.collieRoot), tdir = real(i.terminalDir)
        let common = i.mainGitDir.map(real), worktree = i.worktreeGitDir.map(real)
        let tag = "(with message \(q(tagPrefix + i.terminal.uuidString)))"
        func sub(_ p: String) -> String { "(subpath \(q(p)))" }
        func lit(_ p: String) -> String { "(literal \(q(p)))" }
        func rx(_ p: String) -> String { "(regex \(q(p)))" }
        /// An `EssentialPaths` entry under `base`: `x*` → any name starting with x (and below); `x/` → below x only
        /// (never x itself); else the subpath.
        func entry(_ base: String, _ e: String) -> String {
            if e.hasSuffix("*") { return rx("^" + re(base + "/" + e.dropLast()) + "[^/]*(/|$)") }
            if e.hasSuffix("/") { return rx("^" + re(base + "/" + e) + ".+") }
            return sub(base + "/" + e)
        }
        var out = ["(version 1)", "(allow default)"]
        func rule(_ verb: String, _ op: String, tagged: Bool = false, _ filters: [String]) {
            guard !filters.isEmpty else { return }
            out.append("(\(verb) \(op)\(tagged ? " " + tag : "")\n  " + filters.joined(separator: "\n  ") + ")")
        }
        let grants = i.grants.map { (path: real(URL(fileURLWithPath: $0.path)), access: $0.access) }

        out.append(";; reads: the home is closed; tool essentials, the project and its git re-opened")
        rule("deny", "file-read*", tagged: true, [sub(home)])
        rule("deny", "file-read* (with no-log)", [lit(home), lit(home + "/Library")])   // benign listings: no card
        rule("allow", "file-read-metadata", [sub(home)])   // stat/realpath of ancestors; contents and listings stay closed
        rule("allow", "file-read*", [sub(project)] + [common, worktree].compactMap { $0.map(sub) }
             + EssentialPaths.homeReads.map { entry(home, $0) })
        rule("allow", "file-read*", grants.map { sub($0.path) })
        // secrets stay closed whatever was re-opened or granted; ssh keeps what `git`/`ssh` need without the keys
        rule("deny", "file-read*", tagged: true, EssentialPaths.secrets.map { entry(home, $0) })
        rule("allow", "file-read*", [lit(home + "/.ssh"), lit(home + "/.ssh/known_hosts"), lit(home + "/.ssh/config"),
                                     rx("^" + re(home + "/.ssh/") + "[^/]+\\.pub$")])

        out.append(";; writes: temp and devices; the home (and the git dirs) closed again; then the project and caches")
        out.append("(deny file-write* \(tag))")
        rule("allow", "file-write*", [sub("/private/tmp"), sub(real(i.userTemp))]
             + EssentialPaths.userCacheWrites.map { entry(real(i.userCache), $0) }
             + ["/dev/null", "/dev/zero", "/dev/dtracehelper", "/dev/tty", "/dev/ptmx"].map(lit) + [rx("^/dev/ttys[0-9]+$"), rx("^/dev/fd/")])
        rule("deny", "file-write*", tagged: true, [sub(home)] + [common].compactMap { $0.map(sub) })
        var writes = [sub(project)] + EssentialPaths.homeWrites.map { entry(home, $0) }
        if let common {
            if let worktree {   // a worktree commits through the common dir; its own git dir is its index/HEAD
                writes += ["objects", "refs", "logs"].map { sub(common + "/" + $0) }
                    + [lit(common + "/packed-refs"), lit(common + "/packed-refs.lock"), sub(worktree)]
            } else {
                writes.append(sub(common))
            }
        }
        rule("allow", "file-write*", writes)
        // a pasture never writes its paddocks: their worktrees, nor any worktree's git dir in the common dir
        var closed = i.paddockWorktrees.map { sub(real($0)) }
        if let common, worktree == nil { closed.append(sub(common + "/worktrees")) }
        rule("deny", "file-write*", tagged: true, closed)
        rule("allow", "file-write*", grants.filter { $0.access == .write }.map { sub($0.path) })
        // what the user's own unsandboxed git executes from, and the pointers that pick it (renaming .git, rewriting a
        // worktree's .git file or commondir/gitdir would swap in a planted config): never writable, grants included.
        // R17: no nested `.git` (dir, file or link) anywhere in the project either: the user's git or IDE runs its config.
        // ponytail: agents can't clone/init/submodule-add inside the project (clone into TMP instead)
        rule("deny", "file-write*", tagged: true, [rx("^" + re(project) + "/.+/\\.git(/|$)")])
        if let common {
            let c = re(common)
            rule("deny", "file-write*", tagged: true, [
                lit(common), lit(project + "/.git"), sub(common + "/hooks"), lit(common + "/config"),
                lit(common + "/config.worktree"), lit(common + "/info/attributes"), lit(common + "/commondir"),
                rx("^" + c + "/worktrees/[^/]+/(commondir|gitdir|config\\.worktree)$"),
                rx("^" + c + "/modules/.+/(hooks(/|$)|config$|config\\.worktree$|commondir$|info/attributes$)"),
            ])
        } else {
            rule("deny", "file-write*", tagged: true, [lit(project + "/.git")])   // no planting a pointer in a non-git project
        }

        out.append(";; Collie: closed (data, tokens, grants, workspace.json); this terminal's files readable; only the socket")
        rule("deny", "file-read* file-write*", tagged: true, [sub(collie)])
        rule("allow", "file-read*", i.ownFiles.map { lit(real($0)) } + [sub(tdir)])
        rule("allow", "file-write*", [sub(tdir + "/state")])
        rule("deny", "network-outbound", tagged: true, ["(remote unix-socket \(sub(collie)))"])
        rule("allow", "network-outbound", ["(remote unix-socket (path-literal \(q(real(i.socket)))))"])

        // R14: by path only (a copy of the binary runs): defence in depth, not a boundary. R12: `security` stays (Keychain logins)
        out.append(";; processes: no launchd, no LaunchServices `open` (the shim asks the daemon); no signals out")
        rule("deny", "process-exec", tagged: true, [lit("/bin/launchctl"), lit("/usr/bin/open")])
        out.append("(allow process-exec (literal \"/bin/ps\") (with no-sandbox))   ; setuid: a sandboxed exec of it fails otherwise")
        out.append("(deny signal \(tag))")
        out.append("(allow signal (target same-sandbox))")
        return out.joined(separator: "\n") + "\n"
    }

    /// An SBPL string literal.
    static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    /// `s` matched literally inside a regex.
    static func re<S: StringProtocol>(_ s: S) -> String {
        var o = ""
        for c in s { if "\\^$.|?*+()[]{}".contains(c) { o.append("\\") }; o.append(c) }
        return o
    }
}
