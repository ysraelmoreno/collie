import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func tempDir() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("collie-ce-\(UUID().uuidString.prefix(8))/curator")
}
private func job(prompt: String = "x") -> CuratorJob {
    CuratorJob(id: UUID(), kind: .correction, store: "repo:/x", payload: .object(["prompt": .string(prompt)]), dedupe: UUID().uuidString,
               createdAt: Date(), attempts: 0)
}

/// Idiomas Task 4/8: the curator's texts in English, and what the daemon decides by code or fixed tag, never by translation.
@Suite(.serialized, .curatorEN) struct CuratorEnglishTests {
    @Test func reasonsAreEnglish() async throws {
        let fake = FakeCurator(), c = Curator(dir: tempDir(), runner: fake, clock: ManualClock())
        await c.setCap(0)
        #expect(await c.status().reason == "off")
        await c.setCap(2)
        #expect(Curator.consentMissing == "needs confirming in Preferences")
        #expect(ClaudeCuratorRunner.missing(["PATH": "/usr/bin"]) == "claude not found")
        #expect(CursorCuratorRunner.noLogin == "cursor has no login for the curator")
    }

    /// The Curator pauses on a runner's "unreadable" by its fixed tag: the same in en and pt.
    @Test func unreadableAnswerCountsAsJunkInEnglish() async throws {
        #expect(ClaudeCuratorRunner.unreadable.hasPrefix(CuratorTag.unreadable) && CursorCuratorRunner.unreadable.hasPrefix(CuratorTag.unreadable))
        let fake = FakeCurator(); fake.failOn = "x"
        fake.failMessage = L10n.$override.withValue(.pt) { ClaudeCuratorRunner.unreadable }   // produced in pt, read in en
        let c = Curator(dir: tempDir(), runner: fake, clock: ManualClock())
        for _ in 0..<10 { _ = await c.enqueue(job()) }
        await c.start { _, call in _ = try await call(CuratorCall(instructions: "", input: "x", schema: "{}")) }
        #expect(await waitFor(10) { (await c.status().reason ?? "").hasPrefix("invalid output in 10") })
        await c.stop()
    }

    @Test func parseSaysUnreadableByTagInBothLanguages() {
        for lang in Lang.allCases {
            L10n.$override.withValue(lang) {
                #expect(throws: ProtocolError.self) { try ClaudeCuratorRunner.parse("oops") }
                do throws(ProtocolError) { _ = try ClaudeCuratorRunner.parse("oops") } catch { #expect(error.message.hasPrefix(CuratorTag.unreadable)) }
                do { let r = try ClaudeCuratorRunner.parseOrNil("oops"); #expect(r == nil) } catch { Issue.record("parseOrNil threw: \(error)") }
            }
        }
    }

    /// A cursor login read in one language is still a `noLogin` in the other: the code travels, not the text.
    @Test func reasonCodesSurviveALanguageSwitch() async throws {
        let loggedOut = #"{"status":"unauthenticated","isAuthenticated":false}"#
        let a = L10n.$override.withValue(.pt) { CursorCuratorRunner.login(loggedOut) }
        #expect(a.code == .noLogin && a != CursorCuratorRunner.login(loggedOut))   // pt text, en text: only the code matches
        let fake = FakeCurator(); fake.avail = .unavailable("x", code: .noLogin)
        let c = Curator(dir: tempDir(), runners: [.claude: FakeCurator(), .cursor: fake], clock: ManualClock(), installed: { _ in true })
        #expect(await c.status().providers[1].code == .noLogin)
        let metered = FakeCurator(); metered.bills = .metered("API account (billed per token)")
        let m = Curator(dir: tempDir(), runners: [.claude: metered], clock: ManualClock(), installed: { _ in true })
        let s = await m.status()
        #expect(s.providers[0].code == .paidLogin && s.providers[0].consentNeeded)
        #expect(s.reason == "Claude: pay-per-use or unrecognized login; consent required")
    }

    @Test func junkTagIsFixed() {
        for lang in Lang.allCases {
            L10n.$override.withValue(lang) { #expect(Curator.junk("ops").message == "curator: junk answer (ops)") }
        }
    }
}
