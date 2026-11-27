import Foundation
import Testing
import CollieCore
@testable import CollieApp

@Suite(.appPT) struct TerminalHeaderTests {
    func record(_ name: String = "alfa", shepherd: Bool = false, sandbox: TerminalSandbox = .sandboxed, model: String? = nil) -> TerminalRecord {
        var t = TerminalRecord(id: UUID(), name: name, preset: .claude, command: nil, cwd: "/x", isShepherd: shepherd, sandbox: sandbox)
        t.model = model
        return t
    }

    @Test func stateIsAWordPerBadge() {
        let t = record()
        func word(_ b: StatusBadge?) -> String { TerminalHeader.make(record: t, badge: b, connections: [], lot: nil).state.text }
        #expect(word(.working) == "trabalhando")
        #expect(word(.attention) == "esperando você")
        #expect(word(.idle) == "concluído")
        #expect(word(.stopped) == "parado")
    }

    @Test func noBadgeIsStopped() {
        #expect(TerminalHeader.make(record: record(), badge: nil, connections: [], lot: nil).state == .stopped)
    }

    @Test func shepherdGoesToTheMenuWithItsCount() {
        let t = record(shepherd: true)
        let h = TerminalHeader.make(record: t, badge: .working, connections: [Connection(a: t.id, b: UUID()), Connection(a: UUID(), b: t.id),
                                                                              Connection(a: UUID(), b: UUID())], lot: nil)
        #expect(h.title == "alfa")
        #expect(h.menuItems.contains("Pastor · pastoreando 2"))
        #expect(h.help.contains("Pastor · pastoreando 2"))
        #expect(!TerminalHeader.make(record: record(), badge: nil, connections: [], lot: nil).menuItems.contains { $0.hasPrefix("Pastor") })
    }

    @Test func toolModelAndSandboxInTheMenu() {
        let h = TerminalHeader.make(record: record(model: "claude-opus-5-5"), badge: nil, connections: [], lot: nil)
        #expect(h.menuItems == ["Ferramenta: claude", "Modelo: claude-opus-5-5", "Com sandbox"])
        #expect(h.warning == nil)
    }

    @Test func freeTerminalKeepsAVisibleWarning() {
        let h = TerminalHeader.make(record: record(sandbox: .free), badge: .working, connections: [], lot: nil)
        #expect(h.warning?.contains("sem sandbox") == true)
        #expect(h.menuItems.contains("Livre: sem sandbox"))
    }

    @Test func lotInTheMenu() {
        #expect(TerminalHeader.make(record: record(), badge: nil, connections: [], lot: Lot(name: "l10n")).menuItems.last == "Lote: l10n")
        #expect(TerminalHeader.make(record: record(), badge: nil, connections: [], lot: Lot(name: "l10n", goal: "traduzir")).menuItems.last
                == "Lote: l10n — traduzir")
    }

    /// The node's strip shows the oldest request first; refused cards (nothing to answer) go last; a free terminal has no cards.
    @Test func requestsOldestFirstRefusedLast() {
        let id = UUID(), t0 = Date(timeIntervalSince1970: 0)
        var old = SandboxDenial(terminal: id, op: "read", path: "/a/f", refusal: nil); old.at = t0.addingTimeInterval(10)
        var refused = SandboxDenial(terminal: id, op: "read", path: "/b/f", refusal: "nunca"); refused.at = t0
        let leash = LeashRequest(from: id, to: UUID(), reason: nil, at: t0.addingTimeInterval(5))
        let other = LeashRequest(from: UUID(), to: id, reason: nil, at: t0)
        let reqs = NodeRequest.of(id, sandboxed: true, leash: [leash, other], cards: [old, refused], apps: [])
        #expect(reqs == [.leash(leash), .access(old), .refused([refused])])
        #expect(NodeRequest.of(id, sandboxed: false, leash: [], cards: [old], apps: []).isEmpty)
    }

    /// An app card a terminal of this paddock raised is in that node; the others stay floating on the canvas.
    @Test func appCardsOfThisPaddocksTerminalsLeaveTheCanvas() {
        let pad = UUID(), here = record(), there = { var t = record("beta"); t.paddockId = UUID(); return t }()
        var mine = here; mine.paddockId = pad
        func card(by: UUID?) -> AppCard {
            AppCard(kind: .confirm, paddock: pad, paddockName: "p", app: "x", name: "X", base: nil, call: "restart", by: by)
        }
        let a = card(by: mine.id), b = card(by: there.id), c = card(by: nil)
        #expect(AppCardsView.floating([a, b, c], terminals: [mine, there], paddock: pad) == [b, c])
    }
}
