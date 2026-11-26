import Testing
import CollieCore
import CollieCanvas

@Suite(.canvasEN) struct CanvasEnglishTests {
    @Test func nodeStatusText() {
        #expect(NodeStatus(badge: .working, exitCode: nil).text == "working")
        #expect(NodeStatus(badge: .attention, exitCode: nil).text == "waiting for you")
        #expect(NodeStatus(badge: .stopped, exitCode: nil).text == "ended")
        #expect(NodeStatus(badge: .working, exitCode: 2).text == "ended (code 2)")
    }
}
