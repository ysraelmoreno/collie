import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// F5, `work plan apply`: tasks made from a package only once it passes the linter and only with the hash the owner
/// approved; each wave needs the one before; the loop is never started. A store in a temporary folder, no terminal.
@Suite struct PlanApplyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func store() async throws -> (WorkStore, UUID, URL) {
        let dir = URL(fileURLWithPath: "/tmp/collie-apply-\(UUID().uuidString.prefix(8))")
        let s = WorkStore(dir: dir)
        let w = try await s.start(title: "W", terminal: UUID(), paddockId: nil, branch: nil)
        return (s, w.id, dir)
    }
    private func noArea(_ a: [String]) throws -> String { throw ProtocolError(code: .invalidArgs, message: "sem collie-work.json") }

    @Test func aWrongHashIsRefusedAndCreatesNothing() async throws {
        let f = try PlanFixture(waves: PlanFixture.waves, tasks: PlanFixture.good); defer { f.cleanup() }
        let (s, id, dir) = try await store(); defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: ProtocolError.self) {
            _ = try await PlanApply.apply(dir: f.dir, approve: String(repeating: "0", count: 64), work: id, store: s, now: now, areaCheck: noArea)
        }
        // the package changed after the owner saw it: the hash they approved is refused too
        let seen = PlanLint.lint(f.dir).hash
        try f.write("tasks/api.md", PlanFixture.card("API", check: "swift test --filter OutraTests"))
        await #expect(throws: ProtocolError.self) {
            _ = try await PlanApply.apply(dir: f.dir, approve: seen, work: id, store: s, now: now, areaCheck: noArea)
        }
        let w = try #require(try await s.get(id))
        #expect(w.tasks.isEmpty && w.plan == nil && w.notes.isEmpty)
    }

    @Test func aPackageTheLinterRefusesCreatesNothing() async throws {
        var t = PlanFixture.good; t["api"] = "# API\n\nSem check. Prova: ApiTests.\n"
        let f = try PlanFixture(waves: PlanFixture.waves, tasks: t); defer { f.cleanup() }
        let (s, id, dir) = try await store(); defer { try? FileManager.default.removeItem(at: dir) }
        let hash = PlanLint.lint(f.dir).hash
        await #expect(throws: ProtocolError.self) {
            _ = try await PlanApply.apply(dir: f.dir, approve: hash, work: id, store: s, now: now, areaCheck: noArea)
        }
        #expect(try await s.get(id)?.tasks.isEmpty == true)
    }

    @Test func theTasksNeedTheWaveBefore() async throws {
        let f = try PlanFixture(waves: PlanFixture.waves, tasks: PlanFixture.good); defer { f.cleanup() }
        let (s, id, dir) = try await store(); defer { try? FileManager.default.removeItem(at: dir) }
        let hash = PlanLint.lint(f.dir).hash
        let (plan, built) = try await PlanApply.apply(dir: f.dir, approve: hash.uppercased(), work: id, store: s, now: now, areaCheck: noArea)
        #expect(plan.hash == hash && built.map(\.id) == ["login", "api", "tela"])
        let w = try #require(try await s.get(id))
        #expect(w.tasks.map(\.id) == ["login", "api", "tela"] && w.tasks.allSatisfy { $0.state == .open })
        #expect(w.tasks[0].needs == nil && w.tasks[1].needs == nil && w.tasks[2].needs == ["login", "api"])
        #expect(w.tasks[0].check == "swift test --filter LoginTests" && w.tasks[0].title == "Login")
        #expect(w.tasks[2].accept == "curl -fsS localhost:8080/health")
        #expect(w.tasks[0].spec == SignedAppCheck.realPath(f.dir.appendingPathComponent("tasks/login.md")))
        #expect(w.plan == WorkPlan(dir: f.dir.path, sha256: hash, appliedAt: now, tasks: ["login", "api", "tela"]))
        #expect(w.notes.last?.text.contains("pacote sha256 \(hash)") == true)
        // applied twice: the ids are taken, nothing more is created
        await #expect(throws: ProtocolError.self) {
            _ = try await PlanApply.apply(dir: f.dir, approve: hash, work: id, store: s, now: now, areaCheck: noArea)
        }
        #expect(try await s.get(id)?.tasks.count == 3)
    }

    @Test func itNeverStartsTheLoop() async throws {
        let f = try PlanFixture(waves: PlanFixture.waves, tasks: PlanFixture.good); defer { f.cleanup() }
        let (s, id, dir) = try await store(); defer { try? FileManager.default.removeItem(at: dir) }
        let hash = PlanLint.lint(f.dir).hash
        _ = try await PlanApply.apply(dir: f.dir, approve: hash, work: id, store: s, now: now, areaCheck: noArea)
        let w = try #require(try await s.get(id))
        #expect(w.loop == nil && w.jobs.isEmpty)
        // a running (or queued) loop's approved tasks are not changed under it
        let (s2, id2, dir2) = try await store(); defer { try? FileManager.default.removeItem(at: dir2) }
        try await s2.update(id2) { $0.loop = WorkLoopState(state: .running) }
        await #expect(throws: ProtocolError.self) {
            _ = try await PlanApply.apply(dir: f.dir, approve: hash, work: id2, store: s2, now: now, areaCheck: noArea)
        }
        #expect(try await s2.get(id2)?.tasks.isEmpty == true)
    }

    @Test func anAreaBuildsTheCheck() throws {
        var t = PlanFixture.good; t["api"] = "# API\n\narea: api, quadro\n\nProva: ApiTests.\n"
        let f = try PlanFixture(waves: PlanFixture.waves, tasks: t); defer { f.cleanup() }
        let p = PlanLint.lint(f.dir)
        let built = try PlanApply.tasks(p, approve: p.hash, existing: [], now: now) { "make " + $0.joined(separator: " && make ") }
        #expect(built[1].check == "make api && make quadro")
        #expect(throws: ProtocolError.self) { try PlanApply.tasks(p, approve: p.hash, existing: [], now: now, areaCheck: noArea) }
    }

    /// C4a: `plan apply` revalidates each task's `spec` (its card, links resolved) against the project.
    @Test func aSpecOutOfTheProjectIsRefused() throws {
        let f = try PlanFixture(waves: PlanFixture.waves, tasks: PlanFixture.good); defer { f.cleanup() }
        let p = PlanLint.lint(f.dir)
        #expect(throws: ProtocolError.self) {
            try PlanApply.tasks(p, approve: p.hash, existing: [], now: now, root: f.dir.appendingPathComponent("outro"), areaCheck: noArea)
        }
        #expect(try PlanApply.tasks(p, approve: p.hash, existing: [], now: now, root: f.dir, areaCheck: noArea).count == 3)
    }

    /// C4a: `work run` of a work with a PRD: a task added after the plan (`work task add`) passes the linter's check rule,
    /// and each task of the plan still runs its own card (whose content is in the approved hash).
    @Test func tasksAddedAfterThePlanPassTheCheckRule() throws {
        let f = try PlanFixture(waves: PlanFixture.waves, tasks: PlanFixture.good); defer { f.cleanup() }
        let p = PlanLint.lint(f.dir)
        var w = Work(title: "W", terminalId: UUID())
        w.prd = [WorkPrd(sha256: String(repeating: "a", count: 64), bytes: 3)]
        w.tasks = try PlanApply.tasks(p, approve: p.hash, existing: [], now: now, areaCheck: noArea)
        w.plan = WorkPlan(dir: f.dir.path, sha256: p.hash, tasks: ["login", "api", "tela"])
        #expect(CommandRouter.prdPlanRefusal(w) == nil)
        for c in ["grep -q rota Sources/Api.swift || true", "swift test --filter X; true", "grep -q x a.swift && echo ok", "true"] {
            var x = w; x.tasks.append(WorkTask(id: "depois", title: "Depois", check: c))
            #expect(CommandRouter.prdPlanRefusal(x)?.contains("adicionada depois do plano aprovado") == true, "\(c)")
            x.tasks[3].state = .done   // the loop takes no done task
            #expect(CommandRouter.prdPlanRefusal(x) == nil, "\(c)")
        }
        var ok = w; ok.tasks.append(WorkTask(id: "depois", title: "Depois", check: "swift test --filter DepoisTests"))
        #expect(CommandRouter.prdPlanRefusal(ok) == nil)
        // a planned task whose spec no longer is its card
        var moved = w; moved.tasks[1].spec = "/tmp/outra-spec.md"
        #expect(CommandRouter.prdPlanRefusal(moved)?.contains("não aponta mais para o seu cartão") == true)
    }

    @Test func workRunOfAWorkWithAPrdRunsTheApprovedPlan() throws {
        let f = try PlanFixture(waves: PlanFixture.waves, tasks: PlanFixture.good); defer { f.cleanup() }
        var w = Work(title: "W", terminalId: UUID())
        #expect(CommandRouter.prdPlanRefusal(w) == nil)   // no PRD: as before
        w.prd = [WorkPrd(sha256: String(repeating: "a", count: 64), bytes: 3)]
        #expect(CommandRouter.prdPlanRefusal(w)?.contains("plan apply") == true)   // a PRD, no plan applied
        let hash = PlanLint.lint(f.dir).hash
        w.plan = WorkPlan(dir: f.dir.path, sha256: hash, tasks: ["login", "api", "tela"])
        #expect(CommandRouter.prdPlanRefusal(w) == nil)
        try f.write("tasks/api.md", PlanFixture.card("API", check: "swift test --filter OutraTests"))
        #expect(CommandRouter.prdPlanRefusal(w)?.contains("mudou depois de aprovado") == true)
        try f.write("tasks/api.md", "# API\n\nSem check. Prova: ApiTests.\n")
        #expect(CommandRouter.prdPlanRefusal(w)?.contains("não passa mais no linter") == true)
    }
}
