import Foundation
import CoreGraphics
import CollieProtocol

public struct UINode: Equatable, Sendable {
    public var ref: String; public var cls: String; public var text: String; public var desc: String
    public var id: String; public var bounds: CGRect; public var clickable: Bool; public var depth: Int
    /// Index (in the node list) of the nearest kept ancestor; set by `UITree.linkParents`.
    public var parent: Int?
    public var selected: Bool; public var checked: Bool; public var enabled: Bool; public var focused: Bool; public var scrollable: Bool
    public var password: Bool
    /// The device helper's child-index path to this node (`click`/`scroll`); nil when read by uiautomator or AXe.
    public var path: [Int]?
    /// Read from the screenshot by OCR (`OCR.nodes`), not from the tree: no role, no click.
    public var ocr: Bool
    public var center: (x: Int, y: Int) { (Int(bounds.midX), Int(bounds.midY)) }
    public init(ref: String, cls: String, text: String, desc: String, id: String, bounds: CGRect, clickable: Bool, depth: Int,
                parent: Int? = nil, selected: Bool = false, checked: Bool = false, enabled: Bool = true, focused: Bool = false, scrollable: Bool = false,
                password: Bool = false, path: [Int]? = nil, ocr: Bool = false) {
        self.ref = ref; self.cls = cls; self.text = text; self.desc = desc; self.id = id; self.bounds = bounds; self.clickable = clickable; self.depth = depth
        self.parent = parent; self.selected = selected; self.checked = checked; self.enabled = enabled; self.focused = focused; self.scrollable = scrollable
        self.password = password; self.path = path; self.ocr = ocr
    }
}

/// "configuration_fab" → "configuration fab", "topBarMenu" → "top bar menu", "ICON-btn" → "icon btn":
/// `_`/`-` (any non-alphanumeric) become spaces, camelCase splits, lowercased.
public func humanizeId(_ id: String) -> String {
    var s = "", prev: Character?
    for c in id {
        if c.isUppercase, let p = prev, p.isLowercase || p.isNumber { s.append(" ") }
        s.append(c); prev = c
    }
    return s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
}

/// Compacts a `uiautomator dump` XML into the few nodes an agent needs.
public enum UITree {
    public static func parse(_ xml: Data, cap: Int = 2000) -> (nodes: [UINode], truncated: Bool) {
        let p = XMLParser(data: xml)
        let h = Handler(cap: cap)
        p.delegate = h
        p.parse()
        return (linkParents(h.nodes), h.truncated)
    }

    /// The nodes of a device helper `dump`, kept and numbered as `parse` keeps a uiautomator XML (same refs, same tree),
    /// with each node's `path` for `click`. Depth is the path's length (the root's path is empty, as uiautomator's depth 0).
    public static func nodes(_ d: HelperProtocol.Dump, cap: Int = 2000) -> (nodes: [UINode], truncated: Bool) {
        var out: [UINode] = []
        for n in d.nodes where !n.text.isEmpty || !n.desc.isEmpty || !n.id.isEmpty || n.clickable || n.scrollable {
            guard out.count < cap else { return (linkParents(out), true) }
            let b = n.bounds.count == 4 ? CGRect(x: n.bounds[0], y: n.bounds[1], width: n.bounds[2] - n.bounds[0], height: n.bounds[3] - n.bounds[1]) : .zero
            out.append(UINode(ref: "e\(out.count + 1)", cls: n.cls, text: n.text, desc: n.desc,
                              id: n.id.split(separator: "/").last.map(String.init) ?? n.id, bounds: b, clickable: n.clickable,
                              depth: n.path.count, selected: n.selected, checked: n.checked, enabled: n.enabled, focused: n.focused,
                              scrollable: n.scrollable, password: n.password, path: n.path))
        }
        return (linkParents(out), false)
    }

    /// Sets each node's `parent`: the nearest earlier node with a smaller depth (the list is pre-order).
    public static func linkParents(_ nodes: [UINode]) -> [UINode] {
        var out = nodes, stack: [Int] = []
        for i in out.indices {
            while let top = stack.last, out[top].depth >= out[i].depth { stack.removeLast() }
            out[i].parent = stack.last
            stack.append(i)
        }
        return out
    }

    /// The nodes an agent acts on: a label (`text`/`desc`) or `clickable`. A node with only an `id` drops out.
    /// Refs stay those of the full tree (`--all`), so the compact numbering has gaps.
    public static func compact(_ nodes: [UINode]) -> [UINode] {
        nodes.filter { !$0.text.isEmpty || !$0.desc.isEmpty || $0.clickable }
    }

    /// The `device.ui` result: compact unless `all`; `nodes` is how many were listed, `total` the full tree's count.
    public static func result(_ nodes: [UINode], truncated: Bool, all: Bool) -> JSONValue {
        let shown = all ? nodes : compact(nodes)
        return .object(["tree": .string(lines(shown)), "truncated": .bool(truncated),
                        "nodes": .number(Double(shown.count)), "total": .number(Double(nodes.count))])
    }

    /// `device.tap --text/--id`: the node to tap. `text` matches ignoring case: `text`/`desc` equal, then the humanized
    /// `id` equal (`humanizeId`, clickable nodes only), then containing in any of the three; `id` matches exactly (both given: both must match). A node that isn't clickable gives way to its
    /// nearest clickable ancestor (none: the node itself); candidates landing on the same node count once. Several:
    /// `nth` (from 1) picks one, else invalidArgs listing up to 5. None: notFound with up to 5 similar labels and unlabeled clickable ids.
    /// `keep` drops candidates after the climb (`device.find --role`).
    public static func target(_ nodes: [UINode], text: String?, id: String?, nth: Int?,
                              keep: (UINode) -> Bool = { _ in true }) throws(ProtocolError) -> UINode {
        func label(_ n: UINode) -> String { n.text.isEmpty ? n.desc : n.text }
        func show(_ ns: [UINode]) -> String {
            ns.prefix(5).map { n in "\(n.ref) " + (label(n).isEmpty ? "id=\(n.id)" : "\"\(label(n))\"") }.joined(separator: ", ")
        }
        var idx = Array(nodes.indices)
        if let id { idx = idx.filter { nodes[$0].id == id } }
        if let t = text?.lowercased() {
            let labels = { (i: Int) in [nodes[i].text.lowercased(), nodes[i].desc.lowercased()] }
            let hid = { (i: Int) in nodes[i].clickable ? humanizeId(nodes[i].id) : "" }   // an id only counts on a clickable node
            let equal = idx.filter { labels($0).contains(t) }
            let idEqual = idx.filter { !hid($0).isEmpty && hid($0) == t }
            idx = !equal.isEmpty ? equal : !idEqual.isEmpty ? idEqual
                : idx.filter { labels($0).contains { $0.contains(t) } } + idx.filter { i in !hid(i).isEmpty && hid(i).contains(t) && !labels(i).contains { $0.contains(t) } }
        }
        var hits: [UINode] = []
        for i in idx {
            var hit = nodes[i], d = hit.depth
            for p in nodes[..<i].reversed() where !nodes[i].clickable && p.depth < d {   // pre-order: each shallower node before is an ancestor
                if p.clickable { hit = p; break }
                d = p.depth
            }
            if keep(hit), !hits.contains(where: { $0.ref == hit.ref }) { hits.append(hit) }
        }
        let what = [text.map { "text \"\($0)\"" }, id.map { "id \($0)" }].compactMap { $0 }.joined(separator: " and ")
        guard !hits.isEmpty else {
            // ponytail: "similar" = shares a word with the query; first labels when none does
            let words = Set((text ?? id ?? "").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }))
            let unlabeled = nodes.filter { $0.clickable && label($0).isEmpty && !$0.id.isEmpty }   // e.g. a floating action button
            let named = nodes.filter { (!label($0).isEmpty || !$0.id.isEmpty) && !unlabeled.contains($0) }
            let near = named.filter { n in !words.isDisjoint(with: (label(n) + " " + n.id).lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })) }
            let u = Array(unlabeled.prefix(2)), similar = Array((near.isEmpty ? named : near).prefix(5 - u.count))
            throw ProtocolError(code: .notFound, message: "No element with \(what)" + (similar.isEmpty ? "" : "; similar: \(show(similar))")
                                + (u.isEmpty ? "" : "; unlabeled: \(show(u))"))
        }
        if let nth {
            guard (1...hits.count).contains(nth) else {
                throw ProtocolError(code: .invalidArgs, message: "--nth \(nth): only \(hits.count) element(s) with \(what): \(show(hits))")
            }
            return hits[nth - 1]
        }
        guard hits.count == 1 else {
            throw ProtocolError(code: .invalidArgs, message: "\(hits.count) elements with \(what): \(show(hits)); pick one with --ref or --nth")
        }
        return hits[0]
    }

    public static func lines(_ nodes: [UINode]) -> String {
        nodes.map { n in
            var s = String(repeating: "  ", count: n.depth) + "[\(n.ref)] \(n.cls.split(separator: ".").last.map(String.init) ?? n.cls)"
            let label = n.text.isEmpty ? n.desc : n.text
            if !label.isEmpty { s += " \"\(label)\"" }
            if !n.id.isEmpty { s += " id=\(n.id)" }
            s += " (\(n.center.x),\(n.center.y))"
            if n.clickable { s += " clickable" }
            return s
        }.joined(separator: "\n")
    }

    private final class Handler: NSObject, XMLParserDelegate {
        var nodes: [UINode] = []
        var truncated = false
        let cap: Int
        var depth = 0
        init(cap: Int) { self.cap = cap }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            guard name == "node" else { return }
            defer { depth += 1 }
            let text = a["text"] ?? "", desc = a["content-desc"] ?? "", rid = a["resource-id"] ?? ""
            let clickable = a["clickable"] == "true", scrollable = a["scrollable"] == "true"
            guard !text.isEmpty || !desc.isEmpty || !rid.isEmpty || clickable || scrollable else { return }
            if nodes.count >= cap { truncated = true; parser.abortParsing(); return }
            nodes.append(UINode(ref: "e\(nodes.count + 1)", cls: a["class"] ?? "", text: text, desc: desc,
                                id: rid.split(separator: "/").last.map(String.init) ?? rid,
                                bounds: Self.rect(a["bounds"] ?? ""), clickable: clickable, depth: depth,
                                selected: a["selected"] == "true", checked: a["checked"] == "true", enabled: a["enabled"] != "false",
                                focused: a["focused"] == "true", scrollable: scrollable, password: a["password"] == "true"))
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "node" { depth -= 1 }
        }

        /// "[l,t][r,b]"
        static func rect(_ s: String) -> CGRect {
            let n = s.split(whereSeparator: { !"-0123456789".contains($0) }).compactMap { Double($0) }
            return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1]) : .zero
        }
    }
}
