import Testing
import Foundation
@testable import CollieDaemonKit

@Suite struct PPTXWriterTests {
    private func run(_ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    private func unzip(_ data: Data) throws -> [String: Data] {
        let path = NSTemporaryDirectory() + "pptx-\(UUID().uuidString).pptx"
        try data.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let names = String(decoding: try run(["-Z1", path]), as: UTF8.self).split(separator: "\n").map(String.init)
        var out: [String: Data] = [:]
        // unzip reads names as wildcards: `[[]` is a literal `[`
        for n in names { out[n] = try run(["-p", path, n.replacingOccurrences(of: "[", with: "[[]")]) }
        return out
    }

    private func node(_ tag: String = "div", x: Double = 0, y: Double = 0, w: Double = 100, h: Double = 40,
                      style: [String: String] = [:], text: String? = nil, runs: [DOMRun]? = nil,
                      children: [DOMNode] = []) -> DOMNode {
        DOMNode(tag: tag, x: x, y: y, w: w, h: h, style: style, children: children, text: text, runs: runs)
    }

    private func deck(_ slides: [DeckSlide]) -> DeckSnapshot {
        DeckSnapshot(title: "Deck & Co", slides: slides, blocked: [], truncated: false)
    }

    private func slide(_ children: [DOMNode], w: Double = 1280, background: String? = nil, pseudo: Int? = nil) -> DeckSlide {
        DeckSlide(index: 0, w: w, h: w * 9 / 16, background: background, notes: nil, pseudo: pseudo,
                  root: node("section", w: w, h: w * 9 / 16, children: children))
    }

    private func text(_ files: [String: Data], _ name: String) -> String {
        String(decoding: files[name] ?? Data(), as: UTF8.self)
    }

    @Test func buildsOneSlidePerSlide() throws {
        let files = try unzip(PPTXWriter.build(deck([slide([]), slide([]), slide([])]), payloads: [:]).data)
        for i in 1...3 { #expect(files["ppt/slides/slide\(i).xml"] != nil) }
        #expect(files["ppt/slides/slide4.xml"] == nil)
        #expect(text(files, "ppt/presentation.xml").contains(#"cx="12192000" cy="6858000""#))
        #expect(text(files, "docProps/core.xml").contains("Deck &amp; Co"))
    }

    @Test func textBoxIsRealText() throws {
        let leaf = node("h1", style: ["fontSize": "28px"], text: "Olá mundo")
        let files = try unzip(PPTXWriter.build(deck([slide([leaf])]), payloads: [:]).data)
        let xml = text(files, "ppt/slides/slide1.xml")
        #expect(xml.contains("<a:t>Olá mundo</a:t>"))
        #expect(xml.contains(#"sz="2100""#))
        #expect(xml.contains(#"txBox="1""#))
    }

    @Test func runsKeepBoldAndColor() throws {
        let leaf = node("p", text: "Olá mundo",
                        runs: [DOMRun(start: 4, end: 9, color: "rgb(110, 231, 183)", fontWeight: "700")])
        let xml = text(try unzip(PPTXWriter.build(deck([slide([leaf])]), payloads: [:]).data), "ppt/slides/slide1.xml")
        #expect(xml.contains("<a:t>Olá </a:t>"))
        #expect(xml.contains("<a:t>mundo</a:t>"))
        #expect(xml.contains(#"b="1""#))
        #expect(xml.contains(#"srgbClr val="6EE7B7""#))
    }

    @Test func linesAndLinksAndHashText() throws {
        let leaf = node("p", text: "one\ntwo", runs: [DOMRun(start: 4, end: 7, href: "https://x.test/?a=1&b=2")])
        let loose = node("#text", text: "loose")
        let files = try unzip(PPTXWriter.build(deck([slide([node(children: [leaf, loose])])]), payloads: [:]).data)
        let xml = text(files, "ppt/slides/slide1.xml")
        #expect(xml.components(separatedBy: "<a:p>").count == 4)   // 2 lines + 1 loose
        #expect(xml.contains(#"<a:hlinkClick r:id="rId2"/>"#))
        #expect(xml.contains("<a:t>loose</a:t>"))
        #expect(text(files, "ppt/slides/_rels/slide1.xml.rels").contains("https://x.test/?a=1&amp;b=2"))
    }

    @Test func scaleFollowsSlideWidth() throws {
        let leaf = node(x: 64, text: "hi")
        let xml = text(try unzip(PPTXWriter.build(deck([slide([leaf], w: 640)]), payloads: [:]).data), "ppt/slides/slide1.xml")
        #expect(xml.contains(#"<a:off x="1219200""#))
    }

    @Test func backgroundSolid() throws {
        let r = try PPTXWriter.build(deck([slide([], background: "rgb(15, 23, 42)")]), payloads: [:])
        let xml = text(try unzip(r.data), "ppt/slides/slide1.xml")
        #expect(xml.contains("<p:bg>") && xml.contains(#"srgbClr val="0F172A""#))
        #expect(r.warnings.isEmpty)
    }

    @Test func backgroundGradientWarns() throws {
        let bg = "linear-gradient(135deg, rgb(255, 0, 0) 0%, rgb(0, 0, 255) 100%)"
        let r = try PPTXWriter.build(deck([slide([]), slide([], background: bg)]), payloads: [:])
        #expect(text(try unzip(r.data), "ppt/slides/slide2.xml").contains(#"srgbClr val="FF0000""#))
        #expect(r.warnings.contains("slide 2: gradient background → first color"))
    }

    @Test func fontsWarningListsFamilies() throws {
        let a = node(style: ["fontFamily": "\"Space Grotesk\", sans-serif"], text: "a")
        let b = node(style: ["fontFamily": "Inter, system-ui"], text: "b")
        let c = node(style: ["fontFamily": "Inter"], text: "c")
        let r = try PPTXWriter.build(deck([slide([a, b, c], pseudo: 2), slide([], pseudo: 1)]), payloads: [:])
        #expect(r.warnings.contains("fonts not embedded: Inter, Space Grotesk"))
        #expect(r.warnings.contains("pseudo-element content dropped (3 elements)"))
        #expect(text(try unzip(r.data), "ppt/slides/slide1.xml").contains(#"typeface="Space Grotesk""#))
    }

    @Test func everyPartIsWellFormedXML() throws {
        let leaf = node(style: ["textAlign": "center", "fontStyle": "italic", "textDecorationLine": "underline",
                                "paddingLeft": "8px", "color": "rgba(255, 255, 255, 0.5)"],
                        text: "<b>\u{1}&\"'", runs: [DOMRun(start: -3, end: 99, href: "x\"y")])
        let files = try unzip(PPTXWriter.build(deck([slide([leaf], background: "rgb(0 0 0)")]), payloads: [:]).data)
        #expect(files["ppt/theme/theme1.xml"] != nil)
        let xmlNames = files.keys.filter { $0.hasSuffix(".xml") || $0.hasSuffix(".rels") }
        #expect(xmlNames.count >= 10)
        for name in xmlNames {
            let parser = XMLParser(data: files[name]!)
            #expect(parser.parse(), "\(name): \(String(describing: parser.parserError))")
        }
        let xml = text(files, "ppt/slides/slide1.xml")
        #expect(xml.contains(#"algn="ctr""#) && xml.contains(#"i="1""#) && xml.contains(#"u="sng""#))
        #expect(xml.contains(#"<a:alpha val="50000"/>"#))
    }

    @Test func noSlidesThrows() {
        #expect(throws: PPTXError.noSlides) { try PPTXWriter.build(deck([]), payloads: [:]) }
    }

    @Test func colorAndUnits() {
        #expect(CSSColor.parse("rgba(0, 0, 0, 0)") == nil)
        #expect(CSSColor.parse("rgb(110 231 183)")?.hex == "6EE7B7")
        #expect(CSSColor.parse("rgba(255, 255, 255, 0.5)")?.alpha == 50000)
        #expect(emu(.infinity, scale: 9525) == 0)
        #expect(emu(1e12, scale: 9525) == Int(Int32.max))
        #expect(emu(-1e12, scale: 9525) == -Int(Int32.max))
        #expect(xmlEscape("a\u{0}\u{FFFE}\tb<") == "a\tb&lt;")
    }
}
