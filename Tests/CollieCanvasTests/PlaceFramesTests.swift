import Foundation
import Testing
import CollieCanvas

@Suite struct PlaceFramesTests {
    @Test func placementFromEvent() {
        let a = UUID(), b = UUID(), m = UUID()
        let rel = [a: CGRect(x: 0, y: 0, width: 640, height: 400), b: CGRect(x: 680, y: 440, width: 640, height: 400)]
        // the app: the herd's corner at the clicked point
        let p = placeFrames(rel, anchor: CGPoint(x: 100, y: -50))
        #expect(p[a] == CGRect(x: 100, y: -50, width: 640, height: 400))
        #expect(p[b] == CGRect(x: 780, y: 390, width: 640, height: 400))
        // a Shepherd playing key `m`: it stays put, the rest goes 80 pt to the right of its frame
        let withShepherd = rel.merging([m: CGRect(x: 0, y: 0, width: 640, height: 400)]) { x, _ in x }
        let q = placeFrames(withShepherd, rightOf: CGRect(x: 1000, y: 200, width: 640, height: 400), skipping: m)
        #expect(q[m] == nil)
        #expect(q[a] == CGRect(x: 1720, y: 200, width: 640, height: 400))
        #expect(q[b] == CGRect(x: 2400, y: 640, width: 640, height: 400))
        #expect(placeFrames([:], anchor: .zero).isEmpty)
        // sizes clamped again (a terminal's size becomes its PTY's)
        let huge = placeFrames([a: CGRect(x: 0, y: 0, width: 900_000, height: 10)], anchor: .zero)
        #expect(huge[a] == CGRect(x: 0, y: 0, width: 4000, height: 200))
    }
}
