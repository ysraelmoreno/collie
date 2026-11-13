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

    func run(_ cmd: String, _ s: Site, _ args: [String: JSONValue] = [:], timeout: Double = 32) async throws(ProtocolError) -> JSONValue {
        try await DeckExporter.handle(command: cmd, args: ["id": .string(s.id), "url": .string(s.url.absoluteString)].merging(args) { $1 },
                                      artifactsRoot: s.root, timeoutSeconds: timeout)
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
        #expect(abs(b.width - 960) < 0.5 && abs(b.height - 540) < 0.5, "\(b)")
        #expect(page.string?.contains("Corner") == true, "\(page.string ?? "nil")")
    }

    @Test func pdfHidesChromeOutsideTheSlides() async throws {
        let s = try site(Self.deck + "<div style='position:fixed;left:600px;top:10px;z-index:9'>COUNTER</div>")
        _ = try await run("deck.pdf", s)
        let doc = try #require(PDFDocument(url: s.exportDir.appendingPathComponent("deck-app.pdf")))
        for i in 0..<doc.pageCount { #expect(doc.page(at: i)?.string?.contains("COUNTER") == false, "page \(i + 1)") }
        #expect(doc.page(at: 1)?.string?.contains("Beta slide") == true)
    }

    @Test func exportSymlinkIsReplacedNotFollowed() async throws {
        let s = try site(Self.deck)
        let elsewhere = s.root.deletingLastPathComponent().appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: elsewhere.appendingPathComponent("slides.json"))
        try FileManager.default.createSymbolicLink(at: s.exportDir, withDestinationURL: elsewhere)
        _ = try await run("deck.snapshot", s)
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path) == ["slides.json"])
        #expect(try Data(contentsOf: elsewhere.appendingPathComponent("slides.json")) == Data("old".utf8))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: s.exportDir.path)) == nil)
        // dangling link: replaced by a real folder too
        try FileManager.default.removeItem(at: s.exportDir)
        try FileManager.default.createSymbolicLink(at: s.exportDir, withDestinationURL: elsewhere.appendingPathComponent("gone"))
        _ = try await run("deck.pdf", s)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: s.exportDir.path)) == nil)
        #expect(FileManager.default.fileExists(atPath: s.exportDir.appendingPathComponent("deck-app.pdf").path))
    }

    /// The daemon keeps `deck.pptx` / `deck.pdf` in `.export`: each command clears only its own earlier files.
    @Test func exportKeepsOtherOutputs() async throws {
        let s = try site(Self.deck)
        let fm = FileManager.default
        try fm.createDirectory(at: s.exportDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        for name in ["deck.pptx", "deck.pdf", "img-9.png", "svg-9.svg"] { try Data("x".utf8).write(to: s.exportDir.appendingPathComponent(name)) }
        _ = try await run("deck.snapshot", s)
        _ = try await run("deck.pdf", s)
        let names = Set(try fm.contentsOfDirectory(atPath: s.exportDir.path))
        #expect(names == ["deck.pptx", "deck.pdf", "deck-app.pdf", "slides.json", "img-1.png"], "\(names)")
        #expect(try fm.attributesOfItem(atPath: s.exportDir.path)[.posixPermissions] as? Int == 0o700)
        _ = try await run("deck.pdf", s)   // and pdf leaves the snapshot's files
        #expect(Set(try fm.contentsOfDirectory(atPath: s.exportDir.path)) == names)
    }

    /// A page whose JS hangs once a slide is isolated (after load): `.timeout` at the call's deadline, not a stuck handler.
    @Test func pdfTimesOutAfterLoad() async throws {
        let s = try site(Self.deck + "<script>new MutationObserver(() => { for (;;) {} })"
            + ".observe(document.body, { attributes: true, subtree: true })</script>")
        let start = ContinuousClock.now
        do { _ = try await run("deck.pdf", s, timeout: 7); Issue.record("no error") } catch {
            #expect(error.code == .timeout, "\(error)")
        }
        #expect(ContinuousClock.now - start < .seconds(10))
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
