import Foundation
import CollieCore

/// Markdown answers to status questions, built from the work registry (no tokens spent).
public enum WorkStatusText {
    static let limit = 4_000

    public static func answer(_ q: StatusQuestion, works: [Work], names: [UUID: String], badges: [UUID: StatusBadge], now: Date) -> String {
        func name(_ id: UUID) -> String { names[id] ?? "terminal" }
        func mins(_ d: Date) -> Int { max(0, Int(now.timeIntervalSince(d) / 60)) }
        // Dictionary order is random: sort so the same registry always reads the same.
        func sorted(_ want: StatusBadge) -> [UUID] {
            badges.filter { $0.value == want }.keys.sorted { (names[$0] ?? "", $0.uuidString) < (names[$1] ?? "", $1.uuidString) }
        }
        var lines: [String] = []
        switch q {
        case .summary:   // answered by WorkSummary in the chat; here only a fallback over the given works
            return works.isEmpty ? "Escolha um trabalho para ver o resumo." : works.map { WorkSummary.make($0, terminalAlive: true, now: now).markdown(boldTitle: true) }.joined(separator: "\n\n")
        case .whereAreWe:
            if works.isEmpty { return "Nenhum trabalho ativo." }
            for w in works {
                let paddock = w.paddockId.flatMap { names[$0] } ?? "pasto"
                lines.append("**\(w.title)** — \(name(w.terminalId)) (\(paddock))")
                func n(_ s: TaskState) -> Int { w.tasks.filter { $0.state == s }.count }
                lines.append("- \(n(.done)) feitas · \(n(.inProgress)) em andamento · \(n(.open)) abertas · \(n(.deferred)) para depois")
                if let t = w.tasks.first(where: { $0.state == .inProgress }) { lines.append("- Em andamento: \(t.title)") }
                let running = w.jobs.filter { $0.state == .running }.count
                if running > 0 { lines.append("- Jobs rodando: \(running)") }
            }
        case .whatIsStuck:
            for id in sorted(.attention) { lines.append("- \(name(id)): esperando você") }
            for w in works {
                for j in w.jobs {
                    if j.state == .gone { lines.append("- \(name(w.terminalId)): \(j.label) sumiu") }
                    // ponytail: WorkJob has no last-signal field; endedAt ?? startedAt approximates it
                    if j.state == .unknown { lines.append("- \(name(w.terminalId)): \(j.label) sem sinal há \(mins(j.endedAt ?? j.startedAt)) min") }
                }
                for t in w.tasks where t.state == .inProgress && mins(t.updatedAt) >= 30 {
                    lines.append("- \(name(w.terminalId)): \(t.title) sem mudança há \(mins(t.updatedAt)) min")
                }
            }
            if lines.isEmpty { return "Nada travado." }
        case .whatIsRunning:
            for w in works {
                for j in w.jobs where j.state == .running {
                    // M3.8: a loop's attempt is cited by its agent's name too (the job's id; `[a-z0-9-]` by construction)
                    let what = j.kind == .shell ? "shell" : j.kind == .loop ? "tentativa do laço \(RerailText.clean(j.id)):" : "subagente"
                    lines.append("- \(what) \(j.label) — \(name(w.terminalId)), há \(mins(j.startedAt)) min")
                }
            }
            for id in sorted(.working) { lines.append("- \(name(id)): trabalhando") }
            if lines.isEmpty { return "Nada rodando agora." }
        }
        return bounded(lines)
    }

    /// What the agent needs after a compaction (plain text, at most 1200 UTF-8 bytes): its work's open tasks and last 3 notes.
    /// The agent's own text, one line each (`RerailText.clean`).
    public static func recall(_ w: Work) -> String {
        let open = w.tasks.filter { $0.state == .open || $0.state == .inProgress }
        var lines = ["Seu trabalho ativo (Collie): \(RerailText.clean(w.title))"]
        if let l = loopLine(w) { lines.append("- " + l) }
        lines += open.map { "- \($0.state == .inProgress ? "em andamento" : "aberta"): \(RerailText.clean($0.title))" }
        lines += w.notes.suffix(3).map { "- nota: \(RerailText.clean($0.text))" }
        var out = ""
        for l in lines {
            let add = (out.isEmpty ? "" : "\n") + LotBoards.cut(l, bytes: 300)
            guard out.utf8.count + add.utf8.count <= 1_200 else { break }
            out += add
        }
        return out
    }

    /// A work run by `collie work run`: "em laço: <task> (tentativa n/N)", or how its loop ended (a stopped one with
    /// its `stopReason`'s label). nil: a sequential work. With `now` (`work status`, `work wait`), a running loop that
    /// knows when its phase began also says since when and, with the agent working, when the turn expires (`times`).
    public static func loopLine(_ w: Work, now: Date? = nil, timeZone: TimeZone = .current) -> String? {
        guard let l = w.loop else { return nil }
        switch l.state {
        case .running:
            let title = w.tasks.first { $0.id == l.task }.map { RerailText.clean($0.title) } ?? "?"
            // M3.8: with the agent working, its terminal's name (the attempt's job; only when a single attempt runs)
            let agents = w.jobs.filter { $0.kind == .loop && $0.state == .running }
            return "em laço: \(title) (tentativa \(l.attempt)/\(l.tries))" + (l.phase.map { " · \($0.label)" } ?? "")
                + (now.flatMap { times(l, now: $0, timeZone: timeZone) }.map { " · \($0)" } ?? "")
                + (l.phase == .agent && agents.count == 1 ? " · terminal \(RerailText.clean(agents[0].id))" : "")
        case .stopped: return "laço parado (\(l.used) tentativas)" + (l.stopReason.map { " · \(RerailText.clean($0.label))" } ?? "")
        case .finished: return "laço terminou (\(l.used) tentativas)"
        }
    }

    /// A running loop's phase in time: "desde 14:03 (4 min)" (the daemon's local time; whole minutes elapsed, rounded
    /// down) and, with the agent working, " · próximo limite: turno vence em 56 min" (the attempt's start plus the
    /// turn's `timeout`; minutes left, rounded up; past it: "turno vence agora"). nil: no phase, or no `phaseSince`.
    static func times(_ l: WorkLoopState, now: Date, timeZone: TimeZone = .current) -> String? {
        guard l.state == .running, let phase = l.phase, let since = l.phaseSince else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "HH:mm"
        let elapsed = max(0, now.timeIntervalSince(since))
        var out = "desde \(f.string(from: since)) (\(Int(elapsed / 60)) min)"
        if phase == .agent {
            let left = Double(l.timeout) - elapsed
            out += " · próximo limite: " + (left > 0 ? "turno vence em \(Int((left / 60).rounded(.up))) min" : "turno vence agora")
        }
        return out
    }

    /// M3.6, a running loop with lanes (`--parallel`): "N de M em paralelo", then one line per lane, oldest first:
    /// "faixa T<task> · <phase> · desde 14:03 (4 min)" (the daemon's local time; whole minutes, rounded down; no phase:
    /// "entre fases", which is also a lane being integrated with no gate). Empty: no lane, and `work status` reads as
    /// it always did.
    public static func laneLines(_ w: Work, now: Date, timeZone: TimeZone = .current) -> [String] {
        guard let l = w.loop, l.state == .running, let lanes = l.lanes, !lanes.isEmpty else { return [] }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "HH:mm"
        return ["\(lanes.count) de \(max(l.parallel ?? 1, lanes.count)) em paralelo"] + lanes.map {
            "faixa T\(RerailText.clean($0.task, max: 40)) · \($0.phase?.label ?? "entre fases") · "
                + "desde \(f.string(from: $0.since)) (\(Int(max(0, now.timeIntervalSince($0.since)) / 60)) min)"
        }
    }

    /// What `work wait` prints: the loop's line of `work status` (a work without a loop: its title) and its lanes'
    /// (`laneLines`), then the version to wait from and how the wait ended.
    static func waitLine(_ w: Work, version: Int, timedOut: Bool, now: Date, timeZone: TimeZone = .current) -> String {
        let ended = w.loop.map { $0.state != .running } ?? false
        return ([loopLine(w, now: now, timeZone: timeZone) ?? "sem laço: \(RerailText.clean(w.title))"]
                + laneLines(w, now: now, timeZone: timeZone)).joined(separator: "\n")
            + "\nversão \(version)" + (ended ? " · laço terminou (ended)" : timedOut ? " · tempo esgotado sem mudança (timedOut)" : "")
    }

    /// A loop with a gate (`work run --gate`): "portão: <command>", on one line. nil: no loop, or one without a gate.
    public static func gateLine(_ w: Work) -> String? {
        w.loop?.gate.map { "portão: " + RerailText.clean($0, max: CommandRouter.loopCardMax) }
    }

    /// M3c.4: a loop run with `--notify end`: "avisos: só no fim". nil: no loop, or one that notifies every task.
    /// M5.6: the model the loop's agents run on, when it has one (`--model` or the daemon's `loopModel`).
    public static func modelLine(_ w: Work) -> String? {
        // C3: with --escalate, the model of the attempt in course (the first until one starts)
        if let l = w.loop, let e = l.escalation(attempt: l.attempt), l.escalate != nil {
            return "modelo dos agentes: " + RerailText.clean("\(e.preset):\(e.model)", max: 64) + " (tentativa \(Swift.max(l.attempt, 1)); escalada: " + RerailText.clean(l.escalate?.joined(separator: ",") ?? "", max: 200) + ")"
        }
        return w.loop?.model.map { "modelo dos agentes: " + RerailText.clean($0, max: 64) }
    }
    /// F2 R1: "revisão: ligada, personas auto" (+ ", revisor <model>"); nil: review off.
    public static func reviewLine(_ w: Work) -> String? {
        guard let l = w.loop, l.review == true else { return nil }
        return "revisão: ligada, personas " + (l.personas.map { RerailText.clean($0.joined(separator: ", "), max: 200) } ?? "auto")
            + (l.reviewOnly.map { " (só " + RerailText.clean($0.joined(separator: ", "), max: 200) + ")" } ?? "")
            + (l.reviewThreshold.map { ", veto a partir de " + RerailText.clean($0, max: 10) } ?? "")
            + (l.reviewerModel.map { ", revisor " + RerailText.clean($0, max: 100) } ?? "")
    }
    /// A1: one short line per value the base's `factory` could set, saying where it came from ("revisão: perfil"), then
    /// the `destructive` warning. None: the base had no `factory` (the loop as before).
    public static func originLines(_ w: Work) -> [String] {
        guard let l = w.loop, let o = l.origins else { return [] }
        let lines = [("review", "revisão"), ("budget", "orçamento"), ("tries", "tentativas")].compactMap { k, label -> String? in
            // nit (B1): --no-review is "revisão: desligada", never "origem revisão: flag"
            if k == "review", o[k] == "flag", l.review != true { return "revisão: desligada (--no-review)" }
            return o[k].map { "origem \(label): " + RerailText.clean($0, max: 10) }
        } + (o["budgetCut"].map { ["orçamento do perfil (\(RerailText.clean($0, max: 10)) s) cortado para \(l.budget ?? 0) s, o teto do laço"] } ?? [])
        return lines + (l.destructive.map { ["aviso: factory.guardrails.destructive tem \($0) padrão(ões); ainda não bloqueia comando"] } ?? [])
    }
    /// F2 R1: " (agente codex, modelo x)" after a task with its own worker; "" without one.
    public static func workerLabel(_ t: WorkTask) -> String {
        let parts = [t.agent.map { "agente " + RerailText.clean($0, max: 20) }, t.model.map { "modelo " + RerailText.clean($0, max: 100) }].compactMap { $0 }
        return parts.isEmpty ? "" : " (" + parts.joined(separator: ", ") + ")"
    }
    public static func notifyLine(_ w: Work) -> String? { w.loop?.notify == .end ? "avisos: só no fim" : nil }

    /// The last `last` events of a loop's journal, oldest first, one per line: `HH:mm:ss <kind> T<task>#<attempt> [<lane>] <detail>`
    /// (the daemon's local time; a loop-wide event has no `T…`; `[<lane>]`, M3.6: only an event of a lane). Empty: no journal.
    public static func events(_ loop: WorkLoopState, last: Int, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "HH:mm:ss"
        return (loop.events ?? []).suffix(max(0, last)).map { e in
            let who = e.task.map { "T" + RerailText.clean($0, max: 40) + (e.attempt.map { "#\($0)" } ?? "") }
            let lane = e.lane.map { "[" + RerailText.clean($0, max: 60) + "]" }
            return ([f.string(from: e.at), e.kind.rawValue] + [who, lane, e.detail.map { RerailText.clean($0, max: LoopEvent.detailMax) }].compactMap { $0 })
                .joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// The numbers of the tasks a loop ran (`LoopStats.line`). nil: no loop ran a task of this work.
    public static func statsLine(_ w: Work) -> String? { LoopStats(work: w)?.line }

    /// M5.4: the sum of every task's counts (nil: no attempt's were read).
    public static func tokens(_ w: Work) -> TokenCount? {
        let ts = w.tasks.compactMap(\.tokens)
        return ts.isEmpty ? nil : ts.reduce(TokenCount(), +)
    }
    /// M5.4: "tokens: 1,2 M (índice relativo) · 14 msgs". nil: no counts.
    public static func tokensLine(_ w: Work) -> String? { tokens(w).map { "tokens: " + $0.label } }

    /// M5.4, `work usage`: each work (newest first) with its total, then its tasks that have counts. Counts and titles only.
    /// M10.3: from summaries (an open work's made on the spot, `closedAt` nil), so a closed one reads its file.
    public static func usage(_ works: [WorkArchive]) -> String {
        guard !works.isEmpty else { return "Nenhum trabalho neste cercado." }
        return works.map { w in
            ["\(RerailText.clean(w.title)) [\(w.id.prefix(8))] · \(w.closedAt == nil ? "ativo" : "fechado") · "
                + (WorkArchive.tokensLine(w.tokens) ?? "tokens: sem número")]
                + w.tasks.compactMap { t in t.tokens.map { "  - \(RerailText.clean(t.title)) [\(RerailText.clean(t.id, max: 40))]: tokens: \($0.label)" } }
        }.flatMap { $0 }.joined(separator: "\n")
    }

    /// A done task the loop approved: "✓ <title> · tentativa n · k commits · <shortstat>". nil: it has no evidence.
    public static func doneLine(_ t: WorkTask) -> String? {
        t.evidence.map { "✓ \(RerailText.clean(t.title)) · \($0.summary)" }
    }

    /// How both notices end (M2.4): the notice is a hint typed into a terminal and may not arrive; the state is what counts.
    static let stateHint = " · estado: collie work status"

    /// The line the starter gets when one task of its loop ends: a done one with its evidence (none: marked by hand), a
    /// deferred one with the reason. Counts and git's shortstat only, never a commit subject or the check's output.
    static func taskEnded(_ t: WorkTask) -> String {
        let line = t.state == .deferred
            ? "– \(RerailText.clean(t.title)) · adiada: \(RerailText.clean(t.reason ?? t.lastFailure ?? "sem razão registrada", max: 200))"
            : doneLine(t) ?? "✓ \(RerailText.clean(t.title)) · marcada à mão, sem check"
        return "[collie] Laço, tarefa terminada: \(line)" + stateHint
    }

    /// M5.1: the one line for the notices held inside the window (`LoopNotices`): "3 tarefas feitas · 1 adiada".
    static func noticeBatch(done: Int, deferred: Int) -> String {
        var parts: [String] = []
        if done > 0 { parts.append("\(done) \(done == 1 ? "tarefa feita" : "tarefas feitas")") }
        if deferred > 0 { parts.append("\(deferred) " + (done > 0 ? "" : deferred == 1 ? "tarefa " : "tarefas ") + (deferred == 1 ? "adiada" : "adiadas")) }
        return "[collie] Laço: " + parts.joined(separator: " · ") + stateHint
    }

    /// The line the starter gets when its loop ends (a stopped one: "parou (<why>)"; it ends with `stateHint`), then one line per task of the loop: a done one with its evidence
    /// (one without it was marked by hand, no check judged it: it counts as done and says so), a deferred one with the
    /// reason. At most `RerailText.limit` characters (the cut ends with "… e mais <n>").
    /// Only counts and git's shortstat go beside the agent's titles: never a commit subject or the check's output.
    static func loopEnded(_ w: Work) -> String {
        let ran = w.tasks.filter { t in w.loop?.tasks?.contains(t.id) ?? true }
        let done = ran.filter { $0.state == .done }, deferred = ran.filter { $0.state == .deferred }
        let how = w.loop?.stopReason.map { "parou (\(RerailText.clean($0.label)))" } ?? "terminou"
        var lines = ["[collie] Laço de \"\(RerailText.clean(w.title))\" \(how): \(done.count) feitas, \(deferred.count) adiadas." + stateHint]
        // A1 (reviewAdvisory): the tasks the review gave no opinion on
        let silent = ran.filter { $0.review?.hasPrefix("parecer: " + ReviewVerdict.reviewAdvisoryNone) == true }.count
        if silent > 0 { lines.append("parecer: \(silent) " + (silent == 1 ? "tarefa" : "tarefas") + " " + ReviewVerdict.reviewAdvisoryNone) }
        lines += done.map { doneLine($0) ?? "✓ \(RerailText.clean($0.title)) · marcada à mão, sem check" }
        lines += deferred.map { "– \(RerailText.clean($0.title)) · adiada: \(RerailText.clean($0.reason ?? $0.lastFailure ?? "sem razão registrada", max: 200))" }
        return bounded(lines, limit: RerailText.limit)
    }

    /// What the starter gets when its loop starts without the owner's card (a paddock trusted for loops): the limits
    /// (`--parallel` when over 1), then one line per task with its check. At most `RerailText.limit` characters (the cut ends with "… e mais <n>").
    /// `gateFromFile` (M13.2): the gate came from `collie-work.json`, not `--gate`: the first line names it and its source.
    /// B1: `profileReviewOff`: the profile asks for a review `--no-review` turned off. The review as it runs (its
    /// personas, the profile's "só", its threshold) is told here as on the card.
    static func loopTrusted(paddock: String, _ tasks: [WorkTask], _ l: WorkLoopState, gateFromFile: Bool = false, profileReviewOff: Bool = false) -> String {
        let gate = gateFromFile ? l.gate.map { ", portão (\(ProjectWorkConfig.fileName)) «\(RerailText.clean($0, max: 200))»" } ?? "" : ""
        var lines = ["[collie] Laço iniciado sem cartão (cercado «\(RerailText.clean(paddock))» é confiável): "
            + "\(tasks.count) \(tasks.count == 1 ? "tarefa" : "tarefas"), --max \(l.max ?? 0), "
            + (l.parallel.flatMap { $0 > 1 ? "--parallel \($0), " : nil } ?? "") + "orçamento \(l.budget ?? 0) s" + (l.notify == .end ? ", avisos: só no fim" : "") + gate
            + reviewText(l, profileReviewOff: profileReviewOff) + ". Parar: collie work stop."]
        lines += tasks.enumerated().map { "#\($0 + 1) «\(RerailText.clean($1.title))» check «\(RerailText.clean($1.check ?? "", max: 200))»" }
        return bounded(lines, limit: RerailText.limit)
    }

    /// ", revisão …" for the trusted notice; "" with no review and no profile review turned off.
    static func reviewText(_ l: WorkLoopState, profileReviewOff: Bool) -> String {
        let file = " (\(ProjectWorkConfig.fileName))"
        func names(_ xs: [String]) -> String { xs.map { "«" + RerailText.clean($0, max: 60) + "»" }.joined(separator: " ") }
        if l.review == true {
            let who: String = l.personas.map(names) ?? "auto"
            let only: String = l.reviewOnly.map { " (só " + names($0) + ")" } ?? ""
            let veto: String = l.reviewThreshold == "blocker" ? ", veto só por blocker" + file : ""
            return ", revisão por personas: " + who + only + veto
        }
        return profileReviewOff ? ", sem revisão: --no-review desliga a do perfil\(file)" : ""
    }

    /// Joins lines up to `limit` characters; the cut ends with "… e mais <n>".
    private static func bounded(_ lines: [String], limit: Int = limit) -> String {
        var out = ""
        for (i, l) in lines.enumerated() {
            let tail = "\n… e mais \(lines.count - i)"
            if out.count + l.count + 1 + tail.count > limit { return out + tail }
            out += (out.isEmpty ? "" : "\n") + l
        }
        return out
    }
}
