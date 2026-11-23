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
    }

    /// One persona's answer, with the model it ran on (for the note and the evidence file).
    struct PersonaRun: Sendable, Codable {
        var persona: String, model: String?, approved: Bool, invalid: String?, findings: [ReviewFinding]
    }

    static func reviewerName(_ agent: String, persona: String) -> String {
        // ponytail: the persona's slug after the attempt's name, cut to AgentNaming.max from the head; `unique` sorts
        // out a name taken meanwhile
        let tail = "-" + AgentNaming.slug(persona)
        return String(agent.prefix(Swift.max(0, AgentNaming.max - tail.count))).trimmingCharacters(in: CharacterSet(charactersIn: "-")) + tail
    }

    /// F2 X1: a reviewer's own folder, empty (no agent config of anyone's), made by the daemon under its temp dir, outside
    /// every worktree and paddock: one per attempt and persona (the name carries both), removed once its reviewer is
    /// dismissed. nil: it could not be made (that reviewer is mute, a refusal).
    /// ponytail: a daemon that falls mid-review leaves it in the temp dir, which the system clears.
    static func reviewScratch(_ name: String) -> URL? {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("collie-review")
            .appendingPathComponent(name + "-" + UUID().uuidString.prefix(8).lowercased())
        do { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { return nil }
        return d
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

    /// The review of one attempt: pick the personas, run one reviewer per persona (at once), read each answer, dismiss
    /// them all. `turn`: seconds each reviewer has (the turn's).
    func review(work: Work, loop: WorkLoopState, task: WorkTask, n: Int, agent: String, before: String, judged: String,
                evidence: String, turn: Int, _ dir: URL) async -> Reviewed {
        let personas: [Persona]
        let diff = (try? await host.git(["diff", before, judged], in: dir)).flatMap { $0.status == 0 ? $0.stdout : nil } ?? ""
        let paths = (try? await host.git(["diff", "--name-only", "-z", "--no-renames", before, judged], in: dir))
            .flatMap { $0.status == 0 ? $0.stdout.split(separator: "\0").map(String.init) : nil } ?? []
        let lines = diff.split(separator: "\n").filter { ($0.hasPrefix("+") && !$0.hasPrefix("+++")) || ($0.hasPrefix("-") && !$0.hasPrefix("---")) }.count
        do {
            personas = try PersonaRouter(catalog: try await basePersonas(before, dir))
                .select(changedPaths: paths, diffLines: lines, diffText: diff, requested: loop.personas)
        } catch {
            // no catalog to judge with is no approval
            let why = "revisor recusou: sem personas no commit base (\(error))"
            return Reviewed(outcome: .init(approved: false, reason: why, notes: []), line: "revisão: recusada (sem personas)",
                            note: LotBoards.scrub("[loop] revisão de \"\(task.title)\", tentativa \(n): \(why)"))
        }
        let spec = await specText(task.spec, at: before, dir)
        let host = host, check = task.check ?? ""
        let scratch = personas.map { Self.reviewScratch(Self.reviewerName(agent, persona: $0.name)) }
        let runs = await withTaskGroup(of: (Int, PersonaRun, UUID?).self) { g in
            for (i, p) in personas.enumerated() {
                let model = loop.reviewerModel ?? p.model ?? loop.model
                let as_ = { var l = loop; l.model = model; return l }()
                // F2 X2: a nonce per reviewer and attempt, made here after the agent's turn: no text of the diff can carry it
                let nonce = ReviewPrompt.newNonce()
                let prompt = ReviewPrompt.build(persona: p, spec: spec.isEmpty ? task.title : spec, diff: diff, evidence: evidence, check: check, nonce: nonce)
                let name = Self.reviewerName(agent, persona: p.name), cwd = scratch[i]
                g.addTask {
                    var id: UUID?
                    var verdict = Self.mute(p.name)
                    do {
                        guard let cwd else { throw ProtocolError(code: .internal, message: "no scratch folder") }   // fail closed: mute
                        let t = try await AgentNaming.summon(name, taskId: task.id, taken: await host.namesTaken()) { (x: String) async throws(ProtocolError) -> UUID in
                            try await host.summonReviewer(name: x, for: work, loop: as_, cwd: cwd)
                        }
                        id = t
                        let text = try await host.askText(t, prompt: prompt, timeout: .seconds(turn))
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { verdict = ReviewVerdict.parse(text, persona: p.name, nonce: nonce) }
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
        for case let s? in scratch { try? FileManager.default.removeItem(at: s) }
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
        let note = LotBoards.scrub("[loop] revisão de \"\(task.title)\", tentativa \(n): " + line + "\n" + each.joined(separator: "\n"))
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
