import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieClient

@MainActor struct PaddockClientTests {
    private func paddock(_ n: String, _ s: PaddockStatus = .working) -> Paddock {
        Paddock(id: UUID(), name: n, repoRoot: "/r", path: "/r/.collie/paddocks/\(n)", branch: "collie/\(n)", baseBranch: "main", status: s)
    }

    @Test func appliesPaddockEvents() {
        let c = DaemonClient(paths: Paths(root: URL(fileURLWithPath: "/tmp/collie-none")))
        var f = paddock("a")
        c.apply(.paddock(f)); c.apply(.paddock(paddock("b")))
        #expect(c.paddocks.map(\.name) == ["a", "b"])
        f.status = .review
        c.apply(.paddock(f))   // upsert by id
        #expect(c.paddocks.count == 2 && c.paddocks[0].status == .review)
        c.apply(.paddockRemoved(f.id))
        #expect(c.paddocks.map(\.name) == ["b"])
    }

    @Test func notifyEventCallsHandler() {
        let c = DaemonClient(paths: Paths(root: URL(fileURLWithPath: "/tmp/collie-none")))
        var got: (UUID, String)?
        c.onNotify = { got = ($0, $1) }
        let id = UUID()
        c.apply(.notify(id, message: "pronto"))
        #expect(got?.0 == id && got?.1 == "pronto")
    }

    @Test func terminalsFilteredByPaddock() {
        let fl = UUID()
        func t(_ n: String, _ f: UUID?) -> TerminalRecord {
            TerminalRecord(id: UUID(), name: n, preset: .shell, command: nil, cwd: "/", isShepherd: false, paddockId: f)
        }
        let all = [t("g", nil), t("x", fl), t("y", UUID())]
        #expect(visibleTerminals(all, paddock: nil).map(\.name) == ["g"])
        #expect(visibleTerminals(all, paddock: fl).map(\.name) == ["x"])
    }
}
