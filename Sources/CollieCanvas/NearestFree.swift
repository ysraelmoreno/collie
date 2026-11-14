import CoreGraphics

/// The free frame of `size` closest to `near` (a creator's frame): candidates sit on rings around `near`
/// (steps of size + gap), the one clear of every `avoiding` frame (with `gap` between) and nearest to `near`'s center wins.
/// Ties break by scan order, so the result is deterministic. Always ends: past the outermost frame a ring is free.
public func nearestFreeFrame(size: CGSize, near: CGRect, avoiding: [CGRect], gap: CGFloat = 32) -> CGRect {
    let step = CGSize(width: size.width + gap, height: size.height + gap)
    // ponytail: rings of step, not pixel-exact; O(rings² × frames), fine for hundreds of nodes
    func candidate(_ i: Int, _ j: Int) -> CGRect {
        // ring 0 sits beside `near` (its own size + gap), later rings add whole steps
        CGRect(x: near.midX - size.width / 2 + CGFloat(i) * step.width + sign(i) * (near.width - size.width) / 2,
               y: near.midY - size.height / 2 + CGFloat(j) * step.height + sign(j) * (near.height - size.height) / 2,
               width: size.width, height: size.height)
    }
    func sign(_ v: Int) -> CGFloat { v > 0 ? 1 : v < 0 ? -1 : 0 }
    func free(_ r: CGRect) -> Bool { !avoiding.contains { $0.intersects(r.insetBy(dx: -gap / 2, dy: -gap / 2)) } }
    func dist(_ r: CGRect) -> CGFloat { hypot(r.midX - near.midX, r.midY - near.midY) }
    var ring = 1
    while true {
        let cells = (-ring...ring).flatMap { i in (-ring...ring).map { j in (i, j) } }
            .filter { max(abs($0.0), abs($0.1)) == ring }.map { candidate($0.0, $0.1) }.filter(free)
        if let best = cells.min(by: { dist($0) < dist($1) }) { return best }
        ring += 1
    }
}
