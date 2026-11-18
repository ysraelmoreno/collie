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

    /// A work run by `collie work run`: "em laço: <task> (tentativa n/N)", or how its loop ended. nil: a sequential work.
    public static func loopLine(_ w: Work) -> String? {
        guard let l = w.loop else { return nil }
        switch l.state {
        case .running:
            let title = w.tasks.first { $0.id == l.task }.map { RerailText.clean($0.title) } ?? "?"
            return "em laço: \(title) (tentativa \(l.attempt)/\(l.tries))"
        case .stopped: return "laço parado (\(l.used) tentativas)"
        case .finished: return "laço terminou (\(l.used) tentativas)"
        }
    }

    /// A loop with a gate (`work run --gate`): "portão: <command>", on one line. nil: no loop, or one without a gate.
    public static func gateLine(_ w: Work) -> String? {
        w.loop?.gate.map { "portão: " + RerailText.clean($0, max: CommandRouter.loopCardMax) }
    }

    /// A done task the loop approved: "✓ <title> · tentativa n · k commits · <shortstat>". nil: it has no evidence.
    public static func doneLine(_ t: WorkTask) -> String? {
        t.evidence.map { "✓ \(RerailText.clean(t.title)) · \($0.summary)" }
    }

    /// The line the starter gets when its loop ends, then one line per task of the loop: a done one with its evidence
    /// (one without it was marked by hand, no check judged it: it counts as done and says so), a deferred one with the
    /// reason. At most `RerailText.limit` characters (the cut ends with "… e mais <n>").
    /// Only counts and git's shortstat go beside the agent's titles: never a commit subject or the check's output.
    static func loopEnded(_ w: Work) -> String {
        let ran = w.tasks.filter { t in w.loop?.tasks?.contains(t.id) ?? true }
        let done = ran.filter { $0.state == .done }, deferred = ran.filter { $0.state == .deferred }
        var lines = ["[collie] Laço de \"\(RerailText.clean(w.title))\" terminou: \(done.count) feitas, \(deferred.count) adiadas. Veja: collie work status"]
        lines += done.map { doneLine($0) ?? "✓ \(RerailText.clean($0.title)) · marcada à mão, sem check" }
        lines += deferred.map { "– \(RerailText.clean($0.title)) · adiada: \(RerailText.clean($0.reason ?? $0.lastFailure ?? "sem razão registrada", max: 200))" }
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
