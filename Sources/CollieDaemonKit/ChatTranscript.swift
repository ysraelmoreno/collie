import Foundation
import CollieCore
import CollieProtocol

/// The chat body of a Claude terminal (spec 2026-11-08-terminal-chat): the transcript's messages and tool calls as
/// `ChatEntry`. The path rules are `TranscriptChunk`'s; the content is untrusted and scrubbed of secrets.
enum ChatTranscript {
    static let resultMax = 8 * 1024, summaryMax = 200, diffMax = 16 * 1024, textMax = 64 * 1024

    /// The entries in the complete lines after `offset`, and the byte after the last one. nil: not readable as a regular file.
    static func read(_ url: URL, from offset: UInt64, secrets: Set<String>) -> (entries: [ChatEntry], end: UInt64)? {
        var out: [ChatEntry] = [], pos = offset
        guard let end = TranscriptChunk.lines(url, from: offset, { raw in
            defer { pos += UInt64(raw.count + 1) }   // ponytail: blank lines drift pos by a byte; it only seeds ids
            out += entries(raw, at: pos, secrets: secrets)
        }) else { return nil }
        return (out, end)
    }

    static func entries(_ line: Data, at pos: UInt64, secrets: Set<String>) -> [ChatEntry] {
        guard let e = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              e["isMeta"] as? Bool != true, e["isSidechain"] as? Bool != true,
              let msg = e["message"] as? [String: Any], let type = e["type"] as? String,
              type == "user" || type == "assistant", msg["role"] as? String == type else { return [] }
        func scrub(_ s: String, _ max: Int) -> String { String(LotBoards.scrub(blobs(String(s.prefix(max + 256))), secrets: secrets).prefix(max)) }
        if let s = msg["content"] as? String {
            let t = TranscriptChunk.clean(s).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [ChatEntry(kind: type == "user" ? .user : .assistant, text: scrub(t, textMax), offset: pos)]
        }
        guard let items = msg["content"] as? [[String: Any]] else { return [] }
        var out: [ChatEntry] = []
        for it in items {
            switch it["type"] as? String {
            case "text":
                let t = TranscriptChunk.clean(it["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(ChatEntry(kind: type == "user" ? .user : .assistant, text: scrub(t, textMax), offset: pos)) }
            case "tool_use" where type == "assistant":
                let name = String((it["name"] as? String ?? "?").prefix(80)), input = it["input"] as? [String: Any] ?? [:]
                var c = ChatEntry(kind: .toolUse, tool: name, summary: scrub(summary(name, input), summaryMax), toolId: it["id"] as? String, offset: pos)
                if name == "Edit" { c.old = (input["old_string"] as? String).map { scrub($0, diffMax) }; c.new = (input["new_string"] as? String).map { scrub($0, diffMax) } }
                if name == "Write" { c.new = (input["content"] as? String).map { scrub($0, diffMax) } }
                out.append(c)
            case "tool_result" where type == "user":
                let body: String
                if let s = it["content"] as? String { body = s }
                else if let a = it["content"] as? [[String: Any]] { body = a.compactMap { $0["text"] as? String }.joined(separator: "\n") }
                else { body = "" }
                out.append(ChatEntry(kind: .toolResult, text: scrub(body, resultMax), toolId: it["tool_use_id"] as? String,
                                     isError: it["is_error"] as? Bool, offset: pos))
            default: break
            }
        }
        return out
    }

    /// `LotBoards.scrub`'s regexes are quadratic on a long alphanumeric run (a base64 blob: 16 KiB took 10 min). A run of 200+
    /// is no token shape it hides by pattern, so it becomes "[blob]" first (an exact secret inside goes with it).
    static func blobs(_ s: String) -> String { s.replacing(/[A-Za-z0-9_]{200,}/, with: "[blob]") }

    /// One line naming what a tool call does: its command, path, pattern or description.
    private static func summary(_ tool: String, _ i: [String: Any]) -> String {
        for k in ["command", "file_path", "path", "pattern", "url", "query", "description", "prompt"] {
            if let s = i[k] as? String, !s.isEmpty { return s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s }
        }
        return ""
    }
}

extension CommandRouter {
    /// A Claude hook named `transcript` for `tid`: remembered (as the Stop hook does) and the app told how far it reaches.
    /// Detached: a hook never waits on the file. A refused path or an unreadable file: nothing (never fails the hook).
    func chatNote(_ tid: UUID, transcript: String) {
        guard let me = ws.terminals.first(where: { $0.id == tid }), me.preset == .claude else { return }
        conversations.transcripts[tid] = transcript
        Task {
            guard let url = TranscriptChunk.allowed(transcript, projectsDir: await claudeProjectsDir(me)),
                  let st = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else { return }
            await hub.emit(.chatChanged(tid, end: st.uint64Value))
        }
    }

    /// `terminal.chat <name> [--since n]` (the app): `{entries, end}`. No transcript seen yet: empty from 0.
    func terminalChat(_ r: Request) async throws -> JSONValue {
        let me = try terminalNamed(try need(r, "name"))
        guard me.preset == .claude else { throw ProtocolError(code: .invalidArgs, message: "'\(me.name)' has no chat (Claude only)") }
        guard let path = conversations.transcripts[me.id] else { return .object(["entries": .array([]), "end": .number(0)]) }
        guard let url = TranscriptChunk.allowed(path, projectsDir: await claudeProjectsDir(me)) else {
            throw ProtocolError(code: .invalidArgs, message: "Transcript refused for '\(me.name)'")
        }
        let since = UInt64(max(0, try num(r, "since", max: 1e15) ?? 0)), secrets = await auth.secrets()
        guard let res = try await UnixSocketClient.offPool({ ChatTranscript.read(url, from: since, secrets: secrets) }) else {
            throw ProtocolError(code: .internal, message: "Transcript of '\(me.name)' unreadable")
        }
        let data = try JSONEncoder().encode(res.entries)
        return .object(["entries": try JSONDecoder().decode(JSONValue.self, from: data), "end": .number(Double(res.end))])
    }

    /// `terminal.style <name> terminal|chat|default` (the app): the header toggle.
    func terminalStyle(_ r: Request) async throws -> JSONValue {
        let me = try terminalNamed(try need(r, "name")), v = try need(r, "style")
        let style: TerminalStyle? = v == "default" ? nil : TerminalStyle(rawValue: v)
        guard v == "default" || style != nil else { throw ProtocolError(code: .invalidArgs, message: "style: terminal, chat or default") }
        if style == .chat, me.preset != .claude { throw ProtocolError(code: .invalidArgs, message: "Chat is for Claude terminals") }
        guard let i = ws.terminals.firstIndex(where: { $0.id == me.id }) else { throw ProtocolError(code: .notFound, message: "No terminal '\(me.name)'") }
        ws.terminals[i].style = style
        try? await persist()
        await hub.emit(.terminal(ws.terminals[i]))
        return .object([:])
    }

    /// `terminal.say <name> <text>` (the app's chat composer): the existing prompt delivery. Never typed into a dialog
    /// (`inject` refuses while an approval is pending; the app queues while the badge says attention).
    func terminalSay(_ r: Request) async throws -> JSONValue {
        let me = try terminalNamed(try need(r, "name"))
        try await asks.inject(to: me.id, prompt: try need(r, "text"), hold: .seconds(1800))
        return .object([:])
    }

    private func terminalNamed(_ name: String) throws -> TerminalRecord {
        guard let t = ws.terminals.first(where: { $0.name == name }) else { throw ProtocolError(code: .notFound, message: "No terminal '\(name)'") }
        return t
    }
}
