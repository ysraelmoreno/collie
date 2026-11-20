import Foundation
import Testing
import CollieCore
@testable import CollieApp

private func term(_ name: String, shepherd: Bool = false, paddock: UUID? = nil, preset: Preset = .claude) -> TerminalRecord {
    TerminalRecord(id: UUID(), name: name, preset: preset, command: nil, cwd: "/", isShepherd: shepherd, paddockId: paddock)
}

private func rows(_ terminals: [TerminalRecord], _ connections: [Connection] = [], badges: [UUID: StatusBadge] = [:],
                  pending: [UUID: Int] = [:], paddock: UUID? = nil, collapsed: Set<UUID> = []) -> [AgentTree.Row] {
    AgentTree.rows(terminals: terminals, connections: connections, badges: badges, pending: pending, paddock: paddock, collapsed: collapsed)
}

@Suite struct AgentTreeTests {
    @Test func shepherdWithTwoChildrenAndALooseTerminal() {
        let loose = term("solto", preset: .shell), a = term("a"), main = term("Main", shepherd: true), b = term("b", preset: .codex)
        // The leash's direction doesn't matter; children keep creation order (a before b), not connection order.
        let out = rows([loose, a, main, b], [Connection(a: b.id, b: main.id), Connection(a: main.id, b: a.id)],
                       badges: [a.id: .working], pending: [b.id: 2])
        #expect(out.map(\.name) == ["Main", "a", "b", "solto"])
        #expect(out.map(\.depth) == [0, 1, 1, 0])
        #expect(out.map(\.isParent) == [true, false, false, false])
        #expect(out.map(\.isCollapsed) == [false, false, false, false])
        #expect(out.map(\.status) == [nil, .working, nil, nil])
        #expect(out.map(\.pending) == [0, 0, 2, 0])
        #expect(out.map(\.preset) == [.claude, .claude, .codex, .shell])
        #expect(out.map(\.id) == [main.id, a.id, b.id, loose.id])
    }

    @Test func collapsingHidesOnlyTheChildren() {
        let main = term("Main", shepherd: true), a = term("a"), b = term("b"), loose = term("solto")
        let out = rows([main, a, b, loose], [Connection(a: main.id, b: a.id), Connection(a: main.id, b: b.id)], collapsed: [main.id])
        #expect(out.map(\.name) == ["Main", "solto"])
        #expect(out[0].isParent && out[0].isCollapsed)
        #expect(!out[1].isCollapsed)
    }

    @Test func noShepherdIsAFlatList() {
        let a = term("a"), b = term("b"), c = term("c")
        let out = rows([a, b, c], [Connection(a: a.id, b: b.id)], collapsed: [a.id])
        #expect(out.map(\.name) == ["a", "b", "c"])
        #expect(out.allSatisfy { $0.depth == 0 && !$0.isParent && !$0.isCollapsed })
    }

    @Test func terminalLeashedToTwoShepherdsAppearsOnce() {
        let s1 = term("S1", shepherd: true), s2 = term("S2", shepherd: true), shared = term("shared"), own = term("own")
        let out = rows([s1, s2, shared, own], [Connection(a: s2.id, b: shared.id), Connection(a: s1.id, b: shared.id),
                                              Connection(a: s2.id, b: own.id), Connection(a: s1.id, b: s2.id)])
        // Under the first Shepherd; a Shepherd leashed to another stays a root.
        #expect(out.map(\.name) == ["S1", "shared", "S2", "own"])
        #expect(out.map(\.depth) == [0, 1, 0, 1])
    }

    @Test func terminalsOfAnotherPaddockStayOut() {
        let p = UUID(), other = UUID()
        let main = term("Main", shepherd: true, paddock: p), a = term("a", paddock: p)
        let foreign = term("fora", paddock: other), pasture = term("pasto")
        let leashes = [main.id, main.id, main.id].enumerated().map { Connection(a: $1, b: [a, foreign, pasture][$0].id) }
        #expect(rows([main, a, foreign, pasture], leashes, paddock: p).map(\.name) == ["Main", "a"])
    }

    @Test func pastureIsNil() {
        let p = UUID()
        let inPaddock = term("Main", shepherd: true, paddock: p), a = term("a"), b = term("b")
        let out = rows([inPaddock, a, b], [Connection(a: inPaddock.id, b: a.id)], paddock: nil)
        // The Shepherd lives in a paddock: the Pasto has none, so it is flat.
        #expect(out.map(\.name) == ["a", "b"])
        #expect(out.map(\.depth) == [0, 0])
    }

    @Test func cardsCountPerTerminal() {
        let a = UUID(), b = UUID(), paddock = UUID()
        func app(by: UUID?) -> AppCard { AppCard(kind: .confirm, paddock: paddock, paddockName: "api", app: "x", name: "X", base: nil, by: by) }
        let counts = AgentTree.pending(
            accessCards: [SandboxDenial(terminal: a, op: "write", path: "/x/y"), SandboxDenial(terminal: a, op: "read", path: "/x/z")],
            leashRequests: [LeashRequest(from: b, to: a, reason: nil)],
            appCards: [app(by: a), app(by: b)])
        #expect(counts == [a: 3, b: 2])
    }

    @Test func cardWithoutAKnownTerminalDoesNotCount() {
        let paddock = UUID(), gone = UUID(), a = term("a")
        let counts = AgentTree.pending(accessCards: [], leashRequests: [],
                                       appCards: [AppCard(kind: .approve, paddock: paddock, paddockName: "api", app: "x", name: "X", base: nil, by: nil)])
        #expect(counts.isEmpty)
        // A card of a terminal that isn't in the list reaches no row.
        let out = rows([a], pending: AgentTree.pending(accessCards: [SandboxDenial(terminal: gone, op: "read", path: "/x/y")], leashRequests: [], appCards: []))
        #expect(out.map(\.pending) == [0])
    }
}
