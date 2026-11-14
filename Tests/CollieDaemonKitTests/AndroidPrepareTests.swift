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

private func script(_ f: URL) throws {
    try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\necho ok\n".write(to: f, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
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
                                javaCandidates: [], freeSpace: { _ in free })
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
