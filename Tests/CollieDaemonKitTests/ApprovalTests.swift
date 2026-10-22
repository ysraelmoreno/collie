import Testing
import Foundation
import CollieCore
import CollieProtocol
import CollieTerminal
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

/// A terminal running `command` (after printing its token, so hooks can be sent with its credentials).
private func term(_ d: Daemon, _ p: Paths, _ name: String, preset: String = "custom", _ command: String) async throws -> Term {
    let (id, r) = try await spawn(d, p, name, preset: preset, command: "echo T=$COLLIE_TOKEN; " + command)
    guard !id.isEmpty else { throw ProtocolError(code: .internal, message: "spawn \(name): \(r)") }
    return Term(id: id, token: try await tokenOf(d, id, echo: false))
}
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "a", token: d.adminToken, command: cmd, args: args))
}
private func approvals(_ d: Daemon, _ p: Paths) async throws -> [Approval] {
    let r = try await admin(d, p, "work.approvals")
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    return try dec.decode([Approval].self, from: JSONEncoder().encode(try #require(r.result, "\(r)")))
}
private func pending(_ d: Daemon, _ p: Paths, _ t: Term) async -> Approval? {
    _ = await waitFor(20) { (try? await approvals(d, p))?.contains { $0.terminalId == t.uuid } == true }
    return try? await approvals(d, p).first { $0.terminalId == t.uuid }
}
private func approve(_ d: Daemon, _ p: Paths, _ id: UUID, _ allow: Bool) async throws -> (sent: Bool, reason: String?) {
    let r = try await admin(d, p, "work.approve", ["id": .string(id.uuidString), "allow": .bool(allow)])
    guard case .object(let o)? = r.result, case .bool(let sent)? = o["sent"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    if case .string(let s)? = o["reason"] { return (sent, s) }
    return (sent, nil)
}
private func history(_ d: Daemon) async throws -> [ChatMessage] { try await d.router.chat.page(before: nil, limit: 200) }
private func hook(_ p: Paths, _ t: Term, _ payload: [String: String]) async throws {
    let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    let r = try await send(p, Request(id: "h", terminalId: t.id, token: t.token, command: "work.hook",
                                      args: ["hook": .string("notification"), "payload": .string(json)]))
    #expect(r.ok, "\(r)")
}

/// Types `key⏎` as the user: the yes/no script's next read must be exactly that (nothing else was typed before it).
private func typed(_ d: Daemon, _ p: Paths, _ t: Term, _ key: String) async throws {
    let c = try await StreamClient.open(Request(id: "a", token: d.adminToken, command: "ui.attach", args: ["terminal": .string(t.id)]), path: p.socket)
    defer { c.close() }
    try await c.send(.in(Data((key + "\n").utf8)))
    #expect(await waitFor(10) { await d.scrollbackText(t.uuid).contains("GOT:") })
    #expect(await d.scrollbackText(t.uuid).contains("GOT:\(key)"))
}
private let yesNo = "printf 'Apagar tudo? (y/n) '; read a; echo \"GOT:$a\"; exec cat"
/// Claude Code's Bash permission dialog as it reads once ANSI is stripped (a printf command, then "; ").
private let dialogText = """
    printf 'Bash command\\n\\n  rm -rf build\\n  Remove the build dir\\n\\nDo you want to proceed?\\n\\xe2\\x9d\\xaf 1. Yes\\n  2. Yes, and do not ask again for rm commands\\n  3. No, and tell Claude what to do differently (esc)\\n'; \

    """
/// The dialog in a raw tty; then the one key typed, in hex.
private let dialog = "stty raw -echo; " + dialogText + "k=$(dd bs=1 count=1 2>/dev/null | od -An -tx1); stty sane; echo \"KEY:$k\"; exec cat"

@Suite(.serialized) struct ApprovalTests {
    @Test func detectsClaudePermissionDialog() {
        let transcript = """
            ⏺ Bash(rm -rf build)
            Bash command

              rm -rf build
              Remove the build dir

            Do you want to proceed?
            ❯ 1. Yes
              2. Yes, and don't ask again for rm commands in /tmp
              3. No, and tell Claude what to do differently (esc)
            """
        var d = AttentionDetector(preset: .claude)
        let cut = transcript.firstIndex(of: "❯")!   // split across two reads
        #expect(d.feed(String(transcript[..<cut])) == nil)
        #expect(d.feed(String(transcript[cut...])) == "Do you want to proceed?")
        var e = AttentionDetector(preset: .claude)
        #expect(e.feed("Edit file\n  Sources/A.swift\n\nDo you want to make this edit to A.swift?\n❯ 1. Yes\n  2. No\n") == "Do you want to make this edit to A.swift?")
        #expect(e.feed("Do you want to create notes.md?\n  1. Yes\n") == "Do you want to create notes.md?")
        #expect(AttentionDetector.kind("Do you want to proceed?") == .menu)
        // normal agent output: a question in prose, a numbered list, another preset
        var n = AttentionDetector(preset: .claude)
        for s in ["Do you want to proceed? I can also run the tests first.\n", "Options:\n1. Yes we could cache it\n2. No\n",
                  "Steps:\n  1. Yesterday's build failed\n", "⏺ Do you want to add tests too? Here is the plan:\n  - one\n  - two\n  - three\n  - four\n  1. Yes\n"] {
            #expect(n.feed(s) == nil, "\(s)")
        }
        var sh = AttentionDetector(preset: .shell)
        #expect(sh.feed("Do you want to proceed?\n❯ 1. Yes\n") == nil)
    }

    @Test func hookPayloadPermission() {
        func m(_ o: [String: String]) -> String? { HookPayload.claudePermissionMessage(stdinJSON: try! JSONSerialization.data(withJSONObject: o)) }
        #expect(m(["hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"])
                == "Claude needs your permission to use Bash")
        #expect(m(["message": "Claude needs your permission to use Write"]) == "Claude needs your permission to use Write")   // older: no type
        #expect(m(["notification_type": "idle_prompt", "message": "Claude is waiting for your input"]) == nil)
        #expect(m(["notification_type": "idle_prompt", "message": "Claude needs your permission"]) == nil)   // the type wins
        #expect(m(["message": "Claude is waiting for your input"]) == nil)
        #expect(HookPayload.claudePermissionMessage(stdinJSON: Data("nope".utf8)) == nil)
    }

    @Test func attentionCapturesPrompt() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "A", yesNo)
            let a = try #require(await pending(d, p, t))
            #expect(a.kind == .yesNo && a.terminal == "A" && a.reason == "(y/n)")
            #expect(a.prompt.hasSuffix("Apagar tudo? (y/n)"), "\(a.prompt)")
            #expect(try await approvals(d, p).count == 1)
        }
    }

    @Test func approveWritesKeys() async throws {
        try await withDaemon { d, p in
            let y = try await term(d, p, "Y", yesNo), n = try await term(d, p, "N", yesNo)
            let ay = try #require(await pending(d, p, y)), an = try #require(await pending(d, p, n))
            #expect(try await approve(d, p, ay.id, true) == (true, nil))
            #expect(try await approve(d, p, an.id, false) == (true, nil))
            #expect(await waitFor(10) { await d.scrollbackText(y.uuid).contains("GOT:y") })
            #expect(await waitFor(10) { await d.scrollbackText(n.uuid).contains("GOT:n") })
            #expect(try await approvals(d, p).isEmpty)
            #expect(try await approve(d, p, ay.id, true) == (false, "pedido não está mais pendente"))   // answered once
        }
    }

    @Test func approveStaleSendsNothing() async throws {
        try await withDaemon { d, p in
            // the user answered in the terminal first
            let u = try await term(d, p, "U", yesNo)
            let au = try #require(await pending(d, p, u))
            let c = try await StreamClient.open(Request(id: "a", token: d.adminToken, command: "ui.attach", args: ["terminal": .string(u.id)]), path: p.socket)
            defer { c.close() }
            try await c.send(.in(Data("x\n".utf8)))
            #expect(await waitFor(10) { await d.scrollbackText(u.uuid).contains("GOT:x") })
            var before = await d.scrollbackTotalBytes(u.uuid)
            #expect(try await approve(d, p, au.id, true) == (false, "pedido não está mais pendente"))
            try await Task.sleep(for: .milliseconds(500))
            #expect(await d.scrollbackTotalBytes(u.uuid) == before)

            // another prompt replaced the captured one: the old id is not answered (the new one still is pending)
            let s = try await term(d, p, "S", "printf 'Primeiro? (y/n) '; sleep 2; printf '\\nSegundo? (y/n) '; read a; echo \"GOT:$a\"; exec cat")
            let first = try #require(await pending(d, p, s))
            #expect(await waitFor(10) { (try? await approvals(d, p))?.first { $0.terminalId == s.uuid }.map { $0.id != first.id } == true })
            before = await d.scrollbackTotalBytes(s.uuid)
            #expect(try await approve(d, p, first.id, true) == (false, "pedido não está mais pendente"))
            try await Task.sleep(for: .milliseconds(500))
            #expect(await d.scrollbackTotalBytes(s.uuid) == before)
            #expect(try await approvals(d, p).first { $0.terminalId == s.uuid }?.prompt.hasSuffix("Segundo? (y/n)") == true)

            // the prompt left the screen (more output, no input): nothing written, but it stays pending (only input
            // clears it), so the chat still refuses to type into it
            let g = try await term(d, p, "G", "printf 'Sair? (y/n) '; sleep 2; seq 1 60; read a; echo \"GOT:$a\"; exec cat")
            let ag = try #require(await pending(d, p, g))
            #expect(await waitFor(10) { await d.scrollbackText(g.uuid).contains("\n60") })
            before = await d.scrollbackTotalBytes(g.uuid)
            #expect(try await approve(d, p, ag.id, true) == (false, "pedido não está mais pendente"))
            // B2b: no longer on screen, so it is dropped (its card goes) — and nothing was typed: the next line the
            // script reads is the user's
            #expect(try await !approvals(d, p).map(\.id).contains(ag.id))
            #expect(await d.scrollbackTotalBytes(g.uuid) == before)
            try await typed(d, p, g, "z")
        }
    }

    /// B2a: a Stop hook (the turn ended, so no dialog is open) drops the approval; nothing is typed.
    @Test func stopHookDropsApproval() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "A", yesNo)
            _ = try #require(await pending(d, p, t))
            let before = await d.scrollbackTotalBytes(t.uuid)
            let r = try await send(p, Request(id: "s", terminalId: t.id, token: t.token, command: "turn.completed",
                                              args: ["message": .string("pronto"), "source": .string("generic")]))
            #expect(r.ok, "\(r)")
            #expect(try await approvals(d, p).isEmpty)
            #expect(await d.scrollbackTotalBytes(t.uuid) == before)
            try await typed(d, p, t, "z")
        }
    }

    /// B2c: `work.approval.dismiss` drops the approval and types nothing; app only.
    @Test func dismissWritesNothing() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "A", yesNo)
            let a = try #require(await pending(d, p, t))
            let before = await d.scrollbackTotalBytes(t.uuid)
            let denied = try await send(p, Request(id: "x", terminalId: t.id, token: t.token, command: "work.approval.dismiss",
                                                   args: ["id": .string(a.id.uuidString)]))
            #expect(denied.error?.code == .unauthorized, "\(denied)")
            #expect(try await admin(d, p, "work.approval.dismiss", ["id": .string(a.id.uuidString)]).result == .object(["dismissed": .bool(true)]))
            #expect(try await approvals(d, p).isEmpty)
            #expect(await d.badge(t.uuid) != .attention)
            #expect(try await admin(d, p, "work.approval.dismiss", ["id": .string(a.id.uuidString)]).result == .object(["dismissed": .bool(false)]))
            #expect(await d.scrollbackTotalBytes(t.uuid) == before)
            try await typed(d, p, t, "z")
        }
    }

    /// B3: a terminal that exited lists no approval.
    @Test func exitedTerminalListsNoApproval() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "A", "printf 'Go? (y/n) '; sleep 1")
            _ = try #require(await pending(d, p, t))
            #expect(await waitFor(10) { (try? await approvals(d, p))?.isEmpty == true })
        }
    }

    @Test func menuKeys() async throws {
        try await withDaemon { d, p in
            let y = try await term(d, p, "Y", preset: "claude", dialog), n = try await term(d, p, "N", preset: "claude", dialog)
            let ay = try #require(await pending(d, p, y)), an = try #require(await pending(d, p, n))
            #expect(ay.kind == .menu && ay.reason == "Do you want to proceed?")
            #expect(try await approve(d, p, ay.id, true).sent)
            #expect(try await approve(d, p, an.id, false).sent)
            #expect(await waitFor(10) { await d.scrollbackText(y.uuid).contains(/KEY: *31/) })
            #expect(await waitFor(10) { await d.scrollbackText(n.uuid).contains(/KEY: *1b/) })
        }
    }

    /// Claude queues two dialogs: the second is drawn as soon as the first was approved (before the approval's hops
    /// through the hub are done), inside the input's echo window. It is still caught (scanned when the window ends),
    /// and the chat does not type into it.
    @Test func dialogRightAfterInput() async throws {
        try await withDaemon { d, p in
            let script = dialogText + "k=$(dd bs=1 count=1 2>/dev/null | od -An -tx1); " + dialogText
                + "k2=$(dd bs=1 count=1 2>/dev/null | od -An -tx1); stty sane; echo \"KEYS:$k/$k2\"; exec cat"
            let t = try await term(d, p, "A", preset: "claude", "stty raw -echo; " + script)
            let first = try #require(await pending(d, p, t))
            let inputs = await d.router.asks.approvalInputs(t.uuid)
            #expect(try await approve(d, p, first.id, true).sent)
            #expect(await waitFor(10) { (try? await approvals(d, p))?.contains { $0.terminalId == t.uuid && $0.id != first.id } == true })
            // the approval counted as one input: a second one (through the hub) would drop what was held since
            #expect(await d.router.asks.approvalInputs(t.uuid) == inputs + 1)
            let before = await d.scrollbackTotalBytes(t.uuid)
            #expect(try await admin(d, p, "work.chat.send", ["text": .string("@A hello")]).ok)
            #expect(await waitFor(10) { (try? await history(d))?.contains { $0.text.hasPrefix("A está esperando uma aprovação") } == true })
            try await Task.sleep(for: .milliseconds(500))
            #expect(await d.scrollbackTotalBytes(t.uuid) == before)
            let second = try #require(try await approvals(d, p).first { $0.terminalId == t.uuid })
            #expect(try await approve(d, p, second.id, false).sent)
            #expect(await waitFor(10) { await d.scrollbackText(t.uuid).contains(/KEYS: *31 *\/ *1b/) })   // od pads with spaces
        }
    }

    /// A guarded inject (summon, rerail) issued while the approval's window still holds unscanned output — the next
    /// dialog is drawn there — waits for the scan instead of typing, then is refused: nothing reaches the dialog.
    @Test func injectWaitsForTheWindowScan() async throws {
        try await withDaemon { d, p in
            let script = dialogText + "k=$(dd bs=1 count=1 2>/dev/null | od -An -tx1); " + dialogText
                + "k2=$(dd bs=1 count=1 2>/dev/null | od -An -tx1); stty sane; echo \"KEYS:$k/$k2\"; exec cat"
            let t = try await term(d, p, "A", preset: "claude", "stty raw -echo; " + script)
            let first = try #require(await pending(d, p, t))
            let asks = await d.router.asks, deferred = await asks.windowDeferrals
            #expect(try await approve(d, p, first.id, true).sent)
            await #expect(throws: AskCoordinator.awaitingApproval("A")) { try await asks.inject(to: t.uuid, prompt: "hello") }
            #expect(await asks.windowDeferrals > deferred)   // it was issued inside the window, and held
            let second = try #require(try await approvals(d, p).first { $0.terminalId == t.uuid })
            #expect(second.id != first.id)
            #expect(try await approve(d, p, second.id, false).sent)
            #expect(await waitFor(10) { await d.scrollbackText(t.uuid).contains(/KEYS: *31 *\/ *1b/) })   // nothing in between
        }
    }

    /// The user answers dialog 1 in the terminal (a focus report first, which is no answer); dialog 2 is drawn at once.
    /// The tracker hears of the keys synchronously, so it and the badge agree that dialog 2 waits.
    @Test func userAnswerThenDialogTrackerAndBadgeAgree() async throws {
        try await withDaemon { d, p in
            let next = dialogText.replacingOccurrences(of: "build", with: "dist")   // another command
            let script = dialogText + "k=$(dd bs=1 count=4 2>/dev/null | od -An -tx1); " + next + "exec sleep 100"
            let t = try await term(d, p, "A", preset: "claude", "stty raw -echo; " + script)
            let first = try #require(await pending(d, p, t))
            #expect(await waitFor(10) { await d.badge(t.uuid) == .attention })
            let inputs = await d.router.asks.approvalInputs(t.uuid)
            let c = try await StreamClient.open(Request(id: "a", token: d.adminToken, command: "ui.attach", args: ["terminal": .string(t.id)]), path: p.socket)
            defer { c.close() }
            try await c.send(.in(Data("\u{1B}[I".utf8)))
            try await c.send(.in(Data("1".utf8)))
            #expect(await waitFor(10) {
                guard await d.badge(t.uuid) == .attention else { return false }
                return (try? await approvals(d, p))?.contains { $0.terminalId == t.uuid && $0.id != first.id } == true
            })
            #expect(await d.router.asks.approvalInputs(t.uuid) == inputs + 1)   // the focus report did not count
        }
    }

    /// A screen-matched approval raises the badge even while an ask is in flight (its echo is stripped already).
    @Test func approvalBadgeWhileAskInFlight() async throws {
        try await withDaemon(configure: { $0.idleQuietSeconds = 60 }) { d, p in
            let b = try await term(d, p, "B", "read l; printf 'Real? (y/n) '; read x; exec cat")
            #expect(try await admin(d, p, "work.chat.send", ["text": .string("@B seguir")]).ok)
            #expect(await waitFor(15) { await d.badge(b.uuid) == .attention })
            #expect(await d.router.asks.isBusy(b.uuid))
        }
    }

    /// The echo of a chat prompt that contains "(y/n)" is not an approval; a real prompt printed after the echo is.
    @Test func promptEchoIsNoApproval() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", "while read l; do :; done")
            let b = try await term(d, p, "B", "read l; printf 'Real? (y/n) '; read x; echo \"GOT:$x\"; exec cat")
            try await Task.sleep(for: .seconds(1))   // ready
            #expect(try await admin(d, p, "work.chat.send", ["text": .string("@A apagar tudo? (y/n)")]).ok)
            #expect(try await admin(d, p, "work.chat.send", ["text": .string("@B seguir? (y/n)")]).ok)
            #expect(await waitFor(10) { await d.scrollbackText(a.uuid).contains("apagar tudo? (y/n)") })
            let real = try #require(await pending(d, p, b))
            #expect(real.prompt.hasSuffix("Real? (y/n)"), "\(real.prompt)")
            try await Task.sleep(for: .seconds(2))   // past A's echo window
            #expect(try await approvals(d, p).allSatisfy { $0.terminalId != a.uuid })
            #expect(await d.badge(a.uuid) != .attention)
        }
    }

    /// More output in the echo window than is held: the window can't be checked, so it counts as a pending prompt.
    @Test func overflowFailsSafe() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "A", preset: "claude",
                                   "stty raw -echo; " + dialogText + "k=$(dd bs=1 count=1 2>/dev/null); head -c 300000 /dev/zero | tr '\\0' a; exec sleep 100")
            let first = try #require(await pending(d, p, t))
            #expect(try await approve(d, p, first.id, true).sent)
            #expect(await waitFor(10) { (try? await approvals(d, p))?.first { $0.terminalId == t.uuid }?.reason == "saída demais para conferir" })
            let over = try #require(try await approvals(d, p).first { $0.terminalId == t.uuid })
            #expect(over.kind == .unknown)
            #expect(await waitFor(10) { (try? await history(d))?.contains { $0.text == "A pode estar esperando você (saída demais para conferir); olhe o terminal." } == true })
            let before = await d.scrollbackTotalBytes(t.uuid)
            // nothing answers it: no keys for allow or deny, and it stays pending
            for allow in [true, false] {
                #expect(try await approve(d, p, over.id, allow) == (false, "saída demais para conferir; olhe o terminal"))
            }
            #expect(try await approvals(d, p).map(\.id).contains(over.id))
            #expect(try await admin(d, p, "work.chat.send", ["text": .string("@A hello")]).ok)
            #expect(await waitFor(10) { (try? await history(d))?.contains { $0.text.hasPrefix("A está esperando uma aprovação") } == true })
            try await Task.sleep(for: .milliseconds(500))
            #expect(await d.scrollbackTotalBytes(t.uuid) == before)
        }
    }

    /// R9: the dialog ignored the key (no output at all): the same approval is pending again.
    @Test func ignoredKeyReraises() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "A", preset: "claude", "stty raw -echo; " + dialogText + "exec sleep 100")
            let a = try #require(await pending(d, p, t))
            #expect(try await approve(d, p, a.id, true).sent)
            #expect(try await approvals(d, p).allSatisfy { $0.terminalId != t.uuid })
            #expect(await waitFor(10) { (try? await approvals(d, p))?.first { $0.terminalId == t.uuid }?.id == a.id })
            #expect(try await approve(d, p, a.id, false).sent)   // still answerable: same id, still on screen
        }
    }

    @Test func approvalPostsToChat() async throws {
        try await withDaemon { d, p in
            let panel = await d.router.addWorkPanel()
            let t = try await term(d, p, "A", yesNo)
            let a = try #require(await pending(d, p, t))
            #expect(await waitFor(10) { (try? await history(d))?.contains { $0.role == .collie && $0.text == "A pede permissão: Apagar tudo? (y/n)" } == true })
            #expect(await waitFor(10) { await d.router.panelEvents[panel]?.contains { $0.name == "work.approval" } == true })
            let ev = try #require(await d.router.panelEvents[panel]?.first { $0.name == "work.approval" })
            guard case .object(let o) = ev.payload, case .object(let ap)? = o["approval"] else { Issue.record("\(ev.payload)"); return }
            #expect(ap["id"] == .string(a.id.uuidString))
            #expect(try await approve(d, p, a.id, true).sent)
            #expect(try await history(d).first?.text == "Aprovado")
            #expect(try await history(d).filter { $0.text.contains("pede permissão") }.count == 1)
            // answered: the panels are told, so the card goes
            #expect(await waitFor(10) { await d.router.panelEvents[panel]?.contains { e in
                guard e.name == "work.approval", case .object(let o) = e.payload else { return false }
                return o["cleared"] == .bool(true) && o["terminalId"] == .string(t.id.lowercased())
            } == true })
        }
    }

    /// Claude's `Notification` hook marks the approval even when the screen pattern misses the dialog; the chat
    /// then never types into it, and a second announcement of the same dialog adds nothing.
    @Test func hookMarksPending() async throws {
        try await withDaemon(configure: { $0.idleQuietSeconds = 1 }) { d, p in
            let t = try await term(d, p, "A", "echo 'Edit file'; echo '  A.swift'; echo 'Allow this?'; exec cat")
            #expect(await waitFor(10) { await d.scrollbackText(t.uuid).contains("Allow this?") })
            try await hook(p, t, ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"])
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await approvals(d, p).isEmpty)
            try await hook(p, t, ["hook_event_name": "Notification", "notification_type": "permission_prompt",
                                  "message": "Claude needs your permission to use Edit"])
            let a = try #require(await pending(d, p, t))
            #expect(a.kind == .menu && a.reason == "Claude needs your permission to use Edit" && a.prompt.hasSuffix("Allow this?"))
            try await hook(p, t, ["message": "Claude needs your permission to use Edit"])   // older payload, same dialog
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await approvals(d, p).map(\.id) == [a.id])
            // the chat refuses to type into it
            let before = await d.scrollbackTotalBytes(t.uuid)
            _ = try await admin(d, p, "work.chat.send", ["text": .string("@A hello")])
            #expect(await waitFor(10) { (try? await history(d))?.contains { $0.text.hasPrefix("A está esperando uma aprovação") } == true })
            #expect(await d.scrollbackTotalBytes(t.uuid) == before)
            #expect(try await approve(d, p, a.id, true).sent)
            #expect(await waitFor(10) { await d.scrollbackTotalBytes(t.uuid) > before })   // the tty echoes the "1"
            // a hook right after input (here: the approval) is held, not dropped, and raised when the window ends
            try await hook(p, t, ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"])
            #expect(await waitFor(10) { (try? await approvals(d, p))?.first?.reason == "Claude needs your permission to use Bash" })
            #expect(await waitFor(10) { await d.badge(t.uuid) == .attention })   // the hook raises the badge too
        }
    }

    @Test func terminalsCannotApprove() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "A", yesNo)
            let a = try #require(await pending(d, p, t))
            for (cmd, args) in [("work.approvals", [String: JSONValue]()), ("work.approve", ["id": .string(a.id.uuidString), "allow": .bool(true)])] {
                let r = try await send(p, Request(id: "x", terminalId: t.id, token: t.token, command: cmd, args: args))
                #expect(r.error?.code == .unauthorized, "\(cmd): \(r)")
            }
            try await Task.sleep(for: .milliseconds(300))
            #expect(!(await d.scrollbackText(t.uuid)).contains("GOT:"))
            #expect(try await approvals(d, p).map(\.id) == [a.id])
        }
    }
}

/// A clock the test moves.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { t } }
    func advance(_ d: Duration) { lock.withLock { t += d } }
}
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [ApprovalEvent] = []
    func add(_ e: ApprovalEvent) { lock.withLock { list.append(e) } }
    var all: [ApprovalEvent] { lock.withLock { list } }
}
/// A tracker on a scrollback the test writes to, on a clock it moves; window ends are called by hand.
private struct Rig {
    let sb = ScrollbackBuffer(spillURL: nil), clock = TestClock(), events = Events()
    let tracker: ApprovalTracker
    init(_ preset: Preset = .custom) {
        let clock = clock, events = events
        tracker = ApprovalTracker(terminalId: UUID(), name: "A", preset: preset, scrollback: sb, now: { clock.now }) { events.add($0) }
    }
    func show(_ s: String) { let d = Data(s.utf8); sb.append(d); tracker.feed(d) }
    /// The input window is over and its timer fired.
    func windowEnds() { clock.advance(Fanout.inputQuiet + .milliseconds(10)); tracker.windowEnded() }
}

@Suite struct ApprovalTrackerTests {
    /// Keys the prompt ignored (nothing printed, or no new line) put the same approval back; an answer does not.
    @Test func ignoredKeysRestore() throws {
        let r = Rig()
        r.show("Apagar tudo? (y/n) ")
        let a = try #require(r.tracker.pending)
        r.tracker.input()
        #expect(r.tracker.pending == nil && r.tracker.inWindow)
        r.windowEnds()                                   // nothing printed
        #expect(r.tracker.pending?.id == a.id && !r.tracker.inWindow)
        r.tracker.input(); r.tracker.input()             // keys in a row, one char echoed
        r.show("y")
        r.windowEnds()
        #expect(r.tracker.pending?.id == a.id)
        r.tracker.input()                                // the answer: a new line
        r.show("y\r\nGOT:y\r\n")
        r.windowEnds()
        #expect(r.tracker.pending == nil)
        #expect(r.events.all == [.raised(a), .cleared(a.terminalId), .updated(a), .cleared(a.terminalId), .updated(a),
                                 .cleared(a.terminalId)])
    }

    /// B1: an answer (`y⏎`) followed by more keys inside the window (`ls`) is never brought back.
    @Test func answeredThenTypingIsNotRestored() throws {
        let r = Rig()
        r.show("Apagar tudo? (y/n) ")
        let a = try #require(r.tracker.pending)
        r.tracker.input(); r.show("y\r\n")
        r.tracker.input(); r.show("l")
        r.tracker.input(); r.show("s")
        r.windowEnds()
        #expect(r.tracker.pending == nil)
        #expect(r.events.all == [.raised(a), .cleared(a.terminalId)])
    }

    /// An arrow key in Claude's Select: the whole dialog drawn again with the cursor elsewhere is the same request.
    @Test func arrowKeyRedrawRestores() throws {
        let r = Rig(.claude)
        let dialog = "Bash command\n\n  rm -rf build\n  Remove the build dir\n\nDo you want to proceed?\n"
        r.show(dialog + "❯ 1. Yes\n  2. Yes, and don't ask again\n  3. No\n")
        let a = try #require(r.tracker.pending)
        r.tracker.input()
        r.show(dialog + "  1. Yes\n❯ 2. Yes, and don't ask again\n  3. No\n")
        r.windowEnds()
        let b = try #require(r.tracker.pending)
        #expect(b.id == a.id && b.prompt.hasSuffix("3. No") && b.prompt.contains("❯ 2."))
        #expect(r.events.all == [.raised(a), .cleared(a.terminalId), .updated(b)])   // no second "pede permissão"
    }

    /// Ways out of a stuck approval, none of which writes: dismissing it, or approving one no longer on screen.
    @Test func dismissAndStaleTakeDrop() throws {
        let r = Rig()
        r.show("Apagar tudo? (y/n) ")
        let a = try #require(r.tracker.pending)
        #expect(!r.tracker.dismiss(UUID()) && r.tracker.pending == a)
        #expect(r.tracker.dismiss(a.id) && r.tracker.pending == nil)
        r.show("\nSair? (y/n) ")
        let b = try #require(r.tracker.pending)
        r.show((1...60).map { "\($0)\n" }.joined())    // scrolled away, no input
        #expect(r.tracker.take(b.id) == nil && r.tracker.pending == nil)
        #expect(r.events.all == [.raised(a), .cleared(a.terminalId), .raised(b), .cleared(b.terminalId)])
        #expect(r.tracker.inputCount == 0)               // nothing counted as typed
    }

    /// A focus report (the terminal view gained or lost focus) is not input.
    @Test func focusReportsAreNotInput() throws {
        for s in ["\u{1B}[I", "\u{1B}[O", "\u{1B}[I\u{1B}[O"] { #expect(Fanout.isFocusReport(Data(s.utf8)), "\(s)") }
        for s in ["", "\u{1B}[A", "\u{1B}[Ix", "y", "\u{1B}["] { #expect(!Fanout.isFocusReport(Data(s.utf8)), "\(s)") }
        let p = try PTYProcess(spec: LaunchSpec(executable: "/bin/sh", arguments: ["-c", "exec sleep 30"], cwd: "/tmp"),
                               scrollback: ScrollbackBuffer(spillURL: nil))
        defer { p.terminate() }
        let n = Events()
        let fan = Fanout(p, preset: .custom) { n.add(.cleared(UUID())) }
        fan.noteInput()
        #expect(n.all.count == 1)                        // told at once, not through the hub
        fan.noteInput(signal: false)                     // an approval: the tracker counted it already
        #expect(n.all.count == 1)
    }

    /// The same dialog drawn again at another width (a resize, no input): same id, its prompt updated, nothing told.
    @Test func redrawAtAnotherWidthUpdatesInPlace() throws {
        let r = Rig(.claude)
        r.show("Bash command\n\n  rm -rf build\n  Remove the build dir\n\nDo you want to proceed?\n❯ 1. Yes\n  2. Yes, and don't ask again for rm commands\n  3. No\n")
        let a = try #require(r.tracker.pending)
        let narrow = "Bash command\n\n  rm -rf build\n  Remove the build\n  dir\n\n│ Do you want to proceed?\n│ ❯ 1. Yes\n│   2. Yes, and don't ask\n│   again for rm commands\n│   3. No\n"
        r.show(narrow)
        let b = try #require(r.tracker.pending)
        #expect(b.id == a.id && b.prompt != a.prompt && b.prompt.hasSuffix("│   3. No"))
        r.show(narrow)
        #expect(r.tracker.pending?.id == a.id)
        #expect(r.events.all == [.raised(a)])            // no new chat line, no event
        // another command in the same dialog is a new approval, even without input
        r.show("Bash command\n\n  rm -rf dist\n  Remove the dist dir\n\nDo you want to proceed?\n❯ 1. Yes\n  2. Yes, and don't ask again for rm commands\n  3. No\n")
        #expect(r.tracker.pending.map { $0.id != a.id } == true)
        // another prompt with the same generic reason is a new approval
        let y = Rig()
        y.show("Primeiro? (y/n) ")
        let first = try #require(y.tracker.pending)
        y.show("\nSegundo? (y/n) ")
        #expect(y.tracker.pending.map { $0.id != first.id && $0.prompt.hasSuffix("Segundo? (y/n)") } == true)
    }

    /// Too much output after an input to check: an approval only once the output stopped and stayed stopped; a build that
    /// keeps printing is scanned as it goes, and a prompt at its end is found.
    @Test func overflowOnlyWhenOutputStops() throws {
        let big = String(repeating: "compiling module\n", count: 9000)   // > 128 KiB
        let r = Rig(.claude)
        r.tracker.input()
        r.show(big)
        r.windowEnds()                                   // stopped inside the window
        #expect(r.tracker.pending == nil)
        r.tracker.overflowCheck()                        // and stayed stopped
        #expect(r.tracker.pending?.kind == .unknown && r.tracker.pending?.reason == QuietDetector.overflowReason)

        let b = Rig(.claude)
        b.tracker.input()
        b.show(big)
        b.windowEnds()
        b.show("linked\n")                               // output goes on
        b.tracker.overflowCheck()
        #expect(b.tracker.pending == nil)
        b.show("Do you want to proceed?\n❯ 1. Yes\n")    // a prompt at the end is still found
        #expect(b.tracker.pending?.kind == .menu)

        let c = Rig(.claude)
        c.tracker.input()
        c.show(big)
        c.clock.advance(Fanout.inputQuiet + .milliseconds(10))
        c.show("more\n")                                 // the window ends on output: it did not stop
        c.tracker.windowEnded()
        c.tracker.overflowCheck()
        #expect(c.tracker.pending == nil)
    }

    /// The write-time check and counting the input are one step: refused while pending or while output is unscanned.
    @Test func guardedInputIsOneStep() throws {
        let r = Rig()
        #expect(r.tracker.inputIfClear(echo: "oi") == .written)
        #expect(r.tracker.inputIfClear(echo: "oi") == .window)   // its own output not scanned yet
        r.windowEnds()
        r.show("Seguir? (y/n) ")
        let n = r.tracker.inputCount
        #expect(r.tracker.inputIfClear(echo: "oi") == .pending)
        #expect(r.tracker.pending != nil && r.tracker.inputCount == n)
    }
}
