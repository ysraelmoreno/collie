import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let flow = ["Escrever teste falhando", "Implementar", "Rodar filtro", "Commit"]
/// `flow` with other tasks between its steps (different in each work).
private func work(_ i: Int) -> [String] {
    let w = ["alfa", "beta", "gama"][i % 3]
    return ["Ler o plano \(w)", flow[0], "Ajustar tipos \(w)", flow[1], flow[2], "Revisar diff \(w)", flow[3]]
}
private func steps(_ titles: [String]) -> [String] { titles.map(ProcedureDetector.step).filter { !$0.isEmpty } }
private func all(_ s: RepoMemory) async throws -> [MemoryRecord] { try await s.run { $0.store.all().records } }
private func createProcedure() -> CuratorOutput {
    CuratorOutput(json: .object(["ops": .array([.object([
        "op": .string("create"), "kind": .string("procedure"), "scope": .string("project"), "title": .string("Ciclo de TDD"),
        "body": .string("Escreva o teste falhando\nImplemente\nRode o filtro\nCommite"), "howToApply": .string("implementar uma tarefa"),
    ])])]), inputTokens: 10, outputTokens: 5, costUSD: 0.0001)
}
/// A closed work of `terminal` with tasks `titles`.
private func closedWork(_ d: Daemon, _ terminal: UUID, _ title: String, _ titles: [String]) async throws {
    let w = try await d.router.work.start(title: title, terminal: terminal, paddockId: nil, branch: nil)
    try await d.router.work.update(w.id) { $0.tasks = titles.enumerated().map { WorkTask(id: "t\($0.offset)", title: $0.element, state: .done) } }
    try await d.router.work.close(w.id, by: "app")
}
private func spawn(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL) async throws -> UUID {
    let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn", args: [
        "name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path)]), to: p.socket, timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"], let u = UUID(uuidString: id) else { throw ProtocolError(code: .internal, message: "\(r)") }
    return u
}

@Suite struct ProcedureDetectorTests {
    @Test func stepNormalized() {
        #expect(ProcedureDetector.step("Rodar o filtro (2x)!") == "rodar filtro")
        #expect(ProcedureDetector.step("1. Implementar") == "implementar")
        #expect(ProcedureDetector.step("a b c um dois três quatro cinco seis sete") == "dois três quatro cinco seis sete")
    }

    @Test func findsSequenceInThreeWorks() {
        let r = ProcedureDetector.recurring((0..<3).map { steps(work($0)) })
        #expect(r == [steps(flow)], "\(r)")
    }

    @Test func twoWorksNotEnough() {
        #expect(ProcedureDetector.recurring((0..<2).map { steps(work($0)) }).isEmpty)
        #expect(ProcedureDetector.recurring((0..<3).map { _ in steps(["Implementar", "Commit"]) }).isEmpty)   // < 3 steps
    }

    @Test func subsequencesCollapsed() {
        // the first three steps in a 4th work too: still one sequence (the longest), its subsequences dropped
        let works = (0..<3).map { steps(work($0)) } + [steps(Array(flow.prefix(3)))]
        #expect(ProcedureDetector.recurring(works) == [steps(flow)])
    }
}

@Suite(.serialized) struct ProcedureNoticedTests {
    /// The daily consolidation finds the sequence, the curator names it; it waits for the user (`proposed`), and the same
    /// sequence is never sent again.
    @Test func curatorNamesProcedure() async throws {
        let repo = try await makeRepo()
        let f = FakeCurator(); f.output = createProcedure()
        try await withDaemon(configure: { $0.curatorRunner = f }) { d, p in
            let a = try await spawn(d, p, "A", cwd: repo)
            for i in 0..<3 { try await closedWork(d, a, "Trabalho \(i)", work(i)) }
            let store = await d.router.memory.repo(for: repo.path)
            await d.router.consolidate(store)
            #expect(await waitFor(10) { (try? await all(store))?.contains { $0.kind == .procedure } == true })
            let input = try #require(f.inputs.first { $0.contains("Passos repetidos") })
            #expect(flow.allSatisfy { input.contains($0) } && (0..<3).allSatisfy { input.contains("Trabalho \($0)") }, "\(input)")
            let proc = try #require(try await all(store).first { $0.kind == .procedure })
            #expect(proc.status == .proposed && proc.scope == .project && proc.title == "Ciclo de TDD")
            #expect(proc.body.hasPrefix("Quando: implementar uma tarefa\n\n1. Escreva o teste falhando"), "\(proc.body)")
            let sent = f.inputs.filter { $0.contains("Passos repetidos") }.count
            await d.router.consolidate(store)
            try await Task.sleep(for: .milliseconds(300))
            #expect(f.inputs.filter { $0.contains("Passos repetidos") }.count == sent)
            #expect(try await all(store).filter { $0.kind == .procedure }.count == 1)
        }
    }

    @Test func droppedNothingAndNotResent() async throws {
        let repo = try await makeRepo()
        let f = FakeCurator()   // {"ops":[]}
        try await withDaemon(configure: { $0.curatorRunner = f }) { d, p in
            let a = try await spawn(d, p, "A", cwd: repo)
            for i in 0..<3 { try await closedWork(d, a, "Trabalho \(i)", work(i)) }
            let store = await d.router.memory.repo(for: repo.path)
            await d.router.consolidate(store)
            #expect(await waitFor(10) { f.inputs.contains { $0.contains("Passos repetidos") } })
            #expect(await waitFor(10) { await d.router.curator.queued(kind: .procedure).isEmpty })
            #expect(try await all(store).allSatisfy { $0.kind != .procedure })
            await d.router.consolidate(store)
            try await Task.sleep(for: .milliseconds(300))
            #expect(f.inputs.filter { $0.contains("Passos repetidos") }.count == 1)
            let seen = p.root.appendingPathComponent("learning/procedures.json")
            #expect(FileManager.default.fileExists(atPath: seen.path))
        }
    }

    @Test func otherProjectsIgnored() async throws {
        let repo = try await makeRepo(), other = try await makeRepo()
        let f = FakeCurator(); f.output = createProcedure()
        try await withDaemon(configure: { $0.curatorRunner = f }) { d, p in
            let b = try await spawn(d, p, "B", cwd: other)
            for i in 0..<3 { try await closedWork(d, b, "Trabalho \(i)", work(i)) }
            let store = await d.router.memory.repo(for: repo.path)
            await d.router.consolidate(store)
            try await Task.sleep(for: .milliseconds(300))
            #expect(!f.inputs.contains { $0.contains("Passos repetidos") })
            #expect(await d.router.curator.queued(kind: .procedure).isEmpty)
        }
    }
}
