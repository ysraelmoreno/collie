import Foundation
import Observation
import CollieCore
import CollieProtocol

/// One line of `work.history` (`id,title,openedAt,closedAt,stopReason,done,total,deferred,durationSeconds`). Tolerant:
/// `stopReason` stays the daemon's raw text (a code this app does not know is still a row), a missing count is 0.
public struct HistoryEntry: Decodable, Sendable, Equatable {
    public var id: String, title: String
    public var openedAt: Date?, closedAt: Date
    public var stopReason: String?
    public var done: Int, total: Int, deferred: Int, durationSeconds: Int
    public init(id: String, title: String, openedAt: Date? = nil, closedAt: Date, stopReason: String? = nil,
                done: Int = 0, total: Int = 0, deferred: Int = 0, durationSeconds: Int = 0) {
        self.id = id; self.title = title; self.openedAt = openedAt; self.closedAt = closedAt; self.stopReason = stopReason
        self.done = done; self.total = total; self.deferred = deferred; self.durationSeconds = durationSeconds
    }
    private enum K: String, CodingKey { case id, title, openedAt, closedAt, stopReason, done, total, deferred, durationSeconds }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id); title = (try? c.decode(String.self, forKey: .title)) ?? ""
        closedAt = try c.decode(Date.self, forKey: .closedAt)
        openedAt = try? c.decode(Date.self, forKey: .openedAt)
        stopReason = try? c.decode(String.self, forKey: .stopReason)
        done = (try? c.decode(Int.self, forKey: .done)) ?? 0; total = (try? c.decode(Int.self, forKey: .total)) ?? 0
        deferred = (try? c.decode(Int.self, forKey: .deferred)) ?? 0
        durationSeconds = (try? c.decode(Int.self, forKey: .durationSeconds)) ?? 0
    }
}

/// What the Trilho panel shows of the followed paddock: its active work (the loop inside it) and its last closed works.
/// Kept fresh by `work.wait` (a long wait the daemon answers when the work changes: never a timer), asking again from the
/// version it last saw; `follow` (a paddock switch) starts over. A daemon that fails leaves it empty, never throws.
@MainActor @Observable public final class WorkFeed {
    public private(set) var work: Work?
    public private(set) var history: [HistoryEntry] = []
    public nonisolated static let historyLimit = 20
    /// The daemon's `work.wait` timeout (it answers `timedOut` and the feed waits again from the same version).
    static let waitSeconds = 600.0

    public typealias Call = @MainActor (_ command: String, _ args: [String: JSONValue], _ timeout: Double) async throws -> JSONValue
    @ObservationIgnored public var call: Call?
    /// A terminal's name by id (`work.wait` names its target).
    @ObservationIgnored public var terminalName: @MainActor (UUID) -> String? = { _ in nil }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var followed: (id: UUID?, name: String?) = (nil, nil)

    public init() {}

    /// Follows `paddock` (nil: the Pasto, which has no work to show): drops what the last one left and loads again.
    public func follow(paddock: UUID?, name: String?) {
        followed = (paddock, name)
        restart()
    }
    /// Loads again for the followed paddock (the daemon came back, a work was opened).
    public func refresh() { restart() }

    private func restart() {
        task?.cancel(); generation += 1
        work = nil; history = []
        let gen = generation, (paddock, name) = followed
        guard let paddock, let name else { return }
        task = Task { [weak self] in await self?.run(gen, paddock, name) }
    }

    private func live(_ gen: Int) -> Bool { gen == generation && !Task.isCancelled }

    private func run(_ gen: Int, _ paddock: UUID, _ name: String) async {
        Task { [weak self] in await self?.loadHistory(gen, name) }   // not in the work's way
        do {
            let st = try await ask("work.status", ["all": .bool(true)], 30)
            guard live(gen) else { return }
            struct Status: Decodable { let works: [Work] }
            guard let found = Self.decode(Status.self, st)?.works.first(where: { $0.paddockId == paddock && $0.closedAt == nil }) else {
                work = nil; return   // nothing active here: nothing to wait on
            }
            work = found
            var version = found.version ?? 0
            var ended = found.loop.map { $0.state != .running } ?? false
            while !ended {
                guard let terminal = terminalName(found.terminalId) else { return }
                let r = try await ask("work.wait", ["terminal": .string(terminal), "since": .number(Double(version)),
                                                    "timeout": .number(Self.waitSeconds)], Self.waitSeconds + 10)
                guard live(gen) else { return }
                struct Wait: Decodable { let works: [Work]; let version: Int?; let ended: Bool? }
                guard let w = Self.decode(Wait.self, r), let cur = w.works.first else { throw ProtocolError(code: .internal, message: "work.wait") }
                work = cur; version = w.version ?? version; ended = w.ended ?? false
            }
            await loadHistory(gen, name)   // the loop is over: its work may close next
        } catch {
            guard live(gen) else { return }
            work = nil   // the work closed (or the daemon failed): the history is what is left
            await loadHistory(gen, name)
        }
    }

    private func loadHistory(_ gen: Int, _ name: String) async {
        let r = try? await ask("work.history", ["paddock": .string(name), "limit": .number(Double(Self.historyLimit))], 30)
        guard live(gen) else { return }
        history = Self.entries(r)
    }

    /// The rows a `work.history` answer holds (a bare array, or `{works|history: [...]}`); a row that does not decode is skipped.
    nonisolated static func entries(_ v: JSONValue?) -> [HistoryEntry] {
        var list: [JSONValue] = []
        switch v {
        case .array(let a)?: list = a
        case .object(let o)?: for k in ["history", "works"] { if case .array(let a)? = o[k] { list = a; break } }
        default: break
        }
        return Array(list.compactMap { decode(HistoryEntry.self, $0) }.prefix(historyLimit))
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
