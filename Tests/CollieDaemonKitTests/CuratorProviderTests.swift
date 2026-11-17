import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func dir() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("collie-cp-\(UUID().uuidString.prefix(8))/curator")
}
private func job(_ input: String = "x") -> CuratorJob {
    CuratorJob(id: UUID(), kind: .correction, store: "repo:/x", payload: .object(["prompt": .string(input)]), dedupe: UUID().uuidString,
               createdAt: Date(), attempts: 0)
}
/// A fake that says it is the Cursor curator (limited, no usage, its own timeout and input cap).
private func cursorFake(inputMax: Int = 12_000) -> FakeCurator {
    let f = FakeCurator()
    f.info = CuratorProviderInfo(provider: .cursor, trust: .limited, destination: "Cursor", structuredOutput: false, reportsUsage: false,
                                 timeout: .seconds(120), inputMax: inputMax)
    f.output = CuratorOutput(json: .object(["ops": .array([])]), inputTokens: nil, outputTokens: nil, costUSD: nil)
    return f
}
/// Records each run's output (who answered) through the handler.
actor Outputs { var all: [CuratorOutput] = []; func add(_ o: CuratorOutput) { all.append(o) } }
private func recording(_ outs: Outputs) -> Curator.Handler {
    { j, call in await outs.add(try await call(CuratorCall(instructions: "i", input: "\(j.payload)", schema: "{}"))) }
}

@Suite(.serialized) struct CuratorProviderTests {
    @Test func defaultsToClaude() async throws {
        let c = Curator(dir: dir(), runners: [.claude: FakeCurator(), .cursor: cursorFake()], clock: ManualClock())
        let s = await c.status()
        #expect(s.provider == "claude" && s.model == "haiku" && s.trust == "full" && s.destination == "Anthropic")
        #expect(await c.active.provider == .claude)
    }

    @Test func switchNeedsConsent() async throws {
        let c = Curator(dir: dir(), runners: [.claude: FakeCurator(), .cursor: cursorFake()], clock: ManualClock())
        await #expect(throws: ProtocolError(code: .unavailable, message: "falta confirmar nas Preferências")) {
            try await c.setProvider(.cursor, model: nil)
        }
        #expect(await c.status().provider == "claude")
        await c.consent(.cursor)
        try await c.setProvider(.cursor, model: "auto")
        let s = await c.status()
        #expect(s.provider == "cursor" && s.model == "auto" && s.trust == "limited" && s.destination == "Cursor")
        try await c.setProvider(.claude, model: nil)   // back to Claude: never needs consent
        #expect(await c.status().provider == "claude")
    }

    /// The choice survives a restart (config.json); Claude's model stays in `model` for an older daemon.
    @Test func providerPersists() async throws {
        let d = dir()
        let a = Curator(dir: d, runners: [.claude: FakeCurator(), .cursor: cursorFake()], clock: ManualClock())
        await a.consent(.cursor); try await a.setProvider(.cursor, model: "auto")
        let b = Curator(dir: d, runners: [.claude: FakeCurator(), .cursor: cursorFake()], clock: ManualClock())
        let s = await b.status()
        #expect(s.provider == "cursor" && s.model == "auto")
        let raw = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: d.appendingPathComponent("config.json")))
        #expect(raw["model"] == .string("haiku"))
    }

    @Test func switchKeepsQueue() async throws {
        let claude = FakeCurator(), cursor = cursorFake()
        claude.avail = .unavailable("sem modelo")
        let c = Curator(dir: dir(), runners: [.claude: claude, .cursor: cursor], clock: ManualClock())
        for _ in 0..<3 { _ = await c.enqueue(job()) }
        await c.start { j, call in _ = try await call(CuratorCall(instructions: "i", input: "\(j.payload)", schema: "{}")) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(claude.calls == 0 && cursor.calls == 0)
        await c.consent(.cursor); try await c.setProvider(.cursor, model: nil)
        #expect(await waitFor(10) { cursor.calls == 3 })
        #expect(claude.calls == 0 && cursor.models == ["", "", ""])
        await c.stop()
    }

    @Test func runningJobFinishesOnOld() async throws {
        let claude = FakeCurator(), cursor = cursorFake()
        claude.gated = true
        let c = Curator(dir: dir(), runners: [.claude: claude, .cursor: cursor], clock: ManualClock())
        let outs = Outputs()
        _ = await c.enqueue(job("a")); _ = await c.enqueue(job("b"))
        await c.start(handler: recording(outs))
        #expect(await waitFor(10) { claude.calls == 1 })
        await c.consent(.cursor); try await c.setProvider(.cursor, model: nil)
        claude.open()
        #expect(await waitFor(10) { await outs.all.count == 2 })
        #expect(claude.calls == 1 && cursor.calls == 1)
        #expect(await outs.all.map(\.curatedBy.provider) == ["claude", "cursor"])
        await c.stop()
    }

    @Test func curatedByFromActive() async throws {
        let outs = Outputs()
        let c = Curator(dir: dir(), runners: [.claude: FakeCurator(), .cursor: cursorFake()], clock: ManualClock())
        await c.consent(.cursor); try await c.setProvider(.cursor, model: "auto")
        _ = await c.enqueue(job())
        await c.start(handler: recording(outs))
        #expect(await waitFor(10) { await outs.all.count == 1 })
        #expect(await outs.all.first?.curatedBy == CuratedBy(provider: "cursor", model: "auto", trust: .limited))
        await c.stop()
    }

    @Test func eventCarriesProviderAndModel() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("collie-cp-\(UUID().uuidString.prefix(8))")
        let log = MemoryEventLog(dir: base.appendingPathComponent("learning"))
        let c = Curator(dir: base.appendingPathComponent("curator"), runners: [.claude: FakeCurator(), .cursor: cursorFake()],
                        clock: ManualClock(), events: log)
        await c.consent(.cursor); try await c.setProvider(.cursor, model: "auto")
        _ = await c.enqueue(job())
        await c.start(handler: recording(Outputs()))
        #expect(await waitFor(10) { log.flush(); return log.read(since: Date().addingTimeInterval(-60)).contains { $0.type == .curatorRun } })
        let e = try #require(log.read(since: Date().addingTimeInterval(-60)).first { $0.type == .curatorRun })
        #expect(e.provider == "cursor" && e.model == "auto" && e.inputTokens == nil && e.costUSD == nil)
        await c.stop()
    }

    /// A provider that reports no usage adds nothing (the status stays a Double sum for older apps).
    @Test func nilUsageSumsZero() async throws {
        let c = Curator(dir: dir(), runners: [.claude: FakeCurator(), .cursor: cursorFake()], clock: ManualClock())
        await c.consent(.cursor); try await c.setProvider(.cursor, model: nil)
        _ = await c.enqueue(job())
        await c.start(handler: recording(Outputs()))
        #expect(await waitFor(10) { await c.status().today == 1 })
        let s = await c.status()
        #expect(s.inputTokens == 0 && s.outputTokens == 0 && s.costUSD == 0)
        await c.stop()
    }

    @Test func timeoutAndInputMaxFromInfo() async throws {
        let cursor = cursorFake(inputMax: 500)
        let c = Curator(dir: dir(), runners: [.claude: FakeCurator(), .cursor: cursor], clock: ManualClock())
        await c.consent(.cursor); try await c.setProvider(.cursor, model: nil)
        _ = await c.enqueue(job(String(repeating: "x", count: 2_000)))
        await c.start(handler: recording(Outputs()))
        #expect(await waitFor(10) { cursor.calls == 1 })
        #expect(cursor.inputs[0].unicodeScalars.count <= 500 && cursor.timeouts == [.seconds(120)])
        await c.stop()
    }

    /// A provider chosen in config.json with no runner in this build (or no consent) is unavailable, never run.
    @Test func statusHasProvider() async throws {
        let d = dir()
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Data(#"{"provider":"cursor"}"#.utf8).write(to: d.appendingPathComponent("config.json"))
        let noConsent = Curator(dir: d, runners: [.claude: FakeCurator(), .cursor: cursorFake()], clock: ManualClock())
        #expect(await noConsent.status().reason == "falta confirmar nas Preferências")
        try Data(#"{"provider":"cursor","consented":["cursor"]}"#.utf8).write(to: d.appendingPathComponent("config.json"))
        let noRunner = Curator(dir: d, runner: FakeCurator(), clock: ManualClock())
        let s = await noRunner.status()
        #expect(s.provider == "cursor" && s.available == false && s.reason == "cursor não encontrado")
    }
}
