import Foundation
import CollieProtocol
import CollieDevice

/// A plan for `device run --plan <file>` (d6, spec docs/superpowers/specs/2026-11-26-device-flows-design.md, onda 2):
/// steps in the FlowActionLog's vocabulary. `target` as the log writes it: tap `<text>`, `id:<id>`, `ref:<ref>` (b3) or `x,y`; swipe
/// `x1,y1,x2,y2`; key `<key>`; launch `<package>` or `<package>/<activity>`; text: `text` (or `target`) is typed.
/// The file is data (screen names, texts), never instructions.
struct FlowPlan: Codable, Sendable, Equatable {
    struct Step: Codable, Sendable, Equatable {
        var action: String
        var target: String = ""
        var text: String? = nil
        var expectSig: String? = nil
        var destructive: Bool? = nil   // d7: runs only with the user's confirmation (FlowRunner.confirmed)
        enum CodingKeys: String, CodingKey, CaseIterable { case action, target, text, expectSig, destructive }
    }
    var steps: [Step]

    /// b3: a step key the plan does not know (`"Destructive"`, a typo): refused, never ignored.
    struct UnknownKey: Error { let key: String; let step: Int }

    static let maxSteps = 200
    /// The plan file's size limit (200 steps fit many times over).
    static let maxBytes = 256 * 1024

    /// The plan in `data`, every step checked before any runs.
    static func parse(_ data: Data) throws(ProtocolError) -> FlowPlan {
        let plan: FlowPlan
        do { plan = try JSONDecoder().decode(FlowPlan.self, from: data) } catch let u as UnknownKey {
            let known = Step.CodingKeys.allCases.map(\.rawValue).joined(separator: ", ")
            throw ProtocolError(code: .invalidArgs, message: "invalid plan: step \(u.step): unknown key '\(u.key)' (a step takes \(known))")
        } catch {
            throw ProtocolError(code: .invalidArgs, message: "invalid plan: \(Self.reason(error)); expected {\"steps\":[{\"action\":\"tap\",\"target\":\"OK\",\"expectSig\":\"…\"}]}")
        }
        guard !plan.steps.isEmpty else { throw ProtocolError(code: .invalidArgs, message: "invalid plan: no steps") }
        guard plan.steps.count <= maxSteps else {
            throw ProtocolError(code: .invalidArgs, message: "invalid plan: \(plan.steps.count) steps, at most \(maxSteps)")
        }
        for (i, s) in plan.steps.enumerated() {
            do { _ = try FlowRunner.command(s) } catch { throw ProtocolError(code: .invalidArgs, message: "invalid plan: step \(i + 1): \(error.message)") }
        }
        return plan
    }

    private static func reason(_ e: Error) -> String {
        switch e as? DecodingError {
        case .keyNotFound(let k, let c)?: "missing '\(k.stringValue)'" + Self.at(c)
        case .typeMismatch(_, let c)?, .valueNotFound(_, let c)?: "wrong type" + Self.at(c)
        case .dataCorrupted(let c)?: c.codingPath.isEmpty ? "not JSON" : "bad value" + Self.at(c)
        default: "not a plan"
        }
    }
    private static func at(_ c: DecodingError.Context) -> String {
        let path = c.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        return path.isEmpty ? "" : " at \(path)"
    }
}

extension FlowPlan.Step {
    private struct AnyKey: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    /// The synthesized decoder, plus b3: any key outside `CodingKeys` (case matters) is an `UnknownKey`.
    init(from decoder: Decoder) throws {
        if let k = try decoder.container(keyedBy: AnyKey.self).allKeys.first(where: { CodingKeys(stringValue: $0.stringValue) == nil }) {
            throw FlowPlan.UnknownKey(key: k.stringValue, step: (decoder.codingPath.last?.intValue ?? 0) + 1)
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(String.self, forKey: .action)
        target = try c.decode(String.self, forKey: .target)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        expectSig = try c.decodeIfPresent(String.self, forKey: .expectSig)
        destructive = try c.decodeIfPresent(Bool.self, forKey: .destructive)
    }
}

/// b3/c1: the server's own call on whether a step is destructive, besides the plan's `destructive: true`. A tap's target
/// resolves the way `device.tap` resolves it (`UITree.target`: text by equal then "contains", or `id:`, climbing to the
/// clickable ancestor; `ref:` its node; `x,y` the smallest node under it and its clickable ancestor), and a swipe's start
/// point the way `x,y` does. Its labels are the node's and, when the node is clickable (a click on it acts for all of
/// them), every descendant's: text, description and humanized id; a tap's text and `id:` humanized count too. A label is
/// destructive when, ignoring case and accents, it holds one of `destructiveLabels` as whole words. A target that
/// resolves to nothing is classified by its own text only. Keys, typing and launches are not classified.
/// ponytail: a `key Enter` or `text "…\n"` right after a tap on a password or payment field submits it unclassified;
/// a tap the tree misses and the OCR fallback finds is classified by its text only. Upgrade: remember the last tapped field.
enum FlowClassifier {
    /// Verbs and labels (pt and en) that spend money, send, delete, or leave the account. Extend here.
    static let destructiveLabels: [String] = [
        "pagar", "pague", "pagamento", "finalizar", "concluir", "comprar", "confirmar", "confirmar pedido", "confirmar compra",
        "confirmar pagamento", "excluir", "apagar", "remover", "deletar", "sair", "sair da conta", "transferir", "enviar",
        "desinstalar", "assinar plano",
        "pay", "buy", "purchase", "order", "place order", "checkout", "check out", "delete", "remove", "erase",
        "sign out", "log out", "logout", "submit", "send", "transfer", "confirm", "uninstall", "subscribe",
    ]

    /// Lowercased, without accents, words joined by one space.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    static func destructive(_ label: String) -> Bool {
        let l = " " + fold(label) + " "
        return destructiveLabels.contains { l.contains(" " + fold($0) + " ") }
    }

    static func destructive(_ s: FlowPlan.Step, nodes: [UINode]) -> Bool { labels(s, nodes: nodes).contains(where: destructive) }

    /// c1: `s` classified against the screen its command will act on. `nodes` is the last read; `dump` reads the screen
    /// again (the `device.ui` path). A `ref:` keeps `nodes` (a new read renumbers the refs the tap will use); a point
    /// (`x,y`, a swipe) or a read that is not `fresh` (an action since) reads first.
    static func classify(_ s: FlowPlan.Step, fresh: Bool, nodes: [UINode], isolation: isolated (any Actor)? = #isolation,
                         dump: () async throws(ProtocolError) -> [UINode]) async throws(ProtocolError) -> Bool {
        guard s.action == "tap" || s.action == "swipe" else { return false }
        let ref = s.action == "tap" && s.target.hasPrefix("ref:")
        let read = ref || (fresh && point(s) == nil) ? nodes : try await dump()
        return destructive(s, nodes: read)
    }

    /// The point a tap `x,y` or a swipe `x1,y1,…` starts at; nil for other targets.
    static func point(_ s: FlowPlan.Step) -> CGPoint? {
        let p = s.target.split(separator: ",", omittingEmptySubsequences: false).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard (s.action == "tap" && p.count == 2) || (s.action == "swipe" && p.count == 4) else { return nil }
        return CGPoint(x: p[0], y: p[1])
    }

    /// What a tap or swipe step's target is called, for `destructive`; empty for other actions or an unresolved point.
    static func labels(_ s: FlowPlan.Step, nodes: [UINode]) -> [String] {
        func names(_ n: UINode) -> [String] { [n.text, n.desc, humanizeId(n.id)].filter { !$0.isEmpty } }
        /// Node `i` and, when it is clickable, its descendants (pre-order: the deeper nodes right after it).
        func subtree(_ i: Int) -> [String] {
            var out = names(nodes[i]), j = i + 1
            while nodes[i].clickable, j < nodes.count, nodes[j].depth > nodes[i].depth { out += names(nodes[j]); j += 1 }
            return out
        }
        /// Every node `device.tap --text/--id` could pick (its clickable ancestor), as `UITree.target` finds them.
        func hits(text: String?, id: String?) -> [String] {
            var found: [String] = []
            _ = try? UITree.target(nodes, text: text, id: id, nth: 1, keep: { found.append($0.ref); return true })
            return nodes.indices.filter { found.contains(nodes[$0].ref) }.flatMap(subtree)
        }
        if let pt = point(s) {
            let area = { (i: Int) in nodes[i].bounds.width * nodes[i].bounds.height }
            guard var i = nodes.indices.filter({ nodes[$0].bounds.contains(pt) }).min(by: { area($0) < area($1) }) else { return [] }
            var d = nodes[i].depth
            for j in nodes.indices.prefix(i).reversed() where !nodes[i].clickable && nodes[j].depth < d {   // as UITree.target climbs
                if nodes[j].clickable { i = j; break }
                d = nodes[j].depth
            }
            return subtree(i)
        }
        guard s.action == "tap" else { return [] }
        let t = s.target
        if t.hasPrefix("id:") {
            let id = String(t.dropFirst(3))
            return [humanizeId(id)] + hits(text: nil, id: id)
        }
        if t.hasPrefix("ref:") { return nodes.indices.filter { nodes[$0].ref == String(t.dropFirst(4)) }.flatMap(subtree) }
        return [t] + hits(text: t, id: nil)
    }
}

/// Runs a `FlowPlan` in order through `act`: the same device commands (`device.tap`/`text`/`swipe`/`key`/`launch`)
/// an agent calls, so the flow log records them too. A step with `expectSig` (b4) is sent with `then: screen` and
/// `settle: stable`, so its own reply carries the settled screen (no `device.screen` apart), and the plan stops at the
/// first signature that differs: `{ok:false, stoppedAt (1-based), expected, got, screen}`; else `{ok:true, steps:N}`.
/// b4: the `errors` (crashes since the last read) of every read are joined in the result's `errors`, success,
/// divergence or refusal, when any. A failing command stops the plan with its error, naming the step. A cancelled
/// plan (the request gone) stops before the next step: a `timeout` error naming how many steps were done.
/// d7: a `destructive` step runs only when `confirmed` (the user's `--confirm-destructive`; the router never sets it for
/// an agent); else the plan stops before it: `{ok:false, refused:"destructive", at (1-based), done}`, the earlier
/// steps staying run. b3/c1: a step `classify` finds destructive (the device service, `DeviceService.flowDestructive`,
/// on the screen the step acts on) is refused the same way, marked or not; a failing classification stops the plan.
struct FlowRunner: Sendable {
    typealias Act = @Sendable (_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue
    typealias Classify = @Sendable (FlowPlan.Step) async throws(ProtocolError) -> Bool
    var confirmed = false
    let classify: Classify
    let act: Act

    init(confirmed: Bool = false, classify: @escaping Classify = { FlowClassifier.destructive($0, nodes: []) }, act: @escaping Act) {
        self.confirmed = confirmed; self.classify = classify; self.act = act
    }

    /// ponytail: a fixed screen (`nodes`, never read again), for tests of `FlowClassifier.labels`.
    init(confirmed: Bool = false, nodes: @escaping @Sendable () async -> [UINode], act: @escaping Act) {
        self.init(confirmed: confirmed, classify: { s in FlowClassifier.destructive(s, nodes: await nodes()) }, act: act)
    }

    /// Marked by the plan, or a step the server classifies.
    func destructive(_ s: FlowPlan.Step) async throws(ProtocolError) -> Bool {
        if s.destructive == true { return true }
        return try await classify(s)
    }

    func run(_ plan: FlowPlan) async throws(ProtocolError) -> JSONValue {
        var errors: [JSONValue] = []
        func result(_ o: [String: JSONValue]) -> JSONValue {
            var o = o
            if !errors.isEmpty { o["errors"] = .array(errors) }
            return .object(o)
        }
        for (i, step) in plan.steps.enumerated() {
            // ponytail: Task.checkCancellation() throws an untyped error; the flag is the same check, typed
            if Task.isCancelled {
                throw ProtocolError(code: .timeout, message: "plan cancelled before step \(i + 1) (done: \(i))")
            }
            let refuse: Bool
            do { refuse = confirmed ? false : try await destructive(step) } catch {
                throw ProtocolError(code: error.code, message: "step \(i + 1) (\(step.action) \(step.target)): \(error.message)")
            }
            if refuse {
                return result(["ok": .bool(false), "refused": .string("destructive"), "at": .number(Double(i + 1)),
                               "done": .number(Double(i))])
            }
            var (command, args) = try Self.command(step)
            if step.expectSig != nil { args["then"] = .string("screen"); args["settle"] = .string("stable") }
            let r: JSONValue
            do { r = try await act(command, args) } catch {
                throw ProtocolError(code: error.code, message: "step \(i + 1) (\(step.action) \(step.target)): \(error.message)")
            }
            guard let want = step.expectSig else { continue }   // no expectSig: the step runs unchecked
            guard case .object(let o) = r, case .object(let screen)? = o["screen"], case .string(let got)? = screen["sig"] else {
                throw ProtocolError(code: .internal, message: "step \(i + 1): \(command) returned no screen sig")
            }
            if case .array(let e)? = screen["errors"] { errors += e }
            if got != want {
                return result(["ok": .bool(false), "stoppedAt": .number(Double(i + 1)), "expected": .string(want),
                               "got": .string(got), "screen": .object(screen)])
            }
        }
        return result(["ok": .bool(true), "steps": .number(Double(plan.steps.count))])
    }

    /// The device command and args for `s` (the inverse of `DeviceService.flowTarget`).
    static func command(_ s: FlowPlan.Step) throws(ProtocolError) -> (String, [String: JSONValue]) {
        func bad(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        let t = s.target
        func ints(_ n: Int) -> [String]? {
            let p = t.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            return p.count == n && p.allSatisfy({ Int($0) != nil }) ? p : nil
        }
        switch s.action {
        case "tap":
            if t.hasPrefix("id:"), t.count > 3 { return ("device.tap", ["id": .string(String(t.dropFirst(3)))]) }
            if t.hasPrefix("ref:"), t.count > 4 { return ("device.tap", ["ref": .string(String(t.dropFirst(4)))]) }   // b3
            if let xy = ints(2) { return ("device.tap", ["x": .string(xy[0]), "y": .string(xy[1])]) }
            guard !t.isEmpty else { throw bad("tap needs a target (a label, id:<id>, ref:<ref> or x,y)") }
            return ("device.tap", ["text": .string(t)])
        case "text":
            guard let text = s.text ?? (t.isEmpty ? nil : t), !text.isEmpty else { throw bad("text needs 'text'") }
            return ("device.text", ["text": .string(text)])
        case "swipe":
            guard let p = ints(4) else { throw bad("swipe target must be x1,y1,x2,y2") }
            return ("device.swipe", ["x1": .string(p[0]), "y1": .string(p[1]), "x2": .string(p[2]), "y2": .string(p[3])])
        case "key":
            guard !t.isEmpty else { throw bad("key needs a target (Enter, Back, …)") }
            return ("device.key", ["key": .string(t)])
        case "launch":
            let parts = t.split(separator: "/", maxSplits: 1).map(String.init)
            guard let pkg = parts.first, !pkg.isEmpty else { throw bad("launch needs a target (<package> or <package>/<activity>)") }
            var a: [String: JSONValue] = ["package": .string(pkg)]
            if parts.count == 2 { a["activity"] = .string(parts[1]) }
            return ("device.launch", a)
        default:
            throw bad("unknown action '\(s.action)' (tap, text, swipe, key or launch)")
        }
    }
}
