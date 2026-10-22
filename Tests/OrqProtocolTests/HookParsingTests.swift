import Testing
import Foundation
import OrqProtocol

@Suite struct HookParsingTests {
    @Test func parsesClaudeStopFromField() {
        let d = Data(#"{"last_assistant_message":"hi","transcript_path":"/nonexistent"}"#.utf8)
        #expect(HookPayload.claudeStopMessage(stdinJSON: d) == "hi")
    }
    @Test func parsesClaudeStopFromTranscript() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: f) }
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"q"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"first"}]}}"#,
            "garbage{",
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"sec"},{"type":"tool_use"},{"type":"text","text":"ond"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
        let d = Data(#"{"transcript_path":"\#(f.path)"}"#.utf8)
        #expect(HookPayload.claudeStopMessage(stdinJSON: d) == "second")
    }
    @Test func claudeStopSkipsNonTextAssistantLine() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: f) }
        let lines = [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"keep"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use"}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
        #expect(HookPayload.claudeStopMessage(stdinJSON: Data(#"{"transcript_path":"\#(f.path)"}"#.utf8)) == "keep")
    }
    @Test func parsesCodexNotify() {
        #expect(HookPayload.codexNotifyMessage(argJSON: #"{"type":"agent-turn-complete","last-assistant-message":"done"}"#) == "done")
        #expect(HookPayload.codexNotifyMessage(argJSON: #"{"type":"other","last-assistant-message":"done"}"#) == nil)
    }
}
