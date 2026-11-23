import Foundation
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
    }

    /// One persona's answer, with the model it ran on (for the note and the evidence file).
    struct PersonaRun: Sendable, Codable {
        var persona: String, model: String?, approved: Bool, invalid: String?, findings: [ReviewFinding]
    }

    // ponytail: `unique` sorts out a name taken meanwhile
    static func reviewerName(_ agent: String, persona: String) -> String { AgentNaming.reviewer(agent, persona: persona) }

    /// F2 X4: what the reviewers read instead of a spec when the task has none at the base (no spec, outside the repo
    /// or not committed): said, never the title in silence.
    static let noSpec = "sem spec no commit base"

    /// F2 Y1: the parent of every reviewer's folder: `<daemon root>/<AgentNaming.reviewDir>`, inside Collie's own dir,
    /// which every terminal's profile keeps closed (read and write, `SandboxProfile`): no agent, the judged one
    /// included, plants a CLAUDE.md there or swaps a component for a symlink. Never the temp dir, which every terminal writes.
    static func reviewRoot(of daemonRoot: URL) -> URL { daemonRoot.appendingPathComponent(AgentNaming.reviewDir) }

    /// What an agent loads from its folder's ancestors: none may be in a reviewer's parent.
    static let agentConfigs = ["CLAUDE.md", "AGENTS.md", ".claude", ".cursor"]

    /// F2 Z3a: of the ignored paths new since the review began, the agent configs a reviewer may have left (a path with
    /// one of these names as a component); the rest may be the Shepherd's or the user's (`.env`, a local db) and stays.
    static func reviewerLeftovers(_ fresh: Set<String>) -> (drop: [String], keep: [String]) {
        let names = Set(agentConfigs + ["CLAUDE.local.md"])
        let drop = fresh.filter { $0.split(separator: "/").contains { names.contains(String($0)) } }
        return (drop.sorted(), fresh.subtracting(drop).sorted())
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
        try? FileManager.default.removeItem(at: scratch)
        rmdir(scratch.deletingLastPathComponent().path)
    }

    /// No answer (summon refused, terminal gone, past the turn's time, empty text): a refusal, fail closed.
    static func mute(_ persona: String) -> PersonaVerdict {
        PersonaVerdict(persona: persona, approved: false, findings: [], invalid: "revisor \(persona) sem resposta")
    }

    /// The personas at `before`: the `.md` files of `CommandRouter.personasDir` as committed there.
    func basePersonas(_ before: String, _ dir: URL) async throws -> [Persona] {
        guard let ls = try? await host.git(["ls-tree", "-z", "--name-only", before, "--", CommandRouter.personasDir], in: dir), ls.status == 0 else {
            throw PersonaError.malformed(file: CommandRouter.personasDir, reason: "git ls-tree falhou no commit base")
        }
        var files: [String: String] = [:]
        for path in ls.stdout.split(separator: "\0").map(String.init) where path.hasSuffix(".md") {
            guard let r = try? await host.git(["show", "\(before):\(path)"], in: dir), r.status == 0 else {
                throw PersonaError.malformed(file: path, reason: "git show falhou no commit base")
            }
            files[(path as NSString).lastPathComponent] = r.stdout
        }
        guard !files.isEmpty else { throw PersonaError.malformed(file: CommandRouter.personasDir, reason: "nenhuma persona no commit base") }
        return try PersonaCatalog.parse(files: files)
    }

    /// What the reviewers read as evidence: the attempt's commit hashes, its shortstat and the check's (and the gate's)
    /// exit status. F2 X2: never the commits' subjects nor the check's output, words of who worked.
    func reviewEvidence(before: String, judged: String, check: Int32?, gate: Int32??, _ dir: URL) async -> String {
        let log = await out(["log", "--format=%h", "-n", "\(Self.evidenceCommits)", "\(before)..\(judged)"], dir) ?? ""
        let stat = await out(["diff", "--shortstat", before, judged], dir) ?? ""
        func status(_ s: Int32?) -> String { s.map { "saiu com \($0)" } ?? "sem status (não rodou ou passou do tempo)" }
        var parts = ["Commits: " + log.split(separator: "\n").joined(separator: " "), "Diffstat: " + stat, "Check: " + status(check)]
        if let gate { parts.append("Portão: " + status(gate)) }
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
    /// the reviewers').
    func review(work: Work, loop: WorkLoopState, task: WorkTask, n: Int, agent: String, before: String, judged: String,
                evidence: String, turn: () async -> Int, _ dir: URL) async -> Reviewed {
        let personas: [Persona]
        let diff = (try? await host.git(["diff", before, judged], in: dir)).flatMap { $0.status == 0 ? $0.stdout : nil } ?? ""
        let paths = (try? await host.git(["diff", "--name-only", "-z", "--no-renames", before, judged], in: dir))
            .flatMap { $0.status == 0 ? $0.stdout.split(separator: "\0").map(String.init) : nil } ?? []
        let lines = diff.split(separator: "\n").filter { ($0.hasPrefix("+") && !$0.hasPrefix("+++")) || ($0.hasPrefix("-") && !$0.hasPrefix("---")) }.count
        do {
            // F2 X4: a diff that touches a persona or a spec of the work's tasks (what judges the next attempts) calls seguranca
            personas = try PersonaRouter(catalog: try await basePersonas(before, dir))
                .select(changedPaths: paths, diffLines: lines, diffText: diff, requested: loop.personas,
                        specs: work.tasks.compactMap { $0.spec.map { Self.repoRelative($0, dir) } })
        } catch {
            // no catalog to judge with is no approval
            let why = "revisor recusou: sem personas no commit base (\(error))"
            return Reviewed(outcome: .init(approved: false, reason: why, notes: []), line: "revisão: recusada (sem personas)",
                            note: LotBoards.scrub("[loop] revisão de \"\(task.title)\", tentativa \(n): \(why)"))
        }
        // F2 X5: a finding's line is checked in the file as judged
        let lineCounts = await reviewLineCounts(paths, judged: judged, dir)
        let spec = await specText(task.spec, at: before, dir)
        let turn = await turn()
        // F2 Z3a: the counts and the spec ate the budget: mute reviewers would be a refusal that is not one (X3)
        if turn < Swift.min(Self.reviewMinTurn, loop.timeout) {
            return Reviewed(outcome: .init(approved: false, reason: Self.reviewBudgetNote, notes: []), line: "", note: "", budgetOut: true)
        }
        let specShown = spec.isEmpty ? "(\(Self.noSpec); só o título da tarefa) " + task.title : spec
        let host = host, check = task.check ?? ""
        // F2 Z2: an agent's config the judged agent may write where a reviewer loads it: every reviewer mute, the path said
        let opened = await host.strictWrites()
        let planted = Self.plantedConfig(above: host.reviewRoot, home: opened.home, opened: opened.paths)
        let scratch = personas.map { planted == nil ? Self.reviewScratch(Self.reviewerName(agent, persona: $0.name), in: host.reviewRoot) : nil }
        let runs = await withTaskGroup(of: (Int, PersonaRun, UUID?).self) { g in
            for (i, p) in personas.enumerated() {
                let model = loop.reviewerModel ?? p.model ?? loop.model
                let as_ = { var l = loop; l.model = model; return l }()
                // F2 X2: a nonce per reviewer and attempt, made here after the agent's turn: no text of the diff can carry it
                let nonce = ReviewPrompt.newNonce()
                let prompt = ReviewPrompt.build(persona: p, spec: specShown, diff: diff, evidence: evidence, check: check, nonce: nonce)
                let name = Self.reviewerName(agent, persona: p.name), cwd = scratch[i]
                g.addTask {
                    var id: UUID?
                    var verdict = Self.mute(p.name)
                    if let planted { verdict.invalid = "revisor \(p.name) mudo: \(planted) existe e o agente do laço pode gravá-lo" }
                    do {
                        guard let cwd else { throw ProtocolError(code: .internal, message: "no scratch folder") }   // fail closed: mute
                        // F2 X5: no time left to answer in: mute, and no terminal summoned for nothing
                        guard turn > 0 else { throw ProtocolError(code: .timeout, message: "no turn left") }
                        let t = try await AgentNaming.summon(name, taskId: task.id, taken: await host.namesTaken()) { (x: String) async throws(ProtocolError) -> UUID in
                            try await host.summonReviewer(name: x, for: work, loop: as_, cwd: cwd)
                        }
                        id = t
                        let text = try await host.askText(t, prompt: prompt, timeout: .seconds(turn))
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { verdict = ReviewVerdict.parse(text, persona: p.name, nonce: nonce, lineCounts: lineCounts) }
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
        let verdicts = runs.map { PersonaVerdict(persona: $0.1.persona, approved: $0.1.approved, findings: $0.1.findings, invalid: $0.1.invalid) }
        let outcome = ReviewVerdict.aggregate(verdicts)
        let found = runs.reduce(0) { $0 + $1.1.findings.count }
        let line = "revisão: \(outcome.approved ? "aprovada" : "recusada") (personas: \(personas.map(\.name).joined(separator: ", ")); \(found) "
            + (found == 1 ? "achado" : "achados") + ")"
        let each = runs.map { r in
            "\(r.1.persona) (\(r.1.model ?? "modelo do laço")): \(r.1.approved ? "aprovou" : "recusou")"
                + (r.1.invalid.map { ", \($0)" } ?? "") + (r.1.findings.isEmpty ? "" : ": " + r.1.findings.map { "[\($0.severity.rawValue)] \($0.text)" }.joined(separator: "; "))
        }
        writeReviewFile(work.id, task: task.id, n: n, runs.map(\.1))
        let note = LotBoards.scrub("[loop] revisão de \"\(task.title)\", tentativa \(n): " + line + (spec.isEmpty ? " (\(Self.noSpec))" : "")
            + "\n" + each.joined(separator: "\n"))
        return Reviewed(outcome: outcome, line: line, note: String(note.prefix(Self.noteChars)))
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
