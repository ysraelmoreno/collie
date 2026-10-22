import Foundation
import CoreGraphics

public struct UINode: Equatable, Sendable {
    public var ref: String; public var cls: String; public var text: String; public var desc: String
    public var id: String; public var bounds: CGRect; public var clickable: Bool; public var depth: Int
    public var center: (x: Int, y: Int) { (Int(bounds.midX), Int(bounds.midY)) }
}

/// Compacts a `uiautomator dump` XML into the few nodes an agent needs.
public enum UITree {
    public static func parse(_ xml: Data, cap: Int = 2000) -> (nodes: [UINode], truncated: Bool) {
        let p = XMLParser(data: xml)
        let h = Handler(cap: cap)
        p.delegate = h
        p.parse()
        return (h.nodes, h.truncated)
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
            let clickable = a["clickable"] == "true"
            guard !text.isEmpty || !desc.isEmpty || !rid.isEmpty || clickable else { return }
            if nodes.count >= cap { truncated = true; parser.abortParsing(); return }
            nodes.append(UINode(ref: "e\(nodes.count + 1)", cls: a["class"] ?? "", text: text, desc: desc,
                                id: rid.split(separator: "/").last.map(String.init) ?? rid,
                                bounds: Self.rect(a["bounds"] ?? ""), clickable: clickable, depth: depth))
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
