import Foundation
import Testing
import CollieCore
@testable import CollieApp

private func term(_ name: String, shepherd: Bool = false, paddock: UUID? = nil) -> TerminalRecord {
    TerminalRecord(id: UUID(), name: name, preset: .claude, command: nil, cwd: "/", isShepherd: shepherd, paddockId: paddock)
}

private func paddock(_ name: String) -> Paddock {
    Paddock(id: UUID(), name: name, repoRoot: "/r", path: "/r/\(name)", branch: "collie/\(name)", baseBranch: "main")
}

private func panel(_ name: String, paddock: UUID?, by: UUID? = nil) -> Panel {
    Panel(id: UUID(), name: name, pluginId: "preview", placement: .canvas, paddockId: paddock, createdBy: by)
}

@Suite(.appPT) struct SidebarModelTests {
    @Test func stateInWordsRequestBeatsWorking() {
        let a = paddock("a"), b = paddock("b"), c = paddock("c")
        let a1 = term("a1", paddock: a.id), a2 = term("a2", paddock: a.id), b1 = term("b1", paddock: b.id), b2 = term("b2", paddock: b.id)
        let rows = SidebarModel.paddockRows(paddocks: [a, b, c], terminals: [a1, a2, b1, b2],
                                            badges: [a1.id: .working, b1.id: .working, b2.id: .working],
                                            pending: [a2.id: 1], current: c.id)
        #expect(rows.map(\.name) == ["a", "b", "c"])   // empty Pasto, a paddock selected: hidden (rail rule)
        #expect(rows.map(\.status) == ["espera você", "2 trabalhando", "parado"])
        #expect(rows.map(\.isCurrent) == [false, false, true])
        #expect(rows[0].branch == "collie/a ← main")
    }

    @Test func pastoIncludedWithContent() {
        let a = paddock("a"), loose = term("solto")
        let rows = SidebarModel.paddockRows(paddocks: [a], terminals: [loose], badges: [loose.id: .attention], pending: [:], current: a.id)
        #expect(rows.map(\.id) == [nil, a.id])
        #expect(rows[0].name == "Pasto")
        #expect(rows[0].branch == nil)
        #expect(rows[0].status == "espera você")
        // selected Pasto shows even when empty
        #expect(SidebarModel.paddockRows(paddocks: [a], terminals: [], badges: [:], pending: [:], current: nil).first?.id == nil)
    }

    @Test func needsSumsTheRequestsOfThePaddocksAgents() {
        let a = paddock("a"), x = term("x", paddock: a.id), y = term("y", paddock: a.id), other = term("o")
        let rows = SidebarModel.paddockRows(paddocks: [a], terminals: [x, y, other], badges: [:],
                                            pending: [x.id: 2, y.id: 1, other.id: 5], current: a.id)
        #expect(rows.first { $0.id == a.id }?.needs == 3)
        #expect(rows.first { $0.id == nil }?.needs == 5)
    }

    @Test func panelUnderItsOpenerOwnerlessAtTheEnd() {
        let f = paddock("f"), main = term("Main", shepherd: true, paddock: f.id), w = term("w", paddock: f.id), solo = term("solo", paddock: f.id)
        let p1 = panel("p1", paddock: f.id, by: w.id), p2 = panel("p2", paddock: f.id), p3 = panel("p3", paddock: f.id, by: UUID())
        let elsewhere = panel("x", paddock: UUID(), by: w.id)
        let out = SidebarModel.tree(terminals: [main, w, solo], connections: [Connection(a: main.id, b: w.id)], badges: [:], pending: [:],
                                    panels: [p2, p1, p3, elsewhere], paddock: f.id, collapsed: [])
        #expect(out.map(\.id) == [main.id, w.id, p1.id, solo.id, p2.id, p3.id])
        #expect(out.map(\.depth) == [0, 1, 2, 0, 0, 0])
        #expect(out.map(\.role) == ["Pastor", nil, nil, nil, nil, nil])
    }

    @Test func collapsedShepherdHidesItsWorkersPanels() {
        let f = paddock("f"), main = term("Main", shepherd: true, paddock: f.id), w = term("w", paddock: f.id)
        let p = panel("p", paddock: f.id, by: w.id)
        let out = SidebarModel.tree(terminals: [main, w], connections: [Connection(a: main.id, b: w.id)], badges: [:], pending: [:],
                                    panels: [p], paddock: f.id, collapsed: [main.id])
        #expect(out.map(\.id) == [main.id])
    }

    @Test func subShepherdNestsThroughAgentTree() {
        let f = paddock("f"), main = term("Main", shepherd: true, paddock: f.id)
        var sub = term("Sub", shepherd: true, paddock: f.id); sub.summonedBy = main.id
        var w = term("w", paddock: f.id); w.summonedBy = sub.id
        let out = SidebarModel.tree(terminals: [main, sub, w], connections: [], badges: [:], pending: [:], panels: [], paddock: f.id, collapsed: [])
        #expect(out.map(\.depth) == [0, 1, 2])
        #expect(out.map(\.role) == ["Pastor", "Pastor", nil])
    }

    @Test(arguments: [("collie-general-working", "CG"), ("idiomas", "ID"), ("Pasto", "PA"), ("água fria", "ÁF"),
                      ("ação", "AÇ"), ("x", "X"), ("-", "?"), ("meu cercado", "MC")])
    func initials(_ name: String, _ expected: String) {
        #expect(SidebarModel.initials(name) == expected)
    }
}
