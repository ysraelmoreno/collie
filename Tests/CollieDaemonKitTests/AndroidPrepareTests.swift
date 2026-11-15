import Testing
import Foundation
import CryptoKit
import CollieProtocol
@testable import CollieDaemonKit

/// Serves local files for the URLs it knows, records every URL asked. No network.
private final class FakeFetch: @unchecked Sendable {
    private let lock = NSLock()
    private var served: [String: URL] = [:]
    private var asked: [String] = []
    var urls: [String] { lock.withLock { asked } }
    func serve(_ url: String, _ file: URL) { lock.withLock { served[url] = file } }
    var fetch: AndroidFetch {
        { url, to, progress in
            let src = self.lock.withLock { () -> URL? in self.asked.append(url.absoluteString); return self.served[url.absoluteString] }
            guard let src else { throw ProtocolError(code: .notFound, message: "fake: \(url)") }
            try FileManager.default.copyItem(at: src, to: to)
            progress(1, 1)
        }
    }
}

private var fm: FileManager { .default }
private let catalogURL = "https://dl.google.com/android/repository/repository2-3.xml"
private let zipURL = "https://dl.google.com/android/repository/commandlinetools-mac-1_latest.zip"
private let jdkURL = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21/OpenJDK21.tar.gz"

private func tmp(_ name: String) throws -> URL {
    let d = fm.temporaryDirectory.appendingPathComponent("collie-prep-\(name)-\(UUID().uuidString)")
    try fm.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// A `cmdline-tools/<dir>/bin/<tool>` also gets `<dir>/source.properties` with Pkg.Revision `rev`.
private func script(_ f: URL, rev: String = "20.0") throws {
    try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\necho ok\n".write(to: f, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
    let dir = f.deletingLastPathComponent().deletingLastPathComponent()
    if f.path.contains("cmdline-tools/") {
        try "Pkg.Revision=\(rev)\n".write(to: dir.appendingPathComponent("source.properties"), atomically: true, encoding: .utf8)
    }
}

private func sh(_ exe: String, _ args: [String]) throws {
    let p = try Process.run(URL(fileURLWithPath: exe), arguments: args)
    p.waitUntilExit()
    #expect(p.terminationStatus == 0)
}

/// A temp home + SDK and a fake fetch serving a real tiny cmdline-tools zip and JDK tarball (built here with ditto/tar).
private struct Fixture {
    let home: URL, sdk: URL, fake = FakeFetch()
    var staging: URL { sdk.appendingPathComponent(".collie-staging") }

    /// `evilLink`: the JDK tarball also holds `Contents/escape -> ../../../../etc`.
    init(zipSum: String? = nil, evilLink: Bool = false) throws {
        home = try tmp("home")
        sdk = home.appendingPathComponent("sdk")   // not created: prepare must create it
        let src = try tmp("src")
        try script(src.appendingPathComponent("tools/cmdline-tools/bin/sdkmanager"))
        let zip = src.appendingPathComponent("tools.zip")
        try sh("/usr/bin/ditto", ["-c", "-k", "--keepParent", src.appendingPathComponent("tools/cmdline-tools").path, zip.path])
        try script(src.appendingPathComponent("jdk/jdk-21.0.5+11/Contents/Home/bin/java"))
        if evilLink {
            try fm.createSymbolicLink(atPath: src.appendingPathComponent("jdk/jdk-21.0.5+11/Contents/escape").path,
                                      withDestinationPath: "../../../../etc")
        }
        let tgz = src.appendingPathComponent("jdk.tar.gz")
        try sh("/usr/bin/tar", ["-czf", tgz.path, "-C", src.appendingPathComponent("jdk").path, "jdk-21.0.5+11"])
        let zipData = try Data(contentsOf: zip)
        let sum = zipSum ?? androidHex(Insecure.SHA1.hash(data: zipData))
        let catalog = src.appendingPathComponent("catalog.xml")
        try """
        <sdk:sdk-repository xmlns:sdk="x"><remotePackage path="cmdline-tools;1.0"><revision><major>1</major></revision>
        <channelRef ref="channel-0"/><archives><archive><complete><size>1000</size><checksum type="sha1">\(sum)</checksum>
        <url>commandlinetools-mac-1_latest.zip</url></complete><host-os>macosx</host-os></archive></archives></remotePackage></sdk:sdk-repository>
        """.write(to: catalog, atomically: true, encoding: .utf8)
        let json = src.appendingPathComponent("jdk.json")
        let jdkSum = androidHex(SHA256.hash(data: try Data(contentsOf: tgz)))
        try """
        [{"binary":{"package":{"checksum":"\(jdkSum)","link":"\(jdkURL)","size":2000}}}]
        """.write(to: json, atomically: true, encoding: .utf8)
        fake.serve(catalogURL, catalog); fake.serve(zipURL, zip); fake.serve(AndroidDownload.temurinAPI.absoluteString, json); fake.serve(jdkURL, tgz)
    }

    /// `java`: whether a usable Java is there (via COLLIE_JAVA_HOME).
    func installer(java: Bool, appleSilicon: Bool = true, free: Int64? = 1 << 40, fetch: AndroidFetch? = nil) throws -> AndroidInstaller {
        var env = ["COLLIE_ANDROID_SDK": sdk.path, "PATH": "/usr/bin:/bin"]
        if java {
            let j = home.appendingPathComponent("java")
            try script(j.appendingPathComponent("bin/java"))
            env["COLLIE_JAVA_HOME"] = j.path
        }
        return AndroidInstaller(root: home, env: env, home: home.path, runDir: home.appendingPathComponent("run"), fetch: fetch ?? fake.fetch, isAppleSilicon: appleSilicon,
                                javaCandidates: [], freeSpace: { _ in free }, othersRunning: { _ in nil })   // no pgrep
    }

    var collieJdkJava: String { AvdManager.collieJdk(home.path) + "/bin/java" }
}

@Suite struct AndroidPrepareTests {
    @Test func prepareInstallsCmdlineToolsFromTheFakeFetch() async throws {
        let f = try Fixture()
        try await f.installer(java: true).prepare()
        #expect(fm.isExecutableFile(atPath: f.sdk.appendingPathComponent("cmdline-tools/latest/bin/sdkmanager").path))
        #expect(f.fake.urls == [catalogURL, zipURL])
        #expect(!fm.fileExists(atPath: f.staging.path))
        #expect(!fm.fileExists(atPath: f.collieJdkJava))
    }

    @Test func prepareDownloadsTheJdkWhenJavaIsMissing() async throws {
        let f = try Fixture()
        try await f.installer(java: false).prepare()
        #expect(fm.isExecutableFile(atPath: f.collieJdkJava))
        #expect(fm.isExecutableFile(atPath: f.sdk.appendingPathComponent("cmdline-tools/latest/bin/sdkmanager").path))
        #expect(Set(f.fake.urls) == [catalogURL, zipURL, AndroidDownload.temurinAPI.absoluteString, jdkURL])
        #expect(!fm.fileExists(atPath: f.staging.path))
    }

    @Test func prepareDownloadsTheJdkWhenCollieJavaHomeIsEmptyDespiteACandidate() async throws {
        let f = try Fixture()
        let studio = f.home.appendingPathComponent("studio")
        try script(studio.appendingPathComponent("bin/java"))
        let inst = AndroidInstaller(root: f.home, env: ["COLLIE_ANDROID_SDK": f.sdk.path, "PATH": "/usr/bin:/bin", "COLLIE_JAVA_HOME": ""],
                                    home: f.home.path, runDir: f.home.appendingPathComponent("run"), fetch: f.fake.fetch, isAppleSilicon: true,
                                    javaCandidates: [studio.path], freeSpace: { _ in 1 << 40 })
        try await inst.prepare()
        #expect(fm.isExecutableFile(atPath: f.collieJdkJava))
    }

    @Test func prepareLeavesAnExistingCmdlineToolsAlone() async throws {
        let f = try Fixture()
        let numbered = f.sdk.appendingPathComponent("cmdline-tools/19.0/bin/sdkmanager")
        try script(numbered)
        try await f.installer(java: false).prepare()
        #expect(f.fake.urls == [AndroidDownload.temurinAPI.absoluteString, jdkURL])
        #expect(try fm.contentsOfDirectory(atPath: f.sdk.appendingPathComponent("cmdline-tools").path) == ["19.0"])
        #expect(try String(contentsOf: numbered, encoding: .utf8) == "#!/bin/sh\necho ok\n")
        #expect(fm.isExecutableFile(atPath: f.collieJdkJava))
    }

    /// Studio's SDK with `cmdline-tools/latest` 23.0 (android CLI): allowed, nothing downloaded.
    @Test func prepareKeepsAStudioLatest23() async throws {
        let f = try Fixture()
        let latest = f.sdk.appendingPathComponent("cmdline-tools/latest/bin/sdkmanager")
        try script(latest, rev: "23.0")
        let inst = try f.installer(java: true)
        try await inst.prepare()
        #expect(f.fake.urls.isEmpty)
        #expect(try fm.contentsOfDirectory(atPath: f.sdk.appendingPathComponent("cmdline-tools").path) == ["latest"])
        #expect(await inst.status().items.first { $0.id == "cmdline-tools" }?.detail == latest.path)
    }

    /// A `latest` with no revision is not usable and never touched: 20.0 goes beside it.
    @Test func prepareInstalls20BesideAnUnusableLatest() async throws {
        let f = try Fixture()
        let latest = f.sdk.appendingPathComponent("cmdline-tools/latest/bin/sdkmanager")
        try script(latest)
        try fm.removeItem(at: f.sdk.appendingPathComponent("cmdline-tools/latest/source.properties"))
        try await f.installer(java: true).prepare()
        #expect(f.fake.urls == [catalogURL, zipURL])
        #expect(fm.isExecutableFile(atPath: f.sdk.appendingPathComponent("cmdline-tools/20.0/bin/sdkmanager").path))
        #expect(Set(try fm.contentsOfDirectory(atPath: f.sdk.appendingPathComponent("cmdline-tools").path)) == ["latest", "20.0"])
    }

    /// A fake unknown `latest` (22.0) logging its args in `calls`, `HOME|ANDROID_USER_HOME` in `envs`. Controls (files
    /// in `bin`) act on a package install (the probe): `selfaccept` writes `licenses/`, `kill` dies by SIGKILL,
    /// `sleep` sleeps 30 s (pid in `pid`). Returns `bin`.
    private func unknown22(_ f: Fixture, _ controls: [String] = []) throws -> URL {
        let bin = f.sdk.appendingPathComponent("cmdline-tools/latest/bin")
        try script(bin.appendingPathComponent("sdkmanager"), rev: "22.0")
        try #"""
        #!/bin/sh
        d=$(dirname "$0")
        for a in "$@"; do case "$a" in --sdk_root=*) s="${a#--sdk_root=}";; esac; done
        echo "$*" >> "$d/calls"; echo "$HOME|$ANDROID_USER_HOME" >> "$d/envs"
        case "$*" in *--licenses*) exit 0;; esac
        if [ -f "$d/sleep" ]; then echo $$ > "$d/pid"; sleep 30; fi
        if [ -f "$d/kill" ]; then kill -9 $$; fi
        if [ -f "$d/selfaccept" ]; then mkdir -p "$s/licenses"; echo x > "$s/licenses/android-sdk-license"; fi
        exit 0
        """#.write(to: bin.appendingPathComponent("sdkmanager"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("sdkmanager").path)
        for c in controls { try "".write(to: bin.appendingPathComponent(c), atomically: true, encoding: .utf8) }
        return bin
    }

    private func lines(_ bin: URL, _ name: String) -> [String] {
        ((try? String(contentsOf: bin.appendingPathComponent(name), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func failure(_ body: () async throws -> Void) async -> ProtocolError? {
        do { try await body(); return nil } catch { return error as? ProtocolError }
    }

    @Test func anUnknownCmdlineToolsThatSelfAcceptsIsBlocked() async throws {
        let f = try Fixture()
        let bin = try unknown22(f, ["selfaccept"])
        let inst = try f.installer(java: true)
        for _ in 0..<2 {
            let e = await failure { try await inst.install(accept: []) }
            #expect(e?.code == .unavailable && e?.message.contains("cmdline-tools 22.0 accepts") == true)
            #expect(e?.message.contains("\(f.sdk.path)/cmdline-tools/20.0") == true)
        }
        #expect(f.fake.urls.isEmpty)   // blocked, no 20.0 download
        #expect(lines(bin, "calls").count == 1 && lines(bin, "calls")[0].hasSuffix(" platform-tools"))   // probed once
        #expect(!fm.fileExists(atPath: f.sdk.appendingPathComponent("licenses").path))
        #expect(!fm.fileExists(atPath: f.staging.path))
        #expect(await inst.status().items.first { $0.id == "cmdline-tools" }?.detail.contains("22.0 accepts") == true)
    }

    @Test func anUnknownCmdlineToolsThatAsksRunsAsClassic() async throws {
        let f = try Fixture()
        let bin = try unknown22(f)
        let inst = try f.installer(java: true)
        #expect(try await inst.licenses().isEmpty)
        #expect(try await inst.licenses().isEmpty)
        let calls = lines(bin, "calls")
        let probe = AndroidInstaller.sdkRoot(f.sdk.path) + "/.collie-staging/probe"
        #expect(calls.count == 3 && calls[0] == "--sdk_root=\(probe)/sdk platform-tools"
                && calls[1].hasPrefix("--licenses") && calls[2].hasPrefix("--licenses"))
        let probeHome = f.sdk.path + "/.collie-staging/probe/home"
        #expect(lines(bin, "envs").first == "\(probeHome)|\(probeHome)")
        #expect(!fm.fileExists(atPath: f.staging.path))
    }

    /// A probe killed by a signal, or cancelled, is never cached as classic: the next call probes again.
    @Test func aKilledOrCancelledProbeIsNotCached() async throws {
        let f = try Fixture()
        let bin = try unknown22(f, ["kill"])
        let inst = try f.installer(java: true)
        #expect(await failure { _ = try await inst.licenses() }?.message.contains("22.0 accepts") == true)
        try fm.removeItem(at: bin.appendingPathComponent("kill"))

        try "".write(to: bin.appendingPathComponent("sleep"), atomically: true, encoding: .utf8)
        let read = Task { await failure { _ = try await inst.licenses() } }
        for _ in 0..<200 where !fm.fileExists(atPath: bin.appendingPathComponent("pid").path) { try await Task.sleep(for: .milliseconds(25)) }
        await inst.cancel()
        #expect(await read.value == AndroidInstaller.cancelled)
        try fm.removeItem(at: bin.appendingPathComponent("sleep"))

        try "".write(to: bin.appendingPathComponent("selfaccept"), atomically: true, encoding: .utf8)
        #expect(await failure { _ = try await inst.licenses() }?.message.contains("22.0 accepts") == true)
        #expect(lines(bin, "calls").count == 3 && lines(bin, "calls").allSatisfy { $0.hasSuffix(" platform-tools") })   // probed each time
        #expect(!fm.fileExists(atPath: f.staging.path))
    }

    @Test func prepareCleansTheStagingOnFailure() async throws {
        let f = try Fixture(zipSum: String(repeating: "0", count: 40))
        try script(f.sdk.appendingPathComponent("platform-tools/adb"))
        await #expect(throws: ProtocolError.self) { try await f.installer(java: true).prepare() }
        #expect(!fm.fileExists(atPath: f.staging.path))
        #expect(!fm.fileExists(atPath: f.sdk.appendingPathComponent("cmdline-tools").path))
        #expect(fm.isExecutableFile(atPath: f.sdk.appendingPathComponent("platform-tools/adb").path))
    }

    @Test func prepareRefusesWhenTheDiskIsTooFull() async throws {
        let f = try Fixture()
        // catalog size 1000: needs 2000 free
        await #expect(throws: ProtocolError.self) { try await f.installer(java: true, free: 1999).prepare() }
        #expect(!fm.fileExists(atPath: f.staging.path))
        #expect(f.fake.urls == [catalogURL])
    }

    @Test func prepareRefusesALinkOutOfTheArchive() async throws {
        let f = try Fixture(evilLink: true)
        try script(f.sdk.appendingPathComponent("cmdline-tools/latest/bin/sdkmanager"))
        await #expect(throws: ProtocolError.self) { try await f.installer(java: false).prepare() }
        #expect(!fm.fileExists(atPath: AvdManager.collieJdk(f.home.path)))
        #expect(!fm.fileExists(atPath: f.staging.path))
        #expect(AndroidInstaller.staysInside(link: "Contents/MacOS/libjli.dylib", target: "../Home/lib/libjli.dylib"))
        #expect(!AndroidInstaller.staysInside(link: "a/b", target: "../../x"))
        #expect(!AndroidInstaller.staysInside(link: "a", target: "/etc"))
        #expect(!AndroidInstaller.staysInside(link: "a/b", target: "c/../../../x"))
    }

    @Test func prepareReportsACancelAsCancelled() async throws {
        let f = try Fixture()
        do {
            try await f.installer(java: true, fetch: { _, _, _ in throw CancellationError() }).prepare()
            Issue.record("expected an error")
        } catch {
            #expect(error as? ProtocolError == AndroidInstaller.cancelled)
        }
        #expect(!fm.fileExists(atPath: f.staging.path))
    }

    @Test func prepareRefusesIntelHosts() async throws {
        let f = try Fixture()
        do {
            try await f.installer(java: false, appleSilicon: false).prepare()
            Issue.record("expected an error")
        } catch let error as ProtocolError {
            #expect(error.code == .unavailable && error.message.contains("Apple Silicon"))
        }
        #expect(f.fake.urls.isEmpty)
        #expect(!fm.fileExists(atPath: f.sdk.path))
    }

    @Test func prepareIsSkippedWhenEverythingIsThere() async throws {
        let f = try Fixture()
        try script(f.sdk.appendingPathComponent("cmdline-tools/latest/bin/sdkmanager"))
        try await f.installer(java: true).prepare()
        #expect(f.fake.urls.isEmpty)
        #expect(!fm.fileExists(atPath: f.staging.path))
    }
}
