import Testing
import Foundation
import CollieCore
@testable import CollieClient

@Suite struct RestartAllTests {
    func rec(_ n: String, shepherd: Bool = false, paddock: UUID? = nil) -> TerminalRecord {
        TerminalRecord(id: UUID(), name: n, preset: .shell, command: nil, cwd: "/", isShepherd: shepherd, paddockId: paddock)
    }

    struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }

    @Test func restartsOnlyThisPaddockSkipsShepherdsAndKeepsGoingAfterAFailure() async {
        let p = UUID()
        let all = [rec("a", paddock: p), rec("bad", paddock: p), rec("pastor", shepherd: true, paddock: p),
                   rec("c", paddock: p), rec("other")]
        var called: [String] = []
        let r = await restartAll(all, paddock: p) { name in
            called.append(name)
            if name == "bad" { throw Boom() }
        }
        #expect(called == ["a", "bad", "c"])
        #expect(r.restarted == ["a", "c"])
        #expect(r.skipped == ["pastor"])
        #expect(r.failed.map(\.name) == ["bad"])
        #expect(r.failed.first?.error == "boom")
    }
}
