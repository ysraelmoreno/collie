import Foundation
import Testing
import CollieCore
import CollieProtocol

/// The Prévia's rules: which page it may show and which files of the project it may serve.
@Suite struct PreviewFileTests {
    func project() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        let rp = try #require(realpath(u.path, nil)); defer { free(rp) }
        return URL(fileURLWithPath: String(cString: rp))
    }
    func refused(_ requested: String, _ root: URL) -> Bool {
        do { _ = try PreviewFile.resolve(requested, projectRoot: root); return false } catch { return error.code == .invalidArgs }
    }
    func put(_ rel: String, _ root: URL, _ text: String = "x") throws {
        let u = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
    }

    @Test func resolveInsideProject() throws {
        let root = try project()
        #expect(try PreviewFile.resolve("docs/pages/a/index.html", projectRoot: root).path == root.path + "/docs/pages/a/index.html")
        #expect(try PreviewFile.resolve(root.path + "/b.HTM", projectRoot: root).lastPathComponent == "b.HTM")
    }

    @Test func resolveRefusesOutside() throws {
        let root = try project(), outside = try project()
        #expect(refused("../x.html", root))
        #expect(refused(outside.path + "/x.html", root))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("out"), withDestinationURL: outside)
        #expect(refused("out/x.html", root))
    }

    @Test func resolveRefusesNonHTML() throws {
        let root = try project()
        #expect(refused("a.md", root))
        #expect(refused("docs/", root))
    }

    @Test func servableAllowsSiblingAssets() throws {
        let root = try project()
        try put("docs/pages/d/app.css", root)
        #expect(PreviewFile.servable("docs/pages/d/app.css", projectRoot: root)?.path == root.path + "/docs/pages/d/app.css")
        #expect(PreviewFile.servable("/docs/pages/d/app.css", projectRoot: root) != nil)
        #expect(PreviewFile.servable("docs/pages/d/a%20b.css", projectRoot: root)?.lastPathComponent == "a b.css")
    }

    @Test func servableRefusesDotPaths() throws {
        let root = try project()
        for p in [".env", ".git/config", "a/.collie/x"] { try put(p, root) }
        for p in [".env", ".git/config", "a/.collie/x", "%2eenv"] { #expect(PreviewFile.servable(p, projectRoot: root) == nil, "\(p)") }
    }

    @Test func servableRefusesTraversal() throws {
        let root = try project()
        for p in ["%2e%2e/%2e%2e/etc/hosts", "../../etc/hosts", "a/../../x", "/etc/hosts/.."] {
            #expect(PreviewFile.servable(p, projectRoot: root) == nil, "\(p)")
        }
    }

    @Test func servableRefusesSymlinkOut() throws {
        let root = try project(), outside = try project()
        try put("secret.txt", outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("s.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("d"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("e.txt"), withDestinationURL: root.appendingPathComponent(".env"))
        try put(".env", root)
        #expect(PreviewFile.servable("s.txt", projectRoot: root) == nil)
        #expect(PreviewFile.servable("d/secret.txt", projectRoot: root) == nil)
        #expect(PreviewFile.servable("e.txt", projectRoot: root) == nil)
    }

    @Test func readDataBinary() throws {
        let root = try project()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0xFE])
        let u = root.appendingPathComponent("i/a.png")
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: u)
        #expect(try DiagramFile.readData(u, root: root) == png)
        #expect(try DiagramFile.readData(root.appendingPathComponent("i/none.png"), root: root) == nil)
    }

    @Test func readDataNounInMessage() throws {
        let root = try project()
        let u = root.appendingPathComponent("big.html")
        try Data(count: 9 << 20).write(to: u)
        do { _ = try DiagramFile.readData(u, root: root, noun: "página"); Issue.record("read") }
        catch { #expect(error.message.contains("página grande demais"), "\(error.message)") }
        do { try DiagramFile.write(String(repeating: "a", count: 9 << 20), to: u, root: root, noun: "página"); Issue.record("wrote") }
        catch { #expect(error.message.contains("página grande demais"), "\(error.message)") }
    }

    @Test func contentTypes() {
        #expect(PreviewFile.contentType("html").hasPrefix("text/html"))
        #expect(PreviewFile.contentType("HTM").hasPrefix("text/html"))
        #expect(PreviewFile.contentType("css").hasPrefix("text/css"))
        #expect(PreviewFile.contentType("mjs").hasPrefix("text/javascript"))
        #expect(PreviewFile.contentType("svg") == "image/svg+xml")
        #expect(PreviewFile.contentType("woff2") == "font/woff2")
        #expect(PreviewFile.contentType("exe") == "application/octet-stream")
    }
}
