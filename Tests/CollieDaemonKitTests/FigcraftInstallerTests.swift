import Testing
import Foundation
import Darwin
import CryptoKit
import CollieProtocol
@testable import CollieDaemonKit

/// A temp root plus a `.tar.gz` asset built here with /usr/bin/tar: `figcraft/{bin/*, web/index.html, engine.json}`.
private struct Fx {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collie-figinst-\(UUID().uuidString.prefix(8))")
    var root: URL { dir.appendingPathComponent("root") }
    var engine: URL { root.appendingPathComponent("figcraft") }
    var staging: URL { root.appendingPathComponent(".figcraft-staging") }

    init() { try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    /// The asset and its pin. `edit` changes the tree before it is packed.
    func asset(version: String = "0.8.0-c1", _ edit: (URL) throws -> Void = { _ in }) throws -> (file: URL, pin: FigcraftPin) {
        let src = dir.appendingPathComponent("src-\(UUID().uuidString.prefix(6))"), f = src.appendingPathComponent("figcraft")
        let fm = FileManager.default
        try fm.createDirectory(at: f.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: f.appendingPathComponent("web"), withIntermediateDirectories: true)
        for b in ["figcraft-server", "figcraft-cli"] {
            try Data("#!/bin/sh\necho \(version)\n".utf8).write(to: f.appendingPathComponent("bin/\(b)"))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.appendingPathComponent("bin/\(b)").path)
        }
        try Data("<html>".utf8).write(to: f.appendingPathComponent("web/index.html"))
        try Data("{\"version\":\"\(version)\",\"commit\":\"c\"}".utf8).write(to: f.appendingPathComponent("engine.json"))
        try edit(f)
        let out = dir.appendingPathComponent("asset-\(UUID().uuidString.prefix(6)).tar.gz")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-czf", out.path, "-C", src.path, "figcraft"]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let data = try Data(contentsOf: out)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let pin = FigcraftPin(version: version, figcraft: "v0.8.0", commit: "c", inputs: "i",
                              url: "https://github.com/ysraelmoreno/collie/releases/download/figcraft-v\(version)/figcraft-\(version)-arm64.tar.gz",
                              size: Int64(data.count), unpackedSize: 1000, sha256: sha, teamId: "TEAM123456")
        return (out, pin)
    }

    /// An installed engine (what an older install left).
    func installed(version: String, marker: String = String(repeating: "b", count: 64)) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: engine.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: engine.appendingPathComponent("web"), withIntermediateDirectories: true)
        for b in ["figcraft-server", "figcraft-cli"] {
            try Data("#!/bin/sh\n".utf8).write(to: engine.appendingPathComponent("bin/\(b)"))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.appendingPathComponent("bin/\(b)").path)
        }
        try Data("<html>".utf8).write(to: engine.appendingPathComponent("web/index.html"))
        try Data("{\"version\":\"\(version)\"}".utf8).write(to: engine.appendingPathComponent("engine.json"))
        try Data(marker.utf8).write(to: engine.appendingPathComponent(FigcraftEngine.marker))
    }
}

/// Records what the installer asked for.
private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var _fetches = 0, _swaps = 0, _signed: [String] = [], _team: Set<String> = []
    var fetches: Int { lock.withLock { _fetches } }
    var swaps: Int { lock.withLock { _swaps } }
    var signed: [String] { lock.withLock { _signed } }
    var teams: Set<String> { lock.withLock { _team } }
    func fetched() { lock.withLock { _fetches += 1 } }
    func swapped() { lock.withLock { _swaps += 1 } }
    func sign(_ id: String, _ team: String) { lock.withLock { _signed.append(id); _team.insert(team) } }
}

private func installer(_ fx: Fx, _ asset: URL?, pin: FigcraftPin?, calls: Calls = Calls(),
                       signature: @escaping @Sendable (String) -> Bool = { _ in true },
                       freeSpace: Int64? = nil, busy: Bool = false,
                       fetchGate: (@Sendable () async throws -> Void)? = nil) -> FigcraftInstaller {
    FigcraftInstaller(root: fx.root, pin: pin,
        fetch: { url, to, progress in
            calls.fetched()
            #expect(AndroidDownload.allowed(url))
            try await fetchGate?()
            guard let asset else { throw ProtocolError(code: .unavailable, message: "no network") }
            try FileManager.default.copyItem(at: asset, to: to)
            progress(1, 1)
        },
        signature: { _, id, team in calls.sign(id, team); return signature(id) },
        freeSpace: { _ in freeSpace },
        busy: { busy },
        swap: { op in calls.swapped(); try op() })
}

@Suite struct FigcraftInstallerTests {
    @Test func installsWithSwap() async throws {
        let fx = Fx(), (asset, pin) = try fx.asset(), calls = Calls()
        let i = installer(fx, asset, pin: pin, calls: calls)
        _ = try await i.install()
        let job = await i.finished()
        #expect(job?.phase == "done", "\(String(describing: job))")
        #expect(FileManager.default.isExecutableFile(atPath: fx.engine.appendingPathComponent("bin/figcraft-server").path))
        #expect(calls.swaps == 1)
        #expect(!FileManager.default.fileExists(atPath: fx.staging.path))
        #expect(FigcraftEngine.installedSha(fx.engine) == pin.sha256)
        #expect((try fx.engine.resourceValues(forKeys: [.isExcludedFromBackupKey])).isExcludedFromBackup == true)
        #expect(Set(calls.signed) == ["figcraft-server", "figcraft-cli"] && calls.teams == ["TEAM123456"])
        #expect(FigcraftEngine.resolve(env: nil, bundle: nil, appSupport: fx.engine, vendor: nil, pin: pin)?.source == .appSupport)
    }

    @Test func updateReplacesStaleEngine() async throws {
        let fx = Fx(), (asset, pin) = try fx.asset(version: "0.8.0-c1")
        try fx.installed(version: "0.7.0-c1")
        #expect(FigcraftEngine.resolve(env: nil, bundle: nil, appSupport: fx.engine, vendor: nil, pin: pin) == nil)
        let i = installer(fx, asset, pin: pin)
        _ = try await i.install()
        #expect(await i.finished()?.phase == "done")
        #expect(FigcraftEngine.version(fx.engine) == "0.8.0-c1")
        #expect(FigcraftEngine.installedSha(fx.engine) == pin.sha256)
        #expect(!FileManager.default.fileExists(atPath: fx.staging.path))   // the old one went with the staging
    }

    @Test func swapReplacesExistingAtomically() throws {
        let fx = Fx()
        try fx.installed(version: "0.7.0-c1")
        let staged = fx.staging.appendingPathComponent("figcraft")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("{\"version\":\"0.8.0-c1\"}".utf8).write(to: staged.appendingPathComponent("engine.json"))
        try FigcraftInstaller.swapInto(root: fx.root, staged: staged)
        #expect(FigcraftEngine.version(fx.engine) == "0.8.0-c1")
        #expect(FigcraftEngine.version(staged) == "0.7.0-c1")   // the old one, on the throwaway side
        // nothing there yet: a plain rename
        let fy = Fx(), s2 = fy.staging.appendingPathComponent("figcraft")
        try FileManager.default.createDirectory(at: s2, withIntermediateDirectories: true)
        try FigcraftInstaller.swapInto(root: fy.root, staged: s2)
        #expect(FileManager.default.fileExists(atPath: fy.engine.path) && !FileManager.default.fileExists(atPath: s2.path))
    }

    @Test func badShaExtractsNothing() async throws {
        let fx = Fx(), (asset, good) = try fx.asset(), calls = Calls()
        try fx.installed(version: "0.7.0-c1")
        var pin = good; pin.sha256 = String(repeating: "0", count: 64)
        let i = installer(fx, asset, pin: pin, calls: calls)
        _ = try await i.install()
        let job = await i.finished()
        #expect(job?.phase == "failed")
        #expect(job?.error == "O arquivo baixado não confere (sha256). Nada foi instalado.")
        #expect(FigcraftEngine.version(fx.engine) == "0.7.0-c1")
        #expect(!FileManager.default.fileExists(atPath: fx.staging.path))
        #expect(calls.fetches == 1 && calls.swaps == 0 && calls.signed.isEmpty)
    }

    @Test func rejectsSymlinkInArchive() async throws {
        let fx = Fx(), (asset, pin) = try fx.asset { f in
            try FileManager.default.createSymbolicLink(atPath: f.appendingPathComponent("web/link").path, withDestinationPath: "/etc/hosts")
        }
        let calls = Calls(), i = installer(fx, asset, pin: pin, calls: calls)
        _ = try await i.install()
        #expect(await i.finished()?.phase == "failed")
        #expect(calls.swaps == 0 && !FileManager.default.fileExists(atPath: fx.engine.path))
    }

    @Test func scanRejectsSetuidAndForcesGoW() throws {
        let fx = Fx(), d = fx.dir.appendingPathComponent("scan")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let f = d.appendingPathComponent("x")
        try Data("x".utf8).write(to: f)
        // a setuid file can't be made here (the terminal sandbox refuses the chmod): the rule is checked on the modes
        #expect(FigcraftInstaller.refusal(mode: S_IFREG | 0o4755) == "com setuid/setgid")
        #expect(FigcraftInstaller.refusal(mode: S_IFREG | 0o2755) == "com setuid/setgid")
        #expect(FigcraftInstaller.refusal(mode: S_IFLNK | 0o755) == "não é arquivo nem pasta")
        #expect(FigcraftInstaller.refusal(mode: S_IFIFO | 0o644) == "não é arquivo nem pasta")
        #expect(FigcraftInstaller.refusal(mode: S_IFREG | 0o755) == nil && FigcraftInstaller.refusal(mode: S_IFDIR | 0o755) == nil)
        chmod(f.path, 0o777)
        try FigcraftInstaller.scan(d)
        let mode = (try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(mode & 0o022 == 0)
    }

    @Test func wrongSignatureFails() async throws {
        let fx = Fx(), (asset, pin) = try fx.asset(), calls = Calls()
        let i = installer(fx, asset, pin: pin, calls: calls, signature: { $0 != "figcraft-cli" })
        _ = try await i.install()
        #expect(await i.finished()?.phase == "failed")
        #expect(calls.swaps == 0 && !FileManager.default.fileExists(atPath: fx.engine.path))
        #expect(calls.signed.contains("figcraft-server") && calls.signed.contains("figcraft-cli") && calls.teams == ["TEAM123456"])
    }

    @Test func layoutMismatchFails() async throws {
        let fx = Fx(), (asset, good) = try fx.asset(version: "0.8.0-c1")
        var pin = good; pin.version = "0.9.0-c1"
        let i = installer(fx, asset, pin: pin)
        _ = try await i.install()
        #expect(await i.finished()?.phase == "failed")
        #expect(!FileManager.default.fileExists(atPath: fx.engine.path))
    }

    @Test func cancelMidDownload() async throws {
        let fx = Fx(), (asset, pin) = try fx.asset()
        let i = installer(fx, asset, pin: pin, fetchGate: { try await Task.sleep(for: .seconds(30)) })
        _ = try await i.install()
        try await Task.sleep(for: .milliseconds(100))
        await i.cancel()
        #expect(await i.finished()?.phase == "cancelled")
        #expect(!FileManager.default.fileExists(atPath: fx.staging.path) && !FileManager.default.fileExists(atPath: fx.engine.path))
    }

    @Test func lowSpaceRefuses() async throws {
        let fx = Fx(), (asset, pin) = try fx.asset(), calls = Calls()
        let i = installer(fx, asset, pin: pin, calls: calls, freeSpace: pin.size + pin.unpackedSize + 100_000_000 - 1)
        _ = try await i.install()
        let job = await i.finished()
        #expect(job?.phase == "failed" && job?.error == "Espaço insuficiente")
        #expect(calls.fetches == 0)
    }

    @Test func concurrentInstallReturnsSameJob() async throws {
        let fx = Fx(), (asset, pin) = try fx.asset(), calls = Calls()
        let i = installer(fx, asset, pin: pin, calls: calls, fetchGate: { try await Task.sleep(for: .milliseconds(300)) })
        let a = try await i.install(), b = try await i.install()
        #expect(a == b)
        #expect(await i.finished()?.phase == "done")
        #expect(calls.fetches == 1)
    }

    @Test func removeWhileBusyIsBusy() async throws {
        let fx = Fx()
        try fx.installed(version: "0.7.0-c1")
        let i = installer(fx, nil, pin: nil, busy: true)
        await #expect(throws: ProtocolError.self) { try await i.remove() }
        #expect(FileManager.default.fileExists(atPath: fx.engine.path))
    }

    @Test func removeKeepsDesignData() async throws {
        let fx = Fx(), calls = Calls()
        try fx.installed(version: "0.7.0-c1")
        let keep = fx.root.appendingPathComponent("design/x")
        try FileManager.default.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: keep)
        try await installer(fx, nil, pin: nil, calls: calls).remove()
        #expect(calls.swaps == 1)
        #expect(!FileManager.default.fileExists(atPath: fx.engine.path) && !FileManager.default.fileExists(atPath: fx.staging.path))
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test func removeWithoutEngineIsNotFound() async throws {
        let fx = Fx()
        do { try await installer(fx, nil, pin: nil).remove(); Issue.record("removed nothing") } catch let e as ProtocolError {
            #expect(e.code == .notFound)
        }
    }

    @Test func noPinFails() async throws {
        let fx = Fx()
        do { _ = try await installer(fx, nil, pin: nil).install(); Issue.record("installed without a pin") } catch let e as ProtocolError {
            #expect(e.code == .unavailable)
        }
    }

    @Test func stripsQuarantine() throws {
        let fx = Fx(), d = fx.dir.appendingPathComponent("q")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let f = d.appendingPathComponent("x")
        try Data("x".utf8).write(to: f)
        let v = Array("0083;00000000;Test;".utf8)
        #expect(setxattr(f.path, "com.apple.quarantine", v, v.count, 0, 0) == 0)
        FigcraftInstaller.stripQuarantine(d)
        #expect(getxattr(f.path, "com.apple.quarantine", nil, 0, 0, 0) < 0)
    }
}
