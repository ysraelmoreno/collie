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
/// `licsleep` (`--licenses` sleeps 2 s first, pid in `pid`), `mkdirlic` (`--licenses` creates an empty `licenses/`),
/// `selfaccept` (a package install writes the license itself, like 23.0). Every call is appended to `calls`, its
/// `HOME|ANDROID_USER_HOME` to `envs`. `licout`: `--licenses` prints it (after "Review"), reading one answer per
/// `Accept?`. `oldjava` (holds Collie's JDK path): every run fails like 20.0 on JDK 11 unless JAVA_HOME is that path;
/// `classerr`: every run fails with the class-version error; runs that pass log JAVA_HOME to `javas`. `clidl`: like 23.0's
/// launcher, "downloads" `$HOME/.android/bin/android-cli` and unpacks `$HOME/.android/cli/bundles/` when absent (logged
/// to `downloads`).
private let fakeSdkmanager = #"""
#!/bin/sh
d=$(dirname "$0"); sdk=""; pkg=""; mode=install
for a in "$@"; do case "$a" in --sdk_root=*) sdk="${a#--sdk_root=}";; --list) mode=list;; --licenses) mode=licenses;; *) pkg="$a";; esac; done
echo "$*" >> "$d/calls"; echo "$HOME|$ANDROID_USER_HOME" >> "$d/envs"
if [ -f "$d/oldjava" ] && [ "$JAVA_HOME" != "$(cat "$d/oldjava")" ]; then
  printf 'This tool requires JDK 17 or later. Your version was detected as 11.0.33.\nTo override this check, set SKIP_JDK_VERSION_CHECK.\n'; exit 1
fi
if [ -f "$d/classerr" ]; then
  echo 'Exception in thread "main" java.lang.UnsupportedClassVersionError: com/android/sdklib/repository/generated/addon/v1/ObjectFactory has been compiled by a more recent version of the Java Runtime (class file version 61.0), this version of the Java Runtime only recognizes class file versions up to 55.0'; exit 1
fi
echo "$JAVA_HOME" >> "$d/javas"
if [ -f "$d/clidl" ]; then
  [ -f "$HOME/.android/bin/android-cli" ] || { echo "Downloading Android CLI..."; echo dl >> "$d/downloads"; mkdir -p "$HOME/.android/bin"; echo cli > "$HOME/.android/bin/android-cli"; }
  [ -d "$HOME/.android/cli/bundles" ] || { echo "Unpacking embedded installation..."; echo unpack >> "$d/downloads"; mkdir -p "$HOME/.android/cli/bundles/h1"; echo jar > "$HOME/.android/cli/bundles/h1/main.jar"; : > "$HOME/.android/cli/bundles/lock"; }
  : > "$HOME/.android/cli/analytics"
fi
if [ $mode = list ]; then cat "$d/list"; exit 0; fi
if [ $mode = licenses ]; then
  if [ -f "$sdk/licenses/android-sdk-license" ]; then echo "All SDK package licenses accepted."; exit 0; fi
  if [ -f "$d/licout" ]; then
    printf '8 of 8 SDK package licenses not accepted.\nReview licenses that have not been accepted (y/N)? '
    read a; [ "$a" = y ] || exit 0
    exec 3<&0
    while IFS= read -r line; do printf '%s\n' "$line"; case "$line" in Accept*) read a <&3;; esac; done < "$d/licout"
    exit 0
  fi
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
if [ -f "$d/selfaccept" ]; then mkdir -p "$sdk/licenses"; echo x > "$sdk/licenses/android-sdk-license"; fi
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

    var envs: [String] {
        ((try? String(contentsOf: bin.appendingPathComponent("envs"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    init(rev: String = "20.0") throws {
        home = fm.temporaryDirectory.appendingPathComponent("collie-inst-\(UUID().uuidString)")
        sdk = home.appendingPathComponent("sdk")
        bin = sdk.appendingPathComponent("cmdline-tools/latest/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fakeSdkmanager.write(to: bin.appendingPathComponent("sdkmanager"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("sdkmanager").path)
        try "Pkg.Revision=\(rev)\n".write(to: bin.deletingLastPathComponent().appendingPathComponent("source.properties"), atomically: true, encoding: .utf8)
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
                   othersRunning: (@Sendable (Bool) async -> String?)? = nil, studioSdk: Bool = false,
                   sdkPath: String? = nil, fetch: AndroidFetch? = nil) -> AndroidInstaller {
        var env = ["COLLIE_ANDROID_SDK": sdkPath ?? (studioSdk ? home.appendingPathComponent("Library/Android/sdk").path : sdk.path), "ANDROID_AVD_HOME": home.appendingPathComponent("avd").path]
        if java { env["COLLIE_JAVA_HOME"] = home.appendingPathComponent("java").path }
        return AndroidInstaller(root: home, env: env, home: home.path,
                                runDir: home.appendingPathComponent("run"), fetch: fetch ?? { url, _, _ in throw ProtocolError(code: .notFound, message: "no network: \(url)") },
                                isAppleSilicon: true, javaCandidates: [], freeSpace: { _ in free },
                                othersRunning: othersRunning ?? { studio in studio ? others : nil })
    }

    func waitFor(_ file: String) async throws {
        for _ in 0..<200 where !fm.fileExists(atPath: bin.appendingPathComponent(file).path) {
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}

/// Trimmed from Google's live `repository2-3.xml` (several channels per package; only channel-0 counts).
private let repoCatalog = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sdk:sdk-repository xmlns:sdk="http://schemas.android.com/sdk/android/repo/repository2/03" xmlns:common="http://schemas.android.com/repository/android/common/02" xmlns:generic="http://schemas.android.com/repository/android/generic/02" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<remotePackage path="platform-tools">
  <type-details xsi:type="generic:genericDetailsType"/>
  <revision><major>37</major><minor>0</minor><micro>3</micro></revision>
  <display-name>Android SDK Platform-Tools</display-name>
  <uses-license ref="android-sdk-preview-license"/>
  <channelRef ref="channel-2"/>
  <archives><archive><complete><size>16597640</size><checksum type="sha1">eca4effbe35f4968139b051bbb16753302a3c33c</checksum><url>platform-tools_r37.0.3-darwin.zip</url></complete><host-os>macosx</host-os></archive></archives>
</remotePackage>
<remotePackage path="platform-tools">
  <type-details xsi:type="generic:genericDetailsType"/>
  <revision><major>37</major><minor>0</minor><micro>1</micro></revision>
  <display-name>Android SDK Platform-Tools</display-name>
  <uses-license ref="android-sdk-license"/>
  <channelRef ref="channel-0"/>
  <archives><archive><complete><size>16110554</size><checksum type="sha1">6ae73f4de6452dc57e62ec02b68eed92a4c21661</checksum><url>platform-tools_r37.0.1-darwin.zip</url></complete><host-os>macosx</host-os></archive></archives>
</remotePackage>
<remotePackage path="emulator">
  <type-details xsi:type="generic:genericDetailsType"/>
  <revision><major>37</major><minor>3</minor><micro>9</micro></revision>
  <display-name>Android Emulator</display-name>
  <uses-license ref="android-sdk-license"/>
  <channelRef ref="channel-1"/>
  <archives><archive><complete><size>420630743</size><checksum type="sha1">05bbb7ae4e047e96204364e146e586037f4ad336</checksum><url>emulator-darwin_aarch64-16863232.zip</url></complete><host-os>macosx</host-os><host-arch>aarch64</host-arch></archive></archives>
</remotePackage>
<remotePackage path="emulator">
  <type-details xsi:type="generic:genericDetailsType"/>
  <revision><major>37</major><minor>2</minor><micro>13</micro></revision>
  <display-name>Android Emulator</display-name>
  <uses-license ref="android-sdk-license"/>
  <channelRef ref="channel-0"/>
  <archives><archive><complete><size>416113219</size><checksum type="sha1">6c5e61b873e11c7d1d08683bea089f762baee070</checksum><url>emulator-darwin_aarch64-16740729.zip</url></complete><host-os>macosx</host-os><host-arch>aarch64</host-arch></archive></archives>
</remotePackage>
</sdk:sdk-repository>
"""

/// Shaped like Google's `sys-img/google_apis/sys-img2-3.xml`.
private let sysImgCatalog = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sys-img:sdk-sys-img xmlns:sys-img="http://schemas.android.com/sdk/android/repo/sys-img2/03" xmlns:common="http://schemas.android.com/repository/android/common/02" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
<remotePackage path="system-images;android-37.0;google_apis;arm64-v8a">
  <type-details xsi:type="sys-img:sysImgDetailsType"><api-level>37</api-level></type-details>
  <revision><major>1</major></revision>
  <display-name>Google APIs ARM 64 v8a System Image</display-name>
  <uses-license ref="android-sdk-arm-dbt-license"/>
  <channelRef ref="channel-0"/>
  <archives><archive><complete><size>1</size><checksum type="sha1">00</checksum><url>arm64-v8a-37.0_r01.zip</url></complete></archive></archives>
</remotePackage>
<remotePackage path="system-images;android-CinnamonBun;google_apis;arm64-v8a">
  <revision><major>1</major></revision>
  <uses-license ref="android-sdk-preview-license"/>
  <channelRef ref="channel-2"/>
</remotePackage>
<remotePackage path="system-images;android-36;google_apis;x86_64">
  <revision><major>1</major></revision>
  <uses-license ref="intel-android-sysimage-license"/>
  <channelRef ref="channel-0"/>
</remotePackage>
</sys-img:sdk-sys-img>
"""

/// The 8 licenses real `--licenses` lists on an empty SDK.
private let allLicenses = ["android-googletv-license", "android-sdk-arm-dbt-license", "android-sdk-license", "android-sdk-preview-license",
                           "google-gdk-license", "intel-android-extra-license", "intel-android-sysimage-license", "mips-android-sysimage-license"]

extension Fixture {
    /// `licout` with the 8 licenses, texts `Text of <id>`.
    func eightLicenses() throws {
        try allLicenses.enumerated().map { "\($0 + 1)/8: License \($1):\n---------------------------------------\nText of \($1)\n---------------------------------------\nAccept? (y/N): " }
            .joined(separator: "\n").write(to: bin.appendingPathComponent("licout"), atomically: true, encoding: .utf8)
    }

    /// A fake fetch serving both catalogs.
    func catalogs() throws -> FakeFetch {
        let fake = FakeFetch()
        for (name, xml, url) in [("repo.xml", repoCatalog, AndroidDownload.catalog), ("sysimg.xml", sysImgCatalog, AndroidDownload.sysImgCatalog)] {
            let f = home.appendingPathComponent(name)
            try xml.write(to: f, atomically: true, encoding: .utf8)
            fake.serve(url.absoluteString, f)
        }
        return fake
    }

    /// `<sdk>/licenses/` as name -> contents.
    var licenseFiles: [String: String] {
        let dir = sdk.appendingPathComponent("licenses")
        return Dictionary(uniqueKeysWithValues: ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).map {
            ($0, (try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) ?? "")
        })
    }
}

private let jdkTgzURL = "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21/OpenJDK21.tar.gz"

extension Fixture {
    var collieJdk: String { AvdManager.collieJdk(home.path) }
    var javas: [String] {
        ((try? String(contentsOf: bin.appendingPathComponent("javas"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// `fake` also serves Adoptium's answer and a tiny JDK tarball (`jdk-21/Contents/Home/bin/java`).
    func serveJdk(_ fake: FakeFetch) throws {
        let src = home.appendingPathComponent("jdksrc")
        let java = src.appendingPathComponent("jdk-21/Contents/Home/bin/java")
        try fm.createDirectory(at: java.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: java, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
        let tgz = home.appendingPathComponent("jdk.tar.gz")
        let p = try Process.run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-czf", tgz.path, "-C", src.path, "jdk-21"])
        p.waitUntilExit()
        let json = home.appendingPathComponent("jdk.json")
        try """
        [{"binary":{"package":{"checksum":"\(androidHex(SHA256.hash(data: try Data(contentsOf: tgz))))","link":"\(jdkTgzURL)","size":2000}}}]
        """.write(to: json, atomically: true, encoding: .utf8)
        fake.serve(AndroidDownload.temurinAPI.absoluteString, json); fake.serve(jdkTgzURL, tgz)
    }

    func jdkFetches(_ fake: FakeFetch) -> Int { fake.urls.filter { $0 == jdkTgzURL }.count }
}

private func hashLine(_ id: String) -> String { "\n" + androidHex(Insecure.SHA1.hash(data: Data("Text of \(id)".utf8))) }

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

    /// cmdline-tools 23.0 (android CLI): no license list, the Install click is the acceptance; what it writes in
    /// `<sdk>/licenses/` stays.
    @Test func androidCliInstallsWithoutLicenses() async throws {
        let f = try Fixture(rev: "23.0")
        try f.control("selfaccept")
        let inst = f.installer()
        #expect(try await inst.licenses().isEmpty)
        #expect(await inst.status().needs == "ready")
        try await inst.install(accept: [])
        #expect(!f.calls.contains { $0.contains("--licenses") })
        #expect(try String(contentsOf: f.sdk.appendingPathComponent("licenses/android-sdk-license"), encoding: .utf8) == "x\n")
        let st = await inst.status()
        #expect(st.items.allSatisfy { $0.state == "ok" } && st.needs == "ready" && st.job?.phase == "done")
    }

    /// Every `sdkmanager` run: temp HOME = ANDROID_USER_HOME (gone after the job), `--sdk_root` without `..`.
    @Test func everySdkmanagerRunIsIsolated() async throws {
        let f = try Fixture()
        try fm.createDirectory(at: f.home.appendingPathComponent("x"), withIntermediateDirectories: true)
        let dotted = f.home.path + "/x/../sdk"
        try await f.installer(sdkPath: dotted).install(accept: ["android-sdk-license"])
        let root = "--sdk_root=\(AndroidInstaller.sdkRoot(f.sdk.path))"
        #expect(!root.contains(".."))
        #expect(f.calls.count == 5 && f.calls.allSatisfy { $0.contains(root) && !$0.contains("..") })
        #expect(f.envs.count == 5 && f.envs.allSatisfy { $0 == "\(dotted)/.collie-staging/home|\(dotted)/.collie-staging/home" })
        #expect(!fm.fileExists(atPath: f.sdk.appendingPathComponent(".collie-staging").path))
        #expect(AndroidInstaller.tail("WARNING: The SDK Manager CLI tool (sdkmanager) is deprecated. Android CLI will be used instead.\nboom")
                == "boom")
    }

    /// Classic: of the 8 the repository lists, only the channel-0 `uses-license` of the missing packages.
    @Test func licensesListsOnlyTheNeededOnes() async throws {
        let f = try Fixture()
        try f.eightLicenses()
        let fake = try f.catalogs()
        let inst = f.installer(fetch: fake.fetch)
        #expect(try await inst.licenses().map(\.id).sorted() == ["android-sdk-arm-dbt-license", "android-sdk-license"])
        #expect(Set(fake.urls) == [AndroidDownload.catalog.absoluteString, AndroidDownload.sysImgCatalog.absoluteString])
        #expect(await inst.status().needs == "needsLicense")
        #expect(!fm.fileExists(atPath: f.sdk.appendingPathComponent(".collie-staging").path))

        // platform-tools and emulator there: only the image's
        for p in ["platform-tools/adb", "emulator/emulator"] {
            let x = f.sdk.appendingPathComponent(p)
            try fm.createDirectory(at: x.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\n".write(to: x, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: x.path)
        }
        #expect(try await inst.licenses().map(\.id) == ["android-sdk-arm-dbt-license"])
    }

    @Test func installNeverWritesALicenseTheUserDidNotAccept() async throws {
        let f = try Fixture()
        try f.eightLicenses()
        let inst = f.installer(fetch: try f.catalogs().fetch)
        #expect(await code { try await inst.install(accept: ["android-sdk-license"]) } == .invalidArgs)
        #expect(f.licenseFiles.isEmpty)
        try await inst.install(accept: ["android-sdk-license", "android-sdk-arm-dbt-license", "google-gdk-license", "../evil"])
        #expect(f.licenseFiles == ["android-sdk-license": hashLine("android-sdk-license"),
                                   "android-sdk-arm-dbt-license": hashLine("android-sdk-arm-dbt-license")])
        #expect(await inst.status().needs == "ready")
    }

    /// No catalog: every pending license is asked (today's rule), and still only what the user passed is written.
    @Test func catalogFailureFallsBackToAllPending() async throws {
        let f = try Fixture()
        try f.eightLicenses()
        let inst = f.installer()   // fetch always fails
        #expect(try await inst.licenses().map(\.id) == allLicenses)
        #expect(await code { try await inst.install(accept: ["android-sdk-license", "android-sdk-arm-dbt-license"]) } == .invalidArgs)
        #expect(f.licenseFiles.isEmpty)
        try await inst.install(accept: allLicenses + ["extra"])
        #expect(f.licenseFiles == Dictionary(uniqueKeysWithValues: allLicenses.map { ($0, hashLine($0)) }))
    }

    /// A classic sdkmanager on a Java older than 17: Collie's JDK is downloaded once, the run retried once with it, and
    /// the rest of the daemon's runs use it.
    @Test func retriesOnceWithCollieJdkAfterClassVersionError() async throws {
        let f = try Fixture()
        try f.collieJdk.write(to: f.bin.appendingPathComponent("oldjava"), atomically: true, encoding: .utf8)
        let fake = FakeFetch()
        try f.serveJdk(fake)
        let inst = f.installer(fetch: fake.fetch)
        #expect(try await inst.licenses().map(\.id) == ["android-sdk-license"])
        #expect(f.calls.count == 2 && f.javas == [f.collieJdk])
        #expect(f.jdkFetches(fake) == 1)
        #expect(fm.isExecutableFile(atPath: f.collieJdk + "/bin/java"))
        #expect(!fm.fileExists(atPath: f.sdk.appendingPathComponent(".collie-staging").path))

        try await inst.install(accept: ["android-sdk-license"])
        #expect(f.calls.count == 7 && f.javas.count == 6 && f.javas.allSatisfy { $0 == f.collieJdk })
        #expect(f.jdkFetches(fake) == 1)
    }

    @Test func secondClassVersionErrorFails() async throws {
        let f = try Fixture()
        try f.control("classerr")
        let fake = FakeFetch()
        try f.serveJdk(fake)
        #expect(await code { _ = try await f.installer(fetch: fake.fetch).licenses() } == .unavailable)
        #expect(f.calls.count == 2)   // no third run
        #expect(f.jdkFetches(fake) == 1)
    }

    @Test func unrelatedFailureDoesNotDownloadJdk() async throws {
        let f = try Fixture()
        try f.acceptAlready()
        try f.control("fail")
        let fake = FakeFetch()
        try f.serveJdk(fake)
        #expect(await code { try await f.installer(fetch: fake.fetch).install(accept: []) } == .unavailable)
        #expect(!fake.urls.contains(AndroidDownload.temurinAPI.absoluteString))
        #expect(f.calls.filter { $0.hasSuffix("platform-tools") }.count == 1)
        #expect(!fm.fileExists(atPath: f.collieJdk))
    }

    /// 23.0 downloads its CLI into the job's temp HOME: kept under the daemon root, so the next job (even after a daemon
    /// restart) does not download it again.
    @Test func secondJobReusesTheCache() async throws {
        let f = try Fixture(rev: "23.0")
        try f.control("selfaccept"); try f.control("clidl")
        try await f.installer().install(accept: [])
        let downloads = { ((try? String(contentsOf: f.bin.appendingPathComponent("downloads"), encoding: .utf8)) ?? "").split(separator: "\n") }
        #expect(downloads() == ["dl", "unpack"])
        try fm.removeItem(at: f.sdk.appendingPathComponent("platform-tools"))
        try await f.installer().install(accept: [])   // a new installer: a restarted daemon
        #expect(downloads() == ["dl", "unpack"])
        #expect(fm.fileExists(atPath: f.sdk.appendingPathComponent("platform-tools/adb").path))
    }

    @Test func cacheLivesUnderTheDaemonRoot() async throws {
        let f = try Fixture(rev: "23.0")
        try f.control("selfaccept"); try f.control("clidl")
        try await f.installer().install(accept: [])
        let top = f.home.appendingPathComponent("cache")
        let keys = try fm.contentsOfDirectory(atPath: top.appendingPathComponent("android-cli").path)
        #expect(keys.count == 1)
        let c = top.appendingPathComponent("android-cli/\(keys[0])/.android")
        #expect(try String(contentsOf: c.appendingPathComponent("bin/android-cli"), encoding: .utf8) == "cli\n")
        #expect(fm.fileExists(atPath: c.appendingPathComponent("cli/bundles/h1/main.jar").path))
        #expect(!fm.fileExists(atPath: c.appendingPathComponent("cli/bundles/lock").path))
        #expect(!fm.fileExists(atPath: c.appendingPathComponent("cli/analytics").path))
        #expect((try fm.attributesOfItem(atPath: top.path)[.posixPermissions] as? Int) == 0o700)
        #expect(!fm.fileExists(atPath: f.home.appendingPathComponent(".android").path))
        #expect(!fm.fileExists(atPath: f.sdk.appendingPathComponent(".collie-staging").path))
    }

    @Test func classicNeverTouchesTheCache() async throws {
        let f = try Fixture()
        try f.control("clidl")
        try await f.installer().install(accept: ["android-sdk-license"])
        #expect(!fm.fileExists(atPath: f.home.appendingPathComponent("cache").path))
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
