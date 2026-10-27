import Foundation
import CollieProtocol

/// `ask --no-wait`: each asker's recent asks and their replies, readable only by the asker (`ask.result`).
// ponytail: memory only — a daemon restart loses pending asks and replies; persist if users hit it
actor AskInbox {
    struct Entry: Sendable, Equatable {
        enum Status: String, Sendable { case pending, done, failed }
        var id: String, target: String
        var status: Status = .pending
        var output: String?, error: String?
    }
    static let keep = 20, deliverMax = 3000
    private var byAsker: [UUID: [Entry]] = [:]   // oldest first

    /// A new id (8 lowercase hex chars, unique in the inbox) for `from`'s ask to `target`.
    func open(from: UUID, target: String) -> String {
        var id: String
        repeat { id = String(UUID().uuidString.prefix(8)).lowercased() } while byAsker.values.contains { $0.contains { $0.id == id } }
        byAsker[from, default: []].append(Entry(id: id, target: target))
        if byAsker[from]!.count > Self.keep { byAsker[from]!.removeFirst() }
        return id
    }

    /// Records the reply; nil when the ask is gone (asker removed, or pushed out by newer asks).
    @discardableResult
    func close(id: String, _ r: Result<AskResult, ProtocolError>) -> Entry? {
        for (from, list) in byAsker {
            guard let i = list.firstIndex(where: { $0.id == id }) else { continue }
            switch r {
            case .success(let a): byAsker[from]![i].status = .done; byAsker[from]![i].output = a.output
            case .failure(let e): byAsker[from]![i].status = .failed; byAsker[from]![i].error = e.message
            }
            return byAsker[from]![i]
        }
        return nil
    }

    func get(id: String, from: UUID) -> Entry? { byAsker[from]?.first { $0.id == id } }
    /// Newest first.
    func recent(from: UUID) -> [Entry] { (byAsker[from] ?? []).reversed() }
    func drop(terminal: UUID) { byAsker[terminal] = nil }

    /// The text typed into the asker's terminal.
    static func message(_ e: Entry) -> String {
        guard e.status == .done else { return "[collie] Ask \(e.id) to \(e.target) failed: \(e.error ?? "no reply")" }
        let out = e.output ?? ""
        let body = out.count <= deliverMax ? out : String(out.prefix(deliverMax)) + "\n[cut — full reply: collie ask result \(e.id)]"
        return "[collie] Reply from \(e.target) (ask \(e.id)):\n\(body)"
    }

    static func json(_ e: Entry) -> JSONValue {
        var o: [String: JSONValue] = ["askId": .string(e.id), "target": .string(e.target), "status": .string(e.status.rawValue)]
        if let out = e.output { o["output"] = .string(out) }
        if let err = e.error { o["error"] = .string(err) }
        return .object(o)
    }
}
