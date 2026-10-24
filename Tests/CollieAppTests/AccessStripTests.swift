import Testing
import Foundation
import CollieCore
@testable import CollieApp

private func card(_ i: Int, refused: Bool = false) -> SandboxDenial {
    SandboxDenial(terminal: UUID(), op: "read", path: "/x/\(i)/f", refusal: refused ? "nunca" : nil)
}

@Test func noCardsNoStrip() {
    let m = AccessStrip.Model(cards: [])
    #expect(m.kind == .none)
    #expect(m.text == "")
}

@Test func pendingText() {
    #expect(AccessStrip.Model(cards: (0..<3).map { card($0) }).text == "3 pedidos de acesso — ver")
    #expect(AccessStrip.Model(cards: [card(0)]).text == "O agente pediu acesso — ver")
}

@Test func refusedOnly() {
    let m = AccessStrip.Model(cards: [card(0, refused: true), card(1, refused: true)])
    #expect(m.kind == .refusedOnly(2))
    #expect(m.text == "2 acessos bloqueados de propósito")
}

@Test func mixedCountsGrantableOnly() {
    let m = AccessStrip.Model(cards: (0..<2).map { card($0) } + (2..<7).map { card($0, refused: true) })
    #expect(m.kind == .pending(2))
}

@Test func singularRefusedText() {
    #expect(AccessStrip.Model(cards: [card(0, refused: true)]).text == "1 acesso bloqueado de propósito")
}

@Test func mixedText() {
    #expect(AccessStrip.Model(cards: [card(0), card(1), card(2, refused: true)]).text == "2 pedidos de acesso — ver")
}

@Test @MainActor func popoverStateClose() {
    let s = AccessPopoverState(), id = UUID()
    s.open.insert(id)
    s.close(id)
    #expect(!s.open.contains(id))
}
