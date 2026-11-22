import Foundation
import CoreGraphics

/// One piece of text read from a screenshot. `box` is in the image's pixels (a `screencap` is screen pixels; a caller
/// that shrinks the image maps the boxes back before `OCR.nodes`).
public struct OCRItem: Equatable, Sendable {
    public var text: String, confidence: Double, box: CGRect
    public init(text: String, confidence: Double, box: CGRect) { self.text = text; self.confidence = confidence; self.box = box }
}

public enum OCRLevel: String, Sendable { case fast, accurate }

/// Reads the text of a PNG screenshot (macOS: Vision in `collied`). No provider: everything stays on the tree.
public protocol OCRProvider: Sendable {
    func recognize(png: Data, level: OCRLevel, languages: [String]) async throws -> [OCRItem]
}

/// Which O2 rule found the tree poor (`--timing` reports it as `trigger`).
public enum OCRTrigger: String, Sendable { case fewLabels = "labels", lowCoverage = "coverage", opaqueView = "opaque" }

/// The OCR fallback's pure half: when to read the screenshot (O2) and how its text joins the tree (O3).
public enum OCR {
    /// Rule 1: fewer labelled nodes than this in the content area.
    public static let minContentLabels = 3
    /// Rule 2: labelled or clickable nodes cover less than this share of the screen.
    public static let minCoverage = 0.15
    /// Rule 3: one opaque view (game surface, bare WebView, Flutter) covers more than this share.
    public static let maxOpaqueShare = 0.5
    /// The status and action bars: a node centred above this share of the height is not content.
    public static let barsShare = 0.12
    /// O3: items below this confidence or shorter than `minTextLength` are dropped.
    public static let minConfidence = 0.5, minTextLength = 2
    /// O3: same text closer than this (box gap, px) to a tree label or a kept item is a duplicate.
    public static let duplicateDistance: CGFloat = 24
    static let opaqueClasses: Set<String> = ["SurfaceView", "GLSurfaceView", "FlutterView", "WebView"]

    /// The first rule that fires, nil on a good tree. `size` is the screen; nil uses the nodes' extent (as `ScreenModel`).
    /// ponytail: rules 4 (find/tap without a tree hit) and 5 (--ocr/--no-ocr) are the caller's, not the tree's.
    public static func trigger(_ nodes: [UINode], size: CGSize? = nil) -> OCRTrigger? {
        let w = size?.width ?? nodes.map(\.bounds.maxX).max() ?? 0, h = size?.height ?? nodes.map(\.bounds.maxY).max() ?? 0
        guard w > 0, h > 0 else { return .fewLabels }
        let screen = CGRect(x: 0, y: 0, width: w, height: h)
        let roles = nodes.map(ScreenModel.role)
        func inToolbar(_ i: Int) -> Bool {
            sequence(first: i, next: { nodes[$0].parent }).contains { roles[$0] == "toolbar" }
        }
        let content = nodes.indices.filter { labelled(nodes[$0]) && nodes[$0].bounds.midY >= h * barsShare && !inToolbar($0) }
        if content.count < minContentLabels { return .fewLabels }
        let covered = unionArea(nodes.filter { labelled($0) || $0.clickable }.map { $0.bounds.intersection(screen) })
        if Double(covered / (w * h)) < minCoverage { return .lowCoverage }
        for (i, n) in nodes.enumerated() where opaqueClasses.contains(ScreenModel.short(n.cls)) {
            let share = Double(n.bounds.intersection(screen).area / (w * h))
            // a WebView with labelled children is readable
            if ScreenModel.short(n.cls) == "WebView", nodes[(i + 1)...].prefix(while: { $0.depth > n.depth }).contains(where: labelled) { continue }
            if share > maxOpaqueShare { return .opaqueView }
        }
        return nil
    }

    /// The items that become nodes (`ocr`, refs `o1`…, no click), in reading order: rows by vertical centre, then left
    /// to right. Dropped: low confidence, short text, centre inside a labelled tree node (the tree wins), and the same
    /// text within `duplicateDistance` of a tree label or an item already kept.
    public static func nodes(_ items: [OCRItem], tree: [UINode]) -> [UINode] {
        let labels = tree.filter(labelled)
        var kept: [OCRItem] = []
        for it in readingOrder(items) {
            let t = it.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard it.confidence >= minConfidence, t.count >= minTextLength else { continue }
            let c = CGPoint(x: it.box.midX, y: it.box.midY)
            if labels.contains(where: { $0.bounds.contains(c) }) { continue }
            let same = labels.map { (label($0), $0.bounds) } + kept.map { ($0.text, $0.box) }
            if same.contains(where: { $0.0.caseInsensitiveCompare(t) == .orderedSame && gap($0.1, it.box) < duplicateDistance }) { continue }
            kept.append(OCRItem(text: t, confidence: it.confidence, box: it.box))
        }
        return kept.enumerated().map { i, it in
            var n = UINode(ref: "o\(i + 1)", cls: "ocr", text: it.text, desc: "", id: "", bounds: it.box, clickable: false, depth: 0)
            n.ocr = true
            return n
        }
    }

    /// Rows: an item joins the current row when its centre is within half the row's first box height; rows top to bottom.
    static func readingOrder(_ items: [OCRItem]) -> [OCRItem] {
        var rows: [[OCRItem]] = []
        for it in items.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let first = rows.last?.first, abs(it.box.midY - first.box.midY) <= first.box.height / 2 { rows[rows.count - 1].append(it) }
            else { rows.append([it]) }
        }
        return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    static func labelled(_ n: UINode) -> Bool { !label(n).isEmpty }
    static func label(_ n: UINode) -> String { (n.text.isEmpty ? n.desc : n.text).trimmingCharacters(in: .whitespaces) }

    /// Distance between two boxes' edges; 0 when they touch or overlap.
    static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX)), dy = max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY))
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Area covered by the rects, overlaps counted once: x slabs, merged y intervals per slab.
    /// ponytail: O(n² log n), fine for the compact tree (hundreds of nodes); a sweep tree if trees reach thousands.
    static func unionArea(_ rects: [CGRect]) -> CGFloat {
        let rs = rects.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        let xs = Array(Set(rs.flatMap { [$0.minX, $0.maxX] })).sorted()
        var area: CGFloat = 0
        for (x0, x1) in zip(xs, xs.dropFirst()) {
            let ys = rs.filter { $0.minX <= x0 && $0.maxX >= x1 }.map { ($0.minY, $0.maxY) }.sorted { $0.0 < $1.0 }
            var covered: CGFloat = 0, end = -CGFloat.infinity
            for (y0, y1) in ys {
                if y0 > end { covered += y1 - y0; end = y1 } else if y1 > end { covered += y1 - end; end = y1 }
            }
            area += covered * (x1 - x0)
        }
        return area
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
