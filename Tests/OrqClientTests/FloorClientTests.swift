import Testing
import Foundation
import OrqCore
import OrqProtocol
@testable import OrqClient

@MainActor struct FloorClientTests {
    private func floor(_ n: String, _ s: FloorStatus = .working) -> Floor {
        Floor(id: UUID(), name: n, repoRoot: "/r", path: "/r/.orq/floors/\(n)", branch: "orq/\(n)", baseBranch: "main", status: s)
    }

    @Test func appliesFloorEvents() {
        let c = DaemonClient(paths: Paths(root: URL(fileURLWithPath: "/tmp/orq-none")))
        var f = floor("a")
        c.apply(.floor(f)); c.apply(.floor(floor("b")))
        #expect(c.floors.map(\.name) == ["a", "b"])
        f.status = .review
        c.apply(.floor(f))   // upsert by id
        #expect(c.floors.count == 2 && c.floors[0].status == .review)
        c.apply(.floorRemoved(f.id))
        #expect(c.floors.map(\.name) == ["b"])
    }

    @Test func notifyEventCallsHandler() {
        let c = DaemonClient(paths: Paths(root: URL(fileURLWithPath: "/tmp/orq-none")))
        var got: (UUID, String)?
        c.onNotify = { got = ($0, $1) }
        let id = UUID()
        c.apply(.notify(id, message: "pronto"))
        #expect(got?.0 == id && got?.1 == "pronto")
    }

    @Test func terminalsFilteredByFloor() {
        let fl = UUID()
        func t(_ n: String, _ f: UUID?) -> TerminalRecord {
            TerminalRecord(id: UUID(), name: n, preset: .shell, command: nil, cwd: "/", isMaestro: false, floorId: f)
        }
        let all = [t("g", nil), t("x", fl), t("y", UUID())]
        #expect(visibleTerminals(all, floor: nil).map(\.name) == ["g"])
        #expect(visibleTerminals(all, floor: fl).map(\.name) == ["x"])
    }
}
