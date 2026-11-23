import Foundation

/// U5: the generic ratchet, "the number may only go down" (spec 2026-11-23-fabrica-para-usuarios-design.md, fabrica/u5-catraca.md).
/// Pure: no file, no clock, no process. `collie factory ratchet` (CollieDaemonKit/FactoryCommands.swift) measures and writes.
public enum Ratchet {
    public static let maxReason = 200

    public enum Refusal: Error, Sendable, Equatable {
        /// line number (1-based) and the line, cut
        case badLine(Int, String)
        case duplicate(String)
        case badReason
    }

    /// Key (whitespace-separated fields, joined by one space; `rule path`) -> count >= 0. A zero count is the same as absent.
    public struct Baseline: Sendable, Equatable {
        public private(set) var counts: [String: Int]
        public init(_ counts: [String: Int] = [:]) { self.counts = counts.filter { $0.value > 0 } }

        /// Lines `<key fields...> <n>`: the last field is the number. Blank lines and `#` comments are ignored.
        public static func parse(_ text: String) throws(Refusal) -> Baseline {
            var out: [String: Int] = [:]
            for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count >= 2, let n = Int(fields[fields.count - 1]), n >= 0,
                      !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\t" })
                else { throw .badLine(i + 1, String(line.prefix(120))) }
                let key = fields.dropLast().joined(separator: " ")
                guard out[key] == nil else { throw .duplicate(key) }
                out[key] = n
            }
            return Baseline(out)
        }

        /// Sorted by key, one `<key> <n>` per line, zeros left out; parse(render()) == self.
        public func render() -> String {
            counts.keys.sorted().map { "\($0) \(counts[$0]!)\n" }.joined()
        }
    }

    public struct Change: Sendable, Equatable {
        public var key: String, before: Int, after: Int
        public init(key: String, before: Int, after: Int) { self.key = key; self.before = before; self.after = after }
    }

    public enum Verdict: Sendable, Equatable {
        case same
        /// something went down or left: the baseline should be lowered (`update`)
        case improved([Change])
        /// a new key or a bigger number; wins over `improved` and lists only what went up
        case worse([Change])
    }

    public static func compare(baseline: Baseline, current: Baseline) -> Verdict {
        var up: [Change] = [], down: [Change] = []
        for k in Set(baseline.counts.keys).union(current.counts.keys).sorted() {
            let b = baseline.counts[k] ?? 0, c = current.counts[k] ?? 0
            if c > b { up.append(Change(key: k, before: b, after: c)) } else if c < b { down.append(Change(key: k, before: b, after: c)) }
        }
        if !up.isEmpty { return .worse(up) }
        return down.isEmpty ? .same : .improved(down)
    }

    /// The new baseline when nothing went up (then it is `current`); nil when something did: never raised without a reason.
    public static func lowered(baseline: Baseline, current: Baseline) -> Baseline? {
        if case .worse = compare(baseline: baseline, current: current) { return nil }
        return current
    }

    public struct Raised: Sendable, Equatable {
        public var baseline: Baseline
        /// `# <ISO date>: <key> <before> -> <after>: <reason>`, one per key that went up
        public var log: [String]
    }

    /// Raise to `current` with a reason (non-empty, at most 200 characters, no control character). `date` comes in: pure.
    public static func raise(baseline: Baseline, to current: Baseline, reason: String, date: Date) throws(Refusal) -> Raised {
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty, r.count <= maxReason, !r.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw .badReason }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
        let day = f.string(from: date)
        var log: [String] = []
        if case .worse(let up) = compare(baseline: baseline, current: current) {
            log = up.map { "# \(day): \($0.key) \($0.before) -> \($0.after): \(r)" }
        }
        return Raised(baseline: current, log: log)
    }

    /// List mode (`ci-skip`): the list may only shrink; a new item is worse. Each item counts as 1.
    public static func compareList(baseline: [String], current: [String]) -> Verdict {
        func counts(_ l: [String]) -> Baseline { Baseline(l.reduce(into: [:]) { $0[$1, default: 0] += 1 }) }
        return compare(baseline: counts(baseline), current: counts(current))
    }
}
