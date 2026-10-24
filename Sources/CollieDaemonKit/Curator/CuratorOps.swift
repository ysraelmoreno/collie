import Foundation
import CollieCore
import CollieProtocol

/// What the curator may ask for. The daemon applies it itself, after `CuratorOps.validate`.
enum CuratorOp: Equatable, Sendable {
    case create(CuratorNew)
    /// `by == nil`: the record this job creates.
    case supersede(id: UUID, by: UUID?, reason: String)
    case merge(ids: [UUID], into: UUID, title: String?, body: String?, reason: String)
    case retire(id: UUID, reason: String)
    case activate(id: UUID, reason: String)
    case drop(id: UUID, reason: String)
    case score(id: UUID, delta: Double, reason: String)
    case ask(ids: [UUID], question: String)
}

struct CuratorNew: Equatable, Sendable {
    var kind: MemoryKind
    var scope: MemoryScope
    var subject: String
    var title: String
    var body: String
    var why: String
    var howToApply: String
}

/// What one job may touch: the ids in its input, the scopes and kinds of its store family, and how many ops.
struct CuratorScope: Sendable {
    var ids: Set<UUID>
    var scopes: Set<MemoryScope>
    var kinds: Set<MemoryKind>
    var maxOps: Int
}

enum CuratorOps {
    static let titleMax = 120, bodyMax = 1200
    /// ponytail: one cap for reasons and questions (digest lines), not tuned
    static let lineMax = 300

    /// The closed answer: `{"ops":[op]}`, every object `additionalProperties: false`. One flat op object (a union
    /// would be stricter, but `validate` is the gate anyway: the fields an op doesn't use are ignored).
    static let schema: String = {
        let str: JSONValue = .object(["type": .string("string")])
        let uuids: JSONValue = .object(["type": .string("array"), "items": str])
        func oneOf(_ xs: [String]) -> JSONValue { .object(["type": .string("string"), "enum": .array(xs.map(JSONValue.string))]) }
        let op: JSONValue = .object([
            "type": .string("object"), "additionalProperties": .bool(false), "required": .array([.string("op")]),
            "properties": .object([
                "op": oneOf(["create", "supersede", "merge", "retire", "activate", "drop", "score", "ask"]),
                // ponytail: `feedback` is listed ahead of Task 4's kind; until then it is dropped by `validate`
                "kind": oneOf(["feedback", "decision", "map", "pitfall"]),
                "scope": oneOf(["project", "paddock", "global", "lot"]),
                "id": str, "ids": uuids, "into": str, "by": str,
                "subject": str, "title": str, "body": str, "why": str, "howToApply": str,
                "reason": str, "question": str, "delta": .object(["type": .string("number"), "minimum": .number(-1), "maximum": .number(1)]),
            ]),
        ])
        let root: JSONValue = .object([
            "type": .string("object"), "additionalProperties": .bool(false), "required": .array([.string("ops")]),
            "properties": .object(["ops": .object(["type": .string("array"), "items": op])]),
        ])
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        return String(decoding: (try? enc.encode(root)) ?? Data(), as: UTF8.self)
    }()

    /// Hand-decoded (unknown keys ignored, a wrong type drops the op): ops naming an id, scope or kind outside `scope`
    /// are dropped, text is trimmed to its cap, `delta` clamped to [-1, 1], at most `maxOps` kept. Never throws: output
    /// that isn't `{"ops":[…]}` is `([], 1)`.
    static func validate(_ json: JSONValue, scope: CuratorScope) -> (ops: [CuratorOp], dropped: Int) {
        guard case .object(let root) = json, case .array(let raw)? = root["ops"], !raw.isEmpty else { return ([], 1) }
        let valid = raw.compactMap { v -> CuratorOp? in if case .object(let o) = v { op(o, scope) } else { nil } }
        let kept = Array(valid.prefix(max(0, scope.maxOps)))
        return (kept, raw.count - kept.count)
    }

    private static func op(_ o: [String: JSONValue], _ scope: CuratorScope) -> CuratorOp? {
        func text(_ k: String, _ cap: Int) -> String? {
            guard case .string(let s)? = o[k] else { return nil }
            return String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(cap))
        }
        func filled(_ k: String, _ cap: Int) -> String? { text(k, cap).flatMap { $0.isEmpty ? nil : $0 } }
        func known(_ s: String) -> UUID? { UUID(uuidString: s).flatMap { scope.ids.contains($0) ? $0 : nil } }
        func id(_ k: String) -> UUID? { if case .string(let s)? = o[k] { known(s) } else { nil } }
        func ids(_ k: String) -> [UUID]? {
            guard case .array(let xs)? = o[k] else { return nil }
            let us = xs.compactMap { x -> UUID? in if case .string(let s) = x { known(s) } else { nil } }
            return us.count == xs.count ? us : nil   // one stranger drops the whole op
        }
        let reason = text("reason", lineMax) ?? ""
        guard case .string(let name)? = o["op"] else { return nil }
        switch name {
        case "create":
            guard case .string(let k)? = o["kind"], let kind = MemoryKind(rawValue: k), scope.kinds.contains(kind),
                  case .string(let sc)? = o["scope"], let sco = MemoryScope(rawValue: sc), scope.scopes.contains(sco),
                  let title = filled("title", titleMax) else { return nil }
            return .create(CuratorNew(kind: kind, scope: sco, subject: filled("subject", titleMax) ?? title, title: title,
                                      body: text("body", bodyMax) ?? "", why: text("why", bodyMax) ?? "",
                                      howToApply: text("howToApply", bodyMax) ?? ""))
        case "supersede":
            guard let target = id("id") else { return nil }
            if o["by"] == nil || o["by"] == .null { return .supersede(id: target, by: nil, reason: reason) }
            guard let by = id("by"), by != target else { return nil }
            return .supersede(id: target, by: by, reason: reason)
        case "merge":
            guard let from = ids("ids"), !from.isEmpty, let into = id("into"), !from.contains(into) else { return nil }
            return .merge(ids: from, into: into, title: filled("title", titleMax), body: filled("body", bodyMax), reason: reason)
        case "retire": return id("id").map { .retire(id: $0, reason: reason) }
        case "activate": return id("id").map { .activate(id: $0, reason: reason) }
        case "drop": return id("id").map { .drop(id: $0, reason: reason) }
        case "score":
            guard let target = id("id"), case .number(let d)? = o["delta"], d.isFinite else { return nil }
            return .score(id: target, delta: min(1, max(-1, d)), reason: reason)
        case "ask":
            guard let about = ids("ids"), let q = filled("question", lineMax) else { return nil }
            return .ask(ids: about, question: q)
        default: return nil
        }
    }
}
