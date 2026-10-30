import Foundation

/// Applies addon events to an in-memory ring of flows: oldest evicted past `capacity` flows or past `byteBudget` bytes
/// of captured bodies (the newest flow always stays, even alone over budget).
public struct FlowStore: Sendable {
    public let capacity: Int
    public let byteBudget: Int
    /// Body bytes held (request + response `data`, as captured).
    public private(set) var bytes = 0
    /// Device serial stamped on new flows (the addon does not know which emulator it serves).
    public var serial: String?
    private var order: [String] = []
    private var flows: [String: Flow] = [:]

    public init(capacity: Int = 2000, byteBudget: Int = 256 * 1024 * 1024, serial: String? = nil) {
        self.capacity = max(1, capacity)
        self.byteBudget = max(0, byteBudget)
        self.serial = serial
    }

    public var summaries: [FlowSummary] { order.compactMap { flows[$0]?.summary } }
    public func flow(_ id: String) -> Flow? { flows[id] }

    public mutating func clear() { order.removeAll(); flows.removeAll(); bytes = 0 }

    /// Returns the touched flow's summary, or nil when the event refers to an unknown/evicted flow.
    @discardableResult
    public mutating func apply(_ event: FlowEvent) -> FlowSummary? {
        let before = flows[event.id].map(Self.size) ?? 0
        defer { evict(keeping: event.id) }
        switch event {
        case .request(let r):
            if flows[r.id] == nil { order.append(r.id) }
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
        bytes += (flows[event.id].map(Self.size) ?? 0) - before
        return flows[event.id]?.summary
    }

    private static func size(_ f: Flow) -> Int { (f.reqBody?.data.count ?? 0) + (f.resBody?.data.count ?? 0) }

    /// Drops the oldest flows (never `id`, the one just touched) until both limits hold.
    // ponytail: O(n) removeFirst/firstIndex, fine at 2000; a deque if capacity grows a lot.
    private mutating func evict(keeping id: String) {
        while order.count > capacity || (bytes > byteBudget && order.count > 1) {
            guard let i = order.firstIndex(where: { $0 != id }) else { return }
            if let f = flows.removeValue(forKey: order.remove(at: i)) { bytes -= Self.size(f) }
        }
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
