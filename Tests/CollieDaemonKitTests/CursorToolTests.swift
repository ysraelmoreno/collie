import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// D1: Cursor's `preToolUse`/`postToolUse` mark the terminal as mid-turn (an ask does not close on idle in the middle of a
/// long tool), and the end of a Cursor turn is the plug-ins' `stop`.
@Suite(.serialized) struct CursorToolTests {
    private struct Term { var id: String; var token: String }
    private func term(_ d: Daemon, _ p: Paths, _ name: String, preset: String, command: String? = nil) async throws -> Term {
        let s = try await spawn(d, p, name, preset: preset, command: command)
        #expect(s.resp.ok, "spawn \(name): \(s.resp)")
        return Term(id: s.id, token: try await tokenOf(d, s.id, echo: command == nil))
    }
    private let doneFrame = "for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo done$i; done"

    /// An ask to a Cursor that printed a finished frame and went silent; `during` runs once the prompt is in.
    private func ask(_ d: Daemon, _ p: Paths, timeout: Int, during: @escaping (Term, Paths) async throws -> Void) async throws -> Response {
        let a = try await term(d, p, "A", preset: "shell")
        let b = try await term(d, p, "B", preset: "cursor", command: "echo T=$COLLIE_TOKEN; read x; \(doneFrame); exec sleep 999")
        _ = try await send(p, Request(id: "c", token: d.adminToken, command: "admin.leash", args: ["a": .string("A"), "b": .string("B")]))
        async let r = send(p, Request(id: "a", terminalId: a.id, token: a.token, command: "ask",
                                      args: ["target": .string("B"), "prompt": .string("go"), "timeout": .number(Double(timeout))]),
                           timeoutSeconds: Double(timeout) + 10)
        try await Task.sleep(for: .milliseconds(600))
        try await during(b, p)
        return try await r
    }
    private func tool(_ t: Term, _ p: Paths, _ fixture: String) async throws {
        let payload = String(decoding: try PluginHooksTests.fixture(fixture), as: UTF8.self)
        let r = try await send(p, Request(id: "h", terminalId: t.id, token: t.token, command: "plugin.hook",
                                          args: ["event": .string("edit"), "payload": .string(payload)]))
        #expect(r.ok, "\(r)")
    }

    @Test func aToolRunningLongerThanIdleQuietDoesNotCloseTheAsk() async throws {
        try await withDaemon(configure: { $0.idleQuietSeconds = 1 }) { d, p in
            let r = try await ask(d, p, timeout: 6) { b, p in try await tool(b, p, "preToolUse-read") }   // a pre, never a post
            #expect(r.error?.code == .timeout, "\(r)")
        }
    }

    @Test func theToolEndingLetsIdleCloseTheAsk() async throws {
        try await withDaemon(configure: { $0.idleQuietSeconds = 1 }) { d, p in
            let r = try await ask(d, p, timeout: 15) { b, p in
                try await tool(b, p, "preToolUse-read"); try await tool(b, p, "postToolUse-write")
            }
            guard case .object(let o)? = r.result, case .string(let s)? = o["source"] else { Issue.record("\(r)"); return }
            #expect(s == "idle")
        }
    }

    /// Block at the end of a Cursor turn: exactly one continuation prompt; the continuation's own end asks the plug-ins nothing.
    @Test func blockAtTheEndOfATurnInjectsOnePrompt() async throws {
        try await withDaemon(configure: { $0.idleQuietSeconds = 1 }) { d, p in
            let log = p.root.appendingPathComponent("got.txt")
            let id = try #require(UUID(uuidString: try await spawn(d, p, "B", preset: "cursor", command: "while read l; do echo \"$l\" >> '\(log.path)'; done").id))
            await d.router.noteTurnFiles(["A.swift"], id)
            // inject returns once the continuation ended by idle: that end (a turn end too) must not block again
            await d.router.cursorStop(id) { _ in .init(block: "fix the SQL in A.swift") }
            try await Task.sleep(for: .seconds(3))
            let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.contains("fix the SQL in A.swift") }
            #expect(lines.count == 1, "\(lines)")
        }
    }

    @Test func guideAtTheEndOfATurnIsIgnored() async throws {
        try await withDaemon(configure: { $0.idleQuietSeconds = 1 }) { d, p in
            let log = p.root.appendingPathComponent("got2.txt")
            let id = try #require(UUID(uuidString: try await spawn(d, p, "B", preset: "cursor", command: "while read l; do echo \"$l\" >> '\(log.path)'; done").id))
            await d.router.noteTurnFiles(["A.swift"], id)
            await d.router.cursorStop(id) { _ in .init(guide: "just FYI") }
            try await Task.sleep(for: .seconds(2))
            #expect(!((try? String(contentsOf: log, encoding: .utf8)) ?? "").contains("FYI"))
        }
    }
}
