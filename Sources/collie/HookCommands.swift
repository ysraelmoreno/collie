import Foundation
import CollieCore
import CollieProtocol
import CollieDaemonKit

/// `collie hook ...`: never fails, never prints (but the memory hooks print their injection JSON, and claude-stop its block reply). Errors go to hooks.log.
enum HookCommands {
    static func run(_ args: [String]) async {
        do { try await dispatch(args) } catch { log("\(args.first ?? "?"): \(error)") }
    }

    private static func dispatch(_ a: [String]) async throws {
        var message: String?
        var source = "generic"
        switch a.first {
        case "claude-session-start", "claude-prompt":
            // prints the injection JSON on success only; every failure is just a log line
            let isPrompt = a.first == "claude-prompt"
            let prompt = isPrompt ? HookPayload.userPromptSubmitPrompt(stdinJSON: FileHandle.standardInput.readDataToEndOfFile()) : nil
            if isPrompt && prompt == nil { log("claude-prompt: no prompt in the stdin payload"); return }
            if let out = await MemoryHookClient.output(event: isPrompt ? .userPromptSubmit : .sessionStart, prompt: prompt,
                                                       env: ProcessInfo.processInfo.environment, onError: { log("\(a[0]): \($0)") }) {
                print(out)
            }
            return
        case "claude-tool", "claude-subagent-stop", "claude-precompact", "claude-session-end", "claude-notification":
            // the work registry and approvals: the raw payload goes to the daemon, which parses it (WorkHookParser, HookPayload)
            let stdin = FileHandle.standardInput
            let data = try stdin.read(upToCount: WorkHookParser.maxBytes + 1) ?? Data()
            guard data.count <= WorkHookParser.maxBytes else {
                while let more = try stdin.read(upToCount: 1 << 16), !more.isEmpty {}   // drained: the agent's write never breaks
                log("\(a[0]): payload over 64 KiB, dropped"); return
            }
            try await send("work.hook", ["hook": .string(String(a[0].dropFirst("claude-".count))),
                                         "payload": .string(String(decoding: data, as: UTF8.self))], timeout: 2)
            return
        case "claude-statusline":
            statusline()
            return
        case "claude-stop":
            // prints the block reply only when the daemon asks for one; every failure is just a log line (fail open)
            if let out = await MemoryHookClient.stopOutput(stdin: FileHandle.standardInput.readDataToEndOfFile(),
                                                           env: ProcessInfo.processInfo.environment, onError: { log("claude-stop: \($0)") }) {
                print(out)
            }
            return
        case "codex-notify":
            source = "codex"
            message = a.count > 1 ? HookPayload.codexNotifyMessage(argJSON: a[1]) : nil
        case "generic-stop":
            if let i = a.firstIndex(of: "--message"), i + 1 < a.count { message = a[i + 1] }
        default:
            throw ProtocolError(code: .invalidArgs, message: "unknown hook '\(a.first ?? "")'")
        }
        var args: [String: JSONValue] = ["source": .string(source)]
        if let message { args["message"] = .string(message) }
        try await send("turn.completed", args, timeout: 5)
    }

    /// Claude's statusLine feed: record the rate limits, then run the user's own statusLine with the same stdin and forward its stdout.
    /// Never throws, always exits 0 (the caller's bar must not break). Env: COLLIE_USAGE_DIR / COLLIE_SOCKET (where), COLLIE_CLAUDE_SETTINGS (tests).
    private static func statusline() {
        let env = ProcessInfo.processInfo.environment
        let data = (try? FileHandle.standardInput.read(upToCount: 1 << 20)) ?? Data()
        if let limits = ClaudeRateLimits.extract(data), let dir = ClaudeRateLimits.usageDir(env: env) {
            do { try ClaudeRateLimits.write(limits, to: dir) } catch { log("claude-statusline: \(error)") }
        }
        let settings = env["COLLIE_CLAUDE_SETTINGS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
        guard env["COLLIE_STATUSLINE_CHILD"] == nil,   // recursion guard: we are already inside a user statusLine
              let sd = try? Data(contentsOf: settings), let cmd = ClaudeRateLimits.userStatusLineCommand(settings: sd),
              !ClaudeRateLimits.invokesOurHook(cmd) else { return }
        if let out = ClaudeRateLimits.runUserCommand(cmd, stdin: data, env: env.merging(["COLLIE_STATUSLINE_CHILD": "1"]) { $1 }) {
            FileHandle.standardOutput.write(out)
        }
    }

    /// `command` with the terminal's credentials (COLLIE_SOCKET/COLLIE_TERMINAL_ID/COLLIE_TOKEN).
    private static func send(_ command: String, _ args: [String: JSONValue], timeout: Double) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let sock = env["COLLIE_SOCKET"], let tid = env["COLLIE_TERMINAL_ID"], let tok = env["COLLIE_TOKEN"] else {
            throw ProtocolError(code: .invalidArgs, message: "COLLIE_SOCKET/COLLIE_TERMINAL_ID/COLLIE_TOKEN missing")
        }
        let r = try await UnixSocketClient.send(
            Request(id: UUID().uuidString, terminalId: tid, token: tok, command: command, args: args),
            to: URL(fileURLWithPath: sock), timeoutSeconds: timeout)
        if !r.ok { throw r.error ?? ProtocolError(code: .internal, message: "\(command) failed") }
    }

    private static func log(_ line: String) {
        let dir = ProcessInfo.processInfo.environment["COLLIE_LOG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Collie")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("hooks.log")
        if !FileManager.default.fileExists(atPath: f.path) { FileManager.default.createFile(atPath: f.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: f) else { return }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8))
        try? h.close()
    }
}
