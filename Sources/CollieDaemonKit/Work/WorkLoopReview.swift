import Foundation
import CryptoKit
import CollieCore
import CollieProtocol

/// F2 R4: `Effect.runReview` carried out. The personas and the spec come from the attempt's BASE commit (`before`, by
/// `git show`), never from the worktree: the agent that worked cannot change who judges it, nor against what. Each
/// persona gets a fresh terminal of its own (no leash to the agent that worked, none of its history): only
/// `ReviewPrompt.build`'s text. Every reviewer is dismissed before this returns, so none is ever there when the
/// attempt asks about other terminals (`awaitOthers`) or settles the tree.
extension WorkLoop {
    /// What one review left: the machine's outcome, the task's summary line and the attempt's note.
    struct Reviewed: Sendable {
        var outcome: ReviewOutcome
        var line: String
        var note: String
        /// F2 Z3a: the turn left after the line counts and the spec is under `reviewMinTurn`: no reviewer was summoned
        var budgetOut = false
        /// P1: the journal lines the review leaves (`reviewerMute` per mute persona, `reviewRetried`): the caller records them.
        var events: [LoopEvent] = []
    }

    /// One persona's answer, with the model it ran on (for the note and the evidence file).
    struct PersonaRun: Sendable, Codable {
        var persona: String, model: String?, approved: Bool, invalid: String?, findings: [ReviewFinding]
    }

    // ponytail: `unique` sorts out a name taken meanwhile
    static func reviewerName(_ agent: String, persona: String) -> String { AgentNaming.reviewer(agent, persona: persona) }

    /// F2 X4: what the reviewers read instead of a spec when the task has none at the base (no spec, outside the repo
    /// or not committed): said, never the title in silence.
    static var noSpec: String { tr("sem spec no commit base", "no spec at the base commit") }

    /// F2 Y1: the parent of every reviewer's folder: `<daemon root>/<AgentNaming.reviewDir>`, inside Collie's own dir,
    /// which every terminal's profile keeps closed (read and write, `SandboxProfile`): no agent, the judged one
    /// included, plants a CLAUDE.md there or swaps a component for a symlink. Never the temp dir, which every terminal writes.
    static func reviewRoot(of daemonRoot: URL) -> URL { daemonRoot.appendingPathComponent(AgentNaming.reviewDir) }

    /// What an agent loads from its folder's ancestors: none may be in a reviewer's parent.
    static let agentConfigs = ["CLAUDE.md", "AGENTS.md", ".claude", ".cursor"]

    /// F2 V3 (reviewPathLinked): `rel` under `dir` has a parent component (below `dir`) that is a symlink, or one that
    /// lstat cannot see. The daemon runs outside the sandbox: a `.claude` the judged agent or an orphan swapped for a link
    /// to `~/.ssh` would make a move or delete by path reach `~/.ssh/config`. The last component is never followed by
    /// `moveItem`/`removeItem` (a link is moved or removed as a link), so only the parents are checked.
    /// ponytail: lstat then act by path, a window as wide as one syscall; openat/unlinkat with O_NOFOLLOW if a review shows it raced
    static func reviewPathLinked(_ dir: URL, _ rel: String) -> Bool {
        var path = dir.path, st = stat()
        for c in rel.split(separator: "/").dropLast() {
            if c == ".." { return true }
            path += "/" + c
            if lstat(path, &st) != 0 || (st.st_mode & S_IFMT) == S_IFLNK { return true }
        }
        return false
    }
    static var reviewPathLinkedNote: String { tr("recusado, symlink no caminho (nada movido nem apagado)", "refused, symlink in the path (nothing moved or deleted)") }

    /// F2 Z3a: of the ignored paths new since the review began, the agent configs a reviewer may have left (a path with
    /// one of these names as a component); the rest may be the Shepherd's or the user's (`.env`, a local db) and stays.
    static func reviewerLeftovers(_ fresh: Set<String>) -> (drop: [String], keep: [String]) {
        let names = Set(agentConfigs + ["CLAUDE.local.md"])
        let drop = fresh.filter { $0.split(separator: "/").contains { names.contains(String($0)) } }
        return (drop.sorted(), fresh.subtracting(drop).sorted())
    }

    /// F2 Z3b: what `reviewTree`'s status cannot see: `--ignored=matching` shows an ignored or untracked folder that
    /// already exists as one line, so a file made or edited inside it (`.claude/settings.local.json` in an ignored
    /// `.claude/`) leaves the status as it was. Path → lstat's type, size, inode, mtime and ctime (a ctime no `touch`
    /// sets back) of the worktree's agent configs: `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md` at the root, everything
    /// under the root's `.claude/` and `.cursor/` and under each `.claude/` or `.cursor/` folder `status` shows as one
    /// line. Never follows a symlink. Taken before and after the review: any difference is a touch.
    /// ponytail: walks the whole of those folders (metadata only, no read); a `.claude/worktrees/` of checkouts makes it slow, cap it then
    static func reviewHashAgentConfig(_ dir: URL, status: String?) -> [String: String] {
        let folded = (status ?? "").split(separator: "\0").map { String($0.dropFirst(3)) }
            .filter { $0.hasSuffix("/") && [".claude", ".cursor"].contains(($0.dropLast() as NSString).lastPathComponent) }
        var seen: [String: String] = [:]
        func note(_ rel: String) {
            var st = stat()
            guard lstat(dir.path + "/" + rel, &st) == 0 else { return }
            seen[rel] = "\(st.st_mode) \(st.st_size) \(st.st_ino) \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec) \(st.st_ctimespec.tv_sec).\(st.st_ctimespec.tv_nsec)"
        }
        for top in Set(["CLAUDE.md", "CLAUDE.local.md", "AGENTS.md", ".claude", ".cursor"] + folded.map { String($0.dropLast()) }) {
            note(top)
            var st = stat()
            guard lstat(dir.path + "/" + top, &st) == 0, st.st_mode & S_IFMT == S_IFDIR,
                  let walk = FileManager.default.enumerator(atPath: dir.path + "/" + top) else { continue }
            // the enumerator lists a symlink without going into it
            while let rel = walk.nextObject() as? String { note(top + "/" + rel) }
        }
        return seen
    }

    /// F2 Z3b: the judged agent's terminal is dismissed and every process left in its process group (one it started in
    /// the background and that survived the dismiss's SIGHUP) killed, before any reviewer is summoned: none is left to
    /// read a reviewer's folder (`ps`, `lsof`) and plant a `MEMORY.md` under `~/.claude/projects/` for it to load.
    /// The limit: a process that left the group (`setsid`) is not reached.
    // ponytail: SIGKILL without a wait: a killed process runs nothing more, its zombie is harmless
    static func reapGroup(_ pgid: pid_t) {
        if pgid > 1 { kill(-pgid, SIGKILL) }
    }

    /// F2 W2: every descendant of `roots` (not `roots` themselves), by `proc_listchildpids`: Claude Code runs each Bash
    /// in a group of its own, so a background process (`nohup`, `&`) of the judged agent is outside the PTY's group.
    static func descendants(of roots: Set<pid_t>) -> Set<pid_t> {
        var seen = Set<pid_t>(), todo = Array(roots)
        while let p = todo.popLast() {
            var buf = [pid_t](repeating: 0, count: 4096)
            let n = Int(proc_listchildpids(p, &buf, Int32(buf.count * MemoryLayout<pid_t>.size)))
            for c in buf.prefix(Swift.max(n, 0)) where c > 1 && !roots.contains(c) && seen.insert(c).inserted { todo.append(c) }
        }
        return seen
    }

    /// F2 W2: what `dismissReaping` kills once the terminal is dismissed. `leader`: the PTY's pid, read BEFORE the
    /// dismiss and only while its process ran (`running`): a pid already reaped may be someone else's now, so no group
    /// is killed for it. `known`: its descendants read before the dismiss (`descendants`), reparented to launchd since.
    /// Those and their own descendants are stopped until no new one shows up (none forks while the sweep runs), then
    /// killed, then the leader's group.
    /// The limit: a descendant that left before the first sweep and reparented to launchd is not reached.
    // ponytail: pid reuse between the sweep and the kill is not guarded (milliseconds); a pidfd-like handle when macOS has one
    static func reap(leader: pid_t?, running: Bool, known: Set<pid_t>) {
        var all = known
        while true {
            for p in all { kill(p, SIGSTOP) }
            let more = descendants(of: all).subtracting(all)
            if more.isEmpty { break }
            all.formUnion(more)
        }
        for p in all { kill(p, SIGKILL) }
        if running, let leader { reapGroup(leader) }
    }

    /// F2 W2: the folder, inside the reviewer's own (`reviewScratch`), where the judged commit is exported.
    static let reviewSnapshotDir = "reviewSnapshot"

    /// F2 V1: why a reviewer's copy could not be made (that reviewer is mute, with this reason).
    struct SnapshotFailure: Error { let why: String }

    /// T1 f2fix8 (reviewOneCopy): the copy made, and the paths left out of it for size (said in the review's note).
    struct Snapshot: Sendable { var url: URL; var skipped: [String] }

    /// T1 f2fix8 (reviewOneCopy): a blob above `reviewOneCopyMaxBlob`, or one that would take the copy past
    /// `reviewOneCopyMaxTotal`, is left out (named in the note): under `reviewSnapshotCap`, headers included.
    static let reviewOneCopyMaxBlob = 4 << 20
    static let reviewOneCopyMaxTotal = 48 << 20
    /// T2 f2fix8: the output cap of the copy's own gits (`ls-tree`, `cat-file --batch`); every other `laneGit` keeps 1 MiB.
    static let reviewSnapshotCap = 64 << 20
    static var reviewSnapshotNotUTF8: String { tr("caminho não UTF-8 no commit", "non-UTF-8 path in the commit") }
    /// T1 f2fix8: the copy has `reviewOneCopyDeadline(turn)` seconds to be made: a fifth of the reviewers' turn, at least 30.
    static func reviewOneCopyDeadline(_ turn: Int) -> Int { Swift.max(30, turn / 5) }
    static var reviewOneCopyLate: String { tr("sem parecer: cópia não ficou pronta a tempo", "no opinion: the copy was not ready in time") }

    /// F2 W2: the judged commit (never the live worktree, where a process the judged agent left may swap a file between
    /// the commit and the review) copied to `<scratch>/reviewSnapshot`, read-only. Its agent configs (`agentConfigs`,
    /// `CLAUDE.local.md`, at any depth) are left out: the diff shows them. A failure: the reviewers are mute (fail closed),
    /// the reason said.
    /// F2 V1 (reviewSnapshotOutside): through the daemon's own git (`laneGit`), outside the loop's profile, which denies
    /// Collie's root, where the reviewer's folder is. Fixed arguments, the commit resolved to its hash first.
    /// F2 U2 (reviewNoReplace): built from the commit's blobs, never `git archive`: the commit's `.gitattributes`
    /// (working-tree-encoding, eol, export-subst, export-ignore, an LFS filter run outside any sandbox) cannot change
    /// nor hide what the reviewer reads, and no replacement object (`GitRunner`) stands in for the commit. Every path
    /// checked (no absolute, empty, `.`, `..` nor `.git` component); written with O_EXCL|O_NOFOLLOW in folders made
    /// here; a symlink (120000) becomes a text file holding its target; a submodule (160000) a file holding its oid.
    /// T1 f2fix8 (reviewOneCopy): three gits whatever the tree's size: `rev-parse`, `ls-tree -r -z -l` (sizes first:
    /// the caps are applied before any blob is read) and one `cat-file --batch` fed every oid on its stdin. `end`: past
    /// it the batch is killed, or the writing stops, and the copy fails with `reviewOneCopyLate`.
    func reviewSnapshot(_ judged: String, _ dir: URL, into scratch: URL,
                        until end: ContinuousClock.Instant = .now + .seconds(600)) async -> Result<Snapshot, SnapshotFailure> {
        func fail(_ why: String) -> Result<Snapshot, SnapshotFailure> {
            .failure(SnapshotFailure(why: ContinuousClock.now >= end ? Self.reviewOneCopyLate : tr("cópia do commit: ", "commit copy: ") + why))
        }
        let snap = scratch.appendingPathComponent(Self.reviewSnapshotDir, isDirectory: true)
        guard let r = try? await host.laneGit(["rev-parse", "--verify", "--end-of-options", judged + "^{commit}"], in: dir), r.status == 0 else {
            return fail(tr("o commit não resolveu", "the commit did not resolve"))
        }
        let hash = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard [40, 64].contains(hash.count), hash.allSatisfy(\.isHexDigit) else { return fail(tr("hash inválido", "invalid hash")) }
        guard mkdir(snap.path, 0o700) == 0 else { return fail(tr("pasta não criada", "folder not created")) }
        var dirs: [String] = [snap.path]
        // folders read-only on any way out: a failure leaves nothing writable (`dropScratch` reopens them)
        defer { for d in dirs.reversed() { chmod(d, 0o555) } }
        guard let ls = try? await host.laneGit(["ls-tree", "-r", "-z", "-l", "--full-tree", hash], stdin: nil, timeout: .seconds(120),
                                                    cap: Self.reviewSnapshotCap, in: dir), ls.status == 0, !ls.truncated else {
            return fail(tr("git ls-tree falhou", "git ls-tree failed"))
        }
        let names = Set(Self.agentConfigs + ["CLAUDE.local.md"])
        // `inline`: a submodule's content, never read from git
        var items: [(comps: [Substring], path: String, oid: String, size: Int, inline: Data?)] = [], skipped: [String] = [], total = 0
        // T2 f2fix8: split on NUL in bytes; a path that is not UTF-8 fails the copy by name (decoded, it would become
        // U+FFFD and two such paths collide on O_EXCL)
        for entry in ls.stdoutData.split(separator: 0) {
            guard let tab = entry.firstIndex(of: 0x09) else { return fail(tr("ls-tree ilegível", "unreadable ls-tree")) }
            let meta = String(decoding: entry[..<tab], as: UTF8.self).split(separator: " ")
            guard let path = String(data: entry[(tab + 1)...], encoding: .utf8) else { return fail(Self.reviewSnapshotNotUTF8) }
            guard meta.count == 4 else { return fail(tr("ls-tree ilegível", "unreadable ls-tree")) }
            let mode = meta[0], oid = String(meta[2])
            guard ["100644", "100755", "120000", "160000"].contains(mode) else { return fail(tr("modo \(mode) em \(path)", "mode \(mode) in \(path)")) }
            let comps = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), comps.allSatisfy({ !["", ".", "..", ".git"].contains($0) }) else {
                return fail(tr("caminho recusado: \(path)", "path refused: \(path)"))
            }
            if comps.contains(where: { names.contains(String($0)) }) { continue }
            guard [40, 64].contains(oid.count), oid.allSatisfy(\.isHexDigit) else { return fail(tr("oid inválido em \(path)", "invalid oid in \(path)")) }
            if mode == "160000" { items.append((comps, path, oid, 0, Data((oid + "\n").utf8))); continue }
            guard let size = Int(meta[3]), size >= 0 else { return fail(tr("tamanho ilegível em \(path)", "unreadable size in \(path)")) }
            if size > Self.reviewOneCopyMaxBlob || total + size > Self.reviewOneCopyMaxTotal { skipped.append(path); continue }
            total += size
            items.append((comps, path, oid, size, nil))
        }
        // one process for every blob: "<oid> blob <size>\n<bytes>\n" each, in the order asked
        let wanted = items.filter { $0.inline == nil }
        var blobs: [Data] = []
        if !wanted.isEmpty {
            let input = Data(wanted.map { $0.oid + "\n" }.joined().utf8)
            let left = end - .now
            guard left > .zero else { return fail(tr("sem tempo", "out of time")) }
            guard let b = try? await host.laneGit(["cat-file", "--batch"], stdin: input, timeout: left, cap: Self.reviewSnapshotCap, in: dir), b.status == 0, !b.truncated else {
                return fail(tr("git cat-file --batch falhou", "git cat-file --batch failed"))
            }
            let out = b.stdoutData
            var at = out.startIndex
            for w in wanted {
                guard let nl = out[at...].firstIndex(of: 0x0A) else { return fail(tr("blob ilegível: \(w.path)", "unreadable blob: \(w.path)")) }
                let head = String(decoding: out[at..<nl], as: UTF8.self).split(separator: " ")
                let body = nl + 1, end = body + w.size
                guard head.count == 3, head[0] == w.oid, head[1] == "blob", Int(head[2]) == w.size,
                      end < out.endIndex, out[end] == 0x0A else { return fail(tr("blob ilegível: \(w.path)", "unreadable blob: \(w.path)")) }
                blobs.append(out[body..<end])
                at = end + 1
            }
        }
        var made: Set<String> = [], next = 0
        for item in items {
            if ContinuousClock.now >= end { return fail(tr("sem tempo", "out of time")) }
            let data: Data
            if let inline = item.inline { data = inline } else { data = blobs[next]; next += 1 }
            var p = snap.path
            for c in item.comps.dropLast() {
                p += "/" + c
                if made.contains(p) { continue }
                guard mkdir(p, 0o700) == 0 else { return fail(tr("pasta não criada: \(item.path)", "folder not created: \(item.path)")) }
                made.insert(p); dirs.append(p)
            }
            p += "/" + item.comps.last!
            let fd = open(p, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return fail(tr("arquivo não criado: \(item.path)", "file not created: \(item.path)")) }
            let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            guard (try? h.write(contentsOf: data)) != nil, (try? h.close()) != nil else { return fail(tr("arquivo não escrito: \(item.path)", "file not written: \(item.path)")) }
            chmod(p, 0o444)
        }
        return .success(Snapshot(url: snap, skipped: skipped))
    }

    /// T1 f2fix8 (reviewOneCopy): the attempt's ONE copy of the judged commit (`reviewSnapshot`), in a folder of its own
    /// under `reviewRoot`, made within `deadline` seconds (the batch git is killed past it). The caller clones it into
    /// each reviewer's folder (`reviewClone`) and drops `master` (always, whatever the result).
    // ponytail: `rev-parse` and `ls-tree` keep `laneGit`'s own 120 s; the end is checked after them, not inside
    func reviewOneCopy(_ judged: String, _ dir: URL, agent: String, deadline: Int) async -> (master: URL?, Result<Snapshot, SnapshotFailure>) {
        let end = ContinuousClock.now + .seconds(deadline)
        guard let master = Self.reviewScratch(Self.reviewerName(agent, persona: "copia"), in: host.reviewRoot) else {
            return (nil, .failure(SnapshotFailure(why: tr("cópia do commit: pasta não criada", "commit copy: folder not created"))))
        }
        return (master, await reviewSnapshot(judged, dir, into: master, until: end))
    }

    /// T1 f2fix8 (reviewOneCopy): the copy cloned into `<scratch>/reviewSnapshot` (`clonefile`: APFS shares the blocks
    /// until one side writes, so a reviewer that writes changes no other's copy), read-only as the master.
    // ponytail: off APFS a plain recursive `copyfile`, slower on a big tree; no other filesystem runs the daemon today
    static func reviewClone(_ master: URL, into scratch: URL) -> Result<URL, SnapshotFailure> {
        let dst = scratch.appendingPathComponent(reviewSnapshotDir, isDirectory: true)
        if clonefile(master.path, dst.path, UInt32(CLONE_NOFOLLOW)) == 0
            || copyfile(master.path, dst.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW)) == 0 {
            return .success(dst)
        }
        return .failure(SnapshotFailure(why: tr("cópia do commit: clone não feito", "commit copy: clone not made")))
    }

    /// F2 Z2: an agent's config a reviewer would load from beyond its folder: in `reviewRoot` or any ancestor up to `/`,
    /// in the home, or the home's own `~/.claude/CLAUDE.md` and `~/.claude/settings.json`. The first one that exists and
    /// the loop's agent may write (`strictWritable`); nil: none. One found: every reviewer is mute (fail closed).
    static func plantedConfig(above reviewRoot: URL, home: URL, opened: [String]) -> String? {
        var dirs: [String] = [], p = reviewRoot.path
        while true { dirs.append(p); guard p != "/", !p.isEmpty else { break }; p = (p as NSString).deletingLastPathComponent }
        dirs.append(home.path)
        let paths = dirs.flatMap { d in agentConfigs.map { (d == "/" ? "" : d) + "/" + $0 } }
            + [home.path + "/.claude/CLAUDE.md", home.path + "/.claude/settings.json"]
        return paths.first { var st = stat(); return lstat($0, &st) == 0 && strictWritable($0, home: home, opened: opened) }
    }

    /// F2 V2: why every reviewer is mute when the home's `~/.claude.json` changed between the attempt's start and the
    /// reviewers' launch, and the note when it changed during the review (verdicts dropped, `reviewerTouched`).
    static var reviewGlobalConfigMoved: String { tr("configuração global mudou durante a tentativa", "global configuration changed during the attempt") }
    /// F2 U1: the note when `~/.claude.json` holds an `env` key or `autoConnectIde` true the loop's base did not.
    static var reviewGlobalConfigRiskyNote: String { tr("configuração global tem env ou autoConnectIde", "global configuration has env or autoConnectIde") }
    static var reviewGlobalConfigTouched: String { tr("configuração global (~/.claude.json) mudou durante a revisão", "global configuration (~/.claude.json) changed during the review") }

    /// F2 V2 (reviewGlobalConfigHash): `~/.claude.json` is writable by every strict terminal (`EssentialPaths`, R13) and
    /// Claude Code reads more than `mcpServers` from it (`env`: `HTTPS_PROXY`, `NODE_EXTRA_CA_CERTS`, the auto-memory
    /// switch; `autoConnectIde`). The SHA-256 of what matters there: the keys `env`, `mcpServers`, `autoConnectIde`
    /// and `projects`, the last only for the paths a reviewer is born in (`reviewRoot`, its ancestors, under it) and
    /// without Claude Code's own counters (`last*`, `example*`, `hasUnseen*`, `logged*`) or default values (empty, false,
    /// null): Claude Code rewrites the file on every start and exit. No file: "". Not a JSON object: the bytes' hash
    /// (any change counts, fail closed). Taken at the attempt's start, at the reviewers' launch and after the review.
    // ponytail: by key list; a new Claude Code key that loads config outside these is not seen, add it here then
    static func reviewGlobalConfigHash(home: URL, reviewRoot: URL) -> String {
        guard let data = FileManager.default.contents(atPath: home.appendingPathComponent(".claude.json").path) else { return "" }
        func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        guard let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "raw:" + sha(data) }
        func isDefault(_ v: Any) -> Bool {
            if v is NSNull { return true }
            if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return !n.boolValue }
            if let a = v as? [Any] { return a.isEmpty }
            if let o = v as? [String: Any] { return o.isEmpty }
            return false
        }
        let root = reviewRoot.path
        func reviewerPath(_ p: String) -> Bool { p == root || p == "/" || root.hasPrefix(p + "/") || p.hasPrefix(root + "/") }
        var kept: [String: Any] = [:]
        for k in ["env", "mcpServers", "autoConnectIde"] { if let v = all[k] { kept[k] = v } }
        if let projects = all["projects"] as? [String: Any] {
            var mine: [String: Any] = [:]
            for (path, entry) in projects where reviewerPath(path) {
                guard let e = entry as? [String: Any] else { mine[path] = entry; continue }
                let f = e.filter { k, v in !["last", "example", "hasUnseen", "logged"].contains(where: k.hasPrefix) && !isDefault(v) }
                if !f.isEmpty { mine[path] = f }
            }
            if !mine.isEmpty { kept["projects"] = mine }
        } else if let p = all["projects"] { kept["projects"] = p }
        guard let canon = try? JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys, .fragmentsAllowed]) else { return "raw:" + sha(data) }
        return sha(canon)
    }

    /// F2 U1 (reviewGlobalConfigRisky): what in `~/.claude.json` runs code or reaches out in every reviewer's Bash
    /// (`env`: `PATH`, `ZDOTDIR`; `autoConnectIde`): "" when `env` has no key and `autoConnectIde` is not true (or no
    /// file); else the SHA-256 of both, canonical. Not a JSON object: the bytes' hash (fail closed).
    static func reviewGlobalConfigRisky(home: URL) -> String {
        guard let data = FileManager.default.contents(atPath: home.appendingPathComponent(".claude.json").path) else { return "" }
        func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
        guard let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "raw:" + sha(data) }
        let env = all["env"], ide = all["autoConnectIde"]
        let quietEnv = env == nil || env is NSNull || (env as? [String: Any])?.isEmpty == true
        let quietIde = ide == nil || ide is NSNull || ((ide as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && !$0.boolValue } ?? false)
        if quietEnv && quietIde { return "" }
        let kept: [String: Any] = ["env": env ?? NSNull(), "autoConnectIde": ide ?? NSNull()]
        guard let canon = try? JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys, .fragmentsAllowed]) else { return "raw:" + sha(data) }
        return sha(canon)
    }

    /// F2 V3 (reviewTrust): the notes `trustReviewRoot` leaves.
    static var reviewTrustWritten: String { tr("confiança da pasta dos revisores gravada em ~/.claude.json", "reviewers' folder trust written to ~/.claude.json") }
    static var reviewTrustNotWritten: String { tr("confiança da pasta dos revisores não gravada em ~/.claude.json", "reviewers' folder trust not written to ~/.claude.json") }

    /// F2 V3: Claude Code asks "trust this folder" in every reviewer's fresh folder, and only the user answers it
    /// (`81effa13`): `projects[reviewRoot].hasTrustDialogAccepted = true` in `home/.claude.json` covers the folders under
    /// it. Read, merged and written atomically (a temp file beside it, `rename`; its mode kept; a symlink's target
    /// written), touching nothing else. nil: no file (Claude Code never ran: not made) or already true (not rewritten).
    /// Else the note: written, or why not (not a JSON object, `projects` or the entry not an object, a write error).
    /// F4 3: the temp file is flushed (`F_FULLFSYNC`, else `fsync`) before the `rename`; and the file's `stat` (inode, size,
    /// mtime) at the read is compared with the one just before the `rename`: changed (Claude Code wrote it meanwhile), it is
    /// read and merged again, once; changed again, nothing is written (the user's file wins) and the note says so.
    // ponytail: stat check, no lock; a write between the last stat and the rename still loses, the window is microseconds
    /// F2 V3b: the temp file is born 0600 (`O_EXCL|O_NOFOLLOW`, written through its descriptor): a copy of the file (it may
    /// hold `primaryApiKey`, `oauthAccount`) is never readable by others, then takes the original's mode before the `rename`.
    /// `beforeRename` (tests): the temp file's path, written, before it takes that mode (once per try).
    static func trustReviewRoot(home: URL, reviewRoot: URL, beforeRename: (String) -> Void = { _ in }) -> String? {
        let file = SignedAppCheck.realPath(home.appendingPathComponent(".claude.json"))
        func mark() -> [Int]? {
            var st = stat()
            guard stat(file, &st) == 0 else { return nil }
            return [Int(st.st_ino), Int(st.st_size), Int(st.st_mtimespec.tv_sec), Int(st.st_mtimespec.tv_nsec)]
        }
        for _ in 0..<2 {
            let seen = mark()
            guard let data = FileManager.default.contents(atPath: file) else { return nil }
            guard var all = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return reviewTrustNotWritten + tr(": não é um objeto JSON", ": not a JSON object") }
            let key = SignedAppCheck.realPath(reviewRoot)
            guard var projects = all["projects"] == nil ? [:] : all["projects"] as? [String: Any],
                  var entry = projects[key] == nil ? [:] : projects[key] as? [String: Any] else { return reviewTrustNotWritten + tr(": projects não é um objeto", ": projects is not an object") }
            if (entry["hasTrustDialogAccepted"] as? Bool) == true { return nil }
            entry["hasTrustDialogAccepted"] = true; projects[key] = entry; all["projects"] = projects
            guard let out = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .withoutEscapingSlashes]) else {
                return reviewTrustNotWritten + tr(": não serializa", ": does not serialize")
            }
            let mode = ((try? FileManager.default.attributesOfItem(atPath: file))?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o600
            let tmp = file + ".collie-\(UUID().uuidString.prefix(8))"
            let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return reviewTrustNotWritten + ": " + String(cString: strerror(errno)) }
            let wrote = out.withUnsafeBytes { buf -> Bool in
                var off = 0
                while off < buf.count {
                    let n = write(fd, buf.baseAddress! + off, buf.count - off)
                    if n < 0 { if errno == EINTR { continue }; return false }
                    off += n
                }
                return true
            }
            func err() -> String { String(cString: strerror(errno)) }
            var why: String? = wrote ? nil : err()
            if why == nil { beforeRename(tmp); if fchmod(fd, mode_t(mode)) != 0 { why = err() } }
            if why == nil, fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { why = err() }
            if close(fd) != 0, why == nil { why = err() }
            if let why { unlink(tmp); return reviewTrustNotWritten + ": " + why }
            guard mark() == seen else { unlink(tmp); continue }   // written meanwhile: read and merge again
            if rename(tmp, file) != 0 { let why = err(); unlink(tmp); return reviewTrustNotWritten + ": " + why }
            return reviewTrustWritten
        }
        return reviewTrustNotWritten + ": " + reviewTrustRaced
    }
    static var reviewTrustRaced: String { tr("o arquivo mudou durante a gravação, duas vezes; deixado como está", "the file changed during the write, twice; left as it is") }

    /// F2 U1 (reviewLoopConfigBase): `~/.claude.json` as the loop takes its base, before any judged agent of the run.
    func reviewLoopConfigBase() async -> (hash: String, risky: String) {
        let home = await host.globalConfigHome()
        return (Self.reviewGlobalConfigHash(home: home, reviewRoot: host.reviewRoot), Self.reviewGlobalConfigRisky(home: home))
    }

    /// F2 Z2: whether a strict loop agent may write `path` (resolved: a symlink counts where it points), fail closed: the
    /// user may write it or its folder, and it is outside the home (temp dirs, other volumes) or under `opened` (the
    /// write grants, the paddocks). Inside the home a strict profile writes only the project, the caches and the grants.
    /// ponytail: by path, not by the profile's rules; a cache under the home (`EssentialPaths.homeWrites`) holds no config a reviewer loads.
    static func strictWritable(_ path: String, home: URL, opened: [String]) -> Bool {
        let real = SignedAppCheck.realPath(URL(fileURLWithPath: path))
        guard access(real, W_OK) == 0 || access((real as NSString).deletingLastPathComponent, W_OK) == 0 else { return false }
        let c = URL(fileURLWithPath: real).pathComponents
        func under(_ r: String) -> Bool { c.starts(with: URL(fileURLWithPath: SignedAppCheck.realPath(URL(fileURLWithPath: r))).pathComponents) }
        return !under(home.path) || opened.contains(where: under)
    }

    /// F2 X1/Y1: a reviewer's own folder, empty, made by the daemon under `reviewRoot` (outside every worktree, paddock
    /// and temp dir) by `mkdtemp` (a name no one can guess), mode 0700, one per attempt and persona. nil (that reviewer
    /// is mute, a refusal): a component of the path is a symlink or not a folder, the parent is not the daemon's
    /// user's, it holds an agent's config, or the folder could not be made. Removed once its reviewer is dismissed
    /// (`dropScratch`); what a fallen daemon left goes at the next start (`stopLoopsLeftRunning`).
    static func reviewScratch(_ name: String, in reviewRoot: URL) -> URL? {
        // never `standardizedFileURL`: it turns an existing `/private/tmp/…` into the symlink `/tmp/…`
        let root = reviewRoot.path
        func plainDir(_ p: String, owned: Bool) -> Bool {
            var st = stat()
            guard lstat(p, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return false }   // a symlink is S_IFLNK
            return !owned || st.st_uid == geteuid()
        }
        // ponytail: two tries: a loop that just removed the empty parent (`dropScratch`) makes the first fail
        for _ in 0..<2 {
            var prefix = ""
            for c in URL(fileURLWithPath: root).deletingLastPathComponent().pathComponents.dropFirst() {
                prefix += "/" + c
                guard plainDir(prefix, owned: false) else { return nil }
            }
            if mkdir(root, 0o700) != 0, errno != EEXIST { return nil }
            guard plainDir(root, owned: true) else { return nil }
            guard !agentConfigs.contains(where: { var st = stat(); return lstat(root + "/" + $0, &st) == 0 }) else { return nil }
            var tmpl = Array((root + "/" + name + "-XXXXXXXX").utf8CString)
            // the path is read inside the closure: the buffer is `tmpl`'s, gone once it returns
            if let made = tmpl.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!).map { String(cString: $0) } }) {
                return URL(fileURLWithPath: made, isDirectory: true)
            }
            guard errno == ENOENT else { return nil }
        }
        return nil
    }

    /// A reviewer's folder goes, and its parent with it once no other reviewer's folder is in it (`rmdir` of an empty dir).
    static func dropScratch(_ scratch: URL) {
        // F2 W2: the snapshot's read-only folders let nothing in them go: writable again first
        let snap = scratch.appendingPathComponent(reviewSnapshotDir).path
        chmod(snap, 0o700)
        if let walk = FileManager.default.enumerator(atPath: snap) {
            while let rel = walk.nextObject() as? String {
                var st = stat()
                if lstat(snap + "/" + rel, &st) == 0, st.st_mode & S_IFMT == S_IFDIR { chmod(snap + "/" + rel, 0o700) }
            }
        }
        try? FileManager.default.removeItem(at: scratch)
        rmdir(scratch.deletingLastPathComponent().path)
    }

    /// A1 (reviewAdvisory): the task's `review` line: "parecer: veto (...)", "parecer: sem veto (...)" or
    /// "parecer: sem parecer (...)" (what `WorkStatusText.loopEnded` counts). Never "aprovado".
    static func reviewAdvisoryLine(_ o: ReviewOutcome, _ detail: String) -> String {
        ReviewVerdict.reviewLabel + (!o.approved ? tr("veto", "veto") : o.silent != nil ? ReviewVerdict.reviewAdvisoryNone : tr("sem veto", "no veto")) + " (\(detail))"
    }

    /// P1: why a reviewer gave no answer, said in its note and in the journal (`reviewerMute`). `summonRefused`'s text
    /// is the router's error, cleaned like any journal detail (`eventDetail`). An unreadable answer keeps `ReviewVerdict.parse`'s own reason.
    enum ReviewMuteCause: Sendable, Equatable {
        case summonRefused(String), terminalGone, timedOut(Int), emptyText
        /// C1 (P1-a): the prompt never reached the reviewer (`AskCoordinator.promptNotDelivered`), not a turn past its time.
        case promptNotDelivered
        /// C1 (P1-a): the reviewer's terminal sat in an approval or dialog nobody answered, so the prompt was refused.
        case awaitingApproval
        var text: String {
            switch self {
            case .summonRefused(let why): tr("summon recusado: ", "summon refused: ") + WorkLoop.eventDetail(why)
            case .terminalGone: tr("terminal sumiu", "terminal gone")
            case .timedOut(let s): tr("passou do tempo do turno (\(s) s)", "turn time ran out (\(s) s)")
            case .emptyText: tr("texto vazio", "empty text")
            case .promptNotDelivered: tr("prompt não entregue", "prompt not delivered")
            case .awaitingApproval: tr("terminal esperando aprovação", "terminal waiting for approval")
            }
        }

        /// C1 (P1-a): the cause of an ask that failed, by the error's code first, its text only to split them apart.
        static func of(_ e: ProtocolError, turn: Int) -> ReviewMuteCause {
            if AskCoordinator.promptNotDelivered(e) { return .promptNotDelivered }
            if e.code == .timeout { return .timedOut(turn) }
            if e.code == .unavailable, e.message.contains(ErrorTag.approval) { return .awaitingApproval }
            return .terminalGone
        }
    }

    /// No answer: invalid, never a veto nor an approval (A1, reviewAdvisory: 'sem parecer'). P1: the cause is said.
    static func mute(_ persona: String, _ cause: ReviewMuteCause) -> PersonaVerdict {
        PersonaVerdict(persona: persona, approved: false, findings: [], invalid: tr("revisor \(persona) sem resposta (causa: \(cause.text))", "reviewer \(persona) did not answer (cause: \(cause.text))"))
    }

    /// P1: the journal detail of the retry when every persona was mute.
    static var reviewRetryNote: String { tr("todas as personas mudas: revisão repetida uma vez", "all personas mute: review repeated once") }

    /// The personas at `before`: the `.md` files of `CommandRouter.personasDir` as committed there.
    func basePersonas(_ before: String, _ dir: URL) async throws -> [Persona] {
        guard let ls = try? await host.git(["ls-tree", "-z", "--name-only", before, "--", CommandRouter.personasDir], in: dir), ls.status == 0 else {
            throw PersonaError.malformed(file: CommandRouter.personasDir, reason: tr("git ls-tree falhou no commit base", "git ls-tree failed at the base commit"))
        }
        var files: [String: String] = [:]
        for path in ls.stdout.split(separator: "\0").map(String.init) where path.hasSuffix(".md") {
            guard let r = try? await host.git(["show", "\(before):\(path)"], in: dir), r.status == 0 else {
                throw PersonaError.malformed(file: path, reason: tr("git show falhou no commit base", "git show failed at the base commit"))
            }
            files[(path as NSString).lastPathComponent] = r.stdout
        }
        guard !files.isEmpty else { throw PersonaError.malformed(file: CommandRouter.personasDir, reason: tr("nenhuma persona no commit base", "no persona at the base commit")) }
        return try PersonaCatalog.parse(files: files)
    }

    /// What the reviewers read as evidence: the attempt's commit hashes, its shortstat and the check's (and the gate's)
    /// exit status. F2 X2: never the commits' subjects nor the check's output, words of who worked.
    func reviewEvidence(before: String, judged: String, check: Int32?, gate: Int32??, _ dir: URL) async -> String {
        let log = await out(["log", "--format=%h", "-n", "\(Self.evidenceCommits)", "\(before)..\(judged)"], dir) ?? ""
        let stat = await out(["diff", "--shortstat", before, judged], dir) ?? ""
        func status(_ s: Int32?) -> String { s.map { tr("saiu com \($0)", "exited with \($0)") } ?? tr("sem status (não rodou ou passou do tempo)", "no status (did not run or timed out)") }
        var parts = ["Commits: " + log.split(separator: "\n").joined(separator: " "), "Diffstat: " + stat, "Check: " + status(check)]
        if let gate { parts.append(tr("Portão: ", "Gate: ") + status(gate)) }
        return parts.joined(separator: "\n")
    }

    /// F2 Y2b: the line check reads at most this many changed files, `reviewMaxLineFileBytes` each (`GitRunner`'s cap:
    /// a truncated `git show` is one past it) and `reviewMaxLineBytes` in all; past any of them it is skipped (no line
    /// counts: every finding's line stays as it came, never a false "não existe").
    static let reviewMaxLinePaths = 200
    static let reviewMaxLineFileBytes = 1 << 20
    static let reviewMaxLineBytes = 8 << 20

    /// F2 X5/Y2b: path → lines of each changed file as judged (deleted ones have none to point at); empty past the caps.
    func reviewLineCounts(_ paths: [String], judged: String, _ dir: URL) async -> [String: Int] {
        guard paths.count <= Self.reviewMaxLinePaths else { return [:] }
        var counted: [String: Int] = [:], read = 0
        for p in paths {
            guard let r = try? await host.git(["show", "\(judged):\(p)"], in: dir), r.status == 0 else { continue }
            let size = r.stdout.utf8.count
            read += size
            guard !r.truncated, size <= Self.reviewMaxLineFileBytes, read <= Self.reviewMaxLineBytes else { return [:] }
            counted[p] = ReviewVerdict.lineCount(r.stdout)
        }
        return counted
    }

    /// The review of one attempt: pick the personas, run one reviewer per persona (at once), read each answer, dismiss
    /// them all. `turn`: seconds each reviewer has, asked once the line counts are read (F2 Y2b: what they took is not
    /// the reviewers') and again once the commit's copy is made (T1 f2fix8: nor is the copy's).
    func review(work: Work, loop: WorkLoopState, task: WorkTask, n: Int, agent: String, before: String, judged: String,
                evidence: String, configSilenced: String? = nil, agentOpen: Bool = false, turn: @Sendable () async -> Int, _ dir: URL) async -> Reviewed {
        let personas: [Persona]
        let diff = (try? await host.git(["diff", before, judged], in: dir)).flatMap { $0.status == 0 ? $0.stdout : nil } ?? ""
        let paths = (try? await host.git(["diff", "--name-only", "-z", "--no-renames", before, judged], in: dir))
            .flatMap { $0.status == 0 ? $0.stdout.split(separator: "\0").map(String.init) : nil } ?? []
        let lines = diff.split(separator: "\n").filter { ($0.hasPrefix("+") && !$0.hasPrefix("+++")) || ($0.hasPrefix("-") && !$0.hasPrefix("---")) }.count
        do {
            // F2 X4: a diff that touches a persona or a spec of the work's tasks (what judges the next attempts) calls seguranca
            personas = try PersonaRouter(catalog: try await basePersonas(before, dir))
                .select(changedPaths: paths, diffLines: lines, diffText: diff, requested: loop.personas,
                        specs: work.tasks.compactMap { $0.spec.map { Self.repoRelative($0, dir) } }, only: loop.reviewOnly)
        } catch {
            // A1 (reviewAdvisory): no catalog to judge with is no opinion, not a veto: the check and the gate decide
            let outcome = ReviewVerdict.silent(tr("sem personas no commit base (\(error))", "no personas at the base commit (\(error))"))
            return Reviewed(outcome: outcome, line: Self.reviewAdvisoryLine(outcome, tr("sem personas", "no personas")),
                            note: LotBoards.scrub(tr("[loop] parecer de \"\(task.title)\", tentativa \(n): ", "[loop] review of \"\(task.title)\", attempt \(n): ") + outcome.notes.joined(separator: "; ")))
        }
        // F2 X5: a finding's line is checked in the file as judged
        let lineCounts = await reviewLineCounts(paths, judged: judged, dir)
        let spec = await specText(task.spec, at: before, dir)
        let budgetOut = Reviewed(outcome: .init(approved: false, reason: Self.reviewBudgetNote, notes: []), line: "", note: "", budgetOut: true)
        let specShown = spec.isEmpty ? tr("(\(Self.noSpec); só o título da tarefa) ", "(\(Self.noSpec); only the task's title) ") + task.title : spec
        let host = host, check = task.check ?? ""
        // F2 Z2: an agent's config the judged agent may write where a reviewer loads it: every reviewer mute, the path said
        let opened = await host.strictWrites()
        let planted = agentOpen ? nil : Self.plantedConfig(above: host.reviewRoot, home: opened.home, opened: opened.paths)
        // F2 V2/U1: `~/.claude.json` changed since the loop began, or holds an `env` its base did not: every reviewer mute
        let silenced = configSilenced ?? planted.map { tr("\($0) existe e o agente do laço pode gravá-lo", "\($0) exists and the loop's agent can write it") }
        /// One round of reviewers: fresh folders, one copy, one terminal per persona, all dismissed and their folders gone.
        /// nil: the budget is too short for it (no reviewer summoned).
        func round() async -> (runs: [(Int, PersonaRun, UUID?)], skipped: [String])? {
            let before_ = await turn()
            // F2 Z3a: the counts and the spec ate the budget: mute reviewers would be a refusal that is not one (X3)
            if before_ < Swift.min(Self.reviewMinTurn, loop.timeout) { return nil }
            let scratch = personas.map { p in silenced == nil ? Self.reviewScratch(Self.reviewerName(agent, persona: p.name), in: host.reviewRoot) : nil }
            // F2 W2: each reviewer reads the judged commit's copy in its own folder, never the live worktree.
            // T1 f2fix8 (reviewOneCopy): one copy per attempt, cloned into each folder; the turn is read once it is made.
            var snapshots: [URL?] = scratch.map { _ in nil }, snapshotWhy: [String?] = scratch.map { _ in nil }, skipped: [String] = []
            if scratch.contains(where: { $0 != nil }) {
                let (master, copy) = await reviewOneCopy(judged, dir, agent: agent, deadline: Self.reviewOneCopyDeadline(before_))
                for (i, s) in scratch.enumerated() {
                    guard let s else { continue }
                    switch copy.flatMap({ Self.reviewClone($0.url, into: s) }) {
                    case .success(let u): snapshots[i] = u
                    case .failure(let f): snapshotWhy[i] = f.why
                    }
                }
                if case .success(let c) = copy { skipped = c.skipped }
                if let master { Self.dropScratch(master) }
            }
            let turn = await turn()
            // T1 f2fix8: the copy ate the budget: no reviewer, no refusal counted
            if turn < Swift.min(Self.reviewMinTurn, loop.timeout) {
                for case let s? in scratch { Self.dropScratch(s) }
                return nil
            }
            let runs = await withTaskGroup(of: (Int, PersonaRun, UUID?).self) { g in
                for (i, p) in personas.enumerated() {
                    let model = loop.reviewerModel ?? p.model ?? loop.model
                    let as_ = { var l = loop; l.model = model; return l }()
                    // F2 X2: a nonce per reviewer and attempt, made here after the agent's turn: no text of the diff can carry it
                    let nonce = ReviewPrompt.newNonce()
                    let snapshot = snapshots[i], snapshotFailed = snapshotWhy[i]
                    let prompt = ReviewPrompt.build(persona: p, spec: specShown, diff: diff, evidence: evidence, check: check, nonce: nonce,
                                                    snapshot: snapshot?.path)
                    let name = Self.reviewerName(agent, persona: p.name), cwd = snapshot == nil ? nil : scratch[i]
                    g.addTask {
                        var id: UUID?
                        var verdict = Self.mute(p.name, .summonRefused(tr("pasta do revisor não criada", "reviewer folder not created")))
                        if let silenced { verdict.invalid = tr("revisor \(p.name) mudo: \(silenced)", "reviewer \(p.name) mute: \(silenced)") }
                        if let why = snapshotFailed { verdict.invalid = tr("revisor \(p.name) mudo: \(why)", "reviewer \(p.name) mute: \(why)") }
                        // P1: which of the four ways the reviewer said nothing
                        do throws(ProtocolError) {
                            guard let cwd else { throw ProtocolError(code: .internal, message: "no scratch folder") }   // fail closed: mute
                            // F2 X5: no time left to answer in: mute, and no terminal summoned for nothing
                            guard turn > 0 else { verdict = Self.mute(p.name, .timedOut(turn)); throw ProtocolError(code: .timeout, message: "no turn left") }
                            let t: UUID
                            do throws(ProtocolError) {
                                t = try await AgentNaming.summon(name, taskId: task.id, taken: await host.namesTaken()) { (x: String) async throws(ProtocolError) -> UUID in
                                    try await host.summonReviewer(name: x, for: work, loop: as_, cwd: cwd)
                                }
                            } catch { verdict = Self.mute(p.name, .summonRefused(error.message)); throw error }
                            id = t
                            let text: String
                            do throws(ProtocolError) { text = try await host.askText(t, prompt: prompt, timeout: .seconds(turn)) } catch {
                                verdict = Self.mute(p.name, .of(error, turn: turn)); throw error
                            }
                            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { verdict = Self.mute(p.name, .emptyText) }
                            else { verdict = ReviewVerdict.parse(text, persona: p.name, nonce: nonce, lineCounts: lineCounts) }
                        } catch {}
                        return (i, PersonaRun(persona: p.name, model: model, approved: verdict.approved, invalid: verdict.invalid, findings: verdict.findings), id)
                    }
                }
                var all: [(Int, PersonaRun, UUID?)] = []
                for await r in g { all.append(r) }
                return all.sorted { $0.0 < $1.0 }
            }
            // every reviewer goes, whatever it answered, before the machine moves on
            for case let (_, _, id?) in runs { await host.dismiss(id) }
            // nothing above throws: the folders go whatever happened, a cancelled loop included
            for case let s? in scratch { Self.dropScratch(s) }
            return (runs, skipped)
        }
        guard let first = await round() else { return budgetOut }
        var runs = first.runs, skipped = first.skipped
        // P1: each mute persona's cause in the journal
        var events: [LoopEvent] = []
        func journal(_ rs: [(Int, PersonaRun, UUID?)]) {
            for r in rs { if let why = r.1.invalid { events.append(entry(.reviewerMute, task: task.id, attempt: n, detail: why)) } }
        }
        journal(runs)
        // P1: every persona mute (none deliberately silenced: a retry would be mute the same way) is asked again, once,
        // with fresh reviewers and folders, inside the budget; some mute is a note per persona, no retry
        var firstRound = ""
        if silenced == nil, !runs.isEmpty, runs.allSatisfy({ $0.1.invalid != nil }), !Task.isCancelled {
            events.append(entry(.reviewRetried, task: task.id, attempt: n, detail: Self.reviewRetryNote))
            firstRound = tr("\n1ª rodada (\(Self.reviewRetryNote)): ", "\n1st round (\(Self.reviewRetryNote)): ") + runs.compactMap(\.1.invalid).joined(separator: "; ")
            if let again = await round() { (runs, skipped) = again; journal(runs) }
            else { firstRound += tr(" (repetição sem orçamento)", " (repeat without budget)") }
        }
        let verdicts = runs.map { PersonaVerdict(persona: $0.1.persona, approved: $0.1.approved, findings: $0.1.findings, invalid: $0.1.invalid) }
        let outcome = ReviewVerdict.aggregate(verdicts, threshold: loop.reviewThreshold)
        let found = runs.reduce(0) { $0 + $1.1.findings.count }
        let line = Self.reviewAdvisoryLine(outcome, tr("personas: \(personas.map(\.name).joined(separator: ", ")); \(found) " + (found == 1 ? "achado" : "achados"),
                                                             "personas: \(personas.map(\.name).joined(separator: ", ")); \(found) " + (found == 1 ? "finding" : "findings")))
        let each = runs.map { r in
            "\(r.1.persona) (\(r.1.model ?? tr("modelo do laço", "loop model"))): \(r.1.invalid != nil ? ReviewVerdict.reviewAdvisoryNone : r.1.approved ? "approve" : "reject")"
                + (r.1.invalid.map { ", \($0)" } ?? "") + (r.1.findings.isEmpty ? "" : ": " + r.1.findings.map { "[\($0.severity.rawValue)] \($0.text)" }.joined(separator: "; "))
        }
        writeReviewFile(work.id, task: task.id, n: n, runs.map(\.1))
        let left = skipped.isEmpty ? "" : tr("\ncópia sem \(skipped.count) arquivo(s) acima do limite de tamanho: ", "\ncopy without \(skipped.count) file(s) over the size limit: ") + skipped.prefix(10).joined(separator: ", ")
            + (skipped.count > 10 ? ", …" : "")
        let note = LotBoards.scrub(tr("[loop] parecer de \"\(task.title)\", tentativa \(n): ", "[loop] review of \"\(task.title)\", attempt \(n): ") + line + (spec.isEmpty ? " (\(Self.noSpec))" : "")
            + "\n" + each.joined(separator: "\n") + firstRound + left)
        return Reviewed(outcome: outcome, line: line, note: String(note.prefix(Self.noteChars)), events: events)
    }

    /// The evidence of the review: `<patchDir>/evidence/<task>-revisao/tentativa-<n>.json`, per persona its model,
    /// verdict and findings. Beside the task's evidence folder, never in it (an approval's copy empties that one).
    private func writeReviewFile(_ work: UUID, task: String, n: Int, _ runs: [PersonaRun]) {
        let folder = EvidenceFiles.dir(host.patchDir(work), task: task + "-revisao")
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(runs) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: folder.appendingPathComponent("tentativa-\(n).json").path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
