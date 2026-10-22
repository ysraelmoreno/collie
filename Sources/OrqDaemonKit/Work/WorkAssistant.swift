import Foundation
import os
import OrqCore

/// Rewrites a work's deterministic summary in plain Portuguese with the on-device model, within a deadline. The
/// deterministic markdown is always the source: any failure returns no text and the reason, never a guess.
actor WorkAssistant {
    typealias Rewrite = (text: String?, reason: String?)
    static let instructions = "Reescreva o resumo de trabalho abaixo em português, em até 8 frases curtas, na ordem: o que foi feito, o que ficou para depois, o que não foi feito e onde parou. Use somente os fatos do texto. Não acrescente tarefas, nomes, números ou conclusões que não estejam nele. Se uma seção não existir, não a mencione."
    static let deadline: Duration = .seconds(10)
    /// How long a timeout or failure is answered from the cache (a stuck model is not asked again meanwhile).
    static let failureTTL: Duration = .seconds(60)
    static let maxOutput = 4_000
    static let maxCached = 200

    /// A work's model call: `answer` resolves at the deadline at the latest; `model` lives until the call really ends.
    private struct Run { let token: UUID; let key: Int; let answer: Task<Rewrite, Never>; let model: Task<Void, Never> }
    private struct Cached { let token: UUID; let key: Int; let rewrite: Rewrite }

    private let model: any LocalModel
    private let clock: any Clock<Duration>
    /// Keyed by the markdown's hash: one call in flight a work, and its last result.
    private var running: [UUID: Run] = [:]
    private var cache: [UUID: Cached] = [:]

    init(model: any LocalModel, clock: any Clock<Duration> = ContinuousClock()) { self.model = model; self.clock = clock }

    func status() async -> LocalModelAvailability { await model.availability() }

    func rewrite(_ s: WorkSummary, workId: UUID) async -> Rewrite {
        let prompt = s.markdown(), key = prompt.hashValue
        if let c = cache[workId], c.key == key { return c.rewrite }
        if let r = running[workId] {
            if r.key == key { return await r.answer.value }   // also a call past its deadline: no second call
            // ponytail: if the model ignores cancellation, a markdown change leaves one live call per change (each ends
            // at its own return); cap per work if a model ever does that
            r.model.cancel()   // newer markdown: the old call is moot
        }
        let run = start(workId, key, prompt)
        running[workId] = run
        let r = await run.answer.value
        if running[workId]?.token == run.token { store(workId, Cached(token: run.token, key: key, rewrite: r)) }
        return r
    }

    private func start(_ id: UUID, _ key: Int, _ prompt: String) -> Run {
        let token = UUID(), gate = Gate(), (model, clock) = (self.model, self.clock)
        let call = Task {
            let r = await Self.ask(model, Self.instructions, prompt, [])
            gate.finish(r)
            await self.ended(id, token, key, r)
        }
        let timer = Task { try? await clock.sleep(for: Self.deadline); if gate.finish((nil, "timeout")) { call.cancel() } }
        let answer = Task { let r = await gate.value(); timer.cancel(); return r }
        return Run(token: token, key: key, answer: answer, model: call)
    }

    /// The model call ended (maybe long after its deadline): the work may ask again; a late success is still kept.
    private func ended(_ id: UUID, _ token: UUID, _ key: Int, _ r: Rewrite) {
        guard running[id]?.token == token else { return }
        running[id] = nil
        if r.text != nil { store(id, Cached(token: token, key: key, rewrite: r)) }
    }

    private func store(_ id: UUID, _ c: Cached) {
        // ponytail: over the cap an arbitrary work is dropped (it only costs one more rewrite); LRU if that shows
        if cache[id] == nil, cache.count >= Self.maxCached { cache.remove(at: cache.startIndex) }
        cache[id] = c
        guard c.rewrite.text == nil else { return }
        let clock = self.clock
        Task { try? await clock.sleep(for: Self.failureTTL); self.expire(id, c.token) }
    }

    private func expire(_ id: UUID, _ token: UUID) { if cache[id]?.token == token { cache[id] = nil } }

    private static func ask(_ model: any LocalModel, _ instructions: String, _ prompt: String, _ tools: [AssistantTool]) async -> Rewrite {
        if case .unavailable(let why) = await model.availability() { return (nil, why) }
        do {
            let t = sanitize(try await model.respond(instructions: instructions, prompt: prompt, tools: tools))
            return t.isEmpty ? (nil, "o modelo não respondeu") : (t, nil)
        } catch {
            return (nil, Task.isCancelled ? "cancelado" : "o modelo falhou")
        }
    }

    // MARK: free questions (the chat's "?")

    static let questionInstructions = "Você responde perguntas sobre o trabalho dos agentes no Orq. Use as ferramentas para consultar o registro; responda só com o que elas devolverem, em português, em poucas frases. Se o registro não tiver a resposta, diga que não sabe."
    static let questionDeadline: Duration = .seconds(20)
    static let maxQueued = 3
    static let busy = "O assistente está ocupado, tente de novo em instantes."
    static let maxToolOutput = 2_000

    private var asking = false
    private var waiting: [(id: UUID, c: CheckedContinuation<Bool, Never>)] = []
    /// A question never waits longer than the calls ahead of it can take: (maxQueued + 1) × its deadline.
    static var queueWait: Duration { questionDeadline * (maxQueued + 1) }
    var queued: Int { waiting.count }

    /// One question at a time, at most `maxQueued` waiting (more: `busy`); each answered within `questionDeadline`.
    /// The model only sees the registry through `tools(registry)`; its answer is sanitized like a rewrite.
    func answer(question: String, selected: UUID?, registry: WorkRegistryView) async -> Rewrite {
        if asking {
            guard waiting.count < Self.maxQueued else { return (nil, Self.busy) }
            let id = UUID(), clock = self.clock
            let timer = Task {
                do { try await clock.sleep(for: Self.queueWait) } catch { return }
                self.giveUp(id)
            }
            // `next()` hands the slot over (`asking` stays true); a stuck model past the wait gets `busy` instead
            let turn = await withCheckedContinuation { c in waiting.append((id, c)) }
            timer.cancel()
            guard turn else { return (nil, Self.busy) }
        }
        asking = true
        var prompt = question
        if let selected, let w = try? await registry.works().first(where: { $0.id == selected }) {
            prompt = "Trabalho selecionado: \(w.id.uuidString.lowercased()) \(RerailText.clean(w.title))\n\n" + question
        }
        let gate = Gate(), (model, clock) = (self.model, self.clock), tools = Self.tools(registry), p = prompt
        let call = Task { gate.finish(await Self.ask(model, Self.questionInstructions, p, tools)) }
        let timer = Task { try? await clock.sleep(for: Self.questionDeadline); if gate.finish((nil, "timeout")) { call.cancel() } }
        let r = await gate.value()
        timer.cancel()
        // ponytail: rewrites have no global cap and share the model with questions; a burst of rewrites can make a
        // question time out (bounded by the deadlines). Add a shared semaphore if that shows.
        // ponytail: the slot frees when the call really ends, so calls never pile up; a model that ignores cancellation
        // holds the queue (later questions get `busy`) until it returns
        Task { _ = await call.value; self.next() }
        return r
    }

    private func next() { if waiting.isEmpty { asking = false } else { waiting.removeFirst().c.resume(returning: true) } }

    private func giveUp(_ id: UUID) {
        guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: i).c.resume(returning: false)
    }

    /// Read-only views of the registry. `argument` comes from the model: it only filters or looks up, bounded.
    static func tools(_ reg: WorkRegistryView) -> [AssistantTool] {
        [AssistantTool(name: "listarTrabalhos",
                       description: "Lista os trabalhos ativos e os 20 fechados mais recentes (id · título · terminal · estado). O argumento filtra por texto; vazio lista todos.") {
            await listing(reg, filter: argument($0)) },
         AssistantTool(name: "resumoDoTrabalho", description: "O resumo de um trabalho (feito, para depois, em aberto, onde parou), pelo id ou pelo título.") {
            await summary(reg, of: argument($0)) },
         AssistantTool(name: "statusAgora", description: "Onde estamos, o que travou e o que está rodando agora nos trabalhos ativos.") { _ in
            await status(reg) }]
    }

    private static let unreadable = "O registro de trabalhos não pôde ser lido."

    private static func listing(_ reg: WorkRegistryView, filter: String) async -> String {
        guard let all = try? await reg.works() else { return unreadable }
        // the filter looks at the raw fields; only what is printed is escaped
        let lines = ordered(all, closedLimit: 20).compactMap { w -> String? in
            let title = RerailText.clean(w.title), terminal = RerailText.clean(reg.names[w.terminalId] ?? "terminal removido")
            let state = w.closedAt.map { "fechado em " + day($0) } ?? "ativo"
            let raw = [w.id.uuidString.lowercased(), title, terminal, state].joined(separator: " · ")
            guard filter.isEmpty || raw.localizedCaseInsensitiveContains(filter) else { return nil }
            return [w.id.uuidString.lowercased(), WorkSummary.escaped(title), WorkSummary.escaped(terminal), state].joined(separator: " · ")
        }
        return bounded(lines.isEmpty ? "Nenhum trabalho." : lines.joined(separator: "\n"))
    }

    private static func summary(_ reg: WorkRegistryView, of key: String) async -> String {
        guard let all = try? await reg.works() else { return unreadable }
        let ws = ordered(all, closedLimit: .max)
        let w = ws.first { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame }
            ?? ws.first { $0.title.caseInsensitiveCompare(key) == .orderedSame }
            ?? ws.first { !key.isEmpty && $0.title.localizedCaseInsensitiveContains(key) }
        guard let w else { return "Nenhum trabalho com esse id ou título." }
        // `terminalAlive` is unused by WorkSummary (see its note)
        return bounded(WorkSummary.make(w, terminalAlive: true, now: reg.now()).markdown())
    }

    private static func status(_ reg: WorkRegistryView) async -> String {
        guard let all = try? await reg.works() else { return unreadable }
        let active = all.filter { $0.closedAt == nil }, now = reg.now()
        let parts: [(String, StatusQuestion)] = [("Onde estamos", .whereAreWe), ("O que travou", .whatIsStuck), ("O que está rodando", .whatIsRunning)]
        return bounded(parts.map { "\($0.0):\n" + WorkStatusText.answer($0.1, works: active, names: reg.names, badges: reg.badges, now: now) }
            .joined(separator: "\n\n"))
    }

    /// Active works, then the newest `closedLimit` closed ones.
    private static func ordered(_ all: [Work], closedLimit: Int) -> [Work] {
        all.filter { $0.closedAt == nil } + all.filter { $0.closedAt != nil }.sorted { $0.closedAt! > $1.closedAt! }.prefix(closedLimit)
    }

    private static func c(_ x: String) -> String { WorkSummary.escaped(RerailText.clean(x)) }
    private static func argument(_ x: String) -> String { String(RerailText.clean(x, max: .max).prefix(200)) }

    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    /// Control and format characters dropped (newlines kept), at most `maxToolOutput` characters.
    private static func bounded(_ x: String) -> String {
        let t = String(String.UnicodeScalarView(x.unicodeScalars.filter { sc in
            sc == "\n" || !(sc.properties.generalCategory == .control || sc.properties.generalCategory == .format) }))
        return t.count <= maxToolOutput ? t : String(t.prefix(maxToolOutput - 1)) + "…"
    }

    /// Model output is untrusted: control and format characters dropped (newlines kept), bounded, its own markdown
    /// escapes undone (the prompt was escaped markdown) and everything escaped again like the summary's agent text,
    /// so it cannot become a link in the panel. It is shown, never typed into a PTY.
    static func sanitize(_ x: String) -> String {
        let kept = x.unicodeScalars.filter { sc in
            sc == "\n" || !(sc.properties.generalCategory == .control || sc.properties.generalCategory == .format)
        }
        let t = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkSummary.escaped(unescaped(String(t.prefix(maxOutput))))
    }

    /// `\_` → `_` for every character `WorkSummary.escaped` escapes.
    static func unescaped(_ x: String) -> String {
        var out = "", pending = false
        for ch in x {
            if pending { if !"\\`*_[]()<>~!#:.".contains(ch) { out.append("\\") }; out.append(ch); pending = false }
            else if ch == "\\" { pending = true }
            else { out.append(ch) }
        }
        if pending { out.append("\\") }
        return out
    }
}

/// First result wins; `value` waits for it.
private final class Gate: Sendable {
    private let state = OSAllocatedUnfairLock<(result: WorkAssistant.Rewrite?, waiter: CheckedContinuation<WorkAssistant.Rewrite, Never>?)>(
        initialState: (nil, nil))
    @discardableResult func finish(_ r: WorkAssistant.Rewrite) -> Bool {
        let w: CheckedContinuation<WorkAssistant.Rewrite, Never>?? = state.withLock { s in
            guard s.result == nil else { return .none }
            s.result = r; defer { s.waiter = nil }; return .some(s.waiter)
        }
        guard let w else { return false }
        w?.resume(returning: r)
        return true
    }
    func value() async -> WorkAssistant.Rewrite {
        await withCheckedContinuation { c in
            let r = state.withLock { s -> WorkAssistant.Rewrite? in if s.result == nil { s.waiter = c }; return s.result }
            if let r { c.resume(returning: r) }
        }
    }
}

/// What the free-question tools may read: the work store (closed works included) and a snapshot of names and badges.
struct WorkRegistryView: Sendable {
    let works: @Sendable () async throws -> [Work]
    let names: [UUID: String]
    let badges: [UUID: StatusBadge]
    var now: @Sendable () -> Date = { Date() }
}
