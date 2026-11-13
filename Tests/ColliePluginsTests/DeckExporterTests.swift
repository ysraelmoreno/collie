import Foundation
import PDFKit
import Testing
import CollieProtocol
@testable import ColliePlugins

/// Real WKWebView; deck pages served from a temp `artifacts/<id>/source/` folder through `collie-artifact://app/`.
@MainActor @Suite(.serialized) struct DeckExporterTests {
    struct Site { let root: URL; let id: String; let url: URL; var exportDir: URL { root.appendingPathComponent("\(id)/.export") } }

    func site(_ html: String) throws -> Site {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deck-\(UUID().uuidString)/artifacts")
        let id = UUID().uuidString.lowercased(), source = root.appendingPathComponent("\(id)/source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(html.utf8).write(to: source.appendingPathComponent("index.html"))
        return Site(root: root, id: id, url: URL(string: "collie-artifact://app/\(id)/source/index.html")!)
    }

    func run(_ cmd: String, _ s: Site, _ args: [String: JSONValue] = [:]) async throws(ProtocolError) -> JSONValue {
        try await DeckExporter.handle(command: cmd, args: ["id": .string(s.id), "url": .string(s.url.absoluteString)].merging(args) { $1 },
                                      artifactsRoot: s.root, timeoutSeconds: 32)
    }

    static let png1x1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    static let deck = "<style>body{margin:0}.slide{width:1280px;height:720px;position:absolute;left:0;top:0;display:none;background:#fff}"
        + ".slide.on{display:block}h1{font-size:48px}</style>"
        + "<div class='slide on'><h1>Alpha slide</h1></div>"
        + "<div class='slide'><h1>Beta slide</h1><img src='data:image/png;base64,\(png1x1)' style='width:100px;height:100px'></div>"
        + "<div class='slide'><h1>Gamma slide</h1></div>"

    @Test func snapshotWritesSlidesJson() async throws {
        let s = try site(Self.deck)
        let reply = try await run("deck.snapshot", s)
        guard case .object(let r) = reply else { Issue.record("\(reply)"); return }
        #expect(r["file"] == .string(".export/slides.json"))
        #expect(r["slides"] == .number(3))
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: s.exportDir.appendingPathComponent("slides.json")))
        guard case .object(let o) = json, case .array(let slides)? = o["slides"] else { Issue.record("\(json)"); return }
        #expect(slides.count == 3)
        #expect(FileManager.default.fileExists(atPath: s.exportDir.appendingPathComponent("img-1.png").path))
        #expect(!String(decoding: try Data(contentsOf: s.exportDir.appendingPathComponent("slides.json")), as: UTF8.self).contains(Self.png1x1))
        let perms = try FileManager.default.attributesOfItem(atPath: s.exportDir.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
    }

    @Test func pdfHasOnePagePerSlide() async throws {
        let s = try site(Self.deck)
        let reply = try await run("deck.pdf", s)
        #expect(reply == .object(["file": .string(".export/deck-app.pdf"), "slides": .number(3)]))
        let doc = try #require(PDFDocument(url: s.exportDir.appendingPathComponent("deck-app.pdf")))
        #expect(doc.pageCount == 3)
        let page = try #require(doc.page(at: 0))
        let b = page.bounds(for: .mediaBox)
        #expect(abs(b.width - 960) < 0.5 && abs(b.height - 540) < 0.5, "\(b)")
        #expect(page.string?.contains("Alpha slide") == true, "\(page.string ?? "nil")")
        #expect(doc.page(at: 2)?.string?.contains("Gamma slide") == true)
    }

    @Test func pdfSlideWiderThanTheViewIsWhole() async throws {
        let s = try site("<style>body{margin:0}.slide{width:1920px;height:1080px;position:relative}</style>"
            + "<div class='slide'><h1>Big</h1><p style='position:absolute;top:1000px;left:1700px'>Corner</p></div>")
        _ = try await run("deck.pdf", s)
        let page = try #require(PDFDocument(url: s.exportDir.appendingPathComponent("deck-app.pdf"))?.page(at: 0))
        let b = page.bounds(for: .mediaBox)
        #expect(abs(b.width - 1440) < 0.5 && abs(b.height - 810) < 0.5, "\(b)")
        #expect(page.string?.contains("Corner") == true, "\(page.string ?? "nil")")
    }

    @Test func exportSymlinkIsReplacedNotFollowed() async throws {
        let s = try site(Self.deck)
        let elsewhere = s.root.deletingLastPathComponent().appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: s.exportDir, withDestinationURL: elsewhere)
        _ = try await run("deck.snapshot", s)
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: s.exportDir.path)) == nil)
    }

    @Test func rejectsBadId() async throws {
        let s = try site(Self.deck)
        for cmd in ["deck.snapshot", "deck.pdf"] {
            do { _ = try await run(cmd, s, ["id": .string("nope")]); Issue.record("no error") } catch { #expect(error.code == .invalidArgs) }
        }
    }

    @Test func rejectsForeignScheme() async throws {
        let s = try site(Self.deck)
        for cmd in ["deck.snapshot", "deck.pdf"] {
            do { _ = try await run(cmd, s, ["url": .string("https://example.com/")]); Issue.record("no error") } catch {
                #expect(error.code == .invalidArgs)
            }
        }
    }

    @Test func noSlidesIsInvalidArgs() async throws {
        let s = try site("<section><h1>x</h1></section>")
        for cmd in ["deck.snapshot", "deck.pdf"] {
            do { _ = try await run(cmd, s); Issue.record("no error") } catch {
                #expect(error.code == .invalidArgs && error.message.contains("no slides"), "\(error)")
            }
        }
    }
}
