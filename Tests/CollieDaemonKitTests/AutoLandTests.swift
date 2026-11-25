import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// A4, `work run --auto-land`: the refusals, each land condition failing with its own stop and no land, the land by
/// merge only, and a mute review that never counts as an approval. Hosts are fakes (`LoopFakeHost`): no terminal, no
/// sandbox, no network git.
@Suite struct AutoLandTests {
    private typealias Stop = WorkLoopState.Stop

    /// A repo with one persona and a spec at the base, a done-able task, the review on and the auto-land on, in a
    /// paddock marked a factory's.
    private static func rig(gate: String = "true", ci: String = "true", review: Bool = true, max: Int? = nil, perDay: Int? = nil) async throws -> LoopRig {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "true")], tries: 1)
        let p = r.repo.appendingPathComponent(CommandRouter.personasDir)
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        try "---\nname: correcao\nmodel: sonnet\npaths: [\"**\"]\n---\nCorpo\n".write(to: p.appendingPathComponent("correcao.md"), atomically: true, encoding: .utf8)
        try await commit("spec.md", "SPEC\n", in: r.repo)
        let spec = r.repo.appendingPathComponent("spec.md").path
        try await r.store.update(r.work) {
            $0.tasks[0].spec = spec
            $0.loop?.review = review ? true : nil
            $0.loop?.autoLand = WorkLoopState.AutoLand(gate: gate, ci: ci, timeout: 60, max: max, perDay: perDay)
        }
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("a.swift", "let a = 1\n", in: $0) }))
        await r.host.setFactory(true)
        return r
    }

    private static func expectStopped(_ r: LoopRig, _ code: Stop.Code, _ at: SourceLocation = #_sourceLocation) async throws {
        #expect(await r.run() == .stopped, sourceLocation: at)
        let w = try await r.get()
        // C5d: a discard that dropped the attempt's commits reopens its task (its note); one that kept them leaves it done
        let reopened = w.notes.contains { $0.text.hasPrefix("[reopen]") }
        #expect(w.tasks[0].state == (reopened ? .open : .done), "\(w.notes.map(\.text))", sourceLocation: at)
        #expect(w.loop?.stopReason?.code == code, "\(String(describing: w.loop?.stopReason))", sourceLocation: at)
        #expect(await r.host.lands.isEmpty, sourceLocation: at)
        #expect(w.loop?.autoLand?.before == nil && w.loop?.autoLand?.after == nil, sourceLocation: at)
        let notices = await r.host.ownerNotices
        #expect(notices.count == 1 && notices[0].contains(Stop(code).label.prefix(20)) && notices[0].contains("collie work status"), "\(notices)", sourceLocation: at)
    }

    @Test func landsOnceByMergeAndRecordsBothCommits() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(await r.host.lands == [.merge])
        #expect(w.loop?.stopReason?.code == .landed && w.tasks[0].reviewClean == true)
        #expect(w.loop?.autoLand?.before == LoopFakeHost.landedBefore && w.loop?.autoLand?.after == LoopFakeHost.landedAfter)
        let note = try #require(w.notes.first { $0.text.hasPrefix("[loop] auto-land: integrado") })
        #expect(note.text.contains("git reset --hard \(LoopFakeHost.landedBefore)") && note.text.contains(LoopFakeHost.landedAfter) && note.decision)
        #expect(w.loop?.events?.contains { $0.kind == .landed } == true)
        // the gate, then the CI, both after the task's own check
        #expect(await r.host.commands.suffix(2) == ["true", "true"])
        #expect(await r.host.ownerNotices.count == 1)
    }

    @Test func notAFactoryAnyMoreStops() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        await r.host.setFactory(false)
        try await Self.expectStopped(r, .landNotFactory)
    }

    @Test func aRedGateStops() async throws {
        let r = try await Self.rig(gate: "test ! -f a.swift"); defer { r.cleanup() }
        try await Self.expectStopped(r, .landGateRed)
    }

    @Test func aRedCIStops() async throws {
        let r = try await Self.rig(ci: "echo quebrou; exit 3"); defer { r.cleanup() }
        try await Self.expectStopped(r, .landCiRed)
        #expect(try await r.get().notes.contains { $0.text.contains("CI local vermelho") && $0.text.contains("exit 3") })
    }

    @Test func aDirtyTreeStops() async throws {
        let r = try await Self.rig(ci: "echo x > sobra.txt"); defer { r.cleanup() }
        try await Self.expectStopped(r, .landDirty)
    }

    @Test func anotherAgentBusyStops() async throws {
        let r = try await Self.rig(ci: "echo ci"); defer { r.cleanup() }
        let host = r.host
        await r.host.setProbe { c in if c == "echo ci" { await host.setBusy("intruso") } }
        try await Self.expectStopped(r, .landDirty)
        #expect(try await r.get().loop?.stopReason?.detail == "intruso")
    }

    /// A `work stop` sent during the CI (which may take up to its timeout) wins: nothing lands.
    @Test func aStopDuringTheCILandsNothing() async throws {
        let r = try await Self.rig(ci: "echo ci"); defer { r.cleanup() }
        let loop = r.loop, id = r.work
        await r.host.setProbe { c in if c == "echo ci" { await loop.stop(work: id) } }
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .requested && w.loop?.autoLand?.after == nil)
        #expect(await r.host.lands.isEmpty)
    }

    /// The work closed during the CI: nothing lands.
    @Test func theWorkClosedDuringTheCILandsNothing() async throws {
        let r = try await Self.rig(ci: "echo ci"); defer { r.cleanup() }
        let store = r.store, id = r.work
        await r.host.setProbe { c in if c == "echo ci" { try? await store.update(id) { $0.closedAt = Date() } } }
        _ = await r.run()
        #expect(try await r.get().loop?.autoLand?.after == nil)
        #expect(await r.host.lands.isEmpty)
    }

    @Test func aMuteReviewIsNoApproval() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        await r.host.setReviewAnswer("correcao", nil)
        try await Self.expectStopped(r, .landReviewVeto)
        #expect(try await r.get().tasks[0].reviewClean == nil)
    }

    @Test func noReviewInTheLastAttemptIsNoApproval() async throws {
        let r = try await Self.rig(review: false); defer { r.cleanup() }
        try await Self.expectStopped(r, .landReviewVeto)
    }

    @Test func aFailedLandStopsAsConflict() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        await r.host.setLandError(ProtocolError(code: .invalidArgs, message: "land conflicts: a.swift"))
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .landConflict && w.loop?.stopReason?.detail?.contains("a.swift") == true)
        #expect(await r.host.lands == [.merge] && w.loop?.autoLand?.after == nil)
    }

    @Test func aTaskNotDoneLandsNothing() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        try await r.store.update(r.work) { $0.tasks[0].check = "false" }
        #expect(await r.run() == .stopped)   // C5a: its own stop, never a finish
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred && w.loop?.stopReason?.code == .landTasksNotDone && w.loop?.autoLand?.after == nil)
        let notices = await r.host.ownerNotices
        #expect(await r.host.lands.isEmpty && notices.count == 1)
    }

    @Test func refusals() throws {
        let gated = ProjectWorkConfig(gate: "scripts/ci/lint.sh")
        func refused(_ factory: Bool, _ c: ProjectWorkConfig?, _ review: Bool, _ noReview: Bool, _ text: String) {
            #expect(throws: ProtocolError.self) { try CommandRouter.loopAutoLand(factory: factory, config: c, review: review, noReview: noReview) }
            do { _ = try CommandRouter.loopAutoLand(factory: factory, config: c, review: review, noReview: noReview) } catch {
                #expect(error.message.contains(text), "\(error.message)")
            }
        }
        refused(false, gated, true, false, "fábrica")
        refused(true, nil, true, false, "'gate'")
        refused(true, ProjectWorkConfig(), true, false, "'gate'")
        refused(true, gated, false, false, "exige revisão")
        refused(true, gated, true, true, "exige revisão")
        let ok = try CommandRouter.loopAutoLand(factory: true, config: gated, review: true, noReview: false)
        #expect(ok == WorkLoopState.AutoLand(gate: "scripts/ci/lint.sh", ci: "scripts/ci/run-tests.sh", timeout: 1800))
    }

    /// C2: only `.done` counts as finished for the land: a task dropped (`abandoned`) lands nothing.
    @Test func anAbandonedTaskLandsNothing() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        try await r.store.update(r.work) {
            $0.tasks.append(WorkTask(id: "b", title: "Task b", state: .abandoned, check: "true"))
            $0.loop?.tasks = ["a", "b"]
        }
        #expect(await r.run() == .stopped)   // C5a: a stop of its own, nothing integrated
        let w = try await r.get()
        // C5d: a's commit is discarded with the land, so a is open again
        #expect(w.tasks[0].state == .open && w.loop?.autoLand?.after == nil && w.loop?.stopReason?.code == .landTasksNotDone)
        #expect(w.loop?.stopReason?.detail == "Task b", "\(String(describing: w.loop?.stopReason))")
        #expect(await r.host.lands.isEmpty)
        #expect(w.notes.contains { $0.text.contains("1 tarefa(s) não terminaram feitas") }, "\(w.notes.map(\.text))")
    }

    /// C2: a failure after the merge (the save) is no conflict: both commits recorded, the land counted, and a note that
    /// the base changed.
    @Test func aFailureAfterTheMergeIsNoConflict() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        await r.host.setLandLate("a gravação do cercado falhou")
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .landed, "\(String(describing: w.loop?.stopReason))")
        #expect(w.loop?.autoLand?.before == LoopFakeHost.landedBefore && w.loop?.autoLand?.after == LoopFakeHost.landedAfter)
        #expect(w.notes.contains { $0.text.contains("a base MUDOU") && $0.text.contains("a gravação do cercado falhou") }, "\(w.notes.map(\.text))")
        #expect(w.loop?.stopReason?.detail?.contains("depois do merge falhou") == true)
    }

    /// C2: the land by merge always makes a merge commit when the paddock has commits the base lacks, a fast-forward
    /// included (`--no-ff`): two parents, the first one the base before.
    @Test func theMergeLandAlwaysMakesAMergeCommit() async throws {
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        var k = try await PaddockManager.create(name: "ff", repoRoot: repo, createdBy: nil)
        try await commit("novo.swift", "let n = 1\n", in: URL(fileURLWithPath: k.path))   // the base could fast-forward
        let res = try await PaddockManager.land(&k, mode: .merge, message: "land ff")
        let parents = try await GitRunner.run(["rev-list", "--parents", "-n", "1", "HEAD"], in: repo).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
        #expect(parents.count == 3 && parents[0] == res.commit && parents[1] == res.before, "\(parents)")
        let tip = try await GitRunner.run(["rev-parse", k.branch], in: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(res.commit != tip && parents[2] == tip)
    }

    @Test func theProfileSetsTheCIAndItsTimeout() throws {
        let f: [String: Any] = ["version": 1, "autoland": ["ci": "make ci", "timeoutSeconds": 600]]
        let p = try FactoryProfile.parse(f).get()
        #expect(p.autolandCI == "make ci" && p.autolandTimeout == 600)
        if case .failure(.unknownField(let k)) = FactoryProfile.parse(["version": 1, "autoland": ["push": true]]) { #expect(k == "factory.autoland.push") }
        else { Issue.record("an unknown autoland key must be refused") }
    }

    @Test func theStateKeepsItsAutoLandAndOldOnesDecode() throws {
        var l = WorkLoopState(tasks: ["a"]); l.autoLand = .init(gate: "g"); l.autoLand?.before = "x"
        #expect(try JSONDecoder().decode(WorkLoopState.self, from: JSONEncoder().encode(l)).autoLand == l.autoLand)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(l)) as? [String: Any])
        json["autoLand"] = "lixo"
        #expect(try JSONDecoder().decode(WorkLoopState.self, from: JSONSerialization.data(withJSONObject: json)).autoLand == nil)
    }

    // MARK: A5, the next work of the queue after the land, with caps

    /// A second work in `r`'s paddock (unless `paddock` says another), one task `id`: `queued` the owner approved it on
    /// its card (a `queued` loop with its own auto-land); else `loop` as given (nil: none, never approved).
    private static func another(_ r: LoopRig, _ id: String, gate: String = "true", queued: Bool = true, loop: WorkLoopState? = nil,
                                paddock: UUID? = nil) async throws -> UUID {
        let pid = try await r.get().paddockId
        let w = try await r.store.start(title: "W", terminal: UUID(), paddockId: paddock ?? pid, branch: "main")
        let spec = r.repo.appendingPathComponent("spec.md").path
        try await r.store.update(w.id) {
            $0.tasks = [WorkTask(id: id, title: "Task \(id)", spec: spec, check: "true")]
            if queued {
                var l = WorkLoopState(tries: 1, timeout: 60, tasks: [id], review: true)
                l.autoLand = WorkLoopState.AutoLand(gate: gate, ci: "true", timeout: 60); l.state = .queued
                $0.loop = l
            } else { $0.loop = loop }
        }
        await r.host.set("w-task-\(id)-t1", LoopScript(act: { try await commit("\(id).swift", "let \(id) = 1\n", in: $0) }))
        return w.id
    }

    /// The chain `r.work`'s land picked: still `queued` (the engine never activates), then made `running` as the router
    /// does once the next engine is registered.
    private static func activated(_ r: LoopRig, after id: UUID, _ at: SourceLocation = #_sourceLocation) async throws -> WorkLoop.Chain {
        let c = try #require(await r.loop.takeNext(after: id), sourceLocation: at)
        #expect(try await r.store.get(c.next)?.loop?.state == .queued, "the engine only picks", sourceLocation: at)
        try await r.store.update(c.next) { #expect(WorkLoop.activate(&$0, c, at: r.host.now())) }
        return c
    }

    @Test func maxOneLandsOneAndStopsWithTheQueueWaiting() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        let b = try await Self.another(r, "b")
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .maxReached && w.loop?.stopReason?.detail?.contains("1 na fila") == true)
        #expect(w.loop?.stopReason?.finishes == true && w.notes.last?.text.hasPrefix("[loop] laço terminou") == true)
        #expect(!(w.loop?.events ?? []).contains { $0.kind == .stopped }, "a chain's end is no stop")
        #expect(await r.host.lands == [.merge])
        #expect(await r.loop.takeNext(after: r.work) == nil)
        #expect(try await r.store.get(b)?.loop?.state == .queued)
        let notices = await r.host.ownerNotices
        #expect(notices.count == 1 && notices[0].contains("integrou 1 trabalho (teto do auto-land"), "\(notices)")
    }

    /// N=1 with nothing approved waiting: the land was the whole execution, `landed` (never `queueEmpty`).
    @Test func maxOneWithAnEmptyQueueIsLanded() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        #expect(await r.run() == .finished)
        #expect(try await r.get().loop?.stopReason?.code == .landed)
        #expect(await r.loop.takeNext(after: r.work) == nil)
    }

    @Test func maxTwoLandsTwoAndCarriesTheBudget() async throws {
        let r = try await Self.rig(max: 2); defer { r.cleanup() }
        try await r.store.update(r.work) { $0.loop?.budget = 1000 }
        let b = try await Self.another(r, "b")
        #expect(await r.run() == .finished)
        #expect(try await r.get().loop?.stopReason?.code == .landed)
        #expect(await r.host.ownerNotices.isEmpty, "the chain goes on: its last work tells")
        let spent = try await r.get().loop?.spent ?? 0
        let c = try await Self.activated(r, after: r.work)
        #expect(c.next == b && c.chained == 1 && c.max == 2 && c.budget == 1000 - spent)
        let next = try #require(try await r.store.get(b)?.loop)
        #expect(next.state == .running && next.autoLand?.chained == 1 && next.autoLand?.max == 2 && next.budget == 1000 - spent)
        #expect(await r.loop.run(work: b, dir: r.repo) == .finished)
        let wb = try #require(try await r.store.get(b))
        #expect(wb.tasks[0].state == .done && wb.loop?.stopReason?.code == .landed)
        #expect(await r.host.lands == [.merge, .merge])
        #expect(await r.loop.takeNext(after: b) == nil)
        let notices = await r.host.ownerNotices
        #expect(notices.count == 1 && notices[0].contains("integrou 2 trabalhos"), "\(notices)")
    }

    @Test func anEmptyQueueEndsAsQueueEmpty() async throws {
        let r = try await Self.rig(max: 2); defer { r.cleanup() }
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .queueEmpty && w.loop?.state == .finished)
        #expect(w.notes.last?.text.hasPrefix("[loop] laço terminou") == true)
        #expect(!(w.loop?.events ?? []).contains { $0.kind == .stopped }, "queueEmpty is a normal end")
        #expect(await r.host.lands == [.merge])
    }

    /// A `work stop` during the chain's awaits (here the doctor's read): `requested`, nothing picked.
    @Test func aWorkStopDuringTheChainPicksNothing() async throws {
        let r = try await Self.rig(max: 2); defer { r.cleanup() }
        let b = try await Self.another(r, "b")
        let loop = r.loop, id = r.work
        await r.host.setDoctor(nil) { await loop.stop(work: id) }
        #expect(await r.run() == .stopped)
        #expect(try await r.get().loop?.stopReason?.code == .requested)
        #expect(await r.loop.takeNext(after: r.work) == nil)
        #expect(try await r.store.get(b)?.loop?.state == .queued)
        #expect(await r.host.lands == [.merge])
    }

    /// The loop never approves: with room left (N=2), a work with no loop, one `stopped`, one `running` with no
    /// approval of its own (no auto-land) in the paddock, and a queued one of another paddock never enter.
    @Test func aWorkNotApprovedNeverEnters() async throws {
        let r = try await Self.rig(max: 2); defer { r.cleanup() }
        var stopped = WorkLoopState(tries: 1, timeout: 60, tasks: ["y"], review: true)
        stopped.autoLand = WorkLoopState.AutoLand(gate: "true"); stopped.state = .stopped
        let bare = WorkLoopState(tries: 1, timeout: 60, tasks: ["z"])
        let x = try await Self.another(r, "x", queued: false)
        let y = try await Self.another(r, "y", queued: false, loop: stopped)
        let z = try await Self.another(r, "z", queued: false, loop: bare)
        let o = try await Self.another(r, "o", paddock: UUID())
        #expect(await r.run() == .finished)
        #expect(try await r.get().loop?.stopReason?.code == .queueEmpty)
        #expect(await r.loop.takeNext(after: r.work) == nil)
        #expect(try await r.store.get(x)?.loop == nil)
        #expect(try await r.store.get(y)?.loop == stopped)
        #expect(try await r.store.get(z)?.loop == bare)
        #expect(try await r.store.get(o)?.loop?.state == .queued)
        #expect(await r.host.lands == [.merge])
    }

    /// `activate` moves only a queued work with its auto-land: one closed (or run, or stopped) meanwhile stays as it is.
    @Test func activateTakesOnlyAQueuedWork() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        let b = try await Self.another(r, "b")
        let c = WorkLoop.Chain(next: b, max: 2, perDay: nil, chained: 1, budget: 50, after: "W")
        var w = try #require(try await r.store.get(b))
        w.closedAt = Date()
        #expect(!WorkLoop.activate(&w, c, at: Date()) && w.loop?.state == .queued)
        w.closedAt = nil; w.loop?.state = .stopped
        #expect(!WorkLoop.activate(&w, c, at: Date()) && w.loop?.state == .stopped)
        w.loop?.state = .queued
        #expect(WorkLoop.activate(&w, c, at: Date()) && w.loop?.state == .running && w.loop?.budget == 50 && w.loop?.autoLand?.chained == 1)
    }

    /// The one rule of "finished", for the engine and the app's history rows alike.
    @Test func finishesIsOneRuleOverCodeAndDetail() throws {
        #expect(Stop.finishes(code: "landed", detail: nil) && Stop.finishes(code: "queueEmpty", detail: nil))
        #expect(Stop.finishes(code: "maxReached", detail: "1 de --auto-land-max 1 integrado(s); 1 na fila"))
        #expect(!Stop.finishes(code: "maxReached", detail: nil) && !Stop.finishes(code: "budgetSpent", detail: nil))
        #expect(!Stop.finishes(code: "landDailyCap", detail: "x") && !Stop.finishes(code: nil, detail: nil) && !Stop.finishes(code: "novo", detail: nil))
        #expect(Stop(.maxReached, detail: "x").finishes && !Stop(.maxReached).finishes)
        // the history row gets the detail the rule needs
        var w = Work(title: "W", terminalId: UUID())
        w.loop = WorkLoopState(tasks: []); w.loop?.stopReason = Stop(.maxReached, detail: "1 de 1")
        let a = WorkArchive.make(w, paddock: nil, terminal: nil, loopSummary: "")
        #expect(a.stopReason == "maxReached" && a.stopDetail == "1 de 1")
        #expect(try JSONDecoder().decode(WorkArchive.self, from: a.encoded()).stopDetail == "1 de 1")
    }

    /// The paddock's durable land record of the last 24 h (the fake clock's): one land an hour ago counts, one 25 h ago not.
    private static func pastLands(_ r: LoopRig, hoursAgo: [Double]) async throws {
        let now = r.host.now()
        await r.host.addLands(hoursAgo.map { now.addingTimeInterval(-$0 * 3600) })
    }

    /// C3a: the cap counts the paddock's own record, never a work's journal: a land, then the same work reopened and
    /// run again (`$0.loop = loop`, its events gone) with the closed works pruned, still meets the cap.
    @Test func theDailyCapSurvivesANewRunOfTheSameWorkAndThePruning() async throws {
        let r = try await Self.rig(perDay: 1); defer { r.cleanup() }
        #expect(await r.run() == .finished)
        #expect(await r.host.autoLands().count == 1)
        try await r.store.update(r.work) {
            var l = WorkLoopState(tries: 1, timeout: 60, tasks: ["a"]); l.review = true
            l.autoLand = WorkLoopState.AutoLand(gate: "true", ci: "true", timeout: 60, perDay: 1)
            $0.loop = l; $0.closedAt = nil; $0.tasks[0].state = .open
        }
        #expect(try await r.get().loop?.events?.contains { $0.kind == .landed } != true)
        await r.host.set("w-task-a-t2", LoopScript(act: { try await commit("a2.swift", "let a = 2\n", in: $0) }))
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .landDailyCap && w.loop?.stopReason?.detail == "1 de 1 em 24 h", "\(String(describing: w.loop?.stopReason)) \(w.tasks) \(w.notes.suffix(4).map(\.text))")
        #expect(await r.host.lands == [.merge])
    }

    /// C3a: a merge that made no commit is no land: its own stop, no undo line, no event, nothing counted.
    @Test func aMergeWithNoCommitIsLandNothing() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        await r.host.setLandsNothing(true)
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .landNothing, "\(String(describing: w.loop?.stopReason))")
        #expect(w.loop?.events?.contains { $0.kind == .landed } != true)
        #expect(w.loop?.autoLand?.after == nil && !w.notes.contains { $0.text.contains("git reset --hard") })
        #expect(w.notes.contains { $0.text.contains("nada a integrar") })
        #expect(await r.host.autoLands().isEmpty)
        #expect(await r.loop.takeNext(after: r.work) == nil)
    }

    /// C3a: the clean review carries the HEAD it judged; a land whose HEAD is past it (commits after the review) vetoes.
    @Test func aCommitAfterTheReviewVetoesTheLand() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        #expect(await r.run() == .finished)
        let head = try await GitRunner.run(["rev-parse", "HEAD"], in: r.repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try await r.get().tasks[0].reviewedHead == head)
        var w = try await r.get()
        #expect(await r.loop.reviewedHeadVeto(w, head: head, r.repo) == nil)
        w.tasks[0].reviewedHead = String(repeating: "0", count: 40)
        #expect(await r.loop.reviewedHeadVeto(w, head: head, r.repo)?.contains("não é o que a revisão aprovou") == true)
        w.tasks[0].reviewedHead = nil
        #expect(await r.loop.reviewedHeadVeto(w, head: head, r.repo) != nil)
        // the engine: a done task approved clean at an older HEAD, a commit after it
        let r2 = try await Self.rig(); defer { r2.cleanup() }
        let old = try await GitRunner.run(["rev-parse", "HEAD"], in: r2.repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try await commit("depois.swift", "let x = 1\n", in: r2.repo)
        try await r2.store.update(r2.work) {
            $0.tasks[0].state = .done; $0.tasks[0].reviewClean = true; $0.tasks[0].review = "parecer: sem veto"; $0.tasks[0].reviewedHead = old
        }
        try await Self.expectStopped(r2, .landReviewVeto)
        #expect(try await r2.get().notes.contains { $0.text.contains("commits depois da revisão") })
    }

    @Test func theDailyCapStopsTheChainAndCallsTheOwner() async throws {
        let r = try await Self.rig(max: 3, perDay: 2); defer { r.cleanup() }
        try await Self.pastLands(r, hoursAgo: [1, 25])
        let b = try await Self.another(r, "b")
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .landDailyCap && w.loop?.stopReason?.detail == "2 de 2 em 24 h")
        #expect(await r.host.lands == [.merge])
        #expect(await r.loop.takeNext(after: r.work) == nil)
        #expect(try await r.store.get(b)?.loop?.state == .queued)
        #expect(await r.host.ownerNotices.last?.contains("teto diário") == true)
    }

    /// C6 (S7): the cap already spent refuses at the run's start: no attempt, no agent, no review, nothing landed.
    @Test func theDailyCapReachedStartsNoAttempt() async throws {
        let r = try await Self.rig(perDay: 1); defer { r.cleanup() }
        try await Self.pastLands(r, hoursAgo: [2])
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .landDailyCap && w.loop?.stopReason?.detail == "1 de 1 em 24 h", "\(String(describing: w.loop?.stopReason))")
        #expect(w.loop?.used == 0 && w.tasks[0].state == .open)
        #expect(!(w.loop?.events ?? []).contains { $0.kind == .attemptStarted }, "\(w.loop?.events?.map(\.kind) ?? [])")
        #expect(w.notes.contains { $0.text.contains("teto diário atingido (1 de 1 em 24 h)") })
        #expect(await r.host.lands.isEmpty)
        #expect(await r.host.ownerNotices.last?.contains("teto diário") == true)
    }

    /// C6: the land's gate and CI are in the journal, in order, between the attempt and `landed`.
    @Test func theLandsGateAndCiAreJournaled() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        #expect(await r.run() == .finished)
        let events = try await r.get().loop?.events ?? []
        let land: [LoopEvent.Kind] = [.landGateStarted, .landGateFinished, .landCiStarted, .landCiFinished, .landed]
        #expect(events.map(\.kind).filter(land.contains) == land, "\(events.map(\.kind))")
        let ci = try #require(events.first { $0.kind == .landCiFinished })
        #expect(ci.detail?.hasPrefix("exit 0 em ") == true, "\(String(describing: ci.detail))")
    }

    /// C6: `work stop` cancels the land's CI at once (it never ends by itself here), and journals its end.
    @Test(.timeLimit(.minutes(1))) func aWorkStopCancelsTheLandsCi() async throws {
        let r = try await Self.rig(ci: "ci-held"); defer { r.cleanup() }
        let (entered, inside) = AsyncStream<Void>.makeStream()
        await r.host.setCheckStub { c, _ in
            guard c == "ci-held" else { return nil }
            inside.yield()
            await heldUntilCancelled()
            return ProcessResult(status: 143, stdout: "", stderr: "", truncated: false)
        }
        let run = Task { await r.run() }
        for await _ in entered { break }
        await r.loop.stop(work: r.work)
        #expect(await run.value == .stopped)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .requested, "\(String(describing: w.loop?.stopReason))")
        #expect(await r.host.lands.isEmpty)
        let kinds = (w.loop?.events ?? []).map(\.kind)
        #expect(kinds.contains(.landCiStarted) && kinds.contains(.landCiFinished), "\(kinds)")
    }

    @Test func aRegressedDoctorStopsTheChain() async throws {
        let r = try await Self.rig(max: 2); defer { r.cleanup() }
        let b = try await Self.another(r, "b")
        await r.host.setDoctor("static 0")
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .landDoctorRegressed && w.loop?.stopReason?.detail == "static 0")
        #expect(await r.host.lands == [.merge])
        #expect(await r.loop.takeNext(after: r.work) == nil)
        #expect(try await r.store.get(b)?.loop?.state == .queued)
    }

    @Test func aFailureOfTheNextWorkStopsTheWholeChain() async throws {
        let r = try await Self.rig(max: 3); defer { r.cleanup() }
        let b = try await Self.another(r, "b", gate: "false")
        let c = try await Self.another(r, "c")
        #expect(await r.run() == .finished)
        #expect(try await Self.activated(r, after: r.work).next == b)
        #expect(await r.loop.run(work: b, dir: r.repo) == .stopped)
        #expect(try await r.store.get(b)?.loop?.stopReason?.code == .landGateRed)
        #expect(await r.loop.takeNext(after: b) == nil)
        #expect(await r.host.lands == [.merge])
        #expect(try await r.store.get(c)?.loop?.state == .queued)
    }

    @Test func theCLIsMaxAndTheProfilesPerDayReachTheState() throws {
        let c = try #require(try? ProjectWorkConfig.parse(Data(#"{"gate": "g", "factory": {"version": 1, "guardrails": {"autoLandPerDay": 7}}}"#.utf8)).get().config)
        let al = try CommandRouter.loopAutoLand(factory: true, config: c, review: true, noReview: false, max: 4)
        #expect(al.max == 4 && al.perDay == 7)
        var l = WorkLoopState(tasks: ["a"]); l.autoLand = al; l.state = .queued
        let back = try JSONDecoder().decode(WorkLoopState.self, from: JSONEncoder().encode(l))
        #expect(back.state == .queued && back.autoLand == al)
    }

    // MARK: C3b

    private static func head(_ dir: URL, _ rev: String = "HEAD") async throws -> String {
        try await GitRunner.run(["rev-parse", rev], in: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// C3b: the paddock changed, against the base, a file that judges the land: `landGateRed`, and neither the gate nor
    /// the CI runs. Each file alone: `collie-work.json`, the CI's script, a script the gate names; each still exits 0,
    /// so without the check every one would land.
    @Test func aFileThatJudgesTheLandChangedStopsAsGateRed() async throws {
        for (file, gate, ci) in [("collie-work.json", "echo gate", "echo ci"), ("ci.sh", "echo gate", "bash ci.sh"), ("gate.sh", "bash gate.sh", "echo ci"),
                                 ("ci.sh", "echo gate", "bash ./ci.sh"), ("gate.sh", "(cd . && bash \"./gate.sh\")", "echo ci")] {
            let r = try await Self.rig(gate: gate, ci: ci); defer { r.cleanup() }
            try await commit("ci.sh", "exit 0\n", in: r.repo)
            try await commit("gate.sh", "exit 0\n", in: r.repo)
            // the spec names the files: the attempt's own guards (`tampered`, M13.3) let the task change them
            try await commit("spec.md", "SPEC: collie-work.json ci.sh gate.sh\n", in: r.repo)
            await r.host.setBase(try await Self.head(r.repo))
            let text = file == "collie-work.json" ? "{}\n" : "exit 0 # mudou\n"
            await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("a.swift", "let a = 1\n", in: $0); try await commit(file, text, in: $0) }))
            try await Self.expectStopped(r, .landGateRed)
            #expect(try await r.get().notes.contains { $0.text.contains("o agente alterou \(file) que julga o land") }, "\(file)")
            let ran = await r.host.commands
            #expect(!ran.contains(gate) && !ran.contains(ci), "\(file): \(ran)")
        }
    }

    /// C3b: the paths that judge the land are the commands' whole tokens, never substrings: a file `a` or `ci` beside a
    /// CI `true scripts/ci/run.sh` is no file of the CI, and the land goes on; `./x` and `x` are one path.
    @Test func aShortNameIsNoFileThatJudgesTheLand() async throws {
        let r = try await Self.rig(gate: "echo gate", ci: "true scripts/ci/run.sh"); defer { r.cleanup() }
        await r.host.setBase(try await Self.head(r.repo))
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("a", "x\n", in: $0); try await commit("ci", "x\n", in: $0) }))
        #expect(await r.run() == .finished)
        let got = try await r.get()
        #expect(got.loop?.stopReason?.code == .landed, "\(got.notes.map(\.text))")
        let dir = URL(fileURLWithPath: "/r")
        let t = WorkLoop.judgedPaths("bash ./scripts/x.sh && make ci; \"scripts/y.sh\"|tee /r/out.txt", dir)
        #expect(t.contains("scripts/x.sh") && t.contains("scripts/y.sh") && t.contains("out.txt") && !t.contains("./scripts/x.sh"), "\(t)")
        #expect(WorkLoop.normalPath("././scripts/x.sh", dir) == "scripts/x.sh")
    }

    /// C3b: the base must be exactly the one the last attempt began on (`autoLand.baseHead`, taken at the attempt's
    /// start). The same base lands; one that moves while the CI runs stops as `landBaseMoved`, nothing merged; a base
    /// git cannot read stops as `gitFailed`.
    @Test func aBaseThatMovedStopsAsBaseMoved() async throws {
        let ok = try await Self.rig(); defer { ok.cleanup() }
        let start0 = try await Self.head(ok.repo)
        await ok.host.setBase(start0)
        #expect(await ok.run() == .finished)
        let l = try await ok.get().loop
        #expect(l?.stopReason?.code == .landed && l?.autoLand?.baseHead == start0)
        #expect(await ok.host.landBases == [start0])

        let r = try await Self.rig(ci: "echo ci"); defer { r.cleanup() }
        let start = try await Self.head(r.repo), moved = String(repeating: "c", count: 40)
        await r.host.setBase(start)
        let host = r.host
        await r.host.setProbe { c in if c == "echo ci" { await host.setBase(moved) } }
        try await Self.expectStopped(r, .landBaseMoved)
        #expect(try await r.get().notes.contains { $0.text.contains("a base mudou") && $0.text.contains(String(moved.prefix(12))) })

        let e = try await Self.rig(); defer { e.cleanup() }
        await e.host.setBaseError(ProtocolError(code: .internal, message: "sem base"))
        try await Self.expectStopped(e, .gitFailed)
    }

    /// C3b: a base the host knows now but no attempt recorded (unread when it began): the land fails closed as
    /// `landBaseMoved` ("base desconhecida"), nothing merged.
    @Test func anUnknownBaseFailsClosed() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        let host = r.host, base = try await Self.head(r.repo)
        // nil when the attempt began (nothing recorded); known from the agent's turn on
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("a.swift", "let a = 1\n", in: $0); await host.setBase(base) }))
        try await Self.expectStopped(r, .landBaseMoved)
        #expect(try await r.get().loop?.autoLand?.baseHead == nil)
        #expect(try await r.get().notes.contains { $0.text.contains("base desconhecida") })
    }

    /// C4a: the engine, given a land whose record was not written, stops as `landRegistryFailed` (no chain, the owner
    /// told by the stop's notice), the merge's commits kept on the work.
    @Test func aLandNotRecordedStopsTheLoop() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        await r.host.setLandUnrecorded("disco cheio")
        #expect(await r.run() == .stopped)
        let w = try await r.get()
        #expect(w.loop?.stopReason?.code == .landRegistryFailed, "\(String(describing: w.loop?.stopReason))")
        #expect(await r.host.lands == [.merge] && w.loop?.autoLand?.after == LoopFakeHost.landedAfter)
        #expect(w.notes.contains { $0.text.contains("registro do teto diário não foi gravado: disco cheio") })
        let notices = await r.host.ownerNotices
        #expect(notices.contains { $0.contains("registro do teto diário") }, "\(notices)")
    }

    /// C4a: a base known when the attempt began (`autoLand.baseHead`) but unread at the land (the host says none): the
    /// check of what judges the land cannot run, and the land fails closed as `landGateRed`.
    @Test func aBaseUnreadAtTheLandFailsClosed() async throws {
        let r = try await Self.rig(gate: "echo gate"); defer { r.cleanup() }
        let host = r.host
        await r.host.setBase(try await Self.head(r.repo))
        await r.host.set("w-task-a-t1", LoopScript(act: { try await commit("a.swift", "let a = 1\n", in: $0); await host.setBase(nil) }))
        try await Self.expectStopped(r, .landGateRed)
        #expect(try await r.get().notes.contains { $0.text.contains("não consegui comparar o que julga o land com a base") })
        #expect(!(await r.host.commands).contains("echo gate"))
    }

    /// C4a: `work task done` by hand and `work task reopen` drop the loop's verdicts (a clean review, the HEAD it judged,
    /// a passed acceptance): the auto-land never trusts them afterwards.
    @Test func doneByHandAndReopenClearTheVerdicts() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        func judged(_ state: TaskState) async throws {
            try await r.store.update(r.work) {
                $0.tasks[0].state = state; $0.tasks[0].reviewClean = true; $0.tasks[0].reviewedHead = "abc"; $0.tasks[0].acceptPassed = true
            }
        }
        try await judged(.open)
        let done = try #require(try await r.store.setTask(r.work, task: "a", state: .done, reason: nil, at: Date()))
        #expect(done.reviewClean == nil && done.reviewedHead == nil && done.acceptPassed == nil)
        try await judged(.deferred)
        let back = try #require(try await r.store.reopenTask(r.work, task: "a", keepTries: false, at: Date()))
        #expect(back.task.state == .open && back.task.reviewClean == nil && back.task.reviewedHead == nil && back.task.acceptPassed == nil)
    }

    /// C3b: a base unread at the attempt's start (git failing) never writes over the one recorded before: it stays.
    @Test func aBaseUnreadAtTheAttemptKeepsTheLastOne() async throws {
        let r = try await Self.rig(); defer { r.cleanup() }
        let last = String(repeating: "d", count: 40)
        try await r.store.update(r.work) { $0.loop?.autoLand?.baseHead = last }
        await r.host.setBaseError(ProtocolError(code: .internal, message: "sem base"))
        try await Self.expectStopped(r, .gitFailed)
        #expect(try await r.get().loop?.autoLand?.baseHead == last)
    }

    /// C3b: the conditions in order. The gate and the CI red together: `landGateRed`, and the CI never runs. A mute review
    /// and the CI red: `landReviewVeto`, and the CI never runs.
    @Test func theFirstFailingConditionWinsAndTheCINeverRuns() async throws {
        let ci = "echo ci; exit 4"
        let g = try await Self.rig(gate: "echo gate; exit 3", ci: ci); defer { g.cleanup() }
        try await Self.expectStopped(g, .landGateRed)
        let gran = await g.host.commands
        #expect(gran.contains("echo gate; exit 3") && !gran.contains(ci), "\(gran)")
        let v = try await Self.rig(gate: "echo gate", ci: ci); defer { v.cleanup() }
        await v.host.setReviewAnswer("correcao", nil)
        try await Self.expectStopped(v, .landReviewVeto)
        let vran = await v.host.commands
        #expect(vran.contains("echo gate") && !vran.contains(ci), "\(vran)")
    }

    /// C3b: the queue goes by the owner's approval (`approvedAt`), oldest first, never by when `work run` was asked; a
    /// loop from before (no `approvedAt`) goes by its start.
    @Test func theQueueGoesByTheOldestApproval() async throws {
        let r = try await Self.rig(max: 2); defer { r.cleanup() }
        let b = try await Self.another(r, "b"), c = try await Self.another(r, "c")
        let t = Date()
        // b asked first, approved last; c asked last, approved first
        try await r.store.update(b) { $0.loop?.startedAt = t; $0.loop?.autoLand?.approvedAt = t + 60 }
        try await r.store.update(c) { $0.loop?.startedAt = t + 30; $0.loop?.autoLand?.approvedAt = t + 10 }
        #expect(await r.run() == .finished)
        #expect(try await Self.activated(r, after: r.work).next == c)
        var old = WorkLoopState(tasks: []); old.startedAt = t
        #expect(WorkLoop.approved(old) == t)
    }
}

/// C3a: a profile the factory doctor passes (static and judge at least 1), committed at `repo`'s HEAD.
func commitFactoryProfile(_ repo: URL, gate: Bool = true) async throws {
    let fm = FileManager.default
    try fm.createDirectory(at: repo.appendingPathComponent("scripts/ci"), withIntermediateDirectories: true)
    try "#!/bin/bash\nswift test --disable-sandbox\n".write(to: repo.appendingPathComponent("scripts/ci/gate.sh"), atomically: true, encoding: .utf8)
    try "#!/bin/bash\nexit 0\n".write(to: repo.appendingPathComponent("scripts/ci/check-architecture.sh"), atomically: true, encoding: .utf8)
    try await commit("collie-work.json", factoryProfileText(gate: gate), in: repo)
}

func factoryProfileText(gate: Bool = true) -> String {
    """
    { "version": 1, \(gate ? #""gate": "scripts/ci/gate.sh", "# : "")"precheck": "swift build --build-tests",
      "smoke": "swift test --filter WorkLoopTests",
      "areas": { "work": "swift test --filter WorkCommandTests" },
      "factory": { "version": 1, "static": { "architecture": ["scripts/ci/check-architecture.sh"] },
        "review": { "personas": ["correcao", "testes"], "threshold": "major" },
        "guardrails": { "budgetSeconds": 14400, "maxTries": 3, "destructive": ["git push"], "land": "manual" } } }
    """
}

private extension CommandRouter {
    /// A paddock on `repo`, reserved as a running loop holds it (C3a: a factory's, as only a factory's loop chains).
    func addChainPaddock(_ repo: URL, factory: Bool = true) -> UUID {
        var p = Paddock(id: UUID(), name: "fab", repoRoot: repo.path, path: repo.path, branch: "main", baseBranch: "main")
        p.factory = factory
        ws.paddocks.append(p); loopPaddocks.insert(p.id)
        return p.id
    }
    func addPaddock(_ p: Paddock) { ws.paddocks.append(p) }
    func setFactoryMark(_ id: UUID, _ on: Bool) { if let i = ws.paddocks.firstIndex(where: { $0.id == id }) { ws.paddocks[i].factory = on } }
    func setLandSaveFails(_ on: Bool) { landSaveFails = on }
    func setLandRecordFails(_ on: Bool) { landRecordFails = on }
    func setLandFailsAfterMerge(_ on: Bool) { landFailsAfterMerge = on }
    /// The first work's engine as it is once `engine.run` returned, before `loopEnded` (`stopping`: a `work stop` came then).
    func plantEnded(_ id: UUID, _ engine: WorkLoop, stopping: Bool) { workLoops[id] = (engine, Task {}, stopping) }
    func reserved(_ p: UUID) -> Bool { loopPaddocks.contains(p) }
    func loopTask(_ id: UUID) -> Task<Void, Never>? { workLoops[id]?.task }
    /// `chainLoop`, and what holds the instant it returns (no await in between: the chained engine cannot end yet).
    func chainProbe(_ c: WorkLoop.Chain, paddock: UUID, starter: UUID) async -> (ok: Bool, reserved: Bool, engine: Bool) {
        let ok = await chainLoop(c, paddock: paddock, starter: starter) == nil
        return (ok, loopPaddocks.contains(paddock), workLoops[c.next] != nil)
    }
}

/// A5, the router's side of the chain (`loopEnded` → `chainLoop`): the next work starts on the paddock's reservation,
/// with its engine registered before it turns `running`; a `work stop` after the first engine's end, or a work that
/// cannot start, leaves it `queued` and frees the paddock.
@Suite(.serialized) struct AutoLandTestsChain {
    private struct Rig { var a: UUID, b: UUID, paddock: UUID, chain: WorkLoop.Chain }

    private func rig(_ d: Daemon, _ repo: URL) async throws -> Rig {
        try await commitFactoryProfile(repo)
        let pid = await d.router.addChainPaddock(repo)
        let a = try await d.router.work.start(title: "A", terminal: UUID(), paddockId: pid, branch: nil)
        try await d.router.work.update(a.id) { $0.loop = WorkLoopState(state: .finished, tries: 1, timeout: 60, tasks: []) }
        let b = try await d.router.work.start(title: "B", terminal: UUID(), paddockId: pid, branch: nil)
        try await d.router.work.update(b.id) {
            $0.tasks = [WorkTask(id: "b", title: "Task b", check: "true")]
            var l = WorkLoopState(tries: 1, timeout: 60, tasks: ["b"]); l.autoLand = .init(gate: "true"); l.state = .queued
            $0.loop = l
        }
        await d.router.plantEnded(a.id, WorkLoop(store: d.router.work, host: LoopFakeHost(dir: repo)), stopping: false)
        return Rig(a: a.id, b: b.id, paddock: pid, chain: .init(next: b.id, max: 2, perDay: nil, chained: 1, budget: 500, after: "A"))
    }

    @Test func theNextWorkRunsOnTheSameReservationWithItsEngineRegisteredFirst() async throws {
        try await withDaemon { d, _ in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            let r = try await rig(d, repo)
            // the starter is no terminal: the chained engine runs and stops at once (`starterGone`), no agent
            await d.router.loopEnded(r.a, starter: UUID(), paddock: r.paddock, next: r.chain)
            let task = await d.router.loopTask(r.b)
            let b = try #require(try await d.router.work.get(r.b))
            #expect(task != nil || b.loop?.state != .running, "running with no engine")
            #expect(b.loop?.autoLand?.chained == 1 && b.loop?.autoLand?.max == 2 && b.loop?.budget == 500)
            await task?.value
            let end = try #require(try await d.router.work.get(r.b)?.loop)
            #expect(end.state == .stopped && end.stopReason?.code == .starterGone, "\(String(describing: end.stopReason))")
            #expect(await !d.router.reserved(r.paddock))
        }
    }

    /// The paddock's reservation is never freed between the two works: held, with the chained engine registered and
    /// the work `running`, until that engine ends.
    @Test func theReservationIsHeldWhileTheChainedWorkRuns() async throws {
        try await withDaemon { d, _ in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            let r = try await rig(d, repo)
            let probe = await d.router.chainProbe(r.chain, paddock: r.paddock, starter: UUID())
            #expect(probe.ok && probe.reserved && probe.engine)
            let task = try #require(await d.router.loopTask(r.b))
            await task.value
            #expect(try await d.router.work.get(r.b)?.loop?.stopReason?.code == .starterGone)
            #expect(await !d.router.reserved(r.paddock))
            #expect(await d.router.loopTask(r.b) == nil)
        }
    }

    /// A `work stop` after the first engine's end: nothing chained, and since that engine left the owner's line to the
    /// next work, the first one tells, counting its land.
    @Test func aWorkStopAfterTheEnginesEndStopsTheChain() async throws {
        try await withDaemon { d, p in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            let r = try await rig(d, repo)
            let ev = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            defer { ev.close() }
            let starter = UUID()
            await d.router.plantEnded(r.a, WorkLoop(store: d.router.work, host: LoopFakeHost(dir: repo)), stopping: true)
            await d.router.loopEnded(r.a, starter: starter, paddock: r.paddock, next: r.chain)
            #expect(try await d.router.work.get(r.b)?.loop?.state == .queued)
            #expect(await d.router.loopTask(r.b) == nil)
            #expect(await !d.router.reserved(r.paddock))
            #expect(try await d.router.work.get(r.a)?.notes.last?.text.contains("work stop") == true)
            var line: String?
            while line == nil, case .event(let e)? = try await ev.next(timeoutSeconds: 30) {
                if case .notify(let to, let m) = e, to == starter { line = m }
            }
            #expect(line?.contains("integrou 1 trabalho; parou em pedido pelo dono") == true, "\(line ?? "nenhuma")")
            #expect(line?.contains("segue na fila") == true)
        }
    }

    /// C3a: before any agent of the next work runs, the paddock must still carry the factory mark and its doctor at
    /// HEAD must still pass: else the work stays `queued`, no engine, the paddock freed, and the first work says why.
    @Test func theNextWorkRechecksTheFactoryMarkAndTheDoctorAtHEAD() async throws {
        try await withDaemon { d, _ in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            let r = try await rig(d, repo)
            await d.router.setFactoryMark(r.paddock, false)
            await d.router.loopEnded(r.a, starter: UUID(), paddock: r.paddock, next: r.chain)
            #expect(try await d.router.work.get(r.b)?.loop?.state == .queued)
            #expect(await d.router.loopTask(r.b) == nil)
            #expect(await !d.router.reserved(r.paddock))
            #expect(try await d.router.work.get(r.a)?.notes.last?.text.contains("não está mais marcado como fábrica") == true)
        }
        try await withDaemon { d, _ in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            let r = try await rig(d, repo)
            // the profile committed without its gate: static 0 at HEAD
            try await commit("collie-work.json", factoryProfileText(gate: false), in: repo)
            await d.router.loopEnded(r.a, starter: UUID(), paddock: r.paddock, next: r.chain)
            #expect(try await d.router.work.get(r.b)?.loop?.state == .queued)
            #expect(await d.router.loopTask(r.b) == nil)
            #expect(await !d.router.reserved(r.paddock))
            #expect(try await d.router.work.get(r.a)?.notes.last?.text.contains("factory doctor") == true)
        }
    }

    /// C3a: `loopLand` with real git: the base before is read right before the merge; a land with commits is recorded
    /// on the paddock (durable, persisted); one already integrated, or a paddock with nothing new, makes no commit:
    /// before == after, nothing recorded (the engine stops it as `landNothing`).
    @Test func loopLandReadsBeforeUnderTheClaimAndRecordsOnlyRealLands() async throws {
        try await withDaemon { d, p in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            var k = try await PaddockManager.create(name: "k", repoRoot: repo, createdBy: nil)
            k.factory = true
            await d.router.addPaddock(k)
            let dir = URL(fileURLWithPath: k.path)
            try await commit("novo.swift", "let n = 1\n", in: dir)
            let base = try await GitRunner.run(["rev-parse", "HEAD"], in: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let one = try await d.router.loopLand(k.id, mode: .merge, message: "land 1")
            #expect(one.before == base && one.after != base)
            #expect(await d.router.loopAutoLands(k.id).count == 1)
            let wsId = await d.router.ws.id
            #expect(try await WorkspaceStore(paths: p).load(wsId).paddocks.first { $0.id == k.id }?.autoLands?.count == 1)
            // already integrated: "Already up to date", no commit
            let two = try await d.router.loopLand(k.id, mode: .merge, message: "land 2")
            #expect(two.before == two.after && two.after == one.after)
            #expect(await d.router.loopAutoLands(k.id).count == 1)
            // a new paddock with no commits of its own
            var e = try await PaddockManager.create(name: "e", repoRoot: repo, createdBy: nil)
            e.factory = true
            await d.router.addPaddock(e)
            let three = try await d.router.loopLand(e.id, mode: .merge, message: "land 3")
            #expect(three.before == three.after)
            #expect(await d.router.loopAutoLands(e.id).isEmpty)
        }
    }

    /// C2: `loopLand` with real git and the save after the merge failing: the land is no throw (the base moved), its
    /// commits come back with `late`, and it is counted.
    @Test func loopLandGivesBackAFailureAfterTheMerge() async throws {
        try await withDaemon { d, _ in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            var k = try await PaddockManager.create(name: "late", repoRoot: repo, createdBy: nil)
            k.factory = true
            await d.router.addPaddock(k)
            try await commit("novo.swift", "let n = 1\n", in: URL(fileURLWithPath: k.path))
            await d.router.setLandSaveFails(true)
            let r = try await d.router.loopLand(k.id, mode: .merge, message: "land late")
            await d.router.setLandSaveFails(false)
            #expect(r.before != r.after && r.late?.contains("gravação do cercado falhou") == true, "\(r)")
            let head = try await GitRunner.run(["rev-parse", "HEAD"], in: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(head == r.after)
            #expect(await d.router.loopAutoLands(k.id).count == 1)
        }
    }

    /// C4a: `loopLand` with real git and `PaddockManager.land` throwing AFTER its merge (the base moved): the land still
    /// throws (no `late`), but it is counted in the daily cap all the same.
    @Test func aThrowAfterTheMergeStillCountsInTheDailyCap() async throws {
        try await withDaemon { d, _ in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            var k = try await PaddockManager.create(name: "tarde", repoRoot: repo, createdBy: nil)
            k.factory = true
            await d.router.addPaddock(k)
            try await commit("novo.swift", "let n = 1\n", in: URL(fileURLWithPath: k.path))
            func main() async throws -> String { try await GitRunner.run(["rev-parse", "main"], in: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
            let base = try await main()
            await d.router.setLandFailsAfterMerge(true)
            var threw: String?
            do { _ = try await d.router.loopLand(k.id, mode: .merge, message: "land") } catch { threw = (error as? ProtocolError)?.message ?? "\(error)" }
            await d.router.setLandFailsAfterMerge(false)
            #expect(threw?.contains("depois do merge") == true, "\(threw ?? "no throw")")
            #expect(try await main() != base)   // the merge happened
            #expect(await d.router.loopAutoLands(k.id).count == 1)
        }
    }

    /// C4a: `loopLand` with real git whose land record cannot be persisted: the merge is given back with `unrecorded`
    /// (the in-memory record still counts it); a land that persists says nothing.
    @Test func aLandRecordNotPersistedIsGivenBack() async throws {
        try await withDaemon { d, _ in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            var k = try await PaddockManager.create(name: "reg", repoRoot: repo, createdBy: nil)
            k.factory = true
            await d.router.addPaddock(k)
            try await commit("novo.swift", "let n = 1\n", in: URL(fileURLWithPath: k.path))
            await d.router.setLandRecordFails(true)
            let r = try await d.router.loopLand(k.id, mode: .merge, message: "land")
            await d.router.setLandRecordFails(false)
            #expect(r.before != r.after && r.unrecorded?.contains("gravação do registro falhou") == true, "\(r)")
            #expect(await d.router.loopAutoLands(k.id).count == 1)
        }
    }

    /// C3b: `loopLand` with real git refuses a paddock with no factory mark and, marked, any mode but merge: the base
    /// stays where it was; then the merge gives the base before and after. `loopBaseHead` reads the base branch now.
    @Test func loopLandRefusesAnotherModeAndAPaddockNotAFactorys() async throws {
        try await withDaemon { d, _ in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            let k = try await PaddockManager.create(name: "r", repoRoot: repo, createdBy: nil)
            await d.router.addPaddock(k)
            try await commit("novo.swift", "let n = 1\n", in: URL(fileURLWithPath: k.path))
            func main() async throws -> String { try await GitRunner.run(["rev-parse", "main"], in: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
            let base = try await main()
            #expect(try await d.router.loopBaseHead(k.id) == base)
            func refusal(_ mode: LandMode) async -> String? {
                do { _ = try await d.router.loopLand(k.id, mode: mode, message: "x"); return nil } catch { return error.message }
            }
            let notFactory = await refusal(.merge)
            #expect(notFactory?.contains("not a factory's") == true, "\(notFactory ?? "landed")")
            await d.router.setFactoryMark(k.id, true)
            for mode in [LandMode.squash, .rebase, .pr] {
                let why = await refusal(mode)
                #expect(why?.contains("only by merge") == true, "\(mode): \(why ?? "landed")")
            }
            let none = await d.router.loopAutoLands(k.id)
            #expect(try await main() == base && none.isEmpty)
            let land = try await d.router.loopLand(k.id, mode: .merge, message: "land")
            let after = try await main()
            #expect(land.before == base && land.after == after && after != base)
            #expect(try await d.router.loopBaseHead(k.id) == after)
        }
    }

    /// C3b: works run one after another on a real paddock, each attempt taking the base through the router
    /// (`loopBaseHead`) and each land the router's (`loopLand`). Two lands in a row pass (after the first, the base is
    /// its merge commit, ahead of the paddock: the next attempt takes that one); a commit on the base between the
    /// attempt and the land stops the third as `landBaseMoved`, nothing merged.
    @Test func twoLandsInARowPassAndABaseMovedAfterTheAttemptStops() async throws {
        try await withDaemon { d, _ in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            let k = try await Self.realPaddock(d, repo, "seq")
            let dir = URL(fileURLWithPath: k.path)
            let (store, host, loop, cleanup) = try await Self.engine(d, k)
            defer { cleanup() }
            var stops: [WorkLoopState.Stop.Code?] = [], bases: [String?] = [], seen: [String] = []
            for i in 1...3 {
                seen.append(try await Self.main(repo))
                let w = try await Self.work(store, k, i)
                await host.set("w\(i)-task-t\(i)-t1", LoopScript(act: {
                    try await commit("t\(i).swift", "let t = \(i)\n", in: $0)
                    // the third: someone else commits on the base after the attempt began
                    if i == 3 { try await commit("outro.txt", "x\n", in: repo) }
                }))
                _ = await loop.run(work: w, dir: dir)
                try await store.update(w) { $0.closedAt = Date() }
                let l = try await store.get(w)?.loop
                stops.append(l?.stopReason?.code); bases.append(l?.autoLand?.baseHead)
            }
            #expect(stops == [.landed, .landed, .landBaseMoved], "\(stops)")
            #expect(bases == seen.map { Optional($0) }, "\(bases) \(seen)")
            #expect(await d.router.loopAutoLands(k.id).count == 2)
            let log = try await GitRunner.run(["log", "--oneline", "main"], in: repo).stdout
            #expect(log.contains("t2") && !log.contains("t3"))
        }
    }

    /// C3b: the base moves between the engine's last check and the merge: the land, under its claim, finds the base
    /// branch elsewhere and merges nothing (`landBaseMoved`).
    @Test func aBaseThatMovesRightBeforeTheMergeLandsNothing() async throws {
        try await withDaemon { d, _ in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            let k = try await Self.realPaddock(d, repo, "toctou")
            let (store, host, loop, cleanup) = try await Self.engine(d, k)
            defer { cleanup() }
            let w = try await Self.work(store, k, 1)
            await host.set("w1-task-t1-t1", LoopScript(act: { try await commit("t1.swift", "let t = 1\n", in: $0) }))
            let judged = try await Self.main(repo)
            await host.setLandHook { try? await commit("outro.txt", "x\n", in: repo) }
            _ = await loop.run(work: w, dir: URL(fileURLWithPath: k.path))
            let x = try #require(try await store.get(w))
            #expect(x.loop?.stopReason?.code == .landBaseMoved, "\(String(describing: x.loop?.stopReason)) \(x.notes.map(\.text)) \(x.tasks)")
            #expect(await host.landBases == [judged])
            let now = try await Self.main(repo), log = try await GitRunner.run(["log", "--oneline", "main"], in: repo).stdout
            #expect(now != judged && !log.contains("t1"))
            #expect(await d.router.loopAutoLands(k.id).isEmpty)
        }
    }

    /// C3b: the chain's activation takes the base again (after the land before it): a stale reference goes.
    @Test func theChainsActivationTakesTheBaseAgain() async throws {
        try await withDaemon { d, _ in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            let r = try await rig(d, repo)
            try await d.router.work.update(r.b) { $0.loop?.autoLand?.baseHead = "velha" }
            let probe = await d.router.chainProbe(r.chain, paddock: r.paddock, starter: UUID())
            #expect(probe.ok)
            await (await d.router.loopTask(r.b))?.value
            #expect(try await d.router.work.get(r.b)?.loop?.autoLand?.baseHead == (try await Self.main(repo)))
        }
    }

    private static func main(_ repo: URL) async throws -> String {
        try await GitRunner.run(["rev-parse", "main"], in: repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// A paddock of `repo` (a worktree off `main`) marked a factory's, with a persona and a spec committed in it.
    private static func realPaddock(_ d: Daemon, _ repo: URL, _ name: String) async throws -> Paddock {
        var k = try await PaddockManager.create(name: name, repoRoot: repo, createdBy: nil)
        k.factory = true
        await d.router.addPaddock(k)
        let dir = URL(fileURLWithPath: k.path)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(CommandRouter.personasDir), withIntermediateDirectories: true)
        try await commit(CommandRouter.personasDir + "correcao.md", "---\nname: correcao\nmodel: sonnet\npaths: [\"**\"]\n---\nCorpo\n", in: dir)
        try await commit("spec.md", "SPEC\n", in: dir)
        return k
    }
    /// An engine whose land, land record and base are the router's for `k` (`LoopFakeHost.setLandRouter`).
    private static func engine(_ d: Daemon, _ k: Paddock) async throws -> (WorkStore, LoopFakeHost, WorkLoop, () -> Void) {
        let storeDir = URL(fileURLWithPath: "/tmp/collie-c3b-\(UUID().uuidString.prefix(8))")
        let store = WorkStore(dir: storeDir), host = LoopFakeHost(dir: URL(fileURLWithPath: k.path))
        try FileManager.default.createDirectory(at: host.root, withIntermediateDirectories: true)
        await host.setFactory(true)
        await host.setLandRouter(d.router, k.id)
        let loop = WorkLoop(store: store, host: host, poll: .milliseconds(10), checkTimeout: .seconds(30), othersWait: .milliseconds(50), promptRetryWait: .zero)
        return (store, host, loop, { for u in [storeDir, host.patches, host.root] { try? FileManager.default.removeItem(at: u) } })
    }
    /// Work `i` of the paddock: one task `t<i>`, reviewed, with the auto-land on.
    private static func work(_ store: WorkStore, _ k: Paddock, _ i: Int) async throws -> UUID {
        let dir = URL(fileURLWithPath: k.path)
        let w = try await store.start(title: "W\(i)", terminal: UUID(), paddockId: k.id, branch: k.branch)
        try await store.update(w.id) {
            $0.tasks = [WorkTask(id: "t\(i)", title: "Task t\(i)", spec: dir.appendingPathComponent("spec.md").path, check: "true")]
            var l = WorkLoopState(tries: 1, timeout: 60, tasks: ["t\(i)"]); l.review = true
            l.autoLand = WorkLoopState.AutoLand(gate: "true", ci: "true", timeout: 60, perDay: 5)
            $0.loop = l
        }
        return w.id
    }

    @Test func aWorkThatCannotStartStaysQueued() async throws {
        try await withDaemon { d, _ in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            let r = try await rig(d, repo)
            try await d.router.work.update(r.b) { $0.closedAt = Date() }
            await d.router.loopEnded(r.a, starter: UUID(), paddock: r.paddock, next: r.chain)
            let b = try #require(try await d.router.work.get(r.b))
            #expect(b.loop?.state == .queued && b.loop?.stopReason == nil, "never stopped by a chain that did not start")
            #expect(await d.router.loopTask(r.b) == nil)
            #expect(await !d.router.reserved(r.paddock))
        }
    }
}

/// C2: `work run --auto-land` through the daemon's handler: refused in a paddock with no factory mark, with no gate in the
/// committed profile, and with `--no-review`; nothing runs (no card, no loop).
@Suite(.serialized, .timeLimit(.minutes(5))) struct AutoLandTestsHandler {
    private struct Term { var id: String; var token: String }

    private func spawn(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL? = nil, paddock: String? = nil) async throws -> Term {
        var args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "shepherd": .bool(true)]
        if let paddock { args["paddock"] = .string(paddock) } else if let cwd { args["cwd"] = .string(cwd.path) }
        let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
        guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
        return Term(id: id, token: try await tokenOf(d, id))
    }
    private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
        try await send(p, Request(id: "w", terminalId: t.id, token: t.token, command: cmd, args: args), timeoutSeconds: 60)
    }

    /// A factory's paddock `name` of a new repo whose `main` holds the profile (gate `true`, CI `true`, review by
    /// `correcao`, `perDay` a day) and the persona; `s`, a Shepherd in it.
    private func factoryPaddock(_ d: Daemon, _ p: Paths, _ name: String, perDay: Int = 3, trusted: Bool = false) async throws -> (repo: URL, pid: UUID, dir: URL, s: Term) {
        let repo = try await makeRepo()
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(CommandRouter.personasDir), withIntermediateDirectories: true)
        try await commit(CommandRouter.personasDir + "correcao.md", "---\nname: correcao\nmodel: sonnet\npaths: [\"**\"]\n---\nCorpo\n", in: repo)
        try await commit(ProjectWorkConfig.fileName, #"{"gate": "true", "factory": {"version": 1, "review": {"personas": ["correcao"], "threshold": "major"}, "#
            + #""autoland": {"ci": "true"}, "guardrails": {"autoLandPerDay": \#(perDay)}}}"#, in: repo)
        let m = try await spawn(d, p, "M", cwd: repo)
        #expect(try await call(p, m, "paddock.create", ["name": .string(name)]).ok)
        let pid = try #require(await d.router.ws.paddocks.first { $0.name == name }?.id)
        await d.router.setFactoryMark(pid, true)
        if trusted { _ = try await d.router.setTrustLoops(pid, true) }
        let s = try await spawn(d, p, "S", paddock: name)
        return (repo, pid, repo.appendingPathComponent(".collie/paddocks/\(name)"), s)
    }

    /// C3b: `work stop` on a work waiting in the auto-land queue takes it out: still `queued` (not terminal), still
    /// approved (`approvedAt` kept), `dequeuedAt` set, so no chain activates it; a second stop finds nothing to stop; the
    /// next `work run` puts it back in the queue. The trusted paddock's `work run` is the approval (`approvedAt`).
    @Test func workStopTakesAQueuedWorkOutOfTheQueueAndWorkRunPutsItBack() async throws {
        try await withDaemon { d, p in
            let x = try await factoryPaddock(d, p, "fila", trusted: true); defer { try? FileManager.default.removeItem(at: x.repo) }
            #expect(try await call(p, x.s, "work.start", ["title": .string("Fila")]).ok)
            #expect(try await call(p, x.s, "work.task.add", ["title": .string("A"), "check": .string("true"), "green-ok": .bool(true)]).ok)
            let w = try #require(try await d.router.work.list(includeClosed: false).first { $0.title == "Fila" })
            func run() async throws -> Response { try await call(p, x.s, "work.run", ["command": .string("cat"), "max": .number(1), "auto-land": .bool(true), "queue": .bool(true)]) }
            let chain = WorkLoop.Chain(next: w.id, max: 2, perDay: nil, chained: 1, budget: nil, after: "A")
            let before = Date()
            let queued = try await run()
            #expect(queued.ok, "\(queued)")
            let l0 = try #require(try await d.router.work.get(w.id)?.loop)
            let approved = try #require(l0.autoLand?.approvedAt)
            #expect(l0.state == .queued && approved >= before.addingTimeInterval(-1))

            let r = try await call(p, x.s, "work.stop")
            guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
            #expect(o["state"] == .string("dequeued"))
            var out = try #require(try await d.router.work.get(w.id))
            #expect(out.loop?.state == .queued && out.loop?.stopReason == nil && out.loop?.endedAt == nil)
            #expect(out.loop?.autoLand?.approvedAt == approved && out.loop?.autoLand?.dequeuedAt != nil)
            #expect(out.notes.last?.text.contains("fora da fila") == true)
            #expect(!WorkLoop.activate(&out, chain, at: Date()), "a chain never activates a dequeued work")
            #expect(try await call(p, x.s, "work.stop").error?.code == .invalidArgs)

            #expect(try await run().ok)
            var back = try #require(try await d.router.work.get(w.id))
            #expect(back.loop?.state == .queued && back.loop?.autoLand?.dequeuedAt == nil && back.loop?.autoLand?.approvedAt != nil)
            #expect(WorkLoop.activate(&back, chain, at: Date()))
        }
    }

    /// C3b: a queued work's approval is the card's answer: `approvedAt` is written then, not at `work run`.
    @Test func theCardsAnswerIsTheQueuedWorksApproval() async throws {
        try await withDaemon { d, p in
            let x = try await factoryPaddock(d, p, "card"); defer { try? FileManager.default.removeItem(at: x.repo) }
            #expect(try await call(p, x.s, "work.start", ["title": .string("Card")]).ok)
            #expect(try await call(p, x.s, "work.task.add", ["title": .string("A"), "check": .string("true"), "green-ok": .bool(true)]).ok)
            let w = try #require(try await d.router.work.active(terminal: UUID(uuidString: x.s.id)!))
            #expect(try await call(p, x.s, "work.run", ["command": .string("cat"), "max": .number(1), "auto-land": .bool(true), "queue": .bool(true)]).ok)
            _ = await waitFor(20) { await d.router.appCards.contains { $0.app == "work-loop" } }
            let card = try #require(await d.router.appCards.first { $0.app == "work-loop" }, "no approval card")
            #expect(try await d.router.work.get(w.id)?.loop?.autoLand?.approvedAt == nil)
            let asked = Date()
            #expect(try await send(p, Request(id: "a", token: d.adminToken, command: "admin.app.answer",
                                              args: ["id": .string(card.id.uuidString), "allow": .bool(true), "always": .bool(false)])).ok)
            #expect(await waitFor(20) { (try? await d.router.work.get(w.id))?.loop?.autoLand?.approvedAt != nil })
            let l = try #require(try await d.router.work.get(w.id)?.loop)
            #expect(l.state == .queued && l.autoLand!.approvedAt! >= asked.addingTimeInterval(-1))
        }
    }

    /// C3b: the daily cap through `work run` itself, three times on one paddock (`perDay` 2): each run is the card's
    /// (answered by the owner), its land the router's (`Paddock.autoLands`); nothing seeded but the base
    /// an earlier run's attempt left (`baseHead`, carried to the new run, which here makes no attempt: its task was
    /// done by hand and reviewed). The third stops as `landDailyCap`.
    @Test func theDailyCapCountsTheLandsOfRealWorkRuns() async throws {
        try await withDaemon { d, p in
            let x = try await factoryPaddock(d, p, "cap", perDay: 2); defer { try? FileManager.default.removeItem(at: x.repo) }
            var stops: [WorkLoopState.Stop.Code?] = []
            for i in 1...3 {
                #expect(try await call(p, x.s, "work.start", ["title": .string("W\(i)")]).ok)
                #expect(try await call(p, x.s, "work.task.add", ["title": .string("T\(i)"), "check": .string("true"), "green-ok": .bool(true)]).ok)
                let w = try #require(try await d.router.work.active(terminal: UUID(uuidString: x.s.id)!))
                // an earlier run's attempt began on the base as it is now
                let base = try await GitRunner.run(["rev-parse", "main"], in: x.repo).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                try await d.router.work.update(w.id) {
                    var l = WorkLoopState(state: .finished, tries: 1, timeout: 60, tasks: []); l.autoLand = .init(gate: "true"); l.autoLand?.baseHead = base
                    $0.loop = l
                }
                try await commit("t\(i).swift", "let t = \(i)\n", in: x.dir)
                let run = try await call(p, x.s, "work.run", ["command": .string("cat"), "max": .number(1), "auto-land": .bool(true)])
                #expect(run.ok, "\(run)")
                _ = await waitFor(20) { await d.router.appCards.contains { $0.app == "work-loop" } }
                let card = try #require(await d.router.appCards.first { $0.app == "work-loop" }, "no approval card")
                // the task done by hand and reviewed at the paddock's HEAD before the owner answers
                let head = try await GitRunner.run(["rev-parse", "HEAD"], in: x.dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                try await d.router.work.update(w.id) {
                    $0.tasks[0].state = .done; $0.tasks[0].reviewClean = true; $0.tasks[0].review = "ok"; $0.tasks[0].reviewedHead = head
                }
                #expect(try await send(p, Request(id: "a", token: d.adminToken, command: "admin.app.answer",
                                                  args: ["id": .string(card.id.uuidString), "allow": .bool(true), "always": .bool(false)])).ok)
                _ = await waitFor(30) { let l = (try? await d.router.work.get(w.id))?.loop; return l?.endedAt != nil && l?.state != .running }
                _ = await waitFor(10) { await d.router.loopPaddocks.isEmpty }
                let l = try await d.router.work.get(w.id)?.loop
                #expect(l?.autoLand?.baseHead == base, "a run with no attempt keeps the base the last one began on")
                stops.append(l?.stopReason?.code)
                // a land closes the paddock's works by merge; the one that did not land is closed here
                if try await d.router.work.get(w.id)?.closedAt == nil { #expect(try await call(p, x.s, "work.done").ok) }
            }
            #expect(stops == [.landed, .landed, .landDailyCap], "\(stops)")
            #expect(await d.router.loopAutoLands(x.pid).count == 2)
        }
    }

    @Test func refusesNoFactoryNoGateAndNoReview() async throws {
        try await withDaemon { d, p in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            let m = try await spawn(d, p, "M", cwd: repo)
            #expect(try await call(p, m, "paddock.create", ["name": .string("fab")]).ok)
            let s = try await spawn(d, p, "S", paddock: "fab")
            #expect(try await call(p, s, "work.start", ["title": .string("Auto")]).ok)
            #expect(try await call(p, s, "work.task.add", ["title": .string("A"), "check": .string("true"), "green-ok": .bool(true)]).ok)
            let dir = repo.appendingPathComponent(".collie/paddocks/fab")
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(CommandRouter.personasDir), withIntermediateDirectories: true)
            try await commit(CommandRouter.personasDir + "correcao.md", "x\n", in: dir)
            func run(_ extra: [String: JSONValue] = [:]) async throws -> Response {
                try await call(p, s, "work.run", ["command": .string("cat"), "max": .number(3), "auto-land": .bool(true), "review": .bool(true)].merging(extra) { $1 })
            }
            // the paddock has no factory mark
            let notFactory = try await run()
            #expect(!notFactory.ok && notFactory.error?.message.contains("fábrica") == true, "\(notFactory)")
            // marked, but the committed profile has no gate
            let pid = try #require(await d.router.ws.paddocks.first { $0.name == "fab" }?.id)
            await d.router.setFactoryMark(pid, true)
            let noGate = try await run()
            #expect(!noGate.ok && noGate.error?.message.contains("'gate'") == true, "\(noGate)")
            // a gate, and --no-review
            try await commit("collie-work.json", #"{"gate": "true"}"#, in: dir)
            let noReview = try await run(["review": .bool(false), "no-review": .bool(true)])
            #expect(!noReview.ok && noReview.error?.message.contains("exige revisão") == true, "\(noReview)")
            #expect(await d.router.appCards.isEmpty, "no approval card for a refused run")
            #expect(await d.router.loopPaddocks.isEmpty, "the paddock is not left reserved")
        }
    }
}
