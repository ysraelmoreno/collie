import Foundation
import CollieProtocol
import CollieCore

/// The "you are running inside Collie" text injected at session start: only what the terminal reaches (English, short, no secrets).
enum CollieOrientation {
    private static let maxName = 40, limit = 1500

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
                     paddockPanels: [(name: String, pluginId: String)] = [], designFirst: DesignFirst = .ask,
                     lot: (name: String, goal: String)? = nil) -> String {
        // ponytail: 3 names per group; over the limit, retry with 1, then 0 (just the counts), then -1: also compact
        // (only reached with a lot line on a Shepherd: short lot line, the two panel lines in one, no --help footer)
        for n in [3, 1, 0, -1] {
            let t = build(terminal: terminal, isShepherd: isShepherd, paddock: paddock, peers: peers, panels: panels, paddockPanels: paddockPanels, designFirst: designFirst, lot: lot, n)
            if t.count <= limit { return t }
        }
        return build(terminal: terminal, isShepherd: isShepherd, paddock: paddock, peers: peers, panels: panels, paddockPanels: paddockPanels, designFirst: designFirst, lot: lot, -1)
    }

    private static func build(terminal: String, isShepherd: Bool, paddock: String?, peers: [String],
                              panels: [(name: String, pluginId: String)],
                              paddockPanels: [(name: String, pluginId: String)], designFirst: DesignFirst,
                              lot: (name: String, goal: String)?, _ k: Int) -> String {
        func names(_ xs: [String]) -> String { Self.names(xs, max(k, 0)) }
        let tight = k < 0
        func of(_ ps: [(name: String, pluginId: String)], _ id: String) -> [String] { ps.filter { $0.pluginId == id }.map(\.name) }
        func of(_ id: String) -> [String] { panels.filter { $0.pluginId == id }.map(\.name) }
        var lines = [
            "You are running inside Collie, terminal \(quote(terminal))\(paddock.map { ", on paddock \(quote($0))" } ?? ""). Use Collie's tools (`collie` MCP server or CLI):",
            "- Agents leashed to you: collie list / collie ask <name> \"<prompt>\" / collie check <name> (\(peers.isEmpty ? "none yet" : names(peers))).",
            "- Project memory: collie memory search|save — check before re-reading.",
            "- Work log: collie work status; collie work task defer <task> \"<reason>\" | drop …; collie work done.",
        ]
        if let lot {
            // the goal is the user's text: one line, short (a long one only loses its tail)
            let goal = tight ? "" : LotBoards.clean(lot.goal, max: k > 0 ? 80 : 30)
            lines.append("- Lot \(quote(tight ? String(lot.name.prefix(20)) : lot.name))\(goal.isEmpty ? "" : " (\(goal))"): collie lot board / collie lot post --kind handoff --to <name> \"<what, where, next>\"" + (tight ? "." : "; save lot decisions with collie memory save."))
        }
        let d = of("design"), b = of("browser"), v = of("device")
        if !d.isEmpty { lines.append("- Design panel \(names(d)): collie design …. Do not use other design editors or external artifact tools.") }
        if !b.isEmpty { lines.append("- Browser panel \(names(b)): collie browser … opens and checks pages.") }
        lines.append("- Artifacts: collie artifact … keeps handed-in pages.")   // panel-free: independent of reach
        if !v.isEmpty { lines.append("- Device \(names(v)): collie device … (screenshot, tap, logs).") }
        if isShepherd {
            let hints = ["design": "design --file <name>", "browser": "browser --url <url>", "device": "device [--serial <id|avd:<name>>]"]
            let open = PluginRegistry.canvasPluginIds.map { hints[$0] ?? $0 }.joined(separator: " | ")
            if tight {
                lines.append("- As Shepherd: collie panel open \(open); collie leash <agent> <panel>; panel close|move. Team: collie summon|dismiss|unleash, paddock …; summon|panel open --connect <names>")
            } else {
                lines.append("- As Shepherd you can open panels: collie panel open \(open) (leashed to you, on your paddock).")
                // ponytail: at the length cap (orientationSanitizesNames keeps 3 names); `leash <agent> <panel>` hands one over later
                lines.append("  Team: collie summon designer-1 --preset claude --connect design-1 | panel open design --file F --connect designer-1; leash|unleash|dismiss|paddock, panel close|move")
            }
            // leashed design panels are usable; a paddock-only one is not reachable until the user leashes it
            let notFor = "Not for backend, refactors, tests, docs, invisible fixes."
            let loose = of(paddockPanels, "design").filter { !d.contains($0) }
            if !d.isEmpty {
                lines.append("- UI work (new screen, flow or visible change): use design panel \(names(d)) first; leash it to whoever implements. \(notFor)")
            } else if !loose.isEmpty {
                lines.append("- UI work (new screen, flow or visible change): design panel \(names(loose)) is on your paddock but not leashed to you; ask the user to leash it to you, then design first. \(notFor)")
            } else if designFirst == .ask {
                // ponytail: `design prefer` is pasture-only; a paddock Shepherd tells the user where to set it
                lines.append("- UI work (new screen, flow or visible change) and no design panel: ask the user once whether to design it in FigCraft first. " + (paddock == nil ? "Save the answer: collie design prefer always|never." : "Tell the user to set it in Collie's Preferences.") + " \(notFor)")
            } else if designFirst == .always {
                lines.append("- UI work (new screen, flow or visible change): open a design panel (collie panel open design --file <feature>), design before implementing, and tell the user the file name. \(notFor)")
            }
            lines.append("- Herds: collie herd list | apply <id> --name <n> | save <name> --terminals a,b")
        } else {
            lines.append("- Your own test browsers: collie panel open browser [--url <url>] [--visible] (headless unless --visible; up to 8; closed when you exit).")
        }
        // sandbox: reads are open (secrets never); a blocked write shows the user a card; ask, don't work around it
        lines.append(tight ? "- Sandboxed: blocked write = user card; ask: collie access request <path> --write --reason \"…\"; collie open <url|app>."
            : "- Sandboxed: reads open (not secrets); writes only in project. A blocked write = user card; don't work around it, ask: collie access request <path> --write --reason \"…\". Open URLs/apps: collie open <url|app>.")
        if !tight { lines.append("Run `collie <group> --help` for details.") }
        return lines.joined(separator: "\n")
    }
}
