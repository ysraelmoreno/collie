import Foundation
import Testing
import CollieCore
@testable import CollieApp

private func term(_ name: String) -> TerminalRecord {
    TerminalRecord(id: UUID(), name: name, preset: .claude, command: nil, cwd: "/", isShepherd: false)
}

private func app(_ kind: AppCard.Kind, by: UUID?, at: Date, call: String? = nil) -> AppCard {
    AppCard(kind: kind, paddock: UUID(), paddockName: "p", app: "svc", name: "api", base: nil, call: call, by: by, at: at)
}

@Suite(.appPT) struct SidebarFooterTests {
    let a = term("ana"), b = term("bia")
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func countsTheThreeKindsOldestFirst() {
        let items = NeedsYou.items(
            accessCards: [SandboxDenial(terminal: a.id, op: "write", path: "/etc/x", at: t0.addingTimeInterval(20))],
            leashRequests: [LeashRequest(from: b.id, to: a.id, reason: nil, at: t0)],
            appCards: [app(.confirm, by: a.id, at: t0.addingTimeInterval(10), call: "restart api")],
            terminals: [a, b])
        #expect(items.count == 3)
        #expect(items.map(\.agent) == ["bia", "ana", "ana"])
        #expect(items.map(\.terminal) == [b.id, a.id, a.id])
        if case .leash = items[0].request {} else { Issue.record("leash first") }
        #expect(items.map(\.phrase) == ["quer uma coleira para ana", "app api pede: restart api", "quer escrever fora do projeto"])
    }

    @Test func phrasePerKind() {
        let read = NeedsYou.items(accessCards: [SandboxDenial(terminal: a.id, op: "read", path: "/x/y")], leashRequests: [],
                                  appCards: [], terminals: [a])
        #expect(read.first?.phrase == "quer ler fora do projeto")
        let approve = NeedsYou.items(accessCards: [], leashRequests: [], appCards: [app(.approve, by: a.id, at: t0)], terminals: [a])
        #expect(approve.first?.phrase == "app api pede aprovação")
        let unknown = NeedsYou.items(accessCards: [], leashRequests: [LeashRequest(from: a.id, to: UUID(), reason: nil)],
                                     appCards: [], terminals: [])
        #expect(unknown.first?.agent == "?")
    }

    @Test func userAppCardCountsWithoutTerminal() {
        let cards = [app(.approve, by: nil, at: t0), app(.confirm, by: b.id, at: t0.addingTimeInterval(1), call: "x")]
        let items = NeedsYou.items(accessCards: [], leashRequests: [], appCards: cards, terminals: [a, b])
        #expect(items.map(\.terminal) == [nil, b.id])   // the user's card: listed, no "Ver no canvas"
        #expect(items.map(\.agent) == [nil, "bia"])
    }

    @Test func refusedCardOnlyDismisses() {
        let c = SandboxDenial(terminal: a.id, op: "read", path: "/x/.ssh/id", refusal: "segredo")
        let items = NeedsYou.items(accessCards: [c], leashRequests: [], appCards: [], terminals: [a])
        #expect(items.map(\.request) == [.refused([c])])
        #expect(items.first?.phrase == "teve um acesso bloqueado de propósito")
    }

    @Test func emptyListHidesTheItem() {
        #expect(NeedsYou.items(accessCards: [], leashRequests: [], appCards: [], terminals: [a]).isEmpty)
    }

    @Test func idsAreUnique() {
        let items = NeedsYou.items(
            accessCards: [SandboxDenial(terminal: a.id, op: "read", path: "/x/y"), SandboxDenial(terminal: a.id, op: "write", path: "/x/y")],
            leashRequests: [LeashRequest(from: a.id, to: b.id, reason: nil)], appCards: [app(.confirm, by: a.id, at: t0)], terminals: [a, b])
        #expect(Set(items.map(\.id)).count == 4)
    }
}
