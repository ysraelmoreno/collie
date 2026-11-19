import Foundation
import CollieCore
import CollieProtocol
import CollieTerminal

/// Everything the loop needs from the daemon. No preset or LLM appears here.
protocol LoopHost: Sendable {
    /// A fresh agent terminal in `work`'s paddock, as the loop's settings ask. Returns its id.
    func summon(name: String, for work: Work, loop: WorkLoopState) async throws(ProtocolError) -> UUID
    func ask(_ terminal: UUID, prompt: String, timeout: Duration) async throws(ProtocolError) -> AskResult.Source
    /// True while the terminal's agent is in a turn (the daemon's own badge/turn state).
    func working(_ terminal: UUID) async -> Bool
    func dismiss(_ terminal: UUID) async
    /// A terminal of the work's paddock in a turn, other than the starter (the loop's agent is already gone): its name.
    func othersWorking() async -> String?
    /// The starter (the Shepherd the loop summons as) still exists.
    func starterAlive() async -> Bool
    func git(_ args: [String], in dir: URL) async throws(ProtocolError) -> ProcessResult
    /// `command` via `/bin/bash -c` in `dir`, under the loop's own sandbox profile; throws (never runs unsandboxed) when
    /// the daemon sandboxes terminals and that profile is missing.
    func check(_ command: String, in dir: URL, timeout: Duration) async throws(ProtocolError) -> ProcessResult
    func readSpec(_ path: String) async -> String?
    /// `path` (relative) is a file in the worktree `dir`.
    func exists(_ path: String, in dir: URL) async -> Bool
    /// Where attempt patches go: `<root>/work-loops/<work id>/`.
    func patchDir(_ work: UUID) -> URL
    func now() -> Date
}

/// `collie work run`'s attempt cycle: a fresh agent per attempt, a check that alone decides, a clean tree between
/// attempts. A task passes only when its check exits 0, the loop's gate (if any) exits 0 too, there is a new commit on
/// the same branch, no tracked file is left dirty and neither the check nor the gate moved HEAD. The gate judges the
/// tree of the commit the check judged, and not one whose commit changed a script the gate's text names. The loop never pushes, lands or creates a paddock.
actor WorkLoop {
    static let noteLines = 40, noteChars = 4000
    /// Where a project keeps its feature map, in order of preference.
    static let featureMaps = ["docs/feature-map.md", "FEATURES.md"]
    static let evidenceCommits = 20, evidenceSubject = 200, evidenceLines = 20, evidenceChars = 2000
    let store: WorkStore, host: any LoopHost, poll: Duration, checkTimeout: Duration
    private var stopping: Set<UUID> = []

    init(store: WorkStore, host: any LoopHost, poll: Duration = .seconds(15), checkTimeout: Duration = .seconds(1800)) {
        self.store = store; self.host = host; self.poll = poll; self.checkTimeout = checkTimeout
    }

    /// Ends the loop after the current attempt's verdict.
    func stop(work id: UUID) { stopping.insert(id) }

    /// Runs `work`'s open tasks until all are done/deferred, `max` is used or `stop` is asked. `work.loop` must be set
    /// and `.running`. Returns the final state.
    func run(work id: UUID, dir: URL) async -> WorkLoopState.State {
        var end = WorkLoopState.State.stopped
        while !stopping.contains(id), !Task.isCancelled {
            // closed, missing or stopped from outside (a daemon restart's sweep): stop
            guard let w = try? await store.get(id), w.closedAt == nil, let loop = w.loop, loop.state == .running,
                  await host.starterAlive() else { break }
            // only the tasks the owner approved: one added since waits for the next run
            guard let task = w.tasks.first(where: { $0.state == .open && (loop.tasks?.contains($0.id) ?? true) }) else { end = .finished; break }
            if let max = loop.max, loop.used >= max { break }
            if let b = loop.budget, (loop.spent ?? 0) >= b {
                await note(id, "[loop] orçamento de tempo usado (\(loop.spent ?? 0) de \(b) s); laço parado")
                break
            }
            let t0 = host.now()
            let go = await attempt(w, loop, task, dir)
            let secs = Int(host.now().timeIntervalSince(t0).rounded(.up))
            try? await store.update(id) { x in let was = x.loop?.spent ?? 0; x.loop?.spent = was + secs }
            guard go else { break }
        }
        stopping.remove(id)
        let now = host.now(), final = end
        try? await store.update(id) { w in
            guard w.loop != nil else { return }
            w.loop!.state = final; w.loop!.endedAt = now; w.loop!.task = nil
        }
        return end
    }

    /// One attempt of `task`, through its verdict. False: the loop stops (no verdict when the work closed, the starter is
    /// gone, or the tree holds changes that are not the attempt's; a verdict and no reset when another terminal works).
    private func attempt(_ w: Work, _ loop: WorkLoopState, _ task: WorkTask, _ dir: URL) async -> Bool {
        let n = (task.tries ?? 0) + 1, name = "loop-\(task.id)-\(n)", started = host.now()
        // git failing here (the loop's profile gone, not a repo): stop, nothing to judge
        guard let before = await out(["rev-parse", "HEAD"], dir), let branch = await out(["rev-parse", "--abbrev-ref", "HEAD"], dir),
              let pending = await out(["status", "--porcelain", "--untracked-files=no"], dir) else {
            await note(w.id, "[loop] git falhou em \(dir.path); laço parado")
            return false
        }
        // tracked changes now are someone else's (each attempt ends on a clean tree): never the loop's to reset
        guard pending.isEmpty else {
            await note(w.id, "[loop] arquivos rastreados modificados (dirty) antes da tentativa de \"\(task.title)\", e não são do laço; laço parado, worktree intocada:\n\(pending.prefix(500))")
            return false
        }
        // pre-existing untracked files are never the attempt's: the reset must not delete them
        let keep = await untracked(dir)
        try? await store.update(w.id) { x in
            if let i = x.tasks.firstIndex(where: { $0.id == task.id }) { x.tasks[i].state = .inProgress; x.tasks[i].updatedAt = started }
            x.loop?.task = task.id; x.loop?.attempt = n; x.loop?.used += 1; x.loop?.phase = .agent
            x.jobs.append(WorkJob(id: name, kind: .loop, label: task.title, startedAt: started))
        }

        var failure: String?   // the attempt failed before its check: summon or ask
        var agent: UUID?
        do { agent = try await host.summon(name: name, for: w, loop: loop) } catch { failure = error.message }
        if let agent, failure == nil {
            let spec = if let s = task.spec { await host.readSpec(s) } else { String?.none }
            let notes = w.notes.filter { $0.text.hasPrefix("[loop \(task.id)] ") }   // its own failures, by id
            var map: String?
            for m in Self.featureMaps where map == nil { if await host.exists(m, in: dir) { map = m } }
            let prompt = Self.prompt(task: task, spec: spec, attempt: n, tries: loop.tries, dir: dir, notes: notes, gate: loop.gate, map: map)
            let turn = Swift.min(loop.timeout, left(loop, since: started))   // the budget bounds the turn too
            do {
                if try await host.ask(agent, prompt: prompt, timeout: .seconds(turn)) == .idle {
                    await waitForCommit(agent, before: before, branch: branch, dir: dir, until: started + Double(turn))
                }
            } catch where error.code == .timeout {
                // a turn past its timeout is not a failure by itself: the check decides
            } catch { failure = error.message }
        }
        // before the check: nothing edits the tree while it is judged (a turn past its timeout may still be working)
        if let agent { await host.dismiss(agent) }
        // cancelled (the daemon stops): no verdict, no discard, the attempt not counted
        if Task.isCancelled {
            let at = host.now()
            try? await store.update(w.id) { x in
                if let i = x.tasks.firstIndex(where: { $0.id == task.id }), x.tasks[i].state == .inProgress { x.tasks[i].state = .open }
                let used = x.loop?.used ?? 0
                x.loop?.used = Swift.max(0, used - 1)
                if let j = x.jobs.firstIndex(where: { $0.id == name && $0.state == .running }) { x.jobs[j].state = .gone; x.jobs[j].endedAt = at }
            }
            return false
        }

        let closed = (try? await store.get(w.id)).map { $0?.closedAt != nil } ?? true
        let starterGone = !(await host.starterAlive())
        if closed || starterGone {
            let at = host.now(), why = closed ? "work closed" : "starter gone"
            try? await store.update(w.id) { x in
                if let i = x.tasks.firstIndex(where: { $0.id == task.id }), x.tasks[i].state == .inProgress { x.tasks[i].state = .open }
                Self.endJob(&x, name, why, at: at)
            }
            return false
        }

        var reason: String, output = ""
        var checkOutput = ""   // the check's own, kept for the evidence when a gate's output replaces `output`
        var passed = false
        var blocked: String?   // another terminal of the paddock is working: no reset, the loop stops
        var judged = before   // the commit the agent left: what the check and the gate judge, and where the evidence ends
        if let failure { reason = failure } else {
            let committed = await committed(before: before, branch: branch, dir)
            let dirty = (await out(["status", "--porcelain", "--untracked-files=no"], dir)).map { !$0.isEmpty } ?? true
            judged = await out(["rev-parse", "HEAD"], dir) ?? before
            let on = await out(["rev-parse", "--abbrev-ref", "HEAD"], dir) ?? branch
            let loose = Set(await untracked(dir))   // untracked before the check: the owner's (`keep`) and the agent's
            var status: Int32?   // nil: timed out
            var broken: String?   // the check could not even start
            await phase(w.id, .check)
            do {
                let budgeted = Duration.seconds(left(loop, since: started))
                let r = try await host.check(task.check ?? "false", in: dir, timeout: Swift.min(checkTimeout, budgeted))
                status = r.status; output = r.stdout + r.stderr; checkOutput = output
            } catch where error.code == .timeout {
                status = nil
            } catch { broken = "check could not run: \(error.message)" }
            // the check's own edits, files and commits never count, never reach the gate and never leak into the next
            // attempt: the tree goes back to exactly `judged`. Not when dirty (the agent's uncommitted work is the patch's)
            // nor while another terminal works (no reset under it).
            var moves: [String] = []   // the check or the gate moved HEAD: the attempt fails
            if !dirty { blocked = await host.othersWorking() }
            if await settle(judged, on: on, loose: loose, reset: !dirty && blocked == nil, dir) { moves.append("o check moveu o HEAD") }
            // the gate: only when nothing else already fails the attempt (no budget spent on a lost one), on the tree of
            // `judged`, in the check's conditions (timeout, budget); its output is the note's
            var gate: String?
            if let g = loop.gate, broken == nil, status == 0, committed, !dirty, moves.isEmpty {
                if blocked != nil { gate = "gate did not run (tree not reset)" }
                // the agent may not rewrite the script that judges it: the gate does not run on a tree that changed it
                else if let t = await tampered(g, before: before, judged: judged, dir) { gate = t } else {
                    await phase(w.id, .gate)
                    do {
                        let budgeted = Duration.seconds(left(loop, since: started))
                        let r = try await host.check(g, in: dir, timeout: Swift.min(checkTimeout, budgeted))
                        gate = Self.failure("gate", r.status); output = r.stdout + r.stderr
                    } catch where error.code == .timeout {
                        gate = Self.failure("gate", nil); output = ""
                    } catch { gate = "gate could not run: \(error.message)"; output = "" }
                    blocked = await host.othersWorking()
                    if await settle(judged, on: on, loose: loose, reset: blocked == nil, dir) { moves.append("o portão moveu o HEAD") }
                }
            }
            let v = Self.verdict(checkStatus: broken == nil ? status : 0, gate: gate, committed: committed, dirty: dirty)
            let reasons = [broken, v].compactMap { $0 } + moves
            passed = reasons.isEmpty
            reason = reasons.joined(separator: "; ")
        }

        await phase(w.id, nil)
        let at = host.now()
        if passed {
            // of `judged`, never of a HEAD read after the check and the gate ran
            let head = await out(["rev-parse", "--short", judged], dir) ?? ""
            let log = await out(["log", "--format=%h %s", "-n", "\(Self.evidenceCommits)", "\(before)..\(judged)"], dir) ?? ""
            let evidence = TaskEvidence(
                commits: log.split(separator: "\n").map { Self.evidenceCommit(String($0)) },
                shortstat: await out(["diff", "--shortstat", before, judged], dir) ?? "",
                checkTail: Self.evidenceTail(check: checkOutput, gate: loop.gate == nil ? nil : output),
                seconds: Swift.max(0, Int(at.timeIntervalSince(started).rounded())), attempt: n)
            try? await store.update(w.id) { x in
                // a task dropped or done meanwhile keeps that state
                if let i = x.tasks.firstIndex(where: { $0.id == task.id }), x.tasks[i].state == .inProgress {
                    x.tasks[i].state = .done; x.tasks[i].tries = n; x.tasks[i].reason = nil; x.tasks[i].lastFailure = nil; x.tasks[i].updatedAt = at
                    x.tasks[i].evidence = evidence
                }
                Self.endJob(&x, name, head, at: at)
            }
            if let blocked { await note(w.id, Self.blockedNote(blocked)) }
            return blocked == nil
        }

        if blocked == nil { blocked = await host.othersWorking() }
        if blocked == nil { await discard(w.id, task.id, n, before: before, branch: branch, keep: keep, dir) }
        let last = n >= loop.tries && blocked == nil   // a stopped loop defers nothing
        let tail = output.split(separator: "\n", omittingEmptySubsequences: false).suffix(Self.noteLines).joined(separator: "\n")
        // the next attempt's prompt carries it: secrets hidden (LotBoards.scrub's known shapes). ponytail: tail capped at 4000 chars
        let text = LotBoards.scrub("[loop \(task.id)] \(task.title), tentativa \(n)/\(loop.tries): \(reason)"
            + (tail.isEmpty ? "" : "\n" + String(tail.suffix(Self.noteChars))))
        try? await store.update(w.id) { x in
            if let i = x.tasks.firstIndex(where: { $0.id == task.id }), x.tasks[i].state == .inProgress {
                x.tasks[i].tries = n; x.tasks[i].lastFailure = reason; x.tasks[i].updatedAt = at
                if last { x.tasks[i].state = .deferred; x.tasks[i].reason = "loop: \(reason)" } else { x.tasks[i].state = .open }
            }
            x.notes.append(WorkNote(at: at, text: text))
            Self.endJob(&x, name, reason, at: at)
        }
        if let blocked { await note(w.id, Self.blockedNote(blocked)); return false }
        return true
    }

    /// Seconds of the budget left for this attempt (at least 1); no budget: a day.
    private func left(_ loop: WorkLoopState, since started: Date) -> Int {
        guard let b = loop.budget else { return 86_400 }
        return Swift.max(1, b - (loop.spent ?? 0) - Int(host.now().timeIntervalSince(started)))
    }

    private static func blockedNote(_ who: String) -> String {
        "[loop] '\(who)' está trabalhando no cercado: o laço não reseta a worktree com outro agente nela; laço parado, worktree intocada"
    }

    /// What the running loop is doing, for `work status` and the panel (nil: between attempts).
    private func phase(_ id: UUID, _ p: WorkLoopState.Phase?) async { try? await store.update(id) { x in x.loop?.phase = p } }

    private func note(_ id: UUID, _ text: String) async {
        let at = host.now()
        try? await store.update(id) { $0.notes.append(WorkNote(at: at, text: text)) }
    }

    /// An `.idle` end with no new commit yet: wait until there is one and the agent is out of its turn, or `deadline`.
    private func waitForCommit(_ agent: UUID, before: String, branch: String, dir: URL, until deadline: Date) async {
        if await committed(before: before, branch: branch, dir) { return }
        while host.now() < deadline, !Task.isCancelled {
            if !(await host.working(agent)), await committed(before: before, branch: branch, dir) { return }
            try? await Task.sleep(for: poll)
        }
    }

    /// A new commit: HEAD moved, `before` is its ancestor (no rewritten history) and the branch is still `branch`.
    private func committed(before: String, branch: String, _ dir: URL) async -> Bool {
        guard let head = await out(["rev-parse", "HEAD"], dir), head != before,
              await out(["rev-parse", "--abbrev-ref", "HEAD"], dir) == branch,
              (try? await host.git(["merge-base", "--is-ancestor", before, "HEAD"], in: dir))?.status == 0 else { return false }
        return true
    }

    /// Why the attempt may not go to the gate `gate`: it changed (edited, deleted, renamed) a file whose full path
    /// appears literally in the gate's text and that already existed in `before`. nil = it did not. Creating the file
    /// for the first time is allowed (a task whose spec is to write that script), and only the gate is guarded: a
    /// task's own check often names the very files the task must write.
    // ponytail: substring match on the command text, no shell parsing; a script the gate reaches indirectly
    // (sourced by another script, a directory argument) is not seen. Parse the command if that gap is ever used.
    private func tampered(_ gate: String, before: String, judged: String, _ dir: URL) async -> String? {
        guard let changed = await out(["-c", "core.quotePath=false", "diff", "--name-only", "--no-renames", before, judged], dir) else {
            return "gate did not run (could not list what the attempt changed)"
        }
        for path in changed.split(separator: "\n").map(String.init) where gate.contains(path) {
            if (try? await host.git(["cat-file", "-e", "\(before):\(path)"], in: dir))?.status == 0 {
                return "a tentativa alterou «\(path)», que o portão executa"
            }
        }
        return nil
    }

    /// After the check or the gate ran: true when it moved HEAD off `judged` (a commit, a branch switch). With `reset`,
    /// the tree goes back to exactly `judged` on `on`: tracked files restored, the untracked files it created (those
    /// not in `loose`) removed. Ignored files (build output) stay.
    private func settle(_ judged: String, on: String, loose: Set<String>, reset: Bool, _ dir: URL) async -> Bool {
        let head = await out(["rev-parse", "HEAD"], dir), ref = await out(["rev-parse", "--abbrev-ref", "HEAD"], dir)
        let moved = head != judged || ref != on
        guard reset else { return moved }
        if ref != on { _ = try? await host.git(["checkout", "-q", "-f", on == "HEAD" ? judged : on], in: dir) }
        _ = try? await host.git(["reset", "-q", "--hard", judged], in: dir)
        let made = await untracked(dir).filter { !loose.contains($0) }
        // ponytail: one git call, so a check that leaves tens of thousands of untracked files passes ARG_MAX; chunk then
        if !made.isEmpty { _ = try? await host.git(["--literal-pathspecs", "clean", "-q", "-f", "--"] + made, in: dir) }
        return moved
    }

    /// Untracked files that are not ignored.
    private func untracked(_ dir: URL) async -> [String] {
        (await out(["ls-files", "-z", "--others", "--exclude-standard"], dir) ?? "").split(separator: "\0").map(String.init)
    }

    /// A failed attempt's work goes to `patchDir/<task>-<n>.patch`; the tree goes back to `before` on `branch`.
    private func discard(_ work: UUID, _ task: String, _ n: Int, before: String, branch: String, keep: [String], _ dir: URL) async {
        _ = try? await host.git(["add", "-A"], in: dir)
        if !keep.isEmpty { _ = try? await host.git(["reset", "-q", "--"] + keep, in: dir) }
        // ponytail: the patch is the first 1 MiB of the diff (BoundedProcess's cap)
        if let d = try? await host.git(["diff", "--cached", "--binary", before], in: dir), d.status == 0 {
            let folder = host.patchDir(work)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? d.stdoutData.write(to: folder.appendingPathComponent("\(task)-\(n).patch"))
        }
        _ = try? await host.git(["checkout", "-q", "-f", branch == "HEAD" ? before : branch], in: dir)
        _ = try? await host.git(["reset", "-q", "--hard", before], in: dir)
    }

    private func out(_ args: [String], _ dir: URL) async -> String? {
        guard let r = try? await host.git(args, in: dir), r.status == 0 else { return nil }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func endJob(_ w: inout Work, _ id: String, _ result: String, at: Date) {
        guard let j = w.jobs.firstIndex(where: { $0.id == id && $0.state == .running }) else { return }
        w.jobs[j].state = .finished; w.jobs[j].endedAt = at; w.jobs[j].result = String(result.prefix(280))
    }

    /// One of the evidence's `commits`, from a `git log --format="%h %s"` line: the subject is the agent's text, so it
    /// loses its ANSI sequences and its control and format characters (`RerailText.plain`) and is cut at
    /// `evidenceSubject` characters (`Character`s, not bytes).
    static func evidenceCommit(_ line: String) -> String {
        let p = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let subject = RerailText.plain(ANSI.strip(p.count > 1 ? String(p[1]) : "")).trimmingCharacters(in: .whitespaces)
        return subject.isEmpty ? String(p[0]) : "\(p[0]) \(subject.prefix(evidenceSubject))"
    }

    /// The evidence's `checkTail`: the last `evidenceLines` lines of the check's output, then the gate's (if any),
    /// without ANSI sequences or control and format characters (`RerailText.plain`, line by line), secrets hidden
    /// (LotBoards.scrub's known shapes), the last `evidenceChars` characters.
    static func evidenceTail(check: String, gate: String?) -> String {
        let tails = [check, gate ?? ""].map {
            ANSI.strip($0).trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false)
                .suffix(evidenceLines).map { RerailText.plain(String($0)) }.joined(separator: "\n")
        }.filter { !$0.isEmpty }
        return String(LotBoards.scrub(tails.joined(separator: "\n")).suffix(evidenceChars))
    }

    /// Why `what` (the check, the gate) did not pass, from its exit status (nil: it timed out); nil = it passed.
    static func failure(_ what: String, _ status: Int32?) -> String? {
        guard let status else { return "\(what) timed out" }
        return status == 0 ? nil : "\(what) failed (exit \(status))"
    }

    /// nil = pass, else the reasons joined by `; `. `gate`: the gate's `failure` (nil: it passed, did not run or there is none).
    static func verdict(checkStatus: Int32?, gate: String? = nil, committed: Bool, dirty: Bool) -> String? {
        var r = [failure("check", checkStatus), gate].compactMap { $0 }
        if !committed { r.append("no new commit") }
        if dirty { r.append("tracked files left dirty") }
        return r.isEmpty ? nil : r.joined(separator: "; ")
    }

    /// The attempt's prompt, in the owner's language.
    static func prompt(task: WorkTask, spec: String?, attempt: Int, tries: Int, dir: URL, notes: [WorkNote], gate: String? = nil, map: String? = nil) -> String {
        var lines = [
            "Tarefa \"\(task.title)\", tentativa \(attempt) de \(tries), num laço autônomo: ninguém vai responder perguntas, então decida e registre a decisão no commit.",
            "Trabalhe só em \(dir.path). Faça só esta tarefa. Não faça push nem land.",
            "Faça commit assim que código e testes estiverem escritos, ANTES de rodar build ou teste: sem commit novo a tarefa não conta. Se depois corrigir algo, faça outro commit. Não deixe arquivo modificado sem commit.",
            "Depois do seu turno, o laço roda este comando em \(dir.path) e só ele decide se a tarefa passou:",
            task.check ?? "",
        ]
        if let gate { lines += ["e depois este portão:", gate] }
        if let map { lines.append("O mapa de funcionalidades do projeto está em \(map): use os nomes dele.") }
        if !notes.isEmpty { lines.append("O que falhou nas tentativas anteriores:"); lines += notes.map(\.text) }
        lines.append("")
        lines.append(spec ?? task.title)
        return lines.joined(separator: "\n")
    }
}
