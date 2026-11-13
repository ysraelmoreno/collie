import Foundation

enum PPTXError: Error, Equatable { case noSlides, tooLarge }

/// Deck snapshot → editable .pptx (16:9, one blank layout). Pure: payloads come in by file name.
enum PPTXWriter {
    static let slideCX = 12_192_000, slideCY = 6_858_000

    static func build(_ deck: DeckSnapshot, payloads: [String: Data]) throws(PPTXError) -> (data: Data, warnings: [String]) {
        guard !deck.slides.isEmpty else { throw .noSlides }
        _ = payloads   // ponytail: pictures land in Task 5
        var warnings: [String] = [], families: Set<String> = [], entries: [(name: String, data: Data)] = []
        func add(_ name: String, _ xml: String) { entries.append((name, Data(xml.utf8))) }

        let n = deck.slides.count
        add("[Content_Types].xml", contentTypes(n))
        add("_rels/.rels", rels([("rId1", "officeDocument", "ppt/presentation.xml"),
                                 ("rId2", "metadata/core-properties", "docProps/core.xml"),
                                 ("rId3", "extended-properties", "docProps/app.xml")]))
        add("docProps/core.xml", #"\#(decl)<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\#(xmlEscape(deck.title))</dc:title><dc:creator>Collie</dc:creator></cp:coreProperties>"#)
        add("docProps/app.xml", #"\#(decl)<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Collie</Application><Slides>\#(n)</Slides></Properties>"#)
        add("ppt/presentation.xml", presentation(n))
        add("ppt/_rels/presentation.xml.rels", rels([("rId1", "slideMaster", "slideMasters/slideMaster1.xml"),
                                                     ("rId2", "theme", "theme/theme1.xml"),
                                                     ("rId3", "presProps", "presProps.xml"),
                                                     ("rId4", "viewProps", "viewProps.xml"),
                                                     ("rId5", "tableStyles", "tableStyles.xml")]
                                                    + (1...n).map { ("rIdS\($0)", "slide", "slides/slide\($0).xml") }))
        add("ppt/presProps.xml", #"\#(decl)<p:presentationPr \#(ns)/>"#)
        add("ppt/viewProps.xml", #"\#(decl)<p:viewPr \#(ns)/>"#)
        add("ppt/tableStyles.xml", #"\#(decl)<a:tblStyleLst xmlns:a="\#(nsA)" def="{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"/>"#)
        add("ppt/slideMasters/slideMaster1.xml", master)
        add("ppt/slideMasters/_rels/slideMaster1.xml.rels", rels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"),
                                                                  ("rId2", "theme", "../theme/theme1.xml")]))
        add("ppt/slideLayouts/slideLayout1.xml", layout)
        add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", rels([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")]))
        add("ppt/theme/theme1.xml", theme)

        for (i, slide) in deck.slides.enumerated() {
            var b = SlideBuilder(scale: Double(slideCX) / (slide.w.isFinite && slide.w > 0 ? slide.w : 1280))
            b.walk(slide.root)
            families.formUnion(b.families)
            var bg = slide.background
            if let g = bg, g.contains("linear-gradient(") {
                warnings.append("slide \(i + 1): gradient background → first color")
                bg = g.range(of: "rgb").flatMap { HTMLImport.leadingColor(String(g[$0.lowerBound...]))?.color }
            }
            let bgXML = bg.flatMap(CSSColor.parse).map { "<p:bg><p:bgPr>\(fill($0))<a:effectLst/></p:bgPr></p:bg>" } ?? ""
            add("ppt/slides/slide\(i + 1).xml", #"\#(decl)<p:sld \#(ns)><p:cSld>\#(bgXML)<p:spTree>\#(group)\#(b.shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"#)
            add("ppt/slides/_rels/slide\(i + 1).xml.rels",
                rels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")]
                     + b.links.enumerated().map { ("rId\($0.offset + 2)", "hyperlink", $0.element) }, external: true))
        }

        if !families.isEmpty { warnings.append("fonts not embedded: " + families.sorted().joined(separator: ", ")) }
        let pseudo = deck.slides.reduce(0) { $0 + max(0, $1.pseudo ?? 0) }
        if pseudo > 0 { warnings.append("pseudo-element content dropped (\(pseudo) elements)") }
        do { return (try ZipWriter.archive(entries), warnings) } catch { throw .tooLarge }
    }

    // MARK: - Text

    private struct SlideBuilder {
        let scale: Double
        var shapes = "", links: [String] = [], families: Set<String> = [], nextID = 2

        mutating func walk(_ node: DOMNode) {
            if let t = node.text, !t.isEmpty { textBox(node, t); return }
            for c in node.children { walk(c) }
        }

        mutating func textBox(_ node: DOMNode, _ text: String) {
            let s = node.style
            let family = s["fontFamily"]?.split(separator: ",").first
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                .flatMap { $0.isEmpty ? nil : $0 }
            if let family { families.insert(family) }
            let px = HTMLImport.px(s["fontSize"]).flatMap { $0 > 0 ? $0 : nil } ?? 16
            let sz = Int(min(max((px * 0.75 * 100).rounded(), 100), 400_000))
            // a loose text node's box is its text; the padding in its style is the parent's
            func inset(_ k: String) -> Int { node.tag == "#text" ? 0 : max(0, emu(HTMLImport.px(s[k]) ?? 0, scale: scale)) }
            let algn = ["left": "l", "start": "l", "center": "ctr", "right": "r", "end": "r", "justify": "just"][s["textAlign"] ?? ""]
            let pPr = algn.map { #"<a:pPr algn="\#($0)"/>"# } ?? ""

            // segments at run and line boundaries (UTF-16 offsets, clamped: snapshot values are untrusted)
            let u = Array(text.utf16)
            let runs: [(s: Int, e: Int, run: DOMRun)] = (node.runs ?? []).compactMap {
                let a = max(0, min($0.start, u.count)), b = max(a, min($0.end, u.count))
                return a < b ? (a, b, $0) : nil
            }
            var cuts: Set<Int> = [0, u.count]
            for r in runs { cuts.insert(r.s); cuts.insert(r.e) }
            for (i, c) in u.enumerated() where c == 10 { cuts.insert(i); cuts.insert(i + 1) }
            let bounds = cuts.sorted()

            var paras: [String] = [], cur = ""
            for (a, b) in zip(bounds, bounds.dropFirst()) {
                if b == a + 1, u[a] == 10 { paras.append(cur); cur = ""; continue }
                let r = runs.last { $0.s <= a && b <= $0.e }?.run
                let bold = Self.bold(r?.fontWeight ?? s["fontWeight"])
                let italic = (r?.fontStyle ?? s["fontStyle"]).map { $0.contains("italic") || $0.contains("oblique") } ?? false
                let under = HTMLImport.decoration(r?.decoration ?? s["textDecorationLine"]) == "underline"
                var attrs = #"lang="en-US" sz="\#(sz)""#
                if bold { attrs += #" b="1""# }
                if italic { attrs += #" i="1""# }
                if under { attrs += #" u="sng""# }
                var props = (r?.color ?? s["color"]).flatMap(CSSColor.parse).map(PPTXWriter.fill) ?? ""
                if let family { props += #"<a:latin typeface="\#(xmlEscape(family))"/>"# }
                if let href = r?.href ?? node.href, !href.isEmpty, !href.hasPrefix("#") {
                    links.append(href)
                    props += #"<a:hlinkClick r:id="rId\#(links.count + 1)"/>"#
                }
                let piece = String(decoding: u[a..<b], as: UTF16.self)
                cur += #"<a:r><a:rPr \#(attrs) dirty="0">\#(props)</a:rPr><a:t>\#(xmlEscape(piece))</a:t></a:r>"#
            }
            paras.append(cur)
            let body = paras.map { #"<a:p>\#(pPr)\#($0)<a:endParaRPr lang="en-US" sz="\#(sz)" dirty="0"/></a:p>"# }.joined()

            let id = nextID
            nextID += 1
            shapes += #"<p:sp><p:nvSpPr><p:cNvPr id="\#(id)" name="Text \#(id)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>"#
                + #"<p:spPr><a:xfrm><a:off x="\#(emu(node.x, scale: scale))" y="\#(emu(node.y, scale: scale))"/>"#
                + #"<a:ext cx="\#(max(0, emu(node.w, scale: scale)))" cy="\#(max(0, emu(node.h, scale: scale)))"/></a:xfrm>"#
                + #"<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>"#
                + #"<p:txBody><a:bodyPr wrap="square" lIns="\#(inset("paddingLeft"))" tIns="\#(inset("paddingTop"))" "#
                + #"rIns="\#(inset("paddingRight"))" bIns="\#(inset("paddingBottom"))" anchor="t" rtlCol="0"><a:noAutofit/></a:bodyPr>"#
                + #"<a:lstStyle/>\#(body)</p:txBody></p:sp>"#
        }

        static func bold(_ w: String?) -> Bool {
            guard let w else { return false }
            return w == "bold" || w == "bolder" || (Double(w).map { $0 >= 600 } ?? false)
        }
    }

    static func fill(_ c: (hex: String, alpha: Int)) -> String {
        c.alpha >= 100_000 ? #"<a:solidFill><a:srgbClr val="\#(c.hex)"/></a:solidFill>"#
            : #"<a:solidFill><a:srgbClr val="\#(c.hex)"><a:alpha val="\#(c.alpha)"/></a:srgbClr></a:solidFill>"#
    }

    // MARK: - Package parts

    static let decl = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
    static let nsA = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let ns = #"xmlns:a="\#(nsA)" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
    static let group = #"<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>"#

    /// `(id, type, target)`; type is relative to the officeDocument (or, `metadata/…`, package) relationships namespace.
    /// `external` marks hyperlinks `TargetMode="External"`.
    static func rels(_ list: [(String, String, String)], external: Bool = false) -> String {
        let items = list.map { id, type, target in
            let base = type.hasPrefix("metadata/") ? "http://schemas.openxmlformats.org/package/2006/relationships/"
                : "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
            let mode = external && type == "hyperlink" ? #" TargetMode="External""# : ""
            return #"<Relationship Id="\#(id)" Type="\#(base)\#(type)" Target="\#(xmlEscape(target))"\#(mode)/>"#
        }.joined()
        return #"\#(decl)<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(items)</Relationships>"#
    }

    static func contentTypes(_ n: Int) -> String {
        let pml = "application/vnd.openxmlformats-officedocument.presentationml."
        var o = [("/ppt/presentation.xml", pml + "presentation.main+xml"),
                 ("/ppt/slideMasters/slideMaster1.xml", pml + "slideMaster+xml"),
                 ("/ppt/slideLayouts/slideLayout1.xml", pml + "slideLayout+xml"),
                 ("/ppt/theme/theme1.xml", "application/vnd.openxmlformats-officedocument.theme+xml"),
                 ("/ppt/presProps.xml", pml + "presProps+xml"),
                 ("/ppt/viewProps.xml", pml + "viewProps+xml"),
                 ("/ppt/tableStyles.xml", pml + "tableStyles+xml"),
                 ("/docProps/core.xml", "application/vnd.openxmlformats-package.core-properties+xml"),
                 ("/docProps/app.xml", "application/vnd.openxmlformats-officedocument.extended-properties+xml")]
        o += (1...n).map { ("/ppt/slides/slide\($0).xml", pml + "slide+xml") }
        let overrides = o.map { #"<Override PartName="\#($0.0)" ContentType="\#($0.1)"/>"# }.joined()
        return #"\#(decl)<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>\#(overrides)</Types>"#
    }

    static func presentation(_ n: Int) -> String {
        let ids = (1...n).map { #"<p:sldId id="\#(255 + $0)" r:id="rIdS\#($0)"/>"# }.joined()
        return #"\#(decl)<p:presentation \#(ns) saveSubsetFonts="1"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\#(ids)</p:sldIdLst><p:sldSz cx="\#(slideCX)" cy="\#(slideCY)"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>"#
    }

    static let master = #"\#(decl)<p:sldMaster \#(ns)><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree>\#(group)</p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz="4400"/></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>"#

    static let layout = #"\#(decl)<p:sldLayout \#(ns) type="blank" preserve="1"><p:cSld name="Blank"><p:spTree>\#(group)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"#

    static let theme: String = {
        func c(_ tag: String, _ hex: String) -> String { #"<a:\#(tag)><a:srgbClr val="\#(hex)"/></a:\#(tag)>"# }
        let colors = c("dk1", "000000") + c("lt1", "FFFFFF") + c("dk2", "1F2937") + c("lt2", "F3F4F6")
            + c("accent1", "4472C4") + c("accent2", "ED7D31") + c("accent3", "A5A5A5") + c("accent4", "FFC000")
            + c("accent5", "5B9BD5") + c("accent6", "70AD47") + c("hlink", "0563C1") + c("folHlink", "954F72")
        let font = #"<a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/>"#
        let solid = #"<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>"#
        let three = { (s: String) in String(repeating: s, count: 3) }
        return #"\#(decl)<a:theme xmlns:a="\#(nsA)" name="Collie"><a:themeElements><a:clrScheme name="Collie">\#(colors)</a:clrScheme><a:fontScheme name="Collie"><a:majorFont>\#(font)</a:majorFont><a:minorFont>\#(font)</a:minorFont></a:fontScheme><a:fmtScheme name="Collie"><a:fillStyleLst>\#(three(solid))</a:fillStyleLst><a:lnStyleLst>\#(three(#"<a:ln w="6350">\#(solid)</a:ln>"#))</a:lnStyleLst><a:effectStyleLst>\#(three("<a:effectStyle><a:effectLst/></a:effectStyle>"))</a:effectStyleLst><a:bgFillStyleLst>\#(three(solid))</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"#
    }()
}
