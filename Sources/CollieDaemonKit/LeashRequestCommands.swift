import Foundation
import CollieCore
import CollieProtocol

/// DX backlog 5: a Shepherd asks the user for a leash to a terminal it doesn't reach; the app answers the card.
extension CommandRouter {
    /// `leash.request`: one card per (Shepherd, target); the same request again returns it.
    func requestLeash(_ r: Request, by me: TerminalRecord) async throws -> JSONValue {
        let name = try need(r, "target")
        guard let t = ws.terminals.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw ProtocolError(code: .notFound, message: "Terminal '\(name)' not found")
        }
        guard t.id != me.id else { throw ProtocolError(code: .invalidArgs, message: "cannot leash '\(me.name)' to itself") }
        try refuseFreeLeash(t.id)
        if ConnectionGraph.reachable(from: me.id, in: ws).contains(where: { $0.id == t.id }) {
            throw ProtocolError(code: .invalidArgs, message: "'\(t.name)' is already leashed to you: collie ask \(t.name) \"…\"")
        }
        if let old = leashRequests.first(where: { $0.from == me.id && $0.to == t.id }) { return .object(["requestId": .string(old.id.uuidString)]) }
        let req = LeashRequest(from: me.id, to: t.id, reason: str(r, "reason").map { String($0.prefix(500)) })
        leashRequests.append(req)
        await hub.emit(.leashRequest(req))
        return .object(["requestId": .string(req.id.uuidString)])
    }

    /// `admin.leash.requests` / `admin.leash.answer` (the app's Conectar / Recusar).
    func adminLeashRequest(_ r: Request) async throws -> JSONValue {
        if r.command == "admin.leash.requests" {
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
            return try JSONDecoder().decode(JSONValue.self, from: e.encode(leashRequests))
        }
        guard let id = str(r, "id").flatMap(UUID.init(uuidString:)), let req = leashRequests.first(where: { $0.id == id }) else {
            throw ProtocolError(code: .notFound, message: "No leash request '\(str(r, "id") ?? "")'")
        }
        let allow = flag(r, "allow")
        let from = ws.terminals.first { $0.id == req.from }, to = ws.terminals.first { $0.id == req.to }
        if allow, let from, let to { try await leash(from, to) }
        leashRequests.removeAll { $0.id == id }
        await hub.emit(.leashRequestRemoved(id))
        if let from, let to, [.claude, .codex, .cursor].contains(from.preset) {
            let m = allow ? "[collie] The user leashed you to \(to.name)." : "[collie] The user declined your leash to \(to.name)."
            let asks = asks
            Task { try? await asks.inject(to: from.id, prompt: m, hold: .seconds(1800), afterQuiet: true) }
        }
        return .object([:])
    }

    /// A removed terminal's cards go (either end).
    func dropLeashRequests(_ terminal: UUID) async {
        for req in leashRequests where req.from == terminal || req.to == terminal { await hub.emit(.leashRequestRemoved(req.id)) }
        leashRequests.removeAll { $0.from == terminal || $0.to == terminal }
    }
}
