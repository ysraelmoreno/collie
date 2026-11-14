import Foundation
import Testing
import CollieCanvas

@Suite struct NearestFreeTests {
    let size = CGSize(width: 640, height: 400)
    let me = CGRect(x: 0, y: 0, width: 640, height: 400)

    @Test func emptyCanvasGoesBesideCreator() {
        let r = nearestFreeFrame(size: size, near: me, avoiding: [me])
        #expect(r == CGRect(x: 672, y: 0, width: 640, height: 400) || r == CGRect(x: 0, y: 432, width: 640, height: 400)
                || r == CGRect(x: -672, y: 0, width: 640, height: 400) || r == CGRect(x: 0, y: -432, width: 640, height: 400))
        #expect(!r.intersects(me))
    }

    @Test func occupiedSideFallsToNextClosest() {
        let right = CGRect(x: 672, y: 0, width: 640, height: 400)
        let r = nearestFreeFrame(size: size, near: me, avoiding: [me, right])
        #expect(!r.intersects(me) && !r.intersects(right))
        #expect(hypot(r.midX - me.midX, r.midY - me.midY) < 1000)   // still next door
    }

    @Test func surroundedGoesOutsideTheRing() {
        let ring = (-1...1).flatMap { i in (-1...1).map { j in CGRect(x: CGFloat(i) * 672, y: CGFloat(j) * 432, width: 640, height: 400) } }
        let r = nearestFreeFrame(size: size, near: me, avoiding: ring)
        #expect(ring.allSatisfy { !$0.intersects(r) })
    }

    @Test func neverOverlapsAndKeepsGap() {
        var taken = [me]
        for _ in 0..<25 {
            let r = nearestFreeFrame(size: size, near: me, avoiding: taken)
            #expect(taken.allSatisfy { !$0.insetBy(dx: -16, dy: -16).intersects(r) })
            taken.append(r)
        }
    }

    @Test func differentSizeCreator() {
        let big = CGRect(x: 100, y: 100, width: 1100, height: 720)
        let r = nearestFreeFrame(size: size, near: big, avoiding: [big])
        #expect(!r.intersects(big))
        #expect(r.size == size)
    }
}
