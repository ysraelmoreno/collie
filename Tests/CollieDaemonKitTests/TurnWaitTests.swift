import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// DX backlog 3: `collie wait <name>` and the Shepherd's notice when a leashed agent ends a turn.
private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func term(_ d: Daemon, _ p: Paths, _ name: String, preset: String = "shell", command: String? = nil,
                  shepherd: Bool = false) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string(preset), "cwd": .string("/tmp"), "shepherd": .bool(shepherd)]
    if let command { args["command"] = .string(command) }
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args))
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id, echo: command == nil))
}

private func leash(_ d: Daemon, _ p: Paths, _ a: String, _ b: String) async throws {
    #expect(try await send(p, Request(id: "c", token: d.adminToken, command: "admin.leash", args: ["a": .string(a), "b": .string(b)])).ok)
}

private func turnEnded(_ p: Paths, _ t: Term, _ message: String) async throws {
    _ = try await send(p, Request(id: "h", terminalId: t.id, token: t.token, command: "turn.completed",
                                  args: ["message": .string(message), "source": .string("claude")]))
}

private func wait(_ p: Paths, _ from: Term, _ target: String, timeout: Int) async throws -> Response {
    try await send(p, Request(id: "w", terminalId: from.id, token: from.token, command: "wait",
                              args: ["target": .string(target), "timeout": .number(Double(timeout))]), timeoutSeconds: Double(timeout) + 10)
}

private func field(_ r: Response, _ k: String) -> JSONValue? {
    if case .object(let o)? = r.result { return o[k] } else { return nil }
}

private let quiet = "echo T=$COLLIE_TOKEN; exec cat >/dev/null"
private let busy = "echo T=$COLLIE_TOKEN; while :; do echo .; sleep 0.3; done"

@Suite(.serialized) struct TurnWaitTests {
    @Test func waitOnAnIdleAgentReturnsItsLastTurnAtOnce() async throws {
        try await withDaemon(configure: { $0.idleQuietSeconds = 15 }) { d, p in
            let a = try await term(d, p, "A")
            let b = try await term(d, p, "B", preset: "claude", command: quiet)
            try await leash(d, p, "A", "B")
            try await turnEnded(p, b, "built ok")
            #expect(await waitFor(10) { await d.badge(b.uuid) == .idle })
            let t0 = ContinuousClock.now
            let r = try await wait(p, a, "B", timeout: 20)
            #expect(ContinuousClock.now - t0 < .seconds(2), "\(r)")
            #expect(field(r, "idle") == .bool(true) && field(r, "message") == .string("built ok"), "\(r)")
        }
    }

    @Test func waitOnAWorkingAgentBlocksUntilItsTurnEnds() async throws {
        try await withDaemon(configure: { $0.idleQuietSeconds = 15 }) { d, p in
            let a = try await term(d, p, "A")
            let b = try await term(d, p, "B", preset: "claude", command: busy)
            try await leash(d, p, "A", "B")
            #expect(await waitFor(10) { await d.badge(b.uuid) == .working })
            let w = Task { try await wait(p, a, "B", timeout: 20) }
            try await Task.sleep(for: .milliseconds(700))
            try await turnEnded(p, b, "tests pass")
            let r = try await w.value
            #expect(field(r, "idle") == .bool(false) && field(r, "message") == .string("tests pass"), "\(r)")
        }
    }

    @Test func waitTimesOut() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            let b = try await term(d, p, "B", preset: "claude", command: busy)
            try await leash(d, p, "A", "B")
            #expect(await waitFor(10) { await d.badge(b.uuid) == .working })
            let r = try await wait(p, a, "B", timeout: 1)
            #expect(r.error?.code == .timeout, "\(r)")
        }
    }

    @Test func shepherdIsToldWhenALeashedAgentEndsATurn() async throws {
        try await withDaemon(configure: { $0.idleQuietSeconds = 15 }) { d, p in
            let s = try await term(d, p, "S", preset: "claude", command: quiet, shepherd: true)
            let b = try await term(d, p, "B", preset: "claude", command: quiet)
            try await leash(d, p, "S", "B")
            try await turnEnded(p, b, "built ok\nall green")
            let ok = await waitFor(15) { await d.scrollbackText(s.uuid).contains("[collie] B ended its turn: built ok all green") }
            let text = await d.scrollbackText(s.uuid)
            #expect(ok, "\(text)")
        }
    }

    @Test func noTurnNoticeForTheShepherdsOwnAsk() async throws {
        try await withDaemon(configure: { $0.idleQuietSeconds = 15 }) { d, p in
            let s = try await term(d, p, "S", preset: "claude", command: quiet, shepherd: true)
            let b = try await term(d, p, "B", preset: "claude", command: quiet)
            try await leash(d, p, "S", "B")
            let r = try await send(p, Request(id: "nw", terminalId: s.id, token: s.token, command: "ask",
                                              args: ["target": .string("B"), "prompt": .string("hi"), "no-wait": .bool(true)]))
            #expect(r.ok, "\(r)")
            #expect(await waitFor(10) { await d.askBusy(b.uuid) })
            try await turnEnded(p, b, "answer")
            #expect(await waitFor(15) { await d.scrollbackText(s.uuid).contains("[collie] Reply from B") })
            try await Task.sleep(for: .seconds(3))
            #expect(!(await d.scrollbackText(s.uuid).contains("ended its turn")))
        }
    }
}
