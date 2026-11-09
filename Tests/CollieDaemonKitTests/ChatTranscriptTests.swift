import Testing
import Foundation
import CollieCore
@testable import CollieDaemonKit

@Suite struct ChatTranscriptTests {
    private func entries(_ json: String, secrets: Set<String> = []) -> [ChatEntry] {
        ChatTranscript.entries(Data(json.utf8), at: 7, secrets: secrets)
    }

    @Test func userAndAssistantText() {
        let u = entries(#"{"type":"user","message":{"role":"user","content":"oi <system-reminder>x</system-reminder>"}}"#)
        #expect(u.map(\.kind) == [.user] && u[0].text == "oi")
        let a = entries(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"feito"},{"type":"thinking","thinking":"x"}]}}"#)
        #expect(a.map(\.kind) == [.assistant] && a[0].text == "feito")
    }

    @Test func editCarriesItsDiffAndResultMatchesById() {
        let use = entries(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/a.swift","old_string":"a","new_string":"b"}}]}}"#)
        #expect(use.count == 1 && use[0].tool == "Edit" && use[0].summary == "/a.swift" && use[0].old == "a" && use[0].new == "b" && use[0].toolId == "t1")
        let res = entries(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":[{"type":"text","text":"falhou"}]}]}}"#)
        #expect(res.count == 1 && res[0].kind == .toolResult && res[0].toolId == "t1" && res[0].isError == true && res[0].text == "falhou")
    }

    @Test func resultPreviewIsCappedAndSecretsScrubbed() {
        let big = String(repeating: "x", count: ChatTranscript.resultMax * 2)
        let r = entries(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"\#(big) SEGREDO123"}]}}"#, secrets: ["SEGREDO123"])
        #expect(r[0].text.count <= ChatTranscript.resultMax && !r[0].text.contains("SEGREDO123"))   // a 16 KiB blob must not stall the scrub
        let long = entries(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"\#(String(repeating: "a b ", count: 5000))"}]}}"#)
        #expect(long[0].text.count == ChatTranscript.resultMax)
        let s = entries(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"a chave é SEGREDO123"}]}}"#, secrets: ["SEGREDO123"])
        #expect(!s[0].text.contains("SEGREDO123"))
    }

    @Test func metaSidechainAndJunkAreIgnored() {
        #expect(entries(#"{"type":"user","isMeta":true,"message":{"role":"user","content":"x"}}"#).isEmpty)
        #expect(entries(#"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":"x"}}"#).isEmpty)
        #expect(entries("not json").isEmpty)
    }
}
