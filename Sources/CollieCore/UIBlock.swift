import Foundation

/// A ```collie-ui fence in an assistant reply (Generative UI, v1): one of a closed set of kinds the app draws natively.
/// The reply is untrusted data: bad JSON, an unknown kind or a bad shape is never a block — it stays code.
public enum UIBlock: Equatable, Sendable {
    public struct Task: Equatable, Sendable { public var text: String; public var done: Bool }
    public struct Pair: Equatable, Sendable { public var key: String; public var value: String }
    public enum ChartType: String, Sendable { case bar, line }

    case table(title: String?, columns: [String], rows: [[String]])
    case diff(title: String?, old: String?, new: String)
    case tasks(title: String?, items: [Task])
    case status(title: String?, items: [Pair])
    case form(title: String?, question: String?, choices: [String])
    case chart(title: String?, type: ChartType, labels: [String], values: [Double])

    public var title: String? {
        switch self {
        case .table(let t, _, _), .diff(let t, _, _), .tasks(let t, _), .status(let t, _), .form(let t, _, _), .chart(let t, _, _, _): t
        }
    }
    public var kind: String {
        switch self {
        case .table: "table"
        case .diff: "diff"
        case .tasks: "tasks"
        case .status: "status"
        case .form: "form"
        case .chart: "chart"
        }
    }

    // ponytail: caps keep a hostile reply from building a huge view; over a cap = not a block (shown as code)
    static let maxJSON = 64 * 1024, maxCols = 20, maxRows = 200, maxItems = 100, maxChoices = 12, maxPoints = 500, maxCell = 500

    public static func parse(_ json: String) -> UIBlock? {
        guard json.utf8.count <= maxJSON, let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let kind = o["kind"] as? String else { return nil }
        let title = str(o["title"])
        switch kind {
        case "table":
            guard let cols = strings(o["columns"], max: maxCols), !cols.isEmpty, let raw = o["rows"] as? [Any], raw.count <= maxRows else { return nil }
            var rows: [[String]] = []
            for r in raw { guard let cells = strings(r, max: maxCols) else { return nil }; rows.append(cells) }
            return .table(title: title, columns: cols, rows: rows)
        case "diff":
            guard let new = str(o["new"]) else { return nil }
            return .diff(title: title, old: str(o["old"]), new: new)
        case "tasks":
            guard let raw = o["items"] as? [Any], raw.count <= maxItems else { return nil }
            var items: [Task] = []
            for i in raw {
                if let s = i as? String { items.append(Task(text: cap(s), done: false)) }
                else if let d = i as? [String: Any], let t = str(d["text"]) { items.append(Task(text: t, done: d["done"] as? Bool ?? false)) }
                else { return nil }
            }
            return .tasks(title: title, items: items)
        case "status":
            guard let raw = o["items"] as? [Any], raw.count <= maxItems else { return nil }
            var items: [Pair] = []
            for i in raw {
                if let d = i as? [String: Any], let k = str(d["key"]), let v = str(d["value"]) { items.append(Pair(key: k, value: v)) }
                else if let a = i as? [Any], a.count == 2, let k = str(a[0]), let v = str(a[1]) { items.append(Pair(key: k, value: v)) }
                else { return nil }
            }
            return .status(title: title, items: items)
        case "form":
            guard let choices = strings(o["choices"], max: maxChoices), choices.count >= 2 else { return nil }
            return .form(title: title, question: str(o["question"]), choices: choices)
        case "chart":
            guard let rawValues = o["values"] as? [Any], !rawValues.isEmpty, rawValues.count <= maxPoints else { return nil }
            let values = rawValues.compactMap { v -> Double? in
                guard let n = v as? NSNumber, n !== kCFBooleanTrue, n !== kCFBooleanFalse, n.doubleValue.isFinite else { return nil }
                return n.doubleValue
            }
            guard values.count == rawValues.count else { return nil }
            let labels = o["labels"] == nil ? (1...values.count).map(String.init) : strings(o["labels"], max: maxPoints)
            guard let labels, labels.count == values.count else { return nil }
            let type = ChartType(rawValue: (o["type"] as? String) ?? "bar") ?? .bar
            return .chart(title: title, type: type, labels: labels, values: values)
        default: return nil
        }
    }

    private static func cap(_ s: String) -> String { s.count > maxCell ? String(s.prefix(maxCell)) + "…" : s }
    /// A string or a number (cells are text); nothing else.
    private static func str(_ v: Any?) -> String? {
        if let s = v as? String { return cap(s) }
        if let n = v as? NSNumber, n !== kCFBooleanTrue, n !== kCFBooleanFalse { return cap(n.stringValue) }
        return nil
    }
    private static func strings(_ v: Any?, max: Int) -> [String]? {
        guard let a = v as? [Any], a.count <= max else { return nil }
        let s = a.compactMap(str)
        return s.count == a.count ? s : nil
    }
}

/// An assistant reply cut at its collie-ui fences.
public enum ChatSegment: Equatable, Sendable {
    case text(String)
    case ui(UIBlock, json: String)
    case code(String)   // a collie-ui fence that is not a valid block: its body, as code

    public static func split(_ text: String) -> [ChatSegment] {
        guard text.contains("```collie-ui") else { return [.text(text)] }
        var out: [ChatSegment] = [], buf: [Substring] = [], held: [Substring] = [], body: [Substring] = [], inside = false
        func flush() { let t = buf.joined(separator: "\n"); if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.text(t)) }; buf = [] }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inside, trimmed == "```collie-ui" { held = buf; buf = []; inside = true; body = [] }
            else if inside, trimmed == "```" {
                let json = body.joined(separator: "\n")
                let after = buf; buf = held; flush(); buf = after
                out.append(UIBlock.parse(json).map { .ui($0, json: json) } ?? .code(json)); inside = false
            } else if inside { body.append(line) } else { buf.append(line) }
        }
        if inside { buf = held + ["```collie-ui"] + body }   // never closed (cut off): plain text
        flush()
        return out
    }
}
