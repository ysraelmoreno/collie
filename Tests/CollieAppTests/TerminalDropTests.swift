import AppKit
import Testing
@testable import CollieApp

@MainActor @Suite struct TerminalDropTests {
    @Test func escapesLikeTerminalApp() {
        #expect(TerminalDrop.escape("/Users/a/Captura de Tela.png") == #"/Users/a/Captura\ de\ Tela.png"#)
        #expect(TerminalDrop.escape("/tmp/a(1)'s.png") == #"/tmp/a\(1\)\'s.png"#)
        #expect(TerminalDrop.escape("/tmp/plain-file_1.2.png") == "/tmp/plain-file_1.2.png")
        #expect(TerminalDrop.escape("/tmp/ação.png") == #"/tmp/a\ç\ão.png"#)
    }

    @Test func textJoinsPathsWithATrailingSpace() {
        let urls = [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b c.png")]
        #expect(TerminalDrop.text(for: urls) == #"/tmp/a.png /tmp/b\ c.png "#)
        #expect(TerminalDrop.text(for: []) == nil)
    }

    @Test func fileURLsArePastedAsTheyAre() throws {
        let pb = NSPasteboard(name: .init("collie-test-\(UUID().uuidString)")); defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/x y.png") as NSURL])
        #expect(TerminalDrop.accepts(pb))
        var got: String?
        #expect(TerminalDrop.receive(pb) { got = $0 })
        #expect(got == #"/tmp/x\ y.png "#)
    }

    @Test func bareImageDataIsWrittenAsPNG() throws {
        let pb = NSPasteboard(name: .init("collie-test-\(UUID().uuidString)")); defer { pb.releaseGlobally() }
        pb.clearContents()
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }
        let tiff = try #require(image.tiffRepresentation)
        pb.setData(tiff, forType: .tiff)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collie-drop-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try #require(TerminalDrop.writeImage(from: pb, in: dir))
        #expect(url.pathExtension == "png")
        let data = try Data(contentsOf: url)
        #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func textOnlyIsNotADrop() {
        let pb = NSPasteboard(name: .init("collie-test-\(UUID().uuidString)")); defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("hello", forType: .string)
        #expect(!TerminalDrop.accepts(pb))
        #expect(!TerminalDrop.receive(pb) { _ in })
    }
}
