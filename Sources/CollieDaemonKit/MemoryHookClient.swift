import Foundation
import CollieCore
import CollieProtocol

/// What `collie hook claude-session-start` / `claude-prompt` do, minus the process plumbing (so it can be tested).
public enum MemoryHookClient {
    public enum Event: String, Sendable {
        case sessionStart = "SessionStart", userPromptSubmit = "UserPromptSubmit"
    }

    /// The JSON Claude Code expects on stdout, or nil when there is nothing to inject or anything went wrong
    /// (daemon down, timeout, error: `onError` gets the reason; never throws, never blocks Claude for more than 5 s).
    /// `transcript`: the hook's `transcript_path` (names the session in the memory event log; never read here).
    /// `session`: Cursor's `session_id` (finds its transcript when the payload names none).
    /// `cursor`: Cursor's sessionStart shape, `{"additional_context": …}` (under its 10 000-char cap: orientation ≤ 1500 + 4 KiB).
    public static func output(event: Event, prompt: String?, source: String? = nil, transcript: String? = nil, session: String? = nil, cursor: Bool = false, env: [String: String],
                              onError: (String) -> Void = { _ in }) async -> String? {
        guard let sock = env["COLLIE_SOCKET"], let tid = env["COLLIE_TERMINAL_ID"], let tok = env["COLLIE_TOKEN"] else {
            onError("COLLIE_SOCKET/COLLIE_TERMINAL_ID/COLLIE_TOKEN missing"); return nil
        }
        var args: [String: JSONValue] = [:]
        if event == .userPromptSubmit { args["prompt"] = .string(HookPayload.boundedPrompt(prompt ?? "")) }
        if event == .sessionStart, let source { args["source"] = .string(source) }
        if let transcript { args["transcript"] = .string(transcript) }
        if event == .sessionStart, let session { args["session"] = .string(session) }
        do {
            let r = try await UnixSocketClient.send(
                Request(id: UUID().uuidString, terminalId: tid, token: tok,
                        command: event == .sessionStart ? "memory.hookContext" : "memory.hookRelevant", args: args),
                to: URL(fileURLWithPath: sock), timeoutSeconds: 5)
            guard r.ok else { onError(r.error?.message ?? "memory hook failed"); return nil }
            var text = ""
            if case .object(let o)? = r.result, case .string(let t)? = o["output"] { text = t }
            // a Cursor Shepherd also gets the delegation brief here: the plugin rule alone was not followed
            if cursor, event == .sessionStart, env["COLLIE_SHEPHERD"] == "1" { text += (text.isEmpty ? "" : "\n\n") + AgentLaunch.delegateBrief }
            guard !text.isEmpty else { return nil }
            let json: [String: Any] = cursor ? ["additional_context": text]
                : ["hookSpecificOutput": ["hookEventName": event.rawValue, "additionalContext": text]]
            guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch { onError("\(error)"); return nil }
    }

    /// `collie hook claude-stop`: reports the turn's end (`turn.completed`, which also clears a pending approval) and returns
    /// the block reply when the daemon asks the agent to record what it learned. nil — no block — on a continued Stop
    /// (`stop_hook_active`), when there is nothing to ask, and on any error or timeout (fail open). Never writes to a PTY.
    public static func stopOutput(stdin: Data, env: [String: String], onError: (String) -> Void = { _ in }) async -> String? {
        let r = await stopReply(stdin: stdin, env: env, onError: onError)
        if let ask = r.ask { return HookPayload.claudeStopBlock(reason: ask) }
        return r.advice.flatMap(systemMessage)
    }

    /// M5.5: the advice as a Stop reply that shows it to the user without blocking (no extra turn for the agent).
    static func systemMessage(_ text: String) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: ["systemMessage": text], options: [.withoutEscapingSlashes]) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// The text of `stopOutput`'s block (the memory ask), before it is wrapped as a reply; same rules and same `turn.completed` call.
    public static func stopAsk(stdin: Data, env: [String: String], onError: (String) -> Void = { _ in }) async -> String? {
        await stopReply(stdin: stdin, env: env, onError: onError).ask
    }

    /// `stopAsk`'s call, with M5.5's large-context advice (the daemon gives at most one of the two).
    public static func stopReply(stdin: Data, env: [String: String], onError: (String) -> Void = { _ in }) async -> (ask: String?, advice: String?) {
        guard let sock = env["COLLIE_SOCKET"], let tid = env["COLLIE_TERMINAL_ID"], let tok = env["COLLIE_TOKEN"] else {
            onError("COLLIE_SOCKET/COLLIE_TERMINAL_ID/COLLIE_TOKEN missing"); return (nil, nil)
        }
        let active = HookPayload.claudeStopHookActive(stdinJSON: stdin)
        var args: [String: JSONValue] = ["source": .string("claude")]
        if let active { args[active ? "continued" : "capture"] = .bool(true) }   // unreadable: a plain turn end, no ask
        if let m = HookPayload.claudeStopMessage(stdinJSON: stdin) { args["message"] = .string(m) }
        if let t = HookPayload.transcriptPath(stdinJSON: stdin) { args["transcript"] = .string(t) }
        do {
            let r = try await UnixSocketClient.send(Request(id: UUID().uuidString, terminalId: tid, token: tok, command: "turn.completed", args: args),
                                                    to: URL(fileURLWithPath: sock), timeoutSeconds: 5)
            guard r.ok else { onError(r.error?.message ?? "turn.completed failed"); return (nil, nil) }
            guard active == false, case .object(let o)? = r.result else { return (nil, nil) }
            func text(_ k: String) -> String? { if case .string(let s)? = o[k], !s.isEmpty { return s }; return nil }
            return (text("ask"), text("advice"))
        } catch { onError("\(error)"); return (nil, nil) }
    }
}
