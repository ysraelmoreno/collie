import SwiftUI
import Testing
@testable import CollieTheme

@Test func herdGeometry() {
    let stroked = CollieMark.arcPath(in: CGRect(x: 0, y: 0, width: 200, height: 200)).strokedPath(StrokeStyle(lineWidth: 18, lineCap: .round))
    #expect(stroked.contains(CGPoint(x: 36, y: 100)), "leftmost point of the arc")
    #expect(!stroked.contains(CGPoint(x: 100, y: 100)), "the centre is open")
    #expect(!stroked.contains(CGPoint(x: 164, y: 100)), "the C opens to the right")
}
