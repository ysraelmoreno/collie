import Testing
import Foundation
@testable import CollieDaemonKit

/// M5.5 (M10.1: measured in tokens, see `PastorContextLifecycleTests`): never in the Stop of the memory ask; shown to
/// the user, it never blocks the turn.
@Suite struct ContextAdviceTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func neverWithTheMemoryAsk() {
        #expect(ContextAdvice.decide(tokens: 300_000, isShepherd: true, memoryAsked: true, last: nil, now: t0) == nil)
        #expect(ContextAdvice.decide(tokens: 300_000, isShepherd: true, memoryAsked: false, last: nil, now: t0) != nil)
    }

    @Test func systemMessageNeverBlocks() throws {
        let o = try #require(MemoryHookClient.systemMessage("x").flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] })
        #expect(o == ["systemMessage": "x"])
    }
}
