import Foundation

public enum HookPayload {
    private static let tailBytes = 2 * 1024 * 1024

    public static func claudeStopMessage(stdinJSON: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: stdinJSON) as? [String: Any] else { return nil }
        if let m = o["last_assistant_message"] as? String { return m }
        guard let path = o["transcript_path"] as? String, let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? h.seek(toOffset: start)) != nil, let data = try? h.readToEnd() else { return nil }
        var last: String?
        for line in data.split(separator: 10) {
            guard let e = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let msg = e["message"] as? [String: Any]
            guard e["type"] as? String == "assistant" || msg?["role"] as? String == "assistant" else { continue }
            if let s = msg?["content"] as? String { last = s }
            else if let items = msg?["content"] as? [[String: Any]] {
                let t = items.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
                if !t.isEmpty { last = t }
            }
        }
        return last
    }

    /// Claude sets `stop_hook_active` on a Stop that follows a turn a Stop hook made it continue: never block that one.
    /// nil: unreadable stdin (no block, the turn still ends).
    public static func claudeStopHookActive(stdinJSON: Data) -> Bool? {
        guard let o = try? JSONSerialization.jsonObject(with: stdinJSON) as? [String: Any] else { return nil }
        return o["stop_hook_active"] as? Bool ?? false
    }

    /// SessionStart's `source` (startup|resume|compact|clear); anything else, or unreadable stdin: nil (= startup).
    public static func claudeSessionSource(stdinJSON: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: stdinJSON) as? [String: Any], let s = o["source"] as? String,
              ["startup", "resume", "compact", "clear"].contains(s) else { return nil }
        return s
    }

    /// The Stop hook reply that makes Claude continue one more turn with `reason` as its instruction.
    public static func claudeStopBlock(reason: String) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: ["decision": "block", "reason": reason], options: [.withoutEscapingSlashes])
        else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// Longest prompt (UTF-8 bytes) the memory hook looks at.
    public static let maxPromptBytes = 64 * 1024

    public static func userPromptSubmitPrompt(stdinJSON: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: stdinJSON) as? [String: Any], let p = o["prompt"] as? String else { return nil }
        return boundedPrompt(p)
    }

    public static func boundedPrompt(_ p: String) -> String {
        p.utf8.count <= maxPromptBytes ? p : String(decoding: Data(p.utf8.prefix(maxPromptBytes)), as: UTF8.self)
    }

    /// Claude Code's `Notification` hook stdin: its `message` when it announces a permission dialog. Recent versions send
    /// `notification_type: "permission_prompt"`; older ones only a message like "Claude needs your permission to use Bash".
    public static func claudePermissionMessage(stdinJSON: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: stdinJSON) as? [String: Any] else { return nil }
        let m = (o["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let t = o["notification_type"] as? String { return t == "permission_prompt" ? m ?? "Claude needs your permission" : nil }
        return m.flatMap { $0.localizedCaseInsensitiveContains("needs your permission") ? $0 : nil }
    }

    public static func codexNotifyMessage(argJSON: String) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: Data(argJSON.utf8)) as? [String: Any],
              o["type"] as? String == "agent-turn-complete" else { return nil }
        return o["last-assistant-message"] as? String
    }
}
