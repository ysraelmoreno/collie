import Testing
import Foundation
@testable import CollieDaemonKit

@Suite struct PluginHooksTests {
    let project = URL(fileURLWithPath: "/work/proj")

    func payload(_ tool: String, _ input: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["tool_name": tool, "tool_input": input])
    }

    @Test func editedFilesRelative() {
        for (tool, key) in [("Write", "file_path"), ("Edit", "file_path"), ("MultiEdit", "file_path"), ("NotebookEdit", "notebook_path")] {
            let d = payload(tool, [key: "/work/proj/Sources/X/Foo.swift"])
            #expect(PluginHooks.editedFiles(toolPayload: d, project: project) == ["Sources/X/Foo.swift"], "\(tool)")
        }
    }

    @Test func editedFilesRejects() {
        #expect(PluginHooks.editedFiles(toolPayload: payload("Write", ["file_path": "/etc/passwd"]), project: project).isEmpty)
        #expect(PluginHooks.editedFiles(toolPayload: payload("Write", ["file_path": "/work/proj/../other/a.swift"]), project: project).isEmpty)
        #expect(PluginHooks.editedFiles(toolPayload: payload("Write", ["file_path": "/work/project2/a.swift"]), project: project).isEmpty)
        #expect(PluginHooks.editedFiles(toolPayload: payload("Write", ["file_path": "/work/proj"]), project: project).isEmpty)
        #expect(PluginHooks.editedFiles(toolPayload: payload("Bash", ["file_path": "/work/proj/a"]), project: project).isEmpty)
        #expect(PluginHooks.editedFiles(toolPayload: Data("nope".utf8), project: project).isEmpty)
        let big = payload("Write", ["file_path": "/work/proj/a", "content": String(repeating: "x", count: 70_000)])
        #expect(PluginHooks.editedFiles(toolPayload: big, project: project).isEmpty)
    }

    @Test func editedFilesResolvesDotDotInside() {
        let d = payload("Edit", ["file_path": "/work/proj/a/../b/C.swift"])
        #expect(PluginHooks.editedFiles(toolPayload: d, project: project) == ["b/C.swift"])
    }

    @Test func eventJSONSortedAndDecodable() throws {
        let d = PluginHooks.eventJSON(event: .edit, project: project, files: ["a/b.swift"], agent: "claude", paddock: "p")
        #expect(String(data: d, encoding: .utf8) ==
            #"{"agent":"claude","apiVersion":1,"event":"edit","files":["a/b.swift"],"paddock":"p","project":"/work/proj"}"#)
    }

    @Test func verdictParsing() {
        func v(_ s: String) -> PluginHooks.Verdict? { PluginHooks.verdict(stdout: Data(s.utf8)) }
        #expect(v("") == nil)
        #expect(v("{}") == nil)
        #expect(v("garbage") == nil)
        #expect(v(#"{"guide":5}"#) == nil)
        #expect(v(#"{"guide":"  \n "}"#) == nil)
        #expect(v(#"{"guide":"oi"}"#) == .init(guide: "oi"))
        #expect(v(#"{"block":"no"}"#) == .init(block: "no"))
        #expect(v(#"{"guide":"\#(String(repeating: "a", count: 3000))"}"#)?.guide?.count == 2000)
        #expect(PluginHooks.verdict(stdout: Data(repeating: 0x20, count: 70_000)) == nil)
        let big = Data(#"{"guide":"\#(String(repeating: "a", count: 70_000))"}"#.utf8)
        #expect(PluginHooks.verdict(stdout: big) == nil)
    }

    @Test func mergeOrderAndPrefix() {
        let m = PluginHooks.merge([("zeta", .init(guide: "z")), ("alfa", .init(guide: "a"))], event: .edit)
        #expect(m == .init(guide: "[plug-in alfa] a\n[plug-in zeta] z"))
    }

    @Test func mergeEditBlockWins() {
        let m = PluginHooks.merge([("a", .init(guide: "g")), ("b", .init(block: "x"))], event: .edit)
        #expect(m.guide == nil)
        #expect(m.block == "[plug-in b] x\n[plug-in a] g")
    }

    @Test func mergeStopDropsGuide() {
        #expect(PluginHooks.merge([("a", .init(guide: "g"))], event: .stop) == .init())
        #expect(PluginHooks.merge([("a", .init(guide: "g", block: "b"))], event: .stop) == .init(block: "[plug-in a] b"))
    }

    @Test func mergeCapsTotal() {
        let long = String(repeating: "q", count: 2000)
        let m = PluginHooks.merge((0..<5).map { ("p\($0)", .init(guide: long)) }, event: .edit)
        #expect(m.guide?.count == 4000)
    }

    @Test func claudeOutputs() throws {
        #expect(PluginHooks.claudeToolOutput(.init()) == nil)
        let g = try #require(PluginHooks.claudeToolOutput(.init(guide: "use \"X\"")))
        let go = try #require(JSONSerialization.jsonObject(with: Data(g.utf8)) as? [String: Any])
        let h = try #require(go["hookSpecificOutput"] as? [String: String])
        #expect(h == ["hookEventName": "PostToolUse", "additionalContext": "use \"X\""])
        let b = try #require(PluginHooks.claudeToolOutput(.init(block: "no")))
        let bo = try #require(JSONSerialization.jsonObject(with: Data(b.utf8)) as? [String: String])
        #expect(bo == ["decision": "block", "reason": "no"])
        #expect(PluginHooks.claudeStopReason(.init(block: "r")) == "r")
        #expect(PluginHooks.claudeStopReason(.init(guide: "g")) == nil)
    }

    // D1: Cursor's tool hooks (payloads measured with cursor-agent 2026.11.22, spike REPORT §11)
    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/cursor/\(name).json"))
    }

    @Test func cursorWritePayloadIsAnEditWithARelativePath() throws {
        let d = try Self.fixture("postToolUse-write")
        #expect(PluginHooks.cursorToolPhase(d) == .post)
        #expect(PluginHooks.editedFiles(toolPayload: d, project: URL(fileURLWithPath: "/proj")) == ["Sources/App/hello.txt"])
    }

    @Test func cursorOtherToolsAreNotEdits() throws {
        let d = try Self.fixture("preToolUse-read")
        #expect(PluginHooks.cursorToolPhase(d) == .pre)
        #expect(PluginHooks.editedFiles(toolPayload: d, project: URL(fileURLWithPath: "/proj")).isEmpty)
        // afterFileEdit is not registered: the same write would count twice
        #expect(PluginHooks.cursorToolPhase(try Self.fixture("afterFileEdit")) == nil)
        #expect(PluginHooks.cursorToolPhase(Data("nope".utf8)) == nil)
    }

    @Test func cursorToolOutputIsAdditionalContextAndBlockDegradesToGuide() throws {
        func ctx(_ v: PluginHooks.Verdict) throws -> String? {
            guard let out = PluginHooks.cursorToolOutput(v) else { return nil }
            let o = try #require(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
            #expect(Set(o.keys) == ["additional_context"], "\(o)")   // postToolUse cannot deny: no `permission`
            return o["additional_context"] as? String
        }
        #expect(try ctx(.init(guide: "follow Foo")) == "follow Foo")
        #expect(try ctx(.init(block: "no raw SQL")) == "no raw SQL")
        #expect(try ctx(.init(guide: "g", block: "b")) == "b")
        #expect(PluginHooks.cursorToolOutput(.init()) == nil)
    }

    @Test func cursorStopBlocksOnceThenTheContinuationEndsQuietly() {
        var turn = PluginTurn()
        let t = UUID()
        turn.add(["A.swift", "B.swift", "A.swift"], to: t)
        #expect(turn.cursorEnd(t) == ["A.swift", "B.swift"])   // turn 1 ends: the plug-ins are asked
        turn.continued(t)                                        // ... one blocked: its text went in as a prompt
        turn.add(["A.swift"], to: t)                             // the continuation edits again
        #expect(turn.cursorEnd(t).isEmpty)                       // its end never runs them again (one prompt per turn)
        turn.add(["C.swift"], to: t)
        #expect(turn.cursorEnd(t) == ["C.swift"])                // the next turn is a new one
    }
}
