import Foundation
import CollieProtocol

struct CSSRule: Equatable, Sendable { var selector: String; var decls: [Attr] }

/// Rewrites figcraft's stylesheet for a standalone, responsive document.
enum ExportStyles {
    static let reset = """
        *, *::before, *::after { box-sizing: border-box; }
        html { -webkit-text-size-adjust: 100%; }
        body { margin: 0; }
        h1, h2, h3, h4, h5, h6, p, ul, ol, li, figure { margin: 0; padding: 0; }
        ul, ol { list-style-position: inside; }
        ul.collie-list { list-style: none; }
        a { color: inherit; }
        img, svg { display: block; max-width: 100%; height: auto; }

        """

    static func fallback(_ family: String) -> String {
        family.lowercased().contains("mono") ? "ui-monospace, SFMono-Regular, Menlo, monospace"
            : "system-ui, -apple-system, \"Segoe UI\", Roboto, \"Helvetica Neue\", Arial, sans-serif"
    }

    /// Parses figcraft's regular `selector {\n  prop: value;\n}\n` output. Only `:root` and `.class` rules and plain
    /// property names are kept (anything else: injected through a value, e.g. a font family): dropped, with a warning.
    static func parse(_ css: String) -> (root: [Attr], rules: [CSSRule], warnings: [String]) {
        var root: [Attr] = [], rules: [CSSRule] = [], warnings: [String] = []
        var cur: CSSRule?
        for line in css.split(separator: "\n") {
            if line.hasSuffix(" {") {
                let sel = String(line.dropLast(2))
                cur = sel == ":root" || sel.wholeMatch(of: /\.[a-z0-9-]+/) != nil ? CSSRule(selector: sel, decls: []) : nil
                if cur == nil { warnings.append("unsafe css rule dropped") }
            } else if line == "}", let r = cur {
                if r.selector == ":root" { root += r.decls } else { rules.append(r) }
                cur = nil
            } else if let c = line.range(of: ": "), line.hasSuffix(";"), cur != nil {
                let name = line[..<c.lowerBound].trimmingCharacters(in: .whitespaces)
                // custom properties as figcraft names them (`css_var_of`: letters, digits, `_`, `-`)
                let ok = name.hasPrefix("--") ? name.count > 2 && name.dropFirst(2).allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
                    : name.wholeMatch(of: /-?[a-z0-9-]+/) != nil
                if ok { cur?.decls.append(Attr(name: name, value: String(line[c.upperBound...].dropLast()))) }
                else { warnings.append("unsafe css dropped: \(cur?.selector ?? "") property") }
            }
        }
        return (root, rules, warnings)
    }

    /// `v` as it may stand in a `<style>`: `<` escaped; nil when it could end its declaration or rule, hide text in a
    /// comment, or fetch anything (only figcraft's `url(image.png)` / `url(pattern.png)` placeholders pass).
    static func safeValue(_ v: String) -> String? {
        guard !v.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || "{};\\@".unicodeScalars.contains($0) }),
              !v.contains("/*"), !v.contains("*/") else { return nil }
        let l = v.lowercased().replacingOccurrences(of: "url(image.png)", with: "").replacingOccurrences(of: "url(pattern.png)", with: "")
        guard !l.contains("url("), !l.contains("image-set("), !l.contains("src(") else { return nil }
        return v.replacingOccurrences(of: "<", with: "\\3c ")
    }

    /// `decls` with every value made safe (`safeValue`); those that can't be: dropped, with a warning.
    static func clean(_ r: inout CSSRule, _ warnings: inout [String]) {
        r.decls = r.decls.compactMap { a in
            guard let v = safeValue(a.value) else { warnings.append("unsafe css dropped: \(r.selector) \(a.name)"); return nil }
            return Attr(name: a.name, value: v)
        }
    }

    static func serialize(_ r: CSSRule) -> String {
        "\(r.selector) {\n" + r.decls.map { "  \($0.name): \($0.value);\n" }.joined() + "}\n"
    }

    /// Port of figcraft's `css_var_name`, or `css_var_of` when the variable has a Web code syntax.
    static func cssVarName(_ name: String, web: String? = nil) -> String {
        if let w = web?.trimmingCharacters(in: .whitespaces) {
            var inner = Substring(w)
            if inner.hasPrefix("var(") {
                inner = Substring(inner.dropFirst(4).prefix { $0 != "," && $0 != ")" }.trimmingCharacters(in: .whitespaces))
            }
            let ok = inner.utf8.count > 2 && inner.hasPrefix("--")
                && inner.unicodeScalars.allSatisfy { alnum($0) || $0 == "-" || $0 == "_" }
            if ok { return String(String.UnicodeScalarView(inner.unicodeScalars.prefix(80))) }
            return cssVarName(String(inner))
        }
        var out = "--"
        for c in name.unicodeScalars.flatMap({ $0.properties.lowercaseMapping.unicodeScalars }).prefix(80) {
            if alnum(c) || c == "_" { out.unicodeScalars.append(c) } else if !out.hasSuffix("-") { out.append("-") }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.utf8.count <= 2 ? "--variable" : out
    }

    /// Rust's `char::is_alphanumeric`.
    private static func alnum(_ c: Unicode.Scalar) -> Bool {
        c.properties.isAlphabetic || [.decimalNumber, .letterNumber, .otherNumber].contains(c.properties.generalCategory)
    }

    static func number(_ n: Double) -> String {
        n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
    }

    // MARK: themes

    /// `[data-theme]` rules (and the dark media query) for the `:root` variables with ≥ 2 modes.
    static func themes(root: [Attr], variables: [JSONValue]) -> String {
        let px = Dictionary(root.map { ($0.name, $0.value.hasSuffix("px")) }, uniquingKeysWith: { a, _ in a })
        var order: [String] = []
        var themes: [String: [String: String]] = [:] // slug -> css name -> value
        for list in variables {
            guard case .object(let o) = list, case .array(let cs)? = o["collections"], case .array(let vs)? = o["variables"] else { continue }
            var modes: [String: [(id: String, name: String)]] = [:]
            for case .object(let c) in cs {
                guard let id = c["id"]?.str, case .array(let ms)? = c["modes"] else { continue }
                modes[id] = ms.compactMap { m in
                    guard case .object(let m) = m, let i = m["id"]?.str, let n = m["name"]?.str else { return nil }
                    return (i, n)
                }
            }
            var byId: [String: [String: JSONValue]] = [:]
            for case .object(let v) in vs { if let id = v["id"]?.str { byId[id] = v } }
            for case .object(let v) in vs {
                var web: String?
                if case .object(let cs)? = v["codeSyntax"] { web = cs["WEB"]?.str }
                let css = cssVarName(v["name"]?.str ?? "", web: web)
                guard let isPx = px[css], let col = v["collection"]?.str, let ms = modes[col], ms.count >= 2 else { continue }
                for m in ms {
                    guard let value = resolve(v, mode: m.name, byId: byId, modes: modes, px: isPx) else { continue }
                    let slug = String(m.name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
                    if themes[slug] == nil { order.append(slug) }
                    themes[slug, default: [:]][css] = value // later lists win
                }
            }
        }
        func decls(_ slug: String, _ pad: String) -> String {
            root.compactMap { a in themes[slug]?[a.name].flatMap(safeValue).map { "\(pad)\(a.name): \($0);\n" } }.joined()
        }
        var out = order.map { "[data-theme=\"\($0)\"] {\n" + decls($0, "  ") + "}\n" }.joined()
        if themes["dark"] != nil {
            out += "@media (prefers-color-scheme: dark) {\n  :root:not([data-theme]) {\n" + decls("dark", "    ") + "  }\n}\n"
        }
        return out
    }

    static func resolve(_ v: [String: JSONValue], mode: String, byId: [String: [String: JSONValue]],
                                modes: [String: [(id: String, name: String)]], px: Bool) -> String? {
        var v = v
        for _ in 0...8 {
            guard case .object(let values)? = v["values"], let ms = v["collection"]?.str.flatMap({ modes[$0] }) else { return nil }
            let id = ms.first { $0.name == mode && values[$0.id] != nil }?.id ?? ms.first?.id
            guard let id, case .object(let val)? = values[id] else { return nil }
            switch (val["type"]?.str, val["value"]) {
            case ("color", .object(let c)?):
                func ch(_ k: String) -> Int { min(255, max(0, Int(((c[k]?.num ?? 0) * 255).rounded()))) }
                let a = c["a"]?.num ?? 1
                return "#" + (["r", "g", "b"].map(ch) + (a < 1 ? [ch("a")] : [])).map { String(format: "%02X", $0) }.joined()
            case ("number", .number(let n)?), ("float", .number(let n)?):
                return number(n) + (px ? "px" : "")
            case ("alias", _):
                guard let t = (val["value"] ?? val["id"])?.str, let next = byId[t] else { return nil }
                v = next
            default:
                return nil // ponytail: string/boolean variables aren't themed
            }
        }
        return nil
    }

    // MARK: layout

    /// Grid, responsive sizing and font fallbacks on `rules`; returns the `@media (max-width: 640px)` rules.
    static func adapt(_ rules: inout [CSSRule], tree: MarkupNode) -> [CSSRule] {
        var nodes: [String: MarkupNode] = [:]
        func walk(_ n: MarkupNode) { if !n.cls.isEmpty { nodes[n.cls] = n }; n.children.forEach(walk) }
        walk(tree)
        let textTags: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol"]
        var media: [CSSRule] = []
        for i in rules.indices {
            let sel = rules[i].selector
            let node = sel.hasPrefix(".") ? nodes[String(sel.dropFirst())] : nil
            var d = rules[i].decls
            func has(_ n: String, _ v: String) -> Bool { d.contains { $0.name == n && $0.value == v } }
            var isGrid = false
            if let l = node?.layer, l.layoutMode == "grid" {
                isGrid = true
                d.removeAll { ["flex-direction", "flex-wrap", "align-content"].contains($0.name) }
                d = d.flatMap { a -> [Attr] in
                    if a.name == "display", a.value == "flex" { return [Attr(name: "display", value: "grid")] }
                    if a.name == "gap" { return [Attr(name: "column-gap", value: a.value),
                                                 Attr(name: "row-gap", value: l.crossGap.map { number($0) + "px" } ?? a.value)] }
                    return [a]
                }
                let cols = (0..<max(l.gridColumns ?? l.columnTracks.count, 1)).map { k -> String in
                    guard k < l.columnTracks.count else { return "1fr" }
                    let t = l.columnTracks[k]
                    switch t.sizing { case "fixed": return number(t.value) + "px"; case "fill": return number(t.value) + "fr"; default: return "auto" }
                }
                d.append(Attr(name: "grid-template-columns", value: cols.joined(separator: " ")))
            }
            if sel == ".\(tree.cls)" {
                d = d.flatMap { a -> [Attr] in
                    if a.name == "width", a.value.hasSuffix("px") {
                        return [Attr(name: "width", value: "100%"), Attr(name: "max-width", value: a.value), Attr(name: "margin", value: "0 auto")]
                    }
                    if a.name == "height", a.value.hasSuffix("px") { return [Attr(name: "min-height", value: a.value)] }
                    return [a]
                }
            }
            let stretch = has("align-self", "stretch"), grow = has("flex", "1 1 0")
            if stretch || grow { d.removeAll { $0.name == "width" } }
            if grow { d.append(Attr(name: "min-width", value: "0")) }
            if !stretch, let n = node, textTags.contains(n.tag) {
                for k in d.indices where d[k].name == "width" { d[k].name = "max-width" }
            }
            for k in d.indices where d[k].name == "font-family" && d[k].value.hasPrefix("\"") && !d[k].value.contains(",") {
                d[k].value += ", " + fallback(d[k].value)
            }
            if isGrid { media.append(CSSRule(selector: sel, decls: [Attr(name: "grid-template-columns", value: "1fr")])) }
            else if has("flex-direction", "row") { media.append(CSSRule(selector: sel, decls: [Attr(name: "flex-wrap", value: "wrap")])) }
            rules[i].decls = d
        }
        return media
    }
}
