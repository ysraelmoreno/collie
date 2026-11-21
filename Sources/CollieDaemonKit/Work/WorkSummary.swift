import Foundation
import CollieCore

/// The loop's numbers for one work, from the tasks a loop ran (`tries != nil`): `ran` of them, `done` and `deferred`
/// by state, `firstTry` done with `tries == 1`, `meanTries` over the ran tasks (one decimal), `seconds` the sum of
/// the approved tasks' `evidence.seconds` (a task without evidence adds 0). nil: no loop ran a task of this work.
/// `reverted` and `unknown` stay 0 until `counted(work:git:)` asks git (only when a summary is asked for).
public struct LoopStats: Codable, Sendable, Equatable {
    public var ran: Int, done: Int, deferred: Int, firstTry: Int
    public var meanTries: Double
    public var seconds: Int
    /// Of the evidence's commits: `reverted` have a "This reverts commit <sha>" in the current branch; `unknown` no
    /// longer resolve (rebased away) or git could not say.
    public var reverted = 0, unknown = 0

    public init?(work w: Work) {
        let tasks = w.tasks.filter { $0.tries != nil }
        guard !tasks.isEmpty else { return nil }
        let finished = tasks.filter { $0.state == .done }
        ran = tasks.count; done = finished.count
        deferred = tasks.filter { $0.state == .deferred }.count
        firstTry = finished.filter { $0.tries == 1 }.count
        meanTries = (Double(tasks.reduce(0) { $0 + ($1.tries ?? 0) }) / Double(tasks.count) * 10).rounded() / 10
        seconds = tasks.reduce(0) { $0 + ($1.evidence?.seconds ?? 0) }
    }

    /// "laço: 5/6 feitas · 4 na 1ª · 1 adiada · média 1,4 tentativas · 2h10": decimal comma, short duration
    /// ("2h10", "12min", "40s").
    public var line: String {
        let h = seconds / 3600, m = seconds % 3600 / 60
        let time = h > 0 ? "\(h)h" + String(format: "%02d", m) : m > 0 ? "\(m)min" : "\(seconds)s"
        let mean = String(format: "%.1f", meanTries).replacingOccurrences(of: ".", with: ",")
        return "laço: \(done)/\(ran) feitas · \(firstTry) na 1ª · \(deferred) " + (deferred == 1 ? "adiada" : "adiadas")
            + " · média \(mean) tentativas · \(time)"
            + (reverted > 0 ? " · \(reverted) " + (reverted == 1 ? "revertido" : "revertidos") : "")
    }
}

/// Git for the reverts count (a fake in tests): `args`' trimmed stdout on exit 0, nil when git fails.
protocol RevertGit: Sendable {
    func out(_ args: [String]) async -> String?
}

extension LoopStats {
    /// The numbers with `reverted` and `unknown` counted: each commit of the loop's evidence ("<short sha> <subject>")
    /// is resolved to its full sha, then searched for in the current branch as "This reverts commit <full sha>".
    /// ponytail: a rebased commit still in the object store resolves and counts as not reverted; check ancestry
    /// (`merge-base --is-ancestor`) if that matters. Two git calls a commit: fine for a summary, not for a hot path.
    static func counted(work w: Work, git: any RevertGit) async -> LoopStats? {
        guard var s = LoopStats(work: w) else { return nil }
        var seen: Set<String> = []
        for c in w.tasks.filter({ $0.tries != nil }).flatMap({ $0.evidence?.commits ?? [] }) {
            let sha = String(c.prefix { $0 != " " })
            guard seen.insert(sha).inserted else { continue }
            // hex only: the registry's text never becomes a git option or a revision expression
            guard sha.count >= 4, sha.allSatisfy(\.isHexDigit),
                  let full = await git.out(["rev-parse", "--verify", "--quiet", sha + "^{commit}"]), !full.isEmpty,
                  let by = await git.out(["log", "--fixed-strings", "--grep", "This reverts commit " + full, "--format=%h", "-n", "1"])
            else { s.unknown += 1; continue }
            if !by.isEmpty { s.reverted += 1 }
        }
        return s
    }
}

/// What a work did, deferred and left undone, built only from the registry (no model, no tokens). Every title, note and
/// commit subject is agent text: `RerailText.clean` makes it one line without control or format characters.
public struct WorkSummary: Codable, Sendable, Equatable {
    public static let maxItems = 40
    public static let limit = 6_000

    public var title: String
    public var active: Bool
    public var closedBy: String?
    public var done: [String]
    public var later: [String]
    public var notDone: [String]
    public var stoppedAt: String?
    /// The loop's numbers; nil (and absent from the JSON and the markdown) for a work no loop ran.
    public var loop: LoopStats?
    /// M5.4: the work's token counts (all its tasks' attempts); nil for a work none were read for.
    public var tokens: TokenCount?

    // ponytail: `terminalAlive` is accepted for the interface but unused: job liveness is already in the job states
    // (`gone`/`unknown`, set by the sweeps); use it if a live terminal should downgrade `running` jobs.
    public static func make(_ w: Work, terminalAlive: Bool, now: Date, escape: Bool = true) -> WorkSummary {
        // `escape: false`: plain text for Memory (shown as plain text, so backslashes would be visible)
        func c(_ x: String) -> String { escape ? escaped(RerailText.clean(x)) : RerailText.clean(x) }   // agent text is literal, never markdown
        func titled(_ t: WorkTask, _ fallback: String? = nil) -> String {
            c(t.title) + (t.reason.map(c).flatMap { $0.isEmpty ? nil : " — " + $0 } ?? fallback.map { " — " + $0 } ?? "")
        }
        func jobs(_ s: JobState, _ what: String) -> [String] { w.jobs.filter { $0.state == s }.map { c($0.label) + " — " + what } }
        var done = w.tasks.filter { $0.state == .done }.map { c($0.title) } + w.commits.map(c)
        if w.closedBy == "merge" { done.append("Mergeado") }
        let later = w.tasks.filter { $0.state == .deferred }.map { titled($0) }
            + w.notes.filter(\.decision).map { "Decisão: " + c($0.text) }
        let notDone = w.tasks.filter { $0.state == .open || $0.state == .inProgress }.map { c($0.title) }
            + w.tasks.filter { $0.state == .abandoned }.map { c($0.title) + " — abandonada" + ($0.reason.map { ": " + c($0) } ?? "") }
            + jobs(.gone, "sumiu") + jobs(.unknown, "sem sinal")
        let stopped = w.tasks.filter { $0.state == .inProgress }.max { $0.updatedAt < $1.updatedAt }.map { c($0.title) }
            ?? w.notes.last.map { c($0.text) }
        return WorkSummary(title: c(w.title), active: w.closedAt == nil, closedBy: w.closedBy, done: done, later: later,
                           notDone: notDone, stoppedAt: stopped, loop: LoopStats(work: w), tokens: WorkStatusText.tokens(w))
    }

    /// Inline markdown characters backslash-escaped: the panel and the chat render markdown, and a task title must not
    /// become a link or bold text. The struct's fields hold the escaped text, so JSON and markdown agree.
    static func escaped(_ x: String) -> String {
        var out = ""
        // "://" and "www." too, and "@" gets a zero-width space: the parser would autolink them (and leave a stray backslash before the next escape)
        let chars = Array(x)
        for (i, ch) in chars.enumerated() {
            let www = ch == "." && i >= 3 && String(chars[(i - 3)..<i]).lowercased() == "www"
            if "\\`*_[]()<>~!#".contains(ch) || www || (ch == ":" && chars.dropFirst(i + 1).starts(with: "//")) { out.append("\\") }
            out.append(ch)
            if ch == "@" { out.append("\u{200B}") }   // no escape stops the email autolink; an invisible break does
        }
        return out
    }

    /// `boldTitle`: the title as a `**bold**` line (the chat) instead of a `##` heading (the panel drops that line).
    public func markdown(boldTitle: Bool = false) -> String {
        let sections = [("Feito", done), ("Para depois", later), (active ? "Em aberto" : "Não feito", notDone),
                        ("Onde parou", stoppedAt.map { [$0] } ?? [])]
        // ponytail: k items a section; over the limit, retry with fewer (k = 0 keeps only the counts)
        for k in [Self.maxItems, 20, 10, 5, 2, 1, 0] {
            var lines = [boldTitle ? "**\(title)**" : "## " + title] + (loop.map { ["", $0.line] } ?? [])
                + (tokens.map { ["tokens: " + $0.label] } ?? [])
            for (head, items) in sections where !items.isEmpty {
                lines += ["", "**\(head)**"] + items.prefix(k).map { "- " + $0 }
                if items.count > k { lines.append("- … e mais \(items.count - k)") }
            }
            let text = lines.joined(separator: "\n")
            if text.count <= Self.limit || k == 0 { return text }
        }
        return ""   // unreachable: k == 0 returns
    }
}
