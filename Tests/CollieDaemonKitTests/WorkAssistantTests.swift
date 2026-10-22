import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// A clock that only moves on `advance`; `sleepers` lets a test wait until every sleep is registered.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by d: Duration) -> Instant { Instant(offset: offset + d) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }
    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var waiters: [(id: UUID, deadline: Instant, c: CheckedContinuation<Void, any Error>)] = []
    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .zero }
    var sleepers: Int { lock.withLock { waiters.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                lock.withLock {
                    if Task.isCancelled { c.resume(throwing: CancellationError()) }
                    else if deadline <= current { c.resume() } else { waiters.append((id, deadline, c)) }
                }
            }
        } onCancel: {
            let w = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard let i = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: i).c
            }
            w?.resume(throwing: CancellationError())
        }
    }
    func advance(by d: Duration) {
        let due = lock.withLock {
            current = current.advanced(by: d)
            let due = waiters.filter { $0.deadline <= current }
            waiters.removeAll { $0.deadline <= current }
            return due
        }
        for w in due { w.c.resume() }
    }
    func waitForSleepers(_ n: Int) async { while sleepers < n { await Task.yield() } }
}

actor FakeModel: LocalModel {
    /// `slow`: 30 s on the clock, cancellable; `stuck`: 30 s that cancellation does not stop.
    /// `useTools`: calls each named tool with its argument (outputs in `toolOutputs`), then answers "ok".
    enum Mode { case answer(String), fail, slow, stuck, hang, unavailable, useTools([(String, String)]) }
    var mode: Mode
    var calls: [(instructions: String, prompt: String)] = []
    var toolNames: [String] = []
    var toolOutputs: [String: String] = [:]
    var cancelled = 0
    let clock: ManualClock?
    init(_ mode: Mode, clock: ManualClock? = nil) { self.mode = mode; self.clock = clock }
    func availability() async -> LocalModelAvailability {
        if case .unavailable = mode { return .unavailable("Apple Intelligence está desligada") }
        return .available
    }
    func respond(instructions: String, prompt: String, tools: [AssistantTool]) async throws -> String {
        calls.append((instructions, prompt))
        toolNames = tools.map(\.name)
        switch mode {
        case .useTools(let uses):
            for (name, arg) in uses { if let t = tools.first(where: { $0.name == name }) { toolOutputs[name] = await t.run(arg) } }
            return "ok"
        case .answer(let s): await Task.yield(); return s
        case .fail: throw ProtocolError(code: .internal, message: "boom")
        case .slow:
            do { try await clock!.sleep(for: .seconds(30)) } catch { cancelled += 1; throw error }
            return "tarde demais"
        case .stuck:
            let clock = clock!
            await Task.detached { try? await clock.sleep(for: .seconds(30)) }.value
            return "tarde demais"
        case .hang:   // far past any test deadline, ignores cancellation
            let clock = clock!
            await Task.detached { try? await clock.sleep(for: .seconds(100_000)) }.value
            return "nunca"
        case .unavailable: return ""
        }
    }
    func count() -> Int { calls.count }
}

@Suite struct WorkAssistantTests {
    func summary(_ title: String = "Login") -> WorkSummary {
        WorkSummary.make(Work(title: title, terminalId: UUID(), tasks: [WorkTask(id: "a", title: "form", state: .done)]),
                         terminalAlive: true, now: Date())
    }

    @Test func rewriteUsesModel() async {
        let m = FakeModel(.answer("Foi feito o formulário."))
        let a = WorkAssistant(model: m)
        let s = summary()
        let r = await a.rewrite(s, workId: UUID())
        #expect(r.text == "Foi feito o formulário." && r.reason == nil)
        let calls = await m.calls
        #expect(calls.count == 1 && calls[0].prompt == s.markdown() && calls[0].instructions == WorkAssistant.instructions)
        #expect(WorkAssistant.instructions.hasPrefix("Reescreva o resumo de trabalho abaixo em português, em até 8 frases curtas"))
    }

    @Test func unavailableFallsBack() async {
        let m = FakeModel(.unavailable)
        let r = await WorkAssistant(model: m).rewrite(summary(), workId: UUID())
        let n = await m.count()
        #expect(r.text == nil && r.reason == "Apple Intelligence está desligada" && n == 0)
        #expect(await WorkAssistant(model: m).status() == .unavailable("Apple Intelligence está desligada"))
    }

    @Test func modelErrorFallsBack() async {
        let r = await WorkAssistant(model: FakeModel(.fail)).rewrite(summary(), workId: UUID())
        #expect(r.text == nil && r.reason == "o modelo falhou")
    }

    @Test func slowModelTimesOut() async {
        let clock = ManualClock()
        let a = WorkAssistant(model: FakeModel(.slow, clock: clock), clock: clock)
        async let r = a.rewrite(summary(), workId: UUID())
        await clock.waitForSleepers(2)   // the deadline and the model
        clock.advance(by: .seconds(10))
        let got = await r
        #expect(got.text == nil && got.reason == "timeout")
        clock.advance(by: .seconds(30))   // let the cancelled fake finish
    }

    @Test func stuckModelIsNotAskedAgain() async {
        let clock = ManualClock(), m = FakeModel(.stuck, clock: clock)
        let a = WorkAssistant(model: m, clock: clock), id = UUID(), s = summary()
        async let r = a.rewrite(s, workId: id)
        await clock.waitForSleepers(2)
        clock.advance(by: .seconds(10))
        #expect(await r.reason == "timeout")
        #expect(await a.rewrite(s, workId: id).reason == "timeout")   // cached: no second call while the first hangs
        #expect(await m.count() == 1)
        clock.advance(by: .seconds(20))   // the stuck call ends late: its answer replaces the cached timeout
        while await a.rewrite(s, workId: id).text == nil { await Task.yield() }
        #expect(await m.count() == 1)
    }

    @Test func newerMarkdownCancelsOldCall() async {
        let clock = ManualClock(), m = FakeModel(.slow, clock: clock)
        let a = WorkAssistant(model: m, clock: clock), id = UUID()
        async let old = a.rewrite(summary("A"), workId: id)
        await clock.waitForSleepers(2)
        async let new = a.rewrite(summary("B"), workId: id)
        while await m.cancelled < 1 { await Task.yield() }
        #expect(await old.reason == "cancelado")
        await clock.waitForSleepers(2)   // B's deadline and call (A's timer was cancelled with its answer)
        clock.advance(by: .seconds(10))
        #expect(await new.reason == "timeout")
        #expect(await m.count() == 2)
    }

    @Test func modelEscapesAreNotDoubled() {
        #expect(WorkAssistant.sanitize("usar \\_id\\_ e a\\*b") == "usar \\_id\\_ e a\\*b")
        #expect(WorkAssistant.sanitize("usar \\_id_") == "usar \\_id\\_")
    }

    @Test func concurrentRewritesShareOne() async {
        let m = FakeModel(.answer("ok"))
        let a = WorkAssistant(model: m), id = UUID(), s = summary()
        let results = await withTaskGroup(of: String?.self) { g in
            for _ in 0..<5 { g.addTask { await a.rewrite(s, workId: id).text } }
            return await g.reduce(into: []) { $0.append($1) }
        }
        let n = await m.count()
        #expect(results == Array(repeating: "ok", count: 5) && n == 1)
        _ = await a.rewrite(s, workId: id)   // cached
        #expect(await m.count() == 1)
    }

    @Test func cacheInvalidatesOnChange() async {
        let m = FakeModel(.answer("ok"))
        let a = WorkAssistant(model: m), id = UUID()
        _ = await a.rewrite(summary("A"), workId: id)
        _ = await a.rewrite(summary("B"), workId: id)
        #expect(await m.count() == 2)
    }

    @Test func outputIsSanitized() async {
        let raw = "Feito [clique](https://x.y)\u{1B}[31m\u{200B}\nfim" + String(repeating: "a", count: 5000)
        let r = await WorkAssistant(model: FakeModel(.answer(raw))).rewrite(summary(), workId: UUID())
        let t = r.text ?? ""
        #expect(t.hasPrefix("Feito \\[clique\\]\\(https\\://x.y\\)\\[31m\nfim"))
        #expect(!t.unicodeScalars.contains { $0 == "\u{1B}" || $0 == "\u{200B}" } && t.count < 4_100)
    }

    @Test(.enabled { await FoundationLocalModel().availability() == .available }) func realModelRewrites() async {
        let clock = ContinuousClock(), start = clock.now
        let r = await WorkAssistant(model: FoundationLocalModel()).rewrite(summary(), workId: UUID())
        #expect(r.text?.isEmpty == false, "\(r.reason ?? "")")
        #expect(start.duration(to: clock.now) <= .seconds(11))
    }

    @Test func summaryCommandNatural() async throws {
        try await withDaemon(configure: { $0.localModel = FakeModel(.answer("Resumo natural.")) }) { d, p in
            let s = try await spawn(d, p, "A")
            let tok = try await tokenOf(d, s.id)
            func cmd(_ c: String, _ a: [String: JSONValue] = [:]) async throws -> Response {
                try await send(p, Request(id: "w", terminalId: s.id, token: tok, command: c, args: a), timeoutSeconds: 30)
            }
            #expect(try await cmd("work.start", ["title": .string("Login")]).ok)
            guard case .object(let r)? = try await cmd("work.summary", ["natural": .bool(true)]).result else { Issue.record("summary"); return }
            #expect(r["natural"] == .bool(true) && r["text"] == .string("Resumo natural.") && r["markdown"] != nil)
            guard case .object(let plain)? = try await cmd("work.summary").result else { Issue.record("plain"); return }
            #expect(plain["natural"] == .bool(false) && plain["text"] == nil)
            #expect(try await cmd("work.assistant.status").result == .object(["available": .bool(true)]))
        }
        try await withDaemon(configure: { $0.localModel = FakeModel(.unavailable) }) { d, p in
            let st = try await send(p, Request(id: "s", token: d.adminToken, command: "work.assistant.status"))
            #expect(st.result == .object(["available": .bool(false), "reason": .string("Apple Intelligence está desligada")]))
        }
    }

    // MARK: free questions

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    func registry(_ works: [Work], names: [UUID: String] = [:], badges: [UUID: StatusBadge] = [:]) -> WorkRegistryView {
        WorkRegistryView(works: { works }, names: names, badges: badges, now: { Self.now })
    }

    @Test func toolsReadOnlyRegistry() async {
        let dev = UUID(), ops = UUID()
        let tasks = (0..<300).map { WorkTask(id: "t\($0)", title: "tarefa [\($0)](https://x.y) " + String(repeating: "x", count: 60), state: .done) }
        let a = Work(title: "Login", terminalId: dev, tasks: tasks, jobs: [WorkJob(id: "j", kind: .shell, label: "build", state: .running)])
        let b = Work(title: "Velho", terminalId: ops, closedAt: Self.now.addingTimeInterval(-3600), closedBy: "app")
        let names = [dev: "Dev", ops: "Ops"], badges = [dev: StatusBadge.working]
        let reg = registry([a, b], names: names, badges: badges)
        let m = FakeModel(.useTools([("listarTrabalhos", ""), ("resumoDoTrabalho", "login"), ("statusAgora", "o que houve?")]))
        let r = await WorkAssistant(model: m).answer(question: "como vai?", selected: nil, registry: reg)
        #expect(r.text == "ok")
        #expect(await m.toolNames == ["listarTrabalhos", "resumoDoTrabalho", "statusAgora"])
        let out = await m.toolOutputs
        let day = WorkAssistant.day(b.closedAt!)
        #expect(out["listarTrabalhos"] == "\(a.id.uuidString.lowercased()) · Login · Dev · ativo\n\(b.id.uuidString.lowercased()) · Velho · Ops · fechado em \(day)")
        let md = WorkSummary.make(a, terminalAlive: true, now: Self.now).markdown()
        #expect(md.count > 2_000 && out["resumoDoTrabalho"] == String(md.prefix(1_999)) + "…")
        let status = [("Onde estamos", StatusQuestion.whereAreWe), ("O que travou", .whatIsStuck), ("O que está rodando", .whatIsRunning)]
            .map { "\($0.0):\n" + WorkStatusText.answer($0.1, works: [a], names: names, badges: badges, now: Self.now) }.joined(separator: "\n\n")
        #expect(out["statusAgora"] == status)
        #expect(out.values.allSatisfy { $0.count <= 2_000 })
        // the argument only filters / looks up
        let tools = WorkAssistant.tools(reg)
        #expect(await tools[0].run("ops") == "\(b.id.uuidString.lowercased()) · Velho · Ops · fechado em \(day)")
        #expect(await tools[0].run("; rm -rf /") == "Nenhum trabalho.")
        #expect(await tools[1].run(b.id.uuidString) == WorkSummary.make(b, terminalAlive: true, now: Self.now).markdown())
        #expect(await tools[1].run("../../etc/passwd") == "Nenhum trabalho com esse id ou título.")
    }

    @Test func questionPromptHasSelection() async {
        let w = Work(title: "Tela\u{1B} de login", terminalId: UUID())
        let m = FakeModel(.answer("Resposta [x](https://y.z)."))
        let r = await WorkAssistant(model: m).answer(question: "e agora", selected: w.id, registry: registry([w]))
        #expect(r.text == "Resposta \\[x\\]\\(https\\://y.z\\).")
        let c = await m.calls
        #expect(c.count == 1 && c[0].instructions == WorkAssistant.questionInstructions)
        #expect(c[0].prompt == "Trabalho selecionado: \(w.id.uuidString.lowercased()) Tela  de login\n\ne agora")
        #expect(WorkAssistant.questionInstructions.hasPrefix("Você responde perguntas sobre o trabalho dos agentes no Collie."))
    }

    @Test func freeQuestionTimesOut() async {
        let clock = ManualClock(), m = FakeModel(.slow, clock: clock)
        let a = WorkAssistant(model: m, clock: clock)
        async let r = a.answer(question: "x", selected: nil, registry: registry([]))
        await clock.waitForSleepers(2)
        clock.advance(by: .seconds(10))
        #expect(clock.sleepers == 2)   // 10 s is not the question's deadline
        clock.advance(by: .seconds(10))
        let got = await r
        #expect(got.text == nil && got.reason == "timeout")
        while await m.cancelled < 1 { await Task.yield() }   // the model call was cancelled
        #expect(CommandRouter.questionFailure("timeout") == "O assistente não respondeu (o modelo demorou mais de 20 s).")
        #expect(CommandRouter.questionFailure(WorkAssistant.busy) == "O assistente está ocupado, tente de novo em instantes.")
    }

    @Test func assistantQueueBounded() async {
        let clock = ManualClock(), m = FakeModel(.slow, clock: clock)
        let a = WorkAssistant(model: m, clock: clock), reg = registry([])
        let first = Task { await a.answer(question: "1", selected: nil, registry: reg) }
        await clock.waitForSleepers(2)
        let rest = (2...4).map { i in Task { await a.answer(question: "\(i)", selected: nil, registry: reg) } }
        while await a.queued < 3 { await Task.yield() }
        let fifth = await a.answer(question: "5", selected: nil, registry: reg)
        #expect(fifth.text == nil && fifth.reason == WorkAssistant.busy)
        #expect(await m.count() == 1)   // one running, three waiting
        clock.advance(by: .seconds(20))
        #expect(await first.value.reason == "timeout")
        for n in 2...4 {   // each waits for the previous call to end, then gets its own 20 s
            while true {
                let (calls, cancelled) = (await m.count(), await m.cancelled)
                if calls >= n, cancelled >= n - 1, clock.sleepers >= 2 { break }
                await Task.yield()
            }
            clock.advance(by: .seconds(20))
        }
        for t in rest { #expect(await t.value.reason == "timeout") }
        #expect(await m.count() == 4)
    }

    @Test func queuedQuestionGivesUpAfterTheWait() async {
        let clock = ManualClock(), m = FakeModel(.hang, clock: clock)
        let a = WorkAssistant(model: m, clock: clock), reg = registry([])
        let first = Task { await a.answer(question: "1", selected: nil, registry: reg) }
        await clock.waitForSleepers(2)
        let second = Task { await a.answer(question: "2", selected: nil, registry: reg) }
        await clock.waitForSleepers(3)   // + the queue wait
        clock.advance(by: .seconds(20))
        #expect(await first.value.reason == "timeout")   // the model still holds the slot
        clock.advance(by: .seconds(60))
        let got = await second.value
        #expect(got.text == nil && got.reason == WorkAssistant.busy)
        #expect(await m.count() == 1 && WorkAssistant.queueWait == .seconds(80))
    }

    @Test func listFilterSeesRawFields() async {
        let w = Work(title: "a_b", terminalId: UUID())
        let tools = WorkAssistant.tools(registry([w]))
        #expect(await tools[0].run("a_b") == "\(w.id.uuidString.lowercased()) · a\\_b · terminal removido · ativo")
    }
}
