import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// `<tmp>/collie-usage-<uuid>/d`: the seeding marker lands in the per-test parent, not the shared temp dir.
private func tmpDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("collie-usage-\(UUID().uuidString)/d")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
private func provider(_ id: String, _ script: String, parse: UsageProvider.Parse = .json, timeout: Double? = nil,
                      windows: [UsageProvider.Window] = [.init(label: "5h", usedPercent: "/p", resetsAt: nil)]) -> UsageProvider {
    UsageProvider(id: id, label: id.uppercased(), enabled: true, command: ["/bin/sh", "-c", script],
                  timeoutSeconds: timeout, parse: parse, windows: windows)
}
private func write(_ ps: [UsageProvider], to dir: URL) throws {
    for p in ps { try JSONEncoder().encode(p).write(to: dir.appendingPathComponent("\(p.id).json")) }
}

@Suite struct UsageServiceTests {
    @Test func providerParsesWindows() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try write([provider("fake", #"printf '{"p":42.5,"r":1700000000,"i":"2023-11-14T22:13:20Z"}'"#, windows: [
            .init(label: "5h", usedPercent: "/p", resetsAt: "/r"), .init(label: "7d", usedPercent: "/p", resetsAt: "/i"),
            .init(label: "gone", usedPercent: "/nope", resetsAt: nil)])], to: dir)
        let r = try #require(await UsageService(dir: dir).reports().first)
        #expect(r.error == nil)
        #expect(r.windows.map(\.label) == ["5h", "7d", "gone"])
        #expect(r.windows[0].usedPercent == 42.5)
        #expect(r.windows[0].resetsAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(r.windows[1].resetsAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(r.windows[2].usedPercent == nil)
    }

    @Test func jsonlLastPicksLastMatchingLine() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try write([provider("j", #"printf '{"p":1,"k":"rl"}\n{"p":2,"k":"rl"}\n{"p":3}\n'"#, parse: .jsonlLast(contains: #""rl""#))], to: dir)
        let r = try #require(await UsageService(dir: dir).reports().first)
        #expect(r.windows.first?.usedPercent == 2)
    }

    @Test func hungProviderTimesOutAlone() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try write([provider("bad", "sleep 60", timeout: 1), provider("good", #"printf '{"p":7}'"#)], to: dir)
        let t0 = ContinuousClock.now
        let rs = await UsageService(dir: dir).reports()
        #expect(ContinuousClock.now - t0 < .seconds(10))   // the 1 s timeout, not the 60 s sleep (or the 30 s default)
        let bad = try #require(rs.first { $0.providerId == "bad" }), good = try #require(rs.first { $0.providerId == "good" })
        #expect(bad.error?.contains("timeout") == true)
        #expect(good.error == nil && good.windows.first?.usedPercent == 7)
    }

    @Test func hugeOutputIsCapped() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try write([provider("big", "head -c 5242880 /dev/zero | tr '\\0' a")], to: dir)
        let r = try #require(await UsageService(dir: dir).reports().first)
        #expect(r.error == "output exceeds 1 MiB")
    }

    @Test func cacheHonorsMaxAge() async throws {
        let dir = tmpDir(), counter = dir.appendingPathComponent("count")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let pdir = dir.appendingPathComponent("p"); try FileManager.default.createDirectory(at: pdir, withIntermediateDirectories: true)
        try write([provider("c", "echo x >> '\(counter.path)'; printf '{\"p\":1}'")], to: pdir)
        let svc = UsageService(dir: pdir)
        _ = await svc.reports(); _ = await svc.reports()
        #expect(try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count == 1)
        _ = await svc.reports(maxAge: .zero)
        #expect(try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count == 2)
    }

    @Test func badProvidersReportErrorsWithoutBreakingOthers() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        var off = provider("off", "true"); off.enabled = false
        var missing = provider("missing", "true"); missing.command = ["definitely-not-a-command-collie"]
        try write([off, missing, provider("notjson", "echo hello"), provider("ok", #"printf '{"p":5}'"#)], to: dir)
        try Data("{oops".utf8).write(to: dir.appendingPathComponent("broken.json"))
        let rs = await UsageService(dir: dir).reports()
        func err(_ id: String) -> String? { rs.first { $0.providerId == id }?.error }
        #expect(err("off") == "disabled")
        #expect(err("missing")?.contains("command not found") == true)
        #expect(err("notjson")?.contains("unreadable JSON") == true)
        #expect(err("broken")?.contains("invalid provider") == true)
        #expect(err("ok") == nil)
    }

    @Test func seedsDefaultsOnce() throws {
        let dir = tmpDir().appendingPathComponent("usage/providers"); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()) }
        _ = UsageService(dir: dir)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files == ["claude.json", "codex.json"])
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("codex.json").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("claude.json"))
        _ = UsageService(dir: dir)   // not empty: no reseed
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["codex.json"])
        try FileManager.default.removeItem(at: dir.appendingPathComponent("codex.json"))
        _ = UsageService(dir: dir)   // emptied by the user: still no reseed (final-review M3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
    }

    /// `<tmp>/usage/providers` plus the usage dir that holds the rate-limits file.
    private func usageTree() -> (providers: URL, usage: URL, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("collie-usage-\(UUID().uuidString)")
        let providers = root.appendingPathComponent("usage/providers")
        try? FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        return (providers, root.appendingPathComponent("usage"), { try? FileManager.default.removeItem(at: root) })
    }

    @Test func claudeProviderReadsRateLimitsFile() async throws {
        let t = usageTree(); defer { t.cleanup() }
        let sample = #"{"five_hour":{"used_percentage":23.5,"resets_at":1700000000},"seven_day":{"used_percentage":41,"resets_at":1700600000},"recorded_at":1}"#
        try Data(sample.utf8).write(to: t.usage.appendingPathComponent("claude-rate-limits.json"))
        let svc = UsageService(dir: t.providers)   // seeds the real default claude template
        let r = try #require(await svc.reports().first { $0.providerId == "claude" })
        #expect(r.error == nil)
        #expect(r.windows.map(\.label) == ["5h", "7d"])
        #expect(r.windows[0].usedPercent == 23.5 && r.windows[1].usedPercent == 41)
        #expect(r.windows[0].resetsAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(r.windows[1].resetsAt == Date(timeIntervalSince1970: 1_700_600_000))
    }

    @Test func claudeProviderWithoutFileHasNoPercentsAndNoError() async throws {
        let t = usageTree(); defer { t.cleanup() }
        let r = try #require(await UsageService(dir: t.providers).reports().first { $0.providerId == "claude" })
        #expect(r.error == nil)
        #expect(r.windows.map(\.label) == ["5h", "7d"] && r.windows.allSatisfy { $0.usedPercent == nil && $0.resetsAt == nil })
    }

    @Test func upgradesOldClaudeSeed() throws {
        let t = usageTree(); defer { t.cleanup() }
        let f = t.providers.appendingPathComponent("claude.json")
        try Data(DefaultUsageProviders.claudeV1.utf8).write(to: f)
        _ = UsageService(dir: t.providers)
        #expect(try Data(contentsOf: f) == Data(DefaultUsageProviders.claude.utf8))
    }

    @Test func keepsEditedClaudeProvider() throws {
        let t = usageTree(); defer { t.cleanup() }
        let f = t.providers.appendingPathComponent("claude.json")
        let edited = Data((DefaultUsageProviders.claudeV1 + "\n").utf8)
        try edited.write(to: f)
        _ = UsageService(dir: t.providers)
        #expect(try Data(contentsOf: f) == edited)
    }

    @Test func uiUsageIsAdminOnlyAndReturnsReports() async throws {
        try await withDaemon { d, p in
            let bad = try await send(p, Request(id: "u", token: "nope", command: "ui.usage"))
            #expect(!bad.ok && bad.error?.code == .unauthorized)
            let ok = try await send(p, Request(id: "u", token: d.adminToken, command: "ui.usage"))
            guard ok.ok, case .array(let a)? = ok.result else { Issue.record("not an array: \(ok)"); return }
            #expect(a.count == 2)   // seeded claude + codex
        }
    }

    @Test func errorsAreNotCachedAndConcurrentCallsShareOneRun() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let pdir = dir.appendingPathComponent("p"), counter = dir.appendingPathComponent("count")
        try FileManager.default.createDirectory(at: pdir, withIntermediateDirectories: true)
        // first run fails (marker absent), later runs succeed
        let marker = dir.appendingPathComponent("m").path
        try write([provider("flaky", "echo x >> '\(counter.path)'; if [ -e '\(marker)' ]; then printf '{\"p\":1}'; else touch '\(marker)'; exit 3; fi")], to: pdir)
        let svc = UsageService(dir: pdir)
        #expect(await svc.reports().first?.error?.hasPrefix("exit 3") == true)
        #expect(await svc.reports().first?.error == nil)   // retried, not served from cache
        let svc2 = UsageService(dir: pdir)
        try? FileManager.default.removeItem(at: counter)
        async let a = svc2.reports(maxAge: .zero), b = svc2.reports(maxAge: .zero)
        _ = await (a, b)
        #expect(try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count == 1)
    }

    @Test func idMustMatchFileNameAndEmptyWindowsAreAnError() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        try JSONEncoder().encode(provider("real", #"printf '{"p":1}'"#)).write(to: dir.appendingPathComponent("alias.json"))
        try write([provider("blank", #"printf '{"q":1}'"#)], to: dir)
        let rs = await UsageService(dir: dir).reports()
        #expect(rs.first { $0.providerId == "alias" }?.error?.contains("does not match file name") == true)
        #expect(rs.first { $0.providerId == "blank" }?.error == "no usage fields found")
    }
}
