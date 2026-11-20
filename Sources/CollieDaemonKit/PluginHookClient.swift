import Foundation
import CollieCore
import CollieProtocol

/// What `collie hook claude-tool` / `claude-stop` do about plug-ins, minus the process plumbing (so it can be tested).
/// Everything fails open: any error is a line for `onError` and nothing printed; `work.hook` / `turn.completed` never wait on a plug-in.
public enum PluginHookClient {
    /// `collie hook claude-tool` and its siblings: always sends `work.hook`; for `claude-tool` then asks `plugin.hook` (`edit`)
    /// and returns the PostToolUse reply (guide or block), or nil.
    public static func toolOutput(hook: String, payload: Data, env: [String: String], timeout: Double = 4,
                                  onError: (String) -> Void = { _ in }) async -> String? {
        guard let creds = Creds(env) else { onError("COLLIE_SOCKET/COLLIE_TERMINAL_ID/COLLIE_TOKEN missing"); return nil }
        let body = JSONValue.string(String(decoding: payload, as: UTF8.self))
        do {
            let r = try await creds.send("work.hook", ["hook": .string(String(hook.dropFirst("claude-".count))), "payload": body], timeout: 2)
            if !r.ok { onError(r.error?.message ?? "work.hook failed") }
        } catch { onError("work.hook: \(error)") }
        guard hook == "claude-tool" else { return nil }
        return await verdict(creds, event: "edit", payload: body, timeout: timeout, onError: onError).flatMap(PluginHooks.claudeToolOutput)
    }

    /// `collie hook claude-stop`: the memory flow first (`turn.completed` always goes out), then `plugin.hook` (`stop`).
    /// One block with the plug-in's reason first and the memory ask after it; a continued Stop never blocks.
    public static func stopOutput(stdin: Data, env: [String: String], timeout: Double = 4,
                                  onError: (String) -> Void = { _ in }) async -> String? {
        let ask = await MemoryHookClient.stopAsk(stdin: stdin, env: env, onError: onError)
        var reasons: [String] = []
        // the plug-in call still goes out on a continued Stop (the daemon clears the turn's files), but its answer is dropped
        if let creds = Creds(env), stdin.count <= PluginHooks.maxInput,
           let v = await verdict(creds, event: "stop", payload: .string(String(decoding: stdin, as: UTF8.self)), timeout: timeout, onError: onError),
           HookPayload.claudeStopHookActive(stdinJSON: stdin) == false, let block = PluginHooks.claudeStopReason(v) {
            reasons.append(block)
        }
        if let ask { reasons.append(ask) }
        return reasons.isEmpty ? nil : HookPayload.claudeStopBlock(reason: reasons.joined(separator: "\n\n"))
    }

    private struct Creds {
        let sock: String, tid: String, tok: String
        init?(_ env: [String: String]) {
            guard let s = env["COLLIE_SOCKET"], let t = env["COLLIE_TERMINAL_ID"], let k = env["COLLIE_TOKEN"] else { return nil }
            sock = s; tid = t; tok = k
        }
        func send(_ command: String, _ args: [String: JSONValue], timeout: Double) async throws -> Response {
            try await UnixSocketClient.send(Request(id: UUID().uuidString, terminalId: tid, token: tok, command: command, args: args),
                                            to: URL(fileURLWithPath: sock), timeoutSeconds: timeout)
        }
    }

    private static func verdict(_ creds: Creds, event: String, payload: JSONValue, timeout: Double,
                                onError: (String) -> Void) async -> PluginHooks.Verdict? {
        do {
            let r = try await creds.send("plugin.hook", ["event": .string(event), "payload": payload], timeout: timeout)
            guard r.ok else { onError(r.error?.message ?? "plugin.hook failed"); return nil }
            guard case .object(let o)? = r.result else { return nil }
            var v = PluginHooks.Verdict()
            for (key, value) in o where key == "guide" || key == "block" {
                guard case .string(let s) = value else { onError("plugin.hook: malformed reply"); return nil }
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                if key == "guide" { v.guide = t } else { v.block = t }
            }
            return v.guide == nil && v.block == nil ? nil : v
        } catch { onError("plugin.hook: \(error)"); return nil }
    }
}
