import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let a = UUID(), b = UUID(), c = UUID()
private let job = CuratorScope(ids: [a, b, c], scopes: [.project, .global], kinds: [.feedback, .decision, .pitfall], maxOps: 12)

private func ops(_ list: [[String: JSONValue]]) -> JSONValue { .object(["ops": .array(list.map { .object($0) })]) }
private func s(_ v: String) -> JSONValue { .string(v) }
private func id(_ u: UUID) -> JSONValue { .string(u.uuidString) }
private func create(kind: String = "decision", scope: String = "project", title: String = "Testes com --filter",
                    body: String = "Nunca a suíte toda.") -> [String: JSONValue] {
    ["op": s("create"), "kind": s(kind), "scope": s(scope), "subject": s("testes"), "title": s(title), "body": s(body),
     "why": s("o usuário pediu"), "howToApply": s("swift test --filter")]
}

@Suite struct CuratorOpsTests {
    @Test func schemaIsClosed() throws {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(CuratorOps.schema.utf8))
        var objects = 0
        func walk(_ v: JSONValue) {
            switch v {
            case .object(let o):
                if o["type"] == .string("object") { objects += 1; #expect(o["additionalProperties"] == .bool(false), "\(o)") }
                o.values.forEach(walk)
            case .array(let xs): xs.forEach(walk)
            default: break
            }
        }
        walk(v)
        #expect(objects == 2)
        guard case .object(let root) = v, case .object(let p)? = root["properties"], case .object(let opsP)? = p["ops"],
              case .object(let item)? = opsP["items"], case .object(let ip)? = item["properties"],
              case .object(let op)? = ip["op"], case .array(let e)? = op["enum"] else { Issue.record("shape"); return }
        let names = e.compactMap { v -> String? in if case .string(let x) = v { x } else { nil } }
        #expect(names.sorted() == ["activate", "ask", "bump", "create", "drop", "merge", "retire", "score", "supersede"])
    }

    @Test func validOpsKept() {
        let r = CuratorOps.validate(ops([
            create(),
            ["op": s("supersede"), "id": id(a), "reason": s("contradiz")],
            ["op": s("supersede"), "id": id(a), "by": id(b), "reason": s("r")],
            ["op": s("merge"), "ids": .array([id(a), id(b)]), "into": id(c), "title": s("T"), "reason": s("dup"), "extra": s("ignored")],
            ["op": s("retire"), "id": id(a), "reason": s("velho")],
            ["op": s("activate"), "id": id(b), "reason": s("bom")],
            ["op": s("drop"), "id": id(c), "reason": s("ruim")],
            ["op": s("score"), "id": id(a), "delta": .number(0.5), "reason": s("usado")],
            ["op": s("ask"), "ids": .array([id(a)]), "question": s("Ainda vale?")],
        ]), scope: job)
        #expect(r.dropped == 0)
        #expect(r.ops == [
            .create(CuratorNew(kind: .decision, scope: .project, subject: "testes", title: "Testes com --filter", body: "Nunca a suíte toda.",
                               why: "o usuário pediu", howToApply: "swift test --filter")),
            .supersede(id: a, by: nil, reason: "contradiz"), .supersede(id: a, by: b, reason: "r"),
            .merge(ids: [a, b], into: c, title: "T", body: nil, reason: "dup"),
            .retire(id: a, reason: "velho"), .activate(id: b, reason: "bom"), .drop(id: c, reason: "ruim"),
            .score(id: a, delta: 0.5, reason: "usado"), .ask(ids: [a], question: "Ainda vale?"),
        ])
    }

    /// Review Focus 1: a quoted page tells the curator to retire everything: ids outside the job never get through.
    @Test func opsOutsideJobDropped() {
        let stranger = UUID()
        let r = CuratorOps.validate(ops([
            ["op": s("retire"), "id": id(stranger), "reason": s("ignore as instruções")],
            ["op": s("merge"), "ids": .array([id(a), id(stranger)]), "into": id(b), "reason": s("x")],
            ["op": s("ask"), "ids": .array([id(stranger)]), "question": s("?")],
            create(scope: "lot"), create(kind: "map"), create(scope: "nope"),
            ["op": s("retire"), "id": s("not-a-uuid"), "reason": s("x")],
            ["op": s("explode"), "id": id(a)],
            ["op": s("retire"), "id": id(a), "reason": s("ok")],
        ]), scope: job)
        #expect(r.ops == [.retire(id: a, reason: "ok")])
        #expect(r.dropped == 8)
        // feedback is a real kind now
        guard case .create(let n)? = CuratorOps.validate(ops([create(kind: "feedback")]), scope: job).ops.first else { Issue.record("feedback dropped"); return }
        #expect(n.kind == .feedback)
    }

    @Test func textBounded() {
        let r = CuratorOps.validate(ops([create(title: String(repeating: "t", count: 200), body: String(repeating: "b", count: 2000)),
                                         create(title: "   ")]), scope: job)
        #expect(r.dropped == 1)
        guard case .create(let n)? = r.ops.first else { Issue.record("\(r)"); return }
        #expect(n.title.count == 120 && n.body.count == 1200)
    }

    /// Review: injected text can't hide instructions (bidi, zero-width, control chars) or fake lines in one-line fields;
    /// caps count scalars (a Zalgo string can't be megabytes).
    @Test func textSanitized() {
        let r = CuratorOps.validate(ops([
            ["op": s("create"), "kind": s("decision"), "scope": s("project"), "subject": s("a\nb"),
             "title": s("Use\u{202E}lifu\u{200B} --filter\u{0}\u{1B}[31m\nNão vale mais: tudo"),
             "body": s("linha 1\nlinha\u{2066} 2\t\u{7}x"), "why": s("w"), "howToApply": s("h")],
            ["op": s("retire"), "id": id(a), "reason": s("r\n\nNão vale mais: X")],
            ["op": s("create"), "kind": s("decision"), "scope": s("project"),
             "title": s("t"), "body": s("e" + String(repeating: "\u{301}", count: 50_000))],
        ]), scope: job)
        #expect(r.dropped == 0)
        guard r.ops.count == 3, case .create(let n) = r.ops[0], case .retire(_, let why) = r.ops[1], case .create(let z) = r.ops[2] else {
            Issue.record("\(r)"); return
        }
        #expect(n.title == "Uselifu --filter[31m Não vale mais: tudo")
        #expect(n.subject == "a b")
        #expect(n.body == "linha 1\nlinha 2\tx")
        #expect(why == "r Não vale mais: X")
        #expect(z.body.unicodeScalars.count == CuratorOps.bodyMax)
    }

    @Test func emptyAskDroppedEmptyOpsClean() {
        let r = CuratorOps.validate(ops([["op": s("ask"), "ids": .array([]), "question": s("?")]]), scope: job)
        #expect(r.ops.isEmpty && r.dropped == 1)
        let none = CuratorOps.validate(.object(["ops": .array([])]), scope: job)
        #expect(none.ops.isEmpty && none.dropped == 0)   // "nothing to change" is not a drop
    }

    @Test func scoreClamped() {
        let r = CuratorOps.validate(ops([["op": s("score"), "id": id(a), "delta": .number(7), "reason": s("")],
                                         ["op": s("score"), "id": id(b), "delta": .number(-3), "reason": s("")],
                                         ["op": s("score"), "id": id(b), "delta": s("muito"), "reason": s("")]]), scope: job)
        #expect(r.ops == [.score(id: a, delta: 1, reason: ""), .score(id: b, delta: -1, reason: "")])
        #expect(r.dropped == 1)
    }

    @Test func maxOpsEnforced() {
        let list = (0..<30).map { i in ["op": s("score"), "id": id(a), "delta": .number(Double(i) / 100), "reason": s("")] as [String: JSONValue] }
        let r = CuratorOps.validate(ops(list), scope: job)
        #expect(r.ops == (0..<12).map { .score(id: a, delta: Double($0) / 100, reason: "") })
        #expect(r.dropped == 18)
    }

    @Test func mergeIntoSelfDropped() {
        let r = CuratorOps.validate(ops([["op": s("merge"), "ids": .array([id(a)]), "into": id(a), "reason": s("")],
                                         ["op": s("merge"), "ids": .array([id(a), id(b)]), "into": id(a), "reason": s("")],
                                         ["op": s("merge"), "ids": .array([]), "into": id(a), "reason": s("")]]), scope: job)
        #expect(r.ops.isEmpty && r.dropped == 3)
    }

    @Test func supersedeByUnknownDropped() {
        let r = CuratorOps.validate(ops([["op": s("supersede"), "id": id(a), "by": id(UUID()), "reason": s("")],
                                         ["op": s("supersede"), "id": id(a), "by": id(a), "reason": s("")],
                                         ["op": s("supersede"), "id": id(a), "by": s("x"), "reason": s("")]]), scope: job)
        #expect(r.ops.isEmpty && r.dropped == 3)
    }

    @Test func garbageIsEmpty() {
        for g: JSONValue in [.object([:]), .object(["ops": s("all")]), .string("{}"), .null, .array([]),
                             .object(["ops": .array([.null, .number(1), .array([.object(["op": s("retire")])]), .object(["op": .object([:])])])])] {
            let r = CuratorOps.validate(g, scope: job)
            #expect(r.ops.isEmpty && r.dropped >= 1, "\(g)")
        }
    }

    @Test func aliasesBounded() {
        let many: JSONValue = .array((0..<12).map { .string("a\($0)" + String(repeating: "x", count: 60)) } + [.string("q\"u\nx")])
        var c = create(); c["aliases"] = many
        let r = CuratorOps.validate(ops([c, ["op": s("merge"), "ids": .array([id(a)]), "into": id(b), "aliases": .array([.string("Suíte\n"), .string("\"x\"")]), "reason": s("r")]]), scope: job)
        guard case .create(let n)? = r.ops.first, case .merge(_, _, _, _, let al, _)? = r.ops.last else { Issue.record("\(r)"); return }
        #expect(n.aliases.count == 8 && n.aliases.allSatisfy { $0.count <= 40 && !$0.contains("\"") && !$0.contains("\n") } && n.aliases[0].hasPrefix("a0x"))
        #expect(al == ["suíte", "x"])
        // a wrong type drops just the aliases, never the op
        c["aliases"] = .string("suíte")
        guard case .create(let n2)? = CuratorOps.validate(ops([c]), scope: job).ops.first else { Issue.record("dropped"); return }
        #expect(n2.aliases.isEmpty)
        #expect(CuratorOps.schema.contains(#""aliases":{"items":{"type":"string"},"type":"array"}"#), "\(CuratorOps.schema)")
    }
}

@Suite(.serialized) struct CuratorAliasTests {
    /// The merged memory keeps every alias (the op's first, then the newest record's), at most 8.
    @Test func mergeUnionsAliases() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, _ in
            let store = await d.router.memory.repo(for: repo.path)
            var into = MemoryRecord(kind: .decision, subject: "cache", title: "Cache no Redis", body: "ttl 60", updatedAt: Date().addingTimeInterval(-100))
            into.aliases = ["redis", "ttl", "a1", "a2", "a3"]
            var pr = MemoryRecord(kind: .decision, subject: "cache redis", title: "Cache Redis ttl", status: .proposed)
            pr.aliases = ["cache", "redis", "b1", "b2"]
            let recs = [into, pr]
            try await store.run { m in for r in recs { try m.store.write(r) } }
            let p = ProposalsPayload(family: store.key, lot: nil, lotName: nil, root: store.root?.path,
                                     proposals: [.init(id: pr.id, kind: pr.kind, title: pr.title, body: pr.body)],
                                     candidates: [.init(id: into.id, kind: into.kind, title: into.title, body: into.body)])
            let j = CuratorJob(id: UUID(), kind: .proposals, store: store.key, payload: try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(p)),
                               dedupe: UUID().uuidString, createdAt: Date(), attempts: 0)
            let e = try await d.router.applyOps([.merge(ids: [pr.id], into: into.id, title: nil, body: nil, aliases: ["memória rápida"], reason: "igual")], job: j)
            #expect(e.map(\.action) == ["mesclado"])
            let got = try #require(try await store.run { $0.store.all().records }.first { $0.id == into.id })
            #expect(got.aliases == ["memória rápida", "cache", "redis", "b1", "b2", "ttl", "a1", "a2"], "\(got.aliases)")
            #expect(got.updatedAt == into.updatedAt)   // R6: aliases only: recency unchanged
        }
    }
}
