import Foundation

/// Pure contract between the agent hooks and plug-in helpers: the event a helper reads on stdin,
/// the verdict it prints, and what the Claude Code hooks say back. No process, no I/O.
/// Plug-in text is data: nothing here adds words of Collie's own beyond the `[plug-in <id>] ` prefix.
public enum PluginHooks {
    public enum Event: String, Sendable { case edit, stop }

    public struct Verdict: Equatable, Sendable {
        public var guide: String?
        public var block: String?
        public init(guide: String? = nil, block: String? = nil) { self.guide = guide; self.block = block }
    }

    static let maxInput = 64 * 1024
    static let perPlugin = 2000
    static let total = 4000
    static let writeTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    /// Files written by a PostToolUse payload, relative to `project`. Anything odd is `[]`.
    public static func editedFiles(toolPayload: Data, project: URL) -> [String] {
        guard toolPayload.count <= maxInput,
              let obj = (try? JSONSerialization.jsonObject(with: toolPayload)) as? [String: Any],
              let tool = obj["tool_name"] as? String, writeTools.contains(tool),
              let input = obj["tool_input"] as? [String: Any],
              let raw = (input["file_path"] as? String) ?? (input["notebook_path"] as? String),
              !raw.isEmpty else { return [] }
        let root = project.standardizedFileURL.resolvingSymlinksInPath()
        let file = (raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : root.appendingPathComponent(raw))
            .standardizedFileURL.resolvingSymlinksInPath()
        let base = root.pathComponents, parts = file.pathComponents
        guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return [] }
        return [parts.dropFirst(base.count).joined(separator: "/")]
    }

    /// The helper's stdin: one JSON object, keys sorted.
    public static func eventJSON(event: Event, project: URL, files: [String], agent: String, paddock: String) -> Data {
        let obj: [String: Any] = ["apiVersion": 1, "event": event.rawValue, "project": project.path,
                                  "files": files, "agent": agent, "paddock": paddock]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// The helper's stdout. `nil` = nothing to say (empty, `{}`, invalid, wrong types, oversized).
    public static func verdict(stdout: Data) -> Verdict? {
        guard !stdout.isEmpty, stdout.count <= maxInput,
              let obj = (try? JSONSerialization.jsonObject(with: stdout)) as? [String: Any] else { return nil }
        var v = Verdict()
        for key in ["guide", "block"] {
            guard let any = obj[key] else { continue }
            guard let s = any as? String else { return nil }
            let text = clean(s, limit: perPlugin)
            if key == "guide" { v.guide = text } else { v.block = text }
        }
        return v.guide == nil && v.block == nil ? nil : v
    }

    /// Joins verdicts in plug-in id order. `stop` drops guides; `edit` with any block yields a block.
    public static func merge(_ verdicts: [(plugin: String, Verdict)], event: Event) -> Verdict {
        let sorted = verdicts.sorted { $0.plugin < $1.plugin }
        func pieces(_ pick: (Verdict) -> String?) -> [String] {
            sorted.compactMap { e in pick(e.1).map { "[plug-in \(e.plugin)] \($0)" } }
        }
        let blocks = pieces { $0.block }
        let guides = event == .stop ? [] : pieces { $0.guide }
        func join(_ p: [String]) -> String? { p.isEmpty ? nil : String(p.joined(separator: "\n").prefix(total)) }
        if blocks.isEmpty { return Verdict(guide: join(guides), block: nil) }
        return Verdict(guide: nil, block: join(blocks + guides))
    }

    /// stdout of Claude's PostToolUse hook. Block wins over guide; empty verdict gives `nil`.
    public static func claudeToolOutput(_ v: Verdict) -> String? {
        let obj: [String: Any]
        if let b = v.block { obj = ["decision": "block", "reason": b] }
        else if let g = v.guide {
            obj = ["hookSpecificOutput": ["hookEventName": "PostToolUse", "additionalContext": g]]
        } else { return nil }
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// The reason text that blocks the end of a `stop` turn.
    public static func claudeStopReason(_ v: Verdict) -> String? { v.block }

    private static func clean(_ s: String, limit: Int) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(limit))
    }
}
