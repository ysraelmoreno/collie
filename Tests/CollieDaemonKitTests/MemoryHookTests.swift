import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String
    func env(_ p: Paths) -> [String: String] { ["COLLIE_SOCKET": p.socket.path, "COLLIE_TERMINAL_ID": id, "COLLIE_TOKEN": token] }
}
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args), to: p.socket, timeoutSeconds: 60)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL, command: String? = nil) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string(command == nil ? "shell" : "custom"), "cwd": .string(cwd.path)]
    if let command { args["command"] = .string(command) }
    let r = try await admin(d, p, "admin.spawn", args)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func save(_ p: Paths, _ t: Term, _ subject: String, _ title: String, body: String = "") async throws {
    let r = try await UnixSocketClient.send(Request(id: "s", terminalId: t.id, token: t.token, command: "memory.save",
        args: ["kind": .string("decision"), "subject": .string(subject), "title": .string(title), "body": .string(body)]), to: p.socket, timeoutSeconds: 60)
    #expect(r.ok, "\(r)")
}
private func additional(_ json: String?, _ event: String) -> String? {
    guard let json, let o = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
          let h = o["hookSpecificOutput"] as? [String: Any], h["hookEventName"] as? String == event else { return nil }
    return h["additionalContext"] as? String
}

@Suite(.serialized, .memoryPT) struct MemoryHookTests {
    @Test func claudeSettingsHaveSessionAndPromptHooks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = TerminalRecord(id: UUID(), name: "A", preset: .claude, command: nil, cwd: "/tmp", isShepherd: false)
        _ = try AgentLaunch.launchSpec(for: rec, env: [:], hooksDir: dir, collie: URL(fileURLWithPath: "/opt/o rq/collie"), shell: "/bin/zsh")
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: AgentLaunch.settingsFile(rec.id, in: dir))) as! [String: Any]
        let hooks = o["hooks"] as! [String: Any]
        for (event, sub, timeout) in [("Stop", "claude-stop", 12), ("SessionStart", "claude-session-start", 5), ("UserPromptSubmit", "claude-prompt", 5)] {
            let e = ((hooks[event] as! [[String: Any]])[0]["hooks"] as! [[String: Any]])[0]
            #expect(e["type"] as? String == "command" && e["timeout"] as? Int == timeout)
            #expect(e["command"] as? String == "'/opt/o rq/collie' hook \(sub)", "\(event)")
        }
    }

    @Test func sessionHookOutputsAdditionalContext() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            try await save(p, t, "database", "Use Postgres")
            let out = await MemoryHookClient.output(event: .sessionStart, prompt: nil, env: t.env(p))
            let text = try #require(additional(out, "SessionStart"))
            #expect(text.contains("Use Postgres") && !(out ?? "").contains("\n"))
        }
    }

    /// Cursor's sessionStart output: `{"additional_context": …}`, the same text Claude gets.
    @Test func cursorSessionStartUsesAdditionalContext() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            try await save(p, t, "database", "Use Postgres")
            let out = try #require(await MemoryHookClient.output(event: .sessionStart, prompt: nil, cursor: true, env: t.env(p)))
            let o = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
            let text = try #require(o["additional_context"] as? String)
            #expect(o.count == 1 && text.hasPrefix("You are running inside Collie") && text.contains("Use Postgres"))
        }
    }

    /// A Cursor Shepherd's sessionStart also carries the delegation brief (the plugin rule alone was not followed); a plain Cursor and Claude do not.
    @Test func cursorShepherdSessionStartCarriesTheDelegateBrief() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            var env = t.env(p)
            func text(_ e: [String: String], cursor: Bool = true) async throws -> String {
                let out = try #require(await MemoryHookClient.output(event: .sessionStart, prompt: nil, cursor: cursor, env: e))
                let o = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
                return try #require((o["additional_context"] ?? (o["hookSpecificOutput"] as? [String: Any])?["additionalContext"]) as? String)
            }
            #expect(!(try await text(env)).contains("Do not do that work yourself"))
            env["COLLIE_SHEPHERD"] = "1"
            let shepherd = try await text(env)
            #expect(shepherd.hasPrefix("You are running inside Collie") && shepherd.hasSuffix(AgentLaunch.delegateBrief) && shepherd.count < 10_000)
            #expect(!(try await text(env, cursor: false)).contains("Do not do that work yourself"))
        }
    }

    @Test func promptHookInjectsOnlyRelevantOnce() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            try await save(p, t, "database", "Use Postgres", body: "chosen for jsonb support")
            let prompt = "why did we choose postgres for jsonb?"
            let first = await MemoryHookClient.output(event: .userPromptSubmit, prompt: prompt, env: t.env(p))
            #expect(additional(first, "UserPromptSubmit")?.contains("Use Postgres") == true, "\(first ?? "nil")")
            #expect(await MemoryHookClient.output(event: .userPromptSubmit, prompt: prompt, env: t.env(p)) == nil)
            #expect(await MemoryHookClient.output(event: .userPromptSubmit, prompt: "unrelated kubernetes thing", env: t.env(p)) == nil)
        }
    }

    /// PRD B3.1: a memory enforced by a check is not injected by the prompt hook; cleared, it is again.
    @Test func enforcedMemoryIsNotInjectedByThePromptHook() async throws {
        let repo = try await makeRepo()
        try Data("#!/bin/sh\n".utf8).write(to: repo.appendingPathComponent("lint.sh"))
        for args in [["add", "lint.sh"], ["commit", "-q", "-m", "lint"]] { _ = try await GitRunner.run(args, in: repo) }   // B3.4: --by is tracked in HEAD
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            try await save(p, t, "database", "Use Postgres", body: "chosen for jsonb support")
            let id = try #require(try await d.router.memory.repo(for: repo.path).run { $0.store.all().records.first?.id })
            func enforce(_ args: [String: JSONValue]) async throws -> Response {
                try await UnixSocketClient.send(Request(id: "e", terminalId: t.id, token: t.token, command: "memory.enforce",
                                                        args: args.merging(["id": .string(id.uuidString)]) { a, _ in a }), to: p.socket, timeoutSeconds: 60)
            }
            let r = try await enforce(["by": .string("lint.sh")])
            #expect(r.ok, "\(r)")
            let prompt = "why did we choose postgres for jsonb?"
            #expect(await MemoryHookClient.output(event: .userPromptSubmit, prompt: prompt, env: t.env(p)) == nil)
            // B3.5: nor at session start, not even as an index title
            #expect(!(await d.router.memory.contextText(cwd: repo.path, paddock: nil)).text.contains("Use Postgres"))
            #expect(try await enforce(["clear": .bool(true)]).ok)
            #expect((await d.router.memory.contextText(cwd: repo.path, paddock: nil)).text.contains("Use Postgres"))
            let again = await MemoryHookClient.output(event: .userPromptSubmit, prompt: prompt, env: t.env(p))
            #expect(additional(again, "UserPromptSubmit")?.contains("Use Postgres") == true, "\(again ?? "nil")")
        }
    }

    @Test func hugePromptIsBounded() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            try await save(p, t, "database", "Use Postgres", body: "jsonb")
            let huge = "postgres " + String(repeating: "lorem ipsum dolor ", count: 60_000)   // ~1 MB
            #expect(huge.utf8.count > 1_000_000)
            let t0 = ContinuousClock.now
            let out = await MemoryHookClient.output(event: .userPromptSubmit, prompt: huge, env: t.env(p))
            #expect(ContinuousClock.now - t0 < .milliseconds(2500))   // answered (non-nil below), well under the hook client's 5 s timeout
            #expect((out ?? "").utf8.count <= 2048 + 200)   // 2048 B of text plus the JSON envelope
            #expect(additional(out, "UserPromptSubmit") != nil)
            #expect((additional(out, "UserPromptSubmit") ?? "").utf8.count <= 2048)
        }
    }

    @Test func hookWithoutDaemonIsSilent() async {
        var errors: [String] = []
        let env = ["COLLIE_SOCKET": "/tmp/collie-nonexistent-\(UUID().uuidString).sock", "COLLIE_TERMINAL_ID": UUID().uuidString, "COLLIE_TOKEN": "x"]
        #expect(await MemoryHookClient.output(event: .sessionStart, prompt: nil, env: env, onError: { errors.append($0) }) == nil)
        #expect(await MemoryHookClient.output(event: .userPromptSubmit, prompt: "hi", env: [:], onError: { errors.append($0) }) == nil)
        #expect(errors.count == 2)
    }

    @Test func adminCannotUseHookCommands() async throws {
        try await withDaemon { d, p in
            let a = try await admin(d, p, "memory.hookContext")
            let b = try await admin(d, p, "memory.hookRelevant", ["prompt": .string("x")])
            #expect(a.error?.code == .unauthorized && b.error?.code == .unauthorized)
            #expect(Commands.all.first { $0.name == "memory.hookRelevant" }?.exposedToMCP == false)
        }
    }

    @Test func restartEndsSession() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            try await save(p, t, "database", "Use Postgres", body: "jsonb")
            let prompt = "postgres jsonb"
            #expect(await MemoryHookClient.output(event: .userPromptSubmit, prompt: prompt, env: t.env(p)) != nil)
            #expect(await MemoryHookClient.output(event: .userPromptSubmit, prompt: prompt, env: t.env(p)) == nil)
            let id = UUID(uuidString: t.id)!
            await d.process(id)?.terminate()
            #expect(await waitFor(5) { await d.process(id)?.isRunning == false })
            let restarted = try await admin(d, p, "admin.restart", ["name": .string("T")])
            #expect(restarted.ok, "\(restarted)")
            let tok = try await tokenOf(d, t.id)
            let again = Term(id: t.id, token: tok)
            #expect(await MemoryHookClient.output(event: .userPromptSubmit, prompt: prompt, env: again.env(p)) != nil)
        }
    }
}

extension MemoryHookTests {
    @Test func hookContextStartsWithOrientation() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            func ctx() async throws -> String {
                let r = try await UnixSocketClient.send(Request(id: "h", terminalId: t.id, token: t.token, command: "memory.hookContext", args: [:]), to: p.socket, timeoutSeconds: 60)
                guard case .object(let o)? = r.result, case .string(let s)? = o["output"] else { throw ProtocolError(code: .internal, message: "\(r)") }
                return s
            }
            let before = try await ctx()   // no memories, no panels
            #expect(before.hasPrefix("You are running inside Collie") && !before.contains("collie design") && !before.contains("Memória") && !before.hasSuffix("\n") && !before.contains("\n\n"))
            #expect(try await admin(d, p, "panel.open", ["plugin": "browser", "name": "Web"]).ok)
            try await save(p, t, "database", "Use Postgres")
            let after = try await ctx()
            #expect(after.hasPrefix("You are running inside Collie") && after.contains("Browser panel \"Web\"") && after.contains("\n\nMemória") && after.contains("Use Postgres"))
        }
    }

    /// Task 3: a secret in a memory never reaches the agent, at session start or on a prompt.
    @Test func hookOutputScrubsSecrets() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            try await save(p, t, "staging deploy", "Staging deploy uses password=hunter2", body: "staging login")
            let start = try #require(additional(await MemoryHookClient.output(event: .sessionStart, prompt: nil, env: t.env(p)), "SessionStart"))
            #expect(start.contains("Staging deploy uses [hidden]") && !start.contains("hunter2"), "\(start)")
            let prompt = try #require(additional(await MemoryHookClient.output(event: .userPromptSubmit, prompt: "how is the staging deploy login done?", env: t.env(p)), "UserPromptSubmit"))
            #expect(prompt.contains("[hidden]") && !prompt.contains("hunter2"), "\(prompt)")
        }
    }
}
