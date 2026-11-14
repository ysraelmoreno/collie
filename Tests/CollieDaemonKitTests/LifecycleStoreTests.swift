import Testing
import Foundation
@testable import CollieDaemonKit

private func tmpFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lc-\(UUID().uuidString)/lifecycle.json")
}
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 86_400

@Suite struct LifecycleStoreTests {
    @Test func roundTripsFileWith0600() async throws {
        let f = tmpFile(), id = UUID()
        let s = LifecycleStore(file: f)
        await s.update(id, now: t0) { $0.usefulUses.insert(UseKey(day: "2026-11-13", session: "s")); $0.tier = .earned }
        let e = await LifecycleStore(file: f).entry(id)
        #expect(e?.tier == .earned)
        #expect(e?.usefulUses.count == 1)
        let perms = try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func unreadableFileStartsEmptyNeverCrashes() async throws {
        let f = tmpFile()
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: f)
        let s = LifecycleStore(file: f)
        #expect(await s.all().isEmpty)
        #expect(await s.injected(session: "x").isEmpty)
    }

    @Test func updateCreatesProvisionalWithTierSinceNow() async {
        let id = UUID(), s = LifecycleStore(file: tmpFile())
        #expect(await s.entry(id) == nil)
        await s.update(id, now: t0) { _ in }
        let e = await s.entry(id)
        #expect(e?.tier == .provisional)
        #expect(e?.tierSince == t0)
    }

    @Test func injectedSurvivesReopeningTheFile() async {
        let f = tmpFile(), ids = [UUID(), UUID()]
        await LifecycleStore(file: f).noteInjected(session: "s", ids: ids, now: t0)
        #expect(await LifecycleStore(file: f).injected(session: "s") == Set(ids))
    }

    @Test func injectedDroppedSevenDaysAfterLastEvent() async {
        let s = LifecycleStore(file: tmpFile()), id = UUID()
        await s.noteInjected(session: "a", ids: [id], now: t0)
        await s.noteInjected(session: "b", ids: [id], now: t0 + 6 * day)   // a: 6d idle, kept
        #expect(await s.injected(session: "a") == [id])
        await s.noteInjected(session: "b", ids: [id], now: t0 + 8 * day)   // a: 8d idle, dropped
        #expect(await s.injected(session: "a").isEmpty)
        #expect(await s.injected(session: "b") == [id])
    }

    @Test func takePendingClearsIt() async {
        let s = LifecycleStore(file: tmpFile()), ids = [UUID()]
        await s.setPending(session: "s", ids: ids)
        #expect(await s.takePending(session: "s") == ids)
        #expect(await s.takePending(session: "s").isEmpty)
    }

    @Test func pendingExpiresWithItsSession() async {
        let s = LifecycleStore(file: tmpFile()), id = UUID()
        await s.noteInjected(session: "a", ids: [id], now: t0)
        await s.setPending(session: "a", ids: [id])
        await s.noteInjected(session: "b", ids: [id], now: t0 + 8 * day)   // a: 8d idle, its pending goes too
        #expect(await s.takePending(session: "a").isEmpty)
    }

    @Test func addUseOneWriteSkipsFlaggedBySameSession() async {
        let f = tmpFile(), s = LifecycleStore(file: f), ok = UUID(), flagged = UUID(), key = UseKey(day: "2026-11-13", session: "s")
        await s.update(flagged, now: t0) { $0.flags = [LifecycleFlag(verdict: .outdated, session: "s", day: "2026-11-13", reason: "")] }
        await s.addUse([ok, flagged], key: key, now: t0)
        let all = await LifecycleStore(file: f).all()
        #expect(all[ok]?.usefulUses == [key] && all[ok]?.tierSince == t0)
        #expect(all[flagged]?.usefulUses.isEmpty == true)
    }

    @Test func pruneDropsIdsMissingFor30DaysKeepsRecent() async {
        let s = LifecycleStore(file: tmpFile()), gone = UUID(), back = UUID(), kept = UUID()
        for id in [gone, back, kept] { await s.update(id, now: t0) { _ in } }
        await s.prune(knownIds: [kept], now: t0)                 // gone, back start missing
        await s.prune(knownIds: [kept, back], now: t0 + 20 * day) // back returns: cleared
        await s.prune(knownIds: [kept], now: t0 + 31 * day)      // back missing again since day 31; gone 31d
        let all = await s.all()
        #expect(all[gone] == nil)
        #expect(all[back] != nil)
        #expect(all[kept] != nil)
    }

    @Test func undecodableFileKeptAsCorrupt() async throws {
        let f = tmpFile(), aside = f.appendingPathExtension("corrupt")
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: aside)   // an older .corrupt is overwritten
        try Data("{not json".utf8).write(to: f)
        #expect(await LifecycleStore(file: f).all().isEmpty)
        #expect(try Data(contentsOf: aside) == Data("{not json".utf8))
        #expect(!FileManager.default.fileExists(atPath: f.path))
    }

    @Test func userKeptClearsContestAndRestartsClock() async {
        let id = UUID(), s = LifecycleStore(file: tmpFile())
        await s.userKept(id, now: t0)
        #expect(await s.entry(id) == nil)   // no entry: nothing made up
        await s.update(id, now: t0) { e in
            e.tier = .earned; e.contestedNow = true; e.flags = [LifecycleFlag(verdict: .wrong, session: "a", day: "2026-11-01", reason: "")]
        }
        await s.userKept(id, now: t0 + day)
        let e = await s.entry(id)
        #expect(e?.tier == .earned && e?.flags.isEmpty == true && e?.contestedNow == false)
        #expect(e?.tierSince == t0 + day && e?.recheckedAt == t0 + day)
    }
}
