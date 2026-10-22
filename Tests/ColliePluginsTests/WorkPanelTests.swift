import Foundation
import Testing
import CollieCore
import CollieProtocol
@testable import ColliePlugins

private let workA = UUID(), workB = UUID(), termA = UUID(), termB = UUID(), approvalId = UUID()

private func iso(_ v: some Encodable) -> JSONValue {
    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
    return try! JSONDecoder().decode(JSONValue.self, from: e.encode(v))
}

private actor Fake {
    var calls: [(String, [String: JSONValue])] = []
    var approveResult: JSONValue = .object(["sent": .bool(true)])
    var failure: ProtocolError?
    /// `work.chat.history` without `before` returns a full page.
    var fullPage = false
    func setFullPage() { fullPage = true }
    func set(approve: JSONValue) { approveResult = approve }
    func set(failure: ProtocolError?) { self.failure = failure }
    /// While held, `work.rerail` waits for `release()` (an agent slow to take the block).
    var holdRerail = false, rerailWaiter: CheckedContinuation<Void, Never>?
    func hold() { holdRerail = true }
    func release() { holdRerail = false; rerailWaiter?.resume(); rerailWaiter = nil }
    var approvalsGone = false
    /// While held, `work.summary --natural` waits for `releaseNatural()` (a slow on-device model).
    var holdNatural = false, naturalWaiter: CheckedContinuation<Void, Never>?
    func holdNaturalSummary() { holdNatural = true }
    func releaseNatural() { holdNatural = false; naturalWaiter?.resume(); naturalWaiter = nil }
    func clearApprovals() { approvalsGone = true }
    var assistant: JSONValue = .object(["available": .bool(true)])
    func set(assistant: JSONValue) { self.assistant = assistant }
    func handle(_ cmd: String, _ a: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        calls.append((cmd, a))
        if let failure, cmd != "work.list", cmd != "work.status", cmd != "work.chat.history", cmd != "work.approvals" { throw failure }
        switch cmd {
        case "work.list":
            return .array([
                .object(["id": .string(workA.uuidString.lowercased()), "title": .string("Login"), "terminal": .string("Dev"),
                         "openedAt": .string("2026-10-21T10:00:00Z"), "openTasks": .number(1)]),
                .object(["id": .string(workB.uuidString.lowercased()), "title": .string("Velho"), "terminal": .string("Ops"),
                         "openedAt": .string("2026-10-20T10:00:00Z"), "openTasks": .number(0),
                         "closedAt": .string("2026-10-20T12:00:00Z"), "closedBy": .string("app")]),
            ])
        case "work.status":
            let w = Work(id: workA, title: "Login", terminalId: termA,
                         tasks: [WorkTask(id: "t1", title: "form"), WorkTask(id: "t2", title: "api", state: .done)],
                         jobs: [WorkJob(id: "j1", kind: .shell, label: "build", state: .gone)])
            return .object(["output": .string(""), "works": .array([iso(w)])])
        case "work.chat.history":
            if fullPage, a["before"] == nil {
                return .array((0..<WorkPanelModel.pageSize).map { iso(ChatMessage(at: Date(timeIntervalSince1970: Double(100 - $0)), role: .collie, text: "m\($0)")) })
            }
            let older = ChatMessage(at: Date(timeIntervalSince1970: 1), role: .user, text: "oi")
            let newer = ChatMessage(at: Date(timeIntervalSince1970: 2), role: .collie, text: "olá")
            return .array([iso(newer), iso(older)])   // newest first
        case "work.summary":
            let b = a["id"] == .string(workB.uuidString.lowercased())   // B: no rewrite; A: rewritten
            var o: [String: JSONValue] = ["markdown": .string("## " + (b ? "Velho" : "Login") + "\n\n**Feito**\n- api"), "natural": .bool(false)]
            guard a["natural"] == .bool(true) else { return .object(o) }
            if holdNatural { await withCheckedContinuation { naturalWaiter = $0 } }
            if b { o["reason"] = .string("timeout") } else { o["natural"] = .bool(true); o["text"] = .string("Foi feita a api.") }
            return .object(o)
        case "work.rerail":
            if holdRerail { await withCheckedContinuation { rerailWaiter = $0 } }
            return .object(["injected": .bool(true)])
        case "work.approvals":
            if approvalsGone { return .array([]) }
            return .array([iso(Approval(id: approvalId, terminalId: termA, terminal: "Dev", kind: .yesNo, reason: "(y/n)",
                                        prompt: "rm -rf build?\nProceed (y/n)"))])
        case "work.approve": return approveResult
        case "work.assistant.status": return assistant
        case "work.approval.dismiss": approvalsGone = true; return .object(["dismissed": .bool(true)])
        default: return .object([:])
        }
    }
    func count(_ c: String) -> Int { calls.filter { $0.0 == c }.count }
    func names() -> [String] { calls.map(\.0) }
    func all(_ c: String) -> [[String: JSONValue]] { calls.filter { $0.0 == c }.map(\.1) }
}

@MainActor private func make(window: Duration = .milliseconds(500)) -> (WorkPanelModel, Fake) {
    let f = Fake()
    return (WorkPanelModel(call: { c, a throws(ProtocolError) in try await f.handle(c, a) }, window: window), f)
}

@MainActor @Suite struct WorkPanelTests {
    @Test func refreshLoadsWorksChatApprovals() async {
        let (m, f) = make()
        await m.refresh()
        #expect(Set(await f.names()) == ["work.list", "work.status", "work.chat.history", "work.approvals", "work.summary",
                                       "work.assistant.status"])
        #expect(m.works.map(\.id) == [workA] && m.closed.map(\.id) == [workB])
        #expect(m.selected == workA && m.terminalName(of: m.works[0]) == "Dev")
        #expect(m.messages.map(\.text) == ["oi", "olá"])   // oldest first on screen
        #expect(m.approvals.map(\.id) == [approvalId])
        #expect(m.hasAlert(m.works[0]))   // a gone job (and a pending approval)
        #expect(m.counts(m.works[0]) == [(TaskState.open, 1), (.done, 1)].map { WorkPanelModel.Count(state: $0.0, n: $0.1) })
    }

    @Test func summaryButtonSendsResumo() async {
        let (m, f) = make()
        #expect(WorkPanelModel.quickQuestions.contains { $0.label == "Resumo" && $0.phrase == "resumo" })
        await m.send("resumo")
        #expect(await f.all("work.chat.send") == [["text": .string("resumo")]])
    }

    @Test func selectedWorkLoadsSummary() async {
        let (m, f) = make()
        await m.refresh()
        #expect(m.summary == "## Login\n\n**Feito**\n- api")
        await m.rewriting?.value
        #expect(await f.all("work.summary") == [["id": .string(workA.uuidString.lowercased())],
                                                ["id": .string(workA.uuidString.lowercased()), "natural": .bool(true)]])
        await m.select(workB)
        #expect(m.selected == workB && m.summary?.hasPrefix("## Velho") == true)
    }

    @Test func naturalSummaryHasDataToggle() async {
        let (m, _) = make()
        await m.refresh()
        await m.rewriting?.value
        #expect(m.naturalSummary == "Foi feita a api." && m.summaryReason == nil && !m.showSummaryData)
        m.showSummaryData = true   // "Ver dados"
        #expect(m.summary == "## Login\n\n**Feito**\n- api")
        await m.select(workB)
        await m.rewriting?.value
        #expect(!m.showSummaryData && m.naturalSummary == nil && m.summaryReason == "o modelo demorou mais de 10 s")
    }

    @Test func placeholderShowsAvailability() async {
        let (m, f) = make()
        await m.refresh()
        #expect(m.placeholder == "Mensagem — @nome para um agente, ? para perguntar ao assistente")
        await f.set(assistant: .object(["available": .bool(false), "reason": .string("precisa do macOS 26")]))
        await m.refresh()
        #expect(m.placeholder == "Mensagem — @nome para um agente (assistente indisponível: precisa do macOS 26)")
        #expect(WorkPanelModel.isPortuguese("Nada para perguntar depois de ?."))
    }

    @Test func slowRewriteNeverDelaysApprovals() async {
        let (m, f) = make()
        await f.holdNaturalSummary()
        await m.refresh()   // returns while the rewrite still waits
        #expect(m.approvals.map(\.id) == [approvalId] && m.messages.count == 2)
        #expect(m.summary?.hasPrefix("## Login") == true && m.naturalSummary == nil)
        await f.releaseNatural()
        await m.rewriting?.value
        #expect(m.naturalSummary == "Foi feita a api.")
    }

    @Test func chatEventAppendsWithoutRefresh() async throws {
        let (m, f) = make()
        let msg = ChatMessage(role: .agent, terminal: "Dev", text: "pronto")
        await m.handleEvent("work.chat", .object(["message": iso(msg)]))
        await m.handleEvent("work.chat", .object(["message": iso(msg)]))   // the same one twice: shown once
        #expect(m.messages.map(\.id) == [msg.id])
        #expect(await f.names().isEmpty)
    }

    @Test func changedEventsCoalesce() async throws {
        let (m, f) = make(window: .milliseconds(500))
        for _ in 0..<20 { await m.handleEvent("work.changed", .object([:])) }   // a burst, well inside one window
        #expect(await f.count("work.list") == 1)   // the first, at once
        #expect(await pollUntil { await f.count("work.list") == 2 })   // one more at the window's end
        try await Task.sleep(for: .milliseconds(300))
        #expect(await f.count("work.list") == 2)   // and only one
        #expect(await f.count("work.chat.history") == 0)   // a work change does not reload the chat
    }

    @Test func approvalEventReloadsApprovals() async {
        let (m, f) = make()
        await m.handleEvent("work.approval", .object([:]))
        #expect(await f.names() == ["work.approvals"])
        #expect(m.approvals.count == 1)
    }

    @Test func quickButtonsSendExactPhrases() async {
        let (m, f) = make()
        await m.refresh()
        #expect(WorkPanelModel.quickQuestions.map(\.phrase) == ["onde estamos", "o que travou", "o que está rodando", "resumo"])
        for q in WorkPanelModel.quickQuestions { await m.send(q.phrase) }
        #expect(await f.all("work.chat.send") == WorkPanelModel.quickQuestions.map {
            ["text": .string($0.phrase), "work": .string(workA.uuidString.lowercased())]
        })
        // each phrase is one the registry answers for free
        #expect(WorkPanelModel.quickQuestions.allSatisfy { StatusQuestion.match($0.phrase) != nil })
    }

    @Test func approveCallsDaemon() async {
        let (m, f) = make()
        await m.refresh()
        await m.approve(approvalId, allow: true)
        #expect(await f.all("work.approve").last == ["id": .string(approvalId.uuidString.lowercased()), "allow": .bool(true)])
        #expect(m.notice == nil)
        await f.set(approve: .object(["sent": .bool(false), "reason": .string("pedido não está mais pendente")]))
        await m.approve(approvalId, allow: false)
        #expect(await f.all("work.approve").last?["allow"] == .bool(false))
        #expect(m.notice == "pedido não está mais pendente")
        #expect(Array(await f.names().suffix(2)) == ["work.approve", "work.approvals"])
        await f.clearApprovals()   // the card left: its old result no longer applies
        await m.handleEvent("work.approval", .object([:]))
        #expect(m.approvals.isEmpty && m.notice == nil)
    }

    @Test func approvalNeverWaitsOnRerail() async throws {
        let (m, f) = make()
        await m.refresh()
        await f.hold()
        let rerail = Task { await m.rerail("Dev") }
        #expect(await pollUntil { await f.count("work.rerail") == 1 })
        #expect(m.rerailing == ["Dev"] && !m.busy)
        await m.approve(approvalId, allow: true)   // returns while the rerail still waits
        #expect(await f.all("work.approve").count == 1 && m.approving.isEmpty)
        await m.send("onde estamos")   // and the chat too
        #expect(await f.count("work.chat.send") == 1)
        await f.release()
        await rerail.value
        #expect(m.rerailing.isEmpty)
    }

    @Test func promptShowsHiddenCharacters() {
        #expect(WorkPanelModel.visible("rm a\u{202E}txt.exe\u{200B}") == "rm a⟨U+202E⟩txt.exe⟨U+200B⟩")
        #expect(WorkPanelModel.visible("Proceed (y/n)\nçã") == "Proceed (y/n)\nçã")
    }

    /// "Entendi, vou olhar o terminal" and "Dispensar": the daemon drops it (`work.approval.dismiss`), never `work.approve`.
    @Test func dismissWritesNothing() async {
        let (m, f) = make()
        await m.refresh()
        await m.dismiss(approvalId)
        #expect(await f.all("work.approval.dismiss") == [["id": .string(approvalId.uuidString.lowercased())]])
        #expect(await f.count("work.approve") == 0)
        #expect(m.approvals.isEmpty && m.approving.isEmpty)
    }

    @Test func errorsInPortuguese() async {
        func e(_ c: ErrorCode, _ m: String) -> ProtocolError { ProtocolError(code: c, message: m) }
        let d = WorkPanelModel.describe
        #expect(d(e(.invalidArgs, "no active work"), "Dev") == "Nenhum trabalho ativo.")
        #expect(d(e(.notRunning, "Terminal 'Dev' is not running"), nil) == "Dev não está rodando.")
        #expect(d(e(.unavailable, "'Dev' is waiting for an approval; prompt not delivered"), nil)
                == "Dev está esperando uma aprovação; nada foi enviado.")
        #expect(d(e(.timeout, "'Dev' is still working; prompt not delivered"), nil) == "Dev ainda não estava pronto; nada foi enviado.")
        #expect(d(e(.timeout, "'work.rerail' timed out after 600 s"), "Dev") == "Dev demorou demais para responder.")
        #expect(d(e(.ambiguous, "Multiple terminals named 'Dev'"), nil) == "Mais de um terminal se chama Dev.")
        #expect(d(e(.invalidArgs, "work already open: Login"), "Dev") == "Dev já tem um trabalho aberto (Login).")
        #expect(d(e(.notFound, "Terminal 'Dev' not found"), nil) == "Trabalho ou terminal não encontrado.")
        #expect(d(e(.notFound, "no work 1234"), nil) == "Trabalho ou terminal não encontrado.")
        #expect(d(e(.invalidArgs, "work 1234 is already closed"), nil) == "Esse trabalho já foi fechado.")
        #expect(d(e(.internal, "socket closed"), nil) == "Algo deu errado: socket closed")
        #expect(d(e(.invalidArgs, "Mensagem vazia."), nil) == "Mensagem vazia.")   // already Portuguese: as is
        #expect(d(e(.unavailable, "Dev está pedindo aprovação; recolocar no trilho depois de responder"), nil)
                == "Dev está pedindo aprovação; recolocar no trilho depois de responder")
        #expect(d(e(.unavailable, "Dev não aceita colar texto com segurança; recolocar no trilho só em agentes"), nil)
                == "Dev não aceita colar texto com segurança; recolocar no trilho só em agentes")
        #expect(d(e(.invalidArgs, "Nada para mandar depois de @Dev."), nil) == "Nada para mandar depois de @Dev.")
        // only the daemon's known messages pass: anything else, even ending in "." or saying "está", is wrapped
        #expect(d(e(.internal, "Disk full."), nil) == "Algo deu errado: Disk full.")
        #expect(d(e(.internal, "o banco está fora"), nil) == "Algo deu errado: o banco está fora")

        let (m, f) = make()
        await m.refresh()
        await f.set(failure: e(.invalidArgs, "no active work"))
        await m.rerail("Dev")
        #expect(await f.all("work.rerail") == [["terminal": .string("Dev")]])
        #expect(m.error == "Nenhum trabalho ativo.")
    }

    @Test func closeAndReopenById() async {
        let (m, f) = make()
        await m.closeWork(workA)
        await m.reopenWork(workB)
        #expect(await f.all("work.done") == [["id": .string(workA.uuidString.lowercased())]])
        #expect(await f.all("work.reopen") == [["id": .string(workB.uuidString.lowercased())]])
        #expect(await f.count("work.list") == 2)   // each refreshes
    }

    @Test func loadOlderPages() async {
        let (m, f) = make()
        await m.refresh()
        #expect(!m.hasOlder)   // a short page: nothing older
        await m.loadOlder()
        #expect(await f.count("work.chat.history") == 1)
        await f.setFullPage()
        await m.refresh()
        #expect(m.hasOlder)
        let first = m.messages[0].id
        await m.loadOlder()
        #expect(await f.all("work.chat.history").last?["before"] == .string(first.uuidString.lowercased()))
        #expect(m.messages.count == WorkPanelModel.pageSize + 2 && m.messages.first?.text == "oi" && !m.hasOlder)
    }

    @Test func onePanelPerWorkspace() {
        let mem = Panel(id: UUID(), name: "Memória", pluginId: "memory", placement: .dockRight)
        let work = Panel(id: UUID(), name: "Trabalho", pluginId: "work", placement: .dockLeft)
        #expect(WorkPanel.existing(in: [mem]) == nil)
        #expect(WorkPanel.existing(in: [mem, work])?.id == work.id)
        #expect(PluginRegistry.spec("work")?.events == ["work.changed", "work.chat", "work.approval"])
        #expect(PluginRegistry.spec("work")?.placements.contains(.canvas) == false)
    }
}
