import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private let secret = "SEGREDO-NAO-GUARDAR-77"
private func assistant(input: Int, write: Int = 0, read: Int = 0, output: Int = 5, sidechain: Bool = false) -> String {
    #"{"type":"assistant","isSidechain":\#(sidechain),"message":{"id":"m\#(UUID().uuidString)","model":"claude-opus-5-5","content":[{"type":"text","text":"\#(secret)"}],"usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(write),"cache_read_input_tokens":\#(read)}}}"#
}

/// M10.1: the Shepherd's context is the last call's (input + cache written + cache read), read from the transcript's
/// tail (numbers only); a warning at 150 mil and a strong one at 250 mil, once per level per 2 h; the loop's end leaves
/// a handoff file per paddock that `work handoff` prints; `memory stats` keeps the Shepherd's context per session.
@Suite struct PastorContextLifecycleTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let root = URL(fileURLWithPath: "/tmp/collie-pastor-\(UUID().uuidString.prefix(8))")
    var projects: URL { root.appendingPathComponent("projects") }

    func transcript(_ lines: [String], name: String = "s.jsonl", padding: Int = 0) throws -> String {
        let d = projects.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let f = d.appendingPathComponent(name)
        let pad = padding > 0 ? String(repeating: #"{"type":"user","message":{"content":"x"}}"# + "\n", count: padding) : ""
        try (pad + lines.joined(separator: "\n") + "\n").write(to: f, atomically: true, encoding: .utf8)
        return f.path
    }
    func decide(_ tokens: Int?, last: ContextAdvice.Advised? = nil, now: Date? = nil, shepherd: Bool = true) -> ContextAdvice.Advised? {
        ContextAdvice.decide(tokens: tokens, isShepherd: shepherd, memoryAsked: false, last: last, now: now ?? t0)
    }

    // MARK: context and levels

    @Test func contextIsTheLastCallsInputAndCaches() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let p = try transcript([assistant(input: 900_000), assistant(input: 10, write: 2_000, read: 148_000, output: 99_999),
                                assistant(input: 1, sidechain: true)])
        #expect(ContextAdvice.lastContext(p, projectsDir: projects) == 150_010)
        #expect(ContextAdvice.lastContext(try transcript(["{\"type\":\"user\"}"], name: "n.jsonl"), projectsDir: projects) == nil)
    }

    @Test func onlyTheTailIsRead() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // 1 MB of other lines before the last call: still found (the tail), and an old call beyond the tail is not
        let p = try transcript([assistant(input: 200_000)], padding: 25_000)
        #expect(ContextAdvice.lastContext(p, projectsDir: projects) == 200_000)
        let q = try transcript([assistant(input: 200_000)] + Array(repeating: #"{"type":"user","message":{"content":"y"}}"#, count: 25_000), name: "q.jsonl")
        #expect(ContextAdvice.lastContext(q, projectsDir: projects) == nil)
    }

    @Test func levelsAtTheExactLimits() {
        #expect(ContextAdvice.level(149_999) == 0)
        #expect(ContextAdvice.level(150_000) == 1)
        #expect(ContextAdvice.level(249_999) == 1)
        #expect(ContextAdvice.level(250_000) == 2)
        #expect(decide(149_999) == nil)
        #expect(decide(150_000) == ContextAdvice.Advised(at: t0, level: 1))
        #expect(decide(250_000) == ContextAdvice.Advised(at: t0, level: 2))
        #expect(decide(nil) == nil)
        #expect(decide(300_000, shepherd: false) == nil)
    }

    @Test func oneWarningPerLevelPerWindow() {
        let warned = ContextAdvice.Advised(at: t0, level: 1)
        #expect(decide(160_000, last: warned, now: t0.addingTimeInterval(60)) == nil)
        #expect(decide(160_000, last: warned, now: t0.addingTimeInterval(2 * 3600 - 1)) == nil)
        #expect(decide(160_000, last: warned, now: t0.addingTimeInterval(2 * 3600)) == ContextAdvice.Advised(at: t0.addingTimeInterval(2 * 3600), level: 1))
        // the strong one goes up a level inside the window, then waits its own window
        let strong = decide(260_000, last: warned, now: t0.addingTimeInterval(60))
        #expect(strong == ContextAdvice.Advised(at: t0.addingTimeInterval(60), level: 2))
        #expect(decide(260_000, last: strong, now: t0.addingTimeInterval(120)) == nil)
        #expect(decide(160_000, last: strong, now: t0.addingTimeInterval(120)) == nil)
    }

    @Test func lineIsFixedNamesTheHandoffAndCarriesNoContent() {
        let w = ContextAdvice.line(tokens: 151_234, level: 1), s = ContextAdvice.line(tokens: 251_234, level: 2)
        #expect(w.contains("151 mil") && s.contains("251 mil") && w != s)
        for l in [w, s] { #expect(l.contains("leia a passagem de turno") && l.contains("collie work handoff") && !l.contains("\n") && !l.contains(secret)) }
        #expect(ContextAdvice.line(tokens: 999_000, level: 1).count - ContextAdvice.line(tokens: 150_000, level: 1).count == 0)
    }

    @Test func refusedPathsAreNotRead() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let real = try transcript([assistant(input: 300_000)])
        let link = projects.appendingPathComponent("p/l.jsonl").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        #expect(ContextAdvice.lastContext(link, projectsDir: projects) == nil)
        let fifo = projects.appendingPathComponent("p/f.jsonl").path
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(ContextAdvice.lastContext(fifo, projectsDir: projects) == nil)   // never opened: no hang
        let out = root.appendingPathComponent("elsewhere/x.jsonl")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (assistant(input: 300_000) + "\n").write(to: out, atomically: true, encoding: .utf8)
        #expect(ContextAdvice.lastContext(out.path, projectsDir: projects) == nil)
        #expect(decide(ContextAdvice.lastContext(link, projectsDir: projects)) == nil)
    }

    // MARK: handoff

    func work(tasks: Int, title: String = "Onda 10: contexto") -> Work {
        var w = Work(title: title, terminalId: UUID(), paddockId: UUID())
        w.tasks = (0..<tasks).map { i in
            var t = WorkTask(id: "t\(i)", title: "Tarefa \(i) " + String(repeating: "x", count: 60))
            if i % 2 == 0 {
                t.state = .done
                t.evidence = TaskEvidence(commits: ["abc\(i)def \(secret) assunto"], shortstat: "1 file changed", checkTail: secret, seconds: 3, attempt: 1)
            } else { t.state = .deferred; t.reason = "falhou o check" }
            return t
        }
        w.loop = WorkLoopState(state: .finished, tasks: w.tasks.map(\.id), startedAt: t0)
        return w
    }

    @Test func handoffTextHasTasksCommitsAndMemoryTitlesOnly() throws {
        let m = Handoff.Memory(id: UUID(), kind: .pitfall, title: "Não use ask para adiar")
        let s = Handoff.text(work(tasks: 2), memories: [m], nextWave: "Onda 11 (docs/r/onda11.md)")
        #expect(s.contains("Tarefa 0") && s.contains("Tarefa 1") && s.contains("adiada: falhou o check"))
        #expect(s.contains("abc0def") && !s.contains(secret), "\(s)")   // short shas only, never a subject nor the check's output
        #expect(s.contains("armadilha \(String(m.id.uuidString.prefix(8)).lowercased()): Não use ask para adiar"))
        #expect(s.contains("Onda 11 (docs/r/onda11.md)"))
        #expect(!Handoff.text(work(tasks: 1), memories: [], nextWave: nil).contains("Próxima onda"))
    }

    @Test func handoffStaysUnderFourKilobytes() {
        let many = (0..<40).map { _ in Handoff.Memory(id: UUID(), kind: .decision, title: String(repeating: "d", count: 150)) }
        let s = Handoff.text(work(tasks: 200), memories: many, nextWave: "Onda 11")
        #expect(s.utf8.count <= Handoff.maxBytes)
        #expect(s.contains("… e mais"))
    }

    @Test func nextWaveOnlyWhenTheRoadmapCitesIt() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("repo/docs/superpowers/roadmap/2026-x")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repo = root.appendingPathComponent("repo")
        #expect(Handoff.nextWave(title: "Onda 10: contexto", repoRoot: repo) == nil)
        try Data().write(to: dir.appendingPathComponent("onda11.md"))
        #expect(Handoff.nextWave(title: "Onda 10: contexto", repoRoot: repo) == "Onda 11 (docs/superpowers/roadmap/2026-x/onda11.md)")
        #expect(Handoff.nextWave(title: "Sem número", repoRoot: repo) == nil)
    }

    @Test func handoffFileIsWrittenAtTheLoopsEndOverwrittenAndPrivate() async throws {
        try await withDaemon { d, p in
            let (id, _) = try await spawn(d, p, "A")
            let a = Term(id: id, token: try await tokenOf(d, id))
            func call(_ cmd: String) async throws -> Response {
                try await send(p, Request(id: "w", terminalId: a.id, token: a.token, command: cmd, args: [:]), timeoutSeconds: 60)
            }
            // no file yet: says there is none
            let none = try await call("work.handoff")
            guard case .object(let o)? = none.result, case .string(let out)? = o["output"] else { Issue.record("\(none)"); return }
            #expect(out == Handoff.none)

            let started = try await send(p, Request(id: "w", terminalId: a.id, token: a.token, command: "work.start", args: ["title": .string("Primeiro")]))
            #expect(started.ok)
            let active = try await d.router.work.active(terminal: a.uuid)
            let w = try #require(active)
            try await d.router.work.update(w.id) { $0.loop = WorkLoopState(state: .finished, startedAt: Date()) }
            let pid = UUID()
            await d.router.loopEnded(w.id, starter: a.uuid, paddock: pid)
            let f = Handoff.file(root: p.root, paddock: pid)
            let first = try String(contentsOf: f, encoding: .utf8)
            #expect(first.contains("Primeiro"))
            let mode = try #require(try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? NSNumber)
            #expect(mode.intValue & 0o777 == 0o600)

            try await d.router.work.update(w.id) { $0.title = "Segundo" }
            await d.router.loopEnded(w.id, starter: a.uuid, paddock: pid)
            let second = try String(contentsOf: f, encoding: .utf8)
            #expect(second.contains("Segundo") && !second.contains("Primeiro"))
            let mode2 = try #require(try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? NSNumber)
            #expect(mode2.intValue & 0o777 == 0o600)
        }
    }

    @Test func workHandoffIsAnAgentCommand() throws {
        let spec = try #require(Commands.spec("work.handoff"))
        #expect(spec.mcpName == "work_handoff" && spec.exposedToMCP && !spec.shepherdOnly)
        #expect(try ArgvParser.parse(["work", "handoff"]).command == "work.handoff")
    }

    // MARK: memory stats

    @Test func statsKeepTheShepherdsContextPerSession() {
        func ev(_ s: String, _ n: Int, _ at: TimeInterval) -> MemoryEvent {
            var e = MemoryEvent(type: .pastorContext, session: s, tokens: n); e.at = t0.addingTimeInterval(at); return e
        }
        let r = MemoryObservability.compute(events: [ev("a", 120_000, 1), ev("a", 300_000, 2), ev("a", 90_000, 3), ev("b", 50_000, 4)],
                                            since: t0, now: t0.addingTimeInterval(10), records: [], verified: { _ in false },
                                            scores: [:], openDigest: [], curator: nil)
        #expect(r.cost.pastorContext == [MemoryObservability.PastorContext(session: "a", current: 90_000, max: 300_000),
                                         MemoryObservability.PastorContext(session: "b", current: 50_000, max: 50_000)])
    }
}
