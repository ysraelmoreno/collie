import Testing
import Foundation
import CollieCore
@testable import CollieClient

@MainActor @Suite(.serialized) struct NodeLifecycleTests {
    private func firstFrame(_ s: TerminalStream) async -> StreamFrame? {
        let watchdog = Task { try? await Task.sleep(for: .seconds(10)); s.close() }   // never hang the suite
        defer { watchdog.cancel() }
        var it = s.frames.makeAsyncIterator()
        return await it.next()
    }

    private func isReplay(_ f: StreamFrame?) -> Bool { if case .replay? = f { true } else { false } }

    @Test func offscreenNodeDetachesStream() async throws {
        let d = Collied(); defer { d.cleanup() }
        try await d.start()
        let c = DaemonClient(paths: d.paths); c.start(); defer { c.stop() }
        #expect(await poll(5) { c.state == .connected })
        let id = try await c.spawn(name: "A", preset: .custom, command: d.cmd("exec sleep 300"), cwd: "/tmp", shepherd: false)

        let n = NodeController(id: id, client: c)
        n.setVisible(true)
        let first = try #require(n.stream)
        n.setVisible(true)   // idempotent
        #expect(n.stream === first)
        #expect(isReplay(await firstFrame(first)))

        n.setVisible(false)
        #expect(n.streamOpen == false)
        #expect(n.stream == nil)

        n.setVisible(true)
        #expect(n.streamOpen)
        let again = try #require(n.stream)
        #expect(again !== first)
        #expect(isReplay(await firstFrame(again)))
        n.close()
    }

    @Test func closingNodeReleasesStream() async throws {
        let d = Collied(); defer { d.cleanup() }
        try await d.start()
        let c = DaemonClient(paths: d.paths); c.start(); defer { c.stop() }
        #expect(await poll(5) { c.state == .connected })
        let id = try await c.spawn(name: "A", preset: .custom, command: d.cmd("exec sleep 300"), cwd: "/tmp", shepherd: false)

        let n = NodeController(id: id, client: c)
        n.setVisible(true)
        weak var weakStream = n.stream
        #expect(weakStream != nil)
        n.close()
        #expect(weakStream == nil)
        #expect(n.streamOpen == false)
        n.setVisible(true)   // a closed node stays closed
        #expect(n.streamOpen == false)
    }

    @Test func removedTerminalClosesNode() async throws {
        let d = Collied(); defer { d.cleanup() }
        try await d.start()
        let c = DaemonClient(paths: d.paths); c.start(); defer { c.stop() }
        #expect(await poll(5) { c.state == .connected })
        let a = try await c.spawn(name: "A", preset: .custom, command: d.cmd("exec sleep 300"), cwd: "/tmp", shepherd: false)
        let b = try await c.spawn(name: "B", preset: .custom, command: d.cmd("exec sleep 300"), cwd: "/tmp", shepherd: false)
        #expect(await poll(2) { c.terminals.count == 2 })

        var nodes: [UUID: NodeController] = [:]
        NodeController.sync(&nodes, terminals: c.terminals.map(\.id), visible: [a], client: c)
        #expect(Set(nodes.keys) == [a, b])
        #expect(nodes[a]?.streamOpen == true)
        #expect(nodes[b]?.streamOpen == false)
        weak var weakStream = nodes[a]?.stream

        try await c.kill("A")
        #expect(await poll(2) { c.terminals.map(\.id) == [b] })
        NodeController.sync(&nodes, terminals: c.terminals.map(\.id), visible: [a, b], client: c)
        #expect(Set(nodes.keys) == [b])
        #expect(weakStream == nil)
        #expect(nodes[b]?.streamOpen == true)
        for n in nodes.values { n.close() }
    }
}
