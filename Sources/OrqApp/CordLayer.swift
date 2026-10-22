import AppKit
import OrqCanvas
import OrqClient
import OrqCore
import OrqTheme

/// Cords between connected nodes: one cubic Bézier per connection, edge centre to edge centre. A cord is only
/// hit-testable near its curve, so the canvas and nodes underneath keep their mouse events. Click selects, ⌫ disconnects.
/// The permission itself lives in the daemon (`admin.connect`); this is only the view of it.
@MainActor final class CordLayer: NSView {
    private let client: DaemonClient
    private let canvas: CanvasState
    private(set) var selected: Connection?
    /// A cord being dragged out of a node handle (view coordinates).
    var pending: (from: CGPoint, to: CGPoint)? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(client: DaemonClient, canvas: CanvasState) {
        self.client = client; self.canvas = canvas
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Reads connections, frames, offset and zoom (call from an observation-tracked `sync`).
    func update() {
        _ = client.connections; _ = client.terminals; _ = client.panels; _ = client.currentFloor; _ = canvas.frames; _ = canvas.offset; _ = canvas.zoom
        if let s = selected, !client.connections.contains(s) { selected = nil }
        needsDisplay = true
    }

    private func screenFrame(_ id: UUID) -> CGRect? {
        guard let f = canvas.frames[id] else { return nil }
        let o = canvas.toScreen(f.origin)
        return CGRect(x: o.x, y: o.y, width: f.width * canvas.zoom, height: f.height * canvas.zoom)
    }

    /// Facing edges' centres: left-right when the nodes are apart horizontally, top-bottom otherwise.
    static func curve(_ a: CGRect, _ b: CGRect) -> (p0: CGPoint, c0: CGPoint, c1: CGPoint, p1: CGPoint) {
        let horizontal = a.maxX <= b.minX || b.maxX <= a.minX || abs(a.midX - b.midX) >= abs(a.midY - b.midY)
        let p0: CGPoint, p1: CGPoint, k: CGPoint
        if horizontal {
            let right = a.midX <= b.midX
            p0 = CGPoint(x: right ? a.maxX : a.minX, y: a.midY); p1 = CGPoint(x: right ? b.minX : b.maxX, y: b.midY)
            k = CGPoint(x: max(abs(p1.x - p0.x) / 2, 40) * (right ? 1 : -1), y: 0)
        } else {
            let down = a.midY <= b.midY
            p0 = CGPoint(x: a.midX, y: down ? a.maxY : a.minY); p1 = CGPoint(x: b.midX, y: down ? b.minY : b.maxY)
            k = CGPoint(x: 0, y: max(abs(p1.y - p0.y) / 2, 40) * (down ? 1 : -1))
        }
        return (p0, CGPoint(x: p0.x + k.x, y: p0.y + k.y), CGPoint(x: p1.x - k.x, y: p1.y - k.y), p1)
    }

    /// Both ends (terminals or canvas panels) on the current floor.
    private func shown(_ c: Connection) -> Bool {
        let f = client.currentFloor
        let ids = Set(visibleTerminals(client.terminals, floor: f).map(\.id))
            .union(visiblePanels(client.panels, floor: f).filter { $0.placement == .canvas }.map(\.id))
        return ids.contains(c.a) && ids.contains(c.b)
    }

    private func curve(_ c: Connection) -> (p0: CGPoint, c0: CGPoint, c1: CGPoint, p1: CGPoint)? {
        guard shown(c), let a = screenFrame(c.a), let b = screenFrame(c.b) else { return nil }
        return Self.curve(a, b)
    }

    private static func point(_ q: (p0: CGPoint, c0: CGPoint, c1: CGPoint, p1: CGPoint), _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        func m(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat { u*u*u*a + 3*u*u*t*b + 3*u*t*t*c + t*t*t*d }
        return CGPoint(x: m(q.p0.x, q.c0.x, q.c1.x, q.p1.x), y: m(q.p0.y, q.c0.y, q.c1.y, q.p1.y))
    }

    private func cord(at p: CGPoint) -> Connection? {
        client.connections.first { c in
            guard let q = curve(c) else { return false }
            return (0...40).contains { Self.point(q, CGFloat($0) / 40).distance(to: p) < 8 }   // ponytail: sampled, not exact
        }
    }

    override func hitTest(_ p: NSPoint) -> NSView? { cord(at: convert(p, from: superview)) != nil ? self : nil }

    override func mouseDown(with e: NSEvent) {
        selected = cord(at: convert(e.locationInWindow, from: nil))
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool { selected = nil; needsDisplay = true; return true }

    override func keyDown(with e: NSEvent) {
        guard e.keyCode == 51 || e.keyCode == 117, let s = selected,   // ⌫ / forward delete
              let a = client.nodeName(s.a), let b = client.nodeName(s.b) else { return super.keyDown(with: e) }
        selected = nil
        Task { do { try await client.disconnect(a, b) } catch { Log.canvas.error("disconnect \(a)-\(b): \(error)") } }
    }

    override func draw(_ dirtyRect: NSRect) {
        for c in client.connections {
            guard let q = curve(c) else { continue }
            let path = NSBezierPath()
            path.move(to: q.p0); path.curve(to: q.p1, controlPoint1: q.c0, controlPoint2: q.c1)
            let style = CordStyle(toPanel: client.panels.contains { $0.id == c.a || $0.id == c.b }, selected: c == selected)
            (style.toPanel ? OrqColor.secondary : OrqColor.accent).setStroke()
            path.lineWidth = style.width
            path.lineCapStyle = .round
            if !style.dash.isEmpty { path.setLineDash(style.dash, count: style.dash.count, phase: 0) }
            path.stroke()
        }
        if let d = pending {
            let path = NSBezierPath()
            path.move(to: d.from); path.line(to: d.to)
            OrqColor.accent.setStroke()
            path.setLineDash([4, 4], count: 2, phase: 0)
            path.stroke()
        }
    }
}

private extension CGPoint { func distance(to o: CGPoint) -> CGFloat { hypot(x - o.x, y - o.y) } }
