import Testing
import Foundation
import CollieProtocol
@testable import CollieDaemonKit

/// A fake device: records each command and answers a `then: screen` action with the next signature of `sigs`.
private actor FakeDevice {
    var calls: [(String, [String: JSONValue])] = []
    var sigs: [String]
    var fail: String?
    init(sigs: [String] = [], fail: String? = nil) { self.sigs = sigs; self.fail = fail }
    func act(_ c: String, _ a: [String: JSONValue]) throws(ProtocolError) -> JSONValue {
        calls.append((c, a))
        if c == fail { throw ProtocolError(code: .notFound, message: "no such element") }
        guard a["then"] == .string("screen") else { return .object([:]) }
        return .object(["screen": .object(["sig": .string(sigs.isEmpty ? "" : sigs.removeFirst()), "text": .string("screen")])])
    }
    var commands: [String] { calls.map(\.0) }
}

private func runner(_ d: FakeDevice) -> FlowRunner {
    FlowRunner { c, a async throws(ProtocolError) in try await d.act(c, a) }
}
private func plan(_ json: String) throws -> FlowPlan { try FlowPlan.parse(Data(json.utf8)) }
private func refusal(_ json: String) -> String? {
    do { _ = try FlowPlan.parse(Data(json.utf8)); return nil } catch { return error.message }
}

struct FlowRunnerTests {
    static let five = """
    {"steps":[{"action":"launch","target":"com.shop/.Main","expectSig":"s1"},
              {"action":"tap","target":"Entrar","expectSig":"s2"},
              {"action":"text","target":"","text":"ana@x.dev"},
              {"action":"key","target":"Enter","expectSig":"s3"},
              {"action":"swipe","target":"10,800,10,200","expectSig":"s4"}]}
    """

    @Test func fiveStepPlanRunsToTheEnd() async throws {
        let d = FakeDevice(sigs: ["s1", "s2", "s3", "s4"])
        let r = try await runner(d).run(try plan(Self.five))
        #expect(r == .object(["ok": .bool(true), "steps": .number(5)]))
        #expect(await d.commands == ["device.launch", "device.tap", "device.text", "device.key", "device.swipe"])
        let calls = await d.calls
        let settled: [String: JSONValue] = ["then": .string("screen"), "settle": .string("stable")]
        #expect(calls[0].1 == settled.merging(["package": .string("com.shop"), "activity": .string(".Main")]) { a, _ in a })
        #expect(calls[1].1 == settled.merging(["text": .string("Entrar")]) { a, _ in a })
        #expect(calls[2].1 == ["text": .string("ana@x.dev")])   // no expectSig: no screen asked
        #expect(calls[4].1 == settled.merging(["x1": .string("10"), "y1": .string("800"), "x2": .string("10"), "y2": .string("200")]) { a, _ in a })
    }

    @Test func stopsAtTheFirstDivergenceAndRunsNothingAfter() async throws {
        let d = FakeDevice(sigs: ["s1", "other"])
        let r = try await runner(d).run(try plan(Self.five))
        guard case .object(let o) = r else { Issue.record("\(r)"); return }
        #expect(o["ok"] == .bool(false) && o["stoppedAt"] == .number(2))
        #expect(o["expected"] == .string("s2") && o["got"] == .string("other"))
        #expect(o["screen"] == .object(["sig": .string("other"), "text": .string("screen")]))
        #expect(await d.commands == ["device.launch", "device.tap"])   // text, key, swipe never ran
    }

    @Test func stepWithoutExpectSigRunsUnchecked() async throws {
        let d = FakeDevice()
        let r = try await runner(d).run(try plan(#"{"steps":[{"action":"tap","target":"id:com.shop:id/ok"},{"action":"tap","target":"120,340"}]}"#))
        #expect(r == .object(["ok": .bool(true), "steps": .number(2)]))
        let calls = await d.calls
        #expect(calls.map(\.0) == ["device.tap", "device.tap"])   // no device.screen read
        #expect(calls[0].1 == ["id": .string("com.shop:id/ok")] && calls[1].1 == ["x": .string("120"), "y": .string("340")])
    }

    @Test func refusesAnInvalidPlanWithTheReason() {
        #expect(refusal("not json")?.contains("not JSON") == true)
        #expect(refusal(#"{"steps":[{"target":"OK"}]}"#)?.contains("missing 'action'") == true)
        #expect(refusal(#"{"steps":[{"action":"fly","target":"OK"}]}"#)?.contains("step 1: unknown action 'fly'") == true)
        #expect(refusal(#"{"steps":[{"action":"tap","target":"OK"},{"action":"swipe","target":"1,2"}]}"#)?.contains("step 2: swipe target") == true)
        #expect(refusal(#"{"steps":[{"action":"tap","target":"OK","expectSig":3}]}"#)?.contains("wrong type") == true)
    }

    @Test func refusesAnEmptyPlan() {
        #expect(refusal(#"{"steps":[]}"#) == "invalid plan: no steps")
    }

    @Test func refusesAPlanOverTwoHundredSteps() throws {
        let step = #"{"action":"key","target":"Back"}"#
        #expect(refusal(#"{"steps":["# + Array(repeating: step, count: 201).joined(separator: ",") + "]}") == "invalid plan: 201 steps, at most 200")
        #expect(try plan(#"{"steps":["# + Array(repeating: step, count: 200).joined(separator: ",") + "]}").steps.count == 200)
    }

    @Test func aFailingStepStopsThePlanNamingIt() async throws {
        let d = FakeDevice(fail: "device.tap")
        let e = await #expect(throws: ProtocolError.self) {
            try await runner(d).run(try plan(#"{"steps":[{"action":"key","target":"Home"},{"action":"tap","target":"Entrar"},{"action":"key","target":"Back"}]}"#))
        }
        #expect(e?.message == "step 2 (tap Entrar): no such element")
        #expect(await d.commands == ["device.key", "device.tap"])
    }

    @Test func planFileFollowsTheBodyFileRules() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collie-plan-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big.json")
        try Data(count: FlowPlan.maxBytes + 1).write(to: big)
        let e = #expect(throws: ProtocolError.self) { try CommandRouter.readBodyFile(big.path, allowed: nil, flag: "--plan", limit: FlowPlan.maxBytes) }
        #expect(e?.message == "--plan is \(FlowPlan.maxBytes + 1) bytes, at most \(FlowPlan.maxBytes)")
        let notFile = #expect(throws: ProtocolError.self) { try CommandRouter.readBodyFile(dir.path, allowed: nil, flag: "--plan", limit: FlowPlan.maxBytes) }
        #expect(notFile?.message == "--plan must be a regular file")
        let link = dir.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: big)
        #expect((#expect(throws: ProtocolError.self) { try CommandRouter.readBodyFile(link.path, allowed: nil, flag: "--plan", limit: FlowPlan.maxBytes) })?.message == "--plan may not be a symlink")
    }

    @Test func commandIsDeclaredWithHelp() throws {
        let spec = try #require(Commands.spec("device.run"))
        #expect(spec.params.map(\.name) == ["plan", "panel", "serial", "confirm-destructive"] && spec.params[0].required)
        let help = try #require(ArgvParser.help(["device", "run", "--help"]))
        #expect(help.hasPrefix("usage: collie device run --plan <plan>") && help.contains("--serial"), "\(help)")
        #expect(try ArgvParser.parse(["device", "run", "--plan", "p.json", "--serial", "emulator-5554"]).args
                == ["plan": .string("p.json"), "serial": .string("emulator-5554")])
    }
}
