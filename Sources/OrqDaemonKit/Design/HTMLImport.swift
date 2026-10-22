import Foundation
import OrqProtocol

/// `HTMLSnapshotScript`'s output (see `HTMLSnapshotter`): page CSS px, `style` = computed values that differ from the
/// CSS initial value (inherited ones on non-text nodes: from the parent's).
struct DOMSnapshot: Decodable, Sendable {
    var title: String
    var width: Double
    var height: Double
    var truncated: Bool
    var blocked: [String]
    var root: DOMNode
}

struct DOMNode: Decodable, Sendable {
    var tag: String
    var x: Double, y: Double, w: Double, h: Double
    var style: [String: String]
    var children: [DOMNode]
    var text: String? = nil
    var runs: [DOMRun]? = nil
    var href: String? = nil
    var cls: String? = nil
    var id: String? = nil
    var alt: String? = nil
    var image: DOMImage? = nil
    var svg: DOMFile? = nil
}

/// A styled span of a text leaf; `start`/`end` are UTF-16 offsets into its `text`.
struct DOMRun: Decodable, Sendable {
    var start: Int, end: Int
    var color: String? = nil
    var fontWeight: String? = nil
    var fontStyle: String? = nil
    var decoration: String? = nil
    var href: String? = nil
}

struct DOMImage: Decodable, Sendable { var file: String; var w: Double; var h: Double; var fit: String }
struct DOMFile: Decodable, Sendable { var file: String }

/// The engine's fonts: family → style names, as `text.fonts` lists them.
struct FontBook: Sendable { var families: [String: [String]] }

private typealias Props = [String: JSONValue]
private func str(_ s: String) -> JSONValue { .string(s) }
/// Outgoing numbers: finite, within ±1e6 (snapshot values are untrusted).
private func num(_ d: Double) -> JSONValue { .number(HTMLImport.clamp(d)) }
private func ref(_ step: Int) -> JSONValue { .object(["$step": .number(Double(step))]) }

/// Turns a DOM snapshot into figcraft batch steps (`{command, params}`, `{"$step": n}` refs) that rebuild the page
/// as one screen frame (step 0). Pure: payloads come in by file name. Snapshot values only ever become parameter
/// values, never commands or keys.
enum HTMLImport {
    static let maxLayers = 3000

    /// An opaque solid color the steps paint: the `node.create` step, `fill`|`stroke`|`textFill` (a text layer's
    /// fill), and its `#RRGGBB`.
    typealias ColorUse = (step: Int, field: String, hex: String)

    static func steps(_ s: DOMSnapshot, payloads: [String: Data], fonts: FontBook,
                      name: String) -> (steps: [JSONValue], warnings: [String], colorUses: [ColorUse]) {
        var b = Builder(payloads: payloads, fonts: fonts)
        if s.truncated { b.warn("page truncated at 3000 elements") }
        for u in s.blocked { b.warn("blocked network resource: \(u)") }
        let n = count(s.root)
        guard n <= maxLayers else {
            b.warn("page too large to import (\(n) layers; max \(maxLayers))")
            return ([], b.warnings, [])
        }
        let body = s.root.children.first { $0.tag == "body" }
        let fill = paint(body?.style["backgroundColor"]) ?? paint(s.root.style["backgroundColor"]) ?? str("#FFFFFF")
        let root = b.add("node.create", ["type": str("frame"), "name": str(name), "x": num(0), "y": num(0),
                                         "width": num(s.width), "height": num(s.height),
                                         "props": .object(["fills": .array([fill]), "clip": .bool(true)])])
        let typo = inherit([:], s.root)
        for c in s.root.children { b.map(c, parent: root, in: s.root, layout: nil, typo: typo) }
        return (b.steps, b.warnings, colorUses(b.steps))
    }

    // ponytail: a text run's color (text.style over a range) is left out: a variable binds a whole layer's fill
    /// The first fill and stroke of each frame and text layer created, when solid and opaque (a bound color keeps the
    /// paint's opacity: a translucent one stays literal). Placeholders (rectangles) are not the page's colors.
    static func colorUses(_ steps: [JSONValue]) -> [ColorUse] {
        func hex(_ v: JSONValue?) -> String? {
            guard case .array(let paints)? = v, let first = paints.first else { return nil }
            switch first {
            case .string(let h): return normHex(h)
            case .object(let o):
                guard o["type"] == str("solid"), case .string(let h)? = o["color"] else { return nil }
                if case .number(let a)? = o["opacity"], a < 1 { return nil }
                return normHex(h)
            default: return nil
            }
        }
        var out: [ColorUse] = []
        for (i, step) in steps.enumerated() {
            guard case .object(let o) = step, o["command"] == str("node.create"), case .object(let p)? = o["params"],
                  case .object(let props)? = p["props"], p["type"] != str("rectangle") else { continue }
            if let h = hex(props["fills"]) { out.append((i, p["type"] == str("text") ? "textFill" : "fill", h)) }
            if let h = hex(props["strokes"]) { out.append((i, "stroke", h)) }
        }
        return out
    }

    /// `#rrggbb[aa]` upper-cased, an opaque `FF` alpha dropped.
    static func normHex(_ h: String) -> String {
        let u = h.uppercased()
        return u.count == 9 && u.hasSuffix("FF") ? String(u.dropLast(2)) : u
    }

    /// A `variable.list` answer's color variables, by value in their collection's first mode: hex → variable (its
    /// id and name; two of one value: the first name A-Z), of those whose id is in `published` (nil: any).
    static func colorNames(_ list: JSONValue, published: Set<String>? = nil) -> [String: (id: String, name: String)] {
        guard case .object(let o) = list, case .array(let cols)? = o["collections"], case .array(let vars)? = o["variables"] else { return [:] }
        var first: [String: String] = [:]   // collection id → its first mode id
        for case .object(let c) in cols {
            if case .string(let id)? = c["id"], case .array(let modes)? = c["modes"], case .object(let m)? = modes.first,
               case .string(let mid)? = m["id"] { first[id] = mid }
        }
        var out: [String: (id: String, name: String)] = [:]
        let rows = vars.compactMap { v -> (String, [String: JSONValue])? in
            guard case .object(let v) = v, case .string(let n)? = v["name"] else { return nil }
            return (n, v)
        }.sorted { $0.0 < $1.0 }
        for (name, v) in rows {
            guard case .string(let id)? = v["id"], published?.contains(id) ?? true, case .string(let col)? = v["collection"], let mode = first[col], case .object(let vals)? = v["values"],
                  case .object(let val)? = vals[mode], val["type"] == str("color"), case .object(let c)? = val["value"] else { continue }
            func ch(_ k: String) -> Int {
                guard case .number(let x)? = c[k], x.isFinite else { return 255 }
                return Int((min(max(x, 0), 1) * 255).rounded())
            }
            let h = normHex("#" + ["r", "g", "b", "a"].map { String(format: "%02X", ch($0)) }.joined())
            if out[h] == nil { out[h] = (id, name) }
        }
        return out
    }

    private static func count(_ n: DOMNode) -> Int { n.children.reduce(1) { $0 + count($1) } }

    static let inherited: Set = ["color", "fontFamily", "fontSize", "fontWeight", "fontStyle", "lineHeight", "letterSpacing",
                                 "textAlign", "textTransform"]
    /// Inherited typography walked down from the root (missing at the root = the CSS initial value).
    static func inherit(_ parent: [String: String], _ n: DOMNode) -> [String: String] {
        parent.merging(n.style.filter { inherited.contains($0.key) }) { $1 }
    }

    private struct Builder {
        let payloads: [String: Data]
        let fonts: FontBook
        var steps: [JSONValue] = []
        var warnings: [String] = []

        mutating func add(_ command: String, _ params: Props) -> Int {
            steps.append(.object(["command": str(command), "params": .object(params)]))
            return steps.count - 1
        }
        mutating func warn(_ w: String) { if !warnings.contains(w) { warnings.append(w) } }

        /// Only `img-<n>.png` / `svg-<n>.svg` names the snapshot wrote.
        func payload(_ file: String?) -> String? {
            guard let file, file.wholeMatch(of: /(img|svg)-\d+\.(png|svg)/) != nil else { return nil }
            return payloads[file]?.base64EncodedString()
        }

        mutating func map(_ n: DOMNode, parent: Int, in p: DOMNode, layout: String?, typo parentTypo: [String: String]) {
            let n = HTMLImport.clipped(n)
            if let cp = n.style["clipPath"], cp != "none" { warn("clip-path \(cp.prefix(24)) not imported: \(layerName(n))") }
            // a text leaf's style is relative to the CSS initial values, not to its parent
            let typo = inherit(n.text != nil ? [:] : parentTypo, n)
            let x = n.x - p.x, y = n.y - p.y
            // in an auto layout: absolute children keep their place, the rest keep their size
            var place: Props = [:]
            if layout != nil {
                if ["absolute", "fixed"].contains(n.style["position"]) { place["absolute"] = .bool(true) }
                else { place["sizingH"] = str("fixed"); place["sizingV"] = str("fixed") }
            }
            let geo: Props = ["parent": ref(parent), "x": num(x), "y": num(y), "width": num(max(0, n.w)), "height": num(max(0, n.h))]
            if let text = n.text { return textLeaf(n, text, typo: typo, geo: geo, place: place) }
            if n.svg != nil || n.tag == "svg" {
                guard let data = payload(n.svg?.file) else {
                    warn("svg not imported: \(layerName(n))")
                    return placeholder(n, geo: geo, place: place)
                }
                let i = add("file.import", ["data": str(data), "name": str("icon.svg"), "x": num(x), "y": num(y)])
                _ = add("node.reparent", ["ids": .array([ref(i)]), "parent": ref(parent)])
                var set = geo.merging(place) { $1 }
                set["parent"] = nil
                set["ids"] = .array([ref(i)])
                set["name"] = str(n.alt ?? layerName(n))
                _ = add("node.set", set)
                return
            }
            if n.tag == "img" {
                guard let img = n.image, let data = payload(img.file) else {
                    warn("image not imported: \(n.alt ?? layerName(n))")
                    return placeholder(n, geo: geo, place: place)
                }
                let mode = switch img.fit { case "cover": "fill"; case "contain": "fit"; default: "crop" }
                let i = add("image.place", geo.merging(["data": str(data), "mode": str(mode)]) { $1 })
                _ = add("node.set", place.merging(["ids": .array([ref(i)]), "name": str(n.alt ?? "Imagem")]) { $1 })
                return
            }
            // container
            var own = layoutProps(n)
            let reversed = own.layout != nil && n.style["flexDirection"]?.hasSuffix("-reverse") == true
            let kids = (reversed ? n.children.reversed() : n.children).map(HTMLImport.clipped)
            var spacers: [Double?] = kids.map { _ in nil }
            if let l = own.layout, l != "grid", n.style["flexWrap"]?.hasPrefix("wrap") != true {
                if let (sizes, gap) = HTMLImport.mainSpacers(n, kids, horizontal: l == "horizontal") {
                    if sizes.contains(where: { $0 != nil }) {
                        spacers = sizes
                        own.props["gap"] = num(gap); own.props["mainAlign"] = str("min")
                    }
                } else {
                    warn("flex children overlap, placed by position: \(layerName(n))")
                    own = (nil, [:])
                }
            }
            let props = box(n).merging(place) { $1 }.merging(own.props) { $1 }
            let me = add("node.create", geo.merging(["type": str("frame"), "name": str(layerName(n)), "props": .object(props)]) { $1 })
            if let img = n.image, let data = payload(img.file) {
                // a CSS background image: covers the frame, under the children
                let i = add("image.place", ["data": str(data), "parent": ref(me), "x": num(0), "y": num(0),
                                            "width": num(max(0, n.w)), "height": num(max(0, n.h)), "mode": str("fill")])
                if own.layout != nil { _ = add("node.set", ["ids": .array([ref(i)]), "absolute": .bool(true), "x": num(0), "y": num(0)]) }
            }
            let horizontal = own.layout == "horizontal"
            for (c, spacer) in zip(kids, spacers) {
                if let spacer {
                    _ = add("node.create", ["type": str("frame"), "name": str("spacer"), "parent": ref(me),
                                            "width": num(horizontal ? spacer : 0), "height": num(horizontal ? 0 : spacer),
                                            "props": .object(["fills": .array([]), "sizingH": str("fixed"), "sizingV": str("fixed")])])
                }
                map(c, parent: me, in: n, layout: own.layout, typo: typo)
            }
        }

        /// `HTMLImport.box`, warning when a border is drawn solid in place of its style.
        mutating func box(_ n: DOMNode) -> Props {
            let p = HTMLImport.box(n)
            if p["strokes"] != nil, let s = ["Top", "Right", "Bottom", "Left"].lazy
                .compactMap({ n.style["border\($0)Style"] }).first(where: { !["solid", "none"].contains($0) }) {
                warn("border style \(s) drawn solid: \(layerName(n))")
            }
            return p
        }

        mutating func placeholder(_ n: DOMNode, geo: Props, place: Props) {
            let props = place.merging(["fills": .array([str("#E5E5E5")])]) { $1 }
            _ = add("node.create", geo.merging(["type": str("rectangle"), "name": str(layerName(n)), "props": .object(props)]) { $1 })
        }

        mutating func textLeaf(_ n: DOMNode, _ text: String, typo: [String: String], geo: Props, place: Props) {
            let (family, style) = font(typo["fontFamily"], weight: typo["fontWeight"], italic: typo["fontStyle"] == "italic")
            var props: Props = [
                "fontFamily": str(family), "fontStyle": str(style), "fontSize": num(px(typo["fontSize"]) ?? 16),
                "lineHeight": str(px(typo["lineHeight"]).map { "\(fmt(clamp($0)))px" } ?? "auto"),
                "letterSpacing": num(px(typo["letterSpacing"]) ?? 0),
                "fills": .array([paint(typo["color"]) ?? str("#000000")]), "textAutoResize": str("height"),
            ]
            let align: String? = switch typo["textAlign"] {
            case "left", "start": "left"
            case "center": "center"
            case "right", "end": "right"
            case "justify": "justified"
            default: nil
            }
            if let align { props["textAlign"] = str(align) }
            if let d = decoration(n.style["textDecorationLine"]) { props["textDecoration"] = str(d) }
            let textCase: String? = switch typo["textTransform"] {
            case "uppercase": "upper"
            case "lowercase": "lower"
            case "capitalize": "title"
            default: nil
            }
            if let textCase { props["textCase"] = str(textCase) }
            var t = geo
            t["height"] = nil
            t["type"] = str("text")
            t["text"] = str(text)
            t["name"] = str(text.isEmpty ? layerName(n) : String(text.prefix(40)))
            // a button, badge or padded leaf: its box is a frame, the text sits inside at the padding (`#text` carries its parent's box)
            var textH = n.h
            var frame = n.tag == "#text" ? [:] : box(n)
            frame["clip"] = .bool(false)
            let padded = n.tag != "#text" && ["Top", "Right", "Bottom", "Left"].contains { (px(n.style["padding\($0)"]) ?? 0) > 0 }
            if (frame["fills"] ?? .array([])) != .array([]) || frame["strokes"] != nil || padded {
                let e = ["Top", "Right", "Bottom", "Left"].map {
                    (px(n.style["padding\($0)"]) ?? 0) + (px(n.style["border\($0)Width"]) ?? 0)
                }
                let f = add("node.create", geo.merging(["type": str("frame"), "name": str(layerName(n)),
                                                        "props": .object(frame.merging(place) { $1 })]) { $1 })
                t.merge(["parent": ref(f), "x": num(e[3]), "y": num(e[0]), "width": num(max(n.w - e[1] - e[3], 1))]) { $1 }
                textH = n.h - e[0] - e[2]
            } else {
                props.merge(place) { $1 }
                if let o = frame["opacity"] { props["opacity"] = o }
            }
            // one line: grows sideways, so a wider substitute font doesn't wrap it
            let fontSize = px(typo["fontSize"]) ?? 16
            if textH <= 1.5 * (px(typo["lineHeight"]) ?? fontSize * 1.2) {
                props["textAutoResize"] = str("widthAndHeight")
                t["width"] = nil
            }
            t["props"] = .object(props)
            let id = add("node.create", t)
            if let href = n.href { link(id, 0, text.utf16.count, href, text) }
            for r in n.runs ?? [] {
                var p: Props = [:]
                if let f = paint(r.color) { p["textFills"] = .array([f]) }
                if r.fontWeight != nil || r.fontStyle != nil {
                    p["fontStyle"] = str(font(typo["fontFamily"], weight: r.fontWeight ?? typo["fontWeight"],
                                              italic: (r.fontStyle ?? typo["fontStyle"]) == "italic").style)
                }
                if let d = r.decoration { p["textDecoration"] = str(decoration(d) ?? "none") }
                if !p.isEmpty {
                    _ = add("text.style", p.merging(range(text, r.start, r.end)) { $1 }.merging(["id": ref(id)]) { $1 })
                }
                if let href = r.href { link(id, r.start, r.end, href, text) }
            }
        }

        mutating func link(_ id: Int, _ start: Int, _ end: Int, _ href: String, _ text: String) {
            guard ExportSemantics.safeHref(href) != nil else {
                let u = Array(text.utf16), a = max(0, min(start, u.count)), b = max(a, min(end, u.count))
                return warn("link dropped: \(String(decoding: u[a..<b], as: UTF16.self).prefix(40))")
            }
            _ = add("text.style", range(text, start, end).merging(["id": ref(id),
                                   "hyperlink": str(href.trimmingCharacters(in: .whitespacesAndNewlines))]) { $1 })
        }

        /// UTF-16 offsets (the snapshot's) → Unicode scalar offsets (the engine's), clamped to the text.
        func range(_ text: String, _ start: Int, _ end: Int) -> Props {
            func scalars(_ u16: Int) -> Int {
                var units = 0, n = 0
                for s in text.unicodeScalars {
                    units += s.utf16.count
                    if units > u16 { break }
                    n += 1
                }
                return n
            }
            let a = scalars(start)
            return ["start": num(Double(a)), "end": num(Double(max(a, scalars(end))))]
        }

        /// The first CSS family if the engine has it (any case), else Inter; the style nearest the weight.
        mutating func font(_ css: String?, weight: String?, italic: Bool) -> (family: String, style: String) {
            let first = css?.split(separator: ",").first.map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            func lookup(_ f: String) -> (key: String, value: [String])? {
                fonts.families.first { $0.key.caseInsensitiveCompare(f) == .orderedSame }
            }
            var found = first.flatMap(lookup)
            if found == nil {
                if let first, !first.isEmpty { warn("font \(first) replaced by Inter") }
                found = lookup("Inter") ?? ("Inter", [])
            }
            let (family, styles) = found!
            let w = min(max(Int((min(max(finite(Double(weight ?? "")) ?? 400, 1), 1000) / 100).rounded()) * 100, 100), 900)
            let wanted = styleName(w, italic)
            let parsed = styles.compactMap { s in parseStyle(s).map { (name: s, weight: $0.weight, italic: $0.italic) } }
            if styles.contains(wanted) || parsed.isEmpty { return (family, wanted) }
            let pool = parsed.contains { $0.italic == italic } ? parsed.filter { $0.italic == italic } : parsed
            // nearest weight; a tie goes to the heavier
            let best = pool.min { a, b in
                let da = abs(a.weight - w), db = abs(b.weight - w)
                return da != db ? da < db : a.weight > b.weight
            }!
            return (family, best.name)
        }
    }

    static let weightNames = [100: "Thin", 200: "ExtraLight", 300: "Light", 400: "Regular", 500: "Medium", 600: "SemiBold",
                              700: "Bold", 800: "ExtraBold", 900: "Black"]
    static func styleName(_ w: Int, _ italic: Bool) -> String {
        let base = weightNames[w] ?? "Regular"
        return !italic ? base : w == 400 ? "Italic" : "\(base) Italic"
    }
    static func parseStyle(_ s: String) -> (weight: Int, italic: Bool)? {
        let italic = s.hasSuffix("Italic")
        let base = (italic ? String(s.dropLast(6)) : s).replacingOccurrences(of: " ", with: "").lowercased()
        if base.isEmpty { return (400, italic) }
        return weightNames.first { $0.value.lowercased() == base }.map { ($0.key, italic) }
    }

    // MARK: - CSS values

    static func layerName(_ n: DOMNode) -> String {
        if let id = n.id, !id.isEmpty { return "#\(id)" }
        if let c = n.cls, !c.isEmpty { return ".\(c)" }
        return n.tag
    }

    static func px(_ s: String?) -> Double? {
        guard let s = s?.trimmingCharacters(in: .whitespaces) else { return nil }
        return finite(Double(s.hasSuffix("px") ? String(s.dropLast(2)) : s))
    }

    static func finite(_ d: Double?) -> Double? { d.flatMap { $0.isFinite ? $0 : nil } }
    static func clamp(_ d: Double) -> Double { d.isFinite ? min(max(d, -1e6), 1e6) : 0 }

    static func fmt(_ d: Double) -> String { d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d) }

    static func decoration(_ s: String?) -> String? {
        guard let s else { return nil }
        return s.contains("underline") ? "underline" : s.contains("line-through") ? "strikethrough" : nil
    }

    /// `rgb(r, g, b)` / `rgba(r, g, b, a)` (also space/slash syntax) → `#RRGGBB` + alpha.
    static func color(_ css: String?) -> (hex: String, alpha: Double)? {
        guard let css = css?.trimmingCharacters(in: .whitespaces), css.hasPrefix("rgb"),
              let open = css.firstIndex(of: "("), let close = css.lastIndex(of: ")"), open < close else { return nil }
        let parts = css[css.index(after: open)..<close].split { ", /".contains($0) }.map(String.init)
        guard parts.count >= 3 else { return nil }
        func channel(_ s: String) -> Int? {
            let v = s.hasSuffix("%") ? finite(Double(s.dropLast())).map { $0 * 2.55 } : finite(Double(s))
            return v.map { Int(min(max($0, 0), 255).rounded()) }
        }
        guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
        var a = 1.0
        if parts.count > 3 {
            a = (parts[3].hasSuffix("%") ? finite(Double(parts[3].dropLast())).map { $0 / 100 } : finite(Double(parts[3]))) ?? 1
        }
        return (String(format: "#%02X%02X%02X", r, g, b), min(max(a, 0), 1))
    }

    /// A solid paint; nil when missing or fully transparent.
    static func paint(_ css: String?) -> JSONValue? {
        guard let c = color(css), c.alpha > 0 else { return nil }
        return c.alpha >= 1 ? str(c.hex) : .object(["type": str("solid"), "color": str(c.hex), "opacity": num(c.alpha)])
    }

    /// `#RRGGBBAA` (effects and gradient stops carry their own alpha).
    static func hex8(_ css: String) -> String? {
        guard let c = color(css) else { return nil }
        return c.alpha >= 1 ? c.hex : c.hex + String(format: "%02X", Int((c.alpha * 255).rounded()))
    }

    /// Splits on commas outside parentheses.
    static func splitTop(_ s: String) -> [String] {
        var out: [String] = [], cur = "", depth = 0
        for ch in s {
            if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
            if ch == ",", depth == 0 { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" } else { cur.append(ch) }
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out.filter { !$0.isEmpty }
    }

    /// A leading `rgb…(…)` and what follows it.
    static func leadingColor(_ s: String) -> (color: String, rest: String)? {
        guard s.hasPrefix("rgb"), let close = s.firstIndex(of: ")") else { return nil }
        return (String(s[...close]), String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces))
    }

    /// `linear-gradient(…)` / `radial-gradient(…)` on a `w`×`h` box → a gradient paint (stops in order; linear angle →
    /// from/to; radial size and centre → from (centre), to (end of x radius), width (end of y radius)). A transparent
    /// stop takes its neighbours' colour at alpha 0 (CSS mixes premultiplied).
    static func gradient(_ css: String, w: Double = 1, h: Double = 1) -> JSONValue? {
        let kind: String
        if css.hasPrefix("linear-gradient(") { kind = "linearGradient" }
        else if css.hasPrefix("radial-gradient(") { kind = "radialGradient" }
        else { return nil }
        guard let open = css.firstIndex(of: "("), let close = css.lastIndex(of: ")") else { return nil }
        var args = splitTop(String(css[css.index(after: open)..<close]))
        var deg = 180.0, shape = ""
        if let first = args.first, leadingColor(first) == nil {
            args.removeFirst()
            if kind == "linearGradient" { deg = angle(first) ?? 180 } else { shape = first }
        }
        var stops: [(hex: String, alpha: Double, at: Double?)] = []
        for a in args {
            guard let (c, rest) = leadingColor(a), let rgb = color(c) else { continue }
            let at = rest.split(separator: " ").first.flatMap { $0.hasSuffix("%") ? Double($0.dropLast()) : nil }
            stops.append((rgb.hex, rgb.alpha, finite(at).map { min(max($0 / 100, 0), 1) }))
        }
        guard stops.count >= 2 else { return nil }
        var paintStops: [JSONValue] = []
        func stop(_ hex: String, _ alpha: Double, _ at: Double) {
            let c = alpha >= 1 ? hex : hex + String(format: "%02X", Int((alpha * 255).rounded()))
            paintStops.append(.object(["color": str(c), "position": num(at)]))
        }
        for (i, s) in stops.enumerated() {
            let at = s.at ?? Double(i) / Double(stops.count - 1)
            guard s.alpha == 0 else { stop(s.hex, s.alpha, at); continue }
            let before = stops[..<i].last { $0.alpha > 0 }?.hex, after = stops[(i + 1)...].first { $0.alpha > 0 }?.hex
            let sides = [before, after].compactMap { $0 }
            for hex in sides.isEmpty ? [s.hex] : sides.count == 2 && sides[0] == sides[1] ? [sides[0]] : sides { stop(hex, 0, at) }
        }
        var p: Props = ["type": str(kind), "stops": .array(paintStops)]
        let q = { (v: Double) in num((v * 10000).rounded() / 10000) }
        if kind == "linearGradient" {
            // ponytail: unit-square direction; ignores the box's aspect ratio (CSS angles are corner-aware)
            let r = deg * .pi / 180, dx = sin(r) / 2, dy = -cos(r) / 2
            p["from"] = .array([q(0.5 - dx), q(0.5 - dy)])
            p["to"] = .array([q(0.5 + dx), q(0.5 + dy)])
        } else {
            let w = max(w, 1), h = max(h, 1), g = radial(shape, w, h)
            p["from"] = .array([q(g.cx / w), q(g.cy / h)])
            p["to"] = .array([q((g.cx + g.rx) / w), q(g.cy / h)])
            p["width"] = .array([q(g.cx / w), q((g.cy + g.ry) / h)])
        }
        return .object(p)
    }

    /// A radial gradient's `[circle|ellipse] [<size>] [at <x> <y>]` on a `w`×`h` box: centre and radii in px.
    static func radial(_ shape: String, _ w: Double, _ h: Double) -> (cx: Double, cy: Double, rx: Double, ry: Double) {
        let parts = (" " + shape).components(separatedBy: " at ")
        let size = parts[0].split(separator: " ").map(String.init).filter { $0 != "circle" && $0 != "ellipse" }
        let circle = shape.hasPrefix("circle")
        func length(_ s: String, _ ref: Double) -> Double? {
            let keywords = ["left": 0.0, "top": 0, "center": 50, "right": 100, "bottom": 100]
            if let k = keywords[s] { return k * ref / 100 }
            return s.hasSuffix("%") ? finite(Double(s.dropLast())).map { $0 * ref / 100 } : px(s)
        }
        var pos = parts.count > 1 ? parts[1].split(separator: " ").map(String.init) : []
        if let f = pos.first, f == "top" || f == "bottom" { pos.reverse() }   // y-first keywords
        let cx = clamp(pos.first.flatMap { length($0, w) } ?? w / 2), cy = clamp(pos.dropFirst().first.flatMap { length($0, h) } ?? h / 2)
        let dx = [abs(cx), abs(w - cx)], dy = [abs(cy), abs(h - cy)]
        if size.count >= 2, let rx = length(size[0], w), let ry = length(size[1], h) { return (cx, cy, clamp(rx), clamp(ry)) }
        if size.count == 1, let r = px(size[0]) { return (cx, cy, clamp(r), clamp(r)) }
        let keyword = size.first ?? "farthest-corner"
        let side = keyword.hasPrefix("closest") ? (dx.min()!, dy.min()!) : (dx.max()!, dy.max()!)
        if keyword.hasSuffix("side") {
            let r = keyword.hasPrefix("closest") ? min(side.0, side.1) : max(side.0, side.1)
            return circle ? (cx, cy, r, r) : (cx, cy, side.0, side.1)
        }
        // a corner: a circle through it, or an ellipse of the side's aspect through it
        if circle { let r = hypot(side.0, side.1); return (cx, cy, r, r) }
        return (cx, cy, side.0 * 2.0.squareRoot(), side.1 * 2.0.squareRoot())
    }

    static func angle(_ s: String) -> Double? {
        let sides: [String: Double] = ["to top": 0, "to top right": 45, "to right top": 45, "to right": 90, "to bottom right": 135,
                                       "to right bottom": 135, "to bottom": 180, "to bottom left": 225, "to left bottom": 225,
                                       "to left": 270, "to top left": 315, "to left top": 315]
        if let a = sides[s] { return a }
        if s.hasSuffix("deg") { return Double(s.dropLast(3)) }
        if s.hasSuffix("turn") { return Double(s.dropLast(4)).map { $0 * 360 } }
        if s.hasSuffix("rad") { return Double(s.dropLast(3)).map { $0 * 180 / .pi } }
        return nil
    }

    /// Fills, strokes, radius, shadows, opacity and clip of a box.
    static func box(_ n: DOMNode) -> [String: JSONValue] {
        let st = n.style
        var p: Props = [:]
        // CSS paints the first background layer on top; the engine the last
        let layers = splitTop(st["backgroundImage"] ?? "").compactMap { gradient($0, w: n.w, h: n.h) }
        p["fills"] = .array((paint(st["backgroundColor"]).map { [$0] } ?? []) + layers.reversed())

        let sides = ["Top", "Right", "Bottom", "Left"]
        let widths = sides.map { px(st["border\($0)Width"]) ?? 0 }
        let colors = sides.map { st["border\($0)Color"] ?? "rgb(0, 0, 0)" }
        if let k = widths.firstIndex(where: { $0 > 0 }), let stroke = paint(colors[k]) {
            p["strokes"] = .array([stroke])
            p["strokeAlign"] = str("inside")
            if Set(widths).count == 1, Set(colors).count == 1 { p["strokeWeight"] = num(widths[0]) }
            else { for (s, w) in zip(sides, widths) { p["stroke\(s)Weight"] = num(w) } }
        }

        let minSide = min(n.w, n.h)
        let radii = ["TopLeft", "TopRight", "BottomRight", "BottomLeft"].map { c -> Double in
            guard let v = st["border\(c)Radius"]?.split(separator: " ").first.map(String.init) else { return 0 }
            return clamp(v.hasSuffix("%") ? (finite(Double(v.dropLast())) ?? 0) * minSide / 100 : px(v) ?? 0)
        }
        if Set(radii).count == 1 { if radii[0] > 0 { p["cornerRadius"] = num(radii[0]) } }
        else { p["cornerRadius"] = .array(radii.map(num)) }

        if let sh = st["boxShadow"], sh != "none" {
            let effects: [JSONValue] = splitTop(sh).compactMap { one in
                var s = one, inset = false
                if s.hasPrefix("inset ") { inset = true; s.removeFirst(6) }
                if s.hasSuffix(" inset") { inset = true; s.removeLast(6) }
                var c = "rgb(0, 0, 0)"
                if let r = s.range(of: #"rgba?\([^)]*\)"#, options: .regularExpression) { c = String(s[r]); s.removeSubrange(r) }
                let len = s.split(separator: " ").compactMap { px(String($0)) }
                guard len.count >= 2, let hex = hex8(c) else { return nil }
                return .object(["type": str(inset ? "innerShadow" : "dropShadow"), "offset": .array([num(len[0]), num(len[1])]),
                                "radius": num(len.count > 2 ? len[2] : 0), "spread": num(len.count > 3 ? len[3] : 0),
                                "color": str(hex)])
            }
            if !effects.isEmpty { p["effects"] = .array(effects) }
        }
        if let o = finite(st["opacity"].flatMap(Double.init)), o < 1 { p["opacity"] = num(max(o, 0)) }
        // hidden, clip, auto, scroll on either axis
        p["clip"] = .bool((st["overflow"] ?? "").split(separator: " ").contains { $0 != "visible" })
        return p
    }

    /// `clip-path: inset(t r b l [round …])` (px or %): the box shrunk to that rect, clipping, with no clip-path
    /// left; anything else is returned as it is.
    static func clipped(_ n: DOMNode) -> DOMNode {
        guard let cp = n.style["clipPath"], cp.hasPrefix("inset("), let close = cp.lastIndex(of: ")") else { return n }
        let body = cp[cp.index(cp.startIndex, offsetBy: 6)..<close].components(separatedBy: " round ")[0]
        let v = body.split(separator: " ").map(String.init)
        guard (1...4).contains(v.count) else { return n }
        let sides = [v[0], v.count > 1 ? v[1] : v[0], v.count > 2 ? v[2] : v[0], v.count > 3 ? v[3] : v.count > 1 ? v[1] : v[0]]
        let refs = [n.h, n.w, n.h, n.w]
        let d = zip(sides, refs).map { s, ref in
            clamp(s.hasSuffix("%") ? (finite(Double(s.dropLast())) ?? 0) * ref / 100 : px(s) ?? 0)
        }
        var out = n
        out.x += d[3]; out.y += d[0]
        out.w = max(0, n.w - d[1] - d[3]); out.h = max(0, n.h - d[0] - d[2])
        out.style["clipPath"] = nil
        out.style["overflow"] = "hidden"
        return out
    }

    /// Spacers that keep a non-wrapping flex row's (column's) measured offsets under auto layout (main align min):
    /// for each kid, the spacer before it (nil: none), and the gap to use. A spacer is a slot of its own (one more
    /// gap), so a deviation smaller than the gap (or a negative one) turns the gap off and spacers carry every
    /// distance. nil: kids overlap, not expressible.
    static func mainSpacers(_ n: DOMNode, _ kids: [DOMNode], horizontal: Bool) -> (spacers: [Double?], gap: Double)? {
        let pad = px(n.style[horizontal ? "paddingLeft" : "paddingTop"]) ?? 0
        let gap = px(n.style[horizontal ? "columnGap" : "rowGap"]) ?? 0
        let flow = kids.indices.filter { !["absolute", "fixed"].contains(kids[$0].style["position"]) }
        func start(_ c: DOMNode) -> Double { horizontal ? c.x - n.x : c.y - n.y }
        func size(_ c: DOMNode) -> Double { horizontal ? c.w : c.h }
        func deltas(_ g: Double) -> [Double] {
            var cursor = pad
            return flow.map { i in
                defer { cursor = start(kids[i]) + size(kids[i]) + g }
                return start(kids[i]) - cursor
            }
        }
        let d = deltas(gap)
        var out: [Double?] = kids.map { _ in nil }
        guard d.contains(where: { abs($0) > 1 }) else { return (out, gap) }
        let g = d.allSatisfy { abs($0) <= 1 || $0 >= gap } ? gap : 0
        let dg = g == gap ? d : deltas(0)
        guard !dg.contains(where: { $0 < -1 }) else { return nil }
        for (i, delta) in zip(flow, dg) where delta > 1 { out[i] = clamp(delta - g) }
        return (out, g)
    }

    /// Auto layout from `display: flex|grid`; `layout` is nil for a plain container.
    static func layoutProps(_ n: DOMNode) -> (layout: String?, props: [String: JSONValue]) {
        let st = n.style
        let padding = JSONValue.array(["Top", "Right", "Bottom", "Left"].map { num(px(st["padding\($0)"]) ?? 0) })
        let rowGap = num(px(st["rowGap"]) ?? 0), columnGap = num(px(st["columnGap"]) ?? 0)
        switch st["display"] {
        case "flex", "inline-flex":
            let horizontal = (st["flexDirection"] ?? "row").hasPrefix("row")
            let layout = horizontal ? "horizontal" : "vertical"
            var p: Props = ["layout": str(layout), "padding": padding,
                            "gap": horizontal ? columnGap : rowGap, "crossGap": horizontal ? rowGap : columnGap]
            if st["flexWrap"] == "wrap" { p["wrap"] = .bool(true) }
            let main: String? = switch st["justifyContent"] ?? "normal" {
            case "flex-start", "start", "normal", "left": "min"
            case "center": "center"
            case "flex-end", "end", "right": "max"
            case "space-between": "spaceBetween"
            case "space-around": "spaceAround"
            case "space-evenly": "spaceEvenly"
            default: nil
            }
            let cross: String? = switch st["alignItems"] ?? "normal" {
            case "stretch", "normal", "flex-start", "start": "min"
            case "center": "center"
            case "flex-end", "end": "max"
            case "baseline": "baseline"
            default: nil
            }
            if let main { p["mainAlign"] = str(main) }
            if let cross { p["crossAlign"] = str(cross) }
            return (layout, p)
        case "grid", "inline-grid":
            let tracks = (st["gridTemplateColumns"] ?? "").split(separator: " ").compactMap { t in
                t.hasSuffix("px") ? px(String(t)) : nil
            }
            var p: Props = ["layout": str("grid"), "padding": padding, "gap": columnGap, "crossGap": rowGap]
            if !tracks.isEmpty {
                p["gridColumns"] = num(Double(tracks.count))
                p["columnTracks"] = .array(tracks.map(num))
            }
            return ("grid", p)
        default:
            return (nil, [:])
        }
    }
}
