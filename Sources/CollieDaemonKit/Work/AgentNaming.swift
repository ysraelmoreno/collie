import Foundation
import CollieProtocol

/// M3.8: the name of an attempt's terminal, from what it works on: `<work>-<task>-t<n>`, or
/// `<work>-<task>-f<lane>-t<n>` in a lane. Pure. The titles are the owner's or an agent's text: data, never an
/// instruction, so the name is made only of `[a-z0-9-]`, never starts or ends with `-` and is at most `max` long.
/// No one recognises a loop's agent by this name: the terminal's id is on its job (`WorkJob.terminal`).
enum AgentNaming {
    static let max = 48, part = 18, shortId = 8
    static let noWork = "trabalho", noTask = "tarefa"

    /// F2 X4: a loop reviewer's name ends in `reviewerTail` (then, maybe, what `unique` added); F2 Y1: its folder is
    /// in `WorkLoop.reviewRoot`, `reviewDir` in the daemon's root (`WorkLoop.reviewScratch`). Both together tell an
    /// orphan reviewer, one a fallen daemon left, from any terminal of the owner's.
    static let reviewerTail = "-rev", reviewDir = "collie-review"

    /// `<agent>-<persona>-rev`, cut to `max` from the agent's name (the persona and the tail stay).
    static func reviewer(_ agent: String, persona: String) -> String {
        let tail = "-" + slug(persona) + reviewerTail
        return trim(String(agent.prefix(Swift.max(0, max - tail.count)))) + tail
    }

    static func isReviewer(name: String, cwd: String, reviewRoot: URL) -> Bool {
        let root = SignedAppCheck.realPath(reviewRoot)
        return name.range(of: reviewerTail + #"(-[a-z0-9]{1,8})?$"#, options: .regularExpression) != nil
            && URL(fileURLWithPath: cwd).deletingLastPathComponent().path == root   // `cwd`: a real path (`summon`)
    }

    static func name(work: String, task: String, taskId: String, attempt: Int, lane: Int?) -> String {
        let w = cut(slug(work)), t = cut(slug(task))
        let head = (w.isEmpty ? noWork : w) + "-" + (t.isEmpty ? short(taskId) : t)
        return fit(head, (lane.map { "-f\(Swift.max(0, $0))" } ?? "") + "-t\(Swift.max(0, attempt))")
    }

    /// `name`, or the first of `name-2` … `name-9`, then `name-<the task's short id>`, that no live terminal (or panel)
    /// has: `taken`, compared without case, as `summon` does.
    // ponytail: past the short id nothing else is tried: the summon then refuses the name and the attempt fails with why
    static func unique(_ name: String, taskId: String, taken: Set<String>) -> String {
        let used = Set(taken.map { $0.lowercased() })
        guard used.contains(name) else { return name }
        // over `max`, the titles give way: the name keeps its own tail (`-f<lane>-t<n>`) before what is added
        let tail = name.range(of: #"(-f\d+)?-t\d+$"#, options: .regularExpression)?.lowerBound ?? name.endIndex
        func with(_ more: String) -> String { fit(String(name[..<tail]), name[tail...] + more) }
        for i in 2...9 where !used.contains(with("-\(i)")) { return with("-\(i)") }
        return with("-" + short(taskId))
    }

    /// M3b.6: summons (`go`) with the first name `unique` gives over `taken`. `taken` is read before the summon: a
    /// terminal (or panel) born meanwhile makes the summon refuse the name, and the next one is tried, up to the last
    /// `unique` gives (the short id). Any other refusal, or the last name refused, is the summon's error.
    static func summon(_ name: String, taskId: String, taken: Set<String>,
                       _ go: (String) async throws(ProtocolError) -> UUID) async throws(ProtocolError) -> UUID {
        var taken = Set(taken.map { $0.lowercased() }), last: ProtocolError?
        while true {
            let next = unique(name, taskId: taskId, taken: taken)
            if let last, taken.contains(next) { throw last }
            do { return try await go(next) } catch {
                guard refusedAsTaken(error, next) else { throw error }
                last = error; taken.insert(next)
            }
        }
    }

    /// M3b.6: the summon refused `name` because a terminal or panel has it, or one is being launched with it.
    // ponytail: told by the summon's own text (`ShepherdCommands`, `CommandRouter.reserve`); a code of its own if it moves
    static func refusedAsTaken(_ e: ProtocolError, _ name: String) -> Bool {
        e.code == .invalidArgs && e.message.lowercased().contains("'\(name)'")
            && ["already exists", "is the name of panel", "already being launched"].contains { e.message.contains($0) }
    }

    /// M11.3: the `.build/<dir>` a terminal in a shared folder is told to build in (`--scratch-path`). An attempt's
    /// terminal (`<work>-<task>[-f<lane>]-t<n>`) gets `laco-<work>-<task>[-f<lane>]`: the attempt is dropped, so attempt 2
    /// reuses attempt 1's build; the lane stays, so two live lanes never share a folder (SwiftPM's lock). Any other
    /// name is as before: its first `max` characters, anything not a letter or digit a `-`. Never a `/`, `..` or space.
    static func buildDir(_ terminal: String, max: Int) -> String {
        let plain = String(terminal.prefix(max).map { $0.isLetter || $0.isNumber ? $0 : "-" })
        guard let m = terminal.wholeMatch(of: #/([a-z0-9]+(?:-[a-z0-9]+)+?)(-f\d+)?-t\d+/#) else { return plain }
        let lane = String(m.2 ?? ""), head = "laco-" + m.1
        return trim(trim(String(head.prefix(Swift.max(0, max - lane.count)))) + lane)
    }

    /// Lowercase ASCII with no accents; anything out of `[a-z0-9]` is a `-`, runs of `-` are one, none at the ends.
    static func slug(_ s: String) -> String {
        let plain = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var out = ""
        for u in plain.lowercased().unicodeScalars {
            let ok = (u.value >= 0x61 && u.value <= 0x7A) || (u.value >= 0x30 && u.value <= 0x39)
            if ok { out.unicodeScalars.append(u) } else if !out.isEmpty, !out.hasSuffix("-") { out.append("-") }
        }
        return trim(out)
    }

    /// The task's id as a name's part: its first `shortId` characters, `noTask` when it has none to give.
    static func short(_ taskId: String) -> String {
        let s = trim(String(slug(taskId).prefix(shortId)))
        return s.isEmpty ? noTask : s
    }

    /// A slug cut to `part` characters: at its last `-` when the cut would fall inside a word.
    private static func cut(_ slug: String) -> String {
        guard slug.count > part else { return slug }
        let head = slug.prefix(part)
        let whole = slug[slug.index(slug.startIndex, offsetBy: part)] == "-"
        if !whole, let dash = head.lastIndex(of: "-") { return trim(String(head[..<dash])) }
        return trim(String(head))
    }

    /// `head` + `tail` in `max` characters: the head gives way, never the tail (it tells the attempts apart).
    private static func fit(_ head: String, _ tail: String) -> String {
        trim(trim(String(head.prefix(Swift.max(0, max - tail.count)))) + tail)
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
}
