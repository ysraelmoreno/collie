import Testing
import Foundation
import CoreGraphics
import CollieDevice
import CollieProtocol
@testable import CollieDaemonKit

private func node(_ ref: String, text: String = "", _ r: CGRect, clickable: Bool = false, depth: Int) -> UINode {
    UINode(ref: ref, cls: "android.view.View", text: text, desc: "", id: "", bounds: r, clickable: clickable, depth: depth)
}
private let full = CGRect(x: 0, y: 0, width: 1080, height: 2400)
/// A content view under the status bar: ~95 % of the screen.
private let content = CGRect(x: 0, y: 120, width: 1080, height: 2280)

/// Android's clickable root (it swallows touches), a toolbar with "Sair", a scrolling list and, apart, "Excluir conta".
private let screen: [UINode] = [
    node("e1", full, clickable: true, depth: 0),
    node("e2", content, depth: 1),
    node("e3", CGRect(x: 0, y: 120, width: 1080, height: 200), depth: 2),
    node("e4", text: "Sair", CGRect(x: 900, y: 150, width: 160, height: 140), clickable: true, depth: 3),
    node("e5", CGRect(x: 0, y: 400, width: 1080, height: 1400), depth: 2),
    node("e6", text: "Item 1", CGRect(x: 0, y: 400, width: 1080, height: 200), depth: 3),
    node("e7", text: "Item 2", CGRect(x: 0, y: 600, width: 1080, height: 200), depth: 3),
    node("e8", text: "Excluir conta", CGRect(x: 340, y: 2000, width: 400, height: 100), depth: 2),
]

private func step(_ action: String, _ target: String) -> FlowPlan.Step { FlowPlan.Step(action: action, target: target) }

/// we2 (findings 4, 6 and 7 of `.collie/briefs/rev-device-flows-onda-d.md`): a node of ≥ 90 % of the root lends no labels.
struct FlowRootFalsePositiveTests {
    @Test func scrollSwipeWithAClickableRootAndSairOnScreenIsNotRefused() {
        #expect(!FlowClassifier.destructive(step("swipe", "540,1500,540,500"), nodes: screen))
    }

    @Test func tapOnExcluirContaWithTheSameRootIsRefused() {
        #expect(FlowClassifier.destructive(step("tap", "540,2050"), nodes: screen))
    }

    @Test func tapOnSairItselfIsStillRefused() {
        #expect(FlowClassifier.destructive(step("tap", "980,220"), nodes: screen))
    }

    /// A leaf with no clickable ancestor under a ~95 % content view (not the root's bounds) inherits none of the screen.
    @Test func contentViewOfNinetyFivePercentLendsNoLabelsToALeafTap() {
        let nodes = [
            node("e1", full, depth: 0),
            node("e2", content, depth: 1),
            node("e3", text: "Olá", CGRect(x: 100, y: 1000, width: 300, height: 80), depth: 2),
            node("e4", text: "Sair", CGRect(x: 900, y: 150, width: 160, height: 140), depth: 2),
        ]
        #expect(FlowClassifier.labels(step("tap", "200,1040"), nodes: nodes).contains("Olá"))
        #expect(!FlowClassifier.destructive(step("tap", "200,1040"), nodes: nodes))
        #expect(FlowClassifier.destructive(step("tap", "980,220"), nodes: nodes))
    }

    @Test func panelClosedDropsFlowReadAt() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flowroot-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = DeviceService(root: dir, runDir: dir, adb: { nil }, wmDensity: nil, emit: { _, _, _ in })
        let id = UUID()
        await s.markRead(id)
        #expect(await s.flowReadAt[id] != nil)
        await s.panelClosed(id)
        #expect(await s.flowReadAt[id] == nil)
    }

    @Test func rotationWarningWithANonEmptyFolderCitesTheTruncation() throws {
        final class Lines: @unchecked Sendable {
            private let lock = NSLock(); private var all: [String] = []
            var lines: [String] { lock.withLock { all } }
            func add(_ s: String) { lock.withLock { all.append(s) } }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("flowrot-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: root) }
        let warnings = Lines()
        var l = FlowActionLog(paddock: root.appendingPathComponent("p"), flag: root.appendingPathComponent("daemon/enabled"))
        l.maxBytes = 300; l.warn = { warnings.add($0) }
        try l.setEnabled(true)
        let blocker = l.dir.appendingPathComponent("actions.1.jsonl")
        try fm.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker.appendingPathComponent("inside"))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        for _ in 0..<20 { try l.append(FlowAction(origin: "panel", action: "tap", target: "n"), now: t0) }
        #expect(!warnings.lines.isEmpty)
        #expect(warnings.lines.allSatisfy { $0.contains("failed") && $0.contains("truncated") })
    }
}

private extension DeviceService {
    func markRead(_ id: UUID) { flowReadAt[id] = ContinuousClock.now }
}
