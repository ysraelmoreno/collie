import Foundation
import CoreGraphics

/// Compacts `axe describe-ui` JSON (a one-element array holding the root `Application` element,
/// children nested under `children`, `frame` in points) into the same `UINode`s as `UITree`.
public enum AXeTree {
    private static let clickableTypes: Set<String> = ["Button", "Link", "Switch", "TextField", "SecureTextField",
                                                      "SearchField", "Cell", "Tab", "Slider", "Stepper", "Toggle"]
    private static let scrollTypes: Set<String> = ["ScrollView", "ScrollArea", "Table", "CollectionView"]
    private static let toggleTypes: Set<String> = ["Switch", "Toggle", "CheckBox"]

    public static func parse(_ json: Data, cap: Int = 2000) -> (nodes: [UINode], truncated: Bool, screen: CGSize?) {
        guard let any = try? JSONSerialization.jsonObject(with: json) else { return ([], false, nil) }
        let roots = (any as? [[String: Any]]) ?? (any as? [String: Any]).map { [$0] } ?? []
        var nodes: [UINode] = []
        var truncated = false
        func walk(_ e: [String: Any], _ depth: Int) {
            if truncated { return }
            let label = (e["AXLabel"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let value = (e["AXValue"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let id = e["AXUniqueId"] as? String ?? ""
            let type = e["type"] as? String ?? ""
            let enabled = e["enabled"] as? Bool != false
            let clickable = enabled && clickableTypes.contains(type)
            let scrollable = scrollTypes.contains(type)
            let traits = (e["traits"] as? [String] ?? []).map { $0.lowercased() }
            if !label.isEmpty || !value.isEmpty || !id.isEmpty || clickable || scrollable {
                if nodes.count >= cap { truncated = true; return }
                // ponytail: label goes in `text` (UITree.lines prefers it); AXValue (slider %, field content) in `desc`.
                nodes.append(UINode(ref: "e\(nodes.count + 1)", cls: type, text: label, desc: value, id: id,
                                    bounds: rect(e["frame"]), clickable: clickable, depth: depth,
                                    selected: traits.contains("selected"), checked: toggleTypes.contains(type) && value == "1",
                                    enabled: enabled, focused: traits.contains("focused"), scrollable: scrollable))
            }
            for c in e["children"] as? [[String: Any]] ?? [] { walk(c, depth + 1) }
        }
        for r in roots { walk(r, 0) }
        let f = roots.first.map { rect($0["frame"]) }
        return (UITree.linkParents(nodes), truncated, f.map { CGSize(width: $0.width, height: $0.height) })
    }

    private static func rect(_ v: Any?) -> CGRect {
        guard let f = v as? [String: Any] else { return .zero }
        func n(_ k: String) -> Double { (f[k] as? NSNumber)?.doubleValue ?? 0 }
        return CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height"))
    }
}
