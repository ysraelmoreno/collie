import Foundation
import OrqCore
import OrqProtocol

/// `work.chat.*` (the app alone): status questions answered from the registry (no tokens), anything else typed into one
/// agent — `@name`, else the work's Maestro — whose reply comes back later as a chat message. Each message written is a
/// `work.chat` plugin event to the Work panels; each work store change a `work.changed`.
extension CommandRouter {
    static let chatReplyTimeout: Duration = .seconds(1800)

    func chatCommand(_ r: Request) async throws -> JSONValue {
        switch r.command {
        case "work.chat.send": return try await chatSend(r)
        case "work.chat.history":
            let before = try str(r, "before").map { s throws(ProtocolError) in
                guard let id = UUID(uuidString: s) else { throw ProtocolError(code: .notFound, message: "Mensagem não encontrada.") }
                return id
            }
            let limit = Int(try num(r, "limit", max: 200) ?? 50)
            return try isoJSON(try await chat.page(before: before, limit: limit))
        case "work.chat.clear":
            try await chat.clear()
            return .object([:])
        case "work.approvals": return try isoJSON(await asks.approvals())
        case "work.approve":
            guard let id = UUID(uuidString: try need(r, "id")) else { throw ProtocolError(code: .invalidArgs, message: "Aprovação inválida.") }
            return try await approve(id, allow: flag(r, "allow"))
        case "work.approval.dismiss":   // nothing is typed: the user looks at the terminal
            guard let id = UUID(uuidString: try need(r, "id")) else { throw ProtocolError(code: .invalidArgs, message: "Aprovação inválida.") }
            return .object(["dismissed": .bool(await asks.dismissApproval(id))])
        default: throw ProtocolError(code: .invalidArgs, message: "Unknown command '\(r.command)'")
        }
    }

    private func chatSend(_ r: Request) async throws -> JSONValue {
        let text = (str(r, "text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "Mensagem vazia.") }
        guard text.count <= ChatMessage.maxText else {
            throw ProtocolError(code: .invalidArgs, message: "A mensagem passa de 8 000 caracteres.")
        }
        var w: Work?
        if let s = str(r, "work") {
            guard let id = UUID(uuidString: s), let found = try await work.get(id) else {
                throw ProtocolError(code: .notFound, message: "Trabalho não encontrado.")
            }
            w = found
        }
        let user = ChatMessage(role: .user, workId: w?.id, text: text)
        func reply(_ t: String) async throws -> JSONValue {
            try await post(user)
            try await post(ChatMessage(role: .orq, workId: w?.id, text: t, replyTo: user.id))
            return .object(["messageId": .string(user.id.uuidString.lowercased()), "queued": .bool(false)])
        }

        var names: [UUID: String] = [:]
        for t in ws.terminals { names[t.id] = t.name }
        for f in ws.floors { names[f.id] = f.name }

        // "?": a free question to the on-device assistant (before status phrases and @name); its answer is never typed anywhere
        if text.hasPrefix("?") {
            let question = text.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !question.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "Nada para perguntar depois de ?.") }
            if case .unavailable(let why) = await assistant.status() {
                return try await reply("Perguntas livres precisam do macOS 26 com Apple Intelligence ligada (\(why)).")
            }
            try await post(user)
            let store = work, view = WorkRegistryView(works: { try await store.list(includeClosed: true) }, names: names,
                                                      badges: await hub.currentBadges)
            let workId = w?.id, userId = user.id
            Task { [weak self] in
                guard let self else { return }
                let a = await assistant.answer(question: question, selected: workId, registry: view)
                let text = a.text.map { "Assistente: " + $0 } ?? Self.questionFailure(a.reason ?? "o modelo não respondeu")
                do { try await post(ChatMessage(role: .orq, workId: workId, text: text, replyTo: userId)) }
                catch { workLog("chat: \((error as? ProtocolError)?.message ?? "\(error)")") }
            }
            return .object(["messageId": .string(user.id.uuidString.lowercased()), "queued": .bool(true)])
        }

        if let q = StatusQuestion.match(text) {
            if q == .summary {
                guard let w else { return try await reply("Escolha um trabalho para ver o resumo.") }
                return try await reply(WorkSummary.make(w, terminalAlive: await registry.process(w.terminalId)?.isRunning == true, now: Date()).markdown(boldTitle: true))
            }
            let works = if let w { [w] } else { try await work.list(includeClosed: false) }
            return try await reply(WorkStatusText.answer(q, works: works, names: names, badges: await hub.currentBadges, now: Date()))
        }

        let target: TerminalRecord, prompt: String
        if text.hasPrefix("@") {
            let word = text.dropFirst().prefix { !$0.isWhitespace }
            let rest = text.dropFirst(1 + word.count).trimmingCharacters(in: .whitespacesAndNewlines)
            var name = String(word)
            while let c = name.last, ",.:;!?".contains(c) { name.removeLast() }   // "@Dev, faz isso"
            let hits = ws.terminals.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            guard hits.count <= 1 else { return try await reply("Mais de um terminal se chama \(name).") }
            guard !name.isEmpty, let t = hits.first else { return try await reply("Não conheço \(name).") }
            guard !rest.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "Nada para mandar depois de @\(name).") }
            (target, prompt) = (t, rest)
        } else if let w {
            guard let own = ws.terminals.first(where: { $0.id == w.terminalId }) else {
                return try await reply("O terminal deste trabalho não existe mais.")
            }
            let maestro = own.isMaestro ? own : ConnectionGraph.reachable(from: own.id, in: ws)
                .filter(\.isMaestro).min { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            (target, prompt) = (maestro ?? own, text)
        } else {
            return try await reply("Escolha um trabalho ou comece com @nome.")
        }

        guard await registry.process(target.id)?.isRunning == true else { return try await reply("\(target.name) não está rodando.") }
        // a pasted text ends with Enter: at an approval prompt that Enter would answer it blindly
        if await hub.currentBadges[target.id] == .attention {
            return try await reply("\(target.name) está esperando uma aprovação; responda o pedido primeiro.")
        }
        var sent = user; sent.terminal = target.name
        try await post(sent)
        let id = target.id, name = target.name, workId = w?.id
        Task { [weak self] in
            guard let self else { return }
            let answer: ChatMessage
            // a reply arriving after the timeout is dropped: the turn holds its slot until it ends, but nobody waits for it
            do {
                let a = try await asks.askAsUser(to: id, prompt: prompt, timeout: Self.chatReplyTimeout)
                answer = ChatMessage(role: .agent, workId: workId, terminal: name, text: a.output, replyTo: sent.id)
            } catch {
                let text = (error as? ProtocolError) == AskCoordinator.awaitingApproval(name)
                    ? "\(name) está esperando uma aprovação; a mensagem não foi enviada."
                    : "\(name) não respondeu (\(Self.reason(error)))."
                answer = ChatMessage(role: .orq, workId: workId, terminal: name, text: text, replyTo: sent.id)
            }
            do { try await post(answer) } catch { workLog("chat: \((error as? ProtocolError)?.message ?? "\(error)")") }
        }
        return .object(["messageId": .string(user.id.uuidString.lowercased()), "queued": .bool(true)])
    }

    /// `work.approve`: `{sent, reason?}`; the chat gets "Aprovado"/"Negado" once the prompt is answered.
    private func approve(_ id: UUID, allow: Bool) async throws -> JSONValue {
        func result(_ sent: Bool, _ reason: String? = nil) -> JSONValue {
            var o: [String: JSONValue] = ["sent": .bool(sent)]
            if let reason { o["reason"] = .string(reason) }
            return .object(o)
        }
        let a: Approval, sent: Bool
        switch await asks.approve(id, allow: allow) {
        case .stale: return result(false, "pedido não está mais pendente")
        case .unknown: return result(false, "saída demais para conferir; olhe o terminal")
        case .failed: return result(false, "o terminal não recebeu a resposta")
        case .sent(let x): (a, sent) = (x, true)
        case .dismissed(let x): (a, sent) = (x, false)
        }
        await hub.answered(a.terminalId)
        try await post(ChatMessage(role: .orq, workId: try? await work.active(terminal: a.terminalId)?.id, terminal: a.terminal,
                                   text: allow ? "Aprovado" : "Negado"))
        return result(sent)
    }

    /// ApprovalTracker: a new prompt gets the badge, "‹terminal› pede permissão: ‹…›" in the chat and `work.approval
    /// {approval}` to the panels; the same one changed (redrawn, restored) the badge and the event only; one cleared
    /// (answered) `work.approval {terminalId, cleared: true}`, so the panels drop its card.
    func approvalChanged(_ e: ApprovalEvent) async {
        switch e {
        case .raised(let a): await approvalRaised(a)
        case .updated(let a):
            await hub.approvalRaised(a)
            do { await emitToWorkPanels("work.approval", .object(["approval": try isoJSON(a)])) }
            catch { workLog("approval: \((error as? ProtocolError)?.message ?? "\(error)")") }
        case .cleared(let t):
            await hub.approvalCleared(t)
            await emitToWorkPanels("work.approval", .object(["terminalId": .string(t.uuidString.lowercased()), "cleared": .bool(true)]))
        }
    }

    private func approvalRaised(_ a: Approval) async {
        await hub.approvalRaised(a)
        let line = a.kind == .menu ? a.reason : a.prompt.split(separator: "\n").last.map(String.init) ?? a.reason
        let text = a.kind == .unknown
            ? "\(a.terminal) pode estar esperando você (saída demais para conferir); olhe o terminal."
            : "\(a.terminal) pede permissão: \(line)"
        do {
            try await post(ChatMessage(role: .orq, workId: try? await work.active(terminal: a.terminalId)?.id, terminal: a.terminal,
                                       text: text))
            await emitToWorkPanels("work.approval", .object(["approval": try isoJSON(a)]))
        } catch { workLog("approval: \((error as? ProtocolError)?.message ?? "\(error)")") }
    }

    /// `work.rerail`: types `RerailText.block` into `t` through `inject` (same FIFO and readiness gate as `ask`, never
    /// into a pending approval), then "Recoloquei ‹t› no trilho." and the block in the chat. `wait: false` (a Maestro on
    /// itself, mid-turn): queued without waiting, so its own tool call can't hold the turn the inject waits for.
    /// Refused at once when `t` shows an approval prompt, or does not take a paste as one prompt (a shell, a program
    /// without bracketed paste: each line would run). A Maestro's own rerail is queued once at a time.
    func rerail(_ t: TerminalRecord, _ w: Work, now: Date, wait: Bool) async throws -> JSONValue {
        let block = RerailText.block(w, now: now), id = t.id, name = t.name
        let atApproval = ProtocolError(code: .unavailable, message: "\(name) está pedindo aprovação; recolocar no trilho depois de responder")
        guard await !asks.hasPendingApproval(id) else { throw atApproval }
        // ponytail: paste mode as of now; an agent that turns it off before the queued block is written still gets it
        guard t.preset != .shell, await asks.pasteEnabled(id) else {
            throw ProtocolError(code: .unavailable, message: "\(name) não aceita colar texto com segurança; recolocar no trilho só em agentes")
        }
        let result = JSONValue.object(["injected": .bool(wait), "chars": .number(Double(block.count))])
        func run() async throws(ProtocolError) {
            do { try await asks.inject(to: id, prompt: block) } catch {
                guard error == AskCoordinator.awaitingApproval(name) else { throw error }
                throw atApproval
            }
            do { try await post(ChatMessage(role: .orq, workId: w.id, terminal: name, text: "Recoloquei \(name) no trilho.\n\n" + block)) }
            catch { workLog("rerail: \((error as? ProtocolError)?.message ?? "\(error)")") }
        }
        if wait { try await run() } else {
            guard selfRerails.insert(id).inserted else { return result }   // one already queued: it carries the same state
            Task {
                do { try await run() } catch { workLog("rerail \(name): \((error as? ProtocolError)?.message ?? "\(error)")") }
                selfRerails.remove(id)
            }
        }
        return result
    }


    /// The chat line for a free question the assistant did not answer.
    static func questionFailure(_ reason: String) -> String {
        reason == WorkAssistant.busy ? reason
            : "O assistente não respondeu (\(reason == "timeout" ? "o modelo demorou mais de 20 s" : reason))."
    }

    /// Why an agent did not answer, for the chat.
    static func reason(_ e: any Error) -> String {
        guard let p = e as? ProtocolError else { return "erro interno" }
        switch p.code {
        case .timeout:
            return p.message.contains("not delivered") || p.message.contains("not accepting input")
                ? "a mensagem não foi entregue" : "sem resposta em 30 min"
        case .notRunning: return "o terminal parou"
        default: return "erro interno"
        }
    }

    /// Written to the chat, then `work.chat {message}` to every Work panel.
    private func post(_ m: ChatMessage) async throws {
        try await chat.append(m)
        await emitToWorkPanels("work.chat", .object(["message": try isoJSON(m)]))
    }

    /// The work store wrote work `id` (`WorkStore.onChange`).
    func workChanged(_ id: UUID) async {
        await emitToWorkPanels("work.changed", .object(["workId": .string(id.uuidString.lowercased())]))
        await keepSummary(id)
    }

    /// A work that just closed keeps its deterministic summary in its repo's Memory as an unreviewed decision
    /// (`memory.review` approves it). The subject is fixed per work, so closing again supersedes the earlier one.
    /// Never waits on the model; a failure is logged and told in the chat, the close stays.
    func keepSummary(_ id: UUID) async {
        guard let w = try? await work.get(id), let closedAt = w.closedAt else { savedClose[id] = nil; return }   // reopened or gone
        guard savedClose[id] != closedAt else { return }
        savedClose[id] = closedAt   // set before any await: one save per close
        let removedCwd = closeCwd.removeValue(forKey: id)
        func decided(_ d: String, _ why: String? = nil) {
            summaryDecisions.append(d)
            if let why { workLog("summary \(id.uuidString.lowercased()): \(why)") }
        }
        guard !w.tasks.isEmpty || !w.notes.isEmpty || !w.commits.isEmpty else { return decided("empty", "empty work, not saved") }
        let floor = ws.floors.first { $0.id == w.floorId }
        // the terminal's cwd (v1 memory resolves its git root); a removed terminal leaves its cwd, else its floor's worktree
        guard let cwd = ws.terminals.first(where: { $0.id == w.terminalId })?.cwd ?? removedCwd ?? floor?.path else {
            return decided("no-repo", "terminal has no directory, not saved")
        }
        let repo = await memory.repo(for: cwd)
        guard repo.root != nil else { return decided("no-repo", "no repository, not saved") }
        let alive = await registry.process(w.terminalId)?.isRunning == true
        let body = WorkSummary.make(w, terminalAlive: alive, now: Date(), escape: false).markdown()
        do {
            _ = try await saveMemory(.decision, scope: floor != nil ? .floor : .project,
                                     subject: "trabalho \(w.id.uuidString.prefix(8).lowercased())", title: "Resumo: \(RerailText.clean(w.title))",
                                     body: body, path: nil, repo: repo, floor: floor?.name, origin: "Orq (resumo)")
            decided("saved")
        } catch {
            decided("failed", (error as? ProtocolError)?.message ?? "\(error)")
            do { try await post(ChatMessage(role: .orq, workId: w.id, terminal: nil, text: "Não consegui guardar o resumo de \(RerailText.clean(w.title)) na Memória.")) }
            catch { workLog("chat: \((error as? ProtocolError)?.message ?? "\(error)")") }
        }
    }

    private func emitToWorkPanels(_ name: String, _ payload: JSONValue) async {
        for p in ws.panels where p.pluginId == "work" { await pluginEmitted(panel: p.id, name: name, payload: payload) }
    }
}

/// The "recolocar no trilho" block: only the live state of a work (open and in-progress tasks, running jobs, the 5 newest
/// decisions), Portuguese, at most `limit` characters. Titles come from agents: control/newline characters become spaces.
enum RerailText {
    static let limit = 2000
    private static let maxItem = 120

    static func clean(_ x: String, max: Int = maxItem) -> String {
        // format characters (bidi overrides, zero-width) dropped: what the agent reads is what the chat shows
        let c = String(String.UnicodeScalarView(x.unicodeScalars.filter { $0.properties.generalCategory != .format }.map { sc in
            CharacterSet.controlCharacters.contains(sc) || CharacterSet.newlines.contains(sc) ? " " : sc }))
            .trimmingCharacters(in: .whitespaces)
        return c.count > max ? String(c.prefix(max)) + "…" : c
    }

    static func block(_ w: Work, now: Date) -> String {
        let label: [JobKind: String] = [.subagent: "subagente", .shell: "shell"]
        let sections: [(String, [String])] = [
            ("Em andamento", w.tasks.filter { $0.state == .inProgress }.map { clean($0.title) }),
            ("Abertas", w.tasks.filter { $0.state == .open }.map { clean($0.title) }),
            ("Rodando", w.jobs.filter { $0.state == .running }.map { "\(label[$0.kind]!) \(clean($0.label))" }),
            ("Decisões recentes", w.notes.filter(\.decision).suffix(5).map { clean($0.text) }),
        ]
        // ponytail: k items per section; over the limit, retry with fewer (k = 0 keeps only the counts)
        for k in [20, 8, 3, 1, 0] {
            var lines = ["[Orq] Estado atual do trabalho \"\(clean(w.title).replacingOccurrences(of: "\"", with: "'"))\" — considere encerrado tudo o que não está aqui."]
            for (head, items) in sections where !items.isEmpty {
                lines.append("\(head):")
                lines += items.prefix(k).map { "- " + $0 }
                if items.count > k { lines.append("- … e mais \(items.count - k)") }
            }
            lines.append("Continue a partir daqui. Ao adiar use `orq work task defer`, ao desistir `orq work task drop`.")
            let text = lines.joined(separator: "\n")
            if text.count <= limit || k == 0 { return text }
        }
        return ""   // unreachable: k == 0 returns
    }
}
