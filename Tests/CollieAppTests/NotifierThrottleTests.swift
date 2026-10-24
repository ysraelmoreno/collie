import Testing
import Foundation
import CollieCore
@testable import CollieApp
@testable import CollieClient

@Test func firstCardPosts() { var g = AccessNotifyGate(); let r = g.shouldPost(terminal: UUID()); #expect(r) }
@Test func secondWithin30sSkipped() {
    var g = AccessNotifyGate(); let t = UUID(), n = Date()
    let a = g.shouldPost(terminal: t, at: n), b = g.shouldPost(terminal: t, at: n + 29)
    #expect(a); #expect(!b)
}
@Test func after30sPosts() {
    var g = AccessNotifyGate(); let t = UUID(), n = Date()
    let a = g.shouldPost(terminal: t, at: n), b = g.shouldPost(terminal: t, at: n + 30)
    #expect(a); #expect(b)
}
@Test func otherTerminalIndependent() {
    var g = AccessNotifyGate(); let n = Date()
    let a = g.shouldPost(terminal: UUID(), at: n), b = g.shouldPost(terminal: UUID(), at: n)
    #expect(a); #expect(b)
}

@MainActor private func fed(_ cards: [SandboxDenial]) -> Int {
    let c = DaemonClient(), n = Box()
    c.onAccessCard = { _ in n.v += 1 }
    for d in cards { c.apply(.sandboxDenied(d)) }
    return n.v
}
private final class Box: @unchecked Sendable { var v = 0 }

@Test @MainActor func updateOfSameCardNeverPosts() {
    let t = UUID()
    #expect(fed([SandboxDenial(terminal: t, op: "read", path: "/a/b"), SandboxDenial(terminal: t, op: "read", path: "/a/c", count: 5)]) == 1)
}
@Test @MainActor func refusedCardNeverPosts() {
    #expect(fed([SandboxDenial(terminal: UUID(), op: "read", path: "/a/b", refusal: "nunca")]) == 0)
}
