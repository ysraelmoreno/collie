import Testing
import Foundation
@testable import CollieCore

/// Data written before the herding vocabulary (Orq, or Collie before Task 6) still reads; only the new keys are written.
@Suite struct LegacyKeysTests {
    private let t = UUID(), f = UUID(), pn = UUID(), other = UUID()
    /// A workspace.json as it was written before: `floors`, `isMaestro`, `floorId`.
    private var legacyWorkspace: String {
        #"{"schemaVersion":3,"id":"\#(UUID())","name":"w","terminals":[{"id":"\#(t)","name":"M","preset":"claude","cwd":"/r/.collie/floors/f","isMaestro":true,"floorId":"\#(f)"}],"connections":[{"a":"\#(t)","b":"\#(pn)"},{"a":"\#(t)","b":"\#(other)"}],"floors":[{"id":"\#(f)","name":"f","repoRoot":"/r","path":"/r/.collie/floors/f","branch":"collie/f","baseBranch":"main","status":"working"}],"panels":[{"id":"\#(pn)","name":"web","pluginId":"browser","placement":"canvas","floorId":"\#(f)","state":{"url":"https://x.dev"}}]}"#
    }

    @Test func workspaceDecodesLegacyKeys() throws {
        let w = try JSONDecoder().decode(Workspace.self, from: Data(legacyWorkspace.utf8))
        #expect(w.paddocks.map(\.id) == [f] && w.paddocks[0].path == "/r/.collie/floors/f")   // the path stays as stored
        #expect(w.terminals[0].isShepherd && w.terminals[0].paddockId == f)
        #expect(w.panels[0].paddockId == f && w.panels[0].state["url"] == .string("https://x.dev"))
        let again = String(decoding: try JSONEncoder().encode(w), as: UTF8.self)
        for old in ["floors", "isMaestro", "maestro", "floorId"] { #expect(!again.contains("\"\(old)\""), "\(old)") }   // keys; a stored path keeps its words
        #expect(try JSONDecoder().decode(Workspace.self, from: Data(again.utf8)) == w)
    }

    /// The canvas's leashes are the workspace's `connections` (the layout file holds only frames): they come back the same.
    @Test func layoutDecodesLegacyCords() throws {
        let w = try JSONDecoder().decode(Workspace.self, from: Data(legacyWorkspace.utf8))
        #expect(w.connections == [Connection(a: t, b: pn), Connection(a: t, b: other)])
    }

    /// An `.orqpartitura` / `.colliepartitura` as Collie wrote it before (`wantsFloor`, `cords`, `isMaestro`).
    static let legacyPartitura = #"""
    {
      "cords" : [["maestro", "api"], ["api", "web"]],
      "format" : 1,
      "id" : "time",
      "name" : "Time",
      "panels" : [{"frame" : {"h" : 400, "w" : 640, "x" : 680, "y" : 0}, "key" : "web", "placement" : "canvas", "pluginId" : "browser", "state" : {}}],
      "summary" : "Maestro e api",
      "terminals" : [
        {"isMaestro" : true, "key" : "maestro", "preset" : "claude", "role" : "Coordene pelas cordas."},
        {"isMaestro" : false, "key" : "api", "preset" : "shell"}
      ],
      "wantsFloor" : true
    }
    """#

    @Test func herdDecodesLegacyPartitura() throws {
        let h = try HerdFormat.decode(Data(Self.legacyPartitura.utf8))
        #expect(h.wantsPaddock && h.leashes == [["maestro", "api"], ["api", "web"]])
        #expect(h.terminals.map(\.isShepherd) == [true, false] && h.terminals[0].role == "Coordene pelas cordas.")   // user data as written
        #expect(h.summary == "Maestro e api" && h.panels.map(\.key) == ["web"])
        // the preview and the apply both digest the decoded herd: the same value for the old file and its re-encoding
        let now = try HerdFormat.encode(h)
        #expect(HerdFormat.digest(h) == HerdFormat.digest(try HerdFormat.decode(now)))
        let text = String(decoding: now, as: UTF8.self)
        for old in ["wantsFloor", "cords", "isMaestro"] { #expect(!text.contains("\"\(old)\""), "\(old)") }
    }

    @Test func workAndMemoryDecodeLegacyKeys() throws {
        let work = #"{"id":"\#(UUID())","title":"x","terminalId":"\#(t)","floorId":"\#(f)","openedAt":0,"tasks":[],"jobs":[],"notes":[],"commits":[]}"#
        let w = try JSONDecoder().decode(Work.self, from: Data(work.utf8))
        let again = String(decoding: try JSONEncoder().encode(w), as: UTF8.self)
        #expect(w.paddockId == f && !again.contains("floorId"))
        let md = "---\nid: \(UUID().uuidString.lowercased())\nkind: decision\nscope: floor\nfloor: feat\nsubject: db\ntitle: T\nstatus: active\nreviewed: false\npinned: false\norigin: app\ncreated: 2026-01-01T00:00:00.000Z\nupdated: 2026-01-01T00:00:00.000Z\n---\n\nbody\n"
        let r = try MemoryFile.parse(md)
        #expect(r.scope == .paddock && r.paddock == "feat" && r.body == "body")
    }
}
