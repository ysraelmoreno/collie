import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// A fake daemon on a socket: records every command and answers `plugin.hook` / `turn.completed` / `work.hook` from `replies`.
private final class Fake: @unchecked Sendable {
    let dir = URL(fileURLWithPath: "/tmp/colliet-\(UUID().uuidString.prefix(8))")
    var sock: URL { dir.appendingPathComponent("s.sock") }
    private let lock = NSLock()
    private var seen: [(String, [String: JSONValue])] = []
    var server: UnixSocketServer?
    var commands: [String] { lock.withLock { seen.map(\.0) } }
    func args(_ c: String) -> [String: JSONValue]? { lock.withLock { seen.first { $0.0 == c }?.1 } }
    var env: [String: String] { ["COLLIE_SOCKET": sock.path, "COLLIE_TERMINAL_ID": "t", "COLLIE_TOKEN": "k"] }

    init(plugin: [String: JSONValue]? = nil, turn: [String: JSONValue] = [:], pluginDelay: Double = 0, pluginOK: Bool = true) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = UnixSocketServer(path: sock) { [unowned self] r in
            lock.withLock { seen.append((r.command, r.args)) }
            switch r.command {
            case "plugin.hook":
                if pluginDelay > 0 { try? await Task.sleep(for: .seconds(pluginDelay)) }
                guard pluginOK else { return Response(id: r.id, ok: false, error: ProtocolError(code: .internal, message: "boom")) }
                return Response(id: r.id, ok: true, result: plugin.map { .object($0) } ?? .object([:]))
            case "turn.completed": return Response(id: r.id, ok: true, result: .object(turn))
            default: return Response(id: r.id, ok: true, result: .object([:]))
            }
        }
        try s.start(); server = s
    }
    deinit { server?.stop(); try? FileManager.default.removeItem(at: dir) }
}

private let editPayload = Data(#"{"tool_name":"Edit","tool_input":{"file_path":"/p/A.swift"}}"#.utf8)
private func json(_ s: String?) -> [String: Any]? {
    s.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
}
private let plain = Data(#"{"stop_hook_active":false}"#.utf8)
private let continued = Data(#"{"stop_hook_active":true}"#.utf8)

@Suite(.serialized) struct PluginHookClientTests {
    @Test func editGuideIsAdditionalContext() async throws {
        let f = try Fake(plugin: ["guide": .string("follow Foo")])
        let out = await PluginHookClient.toolOutput(hook: "claude-tool", payload: editPayload, env: f.env)
        let h = try #require(json(out)?["hookSpecificOutput"] as? [String: Any])
        #expect(h["hookEventName"] as? String == "PostToolUse" && h["additionalContext"] as? String == "follow Foo")
        #expect(f.commands == ["work.hook", "plugin.hook"])
        #expect(f.args("plugin.hook")?["event"] == .string("edit"))
    }

    @Test func editBlockIsDecisionBlock() async throws {
        let f = try Fake(plugin: ["block": .string("no")])
        let o = try #require(json(await PluginHookClient.toolOutput(hook: "claude-tool", payload: editPayload, env: f.env)))
        #expect(o["decision"] as? String == "block" && o["reason"] as? String == "no")
    }

    @Test func editWithoutVerdictPrintsNothing() async throws {
        let f = try Fake()
        #expect(await PluginHookClient.toolOutput(hook: "claude-tool", payload: editPayload, env: f.env) == nil)
    }

    @Test func otherHooksSkipPlugins() async throws {
        let f = try Fake(plugin: ["block": .string("no")])
        #expect(await PluginHookClient.toolOutput(hook: "claude-subagent-stop", payload: editPayload, env: f.env) == nil)
        #expect(f.commands == ["work.hook"])
    }

    @Test func workHookGoesOutWhenPluginFails() async throws {
        let f = try Fake(pluginOK: false)
        var errors: [String] = []
        #expect(await PluginHookClient.toolOutput(hook: "claude-tool", payload: editPayload, env: f.env, onError: { errors.append($0) }) == nil)
        #expect(f.commands == ["work.hook", "plugin.hook"] && errors.count == 1)
    }

    @Test func stopBlockBlocks() async throws {
        let f = try Fake(plugin: ["block": .string("fix root cause")])
        let o = try #require(json(await PluginHookClient.stopOutput(stdin: plain, env: f.env)))
        #expect(o["decision"] as? String == "block" && o["reason"] as? String == "fix root cause")
        #expect(f.args("plugin.hook")?["event"] == .string("stop"))
    }

    @Test func stopBlockAndAskShareOneBlock() async throws {
        let f = try Fake(plugin: ["block": .string("PLUGIN")], turn: ["ask": .string("MEMORY")])
        let o = try #require(json(await PluginHookClient.stopOutput(stdin: plain, env: f.env)))
        let reason = try #require(o["reason"] as? String)
        #expect(reason.hasPrefix("PLUGIN") && reason.hasSuffix("MEMORY") && o["decision"] as? String == "block")
    }

    @Test func stopAskAloneStillBlocks() async throws {
        let f = try Fake(turn: ["ask": .string("MEMORY")])
        let o = try #require(json(await PluginHookClient.stopOutput(stdin: plain, env: f.env)))
        #expect(o["reason"] as? String == "MEMORY")
    }

    @Test func continuedStopNeverBlocks() async throws {
        let f = try Fake(plugin: ["block": .string("PLUGIN")], turn: ["ask": .string("MEMORY")])
        #expect(await PluginHookClient.stopOutput(stdin: continued, env: f.env) == nil)
        #expect(f.commands.contains("turn.completed"))
    }

    @Test func silentDaemonPrintsNothingWithinDeadline() async throws {
        let f = try Fake(plugin: ["block": .string("late")], pluginDelay: 20)
        let t0 = Date()
        #expect(await PluginHookClient.toolOutput(hook: "claude-tool", payload: editPayload, env: f.env, timeout: 0.3) == nil)
        #expect(await PluginHookClient.stopOutput(stdin: plain, env: f.env, timeout: 0.3) == nil)
        #expect(Date().timeIntervalSince(t0) < 5)
        #expect(f.commands.contains("work.hook") && f.commands.contains("turn.completed"))
    }

    @Test func daemonDownPrintsNothing() async {
        let env = ["COLLIE_SOCKET": "/tmp/colliet-none/s.sock", "COLLIE_TERMINAL_ID": "t", "COLLIE_TOKEN": "k"]
        #expect(await PluginHookClient.toolOutput(hook: "claude-tool", payload: editPayload, env: env) == nil)
        #expect(await PluginHookClient.stopOutput(stdin: plain, env: env) == nil)
    }

    @Test func cursorToolPrintsAdditionalContextAndSendsOnlyPluginHook() async throws {
        let f = try Fake(plugin: ["guide": .string("follow Foo")])
        let post = try PluginHooksTests.fixture("postToolUse-write")
        let out = await PluginHookClient.cursorToolOutput(payload: post, env: f.env)
        #expect(json(out)?["additional_context"] as? String == "follow Foo")
        #expect(f.commands == ["plugin.hook"] && f.args("plugin.hook")?["event"] == .string("edit"))
    }

    @Test func cursorToolBlockBecomesContextAndErrorsFailOpen() async throws {
        let b = try Fake(plugin: ["block": .string("no")])
        let post = try PluginHooksTests.fixture("postToolUse-write")
        #expect(json(await PluginHookClient.cursorToolOutput(payload: post, env: b.env))?["additional_context"] as? String == "no")
        let bad = try Fake(pluginOK: false)
        var errors: [String] = []
        #expect(await PluginHookClient.cursorToolOutput(payload: post, env: bad.env, onError: { errors.append($0) }) == nil && errors.count == 1)
        #expect(await PluginHookClient.cursorToolOutput(payload: post, env: [:]) == nil)
    }

    @Test func cursorPreToolUsePrintsNothingEvenWhenAPluginSpeaks() async throws {
        let f = try Fake(plugin: ["block": .string("no")])
        #expect(await PluginHookClient.cursorToolOutput(payload: try PluginHooksTests.fixture("preToolUse-read"), env: f.env) == nil)
        #expect(f.commands == ["plugin.hook"])   // still sent: it is the in-turn mark
    }
}
