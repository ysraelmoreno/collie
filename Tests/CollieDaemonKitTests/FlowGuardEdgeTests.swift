import Testing
import Foundation
import CoreGraphics
import CollieDevice
import CollieProtocol
@testable import CollieDaemonKit

/// A uiautomator dump read as the device reads it (`UITree.parse`: unlabelled, non-clickable containers dropped).
private func dump(_ body: String) -> [UINode] {
    UITree.parse(Data(#"<?xml version="1.0" encoding="UTF-8"?><hierarchy rotation="0">\#(body)</hierarchy>"#.utf8)).nodes
}
private func n(_ cls: String, text: String = "", clickable: Bool = false, _ bounds: String, _ children: String = "") -> String {
    #"<node index="0" text="\#(text)" resource-id="" class="android.\#(cls)" content-desc="" clickable="\#(clickable)" bounds="\#(bounds)">\#(children)</node>"#
}
private func step(_ action: String, _ target: String) -> FlowPlan.Step { FlowPlan.Step(action: action, target: target) }

/// A confirmation overlay (clickable, full screen, `onClick` deletes) under the dropped root FrameLayout and a dropped
/// container, with "Excluir conta" in a non-clickable child.
private let overlay = dump(n("widget.FrameLayout", "[0,0][1080,2400]",
    n("widget.LinearLayout", "[0,0][1080,2400]",
      n("view.View", clickable: true, "[0,0][1080,2400]",
        n("widget.TextView", text: "Excluir conta", "[340,1100][740,1200]")))))

/// Android's clickable root (depth 0), a toolbar with "Sair", a list and, apart, "Excluir conta".
private let androidRoot = dump(n("widget.FrameLayout", clickable: true, "[0,0][1080,2400]",
    n("widget.LinearLayout", "[0,120][1080,2400]",
      n("widget.Button", text: "Sair", clickable: true, "[900,150][1060,290]")
      + n("widget.TextView", text: "Item 1", "[0,400][1080,600]")
      + n("widget.TextView", text: "Excluir conta", "[340,2000][740,2100]"))))

/// wf3 (findings 3, 4 and 5 of `.collie/briefs/rev-device-flows-onda-e.md`).
struct FlowGuardEdgeTests {
    @Test func theOverlayFixtureIsTheParsersOwn() {
        #expect(overlay.count == 2)                          // root FrameLayout and LinearLayout dropped
        #expect(overlay[0].clickable && overlay[0].depth == 2 && overlay[0].parent == nil)
    }

    @Test func tapOutsideExcluirContaInsideAFullScreenClickableOverlayIsRefused() {
        #expect(FlowClassifier.destructive(step("tap", "540,300"), nodes: overlay))
        #expect(throws: ProtocolError.self) { try FlowClassifier.guardCheck(step("tap", "540,300"), nodes: overlay, touching: nil) }
    }

    @Test func scrollSwipeOnAndroidsClickableRootWithSairIsNotRefused() {
        #expect(androidRoot[0].clickable && androidRoot[0].depth == 0)
        #expect(!FlowClassifier.destructive(step("swipe", "540,1500,540,500"), nodes: androidRoot))
    }

    @Test func tapOnExcluirContaUnderAndroidsClickableRootIsRefused() {
        #expect(FlowClassifier.destructive(step("tap", "540,2050"), nodes: androidRoot))
    }

    /// wf2's `refTolerance` (8): a node that moved 8 px on every edge is still the node; 20 px is another screen.
    @Test func refoundToleratesEightPixelsButNotTwenty() {
        let a = androidRoot[1]
        func moved(_ d: CGFloat) -> UINode { var m = a; m.bounds = a.bounds.offsetBy(dx: d, dy: -d); return m }
        #expect(FlowClassifier.refound(a, in: [moved(8)])?.ref == a.ref)
        #expect(FlowClassifier.refound(a, in: [moved(-8)]) != nil)
        #expect(FlowClassifier.refound(a, in: [moved(20)]) == nil)
        #expect(FlowClassifier.refound(a, in: [moved(-20)]) == nil)
    }

    /// The hangup test's ceiling: a `wait` never signalled loses to the test's own signal instead of hanging.
    @Test func aHangupNeverSignalledFailsAtTheCeilingInsteadOfHanging() async {
        let gone = ClientHangup()
        let (s, k) = AsyncStream.makeStream(of: Void.self)
        k.yield()
        let r: Bool? = await race({ await gone.wait(); return true }, ceiling: { for await _ in s { return } })
        #expect(r == nil && !gone.isSet)
        gone.set()
        let (never, held) = AsyncStream.makeStream(of: Void.self)   // a ceiling never raised (`held` keeps it open)
        #expect(await race({ await gone.wait(); return true }, ceiling: { _ = held; for await _ in never { return } }) == true)
    }
}
