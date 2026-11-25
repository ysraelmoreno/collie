import Foundation
import Observation
import CollieCore
import CollieProtocol

/// One line of `work.history` (`id,title,openedAt,closedAt,stopReason,stopDetail,done,total,deferred,durationSeconds`). Tolerant:
/// `stopReason` stays the daemon's raw text (a code this app does not know is still a row), a missing count is 0.
public struct HistoryEntry: Decodable, Sendable, Equatable {
    public var id: String, title: String
    public var openedAt: Date?, closedAt: Date
    public var stopReason: String?
    /// A5: the stop's detail, for `WorkLoopState.Stop.finishes` (the engine's one rule of "finished").
    public var stopDetail: String?
    public var done: Int, total: Int, deferred: Int, durationSeconds: Int
    public init(id: String, title: String, openedAt: Date? = nil, closedAt: Date, stopReason: String? = nil,
                done: Int = 0, total: Int = 0, deferred: Int = 0, durationSeconds: Int = 0, stopDetail: String? = nil) {
        self.id = id; self.title = title; self.openedAt = openedAt; self.closedAt = closedAt; self.stopReason = stopReason; self.stopDetail = stopDetail
        self.done = done; self.total = total; self.deferred = deferred; self.durationSeconds = durationSeconds
    }
    private enum K: String, CodingKey { case id, title, openedAt, closedAt, stopReason, stopDetail, done, total, deferred, durationSeconds }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id); title = (try? c.decode(String.self, forKey: .title)) ?? ""
        closedAt = try c.decode(Date.self, forKey: .closedAt)
        openedAt = try? c.decode(Date.self, forKey: .openedAt)
        stopReason = try? c.decode(String.self, forKey: .stopReason); stopDetail = try? c.decode(String.self, forKey: .stopDetail)
        done = (try? c.decode(Int.self, forKey: .done)) ?? 0; total = (try? c.decode(Int.self, forKey: .total)) ?? 0
        deferred = (try? c.decode(Int.self, forKey: .deferred)) ?? 0
        durationSeconds = (try? c.decode(Int.self, forKey: .durationSeconds)) ?? 0
    }
}

/// What the Trilho panel shows of the followed paddock: its active work (the loop inside it) and its last closed works.
/// Kept fresh by the daemon's `work` event (`WorkspaceEvent.work`, on `ui.events`: never a timer): each one of this
/// paddock re-reads `work.status`, at most one read in flight (a burst meanwhile is one more read). The history is read
/// again on `follow`, when an active work of the paddock leaves the list (`work done`, removed), when a loop ends, and
/// on an event of a work that is not active (M7.3: a work closed under a running loop, whose summary is written when
/// the loop ends, after the close: the row then has the summary, not the reconstructed one).
/// `follow` (a paddock switch) starts over. A daemon that fails leaves it empty, never throws.
@MainActor @Observable public final class WorkFeed {
    public private(set) var work: Work?
    public private(set) var history: [HistoryEntry] = []
    public nonisolated static let historyLimit = 20
    /// What is asked and kept: one more than shown, so the panel knows older works exist ("mais antigos no Work").
    public nonisolated static let historyFetch = historyLimit + 1

    public typealias Call = @MainActor (_ command: String, _ args: [String: JSONValue], _ timeout: Double) async throws -> JSONValue
    @ObservationIgnored public var call: Call?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var followed: (id: UUID?, name: String?) = (nil, nil)
    /// A read runs; `again`: an event came meanwhile; `needHistory`: the next read also reads the history.
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var needHistory = false
    /// The paddock's active works and those with a running loop, at the last read (what tells a close or a loop's end).
    @ObservationIgnored private var active: Set<UUID> = []
    @ObservationIgnored private var running: Set<UUID> = []
    /// Works the daemon told about since the last read (M7.3: one not active after it means a closed work changed).
    @ObservationIgnored private var touched: Set<UUID> = []
    @ObservationIgnored private var idle: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Follows `paddock` (nil: the Pasto, which has no work to show): drops what the last one left and loads again.
    public func follow(paddock: UUID?, name: String?) {
        followed = (paddock, name); generation += 1
        work = nil; history = []; active = []; running = []; touched = []
        needHistory = true
        refresh()
    }
    /// Work `id` changed in `paddock` (the daemon's `work` event; nil: unknown, a removed work): re-read when it is ours.
    public func workChanged(paddock: UUID?, work id: UUID? = nil) {
        guard let mine = followed.id, paddock == nil || paddock == mine else { return }
        if let id { touched.insert(id) }
        refresh()
    }
    /// Returns once no read runs nor is due (tests count the daemon's calls after it, never after a clock).
    public func settled() async {
        guard busy else { return }
        await withCheckedContinuation { idle.append($0) }
    }
    /// Reads `work.status` again for the followed paddock (the daemon came back, a work changed): coalesced.
    public func refresh() {
        guard followed.id != nil else { return }
        again = true
        guard !busy else { return }
        busy = true
        Task { [weak self] in await self?.drain() }
    }

    /// One read at a time, as long as something asked for one. A `follow` during a read makes it read again (the
    /// generation tells): the old answer is dropped, never shown in the new paddock.
    private func drain() async {
        defer { busy = false; let w = idle; idle = []; w.forEach { $0.resume() } }
        while again {
            again = false
            let gen = generation
            guard let paddock = followed.id, let name = followed.name else { return }
            struct Status: Decodable { let works: [Work] }
            let seen = touched; touched = []
            let st = try? await ask("work.status", ["all": .bool(true)], 30)
            guard gen == generation else { again = true; continue }
            let works = st.flatMap { Self.decode(Status.self, $0) }?.works.filter { $0.paddockId == paddock && $0.closedAt == nil } ?? []
            let ids = Set(works.map(\.id)), runs = Set(works.filter { $0.loop?.state == .running }.map(\.id))
            // closed, a loop ended, or a closed work changed (its loop ran on and its summary is now written)
            if !active.subtracting(ids).isEmpty || !running.subtracting(runs).isEmpty || !seen.subtracting(ids).isEmpty { needHistory = true }
            active = ids; running = runs
            work = Self.pick(works)
            if needHistory {
                needHistory = false
                await loadHistory(gen, name)
            }
        }
    }

    /// The work the panel shows: one with a running loop; none: the newest with a loop; then the first.
    nonisolated static func pick(_ works: [Work]) -> Work? {
        works.first { $0.loop?.state == .running }
            ?? works.filter { $0.loop != nil }.max { $0.openedAt < $1.openedAt }
            ?? works.first
    }

    private func loadHistory(_ gen: Int, _ name: String) async {
        let r = try? await ask("work.history", ["paddock": .string(name), "limit": .number(Double(Self.historyFetch))], 30)
        guard gen == generation else { needHistory = true; again = true; return }
        history = Self.entries(r)
    }

    /// The rows a `work.history` answer holds (a bare array, or `{works|history: [...]}`); a row that does not decode is skipped.
    public nonisolated static func entries(_ v: JSONValue?) -> [HistoryEntry] {
        var list: [JSONValue] = []
        switch v {
        case .array(let a)?: list = a
        case .object(let o)?: for k in ["history", "works"] { if case .array(let a)? = o[k] { list = a; break } }
        default: break
        }
        return Array(list.compactMap { decode(HistoryEntry.self, $0) }.prefix(historyFetch))
    }

    private func ask(_ command: String, _ args: [String: JSONValue], _ timeout: Double) async throws -> JSONValue {
        guard let call else { throw ProtocolError(code: .daemonUnavailable, message: "no daemon") }
        return try await call(command, args, timeout)
    }

    nonisolated static func decode<T: Decodable>(_ t: T.Type, _ v: JSONValue) -> T? {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(t, from: JSONEncoder().encode(v))
    }
}
