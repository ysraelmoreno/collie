import Foundation
import Testing
import OrqProtocol
@testable import OrqPlugins

private actor Fake {
    var calls: [(String, [String: JSONValue])] = []
    var failPublish: String?
    var slowAcme = false, listFails = false
    /// While held, `design.system.use` waits for `release()`.
    var holdUse = false, useWaiter: CheckedContinuation<Void, Never>?
    func slow() { slowAcme = true }
    func setListFails(_ v: Bool) { listFails = v }
    func hold() { holdUse = true }
    func release() { holdUse = false; useWaiter?.resume(); useWaiter = nil }
    func handle(_ cmd: String, _ a: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        calls.append((cmd, a))
        let outcome: JSONValue = .object(["file": .string("Home"), "ok": .bool(false), "detail": .string("1 sem par"), "unmatched": .array([.string("color/brand")])])
        switch cmd {
        case "floor.list": return .array([.object(["name": .string("f1")])])
        case "design.system.list":
            if listFails { throw ProtocolError(code: .internal, message: "boom") }
            return .array([.object(["name": .string("Acme"), "version": .number(2), "active": .array([.string("workspace"), .string("floor:f1")])]),
                           .object(["name": .string("Beta"), "version": .number(1), "active": .array([]), "reverted": .number(1)])])
        case "design.system.history":
            if a["name"] == .string("Acme"), slowAcme { try? await Task.sleep(for: .milliseconds(150)) }
            return .array([.object(["at": .string("2026-10-21T10:00:00Z"), "kind": .string("published"), "version": .number(2), "scope": .null,
                                    "by": .string("app"), "reason": .string("novo"), "files": .array([outcome])]),
                           .object(["at": .string("2026-10-21T11:00:00Z"), "kind": .string("activated"), "version": .null, "scope": .string("workspace"),
                                    "by": .string("app"), "reason": .string("usar"), "files": .array([])])])
        case "design.system.use", "design.system.undo":
            if cmd == "design.system.use", holdUse { await withCheckedContinuation { useWaiter = $0 } }
            return .object(["scope": .string("workspace"), "system": .string("Acme"), "files": .array([outcome])])
        case "design.system.publish":
            if let m = failPublish, a["force"] == nil { throw ProtocolError(code: .invalidArgs, message: m) }
            return .object(["name": .string("Beta"), "version": .number(2)])
        default: return .object([:])
        }
    }
    func last(_ c: String) -> [String: JSONValue]? { calls.last { $0.0 == c }?.1 }
    func count(_ c: String) -> Int { calls.filter { $0.0 == c }.count }
    func setFail(_ m: String) { failPublish = m }
}

@MainActor private func make() -> (DesignSystemsModel, Fake) {
    let f = Fake()
    return (DesignSystemsModel(call: { c, a throws(ProtocolError) in try await f.handle(c, a) }), f)
}

@MainActor @Suite struct DesignSystemsPanelTests {
    @Test func listsSystemsWithActiveScopes() async {
        let (m, _) = make()
        await m.load()
        #expect(m.systems.map(\.name) == ["Acme", "Beta"])
        #expect(m.systems[0].active == ["workspace", "floor:f1"] && m.systems[0].version == 2)
        #expect(m.scopes == ["workspace", "floor:f1"])
        #expect(m.systems[1].reverted == 1)
        #expect(m.selected == "Acme")
    }

    @Test func useSendsScopeAndReason() async {
        let (m, f) = make()
        await m.load()
        #expect(!m.canWrite)
        m.reason = "  "
        #expect(!m.canWrite)
        m.reason = "marca nova"
        #expect(m.canWrite)
        await m.use()
        var a = await f.last("design.system.use")
        #expect(a?["name"] == .string("Acme") && a?["reason"] == .string("marca nova") && a?["floor"] == nil)
        m.scope = "floor:f1"
        #expect(m.reason.isEmpty)   // cleared after a successful write
        m.reason = "de novo"
        await m.use()
        a = await f.last("design.system.use")
        #expect(a?["floor"] == .string("f1"))
        m.reason = "desfazer"
        await m.undo()
        #expect((await f.last("design.system.undo"))?["floor"] == .string("f1"))
        m.reason = "limpar"
        await m.clear()
        #expect((await f.last("design.system.use"))?["none"] == .bool(true))
    }

    @Test func historyShowsRevertForPublishes() async {
        let (m, f) = make()
        await m.load()
        await m.showHistory()
        #expect((await f.last("design.system.history"))?["name"] == .string("Acme"))
        #expect(m.history.map(\.canRevert) == [false, true])   // newest first
        m.reason = "voltar"
        await m.revert(to: 2)
        let a = await f.last("design.system.revert")
        #expect(a?["to"] == .number(2) && a?["name"] == .string("Acme") && a?["reason"] == .string("voltar"))
    }

    @Test func versionEventsRevertUndoesDoNot() {
        func row(_ kind: String, _ version: Int?, _ scope: String?) -> DesignEventRow {
            DesignEventRow(at: Date(), kind: kind, version: version, scope: scope, by: "app", reason: "r", files: nil)
        }
        #expect(row("created", 1, nil).canRevert && row("published", 2, nil).canRevert && row("reverted", 3, nil).canRevert)
        #expect(!row("activated", 2, "workspace").canRevert && !row("undone", 2, "workspace").canRevert)
        // an undo logged before `undone` existed: `reverted` with a scope
        #expect(!row("reverted", 2, "floor:f1").canRevert && row("reverted", 2, "floor:f1").isUndo)
        #expect(row("undone", 2, "workspace").label == "desfeito" && row("reverted", 3, nil).label == "revertido")
    }

    @Test func showsUnmatchedAfterUse() async {
        let (m, _) = make()
        await m.load()
        m.reason = "x"
        await m.use()
        #expect(m.results.first?.file == "Home" && m.results.first?.unmatched == ["color/brand"])
    }

    @Test func designSystemsPanelRefreshesOnEvent() async throws {
        let f = Fake()
        let m = DesignSystemsModel(call: { c, a throws(ProtocolError) in try await f.handle(c, a) }, window: .milliseconds(500))
        await m.handleEvent("designsystem.changed")
        for _ in 0..<5 { await m.handleEvent("designsystem.changed") }
        #expect(await f.count("design.system.list") == 1)
        #expect(await pollUntil { await f.count("design.system.list") == 2 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(await f.count("design.system.list") == 2)
    }

    @Test func eventKeepsErrorAndStopsOnClose() async throws {
        let (m, f) = make()
        await f.setFail("was reverted to v1")
        await m.load()
        m.selected = "Beta"; m.reason = "r"
        await m.publish()
        #expect(m.error == "was reverted to v1")
        await m.handleEvent("designsystem.changed")
        #expect(m.error == "was reverted to v1")   // a background reload does not clear it
        let g = Fake()
        let c = DesignSystemsModel(call: { c, a throws(ProtocolError) in try await g.handle(c, a) }, window: .milliseconds(50))
        c.stop()
        await c.handleEvent("designsystem.changed")
        try await Task.sleep(for: .milliseconds(150))
        #expect(await g.count("design.system.list") == 0)
    }

    @Test func backgroundReloadFailureHiddenDuringAction() async {
        let (m, f) = make()
        await m.load()
        m.reason = "r"
        await f.hold()
        let action = Task { await m.use() }
        #expect(await pollUntil { await f.count("design.system.use") == 1 })
        await f.setListFails(true)
        await m.handleEvent("designsystem.changed")   // the first event reloads at once, while the use waits
        #expect(await f.count("design.system.list") == 2)
        #expect(m.error == nil)
        await f.setListFails(false)
        await f.release()
        await action.value
        #expect(m.error == nil && m.results.first?.file == "Home")
    }

    @Test func refreshesOnChangedEvent() async {
        let (m, f) = make()
        await m.load()
        await m.handleEvent("browser.loaded")
        #expect(await f.count("design.system.list") == 1)
        await m.handleEvent("designsystem.changed")
        #expect(await f.count("design.system.list") == 2)
    }

    @Test func publishRefusedOffersForce() async {
        let (m, f) = make()
        await f.setFail("was reverted to v1")
        await m.load()
        m.selected = "Beta"; m.reason = "r"
        await m.publish()
        #expect(m.error == "was reverted to v1" && m.offerForce)
        await m.publish(force: true)
        #expect((await f.last("design.system.publish"))?["force"] == .bool(true))
        #expect(!m.offerForce && m.error == nil)
        await f.setFail("was reverted to v1")
        m.reason = "r"
        await m.publish()
        #expect(m.offerForce)
        m.selected = "Acme"
        #expect(!m.offerForce)
        m.selected = "Beta"
        await f.setFail("boom")
        m.reason = "r"
        await m.publish()
        #expect(m.error == "boom" && !m.offerForce)   // not the reverted refusal
    }

    @Test func staleHistoryIsIgnored() async {
        let (m, f) = make()
        await m.load()
        await f.slow()
        m.selected = "Acme"
        let t = Task { await m.showHistory() }
        try? await Task.sleep(for: .milliseconds(30))
        m.selected = "Beta"   // switches before Acme's answer lands
        await t.value
        #expect(m.history.isEmpty)
    }

    @Test func createSendsFromAndReason() async {
        let (m, f) = make()
        await m.load()
        m.reason = "r"; m.newName = "Gama"; m.newFrom = "Acme"
        await m.create()
        let a = await f.last("design.system.create")
        #expect(a?["name"] == .string("Gama") && a?["from"] == .string("Acme") && a?["reason"] == .string("r"))
    }
}
