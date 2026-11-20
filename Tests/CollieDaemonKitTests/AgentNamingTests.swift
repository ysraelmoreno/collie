import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// M3.8: the loop's agents are named after their work and task (`AgentNaming`), and nothing recognises them by name:
/// the terminal's id is on the attempt's job (`WorkJob.terminal`), and the start sweep goes by it.
@Suite struct AgentNamingTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let work: String, task: String, id: String, attempt: Int, lane: Int?, name: String
        var testDescription: String { name }
        init(_ work: String, _ task: String, _ id: String = "40d1a204-aaaa", _ attempt: Int = 1, _ lane: Int? = nil, _ name: String) {
            self.work = work; self.task = task; self.id = id; self.attempt = attempt; self.lane = lane; self.name = name
        }
    }

    static let table: [Row] = [
        Row("W", "Task a", "w-task-a-t1"),
        Row("Ação", "Tarefa única", "acao-tarefa-unica-t1"),                        // accents
        Row("Estado do LAÇO", "Não é órfão", "estado-do-laco-nao-e-orfao-t1"),
        Row("Foo/Bar_baz!!", "a  b--c (d)", "foo-bar-baz-a-b-c-d-t1"),              // symbols, runs of them
        Row("!!!", "###", "trabalho-40d1a204-t1"),                                  // only symbols: the fallbacks
        Row("", "", "trabalho-40d1a204-t1"),
        Row("   ", "\t", "///", 1, nil, "trabalho-tarefa-t1"),                      // and an id with nothing to give
        Row("日本語", "Ωμέγα", "a/../x", 2, nil, "trabalho-a-x-t2"),
        // long titles: 18 characters each, cut at a `-` when the cut would fall inside a word
        Row("Estado do laço máquina explícita", "abcdefghijklmnopqrstuvwxyz", "x", 3, nil, "estado-do-laco-abcdefghijklmnopqr-t3"),
        Row("aaaaaaaaaaaaaaaaaa bbb", "M3.8 Nomes coerentes para os agentes", "aaaaaaaaaaaaaaaaaa-m3-8-nomes-t1"),
        // lanes and attempts
        Row("W", "Task a", "a", 1, 2, "w-task-a-f2-t1"),
        Row("W", "Task a", "a", 3, nil, "w-task-a-t3"),
        Row("W", "Task a", "a", 3, 4, "w-task-a-f4-t3"),
        // a title is data: nothing of it starts the name with `-`, `.` or `/`, climbs a folder or breaks the line
        Row("-rf", "--force", "rf-force-t1"),
        Row(".hidden", "/etc/passwd", "hidden-etc-passwd-t1"),
        Row("../x", "../../y z", "x-y-z-t1"),
        Row("a\nb", "c\r\nd\u{0}e", "a-b-c-d-e-t1"),
        Row("\u{1B}[31mred", "tab\there", "31mred-tab-here-t1"),
        Row("$(rm -rf ~)", "`id`; echo", "rm-rf-id-echo-t1"),
    ]

    @Test(arguments: table) func theNameComesFromTheTitles(_ r: Row) {
        #expect(AgentNaming.name(work: r.work, task: r.task, taskId: r.id, attempt: r.attempt, lane: r.lane) == r.name)
    }

    static func safe(_ name: String) -> Bool {
        name.count <= AgentNaming.max && name.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    @Test func everyNameIsSafeAndFits() {
        let nasty = ["", "-", "--", ".", "..", "/", "../x", "a/b", " a b ", "a\nb", "\u{7}", "-x", ".x", "/x", "Ação", "ÀÉÎÕÜ ç ñ",
                     String(repeating: "x", count: 200), String(repeating: "ab-", count: 80), String(repeating: "é ", count: 90), "loop-a-1"]
        for w in nasty {
            for t in nasty {
                for (n, lane) in [(1, Int?.none), (3, 4), (1_000_000, 99_999), (-5, -1)] {
                    let name = AgentNaming.name(work: w, task: t, taskId: t, attempt: n, lane: lane)
                    #expect(Self.safe(name), "\(name.debugDescription) from \(w.debugDescription) / \(t.debugDescription)")
                    let taken = Set([name] + (2...9).map { "\(name)-\($0)" })
                    let other = AgentNaming.unique(name, taskId: w, taken: taken)
                    #expect(Self.safe(other) && other != name, "\(other.debugDescription)")
                }
            }
        }
    }

    @Test func theLoopPrefixIsGone() {
        #expect(Self.table.allSatisfy { !$0.name.hasPrefix("loop-") })
        #expect(AgentNaming.name(work: "Loop", task: "x", taskId: "a", attempt: 1, lane: nil) == "loop-x-t1")   // only as a title's own word
        // the machine's own default (its tests build a state with no name): no prefix either
        #expect(AttemptMachine.State(task: "a", n: 1, tries: 3, hasGate: false, before: "c0").name == "trabalho-a-t1")
        #expect(AttemptMachine.State(task: "a", n: 1, tries: 3, hasGate: false, before: "c0", name: "w-x-t1").name == "w-x-t1")
    }

    @Test func aNameAlreadyTakenGetsANumberThenTheTasksId() {
        let id = "40d1a204-9999"
        #expect(AgentNaming.unique("w-task-a-t1", taskId: id, taken: []) == "w-task-a-t1")
        #expect(AgentNaming.unique("w-task-a-t1", taskId: id, taken: ["other"]) == "w-task-a-t1")
        #expect(AgentNaming.unique("w-task-a-t1", taskId: id, taken: ["w-task-a-t1"]) == "w-task-a-t1-2")
        #expect(AgentNaming.unique("w-task-a-t1", taskId: id, taken: ["W-Task-A-T1"]) == "w-task-a-t1-2")   // as `summon` compares
        #expect(AgentNaming.unique("w-task-a-t1", taskId: id, taken: ["w-task-a-t1", "w-task-a-t1-2", "w-task-a-t1-3"]) == "w-task-a-t1-4")
        let all = Set(["w-task-a-t1"] + (2...9).map { "w-task-a-t1-\($0)" })
        #expect(AgentNaming.unique("w-task-a-t1", taskId: id, taken: all) == "w-task-a-t1-40d1a204")
        #expect(AgentNaming.unique("w-task-a-t1", taskId: "../..", taken: all) == "w-task-a-t1-tarefa")
    }

    @Test func aLongNameStillFitsWhenItCollides() {
        let name = AgentNaming.name(work: String(repeating: "w", count: 30), task: String(repeating: "t", count: 30), taskId: "x", attempt: 3, lane: 4)
        #expect(name == String(repeating: "w", count: 18) + "-" + String(repeating: "t", count: 18) + "-f4-t3" && name.count == 43)
        let all = Set([name] + (2...9).map { "\(name)-\($0)" })
        let other = AgentNaming.unique(name, taskId: "40d1a204-9999", taken: all)
        // the titles give way: the lane, the attempt and the id stay whole
        #expect(other.count == AgentNaming.max && other.hasSuffix("-f4-t3-40d1a204") && Self.safe(other), "\(other)")
    }

    // MARK: the engine (a fake host)

    private final class Box: @unchecked Sendable { var work: Work? }

    @Test func theSummonGetsTheNewNameAndTheSweepFindsTheOrphanByItsId() async throws {
        let r = try await LoopRig([WorkTask(id: "40d1a204", title: "M3.8 Nomes coerentes", check: "test -f done.txt")]); defer { r.cleanup() }
        try await r.store.update(r.work) { $0.title = "Ação: laço!" }
        let name = "acao-laco-m3-8-nomes-t1", box = Box(), store = r.store, id = r.work
        // mid-turn: what a daemon that fell right now would leave on disk
        await r.host.set(name, LoopScript(act: { d in box.work = try await store.get(id); try await commit("done.txt", "ok\n", in: d) }))
        let end = await r.run()
        #expect(end == .finished)
        let summoned = await r.host.summoned, dismissed = await r.host.dismissed
        #expect(summoned == [name] && dismissed == [name])
        let w = try await r.get()
        #expect(w.tasks[0].state == .done && w.jobs.map(\.id) == [name] && w.jobs[0].kind == .loop)
        // the journal cites the name
        #expect(w.loop?.events?.first { $0.kind == .agentSummoned }?.detail == name)

        // the orphan: the loop still running, the job running with its terminal's id
        var fallen = try #require(box.work)
        let job = try #require(fallen.jobs.first)
        let terminal = try #require(job.terminal)
        #expect(fallen.loop?.state == .running && job.id == name && job.state == .running && !name.hasPrefix("loop-"))
        func term(_ id: UUID, _ name: String, paddock: UUID?) -> TerminalRecord {
            TerminalRecord(id: id, name: name, preset: .shell, command: nil, cwd: "/tmp", isShepherd: false, paddockId: paddock)
        }
        // the agent (renamed since, even), another terminal that only has its name, one of another paddock, the Shepherd
        let agent = term(terminal, "renamed-by-the-owner", paddock: fallen.paddockId)
        let terminals = [agent, term(UUID(), name, paddock: fallen.paddockId), term(UUID(), "loop-a-1", paddock: fallen.paddockId),
                         term(UUID(), "other", paddock: UUID()), term(fallen.terminalId, "Rex", paddock: fallen.paddockId)]
        #expect(CommandRouter.loopAgents(of: fallen, in: terminals) == [agent])
        CommandRouter.sweepLeftRunning(&fallen, now: Date(timeIntervalSince1970: 9))
        #expect(fallen.loop?.state == .stopped && fallen.jobs[0].state == .gone && fallen.tasks[0].state == .open)
    }

    @Test func anAttemptNeverTakesALiveTerminalsName() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "test -f done.txt")]); defer { r.cleanup() }
        await r.host.setTaken(["w-task-a-t1", "Rex"])
        await r.host.set("w-task-a-t1-2", LoopScript(act: { try await commit("done.txt", "ok\n", in: $0) }))
        let end = await r.run()
        #expect(end == .finished)
        let summoned = await r.host.summoned
        #expect(summoned == ["w-task-a-t1-2"])
        let w = try await r.get()
        #expect(w.tasks[0].state == .done && w.jobs.map(\.id) == ["w-task-a-t1-2"] && w.jobs[0].state == .finished && w.jobs[0].terminal != nil)
    }

    @Test func aFailedAttemptsNoteAndTheStatusCiteTheName() async throws {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "false")], tries: 1); defer { r.cleanup() }
        let box = Box(), store = r.store, id = r.work
        await r.host.set("w-task-a-t1", LoopScript(act: { d in box.work = try await store.get(id); try await commit("x.txt", "x\n", in: d) }))
        _ = await r.run()
        let during = try #require(box.work), w = try await r.get()
        // `work status`, with the agent working: the loop's line and the running job say which terminal
        #expect(WorkStatusText.loopLine(during) == "em laço: Task a (tentativa 1/1) · agente trabalhando · terminal w-task-a-t1")
        let running = WorkStatusText.answer(.whatIsRunning, works: [during], names: [:], badges: [:], now: Date())
        #expect(running.contains("tentativa do laço w-task-a-t1: Task a"), "\(running)")
        // the failure's note (what the next attempt's prompt carries) names the agent that failed
        let note = try #require(w.notes.first { $0.text.hasPrefix("[loop a] Task a, tentativa 1/1:") })
        #expect(note.text.contains("check failed (exit 1) (agente w-task-a-t1)"), "\(note.text)")
        #expect(WorkStatusText.loopLine(w)?.contains("terminal") == false)   // ended: no agent to name
    }

    // MARK: the state's mark

    @Test func aJobWithNoTerminalOnRecordIsStillFoundByItsName() {
        let paddock = UUID()
        func term(_ name: String, _ id: UUID = UUID()) -> TerminalRecord {
            TerminalRecord(id: id, name: name, preset: .shell, command: nil, cwd: "/tmp", isShepherd: false, paddockId: paddock)
        }
        let known = UUID()
        var w = Work(title: "W", terminalId: UUID(), paddockId: paddock, jobs: [
            WorkJob(id: "loop-a-1", kind: .loop, label: "A"),                       // a work a daemon before M3.8 wrote
            WorkJob(id: "w-b-t1", kind: .loop, label: "B", terminal: known),
            WorkJob(id: "sub", kind: .subagent, label: "x"), WorkJob(id: "sh", kind: .shell, label: "y", terminal: UUID())])
        w.loop = WorkLoopState(state: .running, task: "a", attempt: 1)
        let old = term("loop-a-1"), new = term("anything", known)
        let terminals = [old, new, term("w-b-t1"), term("sub"), term("sh"), term("loop-zz-9")]
        #expect(CommandRouter.loopAgents(of: w, in: terminals) == [old, new])
        // another paddock's terminals are never the loop's
        var elsewhere = w; elsewhere.paddockId = UUID()
        #expect(CommandRouter.loopAgents(of: elsewhere, in: terminals).isEmpty)
    }

    @Test func theJobsTerminalIsOptionalAndTolerant() throws {
        let e = JSONEncoder(), d = JSONDecoder()
        e.dateEncodingStrategy = .iso8601; d.dateDecodingStrategy = .iso8601
        let t = UUID(), job = WorkJob(id: "w-a-t1", kind: .loop, label: "A", startedAt: Date(timeIntervalSince1970: 60), terminal: t)
        #expect(try d.decode(WorkJob.self, from: e.encode(job)) == job)
        // a file from before the field, and one whose field this daemon cannot read: the job still decodes
        let old = #"{"id":"loop-a-1","kind":"loop","label":"A","state":"running","startedAt":"2026-11-20T10:00:00Z"}"#
        let bad = #"{"id":"w-a-t1","kind":"loop","label":"A","state":"running","startedAt":"2026-11-20T10:00:00Z","terminal":42}"#
        let o = try d.decode(WorkJob.self, from: Data(old.utf8)), b = try d.decode(WorkJob.self, from: Data(bad.utf8))
        #expect(o.id == "loop-a-1" && o.terminal == nil && o.endedAt == nil && b.id == "w-a-t1" && b.terminal == nil)
        // a job with no terminal writes no key
        let plain = String(decoding: try e.encode(WorkJob(id: "x", kind: .shell, label: "y")), as: UTF8.self)
        #expect(!plain.contains("terminal"))
    }
}
