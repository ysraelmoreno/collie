import Testing
import Foundation
import CollieProtocol

@Suite struct HookPayloadTests {
    @Test func parsesUserPromptSubmitPayload() {
        let d = Data(#"{"hook_event_name":"UserPromptSubmit","prompt":"why postgres?","cwd":"/x"}"#.utf8)
        #expect(HookPayload.userPromptSubmitPrompt(stdinJSON: d) == "why postgres?")
        #expect(HookPayload.userPromptSubmitPrompt(stdinJSON: Data("nope".utf8)) == nil)
        #expect(HookPayload.userPromptSubmitPrompt(stdinJSON: Data(#"{"x":1}"#.utf8)) == nil)
    }
    @Test func promptIsCappedAt64KiBOnACharacterBoundary() {
        let big = String(repeating: "é", count: 100_000)   // 2 bytes each
        let d = (try? JSONSerialization.data(withJSONObject: ["prompt": big])) ?? Data()
        let p = HookPayload.userPromptSubmitPrompt(stdinJSON: d) ?? ""
        #expect(p.utf8.count <= 64 * 1024 + 3 && p.utf8.count > 60_000)
    }
    @Test func sessionIdOnlyWhenUUID() {
        let id = "3f2a9c1e-7b4d-4e58-9a6b-0c1d2e3f4a5b"
        #expect(HookPayload.sessionId(stdinJSON: Data(#"{"session_id":"\#(id)","transcript_path":""}"#.utf8)) == id)
        #expect(HookPayload.sessionId(stdinJSON: Data(#"{"session_id":"../../etc"}"#.utf8)) == nil)
        #expect(HookPayload.sessionId(stdinJSON: Data(#"{"session_id":7}"#.utf8)) == nil)
        #expect(HookPayload.sessionId(stdinJSON: Data(#"{"x":1}"#.utf8)) == nil)
        #expect(HookPayload.sessionId(stdinJSON: Data("nope".utf8)) == nil)
    }
}
