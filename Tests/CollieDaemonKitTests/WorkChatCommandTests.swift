import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Fixtures/fake-agent.sh").path

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func term(_ d: Daemon, _ p: Paths, _ name: String, shepherd: Bool = false, command: String? = nil) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string(command == nil ? "shell" : "custom"), "cwd": .string("/tmp")]
    if shepherd { args["shepherd"] = .bool(true) }
    if let command { args["command"] = .string(command) }
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args))
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "spawn \(name): \(r)") }
    return Term(id: id, token: try await tokenOf(d, id, echo: command == nil))
}
/// An agent-like terminal: bracketed paste on (a pasted block stays one prompt), then echoes its input.
private let pasting = "echo T=$COLLIE_TOKEN; printf '\\033[?2004h'; exec cat"
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await send(p, Request(id: "a", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }))
}
private func chat(_ d: Daemon, _ p: Paths, _ text: String, work: String? = nil) async throws -> (id: String, queued: Bool) {
    var a = ["text": text]; a["work"] = work
    let r = try await admin(d, p, "work.chat.send", a)
    guard case .object(let o)? = r.result, case .string(let id)? = o["messageId"], case .bool(let q)? = o["queued"] else {
        throw ProtocolError(code: .internal, message: "send: \(r)")
    }
    return (id, q)
}
private func history(_ d: Daemon) async throws -> [ChatMessage] { try await d.router.chat.page(before: nil, limit: 200) }
/// The collie reply to user message `id`.
private func replyTo(_ d: Daemon, _ id: String) async throws -> ChatMessage? {
    try await history(d).first { $0.replyTo?.uuidString.lowercased() == id }
}
private func startWork(_ d: Daemon, _ p: Paths, _ terminal: String, _ title: String) async throws -> String {
    let r = try await admin(d, p, "work.start", ["terminal": terminal, "title": title])
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return id
}
private func bytes(_ d: Daemon, _ ts: [Term]) async -> [Int] {
    var out: [Int] = []; for t in ts { out.append(await d.scrollbackTotalBytes(t.uuid)) }; return out
}

private func hookWatcher(_ d: Daemon, _ p: Paths, _ t: Term) -> Task<Void, Never> {
    Task {
        var seen = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(30))
            let msgs = (await d.scrollbackText(t.uuid)).matches(of: /<<COLLIE_FAKE_STOP:(.*?)>>/).map { String($0.output.1) }
            for m in msgs.dropFirst(seen) {
                _ = try? await send(p, Request(id: "h", terminalId: t.id, token: t.token, command: "turn.completed",
                                               args: ["message": .string(m), "source": .string("generic")]))
            }
            seen = max(seen, msgs.count)
        }
    }
}

extension CommandRouter {
    /// A Work panel without the app (the `work` plugin's spec comes with the panel itself).
    func addWorkPanel() -> UUID {
        let p = Panel(id: UUID(), name: "Trabalho", pluginId: "work", placement: .dockRight)
        ws.panels.append(p)
        return p.id
    }
}

@Suite(.serialized) struct WorkChatCommandTests {
    @Test func questionMarkGoesToAssistant() async throws {
        let m = FakeModel(.answer("Tudo **certo**."))
        try await withDaemon(configure: { $0.localModel = m }) { d, p in
            let t = try await term(d, p, "Dev")
            let wid = try await startWork(d, p, "Dev", "Tela de login")
            try await Task.sleep(for: .milliseconds(300))
            let before = await bytes(d, [t])
            let s = try await chat(d, p, "?  onde estamos", work: wid)   // without the "?" a status question: the "?" comes first
            #expect(s.queued)
            #expect(await waitFor(10) { (try? await replyTo(d, s.id)) != nil })
            let a = try #require(try await replyTo(d, s.id))
            #expect(a.role == .collie && a.text == "Assistente: Tudo \\*\\*certo\\*\\*.", "\(a)")
            let calls = await m.calls
            #expect(calls.count == 1 && calls[0].instructions == WorkAssistant.questionInstructions)
            #expect(calls.first?.prompt == "Trabalho selecionado: \(wid) Tela de login\n\nonde estamos")
            #expect(await m.toolNames == ["listarTrabalhos", "resumoDoTrabalho", "statusAgora"])
            let empty = try await admin(d, p, "work.chat.send", ["text": "?  "])
            #expect(empty.error?.message == "Nada para perguntar depois de ?.")
            try await Task.sleep(for: .milliseconds(300))
            #expect(await bytes(d, [t]) == before)
        }
    }

    @Test func freeQuestionWithoutModel() async throws {
        try await withDaemon(configure: { $0.localModel = FakeModel(.unavailable) }) { d, p in
            let s = try await chat(d, p, "?o que falta")
            let a = try #require(try await replyTo(d, s.id))
            #expect(!s.queued && a.role == .collie
                    && a.text == "Perguntas livres precisam do macOS 26 com Apple Intelligence ligada (Apple Intelligence está desligada).")
        }
        try await withDaemon(configure: { $0.localModel = FakeModel(.fail) }) { d, p in
            let s = try await chat(d, p, "?o que falta")
            #expect(s.queued)
            #expect(await waitFor(10) { (try? await replyTo(d, s.id))?.text == "O assistente não respondeu (o modelo falhou)." })
        }
    }

    @Test func plainTextStillGoesToAgent() async throws {
        let m = FakeModel(.answer("não devia"))
        try await withDaemon(configure: { $0.localModel = m }) { d, p in
            let dev = try await term(d, p, "Dev")
            let wid = try await startWork(d, p, "Dev", "API")
            #expect(try await chat(d, p, "echo PLAIN_$((40+2)) ?", work: wid).queued)
            #expect(await waitFor(10) { await d.scrollbackText(dev.uuid).contains("PLAIN_42") })
            #expect(await m.count() == 0)
        }
    }

    @Test func statusQuestionAnsweredWithoutAgent() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "Dev")
            let wid = try await startWork(d, p, "Dev", "Tela de login")
            try await Task.sleep(for: .milliseconds(300))
            let before = await bytes(d, [t])
            let s = try await chat(d, p, "Onde estamos?", work: wid)
            #expect(!s.queued)
            let a = try #require(try await replyTo(d, s.id))
            #expect(a.role == .collie && a.text.contains("Tela de login"), "\(a)")
            _ = try await chat(d, p, "o que está rodando")   // no work: all active
            try await Task.sleep(for: .milliseconds(500))
            #expect(await bytes(d, [t]) == before)
        }
    }

    @Test func routingRules() async throws {
        try await withDaemon { d, p in
            let dev = try await term(d, p, "Dev"), m = try await term(d, p, "M", shepherd: true), w = try await term(d, p, "W")
            #expect(try await admin(d, p, "admin.leash", ["a": "M", "b": "W"]).ok)
            // nothing is written for the notices
            try await Task.sleep(for: .milliseconds(300))
            let before = await bytes(d, [dev, m, w])
            let none = try await chat(d, p, "faz o deploy")
            let noneReply = try await replyTo(d, none.id)
            #expect(!none.queued && noneReply?.text == "Escolha um trabalho ou comece com @nome.")
            let nobody = try await chat(d, p, "@ninguem faz isso")
            let nobodyReply = try await replyTo(d, nobody.id)
            #expect(!nobody.queued && nobodyReply?.text == "Não conheço ninguem.")
            try await Task.sleep(for: .milliseconds(500))
            #expect(await bytes(d, [dev, m, w]) == before)
            // @dev (any case) → Dev, the rest only
            let s = try await chat(d, p, "@dev echo ROUTE_DEV_$((40+2))")
            #expect(s.queued)
            #expect(await waitFor(10) { await d.scrollbackText(dev.uuid).contains("ROUTE_DEV_42") })
            #expect(try await history(d).first { $0.id.uuidString.lowercased() == s.id }?.terminal == "Dev")
            // no @, a plain terminal's work → the Shepherd leashed to it
            let wid = try await startWork(d, p, "W", "API")
            #expect(try await chat(d, p, "echo ROUTE_M_$((40+2))", work: wid).queued)
            #expect(await waitFor(10) { await d.scrollbackText(m.uuid).contains("ROUTE_M_42") })
            #expect(!(await d.scrollbackText(w.uuid)).contains("ROUTE_M"))
        }
    }

    @Test func sendReturnsBeforeReply() async throws {
        try await withDaemon(configure: { $0.idleQuietSeconds = 15 }) { d, p in
            // answers after 0.5 s, its hook 1.5 s later: the reply takes ~2 s
            let a = try await term(d, p, "A", command: "echo T=$COLLIE_TOKEN; COLLIE_FAKE_HOOK=1 COLLIE_FAKE_HOOK_DELAY=1.5 exec sh '\(fixture)'")
            let panel = await d.router.addWorkPanel()
            let watcher = hookWatcher(d, p, a)
            defer { watcher.cancel() }
            let start = ContinuousClock.now
            let s = try await chat(d, p, "@A hello")
            #expect(ContinuousClock.now - start < .milliseconds(500))
            #expect(s.queued)
            #expect(await waitFor(15) { (try? await replyTo(d, s.id))?.role == .agent })
            let r = try #require(try await replyTo(d, s.id))
            #expect(r.text == "answer:hello" && r.terminal == "A" && !r.truncated, "\(r)")
            let names = await d.router.panelEvents[panel]?.map(\.name) ?? []
            #expect(names.filter { $0 == "work.chat" }.count == 2, "\(names)")   // the user's message and the reply
        }
    }

    @Test func stoppedTargetIsSystemMessage() async throws {
        try await withDaemon { d, p in
            let r = try await admin(d, p, "admin.spawn", ["name": "Gone", "preset": "custom", "command": "true", "cwd": "/tmp"])
            guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { Issue.record("\(r)"); return }
            #expect(await waitFor(10) { await d.process(UUID(uuidString: id)!)?.isRunning != true })
            let s = try await chat(d, p, "@gone oi")
            #expect(!s.queued)
            #expect(try await replyTo(d, s.id)?.text == "Gone não está rodando.")
        }
    }

    @Test func terminalsCannotChat() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "T")
            for (cmd, args) in [("work.chat.send", ["text": JSONValue.string("@T oi")]), ("work.chat.history", [:]), ("work.chat.clear", [:])] {
                let r = try await send(p, Request(id: "x", terminalId: t.id, token: t.token, command: cmd, args: args))
                #expect(r.error?.code == .unauthorized, "\(cmd): \(r)")
            }
            #expect(try await history(d).isEmpty)
            // the app: history pages, clear empties
            _ = try await chat(d, p, "status")
            let h = try await admin(d, p, "work.chat.history", ["limit": "1"])
            guard case .array(let rows)? = h.result else { Issue.record("\(h)"); return }
            #expect(rows.count == 1)
            #expect(try await admin(d, p, "work.chat.clear").ok)
            #expect(try await history(d).isEmpty)
        }
    }

    @Test func storeChangeEmitsEvent() async throws {
        try await withDaemon { d, p in
            _ = try await term(d, p, "T")
            let panel = await d.router.addWorkPanel()
            let wid = try await startWork(d, p, "T", "Algo")
            #expect(await waitFor(5) {
                await d.router.panelEvents[panel]?.contains { $0.name == "work.changed" && $0.payload == .object(["workId": .string(wid)]) } == true
            })
        }
    }
    @Test func routingPicksTheWorksShepherd() async throws {
        try await withDaemon { d, p in
            let solo = try await term(d, p, "Solo"), boss = try await term(d, p, "Boss", shepherd: true)
            let w = try await term(d, p, "W"), alfa = try await term(d, p, "alfa", shepherd: true), zeta = try await term(d, p, "Zeta", shepherd: true)
            for m in ["Zeta", "alfa"] { #expect(try await admin(d, p, "admin.leash", ["a": m, "b": "W"]).ok) }
            #expect(try await admin(d, p, "admin.leash", ["a": "Boss", "b": "Zeta"]).ok)
            // a Shepherd's own work → itself, even when leashed to another Shepherd
            let bw = try await startWork(d, p, "Boss", "B")
            #expect(try await chat(d, p, "echo TO_BOSS_$((40+2))", work: bw).queued)
            #expect(await waitFor(10) { await d.scrollbackText(boss.uuid).contains("TO_BOSS_42") })
            // two Shepherds leashed: the first by name (alfa < Zeta, any case)
            let ww = try await startWork(d, p, "W", "W")
            #expect(try await chat(d, p, "echo TO_ALFA_$((40+2))", work: ww).queued)
            #expect(await waitFor(10) { await d.scrollbackText(alfa.uuid).contains("TO_ALFA_42") })
            // no Shepherd leashed → the work's own terminal
            let sw = try await startWork(d, p, "Solo", "S")
            #expect(try await chat(d, p, "echo TO_SOLO_$((40+2))", work: sw).queued)
            #expect(await waitFor(10) { await d.scrollbackText(solo.uuid).contains("TO_SOLO_42") })
            for t in [zeta, w] { #expect(!(await d.scrollbackText(t.uuid)).contains("TO_")) }
            // "@Solo," → Solo
            #expect(try await chat(d, p, "@Solo, echo COMMA_$((40+2))").queued)
            #expect(await waitFor(10) { await d.scrollbackText(solo.uuid).contains("COMMA_42") })
        }
    }

    @Test func approvalPromptIsNeverAnswered() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", command: "echo T=$COLLIE_TOKEN; sleep 1; echo 'Apply the change? (y/n)'; exec sh '\(fixture)'")
            #expect(await waitFor(10) { await d.badge(a.uuid) == .attention })
            #expect(await waitFor(10) { await d.scrollbackText(a.uuid).contains("fake-agent ready") })   // its banner comes after the prompt
            try await Task.sleep(for: .milliseconds(300))
            let before = await bytes(d, [a])
            let s = try await chat(d, p, "@A sim")
            #expect(!s.queued)
            #expect(try await replyTo(d, s.id)?.text == "A está esperando uma aprovação; responda o pedido primeiro.")
            try await Task.sleep(for: .milliseconds(500))
            #expect(await bytes(d, [a]) == before)
        }
    }

    /// Queued while the agent works; it then shows an approval prompt and goes quiet: the chat text (and its Enter) is never typed.
    @Test func promptDuringWaitIsNeverAnswered() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", command: "echo T=$COLLIE_TOKEN; read l; echo working; sleep 0.5; printf 'Apply the change? (y/n) '; read ans; echo \"GOT:$ans\"; exec cat")
            try await Task.sleep(for: .seconds(1))   // ready
            try await d.process(a.uuid)!.write(Data("go\n".utf8))   // the agent starts a turn of its own
            let s = try await chat(d, p, "@A hello")
            #expect(s.queued)
            #expect(await waitFor(15) { (try? await replyTo(d, s.id)) != nil })
            #expect(try await replyTo(d, s.id)?.text == "A está esperando uma aprovação; a mensagem não foi enviada.")
            try await Task.sleep(for: .milliseconds(500))
            #expect(!(await d.scrollbackText(a.uuid)).contains("GOT:"))
            #expect(!(await d.scrollbackText(a.uuid)).contains("hello"))
        }
    }

    /// The user typed into the agent just before the chat message: the chat waits for that turn, so its reply is its own.
    @Test func busyTargetIsAskedAfterItsTurn() async throws {
        try await withDaemon(configure: { $0.idleQuietSeconds = 15 }) { d, p in
            let a = try await term(d, p, "A", command: "echo T=$COLLIE_TOKEN; COLLIE_FAKE_HOOK=1 exec sh '\(fixture)'")
            let watcher = hookWatcher(d, p, a); defer { watcher.cancel() }
            try await Task.sleep(for: .seconds(1))   // ready
            try await d.process(a.uuid)!.write(Data("typed\n".utf8))   // a turn the chat does not own
            let s = try await chat(d, p, "@A hello")
            #expect(s.queued)
            #expect(await waitFor(15) { (try? await replyTo(d, s.id))?.role == .agent })
            #expect(try await replyTo(d, s.id)?.text == "answer:hello")
        }
    }

    @Test func refusalsAndReasonsInPortuguese() async throws {
        try await withDaemon { d, p in
            _ = try await term(d, p, "T")
            func err(_ a: [String: String], _ cmd: String = "work.chat.send") async throws -> String? { try await admin(d, p, cmd, a).error?.message }
            #expect(try await err(["text": "  "]) == "Mensagem vazia.")
            #expect(try await err(["text": String(repeating: "x", count: 8_001)]) == "A mensagem passa de 8 000 caracteres.")
            #expect(try await err(["text": "@T"]) == "Nada para mandar depois de @T.")
            #expect(try await err(["text": "oi", "work": UUID().uuidString]) == "Trabalho não encontrado.")
            #expect(try await err(["before": UUID().uuidString], "work.chat.history") == "Mensagem não encontrada.")
            #expect(try await err(["before": "x"], "work.chat.history") == "Mensagem não encontrada.")
        }
        func pe(_ c: ErrorCode, _ m: String) -> ProtocolError { ProtocolError(code: c, message: m) }
        #expect(CommandRouter.reason(pe(.timeout, "No reply from 'A' within 1800s")) == "sem resposta em 30 min")
        #expect(CommandRouter.reason(pe(.timeout, "'A' is still working; prompt not delivered")) == "a mensagem não foi entregue")
        #expect(CommandRouter.reason(pe(.notRunning, "Terminal 'A' exited")) == "o terminal parou")
        #expect(CommandRouter.reason(pe(.internal, "x")) == "erro interno")
    }

    // MARK: - work.rerail

    @Test func rerailBlockHasOnlyLiveState() {
        let ts: [(String, TaskState)] = [("T-DONE", .done), ("T-OPEN", .open), ("T-PROG\u{1b}[31m\nX", .inProgress),
                                         ("T-DROP", .abandoned), ("T-DEFER", .deferred)]
        let w = Work(title: "Login\nhack", terminalId: UUID(),
                     tasks: ts.map { WorkTask(id: $0.0, title: $0.0, state: $0.1) },
                     jobs: [WorkJob(id: "1", kind: .subagent, label: "J-RUN", state: .running), WorkJob(id: "2", kind: .shell, label: "J-FIN", state: .finished),
                            WorkJob(id: "3", kind: .shell, label: "J-GONE", state: .gone)],
                     notes: [WorkNote(text: "N-PLAIN"), WorkNote(text: "D-OLD", decision: true)]
                         + (1...5).map { WorkNote(text: "D-\($0)", decision: true) })
        let b = RerailText.block(w, now: Date())
        #expect(b == """
            [Collie] Estado atual do trabalho "Login hack" — considere encerrado tudo o que não está aqui.
            Em andamento:
            - T-PROG [31m X
            Abertas:
            - T-OPEN
            Rodando:
            - subagente J-RUN
            Decisões recentes:
            - D-1
            - D-2
            - D-3
            - D-4
            - D-5
            Continue a partir daqui. Ao adiar use `collie work task defer`, ao desistir `collie work task drop`.
            """)
        #expect(!b.unicodeScalars.contains { $0 != "\n" && CharacterSet.controlCharacters.contains($0) })
        // empty sections are left out
        let bare = RerailText.block(Work(title: "X", terminalId: UUID()), now: Date())
        #expect(bare.split(separator: "\n").count == 2)
    }

    @Test func rerailBlockIsBounded() {
        let w = Work(title: String(repeating: "t", count: 5000), terminalId: UUID(),
                     tasks: (0..<500).map { WorkTask(id: "\($0)", title: String(repeating: "x", count: 300)) },
                     jobs: (0..<500).map { WorkJob(id: "\($0)", kind: .shell, label: String(repeating: "j", count: 300)) },
                     notes: (0..<50).map { _ in WorkNote(text: String(repeating: "d", count: 3000), decision: true) })
        let b = RerailText.block(w, now: Date())
        #expect(b.count <= RerailText.limit, "\(b.count)")
        #expect(b.contains("Abertas:") && b.contains("e mais"))
    }

    @Test func rerailFollowsLeashes() async throws {
        try await withDaemon { d, p in
            let m = try await term(d, p, "M", shepherd: true, command: pasting), loner = try await term(d, p, "Loner", shepherd: true)
            let w = try await term(d, p, "W", command: pasting), plain = try await term(d, p, "Plain")
            #expect(try await admin(d, p, "admin.leash", ["a": "M", "b": "W"]).ok)
            #expect(try await admin(d, p, "admin.leash", ["a": "Plain", "b": "W"]).ok)
            _ = try await startWork(d, p, "W", "LEASH_WORK")
            func rerail(_ t: Term, _ target: String?) async throws -> Response {
                try await send(p, Request(id: "r", terminalId: t.id, token: t.token, command: "work.rerail",
                                          args: target.map { ["terminal": .string($0)] } ?? [:]))
            }
            // a Shepherd without a leash sees W as missing; a plain terminal may not rerail at all
            #expect(try await rerail(loner, "W").error?.code == .notFound)
            #expect(try await rerail(loner, "Nobody").error?.code == .notFound)
            #expect(try await rerail(plain, "W").error?.code == .unauthorized)
            #expect(try await rerail(plain, nil).error?.code == .unauthorized)
            try await Task.sleep(for: .milliseconds(300))
            #expect(!(await d.scrollbackText(w.uuid)).contains("LEASH_WORK"))
            // the leashed Shepherd injects
            let r = try await rerail(m, "W")
            guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
            #expect(o["injected"] == .bool(true))
            #expect(await waitFor(10) { await d.scrollbackText(w.uuid).contains("LEASH_WORK") })
            // the app: any terminal, --terminal required
            #expect(try await admin(d, p, "work.rerail").error?.code == .invalidArgs)
            #expect(try await admin(d, p, "work.rerail", ["terminal": "W"]).ok)
            #expect(try await history(d).contains { $0.role == .collie && $0.text.hasPrefix("Recoloquei W no trilho.") })
            // a Shepherd on itself: queued without waiting on its own turn
            _ = try await startWork(d, p, "M", "SELF_WORK")
            let me = try await rerail(m, nil)
            guard case .object(let mo)? = me.result else { Issue.record("\(me)"); return }
            #expect(mo["injected"] == .bool(false))
            #expect(await waitFor(10) { await d.scrollbackText(m.uuid).contains("SELF_WORK") })
        }
    }

    @Test func rerailInjectsIntoPTY() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "Dev", command: pasting)
            _ = try await startWork(d, p, "Dev", "PTY_WORK")
            #expect(try await admin(d, p, "work.task.add", ["terminal": "Dev", "title": "abrir tela"]).ok)
            let r = try await admin(d, p, "work.rerail", ["terminal": "Dev"])
            guard case .object(let o)? = r.result, case .number(let n)? = o["chars"] else { Issue.record("\(r)"); return }
            #expect(n > 0)
            #expect(await waitFor(10) {
                await d.scrollbackText(t.uuid).contains("[Collie] Estado atual do trabalho \"PTY_WORK\" — considere encerrado tudo o que não está aqui.")
            })
        }
    }

    @Test func rerailWithoutWork() async throws {
        try await withDaemon { d, p in
            let t = try await term(d, p, "Dev")
            try await Task.sleep(for: .milliseconds(300))
            let before = await bytes(d, [t])
            let r = try await admin(d, p, "work.rerail", ["terminal": "Dev"])
            #expect(r.error?.code == .invalidArgs && r.error?.message == "no active work", "\(r)")
            try await Task.sleep(for: .milliseconds(300))
            #expect(await bytes(d, [t]) == before)
        }
    }

    @Test func rerailRefusedAtApprovalPrompt() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", command: "echo T=$COLLIE_TOKEN; sleep 1; echo 'Apply the change? (y/n)'; exec sh '\(fixture)'")
            #expect(await waitFor(10) { await d.badge(a.uuid) == .attention })
            _ = try await startWork(d, p, "A", "APPROVAL_WORK")
            try await Task.sleep(for: .milliseconds(300))
            let before = await bytes(d, [a])
            let r = try await admin(d, p, "work.rerail", ["terminal": "A"])
            #expect(r.error?.message == "A está pedindo aprovação; recolocar no trilho depois de responder", "\(r)")
            try await Task.sleep(for: .milliseconds(300))
            #expect(await bytes(d, [a]) == before)
        }
    }

    /// A shell, or a program without bracketed paste, would run the block line by line: refused before anything is queued.
    @Test func rerailNeedsBracketedPaste() async throws {
        try await withDaemon { d, p in
            let sh = try await term(d, p, "Sh")
            let plain = try await term(d, p, "Plain", command: "echo T=$COLLIE_TOKEN; exec cat")
            for (name, t) in [("Sh", sh), ("Plain", plain)] {
                _ = try await startWork(d, p, name, "PASTE_WORK")
                let r = try await admin(d, p, "work.rerail", ["terminal": name])
                #expect(r.error?.message == "\(name) não aceita colar texto com segurança; recolocar no trilho só em agentes", "\(r)")
                #expect(await d.router.asks.queued(t.uuid) == 0)
            }
        }
    }

    /// A Shepherd on itself: refused at once at an approval prompt; queued once however often it asks.
    @Test func selfRerailChecksAndDedupes() async throws {
        try await withDaemon { d, p in
            let m = try await term(d, p, "M", shepherd: true, command: "echo T=$COLLIE_TOKEN; printf '\\033[?2004h'; printf 'Go? (y/n) '; exec cat")
            #expect(await waitFor(10) { await d.router.asks.hasPendingApproval(m.uuid) })
            _ = try await startWork(d, p, "M", "SELF_WORK")
            func rerail() async throws -> Response {
                try await send(p, Request(id: "r", terminalId: m.id, token: m.token, command: "work.rerail", args: [:]))
            }
            #expect(try await rerail().error?.message == "M está pedindo aprovação; recolocar no trilho depois de responder")
            #expect(await d.router.selfRerails.isEmpty)
            #expect(await d.router.asks.queued(m.uuid) == 0)

            // never quiet, so never ready: the first rerail stays queued
            let n = try await term(d, p, "N", shepherd: true,
                                   command: "echo T=$COLLIE_TOKEN; printf '\\033[?2004h'; (while :; do echo tick; sleep 0.1; done) & exec cat")
            _ = try await startWork(d, p, "N", "SELF_WORK_2")
            for _ in 0..<3 {
                let r = try await send(p, Request(id: "r", terminalId: n.id, token: n.token, command: "work.rerail", args: [:]))
                #expect(r.ok, "\(r)")
            }
            #expect(await d.router.selfRerails == [n.uuid])
            #expect(await waitFor(10) { await d.router.asks.queued(n.uuid) == 1 })
            #expect(await d.router.asks.queued(n.uuid) == 1)
        }
    }

    @Test func rerailCleanDropsFormatCharacters() {
        #expect(RerailText.clean("a\u{202E}b\u{200B}c\u{2066}d\ne") == "abcd e")
    }
}
