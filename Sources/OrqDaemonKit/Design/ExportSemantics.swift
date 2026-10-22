import Foundation

/// Rewrites figcraft's div/p tree into semantic HTML and serializes it.
enum ExportSemantics {
    private static let containers: Set<String> = ["header", "footer", "nav", "main", "section", "article", "aside"]
    private static let textTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6", "p"]
    private static let markers: [Character] = ["•", "·", "◦", "-", "–", "*"]

    static func apply(_ root: inout MarkupNode, warnings: inout [String]) {
        var sizes: [String: Int] = [:] // fontSize key -> characters
        func collect(_ n: MarkupNode) {
            if let l = n.layer, l.type == "TEXT", let s = l.fontSize { sizes["\(s)", default: 0] += l.characters?.count ?? 0 }
            n.children.forEach(collect)
        }
        collect(root)
        // ponytail: ties resolve to the smallest size; sizes is keyed by description so parse back.
        let body = sizes.max { a, b in a.value != b.value ? a.value < b.value : (Double(a.key) ?? 0) > (Double(b.key) ?? 0) }
            .flatMap { Double($0.key) }
        var headings: [Double] = []
        if let body {
            var seen = Set<Double>()
            func cands(_ n: MarkupNode) {
                if let l = n.layer, l.type == "TEXT", let s = l.fontSize, s >= body * 1.25, (l.characters?.count ?? 0) <= 200 { seen.insert(s) }
                n.children.forEach(cands)
            }
            cands(root)
            headings = seen.sorted(by: >)
        }
        rewrite(&root, isRoot: true, parentIsRoot: false, headings: headings)
        link(&root, warnings: &warnings)
    }

    private static func firstWord(_ name: String) -> String {
        name.lowercased().split(whereSeparator: { " /-:_".contains($0) }).first.map(String.init) ?? ""
    }

    private static func rewrite(_ n: inout MarkupNode, isRoot: Bool, parentIsRoot: Bool, headings: [Double]) {
        if n.tag == "img" || n.text?.hasPrefix("<svg") == true { return } // placed assets keep their element
        let word = n.layer.map { firstWord($0.name) } ?? ""
        let isText = n.layer?.type == "TEXT"
        if n.layer != nil, !isText, containers.contains(word) {
            n.tag = word
        } else if isText, textTags.contains(word) {
            n.tag = word
        } else if isRoot {
            n.tag = "main"
        } else if parentIsRoot, n.tag == "div", !n.children.isEmpty {
            n.tag = "section"
        } else if let l = n.layer, isText, let s = l.fontSize, s >= 0, let i = headings.firstIndex(of: s), (l.characters?.count ?? 0) <= 200 {
            n.tag = "h\(min(i + 1, 6))"
        } else if let l = n.layer, isText, let ls = l.listStyle, ls == "bulleted" || ls == "numbered" {
            n.tag = ls == "bulleted" ? "ul" : "ol"
            let lines = (n.text ?? "").components(separatedBy: "<br>")
            n.text = nil
            n.children = lines.map { MarkupNode(tag: "li", cls: "", attrs: [], text: $0, children: [], layer: nil) }
        }
        for i in n.children.indices where n.tag != "ul" && n.tag != "ol" {
            rewrite(&n.children[i], isRoot: false, parentIsRoot: isRoot, headings: headings)
        }
        groupBullets(&n)
    }

    private static func groupBullets(_ n: inout MarkupNode) {
        func isBullet(_ c: MarkupNode) -> Bool {
            guard c.tag == "p", let t = c.text, let f = t.first, markers.contains(f) else { return false }
            return t.dropFirst().first == " "
        }
        var out: [MarkupNode] = []
        var i = 0
        while i < n.children.count {
            var j = i
            while j < n.children.count, isBullet(n.children[j]) { j += 1 }
            if j - i >= 2 {
                let items = n.children[i..<j].map { c -> MarkupNode in var li = c; li.tag = "li"; return li }
                out.append(MarkupNode(tag: "ul", cls: "orq-list", attrs: [], text: nil, children: items, layer: nil))
                i = j
            } else {
                out.append(n.children[i]); i += 1
            }
        }
        n.children = out
    }

    private static func link(_ n: inout MarkupNode, warnings: inout [String]) {
        if let l = n.layer, let raw = l.hyperlink {
            let targets = n.tag == "ul" || n.tag == "ol" ? n.children.indices.map { [$0] } : (n.text != nil ? [[]] : [])
            if !targets.isEmpty {
                if let href = safeHref(raw) {
                    for t in targets {
                        if let k = t.first { n.children[k].text = "<a href=\"\(href)\">\(n.children[k].text ?? "")</a>" }
                        else { n.text = "<a href=\"\(href)\">\(n.text ?? "")</a>" }
                    }
                } else {
                    warnings.append("link dropped: \(l.name)")
                }
            }
        }
        for i in n.children.indices { link(&n.children[i], warnings: &warnings) }
    }

    static func safeHref(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let l = s.lowercased()
        let ok: Bool
        if ["http:", "https:", "mailto:", "tel:"].contains(where: l.hasPrefix) || s.hasPrefix("#") || s.hasPrefix("/") {
            ok = true
        } else {
            let colon = s.firstIndex(of: ":"), slash = s.firstIndex(of: "/")
            ok = colon == nil || (slash != nil && slash! < colon!)
        }
        guard ok else { return nil }
        return s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func html(_ root: MarkupNode, depth: Int) -> String {
        let pad = String(repeating: "  ", count: depth)
        let attrs = (root.cls.isEmpty ? "" : " class=\"\(root.cls)\"") + root.attrs.map { " \($0.name)=\"\($0.value)\"" }.joined()
        let open = "<\(root.tag)\(attrs)>"
        if root.tag == "img" { return pad + open }
        if root.children.isEmpty || root.text != nil {
            return "\(pad)\(open)\(root.text ?? "")</\(root.tag)>"
        }
        return "\(pad)\(open)\n" + root.children.map { html($0, depth: depth + 1) }.joined(separator: "\n") + "\n\(pad)</\(root.tag)>"
    }
}
