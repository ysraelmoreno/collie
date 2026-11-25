import Foundation
import CollieCore

/// F1: the same failure in 2 or more attempts of a work (one task or several) is a candidate trap (armadilha) for the
/// owner to decide on. Read only from the loop's own failure notes (`[loop <task>] <title>, tentativa n/t: <reason>
/// (agente <name>)` and the output's tail under it, already scrubbed when written), never from an agent's raw screen.
/// Nothing is saved to memory: the summary only shows the candidate and the command the owner may run.
enum TrapCandidates {
    static let max = 5
    static let signatureMax = 160

    struct Candidate: Equatable {
        var signature: String
        var count: Int
        var tasks: [String]
    }

    /// A failing line as a signature: paths (any word with a `/`) become `<path>`, digits `#` (times, counts, lines),
    /// whitespace one space.
    static func normalize(_ line: String) -> String {
        let s = RerailText.clean(line, max: 400)
            .replacing(/\S*\/\S*/, with: "<path>")
            .replacing(/\d+/, with: "#")
            .replacing(/\s+/, with: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(s.prefix(signatureMax))
    }

    /// The signatures of one failure note (each once): `check: <first error line>` / `gate: ...` for a failed or timed
    /// out check or gate, `veto [persona] <file>` for each persona's vetoed file. Empty: not a loop failure note, or a
    /// failure of another kind (no commit, summon...).
    static func signatures(_ note: String) -> (task: String, sigs: [String])? {
        let lines = note.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let head = lines.first, head.hasPrefix("[loop "), let close = head.range(of: "] "),
              let m = head.firstMatch(of: /, tentativa \d+\/\d+: (.*) \(agente [^()]*\)$/) else { return nil }
        let task = String(head[head.index(head.startIndex, offsetBy: 6)..<close.lowerBound])
        let reason = String(m.1)
        var sigs: [String] = []
        // the check or the gate: its first error line (else its first line) of the tail
        let tail = lines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let first = tail.first { $0.contains(/(?i)error|erro|fail|falh|fatal/) } ?? tail.first
        for what in ["check", "gate"] where reason.contains("\(what) failed") || reason.contains("\(what) timed out") {
            sigs.append("\(what): " + (first.map(normalize) ?? normalize(reason)))
        }
        // the review's vetoes: "revisor recusou: [p] file:line claim; file:line claim | [q] ..."
        if let r = reason.range(of: "revisor recusou: ") {
            for veto in reason[r.upperBound...].components(separatedBy: " | ") {
                guard let pm = veto.firstMatch(of: /^\[([^\]]+)\] (.*)$/) else { continue }
                for finding in pm.2.components(separatedBy: "; ") {
                    let file = finding.prefix { $0 != " " && $0 != ":" }
                    if !file.isEmpty, file.contains(where: { $0 == "/" || $0 == "." }) {
                        sigs.append("veto [\(RerailText.clean(String(pm.1), max: 40))] \(RerailText.clean(String(file), max: 120))")
                    }
                }
            }
        }
        var seen: Set<String> = []
        return (task, sigs.filter { seen.insert($0).inserted })
    }

    /// The candidates of `w`: signatures seen in 2+ failure notes, most seen first (ties: first seen), at most `max`.
    static func find(_ w: Work) -> [Candidate] {
        var order: [String] = [], count: [String: Int] = [:], tasks: [String: [String]] = [:]
        for n in w.notes {
            guard let (task, sigs) = signatures(n.text) else { continue }
            let title = w.tasks.first { $0.id == task }.map { RerailText.clean($0.title, max: 80) } ?? task
            for s in sigs {
                if count[s] == nil { order.append(s) }
                count[s, default: 0] += 1
                if !(tasks[s] ?? []).contains(title) { tasks[s, default: []].append(title) }
            }
        }
        return order.filter { count[$0]! >= 2 }.enumerated()
            .sorted { (count[$0.1]!, -$0.0) > (count[$1.1]!, -$1.0) }
            .prefix(max).map { Candidate(signature: $0.1, count: count[$0.1]!, tasks: tasks[$0.1]!) }
    }

    /// The summary's section, each line through `LotBoards.scrub`; empty with no repeated failure.
    static func section(_ w: Work, secrets: Set<String> = []) -> [String] {
        let found = find(w)
        guard !found.isEmpty else { return [] }
        var l = ["", "## Armadilhas candidatas", ""]
        for c in found {
            // scrubbed BEFORE the slug (it drops the `=` the scrub looks for); quoted for the shell: no quote left in the title
            let sig = LotBoards.scrub(c.signature, secrets: secrets)
            let title = sig.replacing(/['`]/, with: "")
            let slug = String(sig.lowercased().replacing(/[^a-z0-9]+/, with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(48))
            l.append("- \(sig): \(c.count) vezes, tarefas: \(c.tasks.joined(separator: "; "))")
            l.append("  - para registrar (texto, nunca executado): `collie memory save --kind pitfall --subject 'trap-\(slug)' --title '\(title)'`")
        }
        return l.map { LotBoards.scrub($0, secrets: secrets) }
    }
}
