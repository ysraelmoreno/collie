import Foundation
import CryptoKit
import CollieDevice

/// `sig=<hash>` on `device screen` and `find`/`tap … --then screen` (device flows d1): a short hash of what names a
/// screen (title, selected tab, fixed labels and ids), stable across numbers, prices, dates, list contents and order,
/// theme and coordinates (nodes carry no colour nor bounds).
enum ScreenSignature {
    struct Node: Equatable, Sendable {
        var label: String, id: String = "", role: String, selected = false
        /// A variable list item: dropped unless it has an id, and then only its role and id count.
        var inList = false
    }

    /// 12 lowercase hex characters (SHA-256 prefix) of the sorted set of node keys.
    static func compute(_ nodes: [Node]) -> String {
        let keys = Set(nodes.compactMap { n -> String? in
            if n.inList {
                guard !n.id.isEmpty else { return nil }
                return "\(n.role)|\(stripDigits(n.id))"   // a row's id, "cell_42" → "cell_"
            }
            let l = normalize(n.label)
            guard !l.isEmpty || !n.id.isEmpty else { return nil }
            return "\(n.role)|\(n.id)|\(l)|\(n.selected ? "*" : "")"
        })
        let digest = SHA256.hash(data: Data(keys.sorted().joined(separator: "\n").utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The grouped screen as signature nodes. OCR items are left out: read only when the trigger fires, and noisy.
    static func compute(_ s: Screen) -> String {
        func node(_ i: ScreenItem, _ role: String? = nil) -> Node {
            Node(label: i.label, id: i.id, role: role ?? i.role, selected: i.state.contains("selected"), inList: i.inList)
        }
        var nodes = s.title.map { [Node(label: $0, role: "title")] } ?? []
        nodes += [s.back].compactMap { $0 }.map { node($0, "back") } + s.tabs.map { node($0, "tab") } + s.actions.map { node($0) }
            + s.fields.map { node($0, "field") } + s.floating.map { node($0, "floating") }
            + s.content.filter { !$0.ocr }.map { node($0) }
        return compute(nodes)
    }

    /// Lowercased words with no digit (numbers, prices, times, dates' days) and with a letter (drops "R$", "•", "-").
    // ponytail: a month name in a date ("26 nov") stays; a list of fixed words if dates move the hash on real apps
    static func normalize(_ label: String) -> String {
        label.lowercased().split(whereSeparator: \.isWhitespace)
            .filter { w in !w.contains(where: \.isNumber) && w.contains(where: \.isLetter) && w != "r$" && w != "us$" }
            .joined(separator: " ")
    }

    static func stripDigits(_ s: String) -> String { String(s.filter { !$0.isNumber }) }
}
