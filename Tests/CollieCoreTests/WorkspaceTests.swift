import Testing
import Foundation
@testable import CollieCore

@Suite struct WorkspaceTests {
    @Test func decodesWithoutDesignFirst() throws {
        let json = #"{"schemaVersion":3,"id":"\#(UUID())","name":"w","terminals":[],"connections":[]}"#
        let w = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        #expect(w.designFirst == .ask)
        #expect(!String(decoding: try JSONEncoder().encode(w), as: UTF8.self).contains("designFirst"))
    }
    @Test func roundTripsDesignFirst() throws {
        for v in DesignFirst.allCases {
            var w = Workspace(id: UUID(), name: "w"); w.designFirst = v
            #expect(try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(w)).designFirst == v)
        }
    }
    @Test func invalidDesignFirstDecodesAsAsk() throws {
        for bad in [#""Always""#, "7", "null", "{}"] {
            let json = #"{"schemaVersion":3,"id":"\#(UUID())","name":"keep","terminals":[],"connections":[],"designFirst":\#(bad)}"#
            let w = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
            #expect(w.designFirst == .ask && w.name == "keep", "\(bad)")
        }
    }
}
