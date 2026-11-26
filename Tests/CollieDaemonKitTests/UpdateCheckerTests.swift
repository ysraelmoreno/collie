import Testing
import Foundation
import CryptoKit
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Serves bytes by URL (no network); a missing URL answers 404 like the daemon's fetch, `hold` waits until released.
final class FakeUpdateFetch: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:], errors: [String: any Error] = [:]
    private(set) var calls: [(url: String, limit: Int64?)] = []
    var hold: AsyncStream<Void>?

    func serve(_ url: URL, _ d: Data) { lock.withLock { files[url.absoluteString] = d; errors[url.absoluteString] = nil } }
    func fail(_ url: URL, _ e: any Error) { lock.withLock { errors[url.absoluteString] = e } }
    func count(_ url: URL) -> Int { lock.withLock { calls.filter { $0.url == url.absoluteString }.count } }
    func limit(_ url: URL) -> Int64?? { lock.withLock { calls.last { $0.url == url.absoluteString }.map(\.limit) } }

    var fetch: UpdateFetch {
        { url, to, limit, progress in
            let (d, e, h) = self.lock.withLock { () -> (Data?, (any Error)?, AsyncStream<Void>?) in
                self.calls.append((url.absoluteString, limit))
                return (self.files[url.absoluteString], self.errors[url.absoluteString], self.hold)
            }
            if let h { for await _ in h { break } }
            try Task.checkCancellation()
            if let e { throw e }
            guard let d else { throw ProtocolError(code: .unavailable, message: "download answered 404 from github.com") }
            if let limit, Int64(d.count) > limit { throw ProtocolError(code: .unavailable, message: AndroidDownload.tooLarge) }
            progress(Int64(d.count), Int64(d.count))
            try d.write(to: to)
        }
    }
}

@Suite(.daemonPt) struct UpdateCheckerTests {
    static let manifestURL = URL(string: "https://github.com/ysraelmoreno/collie/releases/latest/download/update.json")!
    static let dmg = Data(repeating: 7, count: 2048)
    static func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static func manifest(_ version: String = "0.2.0", sha: String? = nil, size: Int? = nil) -> Data {
        let o: [String: Any] = [
            "format": 1, "version": version, "tag": "v\(version)", "dmg": "Collie-\(version).dmg", "size": size ?? dmg.count,
            "sha256": sha ?? hex(dmg), "minimumSystemVersion": "15.0", "teamId": "AG8JQAH6YB", "figcraftEngine": "0.7.0-c1",
            "page": "https://github.com/ysraelmoreno/collie/releases/tag/v\(version)",
        ]
        return try! JSONSerialization.data(withJSONObject: o)
    }
    static func dmgURL(_ version: String = "0.2.0") -> URL {
        URL(string: "https://github.com/ysraelmoreno/collie/releases/download/v\(version)/Collie-\(version).dmg")!
    }

    struct Env {
        let root: URL, fetch = FakeUpdateFetch(), maintenance = Maintenance()
        init() { root = FileManager.default.temporaryDirectory.appendingPathComponent("upd-\(UUID().uuidString)") }
        func checker(installed: String = "0.1.1", dmgCheck: @escaping @Sendable (URL) -> Bool = { _ in true },
                     free: Int64? = nil, manifestURL: URL = UpdateCheckerTests.manifestURL) -> UpdateChecker {
            UpdateChecker(root: root, installedVersion: installed, manifestURL: manifestURL, fetch: fetch.fetch,
                          dmgCheck: dmgCheck, freeSpace: { _ in free }, maintenance: maintenance)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func noneWhenNotNewer() async {
        let e = Env(); defer { e.cleanup() }
        e.fetch.serve(Self.manifestURL, Self.manifest())
        let s = await e.checker(installed: "0.2.0").check()
        #expect(s.state == "none" && s.available == nil && s.error == nil && s.lastCheck != nil)
    }

    @Test func availableWhenNewer() async {
        let e = Env(); defer { e.cleanup() }
        e.fetch.serve(Self.manifestURL, Self.manifest())
        let s = await e.checker().check()
        #expect(s.state == "available")
        #expect(s.available?.version == "0.2.0")
    }

    @Test func manifest404IsNone() async {
        let e = Env(); defer { e.cleanup() }
        let s = await e.checker().check()
        #expect(s.state == "none" && s.error == nil)
    }

    @Test func installedFromAppWins() async {
        // "only the app": the old daemon was started by 0.1.1 but the app runs 0.2.0
        let e = Env(); defer { e.cleanup() }
        e.fetch.serve(Self.manifestURL, Self.manifest())
        let s = await e.checker(installed: "0.1.1").check(installed: "0.2.0")
        #expect(s.state == "none")
    }

    @Test func downloadsAndVerifies() async throws {
        let e = Env(); defer { e.cleanup() }
        e.fetch.serve(Self.manifestURL, Self.manifest()); e.fetch.serve(Self.dmgURL(), Self.dmg)
        let c = e.checker()
        _ = await c.check()
        let started = try await c.download()
        #expect(started.job?.phase == "downloading")
        let s = await c.finished()
        #expect(s.state == "ready" && s.job?.phase == "ready")
        let staged = try #require(await c.stagedDMG)
        #expect(try Data(contentsOf: staged) == Self.dmg)
        #expect(staged.lastPathComponent == "Collie-0.2.0.dmg")
        let mode = try FileManager.default.attributesOfItem(atPath: staged.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(await e.maintenance.active == nil)
        #expect(await c.check().state == "ready")   // a new check keeps the staged dmg
    }

    @Test func shaMismatchRefusesOnlyThatSha() async throws {
        let e = Env(); defer { e.cleanup() }
        let wrong = String(repeating: "0", count: 64)
        e.fetch.serve(Self.manifestURL, Self.manifest(sha: wrong)); e.fetch.serve(Self.dmgURL(), Self.dmg)
        let c = e.checker()
        _ = await c.check()
        _ = try await c.download()
        let s = await c.finished()
        #expect(s.state == "failed" && s.error == UpdateChecker.changed)
        #expect(await c.stagedDMG == nil)
        let refused = try JSONDecoder().decode([String].self, from: Data(contentsOf: e.root.appendingPathComponent(".update-staging/refused.json")))
        #expect(refused == [wrong])
        // the same manifest again: never downloaded again
        _ = await c.check()
        do { _ = try await c.download(); Issue.record("expected a refusal") } catch { #expect(error.code == .unavailable) }
        #expect(e.fetch.count(Self.dmgURL()) == 1)
        // a manifest with a new sha downloads
        e.fetch.serve(Self.manifestURL, Self.manifest())
        _ = await c.check()
        _ = try await c.download()
        #expect(await c.finished().state == "ready")
    }

    @Test func notFoundIsNotRefused() async throws {
        let e = Env(); defer { e.cleanup() }
        e.fetch.serve(Self.manifestURL, Self.manifest())
        let c = e.checker()
        _ = await c.check()
        _ = try await c.download()
        #expect(await c.finished().state == "failed")
        #expect(!FileManager.default.fileExists(atPath: e.root.appendingPathComponent(".update-staging/refused.json").path))
        e.fetch.serve(Self.dmgURL(), Self.dmg)
        _ = await c.check()
        _ = try await c.download()
        #expect(await c.finished().state == "ready")
    }

    @Test func networkErrorAndCancelAreNotRefused() async throws {
        let e = Env(); defer { e.cleanup() }
        e.fetch.serve(Self.manifestURL, Self.manifest())
        e.fetch.fail(Self.dmgURL(), URLError(.notConnectedToInternet))
        let c = e.checker()
        _ = await c.check()
        _ = try await c.download()
        #expect(await c.finished().state == "failed")
        // cancel mid-download
        e.fetch.serve(Self.dmgURL(), Self.dmg)
        let (stream, cont) = AsyncStream<Void>.makeStream()
        e.fetch.hold = stream
        _ = try await c.download()
        await c.cancel()
        cont.finish()
        let s = await c.finished()
        #expect(s.job?.phase == "cancelled" && s.state == "available")
        #expect(!FileManager.default.fileExists(atPath: e.root.appendingPathComponent(".update-staging/refused.json").path))
        #expect(await e.maintenance.active == nil)
    }

    @Test func dmgCheckFailureRefuses() async throws {
        let e = Env(); defer { e.cleanup() }
        e.fetch.serve(Self.manifestURL, Self.manifest()); e.fetch.serve(Self.dmgURL(), Self.dmg)
        let c = e.checker(dmgCheck: { _ in false })
        _ = await c.check()
        _ = try await c.download()
        let s = await c.finished()
        #expect(s.state == "failed" && s.error == UpdateChecker.badSignature)
        #expect(await c.stagedDMG == nil)
        #expect(!FileManager.default.fileExists(atPath: e.root.appendingPathComponent(".update-staging/Collie-0.2.0.dmg").path))
        let refused = try JSONDecoder().decode([String].self, from: Data(contentsOf: e.root.appendingPathComponent(".update-staging/refused.json")))
        #expect(refused == [Self.hex(Self.dmg)])
    }

    @Test func limitPassedToFetch() async throws {
        let e = Env(); defer { e.cleanup() }
        e.fetch.serve(Self.manifestURL, Self.manifest()); e.fetch.serve(Self.dmgURL(), Self.dmg)
        let c = e.checker()
        _ = await c.check()
        _ = try await c.download()
        _ = await c.finished()
        #expect(e.fetch.limit(Self.manifestURL) == .some(65_536))
        #expect(e.fetch.limit(Self.dmgURL()) == .some(Int64(Self.dmg.count)))
    }

    @Test func lowSpaceRefuses() async {
        let e = Env(); defer { e.cleanup() }
        e.fetch.serve(Self.manifestURL, Self.manifest()); e.fetch.serve(Self.dmgURL(), Self.dmg)
        let c = e.checker(free: Int64(Self.dmg.count) * 3 + 100_000_000 - 1)
        _ = await c.check()
        do { _ = try await c.download(); Issue.record("expected a refusal") }
        catch { #expect(error.message == "Espaço insuficiente") }
        #expect(e.fetch.count(Self.dmgURL()) == 0)
    }

    @Test func maintenanceConflict() async throws {
        let e = Env(); defer { e.cleanup() }
        e.fetch.serve(Self.manifestURL, Self.manifest()); e.fetch.serve(Self.dmgURL(), Self.dmg)
        let c = e.checker()
        _ = await c.check()
        try await e.maintenance.enter("backup")
        do { _ = try await c.download(); Issue.record("expected a conflict") } catch { #expect(error.code == .conflict) }
        await e.maintenance.leave("backup")
        let (stream, cont) = AsyncStream<Void>.makeStream()
        e.fetch.hold = stream
        _ = try await c.download()
        do { try await e.maintenance.enter("import"); Issue.record("expected a conflict") } catch { #expect(error.code == .conflict) }
        cont.finish()
        _ = await c.finished()
    }

    @Test func skipHidesVersion() async {
        let e = Env(); defer { e.cleanup() }
        e.fetch.serve(Self.manifestURL, Self.manifest())
        let c = e.checker()
        #expect(await c.check().state == "available")
        #expect(await c.skip("0.2.0").state == "none")
        #expect(await c.check().state == "none")
        #expect(await e.checker().check().state == "none")   // kept on disk
        e.fetch.serve(Self.manifestURL, Self.manifest("0.2.1"))
        #expect(await c.check().state == "available")
    }

    @Test func overrideReported() async throws {
        let e = Env(); defer { e.cleanup() }
        // a test source: file:// manifest, the dmg next to it (spec §8)
        let dir = e.root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.manifest().write(to: dir.appendingPathComponent("update.json"))
        try Self.dmg.write(to: dir.appendingPathComponent("Collie-0.2.0.dmg"))
        let url = dir.appendingPathComponent("update.json")
        let c = e.checker(manifestURL: url)
        let s = await c.check()
        #expect(s.override == url.absoluteString && s.state == "available")
        _ = try await c.download()
        #expect(await c.finished().state == "ready")
        #expect(e.fetch.calls.isEmpty)   // read from disk, never the network fetch
    }
}
