import Foundation
import CollieCore
import CollieProtocol

/// The remote sessions subscribed to events (`events.subscribe`, remote API spec §3.4): each gets every projected
/// event (the "Wire details" shapes), in order. Under `lock`.
final class RemoteEventBus: @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [ObjectIdentifier: @Sendable (JSONValue) -> Void] = [:]

    var isEmpty: Bool { lock.withLock { sinks.isEmpty } }
    func add(_ key: ObjectIdentifier, _ sink: @escaping @Sendable (JSONValue) -> Void) { lock.withLock { sinks[key] = sink } }
    func remove(_ key: ObjectIdentifier) { lock.withLock { _ = sinks.removeValue(forKey: key) } }
    func publish(_ e: JSONValue) { lock.withLock { Array(sinks.values) }.forEach { $0(e) } }

    /// `v` as JSON with ISO 8601 dates.
    static func iso(_ v: some Encodable) -> JSONValue {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(v)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
    }
}

/// What the daemon publishes to subscribed phones: workspace events projected (never cwd, command, paths of Collie's
/// own), plus approvals, chat, work and removed cards from where they happen.
extension CommandRouter {
    /// One `WorkspaceEvent` (from `StreamHub.tapEvents`, in order) as its remote frame, when phones listen.
    func remoteWorkspaceEvent(_ e: WorkspaceEvent) async {
        guard !remoteEvents.isEmpty else { return }
        func uid(_ u: UUID) -> JSONValue { .string(u.uuidString.lowercased()) }
        let since: JSONValue = .string(Date().ISO8601Format())
        let out: JSONValue?
        switch e {
        case .spawned(let r), .terminal(let r):
            out = (try? await remoteTerminal(r)).map { .object(["t": .string("terminal"), "terminal": $0]) }
        case .exited(let id, _):
            out = .object(["t": .string("status"), "terminalId": uid(id), "badge": .string(StatusBadge.stopped.rawValue), "since": since])
        case .removed(let id): out = .object(["t": .string("terminalRemoved"), "id": uid(id)])
        case .status(let id, let b):
            out = .object(["t": .string("status"), "terminalId": uid(id), "badge": .string(b.rawValue),
                           "since": .string(await hub.since(id).ISO8601Format())])
        case .attention(let id, let reason): out = .object(["t": .string("attention"), "terminalId": uid(id), "reason": .string(reason)])
        case .paddock(let f): out = .object(["t": .string("paddock"), "paddock": remotePaddock(f)])
        case .paddockRemoved(let id): out = .object(["t": .string("paddockRemoved"), "id": uid(id)])
        case .lot(let l): out = .object(["t": .string("lot"), "lot": remoteLot(l)])
        case .lotRemoved(let id): out = .object(["t": .string("lotRemoved"), "id": uid(id)])
        case .connected(let c), .disconnected(let c):
            let terms = Set(ws.terminals.map(\.id))
            guard terms.contains(c.a) && terms.contains(c.b) else { return }   // leashes between terminals only
            if case .connected = e { out = .object(["t": .string("leash"), "a": uid(c.a), "b": uid(c.b), "on": .bool(true)]) }
            else { out = .object(["t": .string("leash"), "a": uid(c.a), "b": uid(c.b), "on": .bool(false)]) }
        case .notify(let id, let m): out = .object(["t": .string("notify"), "terminalId": uid(id), "message": .string(m)])
        case .sandboxDenied(let d): out = .object(["t": .string("accessCard"), "card": remoteCard(d)])
        case .panel, .panelRemoved, .pluginEvent, .herdApplied, .sandboxDetection, .confirmCorrection, .pluginsChanged, .remotePairing,
             .leashRequest, .leashRequestRemoved, .remoteReveal, .appCard, .appCardRemoved:   // the app's own (leash requests: not on the remote surface yet)
            out = nil
        }
        if let out { remoteEvents.publish(out) }
    }

    /// An approval raised, redrawn or cleared (ApprovalTracker), as the app's work panels get it.
    func remoteApproval(_ e: ApprovalEvent) {
        guard !remoteEvents.isEmpty else { return }
        switch e {
        case .raised(let a), .updated(let a):
            if case .array(let one) = remoteApprovals([a]), let first = one.first { remoteEvents.publish(.object(["t": .string("approval"), "approval": first])) }
        case .cleared(let t):
            remoteEvents.publish(.object(["t": .string("approval"), "terminalId": .string(t.uuidString.lowercased()), "cleared": .bool(true)]))
        }
    }

    /// Cards gone since `before` (granted, denied, covered by a grant, their terminal removed).
    func publishCardsRemoved(since before: Set<String>) {
        guard !remoteEvents.isEmpty else { return }
        let now = Set(accessCards.all.map(RemoteSurface.cardId))
        for id in before.subtracting(now).sorted() { remoteEvents.publish(.object(["t": .string("accessCardRemoved"), "id": .string(id)])) }
    }

    var cardIds: Set<String> { Set(accessCards.all.map(RemoteSurface.cardId)) }
}
