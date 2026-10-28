import Foundation
import Testing
@testable import CollieCore

@Suite struct PaddockModelTests {
    let fl = Paddock(id: UUID(), name: "auth", repoRoot: "/r", path: "/r/.collie/paddocks/auth", branch: "collie/auth", baseBranch: "main")

    @Test func decodesSchemaV1Workspace() throws {
        let id = UUID(), tid = UUID()
        let v1 = """
        {"schemaVersion":1,"id":"\(id)","name":"w","connections":[],
         "terminals":[{"id":"\(tid)","name":"t","preset":"shell","cwd":"/","isShepherd":false}]}
        """
        let ws = try JSONDecoder().decode(Workspace.self, from: Data(v1.utf8))
        #expect(ws.paddocks == [] && ws.terminals[0].paddockId == nil)
        let out = String(decoding: try JSONEncoder().encode(ws), as: UTF8.self)
        #expect(out.contains("\"schemaVersion\":3"))
    }

    @Test func paddockEventsRoundTrip() throws {
        let id = UUID()
        for (e, tag) in [(WorkspaceEvent.paddock(fl), "paddock"), (.paddockRemoved(id), "paddockRemoved"), (.notify(id, message: "hi"), "notify")] {
            let data = try JSONEncoder().encode(e)
            #expect(String(decoding: data, as: UTF8.self).contains("\"t\":\"\(tag)\""))
            #expect(try JSONDecoder().decode(WorkspaceEvent.self, from: data) == e)
        }
        #expect(fl.status == .working)
    }

    @Test func snapshotCarriesPaddocks() throws {
        let s = WorkspaceSnapshot(terminals: [], connections: [], badges: [:], paddocks: [fl])
        #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(s)).paddocks == [fl])
    }

    @Test func oldPaddocksDecodeAsWorktreesAndFolderRoundTrips() throws {
        var o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fl)) as! [String: Any]
        o["kind"] = nil
        let old = try JSONDecoder().decode(Paddock.self, from: JSONSerialization.data(withJSONObject: o))
        #expect(old == fl && old.kind == .worktree && old.gitBranch == "collie/auth")
        let f = Paddock.folder(name: "docs", path: "/d")
        let back = try JSONDecoder().decode(Paddock.self, from: JSONEncoder().encode(f))
        #expect(back == f && back.isFolder && back.gitBranch == nil && back.path == "/d" && back.repoRoot == "/d")
    }
}
