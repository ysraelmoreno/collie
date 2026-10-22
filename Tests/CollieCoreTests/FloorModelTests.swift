import Foundation
import Testing
@testable import CollieCore

@Suite struct FloorModelTests {
    let fl = Floor(id: UUID(), name: "auth", repoRoot: "/r", path: "/r/.collie/floors/auth", branch: "collie/auth", baseBranch: "main")

    @Test func decodesSchemaV1Workspace() throws {
        let id = UUID(), tid = UUID()
        let v1 = """
        {"schemaVersion":1,"id":"\(id)","name":"w","connections":[],
         "terminals":[{"id":"\(tid)","name":"t","preset":"shell","cwd":"/","isMaestro":false}]}
        """
        let ws = try JSONDecoder().decode(Workspace.self, from: Data(v1.utf8))
        #expect(ws.floors == [] && ws.terminals[0].floorId == nil)
        let out = String(decoding: try JSONEncoder().encode(ws), as: UTF8.self)
        #expect(out.contains("\"schemaVersion\":3"))
    }

    @Test func floorEventsRoundTrip() throws {
        let id = UUID()
        for (e, tag) in [(WorkspaceEvent.floor(fl), "floor"), (.floorRemoved(id), "floorRemoved"), (.notify(id, message: "hi"), "notify")] {
            let data = try JSONEncoder().encode(e)
            #expect(String(decoding: data, as: UTF8.self).contains("\"t\":\"\(tag)\""))
            #expect(try JSONDecoder().decode(WorkspaceEvent.self, from: data) == e)
        }
        #expect(fl.status == .working)
    }

    @Test func snapshotCarriesFloors() throws {
        let s = WorkspaceSnapshot(terminals: [], connections: [], badges: [:], floors: [fl])
        #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(s)).floors == [fl])
    }
}
