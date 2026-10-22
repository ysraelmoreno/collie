// Coordinates: flipped, top-left origin (NSView with isFlipped = true).
// screen = (canvas - offset) * zoom; `offset` is the canvas point at the screen origin.
import CoreGraphics
import Foundation
import Observation
import CollieCore

@MainActor @Observable
public final class CanvasState {
    public static let zoomRange: ClosedRange<CGFloat> = 0.25...2.0
    public static let defaultTerminalSize = CGSize(width: 640, height: 400)

    public var offset: CGPoint = .zero
    public var zoom: CGFloat = 1
    public var frames: [UUID: CGRect] = [:]
    public var selection: Set<UUID> = []
    /// Nodes currently on the canvas (this floor's terminals, canvas panels). nil = every frame counts.
    /// Minimap and fit-all use only these: other floors and docked panels keep their frames but are not drawn.
    public var shown: Set<UUID>?
    public var shownFrames: [CGRect] { frames.filter { shown?.contains($0.key) ?? true }.map(\.value) }

    /// Frames asked for before the daemon event that makes the node live (click point of a new node); `place` consumes them.
    public private(set) var pendingFrames: [UUID: CGRect] = [:]

    public init() {}

    /// Already placed: overwrite. Otherwise remember it until `place` first sees the id.
    public func setFrame(_ r: CGRect, for id: UUID) {
        if frames[id] != nil { frames[id] = r } else { pendingFrames[id] = r }
    }

    /// First placement of a live node: its pending frame, else the next free grid cell.
    public func place(_ id: UUID, viewport: CGSize) {
        frames[id] = pendingFrames.removeValue(forKey: id) ?? placeNew(viewport: viewport)
    }

    public func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) * zoom, y: (p.y - offset.y) * zoom)
    }

    public func toCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / zoom + offset.x, y: p.y / zoom + offset.y)
    }

    /// Keeps the canvas point under `screenPoint` fixed.
    public func zoom(by factor: CGFloat, around screenPoint: CGPoint) {
        let c = toCanvas(screenPoint)
        zoom = min(max(zoom * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        offset = CGPoint(x: c.x - screenPoint.x / zoom, y: c.y - screenPoint.y / zoom)
    }

    /// Content follows the drag.
    public func pan(by screenDelta: CGSize) {
        offset = CGPoint(x: offset.x - screenDelta.width / zoom, y: offset.y - screenDelta.height / zoom)
    }

    private func visibleRect(_ viewport: CGSize) -> CGRect {
        CGRect(origin: offset, size: CGSize(width: viewport.width / zoom, height: viewport.height / zoom))
    }

    public func visibleNodes(viewport: CGSize, margin: CGFloat = 200) -> Set<UUID> {
        let r = visibleRect(viewport).insetBy(dx: -margin / zoom, dy: -margin / zoom)
        return Set(frames.filter { $0.value.intersects(r) }.keys)
    }

    /// First free cell of a grid laid over the visible area (step = size + 32, 16 pt inset), scanning row by row.
    /// A same-size frame blocks at most 4 cells, so 4·n + 1 cells always hold a free one; the last is the fallback.
    public func placeNew(size: CGSize = CanvasState.defaultTerminalSize, viewport: CGSize) -> CGRect {
        let v = visibleRect(viewport)
        let step = CGSize(width: size.width + 32, height: size.height + 32)
        let cols = max(1, Int(v.width / step.width))
        func cell(_ k: Int) -> CGRect {
            CGRect(x: v.minX + 16 + CGFloat(k % cols) * step.width, y: v.minY + 16 + CGFloat(k / cols) * step.height,
                   width: size.width, height: size.height)
        }
        let last = 4 * frames.count
        // ponytail: O(cells × frames) scan; fine for hundreds of nodes, use a spatial index past that
        return (0...last).lazy.map(cell).first { r in !self.frames.values.contains { $0.intersects(r) } } ?? cell(last)
    }

    public func fitAll(viewport: CGSize) {
        let rects = shownFrames
        guard let first = rects.first else { offset = .zero; zoom = 1; return }
        let u = rects.dropFirst().reduce(first) { $0.union($1) }
        let pad: CGFloat = 40
        let fit = min((viewport.width - 2 * pad) / max(u.width, 1), (viewport.height - 2 * pad) / max(u.height, 1))
        zoom = min(max(fit, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        offset = CGPoint(x: u.midX - viewport.width / zoom / 2, y: u.midY - viewport.height / zoom / 2)
    }
}
