import Foundation
import os

/// One canvas node's stream lifecycle: a stream is open only while the node is visible. No AppKit.
@MainActor public final class NodeController {
    static let log = Logger(subsystem: "dev.orq.app", category: "node")

    public let id: UUID
    private let client: DaemonClient
    public private(set) var stream: TerminalStream? { didSet { onStreamChange?(stream) } }
    public var streamOpen: Bool { stream != nil }
    /// The view re-subscribes to `stream.frames` on every change (nil = unmount).
    public var onStreamChange: ((TerminalStream?) -> Void)?
    private var closed = false

    public init(id: UUID, client: DaemonClient) { self.id = id; self.client = client }

    /// true attaches (idempotent); false closes and drops the stream.
    public func setVisible(_ v: Bool) {
        if v {
            guard stream == nil, !closed else { return }
            Self.log.debug("attach \(self.id, privacy: .public)")
            stream = client.attach(id)
        } else if let s = stream {
            Self.log.debug("detach \(self.id, privacy: .public)")
            s.close()
            stream = nil
        }
    }

    /// Final: the node never reattaches.
    public func close() { setVisible(false); closed = true; onStreamChange = nil }

    /// Reconciles `nodes` with the daemon's terminals: new ids get a controller, removed ones are closed and
    /// dropped, and each stream is open iff its id is in `visible`.
    public static func sync(_ nodes: inout [UUID: NodeController], terminals: [UUID], visible: Set<UUID>, client: DaemonClient) {
        let ids = Set(terminals)
        for (id, n) in nodes where !ids.contains(id) { n.close(); nodes[id] = nil }
        for id in terminals {
            let n = nodes[id] ?? NodeController(id: id, client: client)
            nodes[id] = n
            n.setVisible(visible.contains(id))
        }
    }
}
