import Foundation
import Testing
import CollieCore
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

    /// R12: a folder swapped for a symlink after the file was resolved is refused; nothing lands outside.
    @Test func dirSwappedForSymlinkRefused() throws {
        let root = try project(), outside = try project()
        let f = try DiagramFile.resolve("docs/diagrams/a.drawio", panelName: "p", projectRoot: root)
        try DiagramFile.write("<mxfile/>", to: f, root: root)
        let fm = FileManager.default, dir = root.appendingPathComponent("docs/diagrams")
        try fm.moveItem(at: dir, to: root.appendingPathComponent("old"))
        try fm.createSymbolicLink(at: dir, withDestinationURL: outside)
        try Data("<mxfile><diagram/></mxfile>".utf8).write(to: outside.appendingPathComponent("a.drawio"))
        #expect(throws: ProtocolError.self) { try DiagramFile.write("<mxfile/>", to: f, root: root) }
        #expect(throws: ProtocolError.self) { _ = try DiagramFile.read(f, root: root) }
        #expect(try String(contentsOf: outside.appendingPathComponent("a.drawio"), encoding: .utf8) == "<mxfile><diagram/></mxfile>")
        #expect(try fm.contentsOfDirectory(atPath: outside.path) == ["a.drawio"])   // no temp file left there either
    }

    /// R12: a link to /dev/zero or a FIFO is refused at once (never read, never blocks).
    @Test func nonRegularRefusedFast() throws {
        let root = try project()
        let f = try DiagramFile.resolve("z.drawio", panelName: "p", projectRoot: root)
        try FileManager.default.createSymbolicLink(at: f, withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        let t0 = Date()
        #expect(throws: ProtocolError.self) { _ = try DiagramFile.read(f, root: root) }
        try FileManager.default.removeItem(at: f)
        #expect(mkfifo(f.path, 0o600) == 0)
        do { _ = try DiagramFile.read(f, root: root); Issue.record("FIFO read") } catch { #expect(error.message.contains("arquivo comum"), "\(error.message)") }
        #expect(Date().timeIntervalSince(t0) < 1)
    }

    /// R12: more than 8 MiB is refused on write and on read.
    @Test func oversizeRefused() throws {
        let root = try project()
        let f = try DiagramFile.resolve("big.drawio", panelName: "p", projectRoot: root)
        let big = String(repeating: "x", count: DiagramFile.maxBytes + 1)
        #expect(throws: ProtocolError.self) { try DiagramFile.write(big, to: f, root: root) }
        #expect(!FileManager.default.fileExists(atPath: f.path))
        try Data(big.utf8).write(to: f)
        #expect(throws: ProtocolError.self) { _ = try DiagramFile.read(f, root: root) }
        #expect(try DiagramFile.read(root.appendingPathComponent("missing/none.drawio"), root: root) == nil)
    }

    @Test func writeThenReadRoundTrips() throws {
        let root = try project()
        let f = try DiagramFile.resolve(nil, panelName: "n", projectRoot: root)
        try DiagramFile.write("<mxfile/>", to: f, root: root)   // creates docs/diagrams/
        #expect(try DiagramFile.read(f, root: root) == "<mxfile/>")
    }

    /// R13/C1+H1: no DTD at all (external entities: XXE; internal ones: billion laughs), refused fast with a clear message;
    /// nor a byte trick that would make the parser see one where the text has none (a declared encoding, NUL bytes).
    @Test func validateRefusesDoctypeAndEntities() throws {
        let secret = try project().appendingPathComponent("secret.txt")
        try Data("SEGREDO".utf8).write(to: secret)
        let xxe = "<?xml version=\"1.0\"?><!DOCTYPE mxfile [<!ENTITY x SYSTEM \"\(secret.absoluteString)\">]><mxfile><diagram name=\"&x;\"/></mxfile>"
        var bomb = "<!DOCTYPE mxfile [<!ENTITY a0 \"ha\">"
        for i in 1...9 { bomb += "<!ENTITY a\(i) \"" + String(repeating: "&a\(i - 1);", count: 10) + "\">" }
        bomb += "]><mxfile><diagram name=\"&a9;\"/></mxfile>"
        let t0 = Date()
        for (label, xml) in [("xxe", xxe), ("bomb", bomb), ("entity only", "<mxfile><!ENTITY x \"y\"></mxfile>"),
                             ("utf-7", "<?xml version=\"1.0\" encoding=\"UTF-7\"?><mxfile/>"),
                             ("utf-16 bytes", "<\0?\0x\0m\0l\0 \0?\0>\0<\0m\0x\0f\0i\0l\0e\0/\0>\0")] {
            do { try DiagramFile.validate(xml: xml); Issue.record("\(label) accepted") } catch {
                #expect(error.code == .invalidArgs, "\(label)")
                #expect(!error.message.contains("SEGREDO"), "\(label)")
            }
        }
        do { try DiagramFile.validate(xml: xxe) } catch { #expect(error.message.contains("DOCTYPE"), "\(error.message)") }
        #expect(Date().timeIntervalSince(t0) < 1)
        try DiagramFile.validate(xml: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><mxfile/>")
        try DiagramFile.validate(xml: "<mxfile><diagram name=\"&lt;!DOCTYPE&gt;\"/></mxfile>")   // escaped text is fine
    }

    /// R13/L2: `diagram.set --from`: a regular file of at most 8 MiB, read without blocking on a FIFO or a device.
    @Test func readLocalOnlyRegularFiles() throws {
        let dir = try project()
        let f = dir.appendingPathComponent("a.drawio")
        try Data("<mxfile/>".utf8).write(to: f)
        #expect(try DiagramFile.readLocal(f) == "<mxfile/>")
        let t0 = Date()
        #expect(throws: ProtocolError.self) { _ = try DiagramFile.readLocal(URL(fileURLWithPath: "/dev/zero")) }
        let fifo = dir.appendingPathComponent("p.drawio")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: ProtocolError.self) { _ = try DiagramFile.readLocal(fifo) }
        #expect(throws: ProtocolError.self) { _ = try DiagramFile.readLocal(dir) }
        #expect(Date().timeIntervalSince(t0) < 1)
        let big = dir.appendingPathComponent("big.drawio")
        try Data(String(repeating: "x", count: DiagramFile.maxBytes + 1).utf8).write(to: big)
        #expect(throws: ProtocolError.self) { _ = try DiagramFile.readLocal(big) }
    }
}
