import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// DX backlog 20: `collie model <terminal> <model>`, `summon --model`, and `ask "/…"` refused.
@Suite struct ClaudeModelParseTests {
    @Test func readsClaudesAnswers() {
        // as Claude 2.1.319 prints them, cursor moves already spaces (ANSI.strip)
        #expect(ClaudeModel.parse("❯ /model opus\n  ⎿  Set model to Opus 5.5 and saved as your default for new sessions\n") == .set("Opus 5.5"))
        #expect(ClaudeModel.parse("  ⎿  Set  model  to  Sonnet  5.5  and saved as your default\n") == .set("Sonnet 5.5"))
        #expect(ClaudeModel.parse("  ⎿  Kept model as Opus 5.5                    ◐ medium · /effort\n") == .set("Opus 5.5"))
        #expect(ClaudeModel.parse("Set model to Opus 5.5 and saved as your default for new sessions ◐ medium · /effort─────") == .set("Opus 5.5"))
        #expect(ClaudeModel.parse("  ⎿  Model 'bogus-xyz' not found\n") == .notFound("bogus-xyz"))
        #expect(ClaudeModel.parse("❯ /model opus\n") == nil)   // only the echo yet
    }

    @Test func modelNamesAreOneWord() throws {
        for ok in ["opus", "sonnet", "claude-opus-5-5", "opus[1m]", "default"] { try ClaudeModel.validate(ok) }
        for bad in ["", "opus sonnet", "opus\n/clear", "-x", "it's"] {
            #expect(throws: ProtocolError.self) { try ClaudeModel.validate(bad) }
        }
    }

    @Test func slashPromptsToAgentsAreRefused() {
        let claude = TerminalRecord(id: UUID(), name: "dev", preset: .claude, command: nil, cwd: "/tmp", isShepherd: false)
        let shell = TerminalRecord(id: UUID(), name: "sh", preset: .shell, command: nil, cwd: "/tmp", isShepherd: false)
        #expect(ClaudeModel.slashRefusal("/model opus", target: claude)?.message.hasPrefix("use collie model dev opus") == true)
        #expect(ClaudeModel.slashRefusal("  /compact", target: claude)?.message.contains("/compact is a slash command") == true)
        #expect(ClaudeModel.slashRefusal("/Users/me/a.txt: explain it", target: claude) == nil)   // a path
        #expect(ClaudeModel.slashRefusal("fix /model handling", target: claude) == nil)
        #expect(ClaudeModel.slashRefusal("/model opus", target: shell) == nil)
    }
}

private struct Term { var id: String; var token: String }

private func term(_ d: Daemon, _ p: Paths, _ name: String, preset: String = "shell", command: String? = nil, idle: Bool = true) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string(preset), "cwd": .string("/tmp")]
    if let command { args["command"] = .string(command) }
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args))
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    let t = Term(id: id, token: try await tokenOf(d, id, echo: command == nil))
    if idle { #expect(await waitFor(10) { await d.badge(UUID(uuidString: id)!) == .idle }) }   // its start's output is over
    return t
}

private func call(_ p: Paths, _ from: Term, _ command: String, _ args: [String: JSONValue], timeout: Double = 30) async throws -> Response {
    try await send(p, Request(id: "m", terminalId: from.id, token: from.token, command: command, args: args), timeoutSeconds: timeout)
}

private func field(_ r: Response, _ k: String) -> JSONValue? {
    if case .object(let o)? = r.result { return o[k] } else { return nil }
}

/// A Claude stand-in: answers `/model` lines as Claude 2.1.319 does.
private let fakeClaude = #"echo T=$COLLIE_TOKEN; while IFS= read -r l; do case "$l" in *bogus*) echo "  Model 'bogus' not found";; "/model "*) echo "  Set model to Opus 5.5 and saved as your default for new sessions";; esac; done"#
private let silent = "echo T=$COLLIE_TOKEN; exec cat >/dev/null"
private let busy = "echo T=$COLLIE_TOKEN; while :; do echo .; sleep 0.3; done"

@Suite(.serialized) struct ModelCommandTests {
    @Test func summonPassesTheModel() async throws {
        try await withDaemon { d, p in
            var args: [String: JSONValue] = ["name": .string("M"), "preset": .string("shell"), "cwd": .string("/tmp"), "shepherd": .bool(true)]
            let r0 = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args))
            guard case .object(let o)? = r0.result, case .string(let id)? = o["id"] else { Issue.record("\(r0)"); return }
            let m = Term(id: id, token: try await tokenOf(d, id))
            let bad = try await call(p, m, "summon", ["name": .string("s1"), "preset": .string("shell"), "model": .string("opus")])
            #expect(bad.error?.code == .invalidArgs && bad.error?.message.contains("--model is for claude") == true, "\(bad)")
            args = ["name": .string("c1"), "preset": .string("claude"), "command": .string(silent), "model": .string("opus")]
            #expect(try await call(p, m, "summon", args).ok)
            let l = try await call(p, m, "list", [:])
            guard case .array(let rows)? = l.result else { Issue.record("\(l)"); return }
            #expect(rows.contains { if case .object(let o) = $0 { o["name"] == .string("c1") && o["model"] == .string("opus") } else { false } }, "\(rows)")
        }
    }

    @Test func switchesTheModelAndShowsIt() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            let b = try await term(d, p, "B", preset: "claude", command: fakeClaude)
            #expect(try await send(p, Request(id: "c", token: d.adminToken, command: "admin.leash", args: ["a": .string("A"), "b": .string("B")])).ok)
            let t0 = ContinuousClock.now
            let r = try await call(p, a, "model", ["target": .string("B"), "model": .string("opus")])
            #expect(r.ok && field(r, "model") == .string("Opus 5.5"), "\(r)")
            #expect(ContinuousClock.now - t0 < .seconds(5))
            let l = try await call(p, a, "list", [:])
            guard case .array(let rows)? = l.result else { Issue.record("\(l)"); return }
            #expect(rows.contains { if case .object(let o) = $0 { o["name"] == .string("B") && o["model"] == .string("opus") } else { false } }, "\(rows)")
            #expect(field(try await call(p, a, "check", ["target": .string("B")]), "model") == .string("opus"))
            // the app (admin token) too, once B's answer is no longer fresh output (a hookless stand-in: its badge)
            #expect(await waitFor(10) { await d.badge(UUID(uuidString: b.id)!) == .idle })
            let app = try await send(p, Request(id: "m", token: d.adminToken, command: "model", args: ["target": .string("B"), "model": .string("sonnet")]), timeoutSeconds: 30)
            #expect(app.ok, "\(app)")
        }
    }

    @Test func unknownModelFailsFastWithClaudesReason() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            _ = try await term(d, p, "B", preset: "claude", command: fakeClaude)
            #expect(try await send(p, Request(id: "c", token: d.adminToken, command: "admin.leash", args: ["a": .string("A"), "b": .string("B")])).ok)
            let t0 = ContinuousClock.now
            let r = try await call(p, a, "model", ["target": .string("B"), "model": .string("bogus")])
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("model 'bogus' not found") == true, "\(r)")
            #expect(ContinuousClock.now - t0 < .seconds(5))
        }
    }

    @Test func refusesWhatItCannotDo() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            _ = try await term(d, p, "S")
            let wt = try await term(d, p, "W", preset: "claude", command: busy, idle: false)
            _ = try await term(d, p, "Q", preset: "claude", command: silent)
            for n in ["S", "W", "Q"] {
                #expect(try await send(p, Request(id: "c", token: d.adminToken, command: "admin.leash", args: ["a": .string("A"), "b": .string(n)])).ok)
            }
            let s = try await call(p, a, "model", ["target": .string("S"), "model": .string("opus")])
            #expect(s.error?.code == .invalidArgs && s.error?.message.contains("not claude") == true, "\(s)")
            #expect(await waitFor(10) { await d.badge(UUID(uuidString: wt.id)!) == .working })
            let w = try await call(p, a, "model", ["target": .string("W"), "model": .string("opus")])
            #expect(w.error?.code == .unavailable && w.error?.message.contains("--wait") == true, "\(w)")
            let ww = try await call(p, a, "model", ["target": .string("W"), "model": .string("opus"), "wait": .bool(true), "timeout": .number(1)])
            #expect(ww.error?.code == .timeout, "\(ww)")
            // nothing answers: a short timeout with the reason, never the ask's 1800 s
            let t0 = ContinuousClock.now
            let q = try await call(p, a, "model", ["target": .string("Q"), "model": .string("opus")])
            #expect(q.error?.code == .timeout && q.error?.message.contains("did not confirm") == true, "\(q)")
            #expect(ContinuousClock.now - t0 < .seconds(15))
            // an ask with a slash command fails at once, naming the right command
            let k = try await call(p, a, "ask", ["target": .string("Q"), "prompt": .string("/model opus")])
            #expect(k.error?.code == .invalidArgs && k.error?.message.contains("collie model Q opus") == true, "\(k)")
        }
    }

}
