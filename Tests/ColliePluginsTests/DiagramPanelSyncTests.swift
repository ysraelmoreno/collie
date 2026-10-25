import AppKit
import Foundation
import Testing
import CollieCore
import CollieProtocol
@testable import ColliePlugins

/// The panel against the vendored draw.io build (skipped without `scripts/build-drawio.sh`): the file is created and
/// loaded, an outside change is merged in, and draw.io's own autosaves never count as user edits.
@MainActor @Suite(.serialized) struct DiagramPanelSyncTests {
    static let web = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("vendor/drawio/web")

    func mount(root: URL, file: String? = nil) -> (DiagramPanel, NSWindow) {
        var state: [String: JSONValue] = ["root": .string(root.path)]
        if let file { state["file"] = .string(file) }
        let p = Panel(id: UUID(), name: "arq", pluginId: "diagram", placement: .canvas, state: state)
        let host = PanelHostContext(panel: p, root: root, workspaceId: nil, call: { _, _ throws(ProtocolError) in .null }, emit: { _, _ in })
        let panel = DiagramPanel(panel: p, host: host, webRoot: Self.web)
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        panel.view.frame = w.contentView!.bounds
        w.contentView!.addSubview(panel.view)
        return (panel, w)
    }
    func project() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("diagram-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func createsLoadsAndMergesOutsideChanges() async throws {
        guard FileManager.default.fileExists(atPath: Self.web.appendingPathComponent("index.html").path) else {
            print("skipped: vendor/drawio/web missing (run scripts/build-drawio.sh)"); return
        }
        let root = try project()
        let (panel, w) = mount(root: root)
        defer { panel.close(); w.close() }
        let file = try #require(panel.file)
        #expect(file.path.hasSuffix("/docs/diagrams/arq.drawio"))
        #expect(try String(contentsOf: file, encoding: .utf8) == DiagramFile.empty)
        #expect(await pollUntil(30) { panel.seen.contains("load") }, "\(panel.seen)")
        #expect(panel.lastUserEditAt == nil)

        // an agent writes the file directly: merged within 1 s, and the merge's autosave is not the user's
        let agent = #"<mxfile><diagram id="p1" name="Página-1"><mxGraphModel><root><mxCell id="0"/><mxCell id="1" parent="0"/><mxCell id="a" value="Agente" vertex="1" parent="1"><mxGeometry x="10" y="10" width="80" height="40" as="geometry"/></mxCell></root></mxGraphModel></diagram></mxfile>"#
        try DiagramFile.write(agent, to: file, root: root)
        #expect(await pollUntil(1.5) { panel.seen.contains("merge") }, "\(panel.seen)")
        try await Task.sleep(for: .milliseconds(500))
        #expect(panel.lastUserEditAt == nil, "\(panel.seen)")
        #expect(try String(contentsOf: file, encoding: .utf8) == agent)   // the agent's bytes, not draw.io's reformat

        // a malformed write is left alone
        let n = panel.seen.count
        try DiagramFile.write("<mxfile><oops>", to: file, root: root)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!panel.seen.dropFirst(n).contains("merge"))

        // the user's edit (draw.io's autosave outside a load/merge): written at once, and remembered as the user's
        let user = agent.replacingOccurrences(of: "Agente", with: "Usuário")
        panel.received(["event": "autosave", "xml": user])
        #expect(try String(contentsOf: file, encoding: .utf8) == user)
        #expect(panel.lastUserEditAt.map { Date().timeIntervalSince($0) < 1 } == true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!panel.seen.dropFirst(n).contains("merge"))   // its own write is not an outside change
    }

    /// R12: an in-place write (`echo >`: same inode, no folder event) is seen and merged; a user autosave that comes
    /// before the panel saw an outside change never overwrites it.
    @Test func inPlaceWriteReloadsAndIsNeverOverwritten() async throws {
        guard FileManager.default.fileExists(atPath: Self.web.appendingPathComponent("index.html").path) else {
            print("skipped: vendor/drawio/web missing (run scripts/build-drawio.sh)"); return
        }
        let root = try project()
        let (panel, w) = mount(root: root)
        defer { panel.close(); w.close() }
        let file = try #require(panel.file)
        #expect(await pollUntil(30) { panel.seen.contains("load") }, "\(panel.seen)")
        func inPlace(_ xml: String) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "printf '%s' \"$1\" > \"$2\"", "sh", xml, file.path]
            try p.run(); p.waitUntilExit()
        }
        let agent = #"<mxfile><diagram id="p1" name="Página-1"><mxGraphModel><root><mxCell id="0"/><mxCell id="1" parent="0"/><mxCell id="a" value="Agente" vertex="1" parent="1"><mxGeometry x="10" y="10" width="80" height="40" as="geometry"/></mxCell></root></mxGraphModel></diagram></mxfile>"#
        let merges = panel.seen.count(where: { $0 == "merge" })
        try inPlace(agent)
        #expect(await pollUntil(1.5) { panel.seen.count(where: { $0 == "merge" }) > merges }, "\(panel.seen)")
        try await Task.sleep(for: .milliseconds(300))

        // the agent writes again and, before the watch fires, the user's autosave arrives (made on the old content)
        let again = agent.replacingOccurrences(of: "Agente", with: "Agente2")
        try inPlace(again)
        panel.received(["event": "autosave", "xml": agent.replacingOccurrences(of: "Agente", with: "Usuário")])
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Agente2"))   // not overwritten
        #expect(await pollUntil(2) { panel.seen.count(where: { $0 == "merge" }) >= merges + 2 }, "\(panel.seen)")
        try await Task.sleep(for: .milliseconds(500))
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Agente2"), "the agent's change survives the merge")
    }

    /// R12: the folder swapped for a symlink after open: the user's next autosave is refused, nothing written outside.
    @Test func dirSwappedAfterOpenWritesNothingOutside() async throws {
        guard FileManager.default.fileExists(atPath: Self.web.appendingPathComponent("index.html").path) else { return }
        let root = try project(), outside = try project()
        let (panel, w) = mount(root: root)
        defer { panel.close(); w.close() }
        #expect(await pollUntil(30) { panel.seen.contains("load") })
        let dir = root.appendingPathComponent("docs/diagrams")
        try FileManager.default.moveItem(at: dir, to: root.appendingPathComponent("moved"))
        try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: outside)
        panel.received(["event": "autosave", "xml": DiagramFile.empty])
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(panel.failure?.contains("link") == true, "\(panel.failure ?? "")")
    }

    @Test func fileOutsideProjectShowsError() throws {
        let root = try project()
        let (panel, w) = mount(root: root, file: "../fora.drawio")
        defer { panel.close(); w.close() }
        #expect(panel.file == nil && panel.webView == nil)
        #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("fora.drawio").path))
    }
}
