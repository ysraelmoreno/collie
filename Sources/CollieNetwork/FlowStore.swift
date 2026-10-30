import Foundation

/// Applies addon events to an in-memory ring of flows (oldest evicted past `capacity`).
public struct FlowStore: Sendable {
    public let capacity: Int
    /// Device serial stamped on new flows (the addon does not know which emulator it serves).
    public var serial: String?
    private var order: [String] = []
    private var flows: [String: Flow] = [:]

    public init(capacity: Int = 2000, serial: String? = nil) {
        self.capacity = max(1, capacity)
        self.serial = serial
    }

    public var summaries: [FlowSummary] { order.compactMap { flows[$0]?.summary } }
    public func flow(_ id: String) -> Flow? { flows[id] }

    public mutating func clear() { order.removeAll(); flows.removeAll() }

    /// Returns the touched flow's summary, or nil when the event refers to an unknown/evicted flow.
    @discardableResult
    public mutating func apply(_ event: FlowEvent) -> FlowSummary? {
        switch event {
        case .request(let r):
            if flows[r.id] == nil {
                order.append(r.id)
                // ponytail: O(n) removeFirst, fine at 2000; swap for a deque if capacity grows a lot.
                if order.count > capacity { flows[order.removeFirst()] = nil }
            }
            flows[r.id] = Flow(
                id: r.id, serial: serial, started: r.ts, method: r.method, url: r.url, httpVersion: r.httpVersion,
                reqHeaders: r.headers, reqBody: r.body, status: nil, reason: nil, resHeaders: [], resBody: nil,
                timing: FlowTiming(start: r.ts), state: .pending, tls: r.tls)
        case .response(let r):
            guard var f = flows[r.id] else { return nil }
            f.status = r.status; f.reason = r.reason; f.resHeaders = r.headers; f.resBody = r.body
            f.timing.ttfb = r.ttfb; f.timing.end = r.ts
            if f.state == .pending { f.state = .done }
            flows[r.id] = f
        case .error(let id, let ts, let message):
            guard var f = flows[id] else { return nil }
            if f.timing.end == nil { f.timing.end = ts }
            if f.state != .tunneled { f.state = .failed(message) }
            flows[id] = f
        case .tunneled(let id, let ts):
            guard var f = flows[id] else { return nil }
            if f.timing.end == nil { f.timing.end = ts }
            f.state = .tunneled
            flows[id] = f
        }
        return flows[event.id]?.summary
    }
}

extension FlowEvent {
    public var id: String {
        switch self {
        case .request(let r): r.id
        case .response(let r): r.id
        case .error(let id, _, _), .tunneled(let id, _): id
        }
    }
}
