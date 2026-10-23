/// Seeded into `<root>/usage/providers/<id>.json` when that directory is empty. Embedded (not SwiftPM resources) so the
/// daemon binary stays self-contained; users edit the seeded copies.
enum DefaultUsageProviders {
    // Claude Code: the plan windows come from the `statusLine` JSON Claude pipes to `collie hook claude-statusline` (wired by
    // AgentLaunch into every Collie-launched Claude), which writes `<usage dir>/claude-rate-limits.json`. This only cats it;
    // no (or empty) file yet (no Collie Claude has refreshed, or not a subscriber) -> prints `{}` -> a report with "—" windows.
    static let claude = """
    {
      "id": "claude",
      "label": "Claude Code",
      "enabled": true,
      "command": ["/bin/sh", "-c", "f=\\"$COLLIE_USAGE_DIR/claude-rate-limits.json\\"; if [ -s \\"$f\\" ]; then cat \\"$f\\"; else echo '{}'; fi"],
      "timeoutSeconds": 10,
      "parse": { "type": "json" },
      "windows": [
        { "label": "5h", "usedPercent": "/five_hour/used_percentage", "resetsAt": "/five_hour/resets_at" },
        { "label": "7d", "usedPercent": "/seven_day/used_percentage", "resetsAt": "/seven_day/resets_at" }
      ]
    }
    """

    /// The claude template shipped before plan 2J (disabled, no source). `UsageService` replaces `providers/claude.json` with
    /// the current template only when it is byte-equal to this, so a user-edited file is never touched.
    static let claudeV1 = """
    {
      "id": "claude",
      "label": "Claude Code",
      "enabled": false,
      "command": ["claude", "--version"],
      "timeoutSeconds": 10,
      "parse": { "type": "json" },
      "windows": [
        { "label": "5h", "usedPercent": "/five_hour/used_percent", "resetsAt": "/five_hour/resets_at" },
        { "label": "7d", "usedPercent": "/seven_day/used_percent", "resetsAt": "/seven_day/resets_at" }
      ]
    }
    """

    // Codex: rollout logs carry `token_count` events with `rate_limits.primary` (5h) / `.secondary` (7d).
    // Prints the newest rollout's last line carrying a non-null rate_limits object (filtered in the shell: whole rollouts can exceed the 1 MiB cap); `jsonlLast` still applies.
    static let codex = """
    {
      "id": "codex",
      "label": "Codex",
      "enabled": true,
      "command": ["/bin/sh", "-c", "f=$(ls -t \\"$HOME\\"/.codex/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -n 1); [ -n \\"$f\\" ] && grep -F '\\"rate_limits\\":{' \\"$f\\" | tail -n 1; true"],
      "timeoutSeconds": 15,
      "parse": { "type": "jsonlLast", "contains": "rate_limits" },
      "windows": [
        { "label": "5h", "usedPercent": "/payload/rate_limits/primary/used_percent", "resetsAt": "/payload/rate_limits/primary/resets_at" },
        { "label": "7d", "usedPercent": "/payload/rate_limits/secondary/used_percent", "resetsAt": "/payload/rate_limits/secondary/resets_at" }
      ]
    }
    """

    static let all: [(id: String, json: String)] = [("claude", claude), ("codex", codex)]
}
