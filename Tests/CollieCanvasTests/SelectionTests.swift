import CoreGraphics
import Foundation
import Testing
@testable import CollieCanvas

@Suite struct SelectionTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test func clickReplacesEverything() {
        #expect(Selecting.click(b) == SelectionState(ids: [b], anchor: b))
    }

    @Test func toggleAddsThenRemovesAndMovesTheAnchor() {
        let s = Selecting.toggle(Selecting.click(a), b)
        #expect(s == SelectionState(ids: [a, b], anchor: b))
        #expect(Selecting.toggle(s, a).ids == [b])
    }

    @Test func extendAddsAndKeepsTheAnchor() {
        let s = Selecting.extend(Selecting.click(a), c)
        #expect(s == SelectionState(ids: [a, c], anchor: a))
        #expect(Selecting.extend(SelectionState(), b) == SelectionState(ids: [b], anchor: b))
    }

    @Test func rangeCoversAnchorToTargetInEitherDirection() {
        let order = [a, b, c, d]
        let down = Selecting.range(Selecting.click(b), to: d, in: order)
        #expect(down.ids == [b, c, d] && down.anchor == b)
        #expect(Selecting.range(Selecting.click(c), to: a, in: order).ids == [a, b, c])
        // ⇧ again re-ranges from the same anchor, replacing the old range
        #expect(Selecting.range(down, to: a, in: order).ids == [a, b])
    }

    @Test func rangeWithoutUsableAnchorIsAClick() {
        let order = [a, b, c]
        #expect(Selecting.range(SelectionState(), to: b, in: order) == Selecting.click(b))
        #expect(Selecting.range(Selecting.click(d), to: b, in: order) == Selecting.click(b))   // anchor not in the rows
    }

    @Test func marqueeTakesShownNodesThatTouchTheRect() {
        let frames = [a: CGRect(x: 0, y: 0, width: 100, height: 100), b: CGRect(x: 200, y: 0, width: 100, height: 100),
                      c: CGRect(x: 0, y: 500, width: 100, height: 100)]
        let r = CGRect(x: 50, y: 50, width: 200, height: 20)
        #expect(Selecting.marquee(r, frames: frames, shown: nil, base: nil).ids == [a, b])
        #expect(Selecting.marquee(r, frames: frames, shown: [a, c], base: nil).ids == [a])   // b is another paddock's
        #expect(Selecting.marquee(.zero.offsetBy(dx: 900, dy: 900), frames: frames, shown: nil, base: nil).ids.isEmpty)
    }

    @Test func marqueeOnTopOfTheBaseKeepsIt() {
        let frames = [a: CGRect(x: 0, y: 0, width: 10, height: 10), b: CGRect(x: 100, y: 0, width: 10, height: 10)]
        let s = Selecting.marquee(CGRect(x: 0, y: 0, width: 20, height: 20), frames: frames, shown: nil, base: Selecting.click(c))
        #expect(s.ids == [a, c] && s.anchor == c)
    }

    @Test func contextClickKeepsASelectedItemsSelectionAndSwitchesOtherwise() {
        let s = SelectionState(ids: [a, b], anchor: a)
        #expect(Selecting.contextClick(s, b) == s)
        #expect(Selecting.contextClick(s, c) == Selecting.click(c))
        #expect(Selecting.contextClick(SelectionState(), c) == Selecting.click(c))
    }

    @Test func prunedDropsGoneItemsAndAnchor() {
        let s = Selecting.pruned(SelectionState(ids: [a, b], anchor: b), keeping: [a, c])
        #expect(s == SelectionState(ids: [a], anchor: nil))
    }

    @MainActor @Test func canvasStateMirrorsTheSelectionState() {
        let canvas = CanvasState()
        canvas.selectionState = SelectionState(ids: [a, b], anchor: b)
        #expect(canvas.selection == [a, b] && canvas.selectionAnchor == b)
        #expect(canvas.selectionState == SelectionState(ids: [a, b], anchor: b))
    }

    @MainActor @Test func moveTakesEverySelectedShownNodeAlongScaledByZoom() {
        let canvas = CanvasState()
        canvas.zoom = 2
        canvas.frames = [a: CGRect(x: 0, y: 0, width: 10, height: 10), b: CGRect(x: 50, y: 50, width: 10, height: 10),
                         c: CGRect(x: 90, y: 90, width: 10, height: 10)]
        canvas.shown = [a, b]
        canvas.move([a, b, c], by: CGSize(width: 20, height: -10))
        #expect(canvas.frames[a]?.origin == CGPoint(x: 10, y: -5))
        #expect(canvas.frames[b]?.origin == CGPoint(x: 60, y: 45))
        #expect(canvas.frames[c]?.origin == CGPoint(x: 90, y: 90))   // not on this canvas: left where it was
    }
}
