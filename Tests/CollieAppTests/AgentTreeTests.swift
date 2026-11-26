import Foundation
import Testing
import CollieCore
@testable import CollieApp

private func term(_ name: String, shepherd: Bool = false, paddock: UUID? = nil, preset: Preset = .claude, by: TerminalRecord? = nil) -> TerminalRecord {
    var t = TerminalRecord(id: UUID(), name: name, preset: preset, command: nil, cwd: "/", isShepherd: shepherd, paddockId: paddock)
    t.summonedBy = by?.id
    return t
}

private func rows(_ terminals: [TerminalRecord], _ connections: [Connection] = [], badges: [UUID: StatusBadge] = [:],
                  pending: [UUID: Int] = [:], paddock: UUID? = nil, collapsed: Set<UUID> = []) -> [AgentTree.Row] {
    AgentTree.rows(terminals: terminals, connections: connections, badges: badges, pending: pending, paddock: paddock, collapsed: collapsed)
}

@Suite(.appPT) struct AgentTreeTests {
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

    @Test func subShepherdNestsUnderItsSummonerWithItsWorkers() {
        let main = term("Main", shepherd: true), sub = term("Sub", shepherd: true, by: main), w1 = term("w1", by: sub), w2 = term("w2", by: sub)
        let own = term("own", by: main), loose = term("solto")
        // summon leashes: the sub and its workers are leashed to whoever summoned them
        let leashes = [Connection(a: main.id, b: sub.id), Connection(a: sub.id, b: w1.id), Connection(a: sub.id, b: w2.id), Connection(a: main.id, b: own.id)]
        let out = rows([main, sub, w1, w2, own, loose], leashes)
        #expect(out.map(\.name) == ["Main", "Sub", "w1", "w2", "own", "solto"])
        #expect(out.map(\.depth) == [0, 1, 2, 2, 1, 0])
        #expect(out.map(\.isParent) == [true, true, false, false, false, false])
        #expect(out.map(\.summonedByName) == [nil, "Main", nil, nil, nil, nil])
    }

    @Test func collapsingASubShepherdHidesOnlyItsWorkers() {
        let main = term("Main", shepherd: true), sub = term("Sub", shepherd: true, by: main), w = term("w", by: sub)
        let leashes = [Connection(a: main.id, b: sub.id), Connection(a: sub.id, b: w.id)]
        #expect(rows([main, sub, w], leashes, collapsed: [sub.id]).map(\.name) == ["Main", "Sub"])
        #expect(rows([main, sub, w], leashes, collapsed: [main.id]).map(\.name) == ["Main"])
    }

    @Test func threeLevelsOfShepherdsReachDepthThree() {
        let a = term("A", shepherd: true), b = term("B", shepherd: true, by: a), c = term("C", shepherd: true, by: b), w = term("w", by: c)
        let out = rows([a, b, c, w], [Connection(a: a.id, b: b.id), Connection(a: b.id, b: c.id), Connection(a: c.id, b: w.id)])
        #expect(out.map(\.depth) == [0, 1, 2, 3])
    }

    @Test func subShepherdWhoseSummonerIsGoneStaysARoot() {
        let gone = term("gone", shepherd: true), sub = term("Sub", shepherd: true, by: gone), w = term("w", by: sub)
        let out = rows([sub, w], [Connection(a: sub.id, b: w.id)])
        #expect(out.map(\.name) == ["Sub", "w"] && out.map(\.depth) == [0, 1])
        #expect(out[0].summonedByName == nil)   // no live summoner to name
    }

    @Test func summonedWorkerTurnedOffShepherdStillSitsUnderItsSummoner() {
        // "switch off": it stops summoning, the ones it summoned stay alive (loose at the root, as without a Shepherd)
        let main = term("Main", shepherd: true), was = term("was", by: main), w = term("w", by: was)
        let out = rows([main, was, w], [Connection(a: main.id, b: was.id), Connection(a: was.id, b: w.id)])
        #expect(out.map(\.name) == ["Main", "was", "w"] && out.map(\.depth) == [0, 1, 0])
    }

    @Test func endBranchIsOfferedForASingleTerminalWithSummoned() {
        let plain = NodeInfo(id: UUID(), name: "a", kind: .terminal(isClaude: false))
        var branch = plain; branch.hasBranch = true
        #expect(NodeActions.available(for: [branch]) == [.fullscreen, .edit, .restart, .kill, .endBranch, .lot, .close])
        #expect(NodeActions.available(for: [plain]) == [.fullscreen, .edit, .restart, .kill, .lot, .close])
        #expect(!NodeActions.available(for: [branch, plain]).contains(.endBranch))   // one at a time
        let c = NodeActions.confirmation(for: .endBranch, items: [branch])
        #expect(c?.title == "Encerrar o ramo de a?" && c?.button == "Encerrar ramo")
    }
}
