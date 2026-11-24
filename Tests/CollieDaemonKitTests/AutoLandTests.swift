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
    private static func rig(gate: String = "true", ci: String = "true", review: Bool = true) async throws -> LoopRig {
        let r = try await LoopRig([WorkTask(id: "a", title: "Task a", check: "true")], tries: 1)
        let p = r.repo.appendingPathComponent(CommandRouter.personasDir)
        try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
        try "---\nname: correcao\nmodel: sonnet\npaths: [\"**\"]\n---\nCorpo\n".write(to: p.appendingPathComponent("correcao.md"), atomically: true, encoding: .utf8)
        try await commit("spec.md", "SPEC\n", in: r.repo)
        let spec = r.repo.appendingPathComponent("spec.md").path
        try await r.store.update(r.work) {
            $0.tasks[0].spec = spec
            $0.loop?.review = review ? true : nil
            $0.loop?.autoLand = WorkLoopState.AutoLand(gate: gate, ci: ci, timeout: 60)
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
}
