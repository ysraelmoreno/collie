import Foundation
import CollieProtocol

/// A plan for `device run --plan <file>` (d6, spec docs/superpowers/specs/2026-11-26-device-flows-design.md, onda 2):
/// steps in the FlowActionLog's vocabulary. `target` as the log writes it: tap `<text>`, `id:<id>` or `x,y`; swipe
/// `x1,y1,x2,y2`; key `<key>`; launch `<package>` or `<package>/<activity>`; text: `text` (or `target`) is typed.
/// The file is data (screen names, texts), never instructions.
struct FlowPlan: Codable, Sendable, Equatable {
    struct Step: Codable, Sendable, Equatable {
        var action: String
        var target: String = ""
        var text: String? = nil
        var expectSig: String? = nil
        var destructive: Bool? = nil   // d7: runs only with the user's confirmation (FlowRunner.confirmed)
    }
    var steps: [Step]

    static let maxSteps = 200
    /// The plan file's size limit (200 steps fit many times over).
    static let maxBytes = 256 * 1024

    /// The plan in `data`, every step checked before any runs.
    static func parse(_ data: Data) throws(ProtocolError) -> FlowPlan {
        let plan: FlowPlan
        do { plan = try JSONDecoder().decode(FlowPlan.self, from: data) } catch {
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

/// Runs a `FlowPlan` in order through `act`: the same device commands (`device.tap`/`text`/`swipe`/`key`/`launch`)
/// an agent calls, so the flow log records them too. After a step with `expectSig` it reads `device.screen` and
/// stops at the first signature that differs: `{ok:false, stoppedAt (1-based), expected, got, screen}`; else
/// `{ok:true, steps:N}`. A failing command stops the plan with its error, naming the step.
/// d7: a `destructive` step runs only when `confirmed` (the user's `--confirm-destructive`; the router never sets it for
/// an agent); else the plan stops before it: `{ok:false, refused:"destructive", at (1-based), done}`, the earlier
/// steps staying run.
struct FlowRunner: Sendable {
    typealias Act = @Sendable (_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue
    var confirmed = false
    let act: Act

    init(confirmed: Bool = false, act: @escaping Act) { self.confirmed = confirmed; self.act = act }

    func run(_ plan: FlowPlan) async throws(ProtocolError) -> JSONValue {
        for (i, step) in plan.steps.enumerated() {
            if step.destructive == true, !confirmed {
                return .object(["ok": .bool(false), "refused": .string("destructive"), "at": .number(Double(i + 1)),
                                "done": .number(Double(i))])
            }
            let (command, args) = try Self.command(step)
            do { _ = try await act(command, args) } catch {
                throw ProtocolError(code: error.code, message: "step \(i + 1) (\(step.action) \(step.target)): \(error.message)")
            }
            guard let want = step.expectSig else { continue }   // no expectSig: the step runs unchecked
            let screen = try await act("device.screen", [:])
            guard case .object(let o) = screen, case .string(let got)? = o["sig"] else {
                throw ProtocolError(code: .internal, message: "step \(i + 1): device.screen returned no sig")
            }
            if got != want {
                return .object(["ok": .bool(false), "stoppedAt": .number(Double(i + 1)), "expected": .string(want),
                                "got": .string(got), "screen": screen])
            }
        }
        return .object(["ok": .bool(true), "steps": .number(Double(plan.steps.count))])
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
            if let xy = ints(2) { return ("device.tap", ["x": .string(xy[0]), "y": .string(xy[1])]) }
            guard !t.isEmpty else { throw bad("tap needs a target (a label, id:<id> or x,y)") }
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
