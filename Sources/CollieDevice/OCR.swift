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

/// Which O2 rule sent the screen to the OCR (`--timing` reports it as `trigger`): the tree's rules 1-3, `find` (rule 4: a
/// find/tap with no tree hit) and `flag` (rule 5: `--ocr`/`--region`).
public enum OCRTrigger: String, Sendable {
    case fewLabels = "labels", lowCoverage = "coverage", opaqueView = "opaque", find, flag
}

/// The OCR fallback's pure half: when to read the screenshot (O2) and how its text joins the tree (O3).
/// The limits and class lists below are calibration knobs (spec O2, iOS corpus 2026-11-22): change them here, tests pin
/// the edges.
public enum OCR {
    /// Rule 1: fewer labelled nodes than this in the content area.
    public static let minContentLabels = 3
    /// Rule 2: labelled or clickable nodes cover less than this share of the content area. Rule 3 reuses it: an opaque
    /// view's labelled/clickable descendants must cover at least this share of it to count as covering its text.
    /// ponytail: iOS's labelled `Application` root covers the whole screen, so rule 2 is in practice Android's; on iOS
    /// the text-sized frames of a good screen cover ~8%, too little to tell good from poor without that root.
    public static let coverageMin = 0.15
    /// Rule 3: one opaque view covers more than this share of the screen.
    public static let maxOpaqueShare = 0.5
    /// The status and action bars: a node centred above this share of the height is not content, and rule 2's content
    /// area starts below it.
    public static let barsShare = 0.12
    /// O3: items below this confidence or shorter than `minTextLength` are dropped.
    public static let minConfidence = 0.5, minTextLength = 2
    /// O3: same text closer than this (box gap, px) to a tree label or a kept item is a duplicate.
    public static let duplicateDistance: CGFloat = 24
    /// Rule 3's classes (last dotted component of `cls`): views that draw their own pixels, so the tree cannot see the
    /// text. Android: game/video surfaces, WebView (a `<canvas>` is not in the DOM), Flutter; iOS (AXe type or class):
    /// WebView/WKWebView.
    static let opaqueClasses: Set<String> = ["SurfaceView", "GLSurfaceView", "TextureView", "WebView", "FlutterView", "WKWebView"]
    /// iOS Metal/SceneKit/SpriteKit views: opaque only when the tree is that single node (SpriteKit exposes its HUD
    /// labels, corpus `game`: 5 nodes, full recall).
    static let opaqueSingleNodeClasses: Set<String> = ["MTKView", "SCNView", "SKView", "ARSCNView", "ARSKView"]
    /// A node covering at least this share of the screen is a container: it frames content, it is not content (iOS's
    /// labelled `Application` root, a full-screen `ScrollArea`). The fusion never lets it win and rules 1 and 3 do not
    /// count it.
    public static let containerAreaMin = 0.4
    /// Container types (AXe) when they carry no text of their own beyond the app title, whatever their size.
    static let containerClasses: Set<String> = ["Application", "ScrollArea", "Window", "Other"]

    /// The first rule that fires (1 labels, 2 coverage, 3 opaque), nil on a good tree. `size` is the screen; nil uses
    /// the nodes' extent (as `ScreenModel`). Rules 4 (`find`) and 5 (`flag`) are the caller's, not the tree's.
    public static func trigger(_ nodes: [UINode], size: CGSize? = nil) -> OCRTrigger? {
        let w = size?.width ?? nodes.map(\.bounds.maxX).max() ?? 0, h = size?.height ?? nodes.map(\.bounds.maxY).max() ?? 0
        guard w > 0, h > 0 else { return .fewLabels }
        let screen = CGRect(x: 0, y: 0, width: w, height: h)
        if emptyShell(nodes, screen: screen) { return .opaqueView }
        if contentLabels(nodes, screen: screen) < minContentLabels { return .fewLabels }
        if coverage(nodes, screen: screen) < coverageMin { return .lowCoverage }
        if opaqueView(nodes, screen: screen) != nil { return .opaqueView }
        return nil
    }

    /// iOS's opaque signal: the tree has an `Application` root and nothing but containers, scroll bars and the app
    /// title (a WKWebView or canvas that draws its own text: corpus `canvas`, `webcanvas`). Android has no such root.
    static func emptyShell(_ nodes: [UINode], screen: CGRect) -> Bool {
        guard nodes.contains(where: { ScreenModel.short($0.cls) == "Application" }) else { return false }
        let skip = ignored(nodes, screen: screen), title = appTitle(nodes)
        return nodes.allSatisfy { skip($0) || label($0) == title }
    }

    /// Rule 1: labelled nodes centred below the bars and outside a toolbar; containers and scroll bars do not count.
    static func contentLabels(_ nodes: [UINode], screen: CGRect) -> Int {
        let roles = nodes.map(ScreenModel.role), skip = ignored(nodes, screen: screen), h = screen.height
        func inToolbar(_ i: Int) -> Bool { sequence(first: i, next: { nodes[$0].parent }).contains { roles[$0] == "toolbar" } }
        return nodes.indices.filter { labelled(nodes[$0]) && !skip(nodes[$0]) && nodes[$0].bounds.midY >= h * barsShare && !inToolbar($0) }.count
    }

    /// Rule 2: share of the content area (below the bars) covered by labelled or clickable nodes, overlaps once. Scroll
    /// bars do not count; containers still do.
    /// ponytail: dropping containers here too would fire iOS's good screens (`normal`'s text frames cover ~9%); the
    /// empty iOS shell is `emptyShell`'s job. Recalibrate `coverageMin` per platform to drop them.
    static func coverage(_ nodes: [UINode], screen: CGRect) -> Double {
        let content = CGRect(x: 0, y: screen.height * barsShare, width: screen.width, height: screen.height * (1 - barsShare))
        return Double(unionArea(nodes.filter { covers($0) && !scrollBar($0) }.map { $0.bounds.intersection(content) }) / content.area)
    }

    /// A node the trigger does not count and the fusion does not let win: a container or a scroll bar.
    static func ignored(_ nodes: [UINode], screen: CGRect) -> (UINode) -> Bool {
        let title = appTitle(nodes)
        return { container($0, screen: screen, appTitle: title) || scrollBar($0) }
    }

    /// Covers at least `containerAreaMin` of the screen, or a container type with no text beyond the app title.
    static func container(_ n: UINode, screen: CGRect, appTitle: String?) -> Bool {
        if screen.area > 0, Double(n.bounds.intersection(screen).area / screen.area) >= containerAreaMin { return true }
        let l = label(n)
        return containerClasses.contains(ScreenModel.short(n.cls)) && (l.isEmpty || l == appTitle)
    }

    /// iOS scroll bars: AXe `Slider` or a label naming one ("Vertical scroll bar, 2 pages").
    static func scrollBar(_ n: UINode) -> Bool {
        let l = label(n).lowercased()
        return ScreenModel.short(n.cls) == "Slider" || l.contains("scroll bar") || l.contains("barra de rolagem")
    }

    /// The label of the `Application` root (iOS), nil without one.
    static func appTitle(_ nodes: [UINode]) -> String? { nodes.first { ScreenModel.short($0.cls) == "Application" }.map(label) }

    static func extent(_ nodes: [UINode]) -> CGRect {
        CGRect(x: 0, y: 0, width: nodes.map(\.bounds.maxX).max() ?? 0, height: nodes.map(\.bounds.maxY).max() ?? 0)
    }

    /// Rule 3: the first opaque-class node over `maxOpaqueShare` of the screen whose labelled/clickable descendants
    /// cover less than `coverageMin` of it (a WebView with 6 page nodes but its text in a `<canvas>`).
    static func opaqueView(_ nodes: [UINode], screen: CGRect) -> UINode? {
        let skip = ignored(nodes, screen: screen)
        for (i, n) in nodes.enumerated() {
            let cls = ScreenModel.short(n.cls)
            guard opaqueClasses.contains(cls) || (nodes.count == 1 && opaqueSingleNodeClasses.contains(cls)) else { continue }
            let box = n.bounds.intersection(screen)
            guard Double(box.area / screen.area) > maxOpaqueShare else { continue }
            let inside = nodes[(i + 1)...].prefix { $0.depth > n.depth }.filter { covers($0) && !skip($0) }.map { $0.bounds.intersection(box) }
            if Double(unionArea(inside) / box.area) < coverageMin { return n }
        }
        return nil
    }

    static func covers(_ n: UINode) -> Bool { labelled(n) || n.clickable }

    /// The items that become nodes (`ocr`, refs `o1`…, no click), in reading order: rows by vertical centre, then left
    /// to right. Dropped: low confidence, short text, centre inside a labelled tree node (the tree wins; containers and
    /// scroll bars never do), and the same text within `duplicateDistance` of such a label or an item already kept.
    public static func nodes(_ items: [OCRItem], tree: [UINode]) -> [UINode] {
        let skip = ignored(tree, screen: extent(tree)), labels = tree.filter { labelled($0) && !skip($0) }
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
