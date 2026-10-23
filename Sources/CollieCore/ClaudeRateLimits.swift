import Foundation

/// What `collie hook claude-statusline` keeps from Claude Code's statusLine feed: only the rate limits (no session, cwd or transcript data).
public enum ClaudeRateLimits {
    public static let fileName = "claude-rate-limits.json"
    private static let windows = ["five_hour", "seven_day"]

    /// `{"five_hour":{...},"seven_day":{...},"recorded_at":<epoch s>}`; nil without `rate_limits` or without either window.
    public static func extract(_ statusJSON: Data, now: Date = Date()) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: statusJSON) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return nil }
        var out: [String: Any] = [:]
        for w in windows {
            guard let win = limits[w] as? [String: Any] else { continue }
            let kept = win.filter { ["used_percentage", "resets_at"].contains($0.key) }   // ponytail: whitelist, nothing else is stored
            if !kept.isEmpty { out[w] = kept }
        }
        guard !out.isEmpty else { return nil }
        out["recorded_at"] = Int(now.timeIntervalSince1970)
        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }

    /// `statusLine.command` of the user's settings when `statusLine.type == "command"`.
    public static func userStatusLineCommand(settings: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: settings) as? [String: Any],
              let sl = root["statusLine"] as? [String: Any], sl["type"] as? String == "command",
              let cmd = sl["command"] as? String, !cmd.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return cmd
    }

    /// Atomic write, 0600 (temp file created 0600 then renamed over the target).
    public static func write(_ data: Data, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".\(fileName).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do { _ = try FileManager.default.replaceItemAt(dir.appendingPathComponent(fileName), withItemAt: tmp) }
        catch { try? FileManager.default.removeItem(at: tmp); throw error }
    }

    /// COLLIE_USAGE_DIR, else `<root>/usage` from the socket path `<root>/run/collied.sock`; nil when neither is known.
    public static func usageDir(env: [String: String]) -> URL? {
        if let d = env["COLLIE_USAGE_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        guard let s = env["COLLIE_SOCKET"], !s.isEmpty else { return nil }
        return URL(fileURLWithPath: s).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("usage")
    }
}
