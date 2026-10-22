import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

@Suite struct WorkSummaryTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func task(_ t: String, _ s: TaskState, _ reason: String? = nil, at: Double = 0) -> WorkTask {
        WorkTask(id: t, title: t, state: s, reason: reason, updatedAt: Date(timeIntervalSince1970: at))
    }
    func make(_ w: Work) -> WorkSummary { WorkSummary.make(w, terminalAlive: true, now: now) }

    @Test func sectionsFromStates() {
        let w = Work(title: "Login", terminalId: UUID(),
                     tasks: [task("T-done", .done), task("T-later", .deferred, "espera a API"), task("T-drop", .abandoned, "não precisa"),
                             task("T-drop2", .abandoned), task("T-open", .open), task("T-prog", .inProgress)],
                     jobs: [WorkJob(id: "1", kind: .shell, label: "build", state: .gone), WorkJob(id: "2", kind: .subagent, label: "review", state: .unknown),
                            WorkJob(id: "3", kind: .shell, label: "lint", state: .finished)],
                     notes: [WorkNote(text: "papo"), WorkNote(text: "usar JWT", decision: true)],
                     commits: ["abc123 add form", "def456 add api"])
        let s = make(w)
        #expect(s.done == ["T-done", "abc123 add form", "def456 add api"])
        #expect(s.later == ["T-later — espera a API", "Decisão: usar JWT"])
        #expect(s.notDone == ["T-open", "T-prog", "T-drop — abandonada: não precisa", "T-drop2 — abandonada", "build — sumiu", "review — sem sinal"])
        #expect(!(s.done + s.later + s.notDone).contains { $0.contains("lint") })
    }

    @Test func activeSaysEmAbertoClosedSaysNaoFeito() {
        var w = Work(title: "W", terminalId: UUID(), tasks: [task("x", .open)])
        #expect(make(w).markdown().contains("**Em aberto**") && !make(w).markdown().contains("**Não feito**"))
        w.closedAt = now
        #expect(make(w).markdown().contains("**Não feito**") && !make(w).markdown().contains("**Em aberto**"))
        #expect(make(w).markdown().hasPrefix("## W\n\n**Não feito**\n- x"))
    }

    @Test func mergeIsDone() {
        let w = Work(title: "W", terminalId: UUID(), closedAt: now, closedBy: "merge")
        #expect(make(w).done == ["Mergeado"] && make(w).closedBy == "merge")
    }

    @Test func stoppedAt() {
        var w = Work(title: "W", terminalId: UUID(), tasks: [task("old", .inProgress, at: 1), task("new", .inProgress, at: 9), task("o", .open, at: 99)],
                     notes: [WorkNote(text: "primeira"), WorkNote(text: "última")])
        #expect(make(w).stoppedAt == "new")
        w.tasks = [task("o", .open)]
        #expect(make(w).stoppedAt == "última")
        w.notes = []
        #expect(make(w).stoppedAt == nil && !make(w).markdown().contains("Onde parou"))
    }

    @Test func summaryIsBounded() {
        let w = Work(title: "Grande", terminalId: UUID(),
                     tasks: (0..<500).map { task(String(repeating: "t", count: 100) + "\($0)", .open) }
                        + (0..<100).map { task("d\($0)", .deferred, String(repeating: "r", count: 100)) },
                     jobs: (0..<200).map { WorkJob(id: "\($0)", kind: .shell, label: "job\($0)", state: .gone) },
                     commits: (0..<200).map { "abc\($0) " + String(repeating: "c", count: 150) })
        let md = make(w).markdown()
        #expect(md.count <= 6_000)
        #expect(md.components(separatedBy: "… e mais").count - 1 == 3, "\(md)")
    }

    @Test func agentTextIsOneCleanLine() {
        let w = Work(title: "T\nitle\u{202E}", terminalId: UUID(), tasks: [task("a\r\nb\u{200B}c\td", .open, "why\n- fake")],
                     notes: [WorkNote(text: "x\ny", decision: true)], commits: ["abc\u{0007}1 sub\nject"])
        let s = make(w)
        #expect(s.title == "T itle" && s.notDone == ["a  bc d"] && s.later == ["Decisão: x y"] && s.done == ["abc 1 sub ject"])
        let md = s.markdown()
        #expect(!md.unicodeScalars.contains { $0.properties.generalCategory == .format })
        #expect(md.split(separator: "\n").allSatisfy { $0.isEmpty || $0.hasPrefix("- ") || $0.hasPrefix("**") || $0.hasPrefix("## ") })
        let d = make(Work(title: "t", terminalId: UUID(), tasks: [task("x", .deferred, "a\n- b")])).later
        #expect(d == ["x — a - b"])
    }

    @Test func agentTextIsNeverMarkdown() throws {
        let w = Work(title: "[t](http://a)", terminalId: UUID(), tasks: [task("[Aprovar](https://evil.example)", .open), task("**b**", .open)],
                     jobs: [WorkJob(id: "1", kind: .shell, label: "_j_ <x>", state: .gone)], notes: [WorkNote(text: "`c` ~s~ !", decision: true)],
                     commits: ["abc [x](http://a)", "www.evil.com/x a@b.com"])
        let s = make(w)
        for md in [s.markdown(), s.markdown(boldTitle: true)] {
            let a = try AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            #expect(!a.runs.contains { $0.link != nil }, "\(md)")
            let text = String(a.characters)
            for lit in ["[Aprovar](https://evil.example)", "**b**", "[t](http://a)", "_j_ <x>", "`c` ~s~ !", "abc [x](http://a)", "www.evil.com/x a@\u{200B}b.com"] {
                #expect(text.contains(lit), "\(lit) in \(text)")
            }
        }
    }

    @Test func summaryPhrasesAreExact() {
        for t in ["resumo", "Resumo?", "o que foi feito", "O que foi feito?", "resumo agora", "resumo por favor"] {
            #expect(StatusQuestion.match(t) == .summary, "\(t)")
        }
        for t in ["resumo do bug X, depois corrige", "resume o arquivo e apaga", "resume", "o que foi feito no login? corrige"] {
            #expect(StatusQuestion.match(t) == nil, "\(t)")
        }
    }
}

// MARK: daemon

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }
private func spawn(_ d: Daemon, _ p: Paths, _ name: String, maestro: Bool = false) async throws -> Term {
    let args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string("/tmp"), "maestro": .bool(maestro)]
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func cmd(_ d: Daemon, _ p: Paths, _ t: Term?, _ c: String, _ a: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "w", terminalId: t?.id, token: t?.token ?? d.adminToken, command: c, args: a), timeoutSeconds: 60)
}

extension WorkSummaryTests {
    @Test func summaryCommandFollowsCords() async throws {
        try await withDaemon { d, p in
            let a = try await spawn(d, p, "A"), b = try await spawn(d, p, "B"), m = try await spawn(d, p, "M", maestro: true)
            #expect(try await cmd(d, p, nil, "admin.connect", ["a": .string("M"), "b": .string("A")]).ok)
            let s = try await cmd(d, p, a, "work.start", ["title": .string("Feature A")])
            guard case .object(let o)? = s.result, case .string(let id)? = o["id"] else { Issue.record("\(s)"); return }
            #expect(try await cmd(d, p, a, "work.task.add", ["title": .string("Write tests")]).ok)
            // B has no cord: A looks exactly like a terminal that does not exist
            let hidden = try await cmd(d, p, b, "work.summary", ["terminal": .string("A")])
            let missing = try await cmd(d, p, b, "work.summary", ["terminal": .string("Nobody")])
            #expect(hidden.error?.code == .notFound && hidden.error?.message == "Terminal 'A' not found")
            #expect(missing.error?.message == "Terminal 'Nobody' not found")
            #expect(try await cmd(d, p, b, "work.summary", ["id": .string(id)]).error?.code == .notFound)
            #expect(try await cmd(d, p, b, "work.summary").error?.code == .notFound)   // B has no active work
            // the caller itself, the Maestro through the cord, and the app
            for (who, args) in [(a, [:]), (m, ["terminal": JSONValue.string("A")]), (m, ["id": .string(id)]), (nil, ["id": .string(id)])] as [(Term?, [String: JSONValue])] {
                guard case .object(let r)? = try await cmd(d, p, who, "work.summary", args).result, case .string(let md)? = r["markdown"],
                      case .object(let sum)? = r["summary"] else { Issue.record("summary \(args)"); return }
                #expect(md.hasPrefix("## Feature A") && md.contains("**Em aberto**\n- Write tests") && r["natural"] == .bool(false))
                #expect(sum["title"] == .string("Feature A") && sum["active"] == .bool(true))
            }
            #expect(try await cmd(d, p, m, "work.summary", ["terminal": .string("B")]).error?.message == "Terminal 'B' not found")
            #expect(try await cmd(d, p, nil, "work.summary").error?.code == .invalidArgs)   // the app names a terminal
        }
    }

    @Test func chatSummaryQuestion() async throws {
        try await withDaemon { d, p in
            let a = try await spawn(d, p, "A")
            let s = try await cmd(d, p, a, "work.start", ["title": .string("Feature A")])
            guard case .object(let o)? = s.result, case .string(let id)? = o["id"] else { Issue.record("\(s)"); return }
            #expect(try await cmd(d, p, a, "work.task.add", ["title": .string("Write tests")]).ok)
            func ask(_ work: String?) async throws -> String? {
                var args: [String: JSONValue] = ["text": .string("Resumo")]
                if let work { args["work"] = .string(work) }
                guard case .object(let r)? = try await cmd(d, p, nil, "work.chat.send", args).result, case .string(let mid)? = r["messageId"] else { return nil }
                return try await d.router.chat.page(before: nil, limit: 200).first { $0.replyTo?.uuidString.lowercased() == mid }?.text
            }
            let with = try await ask(id)
            #expect(with?.hasPrefix("**Feature A**") == true && with?.contains("- Write tests") == true, "\(with ?? "nil")")
            #expect(try await ask(nil) == "Escolha um trabalho para ver o resumo.")
        }
    }
}
