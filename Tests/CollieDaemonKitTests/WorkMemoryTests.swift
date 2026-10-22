import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var name: String; var token: String }

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "x", token: d.adminToken, command: cmd, args: args), timeoutSeconds: 60)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL, floor: String? = nil) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path)]
    if let floor { args["floor"] = .string(floor) }
    let r = try await admin(d, p, "admin.spawn", args)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, name: name, token: try await tokenOf(d, id))
}
private func work(_ d: Daemon, _ p: Paths, _ cmd: String, _ t: Term, _ args: [String: String] = [:]) async throws {
    let r = try await send(p, Request(id: "w", token: d.adminToken, command: cmd,
                                      args: args.merging(["terminal": t.name]) { a, _ in a }.mapValues { .string($0) }), timeoutSeconds: 60)
    #expect(r.ok, "\(cmd): \(r)")
}
private func records(_ d: Daemon, _ repo: URL) async throws -> [MemoryRecord] {
    let r = await d.router.memory.repo(for: repo.path)
    return try await r.run { $0.store.all().records }.filter { $0.origin == "Collie (resumo)" }
}
private func saved(_ d: Daemon, _ repo: URL, count: Int = 1) async throws -> [MemoryRecord] {
    _ = await waitFor(10) { ((try? await records(d, repo))?.count ?? 0) >= count }
    return try await records(d, repo)
}
/// The daemon's decisions so far, once there are `n` of them.
private func decisions(_ d: Daemon, _ n: Int = 1) async -> [String] {
    _ = await waitFor(10) { await d.router.summaryDecisions.count >= n }
    return await d.router.summaryDecisions
}

@Suite(.serialized) struct WorkMemoryTests {
    @Test func closingSavesSummary() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            try await work(d, p, "work.start", t, ["title": "Feature A"])
            try await work(d, p, "work.task.add", t, ["title": "Write tests"])
            try await work(d, p, "work.done", t)
            let recs = try await saved(d, repo)
            let r = try #require(recs.first)
            #expect(recs.count == 1 && r.kind == .decision && !r.reviewed && r.scope == .project)
            #expect(r.title == "Resumo: Feature A" && r.origin == "Collie (resumo)")
            #expect(r.body.contains("Feature A") && r.body.contains("Write tests"), "\(r.body)")
            #expect(r.subject.hasPrefix("trabalho "))
            let file = repo.appendingPathComponent(".collie/memory/decision")
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func mergeCloseSavesToo() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            #expect(try await admin(d, p, "floor.create", ["name": .string("feat"), "repo": .string(repo.path)]).ok)
            let floor = repo.appendingPathComponent(".collie/floors/feat")
            let t = try await term(d, p, "F", cwd: floor, floor: "feat")
            try await work(d, p, "work.start", t, ["title": "Floor job"])
            try await work(d, p, "work.task.add", t, ["title": "Do it"])
            try "x\n".write(to: floor.appendingPathComponent("g.txt"), atomically: true, encoding: .utf8)
            _ = try await GitRunner.run(["add", "."], in: floor)
            _ = try await GitRunner.run(["commit", "-m", "g"], in: floor)
            let land = try await admin(d, p, "floor.land", ["name": .string("feat")])
            #expect(land.ok, "\(land)")
            let recs = try await saved(d, floor)
            let r = try #require(recs.first)
            #expect(recs.count == 1 && r.scope == .floor && r.floor == "feat" && r.title == "Resumo: Floor job" && !r.reviewed)
            #expect(r.body.contains("Mergeado"))
        }
    }

    @Test func reclosingSupersedes() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            try await work(d, p, "work.start", t, ["title": "Again"])
            try await work(d, p, "work.task.add", t, ["title": "First"])
            try await work(d, p, "work.done", t)
            let first = try await saved(d, repo)
            #expect(first.count == 1)
            try await work(d, p, "work.reopen", t)
            try await work(d, p, "work.task.add", t, ["title": "Second"])
            try await work(d, p, "work.done", t)
            _ = await waitFor(10) { ((try? await records(d, repo))?.contains { $0.body.contains("Second") }) ?? false }
            let all = try await records(d, repo)
            #expect(all.count == 2 && all.filter { $0.status == .active }.count == 1)
            #expect(all.first { $0.status == .active }?.body.contains("Second") == true)
            #expect(all.first { $0.status == .superseded }?.body.contains("Second") == false)
        }
    }

    @Test func emptyWorkNotSaved() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            try await work(d, p, "work.start", t, ["title": "Nothing"])
            try await work(d, p, "work.done", t)
            #expect(await decisions(d) == ["empty"])
            #expect(try await records(d, repo).isEmpty)
        }
    }

    @Test func noRepoNoSave() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collie-norepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: dir)
            try await work(d, p, "work.start", t, ["title": "Loose"])
            try await work(d, p, "work.task.add", t, ["title": "x"])
            try await work(d, p, "work.done", t)
            #expect(await decisions(d) == ["no-repo"])
            let g = await d.router.memory.global
            #expect(try await g.run { $0.store.all().records }.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".collie").path))
        }
    }

    @Test func saveFailureWarnsInChat() async throws {
        let repo = try await makeRepo()
        try "not a directory".write(to: repo.appendingPathComponent(".collie"), atomically: true, encoding: .utf8)   // the store cannot be created
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            try await work(d, p, "work.start", t, ["title": "Broken"])
            try await work(d, p, "work.task.add", t, ["title": "x"])
            try await work(d, p, "work.done", t)
            #expect(await decisions(d) == ["failed"])
            let warned = await waitFor(10) { ((try? await d.router.chat.page(before: nil, limit: 50)) ?? []).contains { $0.role == .collie } }
            let msgs = try await d.router.chat.page(before: nil, limit: 50)
            #expect(warned && msgs.contains { $0.text == "Não consegui guardar o resumo de Broken na Memória." }, "\(msgs.map(\.text))")
            let w = try #require(try await d.router.work.list(includeClosed: true).first)
            #expect(w.closedAt != nil)   // the close stays
        }
    }

    @Test func removedGroundTerminalStillSaves() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            try await work(d, p, "work.start", t, ["title": "Ground"])
            try await work(d, p, "work.task.add", t, ["title": "Do it"])
            #expect(try await admin(d, p, "admin.kill", ["target": .string("T")]).ok)
            let recs = try await saved(d, repo)
            #expect(recs.count == 1 && recs.first?.title == "Resumo: Ground" && recs.first?.scope == .project)
            #expect(await decisions(d) == ["saved"])
        }
    }

    @Test func memoryBodyHasNoEscapes() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let t = try await term(d, p, "T", cwd: repo)
            try await work(d, p, "work.start", t, ["title": "fix(parser) snake_case"])
            try await work(d, p, "work.task.add", t, ["title": "fix(parser) snake_case"])
            try await work(d, p, "work.done", t)
            let r = try #require(try await saved(d, repo).first)
            #expect(!r.body.contains("\\") && !r.title.contains("\\"), "\(r.body)")
            #expect(r.title == "Resumo: fix(parser) snake_case" && r.body.contains("fix(parser) snake_case"))
        }
    }
}
