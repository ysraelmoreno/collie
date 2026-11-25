import Testing
import Foundation
@testable import CollieCore

@Suite struct WorkspaceTests {
    /// F4: a record from before fields has none; one with a field keeps it through a save.
    @Test func oldRecordWithoutField() throws {
        let json = #"{"id":"\#(UUID())","name":"bob","preset":"claude","cwd":"/tmp","isShepherd":false}"#
        var t = try JSONDecoder().decode(TerminalRecord.self, from: Data(json.utf8))
        #expect(t.field == nil)
        t.field = FieldRef(name: "bob", branch: "collie/field/bob", base: "abc1234", path: "/r/.collie/paddocks/field-bob", state: .ready)
        let back = try JSONDecoder().decode(TerminalRecord.self, from: try JSONEncoder().encode(t))
        #expect(back.field == t.field && back.field?.state == .ready)
        // a state this daemon does not know: the record still decodes, without its field
        let odd = String(decoding: try JSONEncoder().encode(t), as: UTF8.self).replacingOccurrences(of: "\"ready\"", with: "\"later\"")
        #expect(try JSONDecoder().decode(TerminalRecord.self, from: Data(odd.utf8)).field == nil)
    }
    @Test func decodesWithoutDesignFirst() throws {
        let json = #"{"schemaVersion":3,"id":"\#(UUID())","name":"w","terminals":[],"connections":[]}"#
        let w = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        #expect(w.designFirst == .artifact)
        #expect(!String(decoding: try JSONEncoder().encode(w), as: UTF8.self).contains("designFirst"))
    }
    @Test func roundTripsDesignFirst() throws {
        for v in DesignFirst.allCases {
            var w = Workspace(id: UUID(), name: "w"); w.designFirst = v
            #expect(try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(w)).designFirst == v)
        }
    }
    @Test func invalidDesignFirstDecodesAsArtifact() throws {
        for bad in [#""Always""#, "7", "null", "{}"] {
            let json = #"{"schemaVersion":3,"id":"\#(UUID())","name":"keep","terminals":[],"connections":[],"designFirst":\#(bad)}"#
            let w = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
            #expect(w.designFirst == .artifact && w.name == "keep", "\(bad)")
        }
    }
    /// "Onde desenhar" replaced "design primeiro": always → figcraft, never → artifact, ask stays.
    @Test func oldDesignFirstValuesMigrate() throws {
        for (old, new) in [("always", DesignFirst.figcraft), ("never", .artifact), ("ask", .ask), ("figcraft", .figcraft)] {
            let json = #"{"schemaVersion":3,"id":"\#(UUID())","name":"w","terminals":[],"connections":[],"designFirst":"\#(old)"}"#
            #expect(try JSONDecoder().decode(Workspace.self, from: Data(json.utf8)).designFirst == new, "\(old)")
            #expect(DesignFirst.parse(old) == new)
        }
        #expect(DesignFirst.parse("sometimes") == nil)
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
    @Test func unknownPresetDecodesAsCustom() throws {
        let t = #"{"id":"\#(UUID())","name":"w1","preset":"warp","command":"warp --x","cwd":"/tmp","isShepherd":false}"#
        let json = #"{"schemaVersion":3,"id":"\#(UUID())","name":"keep","terminals":[\#(t)],"connections":[]}"#
        let w = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        #expect(w.name == "keep" && w.terminals.map(\.preset) == [.custom] && w.terminals[0].command == "warp --x")
        #expect(try JSONDecoder().decode(Preset.self, from: Data(#""cursor""#.utf8)) == .cursor)
    }
}
