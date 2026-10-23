import Foundation
import Testing
import CollieCore
import CollieProtocol
@testable import ColliePlugins

/// A fake daemon: just enough of `memory.*` over an in-memory record list.
private actor FakeDaemon {
    var records: [MemoryRecord]
    var calls: [(String, [String: JSONValue])] = []
    var plan: [JSONValue] = []
    var failing: Set<String> = []
    var lots: [String: UUID] = [:]
    init(_ r: [MemoryRecord]) { records = r }

    func handle(_ cmd: String, _ a: [String: JSONValue]) throws(ProtocolError) -> JSONValue {
        calls.append((cmd, a))
        if failing.contains(cmd) { throw ProtocolError(code: .internal, message: "\(cmd) broke") }
        func s(_ k: String) -> String? { if case .string(let v)? = a[k] { return v }; return nil }
        func enc(_ r: MemoryRecord, _ extra: [String: JSONValue] = [:]) -> JSONValue {
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
            guard case .object(var o) = try! JSONDecoder().decode(JSONValue.self, from: e.encode(r)) else { return .null }
            o.merge(extra) { _, b in b }
            return .object(o)
        }
        switch cmd {
        case "memory.repos": return .array([.object(["path": .string("/r"), "scope": .string("project")])])
        case "lot.list": return .array(lots.keys.sorted().map { .object(["name": .string($0)]) })
        case "memory.list":
            let st = s("status") ?? "active", un = a["unreviewed"] == .bool(true), lot = s("lot").flatMap { lots[$0] }
            return .object(["records": .array(records.filter { $0.status.rawValue == st && (!un || !$0.reviewed) && $0.lotId == lot }
                .map { enc($0, ($0.kind == .map && $0.path == "gone.txt" ? ["missingSince": .string("2026-10-01T00:00:00Z")] : [:])
                    .merging(s("lot").map { ["lot": .string($0)] } ?? [:]) { a, _ in a }) }),
                            "problems": .array([.object(["file": .string("/r/bad.md"), "error": .string("x")])])])
        case "memory.review":
            let i = records.firstIndex { $0.id.uuidString == s("id") }!
            records[i].reviewed = true
            if s("action") == "discard" { records[i].status = .discarded }
            if s("action") == "archive" { records[i].status = .archived }
            if s("action") == "approve", records[i].status == .proposed { records[i].status = .active }
            if let t = s("title") { records[i].title = t }
            return .null
        case "memory.restore":
            let i = records.firstIndex { $0.id.uuidString == s("id") }!
            records[i].status = .active
            return .null
        case "memory.cleanup":
            if a["apply"] == .bool(true) {   // archives what the plan names
                let ids = plan.compactMap { v -> String? in if case .object(let o) = v, case .string(let id)? = o["id"] { return id }; return nil }
                for i in records.indices where ids.contains(records[i].id.uuidString) { records[i].status = .archived }
            }
            return .object(["items": .array(plan), "applied": .array([])])
        case "memory.purge":
            let n = records.filter { $0.status == .discarded }.count
            records.removeAll { $0.status == .discarded }
            return .object(["deleted": .number(Double(n))])
        default: return .null
        }
    }
    func setLots(_ l: [String: UUID]) { lots = l }
    func names() -> [String] { calls.map(\.0) }
    func last(_ c: String) -> [String: JSONValue]? { calls.last { $0.0 == c }?.1 }
    func all(_ c: String) -> [[String: JSONValue]] { calls.filter { $0.0 == c }.map(\.1) }
}

@MainActor private func make(_ recs: [MemoryRecord]) -> (MemoryPanelModel, FakeDaemon) {
    let d = FakeDaemon(recs)
    return (MemoryPanelModel(call: { c, a throws(ProtocolError) in try await d.handle(c, a) }), d)
}

@MainActor @Suite struct MemoryPanelTests {
    func rec(_ title: String, kind: MemoryKind = .decision, status: MemoryStatus = .active, reviewed: Bool = false,
             path: String? = nil, supersedes: UUID? = nil) -> MemoryRecord {
        MemoryRecord(kind: kind, subject: title, title: title, path: path, status: status, reviewed: reviewed, supersedes: supersedes)
    }

    @Test func reviewTabListsUnreviewed() async {
        let (m, d) = make([rec("a"), rec("b", reviewed: true)])
        await m.load()
        #expect(m.unreviewed.map(\.record.title) == ["a"])
        #expect(m.repo == "/r")
        #expect(m.problems.count == 1)
        #expect((await d.all("memory.list")).allSatisfy { $0["repo"] == .string("/r") })
    }

    @Test func approveCallsReviewAndRefreshes() async {
        let a = rec("a")
        let (m, d) = make([a])
        await m.load()
        await m.approve(a.id)
        let args = await d.last("memory.review")
        #expect(args?["action"] == .string("approve") && args?["id"] == .string(a.id.uuidString))
        #expect(m.unreviewed.isEmpty)
        await m.edit(a.id, title: "novo", body: "b", subject: "s")
        #expect((await d.last("memory.review"))?["title"] == .string("novo"))
    }

    @Test func decisionHistoryShowsChain() async {
        let old = rec("v1", status: .superseded), mid = rec("v2", status: .superseded, supersedes: old.id)
        let cur = rec("v3", supersedes: mid.id)
        let (m, _) = make([old, mid, cur])
        await m.load()
        #expect(m.history(of: m.decisions[0]).map(\.record.title) == ["v2", "v1"])
    }

    @Test func mapMarksMissing() async {
        let (m, _) = make([rec("ok", kind: .map, path: "a.txt"), rec("gone", kind: .map, path: "gone.txt")])
        await m.load()
        #expect(m.maps.first { $0.record.title == "gone" }?.missingSince != nil)
        #expect(m.maps.first { $0.record.title == "ok" }?.missingSince == nil)
    }

    @Test func cleanupApplyThenRestore() async {
        let map = rec("m", kind: .map, path: "a")
        let (m, d) = make([map])
        await d.setPlan([.object(["action": .string("archiveMissingPath"), "id": .string(map.id.uuidString), "reason": .string("sumiu")])])
        await m.planCleanup()
        #expect(m.plan.first?.reason == "sumiu")
        await m.applyCleanup()
        #expect((await d.calls).contains { $0.0 == "memory.cleanup" && $0.1["apply"] == .bool(true) })
        #expect(m.maps.isEmpty)
        await m.restore(map.id)
        #expect(m.maps.count == 1)
    }

    @Test func archiveCallsReviewArchiveAndPurgeKeepsIt() async {
        let gone = rec("gone", kind: .map, path: "gone.txt")
        let (m, d) = make([gone])
        await m.load()
        await m.archive(gone.id)
        #expect((await d.last("memory.review"))?["action"] == .string("archive"))
        #expect(m.maps.isEmpty && m.discarded.isEmpty)
        m.purgeConfirmed = true
        await m.purge()
        #expect((await d.records).first?.status == .archived)
    }

    @Test func cleanupArchiveIsListedAndRestorable() async {
        let dec = rec("cold one")
        let (m, d) = make([dec])
        await d.setPlan([.object(["action": .string("archiveCold"), "id": .string(dec.id.uuidString), "reason": .string("fria")])])
        await m.load()
        await m.applyCleanup()
        #expect(m.archived.map(\.id) == [dec.id] && m.decisions.isEmpty)
        await m.restore(dec.id)
        #expect(m.decisions.map(\.id) == [dec.id] && m.archived.isEmpty)
    }

    @Test func unchainedSupersededAreListed() async {
        let merged = rec("merged dup", status: .superseded)
        let chained = rec("v1", status: .superseded), cur = rec("v2", supersedes: chained.id)
        let oldPit = rec("old pitfall", kind: .pitfall, status: .superseded), pit = rec("pitfall", kind: .pitfall, supersedes: oldPit.id)
        let (m, _) = make([merged, chained, cur, oldPit, pit])
        await m.load()
        #expect(m.unchained.map(\.id) == [merged.id])
    }

    @Test func planCleanupKeepsLoadError() async {
        let (m, d) = make([rec("a")])
        await d.fail("memory.list")
        m.tab = .cleanup
        await m.selectRepo("/r")
        #expect(m.error == "memory.list broke")
    }

    @Test func reposRefreshOnReload() async {
        let (m, d) = make([rec("a")])
        await m.load()
        await m.load()
        #expect((await d.all("memory.repos")).count == 2)
        #expect(m.error == nil)
    }

    @Test func purgeRequiresConfirmationFlag() async {
        let (m, d) = make([rec("x", status: .discarded)])
        await m.load()
        #expect(m.discarded.count == 1)
        await m.purge()
        #expect(!(await d.names()).contains("memory.purge"))
        m.purgeConfirmed = true
        await m.purge()
        #expect((await d.names()).contains("memory.purge"))
        #expect(m.discarded.isEmpty && !m.purgeConfirmed)
    }

    @Test func proposalsGroupedByLot() async {
        let lot = UUID()
        var a = rec("redis", status: .proposed); a.lotId = lot
        var b = rec("argon2", status: .proposed); b.lotId = lot
        let c = rec("postgres", status: .proposed)
        let (m, d) = make([a, b, c, rec("active one")])
        await d.setLots(["Login": lot])
        await m.load()
        #expect(m.proposalGroups.map(\.lot) == ["Login", nil])
        #expect(m.proposalGroups.map { $0.rows.map(\.record.title).sorted() } == [["argon2", "redis"], ["postgres"]])
        #expect(!m.unreviewed.contains { $0.record.status == .proposed })
        await m.approveAll(lot: "Login")
        let reviews = await d.all("memory.review")
        #expect(reviews.count == 2 && reviews.allSatisfy { $0["lot"] == .string("Login") && $0["action"] == .string("approve") })
        #expect(m.proposalGroups.map(\.lot) == [nil])
        await m.discard(c.id)
        let lastReview = await d.last("memory.review")
        #expect(m.proposals.isEmpty && lastReview?["lot"] == nil)
    }

    @Test func lotMemoriesGroupedAndActionsCarryTheLot() async {
        let la = UUID(), lb = UUID()
        var a = rec("jwt", reviewed: true); a.lotId = la
        var b = rec("cache"); b.lotId = lb
        let (m, d) = make([a, b, rec("project one")])
        await d.setLots(["LA": la, "LB": lb])
        await m.load()
        #expect(m.lotMemoryGroups.map(\.lot) == ["LA", "LB"] && m.lotMemories.count == 2)
        #expect(!m.unreviewed.contains { $0.record.title == "jwt" })
        await m.pin(a.id, lot: "LA"); await m.promote(a.id, lot: "LA"); await m.archive(b.id, lot: "LB")
        await m.restore(b.id, lot: "LB"); await m.discard(b.id, lot: "LB")
        for c in ["memory.pin", "memory.promote", "memory.restore"] { #expect(await d.last(c)?["lot"] != nil, "\(c)") }
        #expect((await d.all("memory.review")).allSatisfy { $0["lot"] == .string("LB") })
    }
}

extension FakeDaemon {
    func setPlan(_ p: [JSONValue]) { plan = p }
    func fail(_ c: String) { failing.insert(c) }
}
