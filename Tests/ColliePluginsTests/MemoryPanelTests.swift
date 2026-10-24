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
    var digest: JSONValue = .object(["entries": .array([]), "curator": .null])
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
        case "lot.list": return .array(lots.keys.sorted().map { .object(["name": .string($0), "id": .string(lots[$0]!.uuidString)]) })
        case "memory.digest": return digest
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

    private func entry(_ action: String, _ title: String, at: Date, store: String = "/r", resolved: Bool = false,
                       before: [UUID] = []) -> JSONValue {
        let f = ISO8601DateFormatter()
        return .object(["id": .string(UUID().uuidString), "at": .string(f.string(from: at)), "action": .string(action), "title": .string(title),
                        "reason": .string("porque sim"), "store": .string(store), "created": .array([]),
                        "before": .array(before.map { id in
                            let r = MemoryRecord(id: id, kind: .decision, subject: "s", title: "t")
                            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
                            return try! JSONDecoder().decode(JSONValue.self, from: e.encode(r))
                        }), "undone": .bool(false), "resolved": .bool(resolved)])
    }
    private func curator(available: Bool = true, reason: String? = nil) -> JSONValue {
        .object(["available": .bool(available), "reason": reason.map(JSONValue.string) ?? .null, "today": .number(12), "cap": .number(40),
                 "queued": .number(0), "failed": .number(0), "inputTokens": .number(17_000), "outputTokens": .number(1_200), "costUSD": .number(0.0412)])
    }

    @Test func learningTabGroupsTodayAndWeek() async {
        let (m, d) = make([])
        let now = Date()
        await d.setDigest(.object(["entries": .array([
            entry("aprendido", "Regra de hoje", at: now.addingTimeInterval(-60)),
            entry("aposentado", "Velha da semana", at: now.addingTimeInterval(-3 * 86400)),
            entry("ask", "Tabs ou espaços?", at: now.addingTimeInterval(-5 * 86400)),
            entry("ask", "Já resolvida", at: now.addingTimeInterval(-60), resolved: true),
        ]), "curator": curator()]))
        await m.load()
        #expect(MemoryPanelModel.Tab.allCases.first == .learning && m.tab == .learning && MemoryPanelModel.Tab.learning.rawValue == "Aprendizado")
        let g = m.learningGroups(now: now)
        #expect(g.map(\.title) == ["Precisa de você", "Hoje", "Esta semana"])
        #expect(g.map { $0.rows.map(\.title) } == [["Tabs ou espaços?"], ["Regra de hoje"], ["Velha da semana"]])
        #expect(g[1].rows.first?.reason == "porque sim")
        let undo = g[1].rows[0]
        await m.undo(undo)
        #expect(await d.last("memory.undo")?["entry"] == .string(undo.id.uuidString))
        await m.resolve(g[0].rows[0], keepNewer: false)
        #expect(await d.last("memory.resolve")?["keep"] == .string("older"))
    }

    @Test func curatorLine() async {
        let (m, d) = make([])
        await d.setDigest(.object(["entries": .array([]), "curator": curator()]))
        await m.load()
        #expect(m.curatorLine == "Curador: 12/40 hoje · 18 mil tokens · US$ 0,04")
        await d.setDigest(.object(["entries": .array([]), "curator": curator(available: false, reason: "claude sem login")]))
        await m.load()
        #expect(m.curatorLine == "curador indisponível: claude sem login")
    }

    @Test func capEditable() async {
        let (m, d) = make([])
        await m.setCap(25)
        #expect(await d.last("memory.curator")?["cap"] == .number(25))
    }

    @Test func promoteSuggestion() async {
        let la = UUID(), rid = UUID()
        let (m, d) = make([])
        await d.setLots(["Login": la])
        await d.setDigest(.object(["entries": .array([
            entry("ask", "Vale para o projeto todo? Promover ao projeto", at: Date(), store: "lot:\(la.uuidString.lowercased())", before: [rid]),
            entry("ask", "Qual vale?", at: Date(), store: "lot:\(la.uuidString.lowercased())", before: [rid]),
        ]), "curator": curator()]))
        await m.load()
        let asks = m.learningGroups(now: Date())[0].rows
        #expect(m.promoteSuggestion(asks[0])?.lot == "Login" && m.promoteSuggestion(asks[0])?.id == rid)
        #expect(m.promoteSuggestion(asks[1]) == nil)
        await m.promoteSuggested(asks[0])
        let a = await d.last("memory.promote")
        #expect(a?["id"] == .string(rid.uuidString) && a?["lot"] == .string("Login"))
    }

    @Test func dailyNotificationOffByDefault() {
        #expect(MemoryDigestNotice.defaultsKey == "memory.dailyNotification" && MemoryDigestNotice.defaultOn == false)
        let cal = Calendar.current
        let at18 = cal.date(bySettingHour: 18, minute: 5, second: 0, of: Date())!, at17 = cal.date(bySettingHour: 17, minute: 0, second: 0, of: Date())!
        let today: [MemoryDigestNotice.Item] = [.init(at: at17, ask: false), .init(at: at17, ask: false), .init(at: at17, ask: true)]
        #expect(MemoryDigestNotice.message(enabled: false, items: today, now: at18, lastPosted: nil) == nil)
        #expect(MemoryDigestNotice.message(enabled: true, items: today, now: at17, lastPosted: nil) == nil)   // before 18:00
        #expect(MemoryDigestNotice.message(enabled: true, items: today, now: at18, lastPosted: nil) == "Collie aprendeu 2 coisas, 1 precisa de você")
        #expect(MemoryDigestNotice.message(enabled: true, items: Array(today.prefix(2)), now: at18, lastPosted: nil) == "Collie aprendeu 2 coisas")
        #expect(MemoryDigestNotice.message(enabled: true, items: today, now: at18, lastPosted: at18.addingTimeInterval(-60)) == nil)   // once a day
        #expect(MemoryDigestNotice.message(enabled: true, items: [], now: at18, lastPosted: nil) == nil)
        let two: [MemoryDigestNotice.Item] = [.init(at: at17, ask: true), .init(at: at17, ask: true), .init(at: at17, ask: false)]
        #expect(MemoryDigestNotice.message(enabled: true, items: two, now: at18, lastPosted: nil) == "Collie aprendeu 1 coisa, 2 precisam de você")
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
    func setDigest(_ v: JSONValue) { digest = v }
    func setPlan(_ p: [JSONValue]) { plan = p }
    func fail(_ c: String) { failing.insert(c) }
}
