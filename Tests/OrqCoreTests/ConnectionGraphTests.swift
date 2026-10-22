import Testing
import Foundation
import OrqProtocol
@testable import OrqCore

private func term(_ n: String, maestro: Bool = false) -> TerminalRecord {
    TerminalRecord(id: UUID(), name: n, preset: .shell, command: nil, cwd: "/", isMaestro: maestro)
}
private func ws(_ t: [TerminalRecord], _ c: [(Int, Int)] = []) -> Workspace {
    Workspace(id: UUID(), name: "w", terminals: t, connections: c.map { Connection(a: t[$0.0].id, b: t[$0.1].id) })
}
private func code(_ f: () throws -> TerminalRecord) -> ProtocolError? {
    do { _ = try f(); return nil } catch { return error as? ProtocolError }
}

@Test func resolvesOnlyConnected() throws {
    let t = [term("A"), term("B"), term("C")]
    let w = ws(t, [(0, 1)])
    #expect(try ConnectionGraph.resolve(name: "B", from: t[0].id, in: w).id == t[1].id)
    let e = code { try ConnectionGraph.resolve(name: "C", from: t[0].id, in: w) }
    #expect(e?.code == .notConnected)
    #expect(e?.message.contains("C") == true)
}
@Test func resolveUnknownName() {
    let t = [term("A")]
    #expect(code { try ConnectionGraph.resolve(name: "Z", from: t[0].id, in: ws(t)) }?.code == .notFound)
}
@Test func resolveAmbiguous() {
    let t = [term("A"), term("B"), term("B")]
    #expect(code { try ConnectionGraph.resolve(name: "B", from: t[0].id, in: ws(t, [(0, 1), (0, 2)])) }?.code == .ambiguous)
}
@Test func maestroReachesOnlyCorded() {
    let t = [term("A", maestro: true), term("B"), term("C")]
    let w = ws(t, [(0, 1)])
    #expect(ConnectionGraph.reachable(from: t[0].id, in: w).map(\.name) == ["B"])
    #expect(code { try ConnectionGraph.resolve(name: "C", from: t[0].id, in: w) }?.code == .notConnected)
}
@Test func nameMatchIsCaseInsensitive() throws {
    let t = [term("A"), term("Reviewer")]
    #expect(try ConnectionGraph.resolve(name: "reviewer", from: t[0].id, in: ws(t, [(1, 0)])).name == "Reviewer")
}
