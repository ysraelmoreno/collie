import Testing
import CollieProtocol
@testable import CollieClient

@Suite struct CursorMCPPolicyTests {
    let ask: [String: JSONValue] = ["target": .string("w"), "prompt": .string("go")]

    @Test func cursorAskWithoutNoWaitBecomesNoWait() {
        let a = CursorMCPPolicy.adapt(agent: "cursor", command: "ask", args: ask)
        #expect(a.args["no-wait"] == .bool(true))
        #expect(a.kind == .askDetached)
    }

    @Test func cursorAskAlreadyNoWaitIsLeftAlone() {
        var args = ask; args["no-wait"] = .bool(true)
        let a = CursorMCPPolicy.adapt(agent: "cursor", command: "ask", args: args)
        #expect(a.args == args && a.kind == nil)
    }

    @Test func claudeAndUnknownAgentsAreUntouched() {
        for agent in ["claude", "codex", "other", nil] as [String?] {
            #expect(CursorMCPPolicy.adapt(agent: agent, command: "ask", args: ask) == .init(args: ask, kind: nil))
            let w: [String: JSONValue] = ["target": .string("w"), "timeout": .number(1800)]
            #expect(CursorMCPPolicy.adapt(agent: agent, command: "wait", args: w) == .init(args: w, kind: nil))
        }
    }

    @Test func cursorWaitIsCappedBelowTheClientTimeout() {
        let cap = CursorMCPPolicy.waitCapSeconds
        #expect(cap == CursorMCPPolicy.callTimeoutSeconds - 10)
        for t: JSONValue? in [nil, .number(1800), .number(Double(cap + 1))] {
            var args: [String: JSONValue] = ["target": .string("w")]; args["timeout"] = t
            let a = CursorMCPPolicy.adapt(agent: "cursor", command: "wait", args: args)
            #expect(a.args["timeout"] == .number(Double(cap)) && a.kind == .waitCapped(cap))
        }
        var short: [String: JSONValue] = ["target": .string("w"), "timeout": .number(20)]
        let a = CursorMCPPolicy.adapt(agent: "cursor", command: "wait", args: short)
        #expect(a.args == short && a.kind == nil)
        short["timeout"] = .number(Double(cap))
        #expect(CursorMCPPolicy.adapt(agent: "cursor", command: "wait", args: short).kind == nil)
    }

    @Test func otherCommandsAreUntouched() {
        let a = CursorMCPPolicy.adapt(agent: "cursor", command: "check", args: ["target": .string("w")])
        #expect(a.args == ["target": .string("w")] && a.kind == nil)
    }

    @Test func detachedAskReplyGivesIdAndHowToGetTheReply() {
        let r: JSONValue = .object(["askId": .string("a1b2"), "target": .string("w"), "targetBusy": .bool(false)])
        let t = CursorMCPPolicy.askNote(result: r)
        #expect(t?.contains("a1b2") == true && t?.contains("ask result a1b2") == true && t?.contains("message") == true)
        #expect(t?.contains("\n") == false)
        #expect(CursorMCPPolicy.askNote(result: .object([:])) == nil)
    }

    @Test func cappedWaitTimeoutSaysItIsNotDone() {
        let t = CursorMCPPolicy.waitNote(target: "w", seconds: 50)
        #expect(t.contains("still working") && t.contains("wait") && t.contains("again") && !t.contains("\n"))
    }
}
