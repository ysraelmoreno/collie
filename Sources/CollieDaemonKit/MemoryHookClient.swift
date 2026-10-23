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
    public static func output(event: Event, prompt: String?, env: [String: String],
                              onError: (String) -> Void = { _ in }) async -> String? {
        guard let sock = env["COLLIE_SOCKET"], let tid = env["COLLIE_TERMINAL_ID"], let tok = env["COLLIE_TOKEN"] else {
            onError("COLLIE_SOCKET/COLLIE_TERMINAL_ID/COLLIE_TOKEN missing"); return nil
        }
        var args: [String: JSONValue] = [:]
        if event == .userPromptSubmit { args["prompt"] = .string(HookPayload.boundedPrompt(prompt ?? "")) }
        do {
            let r = try await UnixSocketClient.send(
                Request(id: UUID().uuidString, terminalId: tid, token: tok,
                        command: event == .sessionStart ? "memory.hookContext" : "memory.hookRelevant", args: args),
                to: URL(fileURLWithPath: sock), timeoutSeconds: 5)
            guard r.ok else { onError(r.error?.message ?? "memory hook failed"); return nil }
            guard case .object(let o)? = r.result, case .string(let text)? = o["output"], !text.isEmpty else { return nil }
            let json: [String: Any] = ["hookSpecificOutput": ["hookEventName": event.rawValue, "additionalContext": text]]
            guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes]) else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch { onError("\(error)"); return nil }
    }

    /// `collie hook claude-stop`: reports the turn's end (`turn.completed`, which also clears a pending approval) and returns
    /// the block reply when the daemon asks the agent to record what it learned. nil — no block — on a continued Stop
    /// (`stop_hook_active`), when there is nothing to ask, and on any error or timeout (fail open). Never writes to a PTY.
    public static func stopOutput(stdin: Data, env: [String: String], onError: (String) -> Void = { _ in }) async -> String? {
        guard let sock = env["COLLIE_SOCKET"], let tid = env["COLLIE_TERMINAL_ID"], let tok = env["COLLIE_TOKEN"] else {
            onError("COLLIE_SOCKET/COLLIE_TERMINAL_ID/COLLIE_TOKEN missing"); return nil
        }
        let active = HookPayload.claudeStopHookActive(stdinJSON: stdin)
        var args: [String: JSONValue] = ["source": .string("claude")]
        if let active { args[active ? "continued" : "capture"] = .bool(true) }   // unreadable: a plain turn end, no ask
        if let m = HookPayload.claudeStopMessage(stdinJSON: stdin) { args["message"] = .string(m) }
        do {
            let r = try await UnixSocketClient.send(Request(id: UUID().uuidString, terminalId: tid, token: tok, command: "turn.completed", args: args),
                                                    to: URL(fileURLWithPath: sock), timeoutSeconds: 5)
            guard r.ok else { onError(r.error?.message ?? "turn.completed failed"); return nil }
            guard active == false, case .object(let o)? = r.result, case .string(let reason)? = o["ask"], !reason.isEmpty else { return nil }
            return HookPayload.claudeStopBlock(reason: reason)
        } catch { onError("\(error)"); return nil }
    }
}
