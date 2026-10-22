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
                let floor = w.floorId.flatMap { names[$0] } ?? "térreo"
                lines.append("**\(w.title)** — \(name(w.terminalId)) (\(floor))")
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
                    lines.append("- \(j.kind == .shell ? "shell" : "subagente") \(j.label) — \(name(w.terminalId)), há \(mins(j.startedAt)) min")
                }
            }
            for id in sorted(.working) { lines.append("- \(name(id)): trabalhando") }
            if lines.isEmpty { return "Nada rodando agora." }
        }
        return bounded(lines)
    }

    /// Joins lines up to `limit` characters; the cut ends with "… e mais <n>".
    private static func bounded(_ lines: [String]) -> String {
        var out = ""
        for (i, l) in lines.enumerated() {
            let tail = "\n… e mais \(lines.count - i)"
            if out.count + l.count + 1 + tail.count > limit { return out + tail }
            out += (out.isEmpty ? "" : "\n") + l
        }
        return out
    }
}
