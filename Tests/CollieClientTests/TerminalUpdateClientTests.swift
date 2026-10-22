import Testing
import Foundation
import CollieCore
@testable import CollieClient

@MainActor @Suite struct TerminalUpdateClientTests {
    @Test func terminalEventUpsertsById() {
        let id = UUID()
        let c = DaemonClient()
        c.apply(.spawned(TerminalRecord(id: id, name: "a", preset: .shell, command: nil, cwd: "/tmp", isMaestro: false)))
        let edited = TerminalRecord(id: id, name: "b", preset: .custom, command: "x", cwd: "/", isMaestro: true)
        c.apply(.terminal(edited))
        #expect(c.terminals == [edited])
    }

    @Test func terminalEventRoundTrips() throws {
        let e = WorkspaceEvent.terminal(TerminalRecord(id: UUID(), name: "a", preset: .shell, command: nil, cwd: "/tmp", isMaestro: true))
        #expect(try JSONDecoder().decode(WorkspaceEvent.self, from: JSONEncoder().encode(e)) == e)
    }

    @Test func editArgsSendsOnlyChanges() {
        let o = TerminalRecord(id: UUID(), name: "a", preset: .shell, command: nil, cwd: "/tmp", isMaestro: false)
        let a = editArgs(original: o, name: "  a ", maestro: true, preset: .shell, command: "", cwd: "/tmp")
        #expect(a.newName == nil && a.maestro == true && a.preset == nil && a.command == nil && a.cwd == nil)
        let b = editArgs(original: o, name: "b", maestro: false, preset: .custom, command: " ls ", cwd: "/x")
        #expect(b.newName == "b" && b.maestro == nil && b.preset == .custom && b.command == "ls" && b.cwd == "/x")
    }
}
