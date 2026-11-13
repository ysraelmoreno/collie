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
                      children: [DOMNode] = [], image: DOMImage? = nil, list: DOMList? = nil) -> DOMNode {
        DOMNode(tag: tag, x: x, y: y, w: w, h: h, style: style, children: children, text: text, runs: runs,
                image: image, list: list)
    }

    private func deck(_ slides: [DeckSlide]) -> DeckSnapshot {
        DeckSnapshot(title: "Deck & Co", slides: slides, blocked: [], truncated: false)
    }

    private func slide(_ children: [DOMNode], w: Double = 1280, background: String? = nil, pseudo: Int? = nil,
                       notes: String? = nil) -> DeckSlide {
        DeckSlide(index: 0, w: w, h: w * 9 / 16, background: background, notes: notes, pseudo: pseudo,
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

    // MARK: - Task 5

    private func slideXML(_ nodes: [DOMNode], payloads: [String: Data] = [:]) throws -> (xml: String, warnings: [String], files: [String: Data]) {
        let r = try PPTXWriter.build(deck([slide(nodes)]), payloads: payloads)
        let files = try unzip(r.data)
        return (text(files, "ppt/slides/slide1.xml"), r.warnings, files)
    }

    private func assertWellFormed(_ files: [String: Data]) {
        for name in files.keys where name.hasSuffix(".xml") || name.hasSuffix(".rels") {
            let parser = XMLParser(data: files[name]!)
            #expect(parser.parse(), "\(name): \(String(describing: parser.parserError))")
        }
    }

    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    @Test func roundedBoxHasAdj() throws {
        let box = node(w: 400, h: 200, style: ["backgroundColor": "rgb(255, 0, 0)", "borderTopLeftRadius": "20px"])
        let xml = try slideXML([box]).xml
        #expect(xml.contains(#"prst="roundRect""#))
        #expect(xml.contains(#"<a:gd name="adj" fmla="val 10000"/>"#))
    }

    @Test func fillAlpha() throws {
        let xml = try slideXML([node(style: ["backgroundColor": "rgba(255, 255, 255, 0.5)"])]).xml
        #expect(xml.contains(#"prst="rect""#) && xml.contains(#"<a:alpha val="50000"/>"#))
    }

    @Test func borderBecomesLine() throws {
        let st = ["borderTopWidth": "2px", "borderRightWidth": "2px", "borderBottomWidth": "4px", "borderLeftWidth": "2px",
                  "borderTopStyle": "solid", "borderTopColor": "rgb(0, 0, 255)"]
        let r = try slideXML([node(style: st)])
        #expect(r.xml.contains(#"<a:ln w="19050"><a:solidFill><a:srgbClr val="0000FF"/>"#))
        #expect(r.warnings.contains("non-uniform borders approximated (1)"))
        let none = try slideXML([node(style: ["borderTopWidth": "2px", "borderTopStyle": "none"])]).xml
        #expect(!none.contains("<a:ln"))
    }

    @Test func textLeafWithFillEmitsShapeThenText() throws {
        let xml = try slideXML([node(style: ["backgroundColor": "rgb(1, 2, 3)"], text: "hi")]).xml
        let shape = try #require(xml.range(of: #"srgbClr val="010203""#)), txt = try #require(xml.range(of: "<a:t>hi</a:t>"))
        #expect(shape.lowerBound < txt.lowerBound)
    }

    @Test func coverImageIsCropped() throws {
        let img = node("img", w: 100, h: 100, image: DOMImage(file: "img-1.png", w: 200, h: 100, fit: "cover"))
        let r = try slideXML([img], payloads: ["img-1.png": png])
        #expect(r.xml.contains("<p:pic>"))
        #expect(r.xml.contains(#"<a:srcRect l="25000" r="25000"/>"#))
        #expect(r.files["ppt/media/image1.png"] == png)
        #expect(text(r.files, "ppt/slides/_rels/slide1.xml.rels").contains("../media/image1.png"))
    }

    @Test func containImageIsCentered() throws {
        // 200×100 into 100×100 at x 10, y 10 → 100×50 at y 35
        let img = node("img", x: 10, y: 10, w: 100, h: 100, image: DOMImage(file: "img-1.png", w: 200, h: 100, fit: "contain"))
        let xml = try slideXML([img], payloads: ["img-1.png": png]).xml
        #expect(xml.contains(#"<a:off x="95250" y="333375"/><a:ext cx="952500" cy="476250"/>"#))
        #expect(!xml.contains("srcRect"))
    }

    @Test func imagesDedupeAndLinksDoNotCollide() throws {
        let a = node("img", image: DOMImage(file: "img-1.png", w: 1, h: 1, fit: "fill"))
        let link = node("p", text: "go", runs: [DOMRun(start: 0, end: 2, href: "https://x.test")])
        let r = try slideXML([link, a, a], payloads: ["img-1.png": png])
        #expect(r.files.keys.filter { $0.hasPrefix("ppt/media/") } == ["ppt/media/image1.png"])
        let rels = text(r.files, "ppt/slides/_rels/slide1.xml.rels")
        let ids = rels.components(separatedBy: #"Id=""#).dropFirst().map { $0.prefix { $0 != "\"" } }
        #expect(ids.count == 4 && Set(ids).count == 4)
        assertWellFormed(r.files)
    }

    @Test func missingImageWarns() throws {
        let img = node("img", image: DOMImage(file: "img-9.png", w: 1, h: 1, fit: "fill"))
        let big = node("img", image: DOMImage(file: "img-2.png", w: 1, h: 1, fit: "fill"))
        let r = try slideXML([img, big], payloads: ["img-2.png": Data(count: 4 * 1024 * 1024 + 1)])
        #expect(!r.xml.contains("<p:pic>"))
        #expect(r.warnings.contains("image missing: img-9.png") && r.warnings.contains("image missing: img-2.png"))
    }

    @Test func bulletsAndNumbers() throws {
        let ul = node("li", x: 100, style: ["fontSize": "20px"], text: "a", list: DOMList(kind: "ul", index: 1, depth: 0))
        let ol = node("li", style: ["fontSize": "20px"], text: "b", list: DOMList(kind: "ol", index: 3, depth: 1))
        let xml = try slideXML([ul, ol]).xml
        #expect(xml.contains(#"<a:buChar char="•"/>"#))
        #expect(xml.contains(#"<a:buAutoNum type="arabicPeriod" startAt="3"/>"#))
        #expect(xml.contains(#"marL="285750" indent="-285750""#))     // 30 px
        #expect(xml.contains(#"marL="571500" indent="-285750""#))     // depth 1
        #expect(xml.contains(#"<a:off x="666750""#))                  // 100 − 30 px
    }

    @Test func notesPartExists() throws {
        let r = try PPTXWriter.build(deck([slide([]), slide([], notes: "say hi\nthen & bye")]), payloads: [:])
        let files = try unzip(r.data)
        #expect(files["ppt/notesSlides/notesSlide1.xml"] == nil)
        #expect(text(files, "ppt/notesSlides/notesSlide2.xml").contains("<a:t>then &amp; bye</a:t>"))
        #expect(files["ppt/notesMasters/notesMaster1.xml"] != nil && files["ppt/theme/theme2.xml"] != nil)
        #expect(text(files, "ppt/slides/_rels/slide2.xml.rels").contains("../notesSlides/notesSlide2.xml"))
        #expect(text(files, "ppt/presentation.xml").contains("</p:sldMasterIdLst><p:notesMasterIdLst>"))
        #expect(text(files, "[Content_Types].xml").contains("/ppt/notesSlides/notesSlide2.xml"))
        assertWellFormed(files)
        let plain = try unzip(PPTXWriter.build(deck([slide([])]), payloads: [:]).data)
        #expect(plain["ppt/notesMasters/notesMaster1.xml"] == nil)
    }

    @Test func shadowAndClipWarn() throws {
        let child = node(x: 50, y: 0, w: 100, h: 40, text: "x")
        let r = try slideXML([node(style: ["boxShadow": "rgb(0, 0, 0) 0px 1px 2px 0px", "clipPath": "circle(50%)",
                                           "overflow": "hidden"], children: [child]),
                              node(style: ["boxShadow": "none", "clipPath": "none"], text: "y")])
        #expect(r.warnings.contains("box-shadow dropped (1 elements)"))
        #expect(r.warnings.contains("clip-path dropped (1 elements)"))
        #expect(r.warnings.contains("overflow:hidden ignored (1)"))
    }

    @Test func xmlSpecialCharsStayValid() throws {
        let r = try slideXML([node(text: "A & B <c> \u{0}😀")])
        assertWellFormed(r.files)
        #expect(r.xml.contains("A &amp; B &lt;c&gt;") && r.xml.contains("😀") && !r.xml.contains("\u{0}"))
    }

    @Test func newlinesBecomeParagraphs() throws {
        let xml = try slideXML([node(text: "l1\nl2")]).xml
        #expect(xml.components(separatedBy: "<a:p>").count == 3)
    }

    @Test func invalidBoxesAreClampedOrDropped() throws {
        let nan = node(x: .nan, y: 1e12, w: 100, h: 40, style: ["backgroundColor": "rgb(0, 0, 0)"], text: "n")
        let zero = node(w: 0, h: 40, text: "z")
        let inf = node(w: .infinity, h: 40, text: "i")
        let r = try slideXML([nan, zero, inf])
        assertWellFormed(r.files)
        #expect(r.xml.contains(#"<a:off x="0" y="9525000000""#) == false)
        #expect(r.xml.contains(#"y="2147483647""#))   // 1e6 px clamps, then EMU clamps
        #expect(!r.xml.contains("<a:t>z</a:t>") && !r.xml.contains("<a:t>i</a:t>"))
        #expect(r.warnings.contains("slide 1: dropped 2 invalid boxes"))
    }

    @Test func hugeDeckThrows() {
        let many = (0..<20_001).map { _ in node() }
        #expect(throws: PPTXError.tooLarge) { try PPTXWriter.build(deck([slide(many)]), payloads: [:]) }
    }
}
