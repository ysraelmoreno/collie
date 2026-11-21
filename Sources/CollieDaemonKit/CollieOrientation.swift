import Foundation
import CollieProtocol
import CollieCore

/// The "you are running inside Collie" text injected at session start: only what the terminal reaches (English, short, no secrets).
/// External plug-ins never appear by name (`morePanels`: one fixed line for a Shepherd when any is loaded).
enum CollieOrientation {
    private static let maxName = 40, limit = 1500
    /// "Delegate to a terminal" means a Collie terminal (collie summon): agents reach for their own subagents otherwise.
    /// ponytail: a Shepherd is 10-20 characters under the cap; it labels the Team line instead of adding one
    static let delegate = "Delegate (no own subagents):"
    /// M2.4, on the Loop line: a notice typed into the terminal is a hint that may never arrive; the state is read.
    /// The short form is for a text at the cap (a Cursor Shepherd has under 60 characters to spare).
    static let loopWait = "Wait for a loop: collie work wait, not a terminal notice.", loopWaitShort = "Wait: collie work wait."
    /// M3c.4: before `loopWait` where it fits (a form that would lose its place to it keeps today's line).
    /// M5.1: `end` is the default now: the line says per-task notices are off and the state is read with a long wait.
    static let loopNotify = "Per-task notices are off by default; use a long work wait."

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
                     paddockPanels: [(name: String, pluginId: String)] = [], designFirst: DesignFirst = .artifact,
                     lot: (name: String, goal: String)? = nil, morePanels: Bool = false, agent: String = "claude",
                     sharedFolder: [String] = [], figcraftAvailable: Bool = true, memoryTask: Bool = false,
                     candidates: Int = 0) -> String {
        // no engine (absent or out of date): the FigCraft and ask preferences fall back to a page, with a note
        let note = !figcraftAvailable && designFirst != .artifact
        let designFirst = figcraftAvailable ? designFirst : .artifact
        // ponytail: 3 names per group; over the limit, retry with 1, then 0 (just the counts), then -1: also compact
        // (only reached with a lot line on a Shepherd: short lot line, the two panel lines in one, no --help footer)
        // the export + claude.ai import hints go first, before any name
        // a compact UI-work line goes before the names do (a Shepherd in a shared folder keeps them)
        // `/collie:loop` named on the Loop line only where it fits: each form tries it, then the same form with today's line
        // (so the command never costs another line its place). Claude and Cursor carry it (LoopCommand; spike REPORT §9).
        // The Loop line also says how to wait for a loop (M2.4), and that outranks the command's name (still in the / menu):
        // the whole sentence with the name, then without it, then the short sentence, and only then the line as it was.
        // The short sentence is shorter than the name, so no text loses a form it had before.
        let loopCommands = agent == "claude" || agent == "cursor" ? [true, false] : [false]
        let loopLines = loopCommands.flatMap { [($0, loopNotify + " " + loopWait), ($0, loopWait)] } + [(false, loopWaitShort), (false, "")]
        // the candidates line (PRD B3 req. 4, a Shepherd's) may cost the names their room, never the cap: every form is
        // tried with it first, then all of them again without it
        for cands in candidates > 0 && isShepherd ? [candidates, 0] : [0] {
            for (n, claude, compact) in [(3, true, false), (3, false, false), (1, false, false), (1, false, true), (0, false, true), (-1, false, true)] {
                for (lc, wait) in loopLines {
                    let t = build(terminal: terminal, isShepherd: isShepherd, paddock: paddock, peers: peers, panels: panels, paddockPanels: paddockPanels, designFirst: designFirst, lot: lot, morePanels: morePanels, agent: agent, sharedFolder: sharedFolder, n, claude: claude, compact: compact, figcraftNote: note, memoryTask: memoryTask, loopCommand: lc, loopWait: wait, candidates: cands)
                    if t.count <= limit { return t }
                }
            }
        }
        return build(terminal: terminal, isShepherd: isShepherd, paddock: paddock, peers: peers, panels: panels, paddockPanels: paddockPanels, designFirst: designFirst, lot: lot, morePanels: morePanels, agent: agent, sharedFolder: sharedFolder, -1, compact: true, figcraftNote: note, memoryTask: memoryTask)
    }

    private static func build(terminal: String, isShepherd: Bool, paddock: String?, peers: [String],
                              panels: [(name: String, pluginId: String)],
                              paddockPanels: [(name: String, pluginId: String)], designFirst: DesignFirst,
                              lot: (name: String, goal: String)?, morePanels: Bool, agent: String, sharedFolder: [String] = [],
                              _ k: Int, claude: Bool = false, compact: Bool = false, figcraftNote: Bool = false, memoryTask: Bool = false,
                              loopCommand: Bool = false, loopWait: String = "", candidates: Int = 0) -> String {
        func names(_ xs: [String]) -> String { Self.names(xs, max(k, 0)) }
        let tight = k < 0
        func of(_ ps: [(name: String, pluginId: String)], _ id: String) -> [String] { ps.filter { $0.pluginId == id }.map(\.name) }
        func of(_ id: String) -> [String] { panels.filter { $0.pluginId == id }.map(\.name) }
        var lines = [
            "You are running inside Collie, terminal \(quote(terminal))\(paddock.map { ", on paddock \(quote($0))" } ?? ""). Tools: `collie` (MCP or CLI):",
            "- Leashed agents (\(peers.isEmpty ? "none yet" : names(peers))): collie list / check <name> / ask <name> \"<prompt>\""
                + (tight ? " [--no-wait]." : " to wait for the reply, or collie ask <name> \"<prompt>\" --no-wait (reply comes back as a message; collie ask result <id>)."),
            // memory_task (spec 2026-11-17 cursor memory §4): a hookless agent pulls the prompt's memory itself
            memoryTask ? (tight ? "- Memory: memory_task \"<task>\" first; memory save." : "- Memory: each task, first memory_task \"<task>\"; save: collie memory save.")
                : "- Memory: collie memory search|save — check before re-reading.",
            "- Work log: collie work status; collie work task defer <task> \"<reason>\" | drop …; collie work done.",
        ]
        // agent-comms: a crossed blocking ask (or wait) is refused as a deadlock; a hookless Cursor answers by command
        // ponytail: no warning line for a Shepherd: at the 1500 cap already, its ask line teaches --no-wait
        if !peers.isEmpty && !isShepherd && !tight { lines[1] += " Don't block-ask one who may wait on you: --no-wait or lot post." }
        if agent == "cursor" {
            if tight { lines[1] += " Asked: collie reply." } else { lines.insert("- Asked by an agent? End with collie reply \"<short answer>\".", at: 2) }
        }
        if let lot {
            // the goal is the user's text: one line, short (a long one only loses its tail)
            let goal = tight ? "" : LotBoards.clean(lot.goal, max: k > 0 ? 80 : 30)
            lines.append("- Lot \(quote(tight ? String(lot.name.prefix(20)) : lot.name))\(goal.isEmpty ? "" : " (\(goal))"): collie lot board / collie lot post --kind handoff --to <name> \"<what, where, next>\"" + (tight ? "." : "; save lot decisions with collie memory save."))
        }
        let d = of("design"), b = of("browser"), v = of("device")
        if !d.isEmpty { lines.append("- Design panel \(names(d)): collie design …. No other design editors, external design tools or CDNs.") }
        if !b.isEmpty { lines.append("- Browser panel \(names(b)): collie browser … opens, checks pages.") }
        // panel-free: independent of reach. ponytail: the kinds and libs only while names fit (k = 3); else `--help` lists
        // them (the 1500 cap leaves the shorter forms no room: the libs hint drops first)
        lines.append(k >= 3 ? "- Artifacts: collie artifact … keeps pages (--folder A/B); artifact new deck|dashboard|doc|prototype opens a Prévia. No CDN: offline JS libs via artifact libs." + (claude ? " Slides: artifact export <id> --format pptx|pdf. claude.ai links: artifact import-claude." : "")
            : "- Artifacts: collie artifact … (new <kind>: Prévia; --folder).")
        if !v.isEmpty { lines.append("- Device \(names(v)): collie device … (screenshot, tap, logs).") }
        if isShepherd {
            let hints = ["design": "design --file <name>", "diagram": "diagram --file <path.drawio>", "browser": "browser --url <url>", "device": "device [--serial <id|avd:<name>>]"]
            // built-ins only: external plug-ins are user-installed text, kept out of the agent's context (one fixed line below)
            // ponytail: no Prévia here (length cap); the Artifacts line teaches `artifact new`, which opens one
            let open = PluginRegistry.builtIn.filter { $0.placements.contains(.canvas) && $0.id != "preview" }.map(\.id).map { hints[$0] ?? $0 }.joined(separator: "|")
            if tight {
                lines.append("- As Shepherd: collie panel open \(open); leash <agent> <panel>; panel close|move. \(delegate) collie summon|dismiss|unleash, paddock; summon (no --preset: \(agent))|panel open --connect <names>; model <agent> <m> (summon --model m)" + (morePanels ? "; +collie plugin list" : ""))
            } else {
                lines.append("- As Shepherd: collie panel open \(open)")
                // ponytail: at the length cap (orientationSanitizesNames keeps 3 names); `leash <agent> <panel>` hands one over later
                // the asker's own agent: "open a terminal" once summoned a plain shell from Cursor
                lines.append("  \(delegate) collie summon dev --connect design-1 (no --preset: \(agent), yours; shell if asked) | panel open design --file F --connect dev; (un)leash|dismiss|paddock|panel close|move")
            }
            // leashed design panels are usable; a paddock-only one is not reachable until the user leashes it
            let notFor = compact ? "" : "Not for backend, refactors, tests, docs, invisible fixes."
            let loose = of(paddockPanels, "design").filter { !d.contains($0) }
            if !d.isEmpty {
                lines.append("- UI work (screen, flow, visible change): use design panel \(names(d)) first; leash it to whoever implements. \(notFor)")
            } else if !loose.isEmpty {
                lines.append("- UI work (screen, flow, visible change): design panel \(names(loose)) is on your paddock but not leashed to you; ask the user to leash it to you, then design first. \(notFor)")
            } else {
                // "Onde desenhar"; a bare "design X" request follows it too
                switch designFirst {
                case .artifact where compact:
                    lines.append("- UI work: design it as a page first (collie artifact new prototype <name>); FigCraft only if asked.")
                case .artifact:
                    lines.append("- UI work (screen, flow, visible change; also a bare 'design X'): design it as a page first: collie artifact new prototype <name>\(tight ? "" : " (Prévia; fonts, animation, offline libs, collie font add)"). Use FigCraft only if the user asks or for design-system work. \(notFor)")
                case .figcraft:
                    lines.append("- UI work (screen, flow, visible change; also a bare 'design X'): open a design panel (collie panel open design --file <feature>), design before implementing, and tell the user the file name. \(notFor)")
                case .ask:
                    // ponytail: `design prefer` is pasture-only; a paddock Shepherd tells the user where to set it
                    lines.append("- UI work (screen, flow, visible change; also a bare 'design X') and no design panel: ask the user once: a page (collie artifact new prototype <name>) or FigCraft? " + (paddock == nil ? "Save the answer: collie design prefer artifact|figcraft." : "Tell the user to set it in Collie's Preferences (Onde desenhar).") + " \(notFor)")
                }
                if figcraftNote {
                    lines.append("- FigCraft indisponível (motor não instalado ou desatualizado); se o usuário quiser FigCraft, peça para baixá-lo em Preferências.")
                }
            }
            lines.append("- Herds: collie herd list|apply <id> --name <n>|save <name> --terminals a,b")
            // collie work run needs a paddock it has to itself: not in a shared folder (its rule needs the room). One line,
            // gone only in the tightest form (a paddock Shepherd is already compact). The detail: work run --help, docs/referencia.md
            if paddock != nil && sharedFolder.isEmpty && !tight {
                lines.append("- Loop\(loopCommand ? " (owner: /collie:loop <request>)" : ""): work task add --spec --check; collie work run, work stop only after the owner approved the task list and the checks. \(loopWait)")
            }
            if morePanels && !tight { lines.append("- More panels: collie plugin list") }   // tight: on the Shepherd line
            // the owner's language: the Shepherd relays it (`text` drops it where it can't fit)
            if candidates > 0 {
                lines.append("- \(candidates) \(candidates == 1 ? "armadilha recorrente pode" : "armadilhas recorrentes podem") virar checagem: collie memory list --candidates")
            }
        } else {
            lines.append("- Your own test browsers: collie panel open browser [--url <url>] [--visible] (headless unless --visible; up to 8; closed when you exit).")
        }
        // Apps do cercado, slice 4: when to offer one; approving stays the user's
        if paddock != nil && !compact {
            lines.append("- A live tool the user will reuse in this paddock (dashboard, control panel): offer collie app new <id>, then app attach; only the user approves (a card).")
        }
        // sandbox: reads are open (secrets never); a blocked write shows the user a card; ask, don't work around it
        lines.append(tight ? "- Sandboxed: blocked write = user card; ask: collie access request <path> --write --reason \"…\"; collie open <url|app>."
            : "- Sandboxed: reads open (not secrets), writes in project only; blocked write = user card; don't work around it: collie access request <path> --write --reason \"…\". collie open <url|app>.")
        // DX backlog 11: another live terminal in this folder: its edits land mid-build and its WIP in a `git add`
        if !sharedFolder.isEmpty {
            let own = String(terminal.prefix(maxName).map { $0.isLetter || $0.isNumber ? $0 : "-" })
            lines.append(tight ? "- Shared folder: own build dir; git diff <file> before add; verify in git worktree add --detach <tmp> HEAD."
                : "- Shared folder (\(names(sharedFolder))): build in .build/\(own) (--scratch-path); git add only your hunks (git diff <file>); verify: git worktree add --detach <tmp> HEAD, swift test --filter …, git worktree remove <tmp>.")
        }
        if !tight { lines.append("More: collie <group> --help.") }
        return lines.map { $0.hasSuffix(" ") ? String($0.dropLast()) : $0 }.joined(separator: "\n")   // compact: no notFor
    }
}
