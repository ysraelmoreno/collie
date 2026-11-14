import Testing
import Foundation
import CryptoKit
import CollieProtocol
@testable import CollieDaemonKit

private var fm: FileManager { .default }

/// A fake `sdkmanager`: `--list` prints `list` beside it, `--licenses` asks like the real one (unless
/// `<sdk>/licenses/android-sdk-license` exists), a package prints progress with `\r`, then creates what it would install.
/// Control files beside it: `sleep` (sleep 30 first, pid in `pid`), `fail` (exit 1), `direct` (`--licenses` asks
/// `Accept?` with no "Review" question; "y" writes the license file), `autoaccept` (`--licenses` writes it unasked),
/// `licsleep` (`--licenses` sleeps 2 s first, pid in `pid`), `mkdirlic` (`--licenses` creates an empty `licenses/`).
/// Every call is appended to `calls`.
private let fakeSdkmanager = #"""
#!/bin/sh
d=$(dirname "$0"); sdk=""; pkg=""; mode=install
for a in "$@"; do case "$a" in --sdk_root=*) sdk="${a#--sdk_root=}";; --list) mode=list;; --licenses) mode=licenses;; *) pkg="$a";; esac; done
echo "$*" >> "$d/calls"
if [ $mode = list ]; then cat "$d/list"; exit 0; fi
if [ $mode = licenses ]; then
  if [ -f "$sdk/licenses/android-sdk-license" ]; then echo "All SDK package licenses accepted."; exit 0; fi
  if [ -f "$d/licsleep" ]; then echo $$ > "$d/pid"; sleep 2; fi
  if [ -f "$d/mkdirlic" ]; then mkdir -p "$sdk/licenses"; fi
  if [ -f "$d/autoaccept" ]; then mkdir -p "$sdk/licenses"; echo x > "$sdk/licenses/android-sdk-license"; exit 0; fi
  if [ -f "$d/direct" ]; then
    printf 'License android-sdk-license:\n----------\nText\n----------\nAccept? (y/N): '
    read a; if [ "$a" = y ]; then mkdir -p "$sdk/licenses"; echo x > "$sdk/licenses/android-sdk-license"; fi; echo; exit 0
  fi
  printf '1 of 1 SDK package license not accepted.\nReview license that has not been accepted (y/N)? '
  read a; [ "$a" = y ] || exit 0
  printf '\n1/1: License android-sdk-license:\n---------------------------------------\nTerms and Conditions\n\nThis is the Android Software Development Kit License Agreement\n---------------------------------------\nAccept? (y/N): '
  read a; echo; exit 0
fi
if [ -f "$d/sleep" ]; then echo $$ > "$d/pid"; sleep 30; fi
if [ -f "$d/fail" ]; then echo "Error: No space left on device"; exit 1; fi
[ -f "$sdk/licenses/android-sdk-license" ] || { echo "Skipping $pkg: license not accepted"; exit 0; }
printf '[====    ] 45%% Downloading %s...\r[========] 100%% Unzipping...\n' "$pkg"
case "$pkg" in
  platform-tools) mkdir -p "$sdk/platform-tools"; printf '#!/bin/sh\n' > "$sdk/platform-tools/adb"; chmod +x "$sdk/platform-tools/adb";;
  emulator) mkdir -p "$sdk/emulator"; printf '#!/bin/sh\n' > "$sdk/emulator/emulator"; chmod +x "$sdk/emulator/emulator";;
  system-images*) mkdir -p "$sdk/$(echo "$pkg" | tr ';' '/')";;
esac
"""#

private let listOutput = """
Installed packages:
Available Packages:
  Path                                              | Version | Description
  -------                                           | ------- | -------
  platform-tools                                    | 36.0.0  | Android SDK Platform-Tools
  system-images;android-35;google_apis;arm64-v8a    | 9       | Google APIs ARM 64 v8a System Image
  system-images;android-36;google_apis;arm64-v8a    | 7       | Google APIs ARM 64 v8a System Image
  system-images;android-36;google_apis;x86_64       | 7       | Google APIs Intel x86_64 Atom System Image
  system-images;android-CinnamonBun;google_apis;arm64-v8a | 1 | Google APIs ARM 64 v8a System Image
"""

private let licenseText = "Terms and Conditions\n\nThis is the Android Software Development Kit License Agreement"

private struct Fixture {
    let home: URL, sdk: URL, bin: URL
    var calls: [String] {
        ((try? String(contentsOf: bin.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    init() throws {
        home = fm.temporaryDirectory.appendingPathComponent("collie-inst-\(UUID().uuidString)")
        sdk = home.appendingPathComponent("sdk")
        bin = sdk.appendingPathComponent("cmdline-tools/latest/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fakeSdkmanager.write(to: bin.appendingPathComponent("sdkmanager"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("sdkmanager").path)
        try listOutput.write(to: bin.appendingPathComponent("list"), atomically: true, encoding: .utf8)
        let java = home.appendingPathComponent("java/bin/java")
        try fm.createDirectory(at: java.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: java, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
    }

    func control(_ name: String) throws { try "".write(to: bin.appendingPathComponent(name), atomically: true, encoding: .utf8) }

    func acceptAlready() throws {
        let dir = sdk.appendingPathComponent("licenses")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "\n\(androidHex(Insecure.SHA1.hash(data: Data(licenseText.utf8))))".write(
            to: dir.appendingPathComponent("android-sdk-license"), atomically: true, encoding: .utf8)
    }

    func installer(java: Bool = true, free: Int64? = 1 << 40, others: String? = nil,
                   othersRunning: (@Sendable (Bool) async -> String?)? = nil, studioSdk: Bool = false) -> AndroidInstaller {
        var env = ["COLLIE_ANDROID_SDK": studioSdk ? home.appendingPathComponent("Library/Android/sdk").path : sdk.path, "ANDROID_AVD_HOME": home.appendingPathComponent("avd").path]
        if java { env["COLLIE_JAVA_HOME"] = home.appendingPathComponent("java").path }
        return AndroidInstaller(root: home, env: env, home: home.path,
                                runDir: home.appendingPathComponent("run"), fetch: { url, _, _ in throw ProtocolError(code: .notFound, message: "no network: \(url)") },
                                isAppleSilicon: true, javaCandidates: [], freeSpace: { _ in free },
                                othersRunning: othersRunning ?? { studio in studio ? others : nil })
    }

    func waitFor(_ file: String) async throws {
        for _ in 0..<200 where !fm.fileExists(atPath: bin.appendingPathComponent(file).path) {
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

private func code(_ body: () async throws -> Void) async -> ErrorCode? {
    do { try await body(); return nil } catch { return (error as? ProtocolError)?.code }
}

@Suite struct AndroidInstallTests {
    @Test func statusReportsMissingItems() async throws {
        let f = try Fixture()
        let s = await f.installer().status()
        #expect(s.sdk == .init(path: f.sdk.path, source: "env"))
        #expect(s.items.map(\.id) == ["java", "cmdline-tools", "platform-tools", "emulator", "image"])
        #expect(s.items.map(\.state) == ["ok", "ok", "missing", "missing", "missing"])
        #expect(s.needs == "needsLicense")
        #expect(s.job == nil && s.lite == false)

        try fm.removeItem(at: f.bin.appendingPathComponent("sdkmanager"))
        #expect(await f.installer(java: false).status().needs == "needsPrepare")
    }

    @Test func licensesBeforeCmdlineToolsIsNotReady() async throws {
        let f = try Fixture()
        try fm.removeItem(at: f.bin.appendingPathComponent("sdkmanager"))
        #expect(await code { _ = try await f.installer().licenses() } == .unavailable)
    }

    @Test func installRefusesWithoutAcceptedLicenses() async throws {
        let f = try Fixture()
        let inst = f.installer()
        let l = try await inst.licenses()
        #expect(l == [.init(id: "android-sdk-license", title: "Terms and Conditions", text: licenseText, accepted: false)])
        #expect(await code { try await inst.install(accept: []) } == .invalidArgs)
        #expect(await code { try await inst.install(accept: ["other"]) } == .invalidArgs)
        #expect(!fm.fileExists(atPath: f.sdk.appendingPathComponent("licenses").path))
        #expect(f.calls.allSatisfy { $0.contains("--licenses") })
        #expect(await inst.status().job?.phase == "failed")
    }

    @Test func installRunsTheThreePackagesInOrder() async throws {
        let f = try Fixture()
        let inst = f.installer()
        try await inst.install(accept: ["android-sdk-license"])
        let s = "--sdk_root=\(f.sdk.path)"
        #expect(f.calls == ["--licenses \(s)", "\(s) platform-tools", "\(s) emulator", "--list \(s)",
                            "\(s) system-images;android-36;google_apis;arm64-v8a"])
        let st = await inst.status()
        #expect(st.items.allSatisfy { $0.state == "ok" })
        #expect(st.needs == "ready")
        #expect(st.job?.phase == "done" && st.job?.percent == 100)
    }

    @Test func acceptanceWritesTheSdkmanagerLicenseFile() async throws {
        let f = try Fixture()
        try await f.installer().install(accept: ["android-sdk-license"])
        let file = try String(contentsOf: f.sdk.appendingPathComponent("licenses/android-sdk-license"), encoding: .utf8)
        #expect(file == "\n" + androidHex(Insecure.SHA1.hash(data: Data(licenseText.utf8))))
    }

    @Test func installPicksTheNewestStableImage() async throws {
        let f = try Fixture()
        try f.acceptAlready()
        try await f.installer().install(accept: [])
        #expect(fm.fileExists(atPath: f.sdk.appendingPathComponent("system-images/android-36/google_apis/arm64-v8a").path))
        #expect(!fm.fileExists(atPath: f.sdk.appendingPathComponent("system-images/android-CinnamonBun").path))
        #expect(!fm.fileExists(atPath: f.sdk.appendingPathComponent("system-images/android-35").path))
    }

    @Test func secondInstallWhileRunningIsBusy() async throws {
        let f = try Fixture()
        try f.acceptAlready()
        try f.control("sleep")
        let inst = f.installer()
        let first = Task { await code { try await inst.install(accept: []) } }
        try await f.waitFor("pid")
        #expect(await code { try await inst.install(accept: []) } == .conflict)
        #expect(try await inst.licenses().isEmpty)   // the job's answer, no second sdkmanager
        #expect(f.calls.filter { $0.contains("--licenses") }.count == 1)
        await inst.cancel()
        #expect(await first.value == AndroidInstaller.cancelled.code)
        #expect(f.calls.filter { $0.hasSuffix("platform-tools") }.count == 1)
    }

    @Test func cancelKillsTheProcessAndKeepsExistingFiles() async throws {
        let f = try Fixture()
        try f.acceptAlready()
        try f.control("sleep")
        let inst = f.installer()
        let first = Task { await code { try await inst.install(accept: []) } }
        try await f.waitFor("pid")
        let pid = try #require(Int32(try String(contentsOf: f.bin.appendingPathComponent("pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        await inst.cancel()
        _ = await first.value
        var gone = false
        for _ in 0..<80 { if kill(pid, 0) != 0 { gone = true; break }; try await Task.sleep(for: .milliseconds(25)) }
        #expect(gone)
        #expect(await inst.status().job?.phase == "cancelled")
        #expect(fm.isExecutableFile(atPath: f.bin.appendingPathComponent("sdkmanager").path))
        #expect(fm.fileExists(atPath: f.sdk.appendingPathComponent("licenses/android-sdk-license").path))
        #expect(!fm.fileExists(atPath: f.sdk.appendingPathComponent(".collie-staging").path))
        // retry redoes what is missing
        try fm.removeItem(at: f.bin.appendingPathComponent("sleep"))
        try await inst.install(accept: [])
        #expect(await inst.status().needs == "ready")
    }

    @Test func lowDiskFailsBeforeDownloading() async throws {
        let f = try Fixture()
        try f.acceptAlready()
        #expect(await code { try await f.installer(free: 100 << 20).install(accept: []) } == .unavailable)
        #expect(f.calls.allSatisfy { $0.contains("--licenses") })

        // full mid-way: failed with the item, retry only redoes what is missing
        try f.control("fail")
        let inst = f.installer()
        #expect(await code { try await inst.install(accept: []) } == .unavailable)
        let job = await inst.status().job
        #expect(job?.phase == "failed" && job?.item == "platform-tools")
        #expect(job?.error?.contains("No space left") == true)
    }

    @Test func licensesNeverAcceptForTheUser() async throws {
        let f = try Fixture()
        let licenses = f.sdk.appendingPathComponent("licenses")
        try f.control("direct")   // no "Review licenses?" first: an early "y" would accept
        let l = try await f.installer().licenses()
        #expect(l.map(\.id) == ["android-sdk-license"] && l.allSatisfy { !$0.accepted })
        #expect(!fm.fileExists(atPath: licenses.path))

        try f.control("autoaccept")   // wrote a license anyway: restored, and loudly
        #expect(await code { _ = try await f.installer().licenses() } == .internal)
        #expect(((try? fm.contentsOfDirectory(atPath: licenses.path)) ?? []).isEmpty)   // an empty dir may stay
    }

    @Test func licensesReadIsBusy() async throws {
        let f = try Fixture()
        try f.control("licsleep")
        let inst = f.installer()
        let read = Task { try await inst.licenses() }
        try await f.waitFor("pid")
        #expect(await code { _ = try await inst.start(accept: []) } == .conflict)
        #expect(await code { _ = try await inst.licenses() } == .conflict)   // nothing read yet
        #expect(try await read.value.map(\.id) == ["android-sdk-license"])
        #expect(f.calls.count == 1)
    }

    @Test func busyWithNothingReadAndCancelWhileCheckingOthers() async throws {
        let f = try Fixture()
        let inst = f.installer(othersRunning: { _ in try? await Task.sleep(for: .milliseconds(400)); return nil })
        let first = Task { await code { try await inst.install(accept: []) } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await code { _ = try await inst.licenses() } == .conflict)
        await inst.cancel()
        #expect(await first.value == AndroidInstaller.cancelled.code)
        #expect(f.calls.isEmpty)
        #expect(await inst.status().job == nil)
    }

    @Test func anEmptyLicensesDirIsNoChange() async throws {
        let f = try Fixture()
        try f.control("mkdirlic")
        #expect(try await f.installer().licenses().map(\.accepted) == [false])
    }

    @Test func studioRunningIsBusy() async throws {
        let f = try Fixture()
        #expect(await code { try await f.installer(others: "Android Studio", studioSdk: true).install(accept: ["android-sdk-license"]) } == .conflict)
        #expect(f.calls.isEmpty)
    }

    @Test func studioRunningOnAnotherSdkIsNotBusy() async throws {
        let f = try Fixture()
        #expect(await code { try await f.installer(others: "Android Studio").install(accept: ["android-sdk-license"]) } != .conflict)
        #expect(AndroidInstaller.blocksForStudio(sdk: "/h/Library/Android/sdk/", home: "/h"))
        #expect(!AndroidInstaller.blocksForStudio(sdk: "/tmp/x/sdk", home: "/h"))
    }

    @Test func alreadyAcceptedLicensesSkipTheStep() async throws {
        let f = try Fixture()
        try f.acceptAlready()
        let inst = f.installer()
        #expect(try await inst.licenses().isEmpty)
        #expect(await inst.status().needs == "ready")
        try await inst.install(accept: [])
        #expect(await inst.status().items.allSatisfy { $0.state == "ok" })
    }
}
