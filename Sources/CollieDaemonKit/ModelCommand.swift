import Foundation
import CollieCore
import CollieProtocol
import CollieTerminal

/// DX backlog 20: `collie model <terminal> <model>` types `/model <model>` into a Claude terminal and reads Claude's
/// answer. Claude 2.1.319 prints (checked on the installed version, 2026-11-07):
///   ⎿  Set model to Opus 5.5 and saved as your default for new sessions
///   ⎿  Model 'bogus-xyz' not found
///   ⎿  Kept model as Opus 5.5
enum ClaudeModel {
    enum Reply: Equatable { case set(String), notFound(String) }

    static let answerTimeout: Duration = .seconds(10)

    /// A model name typed after `/model`: one word, no control characters (it can't type a second command or a newline).
    static func validate(_ m: String) throws(ProtocolError) {
        guard m.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:@/\[\]-]{0,99}$"#, options: .regularExpression) != nil else {
            throw ProtocolError(code: .invalidArgs, message: "'\(m)' is not a model name (opus, sonnet, haiku, claude-opus-5-5…)")
        }
    }

    /// Claude's answer in `text` (output after the write, ANSI stripped: cursor moves are spaces); nil: none yet.
    static func parse(_ text: String) -> Reply? {
        func first(_ pattern: String) -> String? {
            guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
            let m = String(text[r])
            guard let a = m.range(of: #"(Set\s+model\s+to|Kept\s+model\s+as|Model\s+')\s*"#, options: .regularExpression) else { return nil }
            return m[a.upperBound...].replacingOccurrences(of: #"('\s*not\s+found|\s+and\s+saved|\s+for\s+this\s+session|\s+[^\x20-\x7E]).*$"#, with: "", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        // the rest of the line may hold the TUI's status (◐ medium · /effort, a ─── border): cut at the first non-ASCII
        if let m = first(#"Model\s+'[^'\n]+'\s*not\s+found"#) { return .notFound(m) }
        if let m = first(#"(Set\s+model\s+to|Kept\s+model\s+as)[ \t]+[^\n]+"#), !m.isEmpty { return .set(m) }
        return nil
    }

    /// `ask` with a slash command for an agent: it opens no turn, so the ask would only time out. nil: a normal prompt
    /// (a path like /Users/… is one: the first word holds a second '/').
    static func slashRefusal(_ prompt: String, target t: TerminalRecord) -> ProtocolError? {
        let word = prompt.drop { $0.isWhitespace }.prefix { !$0.isWhitespace }
        guard word.range(of: #"^/[A-Za-z][A-Za-z0-9:_-]*$"#, options: .regularExpression) != nil,
              [.claude, .codex, .cursor].contains(t.preset) || AgentLaunch.isClaude(t) else { return nil }
        if word == "/model" {
            let arg = prompt.drop { $0.isWhitespace }.dropFirst(word.count).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "<model>"
            return ProtocolError(code: .invalidArgs, message: "use collie model \(t.name) \(arg): /model opens no turn, so ask would only wait for its timeout")
        }
        return ProtocolError(code: .invalidArgs, message: "\(word) is a slash command: it opens no turn, so ask would only wait for its timeout. "
            + "Collie sends none but /model (collie model); ask the user to type it in \(t.name)")
    }
}

extension CommandRouter {
    /// `model`: the app (admin), or a terminal leashed to the target.
    func modelCommand(_ r: Request, peer: pid_t) async throws -> JSONValue {
        let caller = try await principal(r, peer: peer)
        let name = try need(r, "target"), model = try need(r, "model")
        let t = try caller.map { try ConnectionGraph.resolve(name: name, from: $0.id, in: ws) } ?? (try find(name))
        try ClaudeModel.validate(model)
        guard t.preset == .claude || AgentLaunch.isClaude(t) else {
            throw ProtocolError(code: .invalidArgs, message: "'\(t.name)' runs \(t.preset.rawValue), not claude: collie model switches Claude's model only")
        }
        guard await registry.process(t.id)?.isRunning == true else {
            throw ProtocolError(code: .notRunning, message: "Terminal '\(t.name)' is not running")
        }
        _ = await asks.waitReady(t.id, timeout: ClaudeModel.answerTimeout)   // just summoned: its prompt first
        if flag(r, "wait") {
            let deadline = ContinuousClock.now + .seconds(try num(r, "timeout", max: 86_400) ?? 1800)
            // ponytail: 200 ms polling, as `wait`
            while await midTurn(t.id) {
                guard ContinuousClock.now < deadline else {
                    throw ProtocolError(code: .timeout, message: "'\(t.name)' is still in its turn; model not switched")
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        } else if await midTurn(t.id) { throw AskCoordinator.midTurn(t.name) }
        let (hold, mark) = try await asks.typeCommand(t.id, "/model " + model)
        let reply = await answer(t.id, since: mark)
        await asks.releaseCapture(t.id, hold)
        switch reply.parsed {
        case .set(let effective)?:
            await noteModel(t.id, model)
            // user decision (A): Claude's /model also saves it as the default for new sessions (~/.claude/settings.json)
            return .object(["terminal": .string(t.name), "model": .string(effective),
                            "note": .string("Claude also saved \(effective) as its default for new sessions (~/.claude/settings.json)")])
        case .notFound(let m)?:
            throw ProtocolError(code: .invalidArgs, message: "Claude in '\(t.name)': model '\(m)' not found; model unchanged")
        case nil:
            let tail = reply.text.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " | ")
            throw ProtocolError(code: .timeout, message: "'\(t.name)' did not confirm /model \(model) in \(ClaudeModel.answerTimeout.components.seconds) s"
                + (tail.isEmpty ? " (no output: is Claude at its prompt?)" : "; its last output: \(tail.prefix(300))"))
        }
    }

    /// Mid-turn for `collie model`: the coordinator's state, or (no hooks seen) the hub's `working` badge.
    private func midTurn(_ id: UUID) async -> Bool {
        guard let s = await asks.commandState(id) else { return false }
        if s.busy || s.hooked { return s.busy }
        return await hub.currentBadges[id] == .working
    }

    /// Claude's answer after `mark`, read every 100 ms up to `ClaudeModel.answerTimeout`.
    private func answer(_ id: UUID, since mark: Int) async -> (parsed: ClaudeModel.Reply?, text: String) {
        let deadline = ContinuousClock.now + ClaudeModel.answerTimeout
        var text = ""
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            text = ANSI.strip(await registry.scrollback(id)?.text(since: mark).text ?? "")
            if let p = ClaudeModel.parse(text) { return (p, text) }
        }
        return (nil, text)
    }

    /// The model `id` runs now (`collie model`, the transcript): saved on its record (its next launch's `--model`) and
    /// shown in the app.
    func noteModel(_ id: UUID, _ model: String) async {
        guard let i = ws.terminals.firstIndex(where: { $0.id == id }), ws.terminals[i].model != model else { return }
        ws.terminals[i].model = model
        try? await persist()
        await hub.emit(.terminal(ws.terminals[i]))
    }
}
