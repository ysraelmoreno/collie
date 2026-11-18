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
    { j, call in
        guard case .object(let o) = j.payload, case .string(let s)? = o["prompt"] else { return }
        await outs.add(try await call(CuratorCall(instructions: "i", input: s, schema: "{}")))
    }
}

@Suite(.serialized) struct CuratorProviderTests {
    @Test func defaultsToClaude() async throws {
        let c = Curator(dir: dir(), runners: [.claude: FakeCurator(), .cursor: cursorFake()], clock: ManualClock())
        let s = await c.status()
        #expect(s.provider == "claude" && s.model == "haiku" && s.trust == "full" && s.destination == "Anthropic")
        #expect(await c.active.provider == .claude)
    }

    /// Review A6: a model id is `^[A-Za-z0-9][A-Za-z0-9._:/-]*$` ("" = the provider's default); else nothing is stored.
    @Test func modelIdValidated() async throws {
        let c = Curator(dir: dir(), runners: [.claude: FakeCurator(), .cursor: cursorFake()], clock: ManualClock())
        await c.consent(.cursor)
        for ok in ["auto", "sonnet", "gpt-5.4-nano-low", "vendor/model:3.1_x", ""] {
            try await c.setProvider(.cursor, model: ok)
            #expect(await c.status().model == ok, "\(ok)")
        }
        for bad in ["--yolo", "-H", "a b", "x;rm", "ok\n--force", "/abs", ".hidden", "é"] {
            await #expect(throws: ProtocolError(code: .invalidArgs, message: Curator.badModel), "\(bad)") {
                try await c.setProvider(.cursor, model: bad)
            }
        }
        #expect(await c.status().model == "")
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
        let mark = "DADOS-" + String(repeating: "c", count: 32)
        _ = await c.enqueue(job("\(mark)\n" + String(repeating: "x", count: 2_000) + "\n\(mark)"))
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
        #expect(s.provider == "cursor" && s.available == false && s.reason == Curator.notInBuild)
    }

    /// Task 7: the billing policy is the Curator's, the same for any provider (no Claude in it): only `included` runs.
    @Test func billingPolicyIsGeneric() async throws {
        for (p, fake) in [(CuratorProvider.claude, FakeCurator()), (.cursor, cursorFake())] {
            let c = Curator(dir: dir(), runners: [p: fake], clock: ManualClock())
            if p != .claude { await c.consent(p); try await c.setProvider(p, model: nil) }
            let name = p.rawValue.capitalized
            // Task 12: metered/unknown need the provider's consent on file (Cursor's sheet already gave it; Claude's not yet)
            for (b, ok) in [(CuratorBilling.included("plano"), true), (.metered("API"), p != .claude), (.unknown, p != .claude)] {
                fake.bills = b
                let s = await c.status()
                #expect(s.available == ok, "\(p) \(b)")
                if !ok { #expect(s.reason == "\(name): login com cobrança por uso ou não reconhecido; consentimento necessário") }
            }
        }
    }
}
