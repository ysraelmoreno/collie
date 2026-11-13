import Foundation

enum PPTXError: Error, Equatable { case noSlides, tooLarge }

/// Deck snapshot → editable .pptx (16:9, one blank layout). Pure: payloads come in by file name.
enum PPTXWriter {
    static let slideCX = 12_192_000, slideCY = 6_858_000

    static func build(_ deck: DeckSnapshot, payloads: [String: Data]) throws(PPTXError) -> (data: Data, warnings: [String]) {
        guard !deck.slides.isEmpty else { throw .noSlides }
        func count(_ n: DOMNode) -> Int { n.children.reduce(1) { $0 + count($1) } }
        guard deck.slides.reduce(0, { $0 + count($1.root) }) <= 20_000 else { throw .tooLarge }
        var warnings: [String] = [], families: Set<String> = [], entries: [(name: String, data: Data)] = []
        var media: [String: Int] = [:], missing: [String] = [], tally: [String: Int] = [:]
        func add(_ name: String, _ xml: String) { entries.append((name, Data(xml.utf8))) }

        let n = deck.slides.count
        let notes = deck.slides.map { s in s.notes.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
        let hasNotes = notes.contains { $0 != nil }
        let pml = "application/vnd.openxmlformats-officedocument.presentationml."
        var types: [(String, String)] = (1...n).map { ("/ppt/slides/slide\($0).xml", pml + "slide+xml") }
        if hasNotes {
            types += [("/ppt/notesMasters/notesMaster1.xml", pml + "notesMaster+xml"),
                      ("/ppt/theme/theme2.xml", "application/vnd.openxmlformats-officedocument.theme+xml")]
            types += notes.enumerated().compactMap { $0.element == nil ? nil : ("/ppt/notesSlides/notesSlide\($0.offset + 1).xml", pml + "notesSlide+xml") }
        }
        add("[Content_Types].xml", contentTypes(types))
        add("_rels/.rels", rels([("rId1", "officeDocument", "ppt/presentation.xml"),
                                 ("rId2", "metadata/core-properties", "docProps/core.xml"),
                                 ("rId3", "extended-properties", "docProps/app.xml")]))
        add("docProps/core.xml", #"\#(decl)<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\#(xmlEscape(deck.title))</dc:title><dc:creator>Collie</dc:creator></cp:coreProperties>"#)
        add("docProps/app.xml", #"\#(decl)<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Collie</Application><Slides>\#(n)</Slides></Properties>"#)
        add("ppt/presentation.xml", presentation(n, notes: hasNotes))
        add("ppt/_rels/presentation.xml.rels", rels([("rId1", "slideMaster", "slideMasters/slideMaster1.xml"),
                                                     ("rId2", "theme", "theme/theme1.xml"),
                                                     ("rId3", "presProps", "presProps.xml"),
                                                     ("rId4", "viewProps", "viewProps.xml"),
                                                     ("rId5", "tableStyles", "tableStyles.xml")]
                                                    + (hasNotes ? [("rId6", "notesMaster", "notesMasters/notesMaster1.xml")] : [])
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
        if hasNotes {
            add("ppt/theme/theme2.xml", theme)
            add("ppt/notesMasters/notesMaster1.xml", notesMaster)
            add("ppt/notesMasters/_rels/notesMaster1.xml.rels", rels([("rId1", "theme", "../theme/theme2.xml")]))
        }

        for (i, slide) in deck.slides.enumerated() {
            var b = SlideBuilder(scale: Double(slideCX) / (slide.w.isFinite && slide.w > 0 ? slide.w : 1280),
                                 payloads: payloads, media: media)
            b.walk(slide.root, root: true)
            families.formUnion(b.families)
            media = b.media
            for m in b.missing where !missing.contains(m) { missing.append(m) }
            tally.merge(b.tally, uniquingKeysWith: +)
            if b.dropped > 0 { warnings.append("slide \(i + 1): dropped \(b.dropped) invalid boxes") }
            if let text = notes[i] {
                b.rels.append(("notesSlide", "../notesSlides/notesSlide\(i + 1).xml"))
                add("ppt/notesSlides/notesSlide\(i + 1).xml", notesSlide(text))
                add("ppt/notesSlides/_rels/notesSlide\(i + 1).xml.rels",
                    rels([("rId1", "notesMaster", "../notesMasters/notesMaster1.xml"), ("rId2", "slide", "../slides/slide\(i + 1).xml")]))
            }
            var bg = slide.background
            if let g = bg, g.contains("linear-gradient(") {
                warnings.append("slide \(i + 1): gradient background → first color")
                bg = g.range(of: "rgb").flatMap { HTMLImport.leadingColor(String(g[$0.lowerBound...]))?.color }
            }
            let bgXML = bg.flatMap(CSSColor.parse).map { "<p:bg><p:bgPr>\(fill($0))<a:effectLst/></p:bgPr></p:bg>" } ?? ""
            add("ppt/slides/slide\(i + 1).xml", #"\#(decl)<p:sld \#(ns)><p:cSld>\#(bgXML)<p:spTree>\#(group)\#(b.shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"#)
            add("ppt/slides/_rels/slide\(i + 1).xml.rels",
                rels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")]
                     + b.rels.enumerated().map { ("rId\($0.offset + 2)", $0.element.type, $0.element.target) }, external: true))
        }
        for (file, k) in media.sorted(by: { $0.value < $1.value }) { entries.append(("ppt/media/image\(k).png", payloads[file]!)) }

        if !families.isEmpty { warnings.append("fonts not embedded: " + families.sorted().joined(separator: ", ")) }
        let pseudo = deck.slides.reduce(0) { $0 + max(0, $1.pseudo ?? 0) }
        if pseudo > 0 { warnings.append("pseudo-element content dropped (\(pseudo) elements)") }
        warnings += missing.map { "image missing: \($0)" }
        for (key, text) in [("border", "non-uniform borders approximated (%d)"), ("shadow", "box-shadow dropped (%d elements)"),
                            ("clip", "clip-path dropped (%d elements)"), ("overflow", "overflow:hidden ignored (%d)")] {
            if let k = tally[key] { warnings.append(text.replacingOccurrences(of: "%d", with: "\(k)")) }
        }
        do { return (try ZipWriter.archive(entries), warnings) } catch { throw .tooLarge }
    }

    // MARK: - Slide content

    private struct SlideBuilder {
        let scale: Double, payloads: [String: Data]
        /// payload file → media number, shared across slides
        var media: [String: Int]
        var shapes = "", rels: [(type: String, target: String)] = [], families: Set<String> = [], nextID = 2
        var missing: [String] = [], tally: [String: Int] = [:], dropped = 0

        /// Next slide relationship id: rId1 is the layout.
        mutating func rel(_ type: String, _ target: String) -> String {
            rels.append((type, target))
            return "rId\(rels.count + 1)"
        }

        func xfrm(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> String {
            #"<a:xfrm><a:off x="\#(emu(x, scale: scale))" y="\#(emu(y, scale: scale))"/>"#
                + #"<a:ext cx="\#(max(0, emu(w, scale: scale)))" cy="\#(max(0, emu(h, scale: scale)))"/></a:xfrm>"#
        }

        /// Document order is z-order.
        mutating func walk(_ raw: DOMNode, root: Bool = false) {
            var node = raw
            node.x = HTMLImport.clamp(node.x); node.y = HTMLImport.clamp(node.y)
            node.w = HTMLImport.clamp(node.w); node.h = HTMLImport.clamp(node.h)
            if (node.w <= 0 || node.h <= 0) && node.children.isEmpty { dropped += 1; return }
            let s = node.style, loose = node.tag == "#text"   // a loose text node carries its parent's box style
            if !loose, let v = s["boxShadow"], !v.isEmpty, v != "none" { tally["shadow", default: 0] += 1 }
            if !loose, let v = s["clipPath"], !v.isEmpty, v != "none" { tally["clip", default: 0] += 1 }
            if !root && !loose { shape(node) }   // the root's fill is the slide background
            if let img = node.image { picture(node, img); return }
            if let t = node.text, !t.isEmpty { textBox(node, t); return }
            let clips = (s["overflow"] ?? "").split(separator: " ").contains { $0 == "hidden" || $0 == "clip" }
            if clips, node.children.contains(where: {
                $0.x < node.x - 0.5 || $0.y < node.y - 0.5 || $0.x + $0.w > node.x + node.w + 0.5 || $0.y + $0.h > node.y + node.h + 0.5
            }) { tally["overflow", default: 0] += 1 }
            for c in node.children { walk(c) }
        }

        mutating func shape(_ n: DOMNode) {
            let s = n.style
            let bg = s["backgroundColor"].flatMap(CSSColor.parse)
            // the snapshot omits initial values: an absent style is none, an absent colour is currentColor (≈ black)
            let sides = ["Top", "Right", "Bottom", "Left"].map { side -> Double in
                let w = HTMLImport.px(s["border\(side)Width"]) ?? 0
                return w > 0 && (s["border\(side)Style"] ?? "none") != "none" ? w : 0
            }
            let first = sides.firstIndex { $0 > 0 }
            guard bg != nil || first != nil else { return }
            var ln = ""
            if let k = first {
                if Set(sides).count > 1 { tally["border", default: 0] += 1 }   // differing widths or unbordered sides
                let side = ["Top", "Right", "Bottom", "Left"][k]
                if let c = CSSColor.parse(s["border\(side)Color"] ?? s["color"] ?? "rgb(0, 0, 0)") {
                    ln = #"<a:ln w="\#(emu(sides[k], scale: scale))">\#(PPTXWriter.fill(c))</a:ln>"#
                }
            }
            let minSide = min(n.w, n.h)
            let r = s["borderTopLeftRadius"]?.split(separator: " ").first.map(String.init).flatMap { v in
                v.hasSuffix("%") ? HTMLImport.finite(Double(v.dropLast())).map { $0 * minSide / 100 } : HTMLImport.px(v)
            } ?? 0
            let geom = r > 0 && minSide > 0
                ? #"<a:prstGeom prst="roundRect"><a:avLst><a:gd name="adj" fmla="val \#(Int((min(r / minSide, 0.5) * 100_000).rounded()))"/></a:avLst></a:prstGeom>"#
                : #"<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>"#
            let id = nextID
            nextID += 1
            shapes += #"<p:sp><p:nvSpPr><p:cNvPr id="\#(id)" name="Shape \#(id)"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>"#
                + #"<p:spPr>\#(xfrm(n.x, n.y, n.w, n.h))\#(geom)\#(bg.map(PPTXWriter.fill) ?? "<a:noFill/>")\#(ln)</p:spPr></p:sp>"#
        }

        mutating func picture(_ n: DOMNode, _ img: DOMImage) {
            guard (payloads[img.file]?.count ?? .max) <= 4 * 1024 * 1024 else {
                if !missing.contains(img.file) { missing.append(img.file) }
                return
            }
            let k = media[img.file] ?? media.count + 1
            media[img.file] = k
            var (x, y, w, h) = (n.x, n.y, n.w, n.h), crop = ""
            let ra = img.w / img.h, rb = w / h
            if ra.isFinite, ra > 0, rb.isFinite, rb > 0 {
                switch img.fit {
                case "cover" where ra > rb:
                    let c = Int(((1 - rb / ra) / 2 * 100_000).rounded())
                    crop = #"<a:srcRect l="\#(c)" r="\#(c)"/>"#
                case "cover" where ra < rb:
                    let c = Int(((1 - ra / rb) / 2 * 100_000).rounded())
                    crop = #"<a:srcRect t="\#(c)" b="\#(c)"/>"#
                case "contain" where ra > rb:
                    let nh = w / ra; y += (h - nh) / 2; h = nh
                case "contain" where ra < rb:
                    let nw = h * ra; x += (w - nw) / 2; w = nw
                default: break   // fill (and anything else) stretches
                }
            }
            let rid = rel("image", "../media/image\(k).png")
            let id = nextID
            nextID += 1
            shapes += #"<p:pic><p:nvPicPr><p:cNvPr id="\#(id)" name="Picture \#(id)" descr="\#(xmlEscape(n.alt ?? ""))"/>"#
                + #"<p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>"#
                + #"<p:blipFill><a:blip r:embed="\#(rid)"/>\#(crop)<a:stretch><a:fillRect/></a:stretch></p:blipFill>"#
                + #"<p:spPr>\#(xfrm(x, y, w, h))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>"#
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
                .map { #" algn="\#($0)""# } ?? ""
            // list item: hanging bullet 1.5 em left of the text, which stays where the page drew it
            var (x, w) = (node.x, node.w), pPr = algn.isEmpty ? "" : "<a:pPr\(algn)/>", contPPr = pPr
            if let l = node.list {
                let depth = max(0, min(l.depth, 8)), em15 = 1.5 * px
                let base = emu(em15, scale: scale), marL = base * (depth + 1)
                x -= em15 * Double(depth + 1); w += em15 * Double(depth + 1)
                let bu = l.kind == "ol" ? #"<a:buAutoNum type="arabicPeriod" startAt="\#(max(1, min(l.index, 32767)))"/>"#
                    : #"<a:buChar char="•"/>"#
                pPr = #"<a:pPr marL="\#(marL)" indent="-\#(base)"\#(algn)>\#(bu)</a:pPr>"#
                contPPr = #"<a:pPr marL="\#(marL)" indent="0"\#(algn)><a:buNone/></a:pPr>"#
            }

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
                    props += #"<a:hlinkClick r:id="\#(rel("hyperlink", href))"/>"#
                }
                let piece = String(decoding: u[a..<b], as: UTF16.self)
                cur += #"<a:r><a:rPr \#(attrs) dirty="0">\#(props)</a:rPr><a:t>\#(xmlEscape(piece))</a:t></a:r>"#
            }
            paras.append(cur)
            let body = paras.enumerated().map {
                #"<a:p>\#($0.offset == 0 ? pPr : contPPr)\#($0.element)<a:endParaRPr lang="en-US" sz="\#(sz)" dirty="0"/></a:p>"#
            }.joined()

            let id = nextID
            nextID += 1
            shapes += #"<p:sp><p:nvSpPr><p:cNvPr id="\#(id)" name="Text \#(id)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>"#
                + #"<p:spPr>\#(xfrm(x, node.y, w, node.h))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>"#
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

    /// `extra`: per-deck overrides (slides, notes).
    static func contentTypes(_ extra: [(String, String)]) -> String {
        let pml = "application/vnd.openxmlformats-officedocument.presentationml."
        let o = [("/ppt/presentation.xml", pml + "presentation.main+xml"),
                 ("/ppt/slideMasters/slideMaster1.xml", pml + "slideMaster+xml"),
                 ("/ppt/slideLayouts/slideLayout1.xml", pml + "slideLayout+xml"),
                 ("/ppt/theme/theme1.xml", "application/vnd.openxmlformats-officedocument.theme+xml"),
                 ("/ppt/presProps.xml", pml + "presProps+xml"),
                 ("/ppt/viewProps.xml", pml + "viewProps+xml"),
                 ("/ppt/tableStyles.xml", pml + "tableStyles+xml"),
                 ("/docProps/core.xml", "application/vnd.openxmlformats-package.core-properties+xml"),
                 ("/docProps/app.xml", "application/vnd.openxmlformats-officedocument.extended-properties+xml")] + extra
        let overrides = o.map { #"<Override PartName="\#($0.0)" ContentType="\#($0.1)"/>"# }.joined()
        return #"\#(decl)<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>\#(overrides)</Types>"#
    }

    static func presentation(_ n: Int, notes: Bool) -> String {
        let ids = (1...n).map { #"<p:sldId id="\#(255 + $0)" r:id="rIdS\#($0)"/>"# }.joined()
        let nm = notes ? #"<p:notesMasterIdLst><p:notesMasterId r:id="rId6"/></p:notesMasterIdLst>"# : ""
        return #"\#(decl)<p:presentation \#(ns) saveSubsetFonts="1"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\#(nm)<p:sldIdLst>\#(ids)</p:sldIdLst><p:sldSz cx="\#(slideCX)" cy="\#(slideCY)"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>"#
    }

    static let master = #"\#(decl)<p:sldMaster \#(ns)><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree>\#(group)</p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz="4400"/></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>"#

    static let layout = #"\#(decl)<p:sldLayout \#(ns) type="blank" preserve="1"><p:cSld name="Blank"><p:spTree>\#(group)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"#

    static let notesBody = #"<p:sp><p:nvSpPr><p:cNvPr id="2" name="Notes Placeholder 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>"#

    /// Slide thumbnail on the Notes Page.
    static func sldImg(_ spPr: String) -> String {
        #"<p:sp><p:nvSpPr><p:cNvPr id="3" name="Slide Image Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvSpPr><p:nvPr><p:ph type="sldImg" idx="2"/></p:nvPr></p:nvSpPr>\#(spPr)</p:sp>"#
    }

    static let notesMaster = #"\#(decl)<p:notesMaster \#(ns)><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree>\#(group)\#(sldImg(#"<p:spPr><a:xfrm><a:off x="685800" y="1143000"/><a:ext cx="5486400" cy="3086100"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>"#))\#(notesBody)<p:spPr><a:xfrm><a:off x="685800" y="4400550"/><a:ext cx="5486400" cy="3600450"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp></p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:notesStyle><a:lvl1pPr><a:defRPr sz="1200"/></a:lvl1pPr></p:notesStyle></p:notesMaster>"#

    static func notesSlide(_ text: String) -> String {
        let paras = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { #"<a:p><a:r><a:rPr lang="en-US" dirty="0"/><a:t>\#(xmlEscape(String($0)))</a:t></a:r></a:p>"# }.joined()
        return #"\#(decl)<p:notes \#(ns)><p:cSld><p:spTree>\#(group)\#(sldImg("<p:spPr/>"))\#(notesBody)<p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>\#(paras)</p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>"#
    }

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
