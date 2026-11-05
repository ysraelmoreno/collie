import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// DX backlog 4: Claude's question dialog (AskUserQuestion) is waiting for the user, like an approval only their keys
/// answer: an `ask --no-wait` reply is held instead of being typed in as the answer.
private let dialog = """
 ☐ Renderer

check --screen precisa de um emulador. Qual caminho?

❯ 1. SwiftTerm só no collied (Recommended)
  2. Renderer próprio mínimo
  3. Type something.
──────────────
  4. Chat about this

Enter to select · ↑/↓ to navigate · Esc to cancel
"""

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func term(_ d: Daemon, _ p: Paths, _ name: String, _ command: String) async throws -> Term {
    let (id, r) = try await spawn(d, p, name, preset: "claude", command: "echo T=$COLLIE_TOKEN; " + command)
    guard !id.isEmpty else { throw ProtocolError(code: .internal, message: "spawn \(name): \(r)") }
    return Term(id: id, token: try await tokenOf(d, id, echo: false))
}

@Suite(.serialized) struct QuestionDialogTests {
    @Test func claudesQuestionDialogIsAnUnknownApproval() {
        var det = AttentionDetector(preset: .claude)
        let reason = det.feed(dialog)
        #expect(reason != nil)
        #expect(reason.map(AttentionDetector.kind) == .unknown)
        var shell = AttentionDetector(preset: .shell)
        #expect(shell.feed(dialog) == nil, "Claude's dialog only")
    }

    @Test func replyIsHeldWhileTheAskerShowsAQuestion() async throws {
        try await withDaemon(configure: { $0.idleQuietSeconds = 15 }) { d, p in
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID().uuidString).txt")
            try dialog.write(to: f, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: f) }
            let a = try await term(d, p, "A", "sleep 0.5; cat '\(f.path)'; exec cat >/dev/null")
            let b = try await term(d, p, "B", "exec sleep 999")
            #expect(try await send(p, Request(id: "l", token: d.adminToken, command: "admin.leash", args: ["a": "A", "b": "B"])).ok)
            #expect(await waitFor(10) { await d.badge(a.uuid) == .attention })
            let r = try await send(p, Request(id: "nw", terminalId: a.id, token: a.token, command: "ask",
                                              args: ["target": "B", "prompt": "hi", "no-wait": true]))
            #expect(r.ok, "\(r)")
            #expect(await waitFor(10) { await d.askBusy(b.uuid) })
            _ = try await send(p, Request(id: "h", terminalId: b.id, token: b.token, command: "turn.completed",
                                          args: ["message": "answer", "source": "claude"]))
            try await Task.sleep(for: .seconds(3))
            #expect(!(await d.scrollbackText(a.uuid).contains("[collie] Reply from B")), "held while the question is open")
            let ap = try await send(p, Request(id: "x", token: d.adminToken, command: "work.approvals"))
            guard case .array(let list)? = ap.result, case .object(let o)? = list.first, case .string(let id)? = o["id"] else {
                Issue.record("no approval: \(ap)"); return
            }
            _ = try await send(p, Request(id: "x", token: d.adminToken, command: "work.approval.dismiss", args: ["id": .string(id)]))
            #expect(await waitFor(10) { await d.scrollbackText(a.uuid).contains("[collie] Reply from B (ask") })
        }
    }
}
