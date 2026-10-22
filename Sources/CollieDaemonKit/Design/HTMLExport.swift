import Foundation
import CollieProtocol

struct ExportAsset: Sendable, Equatable { var id: String; var name: String; var kind: String /* icon|image */; var data: Data }

struct ExportInput: Sendable {
    var title: String
    var code: [String] /* one per root */
    var layers: [JSONValue] /* get_node per root */
    var variables: [JSONValue] /* the screen's variable.list, then the active design system's */
    var assets: [ExportAsset]
}

struct ExportBundle: Sendable { var html: String; var files: [(path: String, data: Data)]; var warnings: [String] }

/// Turns figcraft's `inspect.code` output into one standalone HTML document.
enum HTMLExport {
    static func build(_ input: ExportInput) -> ExportBundle {
        var warnings: [String] = [], files: [(path: String, data: Data)] = []
        var root: [Attr] = [], rules: [CSSRule] = [], media: [CSSRule] = [], markup = ""
        for (k, code) in input.code.enumerated() {
            let (m, css) = ExportMarkup.split(code)
            guard var tree = (try? ExportMarkup.parse(m))?.first else {
                warnings.append("unreadable export markup: root \(k + 1)"); continue
            }
            var (vars, rs, dropped) = ExportStyles.parse(css)
            warnings += dropped
            let layer = k < input.layers.count ? ExportMarkup.layer(input.layers[k]) : nil
            if layer.map({ !ExportMarkup.attach(&tree, $0) }) ?? true {
                warnings.append("layer map mismatch: \(layer?.name ?? tree.cls)")
            }
            let assets = Dictionary(input.assets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            place(&tree, assets, &rs, &files, &warnings)
            ExportSemantics.apply(&tree, warnings: &warnings)
            var ms = ExportStyles.adapt(&rs, tree: tree)
            if k > 0 {
                let p = "r\(k + 1)-"
                prefix(&tree, p)
                for i in rs.indices where rs[i].selector.hasPrefix(".") { rs[i].selector = "." + p + rs[i].selector.dropFirst() }
                for i in ms.indices { ms[i].selector = "." + p + ms[i].selector.dropFirst() }
            }
            for v in vars where !root.contains(where: { $0.name == v.name }) { root.append(v) }
            rules += rs; media += ms
            markup += ExportSemantics.html(tree, depth: 0) + "\n"
        }
        // every value checked as it reaches the `<style>` (a font family is the agent's text)
        var rootRule = CSSRule(selector: ":root", decls: root)
        ExportStyles.clean(&rootRule, &warnings)
        for i in rules.indices { ExportStyles.clean(&rules[i], &warnings) }
        for i in media.indices { ExportStyles.clean(&media[i], &warnings) }
        root = rootRule.decls
        var style = ExportStyles.reset
        if !root.isEmpty { style += ExportStyles.serialize(CSSRule(selector: ":root", decls: root)) }
        style += ExportStyles.themes(root: root, variables: input.variables)
        style += rules.map(ExportStyles.serialize).joined()
        if !media.isEmpty {
            style += "@media (max-width: 640px) {\n" + media.map { r in
                "  \(r.selector) { " + r.decls.map { "\($0.name): \($0.value);" }.joined(separator: " ") + " }\n"
            }.joined() + "}\n"
        }
        let html = """
            <!doctype html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="generator" content="Collie">
            <title>\(escape(input.title))</title>
            <style>
            \(style)</style>
            </head>
            <body>
            \(markup)</body>
            </html>

            """
        return ExportBundle(html: html, files: files, warnings: warnings)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Scripts, handlers, entities (which can hide either), network or `data:` references: not safe to inline.
    static func unsafeSVG(_ svg: String) -> Bool {
        let l = svg.lowercased()
        if l.contains("&") || l.range(of: #"[\s/"']on[a-z]+\s*="#, options: .regularExpression) != nil { return true }
        let ns = #"xmlns(:[a-z]+)?\s*=\s*["']http://www\.w3\.org/(2000/svg|1999/xlink)["']"#
        let rest = l.replacingOccurrences(of: ns, with: "", options: .regularExpression)
        // ponytail: URL parsers drop whitespace/control chars, so `java\tscript:` is matched squashed.
        let squashed = String(String.UnicodeScalarView(rest.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }))
        return ["<script", "foreignobject", "javascript:", "@import", "http:", "https:", "//", "data:"].contains(where: squashed.contains)
    }

    private static func prefix(_ n: inout MarkupNode, _ p: String) {
        if !n.cls.isEmpty, n.cls != "collie-list" { n.cls = p + n.cls }
        for i in n.children.indices { prefix(&n.children[i], p) }
    }

    /// Inlines icons and turns images into `<img>`, matching assets to nodes by layer id.
    private static func place(_ n: inout MarkupNode, _ assets: [String: ExportAsset], _ rules: inout [CSSRule],
                              _ files: inout [(path: String, data: Data)], _ warnings: inout [String]) {
        for i in n.children.indices { place(&n.children[i], assets, &rules, &files, &warnings) }
        guard let id = n.layer?.id, let a = assets[id] else { return }
        let ri = rules.firstIndex { $0.selector == ".\(n.cls)" }
        var name = a.name
        for ext in [".svg", ".png"] where name.lowercased().hasSuffix(ext) { name.removeLast(ext.count) }
        var used: [String] = []
        let safeId = String(a.id.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "-" })
        let file = "assets/\(ExportMarkup.className(name, used: &used))-\(safeId)"
        func save(_ path: String) { if !files.contains(where: { $0.path == path }) { files.append((path, a.data)) } }
        func img(_ path: String) {
            n.tag = "img"; n.text = nil; n.children = []
            n.attrs = [Attr(name: "src", value: path), Attr(name: "alt", value: escape(name))]
        }
        if a.kind == "icon" {
            if let ri { rules[ri].decls.removeAll { $0.name == "background" } }
            var svg = String(decoding: a.data, as: UTF8.self)
            if svg.hasPrefix("<?xml"), let e = svg.range(of: "?>") { svg = String(svg[e.upperBound...]) }
            svg = svg.trimmingCharacters(in: .whitespacesAndNewlines)
            if unsafeSVG(svg) {
                save(file + ".svg"); img(file + ".svg")
                warnings.append("unsafe svg exported as file: \(name)")
            } else {
                n.children = []; n.text = svg
            }
        } else if a.kind == "image" {
            let bg = ri.flatMap { r in rules[r].decls.firstIndex { $0.name == "background" && $0.value.contains("url(image.png)") } }
            if n.children.isEmpty {
                save(file + ".png"); img(file + ".png")
                if let ri, let bg { rules[ri].decls[bg] = Attr(name: "object-fit", value: "cover") }
            } else {
                if let ri, let bg { rules[ri].decls.remove(at: bg) }
                warnings.append("background image not exported: \(name)")
            }
        }
    }
}
