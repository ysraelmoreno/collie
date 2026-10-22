import Foundation
import CollieProtocol

/// The "you are running inside Collie" text injected at session start: only what the terminal reaches (English, short, no secrets).
enum CollieOrientation {
    private static let maxName = 40, limit = 1200

    /// Names are unvalidated: control/newline chars become spaces and `"` is dropped, so a name can't inject lines.
    private static func quote(_ x: String) -> String {
        let clean = String(String.UnicodeScalarView(x.unicodeScalars.compactMap { sc in
            sc == "\"" ? nil : (CharacterSet.controlCharacters.contains(sc) || CharacterSet.newlines.contains(sc) ? " " : sc) }))
        return "\"\(clean.count > maxName ? String(clean.prefix(maxName)) + "…" : clean)\""
    }
    private static func names(_ xs: [String], _ k: Int) -> String {
        ([xs.prefix(k).map(quote).joined(separator: ", ")] + (xs.count > k ? ["+\(xs.count - k) more"] : [])).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func text(terminal: String, isShepherd: Bool, paddock: String?, peers: [String],
                     panels: [(name: String, pluginId: String)]) -> String {
        // ponytail: 3 names per group; over the limit, retry with 1, then 0 (just the counts)
        for n in [3, 1, 0] {
            let t = build(terminal: terminal, isShepherd: isShepherd, paddock: paddock, peers: peers, panels: panels, n)
            if t.count <= limit { return t }
        }
        return build(terminal: terminal, isShepherd: isShepherd, paddock: paddock, peers: peers, panels: panels, 0)
    }

    private static func build(terminal: String, isShepherd: Bool, paddock: String?, peers: [String],
                              panels: [(name: String, pluginId: String)], _ k: Int) -> String {
        func names(_ xs: [String]) -> String { Self.names(xs, k) }
        func of(_ id: String) -> [String] { panels.filter { $0.pluginId == id }.map(\.name) }
        var lines = [
            "You are running inside Collie, terminal \(quote(terminal))\(paddock.map { ", on paddock \(quote($0))" } ?? ""). Use Collie's tools (the `collie` MCP server, or the `collie` CLI):",
            "- Agents leashed to you: collie list / collie ask <name> \"<prompt>\" / collie check <name> (\(peers.isEmpty ? "none yet" : names(peers))).",
            "- Project memory: collie memory search|save — check it before re-reading code.",
            "- Work log: collie work status; defer a task with collie work task defer <task> \"<reason>\", drop with collie work task drop …, finish with collie work done.",
        ]
        let d = of("design"), b = of("browser"), v = of("device")
        if !d.isEmpty { lines.append("- Design panel \(names(d)): collie design … builds screens there. Do not use other design editors or external artifact tools.") }
        if !b.isEmpty { lines.append("- Browser panel \(names(b)): collie browser … to open and check pages.") }
        lines.append("- Artifacts: collie artifact … keeps handed-in pages.")   // panel-free: independent of reach
        if !v.isEmpty { lines.append("- Device \(names(v)): collie device … (screenshot, tap, logs).") }
        if isShepherd {
            let hints = ["design": "design --file <name>", "browser": "browser --url <url>", "device": "device [--serial <id|avd:<name>>]"]
            let open = PluginRegistry.canvasPluginIds.map { hints[$0] ?? $0 }.joined(separator: " | ")
            lines.append("- As Shepherd you can open panels: collie panel open \(open) (leashed to you, on your paddock).")
            lines.append("  Give one to an agent: collie leash <agent> <panel>; collie panel close|move. Team: collie summon|dismiss|leash|unleash, collie paddock …")
            lines.append("- Herds: collie herd list | apply <id> --name <n> [--paddock true|false] | save <name> --terminals a,b")
        }
        lines.append("Run `collie <group> --help` for details.")
        return lines.joined(separator: "\n")
    }
}
