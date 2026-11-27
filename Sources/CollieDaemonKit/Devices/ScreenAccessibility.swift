import Foundation
import CollieDevice

/// `ACESSIBILIDADE: N sem nome, M alvos pequenos` on `device screen` (device flows d3), from the bounds, text and
/// description the tree already carries: a clickable control with no name, and a touch target under 48 dp (Android)
/// or 44 pt (iOS) on either side.
enum ScreenAccessibility {
    typealias Node = UINode

    enum Platform: Equatable, Sendable {
        /// `density`: pixels per dp (`wm density` / 160); nil: unknown, so target sizes are not judged.
        case android(density: Double?)
        /// The tree (AXe) is in points.
        case ios
    }

    /// "N sem nome, M alvos pequenos" (`device screen` prints it after `ACESSIBILIDADE: `); nil: nothing found.
    static func summary(_ nodes: [Node], platform: Platform) -> String? {
        let (unnamed, small) = findings(nodes, platform: platform)
        guard unnamed + small > 0 else { return nil }
        return "\(unnamed) sem nome, \(small) alvos pequenos"
    }

    static func findings(_ nodes: [Node], platform: Platform) -> (unnamed: Int, small: Int) {
        // A control is named by its own text/description or a descendant's (TalkBack and VoiceOver read the children).
        var named = Set<Int>()
        for (i, n) in nodes.enumerated() where !n.ocr && hasName(n) {
            var at: Int? = i, hops = 0
            while let a = at, hops <= nodes.count { named.insert(a); at = nodes[a].parent; hops += 1 }
        }
        let minSide: Double? = switch platform {
        case .android(let d): d.map { 48 * $0 }
        case .ios: 44
        }
        var unnamed = 0, small = 0
        for (i, n) in nodes.enumerated() where n.clickable && !n.ocr {
            if !named.contains(i) { unnamed += 1 }
            if let minSide, !n.bounds.isEmpty, min(n.bounds.width, n.bounds.height) < minSide - 0.5 { small += 1 }
        }
        return (unnamed, small)
    }

    /// `wm density` output ("Physical density: 420", an "Override density: 480" line wins) as pixels per dp.
    static func density(wm: String) -> Double? {
        func value(_ prefix: String) -> Double? {
            wm.split(whereSeparator: \.isNewline).first { $0.hasPrefix(prefix) }
                .flatMap { $0.split(separator: ":").last }.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        return (value("Override density") ?? value("Physical density")).map { $0 / 160 }
    }

    private static func hasName(_ n: Node) -> Bool {
        !(n.text + n.desc).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
