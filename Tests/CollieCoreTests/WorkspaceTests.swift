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
    @Test func decodesWithoutLots() throws {
        let json = #"{"schemaVersion":3,"id":"\#(UUID())","name":"w","terminals":[],"connections":[]}"#
        let w = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        #expect(w.lots.isEmpty)
        #expect(!String(decoding: try JSONEncoder().encode(w), as: UTF8.self).contains("lots"))
    }
    @Test func lotsRoundTripAndLotOf() throws {
        let t = UUID()
        var w = Workspace(id: UUID(), name: "w"); w.lots = [Lot(name: "a"), Lot(name: "b", goal: "g", members: [t])]
        let back = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(w))
        #expect(back == w && back.lot(of: t)?.name == "b" && back.lot(of: UUID()) == nil)
    }
    /// R2: a malformed lot entry (or field) never makes workspace.json fail to decode.
    @Test func malformedLotsNeverDiscardWorkspace() throws {
        let good = UUID(), m = UUID()
        for bad in [#""x""#, "7", "{}", #"[{"name":"no id"},{"id":"\#(good)","name":"ok","members":["\#(m)","bad",3],"createdAt":"x","paddockId":5}]"#] {
            let json = #"{"schemaVersion":3,"id":"\#(UUID())","name":"keep","terminals":[],"connections":[],"lots":\#(bad)}"#
            let w = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
            #expect(w.name == "keep", "\(bad)")
            if bad.hasPrefix("[") { #expect(w.lots.map(\.id) == [good] && w.lots[0].members == [m] && w.lots[0].paddockId == nil) }
            else { #expect(w.lots.isEmpty) }
        }
    }
}
