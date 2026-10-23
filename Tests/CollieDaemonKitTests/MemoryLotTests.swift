import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL, shepherd: Bool = false) async throws -> Term {
    let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn", args: [
        "name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path), "shepherd": .bool(shepherd)]), to: p.socket, timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func obj(_ r: Response) -> [String: JSONValue] { if case .object(let o)? = r.result { return o }; return [:] }
private func s(_ v: JSONValue?) -> String? { if case .string(let x)? = v { return x }; return nil }
private func rows(_ r: Response) -> [[String: JSONValue]] {
    guard case .array(let a)? = r.result else { return [] }
    return a.compactMap { if case .object(let o) = $0 { return o }; return nil }
}
private func listed(_ r: Response) -> [[String: JSONValue]] {
    guard case .array(let a)? = obj(r)["records"] else { return [] }
    return a.compactMap { if case .object(let o) = $0 { return o }; return nil }
}
private func titles(_ r: Response) -> [String] { rows(r).compactMap { s($0["title"]) }.sorted() }
private func output(_ r: Response) -> String { s(obj(r)["output"]) ?? "<\(r)>" }
private func save(_ p: Paths, _ t: Term, _ subject: String, _ title: String, body: String = "", scope: String? = nil) async throws -> [String: JSONValue] {
    var a = ["kind": "decision", "subject": subject, "title": title, "body": body]
    if let scope { a["scope"] = scope }
    let r = try await call(p, t, "memory.save", a)
    #expect(r.ok, "\(r)")
    return obj(r)
}
private func lotId(_ d: Daemon, _ name: String) async -> UUID { await d.router.ws.lots.first { $0.name == name }!.id }
private func mode(_ path: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int) ?? -1 }
private func rec(_ title: String, scope: MemoryScope = .project, lot: UUID? = nil, status: MemoryStatus = .active, pinned: Bool = false,
                 body: String = "", age: TimeInterval = 0) -> MemoryRecord {
    MemoryRecord(kind: .decision, scope: scope, lotId: lot, subject: title, title: title, body: body, status: status, pinned: pinned,
                 createdAt: Date().addingTimeInterval(-age))
}

@Suite(.serialized) struct MemoryLotTests {
    @Test func saveDefaultsToCallersLot() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo), b = try await term(d, p, "B", cwd: repo)
            #expect(try await admin(d, p, "lot.create", ["name": "Login", "members": "A"]).ok)
            let o = try await save(p, a, "css", "Use Tailwind")
            let lid = await lotId(d, "Login")
            #expect(s(o["scope"]) == "lot" && s(o["lot"]) == "Login" && s(o["lotId"]) == lid.uuidString, "\(o)")
            let file = try #require(s(o["file"]))
            let lotDir = p.root.appendingPathComponent("lots/\(lid.uuidString.lowercased())")
            #expect(file.hasPrefix(lotDir.path + "/memory/"))
            #expect(mode(file) == 0o600 && mode(lotDir.path) == 0o700 && mode(URL(fileURLWithPath: file).deletingLastPathComponent().path) == 0o700)
            #expect(s(try await save(p, b, "db", "Use Postgres")["scope"]) == "project")   // no lot: project
            #expect(s(try await save(p, a, "db2", "Use Redis", scope: "project")["scope"]) == "project")
            #expect(try await call(p, b, "memory.save", ["kind": "decision", "subject": "x", "title": "x", "scope": "lot"]).error?.code == .invalidArgs)
        }
    }

    /// Review Focus 1: two lots in one pasture; B never sees A's lot memories, by hook or by a flagless search.
    @Test func otherLotNeverInjected() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo), b = try await term(d, p, "B", cwd: repo)
            #expect(try await admin(d, p, "lot.create", ["name": "LA", "members": "A"]).ok)
            #expect(try await admin(d, p, "lot.create", ["name": "LB", "members": "B"]).ok)
            _ = try await save(p, a, "styling", "Tailwind everywhere", body: "tailwind utility classes")
            _ = try await save(p, b, "styling b", "Plain CSS for B", body: "tailwind avoided here")
            _ = try await save(p, b, "shared", "Tailwind project note", scope: "project")
            let ctx = output(try await call(p, b, "memory.hookContext"))
            #expect(!ctx.contains("Tailwind everywhere") && ctx.contains("Plain CSS for B"), "\(ctx)")
            let rel = output(try await call(p, b, "memory.hookRelevant", ["prompt": "tailwind utility classes everywhere"]))
            #expect(!rel.contains("Tailwind everywhere") && !rel.isEmpty, "\(rel)")
            #expect(titles(try await call(p, b, "memory.search", ["query": "tailwind"])) == ["Plain CSS for B", "Tailwind project note"])
            #expect(try await call(p, b, "memory.search", ["query": "tailwind", "lot": "LA"]).error?.code == .notFound)
            #expect(try await call(p, b, "memory.search", ["query": "tailwind", "lot": "Nope"]).error?.code == .notFound)
            #expect(!titles(try await call(p, b, "memory.search", ["query": "tailwind", "all": "true"])).contains("Tailwind everywhere"))
            #expect(try await call(p, b, "memory.list", ["lot": "LA"]).error?.code == .notFound)
        }
    }

    @Test func searchDefaultScope() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            #expect(try await admin(d, p, "lot.create", ["name": "LA", "members": "A"]).ok)
            _ = try await save(p, a, "q1", "Queue in lot", body: "queue")
            _ = try await save(p, a, "q2", "Queue in project", body: "queue", scope: "project")
            _ = try await save(p, a, "q3", "Queue global", body: "queue", scope: "global")
            let hits = rows(try await call(p, a, "memory.search", ["query": "queue"]))
            #expect(hits.compactMap { s($0["title"]) }.sorted() == ["Queue global", "Queue in lot", "Queue in project"])
            #expect(hits.filter { s($0["lot"]) == "LA" }.compactMap { s($0["title"]) } == ["Queue in lot"])
            #expect(titles(try await call(p, a, "memory.search", ["query": "queue", "lot": "LA"])) == ["Queue in lot"])
        }
    }

    @Test func searchAllLabelsLot() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo), b = try await term(d, p, "B", cwd: repo)
            let m = try await term(d, p, "M", cwd: repo, shepherd: true)
            #expect(try await admin(d, p, "lot.create", ["name": "LA", "members": "A"]).ok)
            #expect(try await admin(d, p, "lot.create", ["name": "LB", "members": "B"]).ok)
            #expect(try await admin(d, p, "admin.leash", ["a": "M", "b": "A"]).ok)
            _ = try await save(p, a, "k", "Kafka in A", body: "kafka")
            _ = try await save(p, b, "k", "Kafka in B", body: "kafka")
            let all = rows(try await admin(d, p, "memory.search", ["query": "kafka", "all": "true", "repo": repo.path]))
            #expect(Set(all.map { "\(s($0["title"]) ?? "")@\(s($0["lot"]) ?? "")" }) == ["Kafka in A@LA", "Kafka in B@LB"], "\(all)")
            #expect(try await admin(d, p, "memory.search", ["query": "kafka", "all": "true", "lot": "LA"]).error?.code == .invalidArgs)
            // a Shepherd: only lots whose every live member it reaches
            #expect(titles(try await call(p, m, "memory.search", ["query": "kafka", "lot": "LA"])) == ["Kafka in A"])
            #expect(try await call(p, m, "memory.search", ["query": "kafka", "lot": "LB"]).error?.code == .notFound)
            #expect(titles(try await call(p, m, "memory.search", ["query": "kafka", "all": "true"])) == ["Kafka in A"])
            #expect(titles(try await call(p, m, "memory.search", ["query": "kafka"])).isEmpty)   // no lot of its own
        }
    }

    /// Review Focus 2: supersession keys are (scope, lot, subject).
    @Test func supersedeIsPerLot() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo), b = try await term(d, p, "B", cwd: repo)
            #expect(try await admin(d, p, "lot.create", ["name": "LA", "members": "A"]).ok)
            #expect(try await admin(d, p, "lot.create", ["name": "LB", "members": "B"]).ok)
            let tw = try await save(p, a, "css framework", "Use Tailwind")
            #expect(try await save(p, b, "css framework", "Use CSS modules", scope: "project")["superseded"] == .null)
            #expect(try await save(p, b, "css framework", "B uses Bootstrap")["superseded"] == .null)
            let list = listed(try await call(p, a, "memory.list"))
            #expect(list.first { s($0["id"]) == s(tw["id"]) }.flatMap { s($0["status"]) } == "active")
            // the same key inside one lot does supersede
            #expect(s(try await save(p, a, "CSS  Framework", "Use UnoCSS")["superseded"]) == s(tw["id"]))
        }
    }

    @Test func agentPromotionIsUnreviewedAndUnpinned() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            #expect(try await admin(d, p, "lot.create", ["name": "LA", "members": "A"]).ok)
            let lot = try await save(p, a, "auth", "JWT", body: "x")
            #expect(try await admin(d, p, "memory.review", ["id": s(lot["id"])!, "lot": "LA", "action": "approve"]).ok)
            #expect(try await admin(d, p, "memory.pin", ["id": s(lot["id"])!, "lot": "LA"]).ok)
            let o = obj(try await call(p, a, "memory.promote", ["id": s(lot["id"])!]))
            #expect(o["pinned"] != .bool(true) && o["reviewed"] != .bool(true), "\(o)")
        }
    }

    @Test func promoteMovesToProject() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo), b = try await term(d, p, "B", cwd: repo)
            #expect(try await admin(d, p, "lot.create", ["name": "LA", "members": "A"]).ok)
            let lot = try await save(p, a, "auth", "JWT in cookies", body: "httponly")
            #expect(titles(try await call(p, b, "memory.search", ["query": "jwt"])).isEmpty)
            let r = try await call(p, a, "memory.promote", ["id": s(lot["id"])!])
            let o = obj(r)
            #expect(r.ok && s(o["scope"]) == "project" && s(o["supersedes"]) == s(lot["id"]) && o["lot"] == nil, "\(r)")
            #expect(titles(try await call(p, b, "memory.search", ["query": "jwt"])) == ["JWT in cookies"])
            let old = listed(try await call(p, a, "memory.list", ["status": "superseded"])).first { s($0["id"]) == s(lot["id"]) }
            #expect(old.flatMap { s($0["supersededBy"]) } == s(o["id"]))
            #expect(try await call(p, b, "memory.promote", ["id": s(lot["id"])!]).error?.code == .invalidArgs)   // B is in no lot
        }
    }

    @Test func proposedNotInjected() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            #expect(try await admin(d, p, "lot.create", ["name": "LA", "members": "A"]).ok)
            let store = await d.router.memory.lotStore(await lotId(d, "LA"))
            let prop = rec("Retry webhooks thrice", scope: .lot, lot: await lotId(d, "LA"), status: .proposed, pinned: true, body: "webhook retry")
            try await store.run { try $0.store.write(prop) }
            #expect(!output(try await call(p, a, "memory.hookContext")).contains("Retry webhooks"))
            #expect(output(try await call(p, a, "memory.hookRelevant", ["prompt": "webhook retry thrice"])).isEmpty)
            #expect(titles(try await call(p, a, "memory.search", ["query": "webhook"])).isEmpty)
            #expect(listed(try await call(p, a, "memory.list", ["status": "proposed"])).compactMap { s($0["title"]) } == ["Retry webhooks thrice"])
            #expect(try await admin(d, p, "memory.review", ["id": prop.id.uuidString, "action": "approve", "lot": "LA"]).ok)
            #expect(output(try await call(p, a, "memory.hookRelevant", ["prompt": "webhook retry thrice"])).contains("Retry webhooks"))
        }
    }

    @Test func contextPinnedThenIndex() async throws {
        let repo = try await makeRepo()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ml-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let mem = MemoryService(globalDir: root.appendingPathComponent("memory"))
        let lot = UUID()
        let project = await mem.repo(for: repo.path), lotStore = await mem.lotStore(lot)
        let pp = rec("Pinned project", pinned: true, body: "project body line"), up = rec("Unpinned project")
        let pl = rec("Pinned lot", scope: .lot, lot: lot, pinned: true, body: "lot body line")
        let old = rec("Older lot", scope: .lot, lot: lot, age: 100), new = rec("Newer lot", scope: .lot, lot: lot, age: 10)
        try await project.run { m in for r in [pp, up] { try m.store.write(r) } }
        try await lotStore.run { m in for r in [pl, old, new] { try m.store.write(r) } }
        let (text, ids) = await mem.contextText(cwd: repo.path, paddock: nil, lot: lot)
        #expect(text.contains("Pinned project: project body line") && text.contains("Pinned lot: lot body line"), "\(text)")
        #expect(!text.contains("Unpinned project"))
        let index = try #require(text.range(of: MemoryService.indexTitle))
        let tail = String(text[index.upperBound...])
        #expect(tail == "\n- Newer lot\n- Older lot")
        #expect(ids == [pp.id, pl.id])
        // outside a lot the index is the project's
        let (noLot, _) = await mem.contextText(cwd: repo.path, paddock: nil)
        #expect(noLot.contains("- Unpinned project") && !noLot.contains("Newer lot"))
    }

    @Test func contextFits4096With500Memories() async throws {
        let repo = try await makeRepo()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ml-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let mem = MemoryService(globalDir: root.appendingPathComponent("memory"))
        let lot = UUID(), store = await mem.lotStore(lot)
        try await store.run { m in
            for i in 0..<500 {
                try m.store.write(rec("Lot memory number \(i) with a reasonably long title", scope: .lot, lot: lot, pinned: i % 50 == 0,
                                      body: String(repeating: "detail ", count: 40), age: Double(500 - i)))
            }
        }
        let text = await mem.context(for: UUID(), cwd: repo.path, lot: lot)
        #expect(text.utf8.count <= 4096 && text.contains(MemoryService.indexTitle), "\(text.utf8.count)")
        let idx = try #require(text.range(of: MemoryService.indexTitle))
        #expect(text[idx.upperBound...].hasPrefix("\n- Lot memory number 499 "))   // newest first
    }

    /// Review Focus 5: moved to another lot mid-session, the next prompt injects from the new lot, from scratch.
    @Test func lotChangeResetsInjected() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo), b = try await term(d, p, "B", cwd: repo)
            #expect(try await admin(d, p, "lot.create", ["name": "LA", "members": "A"]).ok)
            #expect(try await admin(d, p, "lot.create", ["name": "LB", "members": "B"]).ok)
            _ = try await save(p, a, "cache a", "Redis cache in A", body: "redis cache ttl")
            _ = try await save(p, b, "cache b", "Redis cache in B", body: "redis cache ttl")
            _ = try await save(p, a, "cache p", "Redis cache project", body: "redis cache ttl", scope: "project")
            let prompt = "redis cache ttl"
            let first = output(try await call(p, a, "memory.hookRelevant", ["prompt": prompt]))
            #expect(first.contains("in A") && first.contains("project") && !first.contains("in B"), "\(first)")
            #expect(output(try await call(p, a, "memory.hookRelevant", ["prompt": prompt])).isEmpty)
            #expect(try await admin(d, p, "lot.join", ["terminal": "A", "lot": "LB"]).ok)
            let moved = output(try await call(p, a, "memory.hookRelevant", ["prompt": prompt]))
            #expect(moved.contains("in B") && moved.contains("project") && !moved.contains("in A"), "\(moved)")
        }
    }

    @Test func proposalExpiresTo14Days() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ml-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MemoryStore(dir: dir)
        let old = rec("Old proposal", status: .proposed, age: 15 * 86400), young = rec("Young proposal", status: .proposed, age: 13 * 86400)
        let active = rec("Old active", age: 30 * 86400)
        for r in [old, young, active] { try store.write(r) }
        #expect(try MemoryCleanup.expireProposals(store: store).map(\.id) == [old.id])
        let by = Dictionary(uniqueKeysWithValues: store.all().records.map { ($0.id, $0.status) })
        #expect(by == [old.id: .discarded, young.id: .proposed, active.id: .active])   // never deleted
        #expect(try MemoryCleanup.restore(old.id, store: store).status == .active)
    }

    /// R2: an unknown scope or status keeps the file readable, out of injection, never deleted.
    @Test func unknownScopeOrStatusStaysReadable() throws {
        func file(_ extra: String) -> String {
            "---\nid: \(UUID().uuidString)\nkind: decision\n\(extra)\nsubject: s\ntitle: t\nreviewed: false\npinned: false\norigin: app\ncreated: 2026-01-01T00:00:00Z\nupdated: 2026-01-01T00:00:00Z\n---\n\nbody\n"
        }
        let a = try MemoryFile.parse(file("scope: herd\nstatus: active"))
        #expect(a.status == .archived)
        let b = try MemoryFile.parse(file("scope: project\nstatus: someday"))
        #expect(b.scope == .project && b.status == .archived)
        let c = try MemoryFile.parse(file("scope: lot\nlot: not-a-uuid\nstatus: proposed"))
        #expect(c.scope == .lot && c.lotId == nil && c.status == .proposed && !MemoryService.visible(c, paddock: nil, lot: UUID()))
        let old = try MemoryFile.parse(file("scope: project"))   // pre-2M files: no lot, project, active
        #expect(old.lotId == nil && old.status == .active)
        let lot = UUID(), r = rec("x", scope: .lot, lot: lot, status: .proposed)
        #expect(try MemoryFile.parse(MemoryFile.render(r)) == r)
    }

    /// R5: a lot whose store still holds active or proposed memories can't be deleted; its store stays on disk.
    @Test func lotDeleteRefusedWithLiveMemories() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            #expect(try await admin(d, p, "lot.create", ["name": "LA", "members": "A"]).ok)
            let lid = await lotId(d, "LA")
            let act = try await save(p, a, "q", "Active one")
            let prop = rec("Proposed one", scope: .lot, lot: lid, status: .proposed)
            let arch = rec("Archived one", scope: .lot, lot: lid, status: .archived)
            try await d.router.memory.lotStore(lid).run { m in for r in [prop, arch] { try m.store.write(r) } }
            #expect(try await admin(d, p, "admin.kill", ["target": "A"]).ok)
            let refused = try await admin(d, p, "lot.delete", ["lot": "LA"])
            #expect(refused.error?.code == .invalidArgs && refused.error?.message.contains("promote or discard") == true, "\(refused)")
            #expect(try await admin(d, p, "memory.review", ["id": s(act["id"])!, "action": "discard", "lot": "LA"]).ok)
            #expect(try await admin(d, p, "lot.delete", ["lot": "LA"]).error?.code == .invalidArgs)   // the proposal still blocks
            #expect(try await admin(d, p, "memory.review", ["id": prop.id.uuidString, "action": "discard", "lot": "LA"]).ok)
            #expect(try await admin(d, p, "lot.delete", ["lot": "LA"]).ok)   // archived + discarded only
            let dir = p.root.appendingPathComponent("lots/\(lid.uuidString.lowercased())/memory")
            #expect(MemoryStore(dir: dir).all().records.count == 3)   // nothing deleted
        }
    }

    /// M1: an unknown scope stays archived, keeps its value on rewrite and is never restored (it would widen to project).
    @Test func unknownScopeIsNeverRestored() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            let id = UUID()
            let dir = repo.appendingPathComponent(".collie/memory/decision")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("s-\(id.uuidString.lowercased().prefix(8)).md")
            try "---\nid: \(id.uuidString.lowercased())\nkind: decision\nscope: herd\nsubject: s\ntitle: Herd secret\nstatus: active\norigin: app\ncreated: 2026-01-01T00:00:00Z\nupdated: 2026-01-01T00:00:00Z\n---\n\nzebra\n"
                .write(to: file, atomically: true, encoding: .utf8)
            #expect(try await admin(d, p, "memory.restore", ["id": id.uuidString, "repo": repo.path]).error?.code == .invalidArgs)
            #expect(try await admin(d, p, "memory.pin", ["id": id.uuidString, "repo": repo.path]).ok)
            #expect(try String(contentsOf: file, encoding: .utf8).contains("scope: herd"))   // a rewrite keeps the unknown scope
            #expect(titles(try await call(p, a, "memory.search", ["query": "zebra", "inactive": "true"])).isEmpty)
            #expect(try await call(p, a, "memory.get", ["id": id.uuidString]).error?.code == .notFound)
            #expect(!output(try await call(p, a, "memory.hookContext")).contains("Herd secret"))
        }
    }

    /// M3: reading, searching (`--all`) or injecting never creates a lot's store; the first save does.
    @Test func lotStoreCreatedOnlyOnSave() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await term(d, p, "A", cwd: repo)
            #expect(try await admin(d, p, "lot.create", ["name": "LA", "members": "A"]).ok)
            #expect(try await admin(d, p, "lot.create", ["name": "LB"]).ok)
            let lots = p.root.appendingPathComponent("lots")
            #expect(try await admin(d, p, "memory.search", ["query": "x", "all": "true", "repo": repo.path]).ok)
            #expect(try await admin(d, p, "memory.search", ["query": "x", "lot": "LB"]).ok)
            #expect(try await admin(d, p, "memory.list", ["lot": "LB"]).ok)
            #expect(try await call(p, a, "memory.search", ["query": "x"]).ok)
            _ = try await call(p, a, "memory.hookContext")
            _ = try await call(p, a, "memory.hookRelevant", ["prompt": "anything goes here"])
            #expect(!FileManager.default.fileExists(atPath: lots.path))
            _ = try await save(p, a, "q", "First")
            let la = await lotId(d, "LA"), lb = await lotId(d, "LB")
            #expect(mode(lots.path) == 0o700 && mode(lots.appendingPathComponent(la.uuidString.lowercased()).path) == 0o700)
            #expect(!FileManager.default.fileExists(atPath: lots.appendingPathComponent(lb.uuidString.lowercased()).path))
        }
    }
}
