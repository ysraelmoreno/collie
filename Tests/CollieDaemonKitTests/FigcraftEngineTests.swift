import Testing
import Foundation
@testable import CollieDaemonKit

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// Fake engine dirs in a temp root: `bin/figcraft-server`, `bin/figcraft-cli` (executable), `web/index.html`.
private struct Dirs {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("collie-figeng-\(UUID().uuidString)")
    var env: URL { root.appendingPathComponent("env") }
    var bundle: URL { root.appendingPathComponent("bundle/figcraft") }
    var appSupport: URL { root.appendingPathComponent("figcraft") }
    var vendor: URL { root.appendingPathComponent("vendor/figcraft") }

    @discardableResult
    func engine(_ dir: URL, version: String? = nil, web: Bool = true, marker: String? = nil) -> URL {
        let fm = FileManager.default
        try! fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        for b in ["figcraft-server", "figcraft-cli"] {
            let f = dir.appendingPathComponent("bin/\(b)")
            try! Data("#!/bin/sh\n".utf8).write(to: f)
            try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
        if web {
            try! fm.createDirectory(at: dir.appendingPathComponent("web"), withIntermediateDirectories: true)
            try! Data("<html>".utf8).write(to: dir.appendingPathComponent("web/index.html"))
        }
        if let version { try! Data("{\"version\":\"\(version)\",\"commit\":\"x\"}".utf8).write(to: dir.appendingPathComponent("engine.json")) }
        if let marker { try! Data((marker + "\n").utf8).write(to: dir.appendingPathComponent(FigcraftEngine.marker)) }
        return dir
    }

    func resolve(env: URL? = nil, bundle: URL? = nil, vendor: URL? = nil, pin: FigcraftPin? = Dirs.pin()) -> FigcraftEngine? {
        FigcraftEngine.resolve(env: env, bundle: bundle, appSupport: appSupport, vendor: vendor, pin: pin)
    }

    static func pin(version: String = "0.8.0-c1", sha: String = String(repeating: "a", count: 64)) -> FigcraftPin {
        FigcraftPin(version: version, figcraft: "v0.8.0", commit: "c", inputs: "i", url: "https://example.invalid/x",
                    size: 1, unpackedSize: 2, sha256: sha, teamId: "T")
    }
}

private let goodSha = String(repeating: "a", count: 64)

@Suite struct FigcraftEngineTests {
    @Test func envWinsWithoutVersionCheck() {
        let d = Dirs()
        d.engine(d.env); d.engine(d.bundle, version: "0.8.0-c1")
        let e = d.resolve(env: d.env, bundle: d.bundle)
        #expect(e?.source == .env)
        #expect(e?.dir == d.env)
        #expect(e?.version == nil)
    }

    @Test func envIsTakenAsIs() {
        let d = Dirs()   // nothing on disk: the start then reports the missing binary
        #expect(d.resolve(env: d.env)?.dir == d.env)
    }

    @Test func bundleBeforeAppSupport() {
        let d = Dirs()
        d.engine(d.bundle, version: "0.7.0-c1")
        d.engine(d.appSupport, version: "0.8.0-c1", marker: goodSha)
        #expect(d.resolve(bundle: d.bundle)?.source == .bundle)
    }

    @Test func appSupportWhenNoBundle() {
        let d = Dirs()
        d.engine(d.appSupport, version: "0.8.0-c1", marker: goodSha)
        let e = d.resolve(bundle: d.bundle)   // bundle dir does not exist
        #expect(e?.source == .appSupport)
        #expect(e?.version == "0.8.0-c1")
        #expect(e?.web == d.appSupport.appendingPathComponent("web"))
    }

    @Test func invalidAppSupportIsSkipped() {
        let d = Dirs()
        d.engine(d.appSupport, version: "0.8.0-c1", web: false, marker: goodSha)
        #expect(d.resolve() == nil)
        #expect(!FigcraftEngine.isValid(d.appSupport))
    }

    @Test func appSupportWithoutMarkerDoesNotRun() {
        let d = Dirs()
        d.engine(d.appSupport, version: "0.8.0-c1")
        #expect(d.resolve() == nil)
    }

    @Test func appSupportWithOtherShaDoesNotRun() {
        let d = Dirs()
        d.engine(d.appSupport, version: "0.8.0-c1", marker: String(repeating: "b", count: 64))
        #expect(d.resolve() == nil)
    }

    @Test func appSupportWithoutPinDoesNotRun() {
        let d = Dirs()
        d.engine(d.appSupport, version: "0.8.0-c1", marker: goodSha)
        #expect(d.resolve(pin: nil) == nil)
    }

    @Test func vendorIsLast() {
        let d = Dirs()
        d.engine(d.vendor)
        #expect(d.resolve(vendor: d.vendor)?.source == .vendor)
    }

    @Test func noneIsNil() {
        #expect(Dirs().resolve(env: nil, bundle: nil, vendor: nil) == nil)
    }

    @Test func versionReadFromEngineJson() {
        let d = Dirs()
        d.engine(d.bundle)
        #expect(d.resolve(bundle: d.bundle)?.version == nil)
        d.engine(d.appSupport, version: "0.7.0-c1", marker: goodSha)
        #expect(FigcraftEngine.version(d.appSupport) == "0.7.0-c1")
    }

    @Test func stateNeedsUpdateWhenOlder() {
        let d = Dirs()
        d.engine(d.appSupport, version: "0.7.0-c1", marker: String(repeating: "b", count: 64))
        let s = FigcraftEngine.state(running: d.resolve(), appSupport: d.appSupport, pin: Dirs.pin())
        #expect(s == .needsUpdate(installed: "0.7.0-c1", pinned: "0.8.0-c1", reinstall: false))
    }

    @Test func stateReinstallWhenNewerOrSameVersion() {
        let other = String(repeating: "b", count: 64)
        for v in ["0.9.0-c1", "0.8.0-c1"] {
            let d = Dirs()
            d.engine(d.appSupport, version: v, marker: other)
            let s = FigcraftEngine.state(running: d.resolve(), appSupport: d.appSupport, pin: Dirs.pin())
            #expect(s == .needsUpdate(installed: v, pinned: "0.8.0-c1", reinstall: true), "\(v)")
        }
    }

    @Test func stateReinstallWhenMarkerMissing() {
        let d = Dirs()
        d.engine(d.appSupport, version: "0.7.0-c1")
        let s = FigcraftEngine.state(running: d.resolve(), appSupport: d.appSupport, pin: Dirs.pin())
        #expect(s == .needsUpdate(installed: "0.7.0-c1", pinned: "0.8.0-c1", reinstall: true))
    }

    @Test func stateInstalledWhenMarkerMatches() {
        let d = Dirs()
        d.engine(d.appSupport, version: "0.8.0-c1", marker: goodSha)
        let e = d.resolve()
        #expect(e != nil)
        #expect(FigcraftEngine.state(running: e, appSupport: d.appSupport, pin: Dirs.pin()) == .installed(e!))
    }

    @Test func stateAbsentWithNothing() {
        let d = Dirs()
        #expect(FigcraftEngine.state(running: nil, appSupport: d.appSupport, pin: Dirs.pin()) == .absent)
    }

    @Test func stateInstalledFromBundleIgnoresStaleAppSupport() {
        let d = Dirs()
        d.engine(d.bundle, version: "0.7.0-c1")
        d.engine(d.appSupport, version: "0.6.0-c1", marker: String(repeating: "b", count: 64))
        let e = d.resolve(bundle: d.bundle)
        #expect(FigcraftEngine.state(running: e, appSupport: d.appSupport, pin: Dirs.pin()) == .installed(e!))
    }

    @Test func compareVersionsOrdersCN() {
        #expect(FigcraftEngine.compareVersions("0.7.0-c2", "0.7.0-c1") == .orderedDescending)
        #expect(FigcraftEngine.compareVersions("0.10.0-c1", "0.9.0-c9") == .orderedDescending)
        #expect(FigcraftEngine.compareVersions("0.7.0-c1", "0.8.0-c1") == .orderedAscending)
        #expect(FigcraftEngine.compareVersions("0.8.0-c1", "0.8.0-c1") == .orderedSame)
    }

    @Test func installedShaTrimsWhitespace() {
        let d = Dirs()
        d.engine(d.appSupport, marker: goodSha)
        #expect(FigcraftEngine.installedSha(d.appSupport) == goodSha)
    }

    @Test func pinLoadsShippedFile() throws {
        let pin = try #require(FigcraftPin.load(repoRoot.appendingPathComponent("Resources/figcraft-engine.json")))
        #expect(pin.version == "0.7.0-c1")
        #expect(pin.figcraft == "v0.7.0")
        #expect(pin.url.hasPrefix("https://github.com/ysraelmoreno/collie/releases/download/figcraft-v"))
        #expect(!pin.teamId.isEmpty)
        #expect(pin.sha256.count == 64)
    }

    @Test func pinLoadIsNilForMissingOrBadFile() {
        let d = Dirs()
        #expect(FigcraftPin.load(d.root.appendingPathComponent("nope.json")) == nil)
        try! FileManager.default.createDirectory(at: d.root, withIntermediateDirectories: true)
        let bad = d.root.appendingPathComponent("bad.json")
        try! Data("{".utf8).write(to: bad)
        #expect(FigcraftPin.load(bad) == nil)
    }

    @Test func cleanStagingRemovesIt() {
        let d = Dirs()
        let staging = d.root.appendingPathComponent(".figcraft-staging/figcraft")
        try! FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        d.engine(d.appSupport, marker: goodSha)
        FigcraftEngine.cleanStaging(root: d.root)
        #expect(!FileManager.default.fileExists(atPath: d.root.appendingPathComponent(".figcraft-staging").path))
        #expect(FileManager.default.fileExists(atPath: d.appSupport.path))
    }
}
