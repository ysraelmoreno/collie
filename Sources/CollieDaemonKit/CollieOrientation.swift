import Foundation
import CollieProtocol
import CollieCore

/// The "you are running inside Collie" text injected at session start: only what the terminal reaches (English, short, no secrets).
enum CollieOrientation {
    private static let maxName = 40, limit = 1300

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
                     panels: [(name: String, pluginId: String)],
                     paddockPanels: [(name: String, pluginId: String)] = [], designFirst: DesignFirst = .ask) -> String {
        // ponytail: 3 names per group; over the limit, retry with 1, then 0 (just the counts)
        for n in [3, 1, 0] {
            let t = build(terminal: terminal, isShepherd: isShepherd, paddock: paddock, peers: peers, panels: panels, paddockPanels: paddockPanels, designFirst: designFirst, n)
            if t.count <= limit { return t }
        }
        return build(terminal: terminal, isShepherd: isShepherd, paddock: paddock, peers: peers, panels: panels, paddockPanels: paddockPanels, designFirst: designFirst, 0)
    }

    private static func build(terminal: String, isShepherd: Bool, paddock: String?, peers: [String],
                              panels: [(name: String, pluginId: String)],
                              paddockPanels: [(name: String, pluginId: String)], designFirst: DesignFirst, _ k: Int) -> String {
        func names(_ xs: [String]) -> String { Self.names(xs, k) }
        func of(_ ps: [(name: String, pluginId: String)], _ id: String) -> [String] { ps.filter { $0.pluginId == id }.map(\.name) }
        func of(_ id: String) -> [String] { panels.filter { $0.pluginId == id }.map(\.name) }
        var lines = [
            "You are running inside Collie, terminal \(quote(terminal))\(paddock.map { ", on paddock \(quote($0))" } ?? ""). Use Collie's tools (`collie` MCP server or CLI):",
            "- Agents leashed to you: collie list / collie ask <name> \"<prompt>\" / collie check <name> (\(peers.isEmpty ? "none yet" : names(peers))).",
            "- Project memory: collie memory search|save — check before re-reading code.",
            "- Work log: collie work status; collie work task defer <task> \"<reason>\" | drop …; collie work done.",
        ]
        let d = of("design"), b = of("browser"), v = of("device")
        if !d.isEmpty { lines.append("- Design panel \(names(d)): collie design …. Do not use other design editors or external artifact tools.") }
        if !b.isEmpty { lines.append("- Browser panel \(names(b)): collie browser … opens and checks pages.") }
        lines.append("- Artifacts: collie artifact … keeps handed-in pages.")   // panel-free: independent of reach
        if !v.isEmpty { lines.append("- Device \(names(v)): collie device … (screenshot, tap, logs).") }
        if isShepherd {
            let hints = ["design": "design --file <name>", "browser": "browser --url <url>", "device": "device [--serial <id|avd:<name>>]"]
            let open = PluginRegistry.canvasPluginIds.map { hints[$0] ?? $0 }.joined(separator: " | ")
            lines.append("- As Shepherd you can open panels: collie panel open \(open) (leashed to you, on your paddock).")
            lines.append("  Give one to an agent: collie leash <agent> <panel>; collie panel close|move. Team: collie summon|dismiss|leash|unleash, collie paddock …")
            // reachable design panels first, then the paddock's (a Shepherd can leash those itself)
            var dn = d; for n in of(paddockPanels, "design") where !dn.contains(n) { dn.append(n) }
            if !dn.isEmpty {
                lines.append("- UI work (new screen, flow or visible change): use design panel \(names(dn)) first; leash it to whoever implements. Not for backend, refactors or tests.")
            } else if designFirst == .ask {
                // ponytail: `design prefer` is pasture-only, so a paddock Shepherd is not told to save
                lines.append("- UI work (new screen, flow or visible change) and no design panel: ask the user once whether to design it in FigCraft first. " + (paddock == nil ? "Save the answer: collie design prefer always|never." : "The pasture saves the answer.") + " Not for backend, refactors or tests.")
            } else if designFirst == .always {
                lines.append("- UI work (new screen, flow or visible change): open a design panel (collie panel open design --file <feature>) and have it designed before implementing. Not for backend, refactors or tests.")
            }
            lines.append("- Herds: collie herd list | apply <id> --name <n> | save <name> --terminals a,b")
        } else {
            lines.append("- Your own test browsers: collie panel open browser [--url <url>] [--visible] (headless unless --visible; up to 8; closed when you exit).")
        }
        lines.append("Run `collie <group> --help` for details.")
        return lines.joined(separator: "\n")
    }
}
