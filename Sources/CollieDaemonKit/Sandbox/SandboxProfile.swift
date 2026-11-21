import Foundation
import CollieCore

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
    /// A lane's profile (M3.3; `project` is the lane): the worktree of its paddock. That worktree and every other lane
    /// (the project's `lane-*` siblings, the ones made later too) are closed for reading and writing, whatever the
    /// mode or a grant says. nil: not a lane.
    var lanePaddock: URL? = nil
    var home: URL
    var collieRoot: URL
    /// Collie's generated files for this terminal (settings/hooks/MCP config, Cursor's plugin dir): readable, with what
    /// is under them, inside the closed Collie dir.
    var ownFiles: [URL] = []
    /// `<collieRoot>/sandbox/<id>`: readable (shims, zsh startup); only its `state/` is writable.
    var terminalDir: URL
    var socket: URL
    var agent: Preset
    /// The custom command (a `cursor-agent` one gets `~/.cursor`, R19).
    var command: String? = nil
    var grants: [SandboxGrant] = []
    /// The Collie.app bundle (`collied`, `collie`, `collie-ctty`, which launchd runs outside any sandbox): never writable (I3).
    var appBundle: URL? = nil
    /// `open`: Collie's internals closed, nothing else (the router passes the workspace's mode; strict here keeps the
    /// curator's and the strict suites' profile).
    var mode: SandboxMode = .strict
    var userTemp = SandboxInput.darwinDir(_CS_DARWIN_USER_TEMP_DIR)
    var userCache = SandboxInput.darwinDir(_CS_DARWIN_USER_CACHE_DIR)

    static func darwinDir(_ name: Int32) -> URL {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(name, &buf, buf.count)
        return URL(fileURLWithPath: n > 0 ? String(cString: buf) : NSTemporaryDirectory())
    }

    /// The `.app` bundle holding `executable` (resolved); nil outside one (a dev build).
    /// ponytail: a dev build's binaries aren't closed (they're a build output in the user's checkout)
    static func appBundle(of executable: URL) -> URL? {
        var u = URL(fileURLWithPath: SignedAppCheck.realPath(executable))
        while u.pathComponents.count > 1 {
            if u.pathExtension == "app" { return u }
            u = u.deletingLastPathComponent()
        }
        return nil
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

/// The per-terminal Seatbelt profile (strict mode; open mode keeps only Collie's internals closed): `(allow default)`, then deny rules and allow-backs where the last matching rule
/// wins (Task 1's shape). Reads open but for a closed list; writes closed but for the project, caches and grants.
/// Every path is resolved and inlined as an escaped SBPL string; the ones inside regexes are regex-escaped too. Every deny that should raise a card carries `(with message "collie-term:<id>")` (Task 4).
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
        /// R-H1 (2Q review): a closed entry and, when it is a symlink (dotfiles, stow), its resolved target too: Seatbelt
        /// matches the resolved path, so the target would stay open. ponytail: resolved at render (a link made later
        /// takes effect at the terminal's next start)
        func closing(_ es: [String]) -> [String] {
            es.map { entry(home, $0) } + es.filter { !$0.hasSuffix("*") && !$0.hasSuffix("/") }.compactMap { e in
                let r = real(URL(fileURLWithPath: home + "/" + e))
                return r == home + "/" + e ? nil : sub(r)
            }
        }
        var out = ["(version 1)", "(allow default)"]
        func rule(_ verb: String, _ op: String, tagged: Bool = false, _ filters: [String]) {
            guard !filters.isEmpty else { return }
            out.append("(\(verb) \(op)\(tagged ? " " + tag : "")\n  " + filters.joined(separator: "\n  ") + ")")
        }
        func under(_ p: String, _ root: String) -> Bool { URL(fileURLWithPath: p).pathComponents.starts(with: URL(fileURLWithPath: root).pathComponents) }
        // the updater's sibling next to the app (`.Collie-update-XXXXXX`, spec 2026-11-17 §2): a verified bundle waits
        // there for its swap into the app's name; no terminal plants or edits one, in either mode
        let updateSibling = i.appBundle.map { rx("^" + re(real($0.deletingLastPathComponent())) + "/\\.Collie-update-") }
        // M3.3: a lane is strict whatever the workspace's mode. Its paddock's worktree, and any `lane-*` sibling of the
        // project (a regex: a lane made after this profile too; the same shape as an `EssentialPaths` `x*` entry).
        let strict = i.mode == .strict || i.lanePaddock != nil
        let laneClosed = i.lanePaddock.map {
            [sub(real($0)), rx("^" + re(URL(fileURLWithPath: project).deletingLastPathComponent().path + "/" + LaneWorktree.dirPrefix) + "[^/]*(/|$)")]
        } ?? []
        if !strict {
            // user decision (2026-10-25): everything in the account is open but Collie's internals: its data (below), the
            // app bundle and its LaunchAgents (writes), and their parents (renaming one away, writing inside and renaming
            // back would get past the leaves), every ancestor. Signals out and the socket rule stay (below)
            out.append(";; open mode: only Collie's internals closed")
            let app = i.appBundle.map(real), agents = home + "/Library/LaunchAgents"
            rule("deny", "file-write*", tagged: true, [app].compactMap { $0.map(sub) } + [rx("^" + re(agents + "/dev.collie.") + ".*")]
                 + [updateSibling].compactMap { $0 })
            var parents: Set<String> = [agents]
            for p in [collie, agents] + [app].compactMap({ $0 }) {
                var u = URL(fileURLWithPath: p).deletingLastPathComponent()
                while u.pathComponents.count > 1 { parents.insert(u.path); u = u.deletingLastPathComponent() }
            }
            rule("deny", "file-write*", tagged: true, parents.sorted().map(lit))
            // launchctl could boot out Collie's own daemon; `open x.command` runs a script in Terminal.app, outside any
            // sandbox (R3; the `open` shim asks the daemon). By path only: a copy still runs, as in strict mode
            rule("deny", "process-exec", tagged: true, [lit("/bin/launchctl"), lit("/usr/bin/open")])
        } else {
            // R26: a grant is rendered exactly as stored (the resolved path the card showed), never resolved again: a symlink
            // swapped in later opens nothing (Seatbelt matches the resolved path)
            let grants = i.grants.map { (path: $0.path, access: $0.access) }

            if !laneClosed.isEmpty {
                // first of the read rules: every later read deny still holds inside the lane. Untagged: no card asks
                // the owner to open what is never opened.
                out.append(";; lane: its paddock's worktree and the other lanes closed (read and write); the lane itself open")
                rule("deny", "file-read*", laneClosed)
                rule("allow", "file-read*", [sub(project)])
            }

            // 2Q (user decision): reads are open, except what `readClosed` lists (secrets, browser profiles, mail, messages,
            // containers) and Collie's data (below). No read grant is rendered (a stored one is moot): nothing re-opens them.
            // ssh keeps what `git`/`ssh` need without the keys
            out.append(";; reads: open; secrets, browser profiles, mail/messages/containers closed")
            rule("deny", "file-read*", tagged: true, closing(EssentialPaths.readClosed))
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
                if let worktree, i.lanePaddock != nil {
                    // M3b.3: a lane moves its own branch and nothing else of the repository's refs (not its paddock's
                    // branch, not `main`, no reflog but its own, no `packed-refs`): the integrator is the only way in.
                    // The branch is named from the lane's folder (`lane-<name>` → `collie/lane/<name>`, as
                    // `LaneWorktree.create` makes them), never from a file the lane writes (its HEAD). Literals: no
                    // name becomes a pattern. HEAD's reflog and the index are in its own git dir; `<common>/logs/HEAD`
                    // is the main checkout's, and stays closed.
                    // ponytail: the folders `refs/heads/collie/lane` and its `logs` twin are not opened (a literal
                    // on a folder would let it be renamed away, the other lanes' branches with it). If a gc of the
                    // owner packs every lane's ref and prunes the folder mid-lane, the lane's commit fails and the
                    // attempt is retried in a new lane; open `file-write-create` on them if that is ever seen.
                    writes += [sub(common + "/objects"), sub(worktree)]
                    let folder = URL(fileURLWithPath: project).lastPathComponent
                    if folder.hasPrefix(LaneWorktree.dirPrefix), folder.count > LaneWorktree.dirPrefix.count {
                        let ref = "/refs/heads/" + LaneWorktree.branchPrefix + folder.dropFirst(LaneWorktree.dirPrefix.count)
                        writes += [lit(common + ref), lit(common + ref + ".lock"), lit(common + "/logs" + ref)]
                    }
                } else if let worktree {   // a worktree commits through the common dir; its own git dir is its index/HEAD
                    writes += ["objects", "refs", "logs"].map { sub(common + "/" + $0) }
                        + [lit(common + "/packed-refs"), lit(common + "/packed-refs.lock"), sub(worktree)]
                } else {
                    writes.append(sub(common))
                }
            }
            // write grants, before the project's own allows (which re-open the project's git dir and the tools' caches):
            // R27: a write grant never covers a git dir beneath it (`.git` or `*.git`: hooks, config, modules, worktrees, bare)
            let writeGrants = grants.filter { $0.access == .write }.map(\.path)
            rule("allow", "file-write*", writeGrants.map(sub))
            // except a grant under TMP outside the home: TMP is writable anyway, and clones go there (R17)
            let temps = ["/private/tmp", real(i.userTemp)]
            func gitDeny(_ gs: [String]) {
                rule("deny", "file-write*", tagged: true, gs.filter { g in under(g, home) || !temps.contains { under(g, $0) } }
                     .map { rx("^" + re($0) + "/(.+/)?[^/]*\\.git(/|$)") })
            }
            gitDeny(writeGrants)
            rule("allow", "file-write*", writes)
            // R34: global agent config closed after the project (the home as project too), then the agents' own state, then
            // re-opened by a write grant on (or above) it: the user's click (user decision)
            let agentConfig = EssentialPaths.agentConfig.map { home + "/" + $0 }
            rule("deny", "file-write*", tagged: true, agentConfig.map(sub))
            rule("allow", "file-write*", EssentialPaths.agentStateWrites.map { entry(home, $0) })
            let reopened = writeGrants.filter { g in agentConfig.contains { under(g, $0) || under($0, g) } }
            rule("allow", "file-write*", reopened.map(sub))
            gitDeny(reopened)
            // M3.3 lane: after every allow that could reach them (temp, caches, grants); the project is opened again
            // before the denies below (its nested paddocks folder, nested `.git`, the git pointers), which still hold
            if !laneClosed.isEmpty {
                rule("deny", "file-write*", laneClosed)
                rule("allow", "file-write*", [sub(project)])
            }
            // a pasture never writes its paddocks: their worktrees, nor any worktree's git dir in the common dir
            var closed = i.paddockWorktrees.map { sub(real($0)) }
            if let common, worktree == nil { closed.append(sub(common + "/worktrees")) }
            rule("deny", "file-write*", tagged: true, closed)
            // R17: no nested `.git` (dir, file or link) anywhere in the project either: the user's git or IDE runs its config.
            // ponytail: agents can't clone/init/submodule-add inside the project (clone into TMP instead)
            rule("deny", "file-write*", tagged: true, [rx("^" + re(project) + "/.+/\\.git(/|$)")])
            // R20: except the tools' own checkouts at the project root (SwiftPM `.build/`, Carthage), normally git-ignored.
            // Accepted: an IDE that scans nested repos there could run a planted config
            rule("allow", "file-write*", [rx("^" + re(project) + "/(\\.build|Carthage/Checkouts)/.+")])
            // R32: what no project root (the home itself included) and no grant re-opens: config run outside, preferences,
            // launchd agents, ~/Applications, the app bundle (I3). R23: secrets. (N2: after the `.build/` re-allow above)
            rule("deny", "file-write*", tagged: true, EssentialPaths.neverWritable.map { entry(home, $0) } + [i.appBundle].compactMap { $0.map { sub(real($0)) } }
                 + [updateSibling].compactMap { $0 })
            rule("deny", "file-write*", tagged: true, closing(EssentialPaths.readClosed))   // M1: what is never read, never moved away
            // R35: their parents themselves (never their other children): renaming `~/Library` or `~/.config` away, writing
            // inside and renaming back would get past the denies on the leaves. From the home down, computed from the lists
            let protected = (EssentialPaths.neverWritable + EssentialPaths.agentConfig + EssentialPaths.readClosed)
                .map { home + "/" + ($0.hasSuffix("*") ? String($0.dropLast()) : $0) } + [collie]
            var parents: Set<String> = [home]
            for p in protected where under(p, home) {
                var u = URL(fileURLWithPath: p).deletingLastPathComponent()
                while u.pathComponents.count > URL(fileURLWithPath: home).pathComponents.count { parents.insert(u.path); u = u.deletingLastPathComponent() }
            }
            rule("deny", "file-write*", tagged: true, parents.sorted().map(lit))
            // what the user's own unsandboxed git executes from, and the pointers that pick it (renaming .git, rewriting a
            // worktree's .git file or commondir/gitdir would swap in a planted config): never writable, grants included.
            // M3b.5: nor a worktree's lane mark (`LaneWorktree.markerName`): only the daemon writes which lanes are its own.
            if let common {
                let c = re(common)
                rule("deny", "file-write*", tagged: true, [
                    lit(common), lit(project + "/.git"), sub(common + "/hooks"), lit(common + "/config"),
                    lit(common + "/config.worktree"), lit(common + "/info/attributes"), lit(common + "/commondir"),
                    rx("^" + c + "/worktrees/[^/]+/(commondir|gitdir|config\\.worktree|\(LaneWorktree.markerName))$"),
                    rx("^" + c + "/modules/.+/(hooks(/|$)|config$|config\\.worktree$|commondir$|info/attributes$)"),
                ])
            } else {
                rule("deny", "file-write*", tagged: true, [lit(project + "/.git")])   // no planting a pointer in a non-git project
            }
            // M3c.3 (finding 4 of the 3b review): a lane never renames nor deletes its own folder or its git dir in
            // `<common>/worktrees` (what is in them stays writable). Moving the git dir out, rewriting `gitdir` and the
            // mark where the regex above does not reach and moving it back, or swapping the lane's folder for a symlink
            // to another lane, would get past the rules above. Git needs neither inside the lane. Untagged, as the
            // lane's other denies.
            if i.lanePaddock != nil { rule("deny", "file-write*", [lit(project)] + [worktree].compactMap { $0.map(lit) }) }
        }
        out.append(";; Collie: closed (data, tokens, grants, workspace.json); this terminal's files readable; only the socket")
        rule("deny", "file-read* file-write*", tagged: true, [sub(collie)])
        rule("allow", "file-read*", i.ownFiles.map { sub(real($0)) } + [sub(tdir)])   // subpath: Cursor's plugin is a dir
        // Claude vets each component of its --settings path: the dirs from the root down to its own files can be
        // examined (stat/readlink), not listed
        var vetted: Set<String> = []
        for f in i.ownFiles.map({ real($0) }) + [tdir] where under(f, collie) {
            var u = URL(fileURLWithPath: f).deletingLastPathComponent()
            while u.path.count >= collie.count { vetted.insert(u.path); u = u.deletingLastPathComponent() }
        }
        rule("allow", "file-read-metadata", vetted.sorted().map(lit))
        rule("allow", "file-write*", [sub(tdir + "/state")])
        rule("deny", "network-outbound", tagged: true, ["(remote unix-socket \(sub(collie)))"])
        rule("allow", "network-outbound", ["(remote unix-socket (path-literal \(q(real(i.socket)))))"])

        if strict {
            // R14: by path only (a copy of the binary runs): defence in depth, not a boundary. R12: `security` stays (Keychain logins)
            out.append(";; processes: no launchd, no LaunchServices `open` (the shim asks the daemon); no signals out")
            rule("deny", "process-exec", tagged: true, [lit("/bin/launchctl"), lit("/usr/bin/open")])
        }
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
