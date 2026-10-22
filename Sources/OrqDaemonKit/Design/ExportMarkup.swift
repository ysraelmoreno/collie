import Foundation
import OrqProtocol

struct Attr: Equatable, Sendable { var name: String; var value: String }
struct GridTrack: Equatable, Sendable { var sizing: String /* fixed|fill|hug */; var value: Double }

/// A design layer as read from `get_node` JSON.
struct Layer: Equatable, Sendable {
    var id: String
    var name: String
    var type: String
    var visible: Bool
    var characters: String?
    var fontSize: Double?
    var listStyle: String?
    var hyperlink: String?
    var layoutMode: String? /* horizontal|vertical|grid */
    var gridColumns: Int?
    var columnTracks: [GridTrack]
    var crossGap: Double?
    var children: [Layer]
}

/// An element of figcraft's HTML markup, optionally bound to the layer it came from.
struct MarkupNode: Equatable, Sendable {
    var tag: String
    var cls: String
    var attrs: [Attr]
    var text: String? /* already HTML-escaped, `<br>` as emitted */
    var children: [MarkupNode]
    var layer: Layer?
}

enum ExportMarkup {
    /// Splits inspect.code output into markup and stylesheet body.
    static func split(_ code: String) -> (markup: String, css: String) {
        guard let open = code.range(of: "\n<style>\n") else { return (code, "") }
        let rest = code[open.upperBound...]
        let css = rest.range(of: "</style>", options: .backwards).map { String(rest[..<$0.lowerBound]) } ?? String(rest)
        return (String(code[..<open.lowerBound]), css)
    }

    static func parse(_ markup: String) throws(ProtocolError) -> [MarkupNode] {
        let bad = ProtocolError(code: .internal, message: "unexpected export markup")
        var roots: [MarkupNode] = []
        var stack: [MarkupNode] = []
        func emit(_ n: MarkupNode) {
            if stack.isEmpty { roots.append(n) } else { stack[stack.count - 1].children.append(n) }
        }
        var s = Substring(markup)
        while true {
            s = s.drop { $0.isWhitespace }
            if s.isEmpty { break }
            if s.hasPrefix("</div>") {
                s = s.dropFirst(6)
                guard let n = stack.popLast() else { throw bad }
                emit(n)
                continue
            }
            let isDiv = s.hasPrefix("<div"), isP = s.hasPrefix("<p")
            guard isDiv || isP, let end = s.firstIndex(of: ">") else { throw bad }
            let head = s[s.index(after: s.startIndex)..<end]
            let tag = isDiv ? "div" : "p"
            guard head.dropFirst(tag.count).first.map({ $0 == " " }) ?? true else { throw bad }
            var cls = ""
            var attrs: [Attr] = []
            var h = head.dropFirst(tag.count)
            while true {
                h = h.drop { $0 == " " }
                if h.isEmpty { break }
                guard let eq = h.firstIndex(of: "="), h[h.index(after: eq)...].first == "\"" else { throw bad }
                let vs = h.index(eq, offsetBy: 2)
                guard let q = h[vs...].firstIndex(of: "\"") else { throw bad }
                let (name, value) = (String(h[..<eq]), String(h[vs..<q]))
                if name == "class" { cls = value } else { attrs.append(Attr(name: name, value: value)) }
                h = h[h.index(after: q)...]
            }
            s = s[s.index(after: end)...]
            var node = MarkupNode(tag: tag, cls: cls, attrs: attrs, text: nil, children: [], layer: nil)
            if isDiv {
                stack.append(node)
            } else {
                // ponytail: figcraft escapes `<` in text, so the first `</p>` always closes it.
                guard let close = s.range(of: "</p>") else { throw bad }
                node.text = String(s[..<close.lowerBound])
                s = s[close.upperBound...]
                emit(node)
            }
        }
        guard stack.isEmpty else { throw bad }
        return roots
    }

    /// Reads a `get_node` JSON subtree; nil when it has no id/name/type.
    static func layer(_ json: JSONValue) -> Layer? {
        guard case .object(let o) = json, let name = o["name"]?.str, let type = o["type"]?.str else { return nil }
        let id: String
        switch o["id"] {
        case .number(let n)?: id = Int(exactly: n).map(String.init) ?? String(n)
        case .string(let s)?: id = s
        default: return nil
        }
        var visible = true
        if case .bool(let b)? = o["visible"] { visible = b }
        var layout: [String: JSONValue] = [:]
        if case .object(let l)? = o["layout"] { layout = l }
        var tracks: [GridTrack] = []
        if case .array(let a)? = layout["columnTracks"] {
            for case .object(let t) in a {
                if let s = t["sizing"]?.str, case .number(let v)? = t["value"] { tracks.append(GridTrack(sizing: s, value: v)) }
            }
        }
        var kids: [Layer] = []
        // ponytail: malformed children are dropped, so attach then fails closed on the count.
        if case .array(let a)? = o["children"] { kids = a.compactMap(layer) }
        return Layer(
            id: id, name: name, type: type, visible: visible,
            characters: o["characters"]?.str, fontSize: o["fontSize"]?.num, listStyle: o["listStyle"]?.str,
            hyperlink: o["hyperlink"]?.str, layoutMode: layout["mode"]?.str,
            gridColumns: layout["gridColumns"]?.num.map { n in Int(exactly: n).map { min(max($0, 1), 1000) } ?? 1 }, columnTracks: tracks,
            crossGap: layout["crossGap"]?.num, children: kids)
    }

    /// Port of figcraft's `class_name` (codegen.rs): ASCII-alphanumeric lowercase, unique in `used`.
    static func className(_ name: String, used: inout [String]) -> String {
        var base = ""
        for u in name.unicodeScalars {
            for c in u.properties.lowercaseMapping.unicodeScalars {
                if c.isASCII, (c.properties.numericType != nil || ("a"..."z").contains(Character(c))) {
                    base.unicodeScalars.append(c)
                } else if !base.isEmpty, !base.hasSuffix("-") {
                    base.append("-")
                }
            }
        }
        while base.hasSuffix("-") { base.removeLast() }
        base = String(base.prefix(40))
        if base.isEmpty || base.first!.isNumber { base = "layer-" + base }
        var n = base, k = 1
        while used.contains(n) { k += 1; n = "\(base)-\(k)" }
        used.append(n)
        return n
    }

    /// figcraft's `MAX_CHILDREN` (codegen.rs): visible children past this are not emitted.
    private static let maxChildren = 200

    /// Binds `layer` and its visible descendants to the markup tree. All or nothing.
    static func attach(_ root: inout MarkupNode, _ layer: Layer) -> Bool {
        var used: [String] = []
        var copy = root
        guard bind(&copy, layer, &used) else { return false }
        root = copy
        return true
    }

    private static func bind(_ node: inout MarkupNode, _ layer: Layer, _ used: inout [String]) -> Bool {
        guard className(layer.name, used: &used) == node.cls else { return false }
        node.layer = layer
        if node.children.isEmpty { return true } // leaf, or the codegen's depth cut
        let kids = Array(layer.children.filter(\.visible).prefix(maxChildren))
        guard kids.count == node.children.count else { return false }
        for i in kids.indices where !bind(&node.children[i], kids[i], &used) { return false }
        return true
    }
}

extension JSONValue {
    var str: String? { if case .string(let s) = self { s } else { nil } }
    var num: Double? { if case .number(let n) = self { n } else { nil } }
}
