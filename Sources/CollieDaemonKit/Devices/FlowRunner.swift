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
/// clickable ancestor; `ref:` its node). Its labels are the node's and, when the node is clickable (a click on it acts for
/// all of them), every descendant's: text, description and humanized id; a tap's text and `id:` humanized count too.
/// wd1, fail-closed: a target neither clickable nor under a clickable ancestor (a `Group`/`Other`/`LinearLayout`) brings
/// all its descendants and what lies under its centre (where `device.tap` touches). A point (`x,y`, a swipe's start)
/// brings every node holding it, each with its clickable ancestor's subtree; and, when nothing clickable holds it, the
/// smallest node's subtree (a leaf: its parent's, the slider of a thumb), a full-screen node excepted. A label is
/// destructive when, ignoring case and accents, it holds one of `destructiveLabels` as whole words. A target that
/// resolves to nothing is classified by its own text only. Keys, typing and launches are not classified.
/// ponytail: a `key Enter` or `text "…\n"` right after a tap on a password or payment field submits it unclassified.
/// Upgrade: remember the last tapped field.
enum FlowClassifier {
    /// Verbs and labels (pt and en) that spend money, send, delete, or leave the account. Extend here.
    static let destructiveLabels: [String] = [
        "pagar", "pague", "pagamento", "finalizar", "concluir", "comprar", "confirmar", "confirmar pedido", "confirmar compra",
        "confirmar pagamento", "excluir", "apagar", "remover", "deletar", "sair", "sair da conta", "transferir", "enviar",
        "desinstalar", "assinar plano", "cancelar assinatura", "encerrar conta", "limpar dados", "redefinir", "desativar",
        "pay", "buy", "purchase", "order", "place order", "checkout", "check out", "delete", "remove", "erase",
        "sign out", "log out", "logout", "submit", "send", "transfer", "confirm", "uninstall", "subscribe",
        "cancel subscription", "close account", "clear data", "reset", "deactivate",
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

    /// wf2: how far a node may move between two reads and still be the node a `ref:` named (`uiautomator` and the helper
    /// round bounds 1 px apart). ponytail: one value for Android pixels and iOS points (8 pt ≈ 24 px); per platform if it bites.
    static let refTolerance: CGFloat = 8

    /// wf2: the node of `fresh` (a new read) that is still `n` (a node of the read a `ref:` named): same class, text,
    /// description and id, every edge within `refTolerance`. None, or more than one: nil (the screen changed; fail-closed).
    static func refound(_ n: UINode, in fresh: [UINode]) -> UINode? {
        let t = refTolerance
        let same = fresh.filter {
            $0.cls == n.cls && $0.text == n.text && $0.desc == n.desc && $0.id == n.id
                && abs($0.bounds.minX - n.bounds.minX) <= t && abs($0.bounds.minY - n.bounds.minY) <= t
                && abs($0.bounds.maxX - n.bounds.maxX) <= t && abs($0.bounds.maxY - n.bounds.maxY) <= t
        }
        return same.count == 1 ? same[0] : nil
    }

    /// wf1: how a guarded command's refusal of a destructive target starts (`FlowRunner` turns it into `refused: destructive`).
    static let refusedPrefix = "destructive:"

    /// wf1: the guard of `device.tap`/`device.swipe` (`guard: "destructive"`, sent by the `FlowRunner`): `s`, the command's
    /// target, classified on `nodes`, the read the command resolved it in, plus `n`, the node it will touch (nil: a point),
    /// as a `ref:` of that read (its subtree, clickable ancestor and what lies under its centre). Destructive: `.conflict`
    /// with `refusedPrefix`. Fail-closed: a read with no nodes, or an OCR node with no label, is a `.conflict` too.
    /// Either way nothing is touched.
    static func guardCheck(_ s: FlowPlan.Step, nodes: [UINode], touching n: UINode?) throws(ProtocolError) {
        guard !nodes.isEmpty else { throw unread("the read has no nodes") }
        if let n, n.ocr, (n.text + n.desc).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProtocolError(code: .conflict, message: "the OCR read no label for \(s.target); \(s.action) refused, nothing touched")
        }
        let all = labels(s, nodes: nodes) + (n.map { labels(FlowPlan.Step(action: "tap", target: "ref:" + $0.ref), nodes: nodes) } ?? [])
        if let l = all.first(where: destructive) {
            throw ProtocolError(code: .conflict, message: "\(refusedPrefix) \(s.action) \(s.target) acts on '\(l)'; refused before touching (only the user's --confirm-destructive runs it)")
        }
    }

    /// wf1, fail-closed: a guarded command that cannot read the screen it would classify touches nothing.
    static func unread(_ why: String) -> ProtocolError {
        ProtocolError(code: .conflict, message: "cannot read the screen to classify (\(why)); refused, nothing touched")
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
        /// Node `i` and, when it is clickable or `all`, its descendants (pre-order: the deeper nodes right after it).
        func subtree(_ i: Int, all: Bool = false) -> [String] {
            var out = names(nodes[i]), j = i + 1
            while all || nodes[i].clickable, j < nodes.count, nodes[j].depth > nodes[i].depth { out += names(nodes[j]); j += 1 }
            return out
        }
        /// Node `i`'s ancestors, nearest first (pre-order: each shallower node before it).
        func ancestors(_ i: Int) -> [Int] {
            var out: [Int] = [], d = nodes[i].depth
            for j in nodes.indices.prefix(i).reversed() where nodes[j].depth < d { out.append(j); d = nodes[j].depth }
            return out
        }
        func area(_ i: Int) -> CGFloat { nodes[i].bounds.width * nodes[i].bounds.height }
        /// we2: a node of ≥ 90 % of the root's area (Android's clickable root, a content view under the status bar) is the
        /// screen itself: it lends no labels to what lies in it, or a scroll swipe on a screen with "Sair" would be refused.
        /// wf3: a clickable one is the screen only as the tree's real root (`depth == 0`: the depth counts the nodes the
        /// parser drops, so a full-screen overlay under dropped containers is not mistaken for it); any other clickable
        /// full-screen node (a confirmation overlay whose `onClick` deletes) lends its whole subtree.
        // ponytail: fixed 90 % cut
        func screen(_ i: Int) -> Bool { area(0) > 0 && area(i) >= 0.9 * area(0) && (!nodes[i].clickable || nodes[i].depth == 0) }
        /// Node `i` when clickable, else its clickable ancestor (as `UITree.target` climbs), never the screen itself; nil: none.
        func clickable(_ i: Int) -> Int? { nodes[i].clickable ? i : ancestors(i).first { nodes[$0].clickable && !screen($0) } }
        /// wd1: what a touch at `pt` can act on, fail-closed (see the type's doc).
        func at(_ pt: CGPoint) -> [String] {
            let inside = nodes.indices.filter { nodes[$0].bounds.contains(pt) }
            var out = inside.flatMap { screen($0) ? names(nodes[$0]) : subtree(clickable($0) ?? $0) }
            if let i = inside.min(by: { area($0) < area($1) }), clickable(i) == nil {
                let leaf = i + 1 == nodes.count || nodes[i + 1].depth <= nodes[i].depth
                let c = leaf ? ancestors(i).first ?? i : i
                if !screen(c) { out += subtree(c, all: true) }   // the screen itself: not every label on it
            }
            return out
        }
        /// Every node `device.tap --text/--id` could pick (its clickable ancestor), as `UITree.target` finds them; one not
        /// clickable (no clickable ancestor) with all its descendants and what lies under its centre.
        func hits(text: String?, id: String?) -> [String] {
            var found: [String] = []
            _ = try? UITree.target(nodes, text: text, id: id, nth: 1, keep: { found.append($0.ref); return true })
            return nodes.indices.filter { found.contains(nodes[$0].ref) }.flatMap { i in
                nodes[i].clickable ? subtree(i) : subtree(i, all: true) + at(CGPoint(x: nodes[i].bounds.midX, y: nodes[i].bounds.midY))
            }
        }
        if let pt = point(s) { return at(pt) }
        guard s.action == "tap" else { return [] }
        let t = s.target
        if t.hasPrefix("id:") {
            let id = String(t.dropFirst(3))
            return [humanizeId(id)] + hits(text: nil, id: id)
        }
        // we1: as a hit (clickable ancestor; not clickable: all descendants and what lies under its centre, where the tap touches)
        if t.hasPrefix("ref:") {
            return nodes.indices.filter { nodes[$0].ref == String(t.dropFirst(4)) }.flatMap { i in
                let c = clickable(i) ?? i
                return subtree(c, all: !nodes[c].clickable) + at(CGPoint(x: nodes[i].bounds.midX, y: nodes[i].bounds.midY))
            }
        }
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
/// c2: `hungUp` (the client of `device.run` gone, `ClientHangup`) is read between steps only, so the step in flight (a
/// tap with `then: screen`) finishes whole; then the plan stops the same way and touches nothing more. A failing step
/// carries the `errors` joined so far in its message (the crash that explains a later "not found").
/// d7: a `destructive` step runs only when `confirmed` (the user's `--confirm-destructive`; the router never sets it for
/// an agent); else the plan stops before it: `{ok:false, refused:"destructive", at (1-based), done}`, the earlier
/// steps staying run. b3: a step `classify` finds destructive (by default by its own target text, no read) is refused the
/// same way, marked or not; a failing classification stops the plan. wf2: the screen is classified by each tap and
/// swipe's `guard` alone, in the command's own read (one read per step); the runner only sends it and reports the refusal.
struct FlowRunner: Sendable {
    typealias Act = @Sendable (_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue
    typealias Classify = @Sendable (FlowPlan.Step) async throws(ProtocolError) -> Bool
    var confirmed = false
    /// wf1: every tap and swipe of an unconfirmed plan carries `guard: "destructive"`, so the command classifies the node it
    /// resolved in its own read and refuses it before touching (`FlowClassifier.guardCheck`). `device.run` sets it; off
    /// only for tests of the runner's own steps.
    var guarded = false
    let classify: Classify
    let act: Act
    /// c2: the plan's client is gone; read between steps.
    var hungUp: @Sendable () -> Bool = { false }

    init(confirmed: Bool = false, classify: @escaping Classify = { FlowClassifier.destructive($0, nodes: []) }, act: @escaping Act) {
        self.confirmed = confirmed; self.classify = classify; self.act = act
    }

    /// ponytail: a fixed screen (`nodes`, never read again), for tests of `FlowClassifier.labels`.
    init(confirmed: Bool = false, nodes: @escaping @Sendable () async -> [UINode], act: @escaping Act) {
        self.init(confirmed: confirmed, classify: { s in FlowClassifier.destructive(s, nodes: await nodes()) }, act: act)
    }

    /// Marked by the plan, or a step `classify` finds destructive.
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
            if Task.isCancelled || hungUp() {
                throw ProtocolError(code: .timeout, message: "plan cancelled before step \(i + 1) (done: \(i))")
            }
            var refuse = false
            do { refuse = confirmed ? false : try await destructive(step) } catch {
                throw ProtocolError(code: error.code, message: "step \(i + 1) (\(step.action) \(step.target)): \(error.message)")
            }
            if refuse {
                return result(["ok": .bool(false), "refused": .string("destructive"), "at": .number(Double(i + 1)),
                               "done": .number(Double(i))])
            }
            var (command, args) = try Self.command(step)
            if step.expectSig != nil { args["then"] = .string("screen"); args["settle"] = .string("stable") }
            if guarded, !confirmed, command == "device.tap" || command == "device.swipe" { args["guard"] = .string("destructive") }
            let r: JSONValue
            do { r = try await act(command, args) } catch {
                if error.code == .conflict, error.message.hasPrefix(FlowClassifier.refusedPrefix) {   // wf1: the command's own guard
                    return result(["ok": .bool(false), "refused": .string("destructive"), "at": .number(Double(i + 1)),
                                   "done": .number(Double(i))])
                }
                var m = "step \(i + 1) (\(step.action) \(step.target)): \(error.message)"
                if !errors.isEmpty, let e = try? JSONEncoder().encode(JSONValue.array(errors)) { m += "; errors so far: " + String(decoding: e, as: UTF8.self) }
                throw ProtocolError(code: error.code, message: m)
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
