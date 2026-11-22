import Foundation
import CoreGraphics
import CollieProtocol

/// One element of a `Screen` group: `ref` taps it (`device tap --ref`), `state` is any of selected, checked,
/// disabled, focused, scrollable, password. `position` is set on floating items only ("topo direito").
/// `ocr`: read from the screenshot (`OCR.nodes`), always a content text.
public struct ScreenItem: Equatable, Sendable {
    public var ref: String, label: String, role: String, state: [String], id: String, position: String?
    public var ocr = false
}

/// `device screen`: the UI tree grouped the way a person reads it (title, back, tabs, actions, fields, content,
/// floating buttons). `content` is what the spec's JSON calls `lists`: the labels left over, in tree order.
public struct Screen: Equatable, Sendable {
    public var title: String?
    public var back: ScreenItem?
    public var tabs: [ScreenItem] = [], actions: [ScreenItem] = [], fields: [ScreenItem] = []
    public var content: [ScreenItem] = [], floating: [ScreenItem] = []
    /// Content items cut by `cap`; whether a scrollable area was seen ("Conteúdo (rolável)").
    public var more = 0, scrolls = false
    public var changed: [String] = []
}

/// Pure grouping of `UINode`s (Android or iOS) into a `Screen`. Heuristics, wrong on some apps by design: nothing
/// is dropped, what fits no group lands in actions or content, and `device ui` keeps the raw tree.
public enum ScreenModel {
    public static func build(_ nodes: [UINode], size: CGSize? = nil, cap: Int = 12) -> Screen {
        // ponytail: no screen size from adb here; the nodes' extent stands in (the dump drops the bare root)
        let w = size?.width ?? nodes.map(\.bounds.maxX).max() ?? 1, h = size?.height ?? nodes.map(\.bounds.maxY).max() ?? 1
        var used = Set<Int>(), s = Screen()
        let roles = nodes.map(role)

        func ancestors(_ i: Int) -> [Int] { sequence(first: i, next: { nodes[$0].parent }).dropFirst().map { $0 } }
        func descendants(_ i: Int) -> [Int] {
            var out: [Int] = []
            for j in (i + 1)..<nodes.count { if nodes[j].depth <= nodes[i].depth { break }; out.append(j) }
            return out
        }
        /// The node's label; "" for an image named like a symbol ("chevron", "apple.id"): not text for people.
        /// `device ui` and `--all` keep the raw tree, label included.
        func own(_ n: UINode) -> String {
            let l = (n.text.isEmpty ? n.desc : n.text).trimmingCharacters(in: .whitespaces)
            return isImage(n) && symbolNameNoise(l) ? "" : l
        }
        /// The node's label, else its first labelled non-clickable descendant's (that descendant is then used).
        func label(_ i: Int, consume: Bool) -> String {
            if !own(nodes[i]).isEmpty { return own(nodes[i]) }
            guard let d = descendants(i).first(where: { !nodes[$0].clickable && !own(nodes[$0]).isEmpty }) else { return "" }
            if consume { used.insert(d) }
            return own(nodes[d])
        }
        func item(_ i: Int, _ role: String, _ text: String? = nil) -> ScreenItem {
            let n = nodes[i]
            let state = [(n.selected || descendants(i).contains { nodes[$0].selected }) ? "selected" : nil,
                         n.checked ? "checked" : nil, n.enabled ? nil : "disabled", n.focused ? "focused" : nil,
                         n.scrollable ? "scrollable" : nil, n.password ? "password" : nil].compactMap { $0 }
            used.insert(i)
            return ScreenItem(ref: n.ref, label: text ?? label(i, consume: true), role: role, state: state, id: n.id, position: nil, ocr: n.ocr)
        }
        let top = { (i: Int) in nodes[i].bounds.midY < h * 0.15 }
        let inToolbar = { (i: Int) in ancestors(i).contains { roles[$0] == "toolbar" } }
        let inList = { (i: Int) in ancestors(i).contains { roles[$0] == "list" } }

        // back: a top clickable named like one
        if let b = nodes.indices.first(where: { i in
            nodes[i].clickable && top(i) && (["navigate up", "back", "voltar", "go back"].contains(label(i, consume: false).lowercased())
                || words(nodes[i].id).contains("back") || words(nodes[i].id).contains("up")) }) {
            s.back = item(b, "button")
        }
        // title: the toolbar's first text, else the first plain text near the top
        // OCR items only ever land in content
        let titleNode = nodes.indices.first { i in !used.contains(i) && !nodes[i].clickable && !own(nodes[i]).isEmpty && inToolbar(i) }
            ?? nodes.indices.first { i in !used.contains(i) && !nodes[i].ocr && !nodes[i].clickable && !own(nodes[i]).isEmpty && top(i) && !inList(i) }
        if let t = titleNode { s.title = own(nodes[t]); used.insert(t) }
        // fields
        for i in nodes.indices where roles[i] == "field" && !used.contains(i) {
            s.fields.append(item(i, "field", label(i, consume: true).nonEmpty ?? humanize(nodes[i].id)))
        }
        // floating: small unlabelled (or one-character) clickable against an edge
        for i in nodes.indices where nodes[i].clickable && !used.contains(i) && !inList(i) {
            let b = nodes[i].bounds, l = label(i, consume: false)
            let edge = b.minX < w * 0.1 || b.maxX > w * 0.9 || b.minY < h * 0.12 || b.maxY > h * 0.9
            guard l.count <= 1, b.width < w * 0.25, b.height < w * 0.25, edge else { continue }
            var it = item(i, "button", l.nonEmpty ?? humanize(nodes[i].id).nonEmpty ?? short(nodes[i].cls))
            it.position = (b.midY < h / 3 ? "topo" : b.midY > h * 2 / 3 ? "base" : "meio") + " "
                + (b.midX < w / 3 ? "esquerdo" : b.midX > w * 2 / 3 ? "direito" : "centro")
            s.floating.append(it)
        }
        // tabs: role tab, or 2 to 6 labelled clickable siblings on one row
        var tabIdx = Set(nodes.indices.filter { roles[$0] == "tab" && nodes[$0].clickable && !used.contains($0) })
        let candidates = nodes.indices.filter { i in nodes[i].clickable && !used.contains(i) && !inToolbar(i)
            && (1...20).contains(label(i, consume: false).count) }
        for (_, sibs) in Dictionary(grouping: candidates, by: { nodes[$0].parent ?? -1 }) where (2...6).contains(sibs.count) {
            let y = nodes[sibs[0]].bounds.midY
            if sibs.allSatisfy({ abs(nodes[$0].bounds.midY - y) < h * 0.03 }) { tabIdx.formUnion(sibs) }
        }
        for i in tabIdx.sorted() { s.tabs.append(item(i, "tab")) }
        // the rest: clickable outside a list = actions; labels and list buttons = content
        s.scrolls = roles.contains("list")
        var content: [ScreenItem] = []
        for i in nodes.indices where !used.contains(i) {
            if nodes[i].clickable && !inList(i) { s.actions.append(item(i, "button", label(i, consume: true).nonEmpty ?? humanize(nodes[i].id).nonEmpty ?? short(nodes[i].cls))) }
            else if nodes[i].clickable { let l = label(i, consume: true); if !l.isEmpty { content.append(item(i, "button", l)) } }
            else if !own(nodes[i]).isEmpty { content.append(item(i, "text", own(nodes[i]))) }
        }
        // P2: one item per thing within a group (iOS: a cell and its button carry the same label)
        let at = Dictionary(nodes.indices.map { (nodes[$0].ref, $0) }, uniquingKeysWith: { a, _ in a })
        func same(_ a: UINode, _ b: UINode) -> Bool {
            hypot(a.bounds.midX - b.bounds.midX, a.bounds.midY - b.bounds.midY) < 24
                || a.bounds.contains(b.bounds) || b.bounds.contains(a.bounds)
        }
        /// Kept: the clickable, then the shallower; it takes the first one's place, with its own ref.
        func dedup(_ items: [ScreenItem]) -> [ScreenItem] {
            var out: [ScreenItem] = []
            for it in items {
                guard let a = at[it.ref], !it.label.isEmpty,
                      let k = out.firstIndex(where: { o in o.label == it.label && at[o.ref].map { same(nodes[$0], nodes[a]) } == true })
                else { out.append(it); continue }
                let n = nodes[a], o = nodes[at[out[k].ref]!]
                if (n.clickable && !o.clickable) || (n.clickable == o.clickable && n.depth < o.depth) { out[k] = it }
            }
            return out
        }
        s.tabs = dedup(s.tabs); s.actions = dedup(s.actions); s.fields = dedup(s.fields); s.floating = dedup(s.floating)
        content = dedup(content)
        s.content = Array(content.prefix(cap)); s.more = max(0, content.count - cap)
        return s
    }

    /// What changed since `old`: title, the selected tabs, the content count. No `old`: nothing.
    public static func changes(from old: Screen?, to new: Screen) -> [String] {
        guard let old else { return [] }
        var out: [String] = []
        if old.title != new.title { out.append("título \(old.title ?? "-") → \(new.title ?? "-")") }
        let sel = { (s: Screen) in s.tabs.filter { $0.state.contains("selected") }.map(\.label).joined(separator: ", ") }
        if sel(old) != sel(new) { out.append("aba \(sel(old).nonEmpty ?? "-") → \(sel(new).nonEmpty ?? "-")") }
        let count = { (s: Screen) in s.content.count + s.more }
        if count(old) != count(new) { out.append("itens \(count(old)) → \(count(new))") }
        return out
    }

    public static func text(_ s: Screen) -> String {
        func b(_ i: ScreenItem) -> String { "[\(i.label)\(i.state.contains("selected") || i.state.contains("checked") ? "*" : "")]" }
        func row(_ name: String, _ items: [ScreenItem]) -> String? { items.isEmpty ? nil : name + ": " + items.map(b).joined(separator: " ") }
        var lines: [String?] = []
        lines.append("Tela: \(s.title ?? "(sem título)")" + (s.back == nil ? "" : "   [voltar]"))
        lines.append(row("Abas", s.tabs))
        lines.append(row("Ações", s.actions))
        lines.append(row("Campos", s.fields))
        if !s.content.isEmpty {
            let items = s.content.map { $0.role == "text" ? "\"\($0.label)\"" + ($0.ocr ? " (ocr)" : "") : b($0) } + (s.more > 0 ? ["+\(s.more) itens: use device ui"] : [])
            lines.append("Conteúdo\(s.scrolls ? " (rolável)" : ""): " + items.joined(separator: ", "))
        }
        if !s.floating.isEmpty {
            lines.append("Flutuante: " + s.floating.map { f in
                b(f) + (f.id.isEmpty ? "" : " id=\(f.id)") + (f.position.map { ", \($0)" } ?? "")
            }.joined(separator: "; "))
        }
        if !s.changed.isEmpty { lines.append("Mudou: " + s.changed.joined(separator: "; ")) }
        return lines.compactMap { $0 }.joined(separator: "\n")
    }

    /// `{text,title,back,tabs[],actions[],fields[],lists[],floating[],changed[],more}`; items `{ref,label,role,state[],id?,position?,source?}`
    /// (`source: "ocr"` on OCR items).
    public static func json(_ s: Screen) -> [String: JSONValue] {
        func j(_ i: ScreenItem) -> JSONValue {
            var o: [String: JSONValue] = ["ref": .string(i.ref), "label": .string(i.label), "role": .string(i.role),
                                          "state": .array(i.state.map { .string($0) })]
            if !i.id.isEmpty { o["id"] = .string(i.id) }
            if let p = i.position { o["position"] = .string(p) }
            if i.ocr { o["source"] = .string("ocr") }
            return .object(o)
        }
        return ["text": .string(text(s)), "title": s.title.map { .string($0) } ?? .null, "back": s.back.map(j) ?? .null,
                "tabs": .array(s.tabs.map(j)), "actions": .array(s.actions.map(j)), "fields": .array(s.fields.map(j)),
                "lists": .array(s.content.map(j)), "floating": .array(s.floating.map(j)),
                "changed": .array(s.changed.map { .string($0) }), "more": .number(Double(s.more))]
    }

    /// The node's role from its class (Android or iOS), then its id (Compose: every class is View).
    static func role(_ n: UINode) -> String? {
        switch short(n.cls) {
        case "Button", "ImageButton", "Link": return "button"
        case "EditText", "TextField", "SecureTextField", "SearchField", "AutoCompleteTextView": return "field"
        case "RecyclerView", "ListView", "ScrollView", "HorizontalScrollView", "NestedScrollView", "ScrollArea", "Table", "CollectionView": return "list"
        case "Tab", "TabView": return "tab"
        case "Toolbar", "NavigationBar", "ActionBar": return "toolbar"
        default: break
        }
        let w = words(n.id)
        if w.contains("toolbar") || w.contains("appbar") { return "toolbar" }
        if w.contains("search") { return "field" }
        if w.contains("tab") { return "tab" }
        if n.scrollable { return "list" }
        return n.clickable ? "button" : nil
    }

    /// iOS `Image`; Android `ImageView`/`ImageButton` without text (its label is the content description).
    static func isImage(_ n: UINode) -> Bool {
        switch short(n.cls) {
        case "Image": true
        case "ImageView", "ImageButton": n.text.isEmpty
        default: false
        }
    }

    /// "configuration_fab" → "configuration fab"
    static func humanize(_ id: String) -> String { humanizeId(id) }
    static func words(_ id: String) -> [String] {
        id.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
    static func short(_ cls: String) -> String { cls.split(separator: ".").last.map(String.init) ?? cls }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
