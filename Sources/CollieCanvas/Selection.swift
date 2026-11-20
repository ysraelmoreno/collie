import CoreGraphics
import Foundation
import CollieCore

/// A selection and its anchor (the last item clicked without Shift: the start of a Shift range).
/// One of these lives in `CanvasState`; the canvas and the side panel both read and write it.
public struct SelectionState: Equatable, Sendable {
    public var ids: Set<UUID>
    public var anchor: UUID?
    public init(ids: Set<UUID> = [], anchor: UUID? = nil) { self.ids = ids; self.anchor = anchor }
}

/// Pure selection rules (Finder-like). The views only call these and store the result.
public enum Selecting {
    /// Plain click: just that item.
    public static func click(_ id: UUID) -> SelectionState { SelectionState(ids: [id], anchor: id) }

    /// ⌘-click: flips one item; it becomes the anchor.
    public static func toggle(_ s: SelectionState, _ id: UUID) -> SelectionState {
        var ids = s.ids
        if !ids.insert(id).inserted { ids.remove(id) }
        return SelectionState(ids: ids, anchor: id)
    }

    /// ⇧-click on the canvas (no order there): adds the item.
    public static func extend(_ s: SelectionState, _ id: UUID) -> SelectionState {
        SelectionState(ids: s.ids.union([id]), anchor: s.anchor ?? id)
    }

    /// ⇧-click in the side panel: everything between the anchor and `id` in `order` (the rows as shown).
    /// No usable anchor (none, or not in `order`): same as a click. The anchor stays, so ⇧ again re-ranges from it.
    public static func range(_ s: SelectionState, to id: UUID, in order: [UUID]) -> SelectionState {
        guard let a = s.anchor.flatMap(order.firstIndex(of:)), let b = order.firstIndex(of: id) else { return click(id) }
        return SelectionState(ids: Set(order[min(a, b)...max(a, b)]), anchor: s.anchor)
    }

    /// Dragging a rectangle on empty canvas: the shown nodes whose frame touches `rect` (canvas coordinates),
    /// on top of `base` when ⌘/⇧ was held at the start (nil: from scratch).
    public static func marquee(_ rect: CGRect, frames: [UUID: CGRect], shown: Set<UUID>?, base: SelectionState?) -> SelectionState {
        let hit = Set(frames.filter { (shown?.contains($0.key) ?? true) && $0.value.intersects(rect) }.keys)
        return SelectionState(ids: (base?.ids ?? []).union(hit), anchor: base?.anchor ?? hit.first)
    }

    /// Right-click: inside the selection it stays (the menu then acts on all of it); outside, it moves to that item.
    public static func contextClick(_ s: SelectionState, _ id: UUID) -> SelectionState { s.ids.contains(id) ? s : click(id) }

    /// Drops items that no longer exist.
    public static func pruned(_ s: SelectionState, keeping live: Set<UUID>) -> SelectionState {
        let ids = s.ids.intersection(live)
        return SelectionState(ids: ids, anchor: s.anchor.flatMap { live.contains($0) ? $0 : nil })
    }
}
