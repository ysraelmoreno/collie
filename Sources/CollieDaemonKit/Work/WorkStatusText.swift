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
                    lines.append("- \(j.kind == .shell ? "shell" : j.kind == .loop ? "tentativa do laço" : "subagente") \(j.label) — \(name(w.terminalId)), há \(mins(j.startedAt)) min")
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
            return "em laço: \(title) (tentativa \(l.attempt)/\(l.tries))" + (l.phase.map { " · \($0.label)" } ?? "")
                + (now.flatMap { times(l, now: $0, timeZone: timeZone) }.map { " · \($0)" } ?? "")
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

    /// What `work wait` prints: the loop's line of `work status` (a work without a loop: its title), then the version
    /// to wait from and how the wait ended.
    static func waitLine(_ w: Work, version: Int, timedOut: Bool, now: Date, timeZone: TimeZone = .current) -> String {
        let ended = w.loop.map { $0.state != .running } ?? false
        return (loopLine(w, now: now, timeZone: timeZone) ?? "sem laço: \(RerailText.clean(w.title))")
            + "\nversão \(version)" + (ended ? " · laço terminou (ended)" : timedOut ? " · tempo esgotado sem mudança (timedOut)" : "")
    }

    /// A loop with a gate (`work run --gate`): "portão: <command>", on one line. nil: no loop, or one without a gate.
    public static func gateLine(_ w: Work) -> String? {
        w.loop?.gate.map { "portão: " + RerailText.clean($0, max: CommandRouter.loopCardMax) }
    }

    /// The last `last` events of a loop's journal, oldest first, one per line: `HH:mm:ss <kind> T<task>#<attempt> <detail>`
    /// (the daemon's local time; a loop-wide event has no `T…`). Empty: no journal.
    public static func events(_ loop: WorkLoopState, last: Int, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "HH:mm:ss"
        return (loop.events ?? []).suffix(max(0, last)).map { e in
            let who = e.task.map { "T" + RerailText.clean($0, max: 40) + (e.attempt.map { "#\($0)" } ?? "") }
            return ([f.string(from: e.at), e.kind.rawValue] + [who, e.detail.map { RerailText.clean($0, max: LoopEvent.detailMax) }].compactMap { $0 })
                .joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// The numbers of the tasks a loop ran (`LoopStats.line`). nil: no loop ran a task of this work.
    public static func statsLine(_ w: Work) -> String? { LoopStats(work: w)?.line }

    /// A done task the loop approved: "✓ <title> · tentativa n · k commits · <shortstat>". nil: it has no evidence.
    public static func doneLine(_ t: WorkTask) -> String? {
        t.evidence.map { "✓ \(RerailText.clean(t.title)) · \($0.summary)" }
    }

    /// The line the starter gets when one task of its loop ends: a done one with its evidence (none: marked by hand), a
    /// deferred one with the reason. Counts and git's shortstat only, never a commit subject or the check's output.
    static func taskEnded(_ t: WorkTask) -> String {
        let line = t.state == .deferred
            ? "– \(RerailText.clean(t.title)) · adiada: \(RerailText.clean(t.reason ?? t.lastFailure ?? "sem razão registrada", max: 200))"
            : doneLine(t) ?? "✓ \(RerailText.clean(t.title)) · marcada à mão, sem check"
        return "[collie] Laço, tarefa terminada: \(line)"
    }

    /// The line the starter gets when its loop ends (a stopped one: "parou (<why>)"), then one line per task of the loop: a done one with its evidence
    /// (one without it was marked by hand, no check judged it: it counts as done and says so), a deferred one with the
    /// reason. At most `RerailText.limit` characters (the cut ends with "… e mais <n>").
    /// Only counts and git's shortstat go beside the agent's titles: never a commit subject or the check's output.
    static func loopEnded(_ w: Work) -> String {
        let ran = w.tasks.filter { t in w.loop?.tasks?.contains(t.id) ?? true }
        let done = ran.filter { $0.state == .done }, deferred = ran.filter { $0.state == .deferred }
        let how = w.loop?.stopReason.map { "parou (\(RerailText.clean($0.label)))" } ?? "terminou"
        var lines = ["[collie] Laço de \"\(RerailText.clean(w.title))\" \(how): \(done.count) feitas, \(deferred.count) adiadas. Veja: collie work status"]
        lines += done.map { doneLine($0) ?? "✓ \(RerailText.clean($0.title)) · marcada à mão, sem check" }
        lines += deferred.map { "– \(RerailText.clean($0.title)) · adiada: \(RerailText.clean($0.reason ?? $0.lastFailure ?? "sem razão registrada", max: 200))" }
        return bounded(lines, limit: RerailText.limit)
    }

    /// What the starter gets when its loop starts without the owner's card (a paddock trusted for loops): the limits,
    /// then one line per task with its check. At most `RerailText.limit` characters (the cut ends with "… e mais <n>").
    static func loopTrusted(paddock: String, _ tasks: [WorkTask], _ l: WorkLoopState) -> String {
        var lines = ["[collie] Laço iniciado sem cartão (cercado «\(RerailText.clean(paddock))» é confiável): "
            + "\(tasks.count) \(tasks.count == 1 ? "tarefa" : "tarefas"), --max \(l.max ?? 0), orçamento \(l.budget ?? 0) s. Parar: collie work stop."]
        lines += tasks.enumerated().map { "#\($0 + 1) «\(RerailText.clean($1.title))» check «\(RerailText.clean($1.check ?? "", max: 200))»" }
        return bounded(lines, limit: RerailText.limit)
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
