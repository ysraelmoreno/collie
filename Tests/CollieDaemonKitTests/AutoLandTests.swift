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
        #expect(w.tasks[0].state == .done, sourceLocation: at)
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
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .deferred && w.loop?.stopReason == nil && w.loop?.autoLand?.after == nil)
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
        #expect(await r.run() == .finished)
        let w = try await r.get()
        #expect(w.tasks[0].state == .done && w.loop?.autoLand?.after == nil && w.loop?.stopReason == nil)
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

    @Test func theDailyCapReachedLandsNothing() async throws {
        let r = try await Self.rig(perDay: 1); defer { r.cleanup() }
        try await Self.pastLands(r, hoursAgo: [2])
        try await Self.expectStopped(r, .landDailyCap)
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

    @Test func refusesNoFactoryNoGateAndNoReview() async throws {
        try await withDaemon { d, p in
            let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
            let m = try await spawn(d, p, "M", cwd: repo)
            #expect(try await call(p, m, "paddock.create", ["name": .string("fab")]).ok)
            let s = try await spawn(d, p, "S", paddock: "fab")
            #expect(try await call(p, s, "work.start", ["title": .string("Auto")]).ok)
            #expect(try await call(p, s, "work.task.add", ["title": .string("A"), "check": .string("true")]).ok)
            let dir = repo.appendingPathComponent(".collie/paddocks/fab")
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(CommandRouter.personasDir), withIntermediateDirectories: true)
            try await commit(CommandRouter.personasDir + "correcao.md", "x\n", in: dir)
            func run(_ extra: [String: JSONValue] = [:]) async throws -> Response {
                try await call(p, s, "work.run", ["max": .number(3), "auto-land": .bool(true), "review": .bool(true)].merging(extra) { $1 })
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
