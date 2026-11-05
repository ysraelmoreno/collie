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
        /// How it ended (hook/idle) and when: asked, prompt delivered (submitted), reply or failure.
        var source: AskResult.Source?
        var askedAt = Date(), deliveredAt: Date?, completedAt: Date?
    }
    static let keep = 20, inlineMax = 300, previewMax = 120
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
    func delivered(id: String) {
        for (from, list) in byAsker { if let i = list.firstIndex(where: { $0.id == id && $0.completedAt == nil }) { byAsker[from]![i].deliveredAt = Date() } }
    }

    @discardableResult
    func close(id: String, _ r: Result<AskResult, ProtocolError>) -> Entry? {
        for (from, list) in byAsker {
            guard let i = list.firstIndex(where: { $0.id == id }) else { continue }
            byAsker[from]![i].completedAt = Date()
            switch r {
            case .success(let a): byAsker[from]![i].status = .done; byAsker[from]![i].output = a.output; byAsker[from]![i].source = a.source
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

    /// The line typed into the asker's terminal: never a pasted block (Claude shows one as "[Pasted text]", easy to leave
    /// unsent). A short reply inline, whitespace folded; a long one as its first line and where to read it all.
    static func message(_ e: Entry) -> String {
        guard e.status == .done else { return "[collie] Ask \(e.id) to \(e.target) failed: \(e.error ?? "no reply")" }
        let out = e.output ?? ""
        let flat = out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if flat.count <= inlineMax { return "[collie] Reply from \(e.target) (ask \(e.id)): \(flat)" }
        let lines = out.split(separator: "\n", omittingEmptySubsequences: true)
        let first = (lines.first ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let preview = first.count <= previewMax ? first : String(first.prefix(previewMax)) + "…"
        return "[collie] Reply from \(e.target) (ask \(e.id), \(lines.count) lines): \(preview) — full reply: collie ask result \(e.id)"
    }

    static func json(_ e: Entry) -> JSONValue {
        var o: [String: JSONValue] = ["askId": .string(e.id), "target": .string(e.target), "status": .string(e.status.rawValue)]
        if let out = e.output { o["output"] = .string(out) }
        if let err = e.error { o["error"] = .string(err) }
        if let s = e.source { o["source"] = .string(s.rawValue) }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        o["askedAt"] = .string(f.string(from: e.askedAt))
        if let d = e.deliveredAt { o["deliveredAt"] = .string(f.string(from: d)) }
        if let d = e.completedAt { o["completedAt"] = .string(f.string(from: d)) }
        return .object(o)
    }
}
