import Testing
import Foundation
import CollieProtocol
@testable import CollieDaemonKit

/// A fake device: records each command; a `then: screen` action answers the next of `screens` (a `sig`, maybe `errors`).
private actor Fake {
    var calls: [(String, [String: JSONValue])] = []
    var screens: [[String: JSONValue]]
    init(_ screens: [[String: JSONValue]] = []) { self.screens = screens }
    func act(_ c: String, _ a: [String: JSONValue]) -> JSONValue {
        calls.append((c, a))
        guard a["then"] == .string("screen") else { return .object([:]) }
        return .object(["screen": .object(screens.isEmpty ? [:] : screens.removeFirst())])
    }
    var commands: [String] { calls.map(\.0) }
}
private func screen(_ sig: String, errors: [String] = []) -> [String: JSONValue] {
    var o: [String: JSONValue] = ["sig": .string(sig)]
    if !errors.isEmpty { o["errors"] = .array(errors.map { .string($0) }) }
    return o
}
/// Runs `json` in a task of its own; `cancelAfter`: that task is cancelled once the fake has taken that many calls.
private func run(_ json: String, _ d: Fake, confirmed: Bool = false, cancelAfter: Int? = nil) async throws -> JSONValue {
    let plan = try FlowPlan.parse(Data(json.utf8))
    return try await Task {
        try await FlowRunner(confirmed: confirmed) { c, a async throws(ProtocolError) in
            let r = await d.act(c, a)
            if let n = cancelAfter, await d.calls.count == n { withUnsafeCurrentTask { $0?.cancel() } }
            return r
        }.run(plan)
    }.value
}
private func errors(_ r: JSONValue) -> [String] {
    guard case .object(let o) = r, case .array(let e)? = o["errors"] else { return [] }
    return e.compactMap { if case .string(let s) = $0 { s } else { nil } }
}

/// b4: a step with `expectSig` waits for the screen to settle in its own call, the crashes of every read reach the
/// result, and a cancelled plan stops before its next step.
extension DeviceCommandTests {
    @Suite struct FlowRunnerWaveBTests {
        static let three = """
        {"steps":[{"action":"tap","target":"Entrar","expectSig":"s1"},{"action":"key","target":"Enter","expectSig":"s2"},
                  {"action":"tap","target":"Carrinho","expectSig":"s3"}]}
        """

        @Test func expectSigStepAsksASettledScreenInItsOwnCall() async throws {
            let d = Fake([screen("s1")])
            let r = try await run(#"{"steps":[{"action":"tap","target":"Entrar","expectSig":"s1"}]}"#, d)
            #expect(r == .object(["ok": .bool(true), "steps": .number(1)]))
            let calls = await d.calls
            #expect(calls.map(\.0) == ["device.tap"])   // no device.screen apart
            #expect(calls.first?.1 == ["text": .string("Entrar"), "then": .string("screen"), "settle": .string("stable")])
        }

        @Test func stepWithoutExpectSigAsksNoScreen() async throws {
            let d = Fake()
            _ = try await run(#"{"steps":[{"action":"key","target":"Back"}]}"#, d)
            #expect(await d.calls.first?.1 == ["key": .string("Back")])
        }

        @Test func crashOnStep3WithTheSameScreenReachesTheResult() async throws {
            let d = Fake([screen("s1"), screen("s2"), screen("s3", errors: ["FATAL EXCEPTION: main"])])
            let r = try await run(Self.three, d)
            guard case .object(let o) = r else { Issue.record("\(r)"); return }
            #expect(o["ok"] == .bool(true) && o["steps"] == .number(3))
            #expect(errors(r) == ["FATAL EXCEPTION: main"])
        }

        @Test func errorsOfEveryReadAreJoinedAndKeptOnDivergence() async throws {
            let d = Fake([screen("s1", errors: ["ANR in com.shop"]), screen("other", errors: ["FATAL EXCEPTION: main"])])
            let r = try await run(Self.three, d)
            guard case .object(let o) = r else { Issue.record("\(r)"); return }
            #expect(o["ok"] == .bool(false) && o["stoppedAt"] == .number(2) && o["got"] == .string("other"))
            #expect(errors(r) == ["ANR in com.shop", "FATAL EXCEPTION: main"])
            #expect(await d.commands == ["device.tap", "device.key"])
        }

        @Test func errorsAreKeptOnADestructiveRefusal() async throws {
            let d = Fake([screen("s1", errors: ["FATAL EXCEPTION: main"])])
            let r = try await run(#"{"steps":[{"action":"tap","target":"Entrar","expectSig":"s1"},{"action":"tap","target":"Pagar"}]}"#, d)
            guard case .object(let o) = r else { Issue.record("\(r)"); return }
            #expect(o["refused"] == .string("destructive") && o["done"] == .number(1))
            #expect(errors(r) == ["FATAL EXCEPTION: main"])
        }

        @Test func cancelledAtStep2RunsNoStep3() async throws {
            let d = Fake([screen("s1"), screen("s2"), screen("s3")])
            let e = await #expect(throws: ProtocolError.self) { try await run(Self.three, d, cancelAfter: 2) }
            #expect(e?.code == .timeout && e?.message == "plan cancelled before step 3 (done: 2)")
            #expect(await d.commands == ["device.tap", "device.key"])   // no tap after the cancel
        }

        @Test func cancelledBeforeTheFirstStepRunsNothing() async throws {
            let d = Fake()
            let plan = try FlowPlan.parse(Data(Self.three.utf8))
            let e = await #expect(throws: ProtocolError.self) {
                try await Task {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await FlowRunner { c, a async throws(ProtocolError) in await d.act(c, a) }.run(plan)
                }.value
            }
            #expect(e?.message == "plan cancelled before step 1 (done: 0)")
            #expect(await d.commands.isEmpty)
        }

        @Test func aReplyWithoutAScreenSigIsAnError() async throws {
            let d = Fake()   // answers `then: screen` with an empty screen
            let e = await #expect(throws: ProtocolError.self) { try await run(Self.three, d) }
            #expect(e?.code == .internal && e?.message == "step 1: device.tap returned no screen sig")
        }
    }
}
