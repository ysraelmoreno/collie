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

/// b3: the server's own call on whether a step is destructive, besides the plan's `destructive: true`. A tap's target
/// resolves to labels (the `tap` text and the node it finds, `id:` humanized and its node, `ref:` its node, `x,y` the
/// smallest labeled node under it) in `nodes`, the panel's last tree read; a label is destructive when, ignoring case
/// and accents, it holds one of `destructiveLabels` as whole words. A target that cannot be resolved (`x,y` with no
/// read, a `ref:` not in it) is not classified. Only taps are classified: keys, swipes, typing and launches are not.
/// ponytail: `nodes` is the last read, maybe from before earlier steps of the plan; a stale node can classify a tap
/// either way. Upgrade: read the screen before each unmarked coordinate tap.
enum FlowClassifier {
    /// Verbs and labels (pt and en) that spend money, delete, or leave the account. Extend here.
    static let destructiveLabels: [String] = [
        "pagar", "finalizar", "comprar", "confirmar pedido", "confirmar compra", "confirmar pagamento",
        "excluir", "apagar", "remover", "deletar", "sair da conta", "desinstalar", "assinar plano",
        "pay", "buy", "purchase", "place order", "checkout", "check out", "delete", "remove", "erase",
        "sign out", "log out", "logout", "confirm", "uninstall", "subscribe",
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

    /// What a tap step's target is called, for `destructive`; empty for other actions or an unresolved target.
    static func labels(_ s: FlowPlan.Step, nodes: [UINode]) -> [String] {
        func names(_ n: UINode) -> [String] { [n.text, n.desc, humanizeId(n.id)].filter { !$0.isEmpty } }
        guard s.action == "tap" else { return [] }
        let t = s.target
        if t.hasPrefix("id:") {
            let id = String(t.dropFirst(3))
            return [humanizeId(id)] + nodes.filter { $0.id == id }.flatMap(names)
        }
        if t.hasPrefix("ref:") { return nodes.filter { $0.ref == String(t.dropFirst(4)) }.flatMap(names) }
        let xy = t.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if xy.count == 2, let x = Int(xy[0]), let y = Int(xy[1]) {
            let pt = CGPoint(x: x, y: y)
            let under = nodes.filter { $0.bounds.contains(pt) && !names($0).isEmpty }
            return under.min(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }).map(names) ?? []
        }
        return [t] + ((try? UITree.target(nodes, text: t, id: nil, nth: nil)).map(names) ?? [])
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
/// steps staying run. b3: a step `FlowClassifier` finds destructive (against `nodes`, the panel's last tree read) is
/// refused the same way, marked or not.
struct FlowRunner: Sendable {
    typealias Act = @Sendable (_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue
    var confirmed = false
    let nodes: @Sendable () async -> [UINode]
    let act: Act

    init(confirmed: Bool = false, nodes: @escaping @Sendable () async -> [UINode] = { [] }, act: @escaping Act) {
        self.confirmed = confirmed; self.nodes = nodes; self.act = act
    }

    /// Marked by the plan, or a tap the server classifies.
    func destructive(_ s: FlowPlan.Step) async -> Bool {
        if s.destructive == true { return true }
        return s.action == "tap" ? FlowClassifier.destructive(s, nodes: await nodes()) : false
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
            if !confirmed, await destructive(step) {
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
