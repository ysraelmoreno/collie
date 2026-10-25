import Foundation
import Testing
import ColliePlugins
import CollieProtocol

@Suite struct DiagramFileTests {
    /// A fresh project folder (symlinks resolved, as `resolve` returns real paths).
    func project() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("diagram-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        let rp = try #require(realpath(u.path, nil)); defer { free(rp) }   // /private/var, as `resolve` returns it
        return URL(fileURLWithPath: String(cString: rp))
    }
    func refused(_ requested: String?, _ root: URL) -> Bool {
        do { _ = try DiagramFile.resolve(requested, panelName: "p", projectRoot: root); return false } catch { return error.code == .invalidArgs }
    }

    @Test func resolveDefaultPath() throws {
        let root = try project()
        #expect(try DiagramFile.resolve(nil, panelName: "arq", projectRoot: root).path == root.path + "/docs/diagrams/arq.drawio")
        #expect(try DiagramFile.resolve("", panelName: "arq", projectRoot: root).path == root.path + "/docs/diagrams/arq.drawio")
    }

    @Test func resolveRelativeInsideProject() throws {
        let root = try project()
        #expect(try DiagramFile.resolve("docs/x/fluxo.drawio", panelName: "p", projectRoot: root).path == root.path + "/docs/x/fluxo.drawio")
        #expect(try DiagramFile.resolve(root.path + "/a.drawio", panelName: "p", projectRoot: root).path == root.path + "/a.drawio")
        #expect(try DiagramFile.resolve("docs/../b.drawio", panelName: "p", projectRoot: root).path == root.path + "/b.drawio")
    }

    @Test func resolveRefusesOutside() throws {
        let root = try project(), outside = try project()
        #expect(refused("../x.drawio", root))
        #expect(refused(outside.path + "/x.drawio", root))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(refused("link/x.drawio", root))
        try Data().write(to: outside.appendingPathComponent("real.drawio"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("f.drawio"), withDestinationURL: outside.appendingPathComponent("real.drawio"))
        #expect(refused("f.drawio", root))
        #expect(refused("../../" + root.lastPathComponent + "x/a.drawio", root))
    }

    @Test func resolveRefusesWrongExtension() throws {
        let root = try project()
        #expect(refused("a.xml", root))
        #expect(refused("a", root))
        #expect(refused("docs/", root))
        #expect(try DiagramFile.resolve("A.DRAWIO", panelName: "p", projectRoot: root).lastPathComponent == "A.DRAWIO")
    }

    @Test func validateRejectsMalformed() {
        do {
            try DiagramFile.validate(xml: "<mxfile>\n<diagram>\n<mxGraphModel></diagram>\n</mxfile>")
            Issue.record("accepted")
        } catch {
            #expect(error.code == .invalidArgs)
            #expect(error.message.contains("linha 3") || error.message.contains("linha 4"), "\(error.message)")
        }
        #expect(throws: ProtocolError.self) { try DiagramFile.validate(xml: "") }
        #expect(throws: ProtocolError.self) { try DiagramFile.validate(xml: "<svg/>") }   // not a draw.io document
    }

    @Test func validateAcceptsEmptyDiagram() throws {
        try DiagramFile.validate(xml: DiagramFile.empty)
        try DiagramFile.validate(xml: "<mxfile/>")
        try DiagramFile.validate(xml: "<mxGraphModel><root><mxCell id=\"0\"/></root></mxGraphModel>")
    }

    @Test func mayOverwriteRule() {
        let now = Date()
        #expect(!DiagramFile.mayOverwrite(lastUserEditAt: now.addingTimeInterval(-1.9), now: now))
        #expect(DiagramFile.mayOverwrite(lastUserEditAt: now.addingTimeInterval(-2.1), now: now))
        #expect(DiagramFile.mayOverwrite(lastUserEditAt: nil, now: now))
    }

    @Test func writeThenReadRoundTrips() throws {
        let root = try project()
        let f = try DiagramFile.resolve(nil, panelName: "n", projectRoot: root)
        try DiagramFile.write("<mxfile/>", to: f)   // creates docs/diagrams/
        #expect(try DiagramFile.read(f) == "<mxfile/>")
    }
}
