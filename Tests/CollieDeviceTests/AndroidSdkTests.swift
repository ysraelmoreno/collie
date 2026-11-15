import Testing
import Foundation
@testable import CollieDevice

@Suite struct AndroidSdkTests {
    private func fs(_ paths: Set<String>) -> (String) -> Bool { { paths.contains($0) } }

    @Test func looksLikeSdkNeedsOneMarker() {
        #expect(!AndroidSdk.looksLikeSdk("/s", exists: fs([])))
        #expect(AndroidSdk.looksLikeSdk("/s", exists: fs(["/s/platform-tools"])))
        #expect(AndroidSdk.looksLikeSdk("/s", exists: fs(["/s/system-images"])))
    }

    @Test func resolvePrefersEnvThenHomeThenCollie() {
        let e = fs(["/h/Library/Android/sdk/emulator", "/ah/platform-tools", "/asr/emulator"])
        let all = ["ANDROID_HOME": "/ah", "ANDROID_SDK_ROOT": "/asr"]
        #expect(AndroidSdk.resolve(env: all, home: "/h", colliePath: "/c", exists: e) == ("/ah", "android-home"))
        #expect(AndroidSdk.resolve(env: ["ANDROID_SDK_ROOT": "/asr"], home: "/h", colliePath: "/c", exists: e) == ("/asr", "android-sdk-root"))
        #expect(AndroidSdk.resolve(env: [:], home: "/h", colliePath: "/c", exists: e) == ("/h/Library/Android/sdk", "studio"))
    }

    @Test func collieAndroidSdkWinsEvenWhenItIsNotAnSdkYet() {
        let e = fs(["/ah/platform-tools"])
        let env = ["COLLIE_ANDROID_SDK": "/tmp/empty", "ANDROID_HOME": "/ah"]
        #expect(AndroidSdk.resolve(env: env, home: "/h", colliePath: "/c", exists: e) == ("/tmp/empty", "env"))
    }

    @Test func resolveSkipsAnEmptyAndroidHome() {
        let e = fs(["/h/Library/Android/sdk/platform-tools"])
        let env = ["ANDROID_HOME": "", "ANDROID_SDK_ROOT": "/not-an-sdk"]
        #expect(AndroidSdk.resolve(env: env, home: "/h", colliePath: "/c", exists: e) == ("/h/Library/Android/sdk", "studio"))
    }

    @Test func resolveFallsBackToCollieWhenNothingLooksLikeSdk() {
        #expect(AndroidSdk.resolve(env: ["ANDROID_HOME": "/x"], home: "/h", colliePath: "/c", exists: fs([])) == ("/c", "collie"))
    }

    /// `source.properties` for every dir: `rev[dir]` as its Pkg.Revision, dirs not in `rev` have none.
    private func props(_ rev: [String: String]) -> (String) -> String? {
        { path in rev.first { path == "/s/cmdline-tools/\($0.key)/source.properties" }.map { "Pkg.Desc=x\nPkg.Revision=\($0.value)\n" } }
    }

    @Test func sdkmanagerPrefersLatestThenHighestNumbered() {
        let latest = "/s/cmdline-tools/latest/bin/sdkmanager"
        let v9 = "/s/cmdline-tools/9.0/bin/sdkmanager", v11 = "/s/cmdline-tools/11.0/bin/sdkmanager"
        let list: (String) -> [String] = { _ in ["9.0", "11.0", "latest"] }
        let read = props(["latest": "20.0", "9.0": "9.0", "11.0": "11.0", "beta": "12.0"])
        #expect(AndroidSdk.sdkmanager(in: "/s", exists: fs([latest, v11]), list: list, read: read) == latest)
        #expect(AndroidSdk.sdkmanager(in: "/s", exists: fs([v9, v11]), list: list, read: read) == v11)
        #expect(AndroidSdk.sdkmanager(in: "/s", exists: fs([]), list: list, read: read) == nil)
        let named = "/s/cmdline-tools/beta/bin/sdkmanager"
        #expect(AndroidSdk.sdkmanager(in: "/s", exists: fs([named]), list: { _ in ["beta"] }, read: read) == named)
        #expect(AndroidSdk.sdkmanager(in: "/s", exists: fs([named, v9]), list: { _ in ["beta", "9.0"] }, read: read) == named)
    }

    @Test func sdkmanagerSkipsCmdlineTools21AndUp() {
        let latest = "/s/cmdline-tools/latest/bin/sdkmanager", v20 = "/s/cmdline-tools/20.0/bin/sdkmanager"
        let list: (String) -> [String] = { _ in ["latest", "20.0"] }
        #expect(AndroidSdk.sdkmanager(in: "/s", exists: fs([latest]), list: list, read: props(["latest": "23.0"])) == nil)
        #expect(AndroidSdk.sdkmanager(in: "/s", exists: fs([latest]), list: list, read: props(["latest": "20.1"])) == nil)
        #expect(AndroidSdk.sdkmanager(in: "/s", exists: fs([latest]), list: list, read: props(["latest": "20.0.1"])) == latest)
        #expect(AndroidSdk.sdkmanager(in: "/s", exists: fs([latest, v20]), list: list,
                                      read: props(["latest": "23.0", "20.0": "20.0"])) == v20)
        #expect(AndroidSdk.cmdlineToolsRevision("Pkg.Revision=23.0\n") == [23, 0])
        #expect(AndroidSdk.cmdlineToolsRevision("Pkg.Revision=19\n") == [19, 0])
        #expect(AndroidSdk.cmdlineToolsRevision("Pkg.Revision=abc\n") == nil)
    }

    @Test func sdkmanagerNeedsSourceProperties() {
        let latest = "/s/cmdline-tools/latest/bin/sdkmanager", v9 = "/s/cmdline-tools/9.0/bin/sdkmanager"
        let list: (String) -> [String] = { _ in ["latest", "9.0"] }
        #expect(AndroidSdk.sdkmanager(in: "/s", exists: fs([latest, v9]), list: list, read: props(["9.0": "9.0"])) == v9)
        #expect(AndroidSdk.sdkmanager(in: "/s", exists: fs([latest]), list: list, read: props([:])) == nil)
        #expect(AndroidSdk.sdkmanager(in: "/s", exists: fs([latest]), list: list, read: { _ in "Pkg.Desc=x\n" }) == nil)
    }

    private let listing = """
    Installed packages:
      Path                                 | Version | Description                     | Location
      -------                              | ------- | -------                         | -------
      platform-tools                       | 35.0.2  | Android SDK Platform-Tools      | platform-tools
      system-images;android-35;google_apis;arm64-v8a | 9 | Google APIs ARM 64 v8a System Image | system-images/android-35/google_apis/arm64-v8a

    Available Packages:
      Path                                                  | Version | Description
      -------                                               | ------- | -------
      system-images;android-35;google_apis;arm64-v8a        | 9       | Google APIs ARM 64 v8a System Image
      system-images;android-35;google_apis_playstore;arm64-v8a | 9    | Google Play ARM 64 v8a System Image
      system-images;android-36;google_apis;x86_64           | 5       | Google APIs Intel x86_64 System Image
      system-images;android-37.0;google_apis;arm64-v8a      | 1       | Google APIs ARM 64 v8a System Image
      system-images;android-CinnamonBun;google_apis;arm64-v8a | 1     | Google APIs ARM 64 v8a System Image
    """

    @Test func parseImagesKeepsOnlyGoogleApisArm64() {
        #expect(AndroidSdk.parseImages(listing) == [
            "system-images;android-35;google_apis;arm64-v8a",
            "system-images;android-37.0;google_apis;arm64-v8a",
            "system-images;android-CinnamonBun;google_apis;arm64-v8a",
        ])
    }

    @Test func pickLatestStableSkipsPreviews() {
        #expect(AndroidSdk.pickLatestStable(AndroidSdk.parseImages(listing)) == "system-images;android-37.0;google_apis;arm64-v8a")
        #expect(AndroidSdk.pickLatestStable(["system-images;android-CinnamonBun;google_apis;arm64-v8a"]) == nil)
        #expect(AndroidSdk.pickLatestStable([]) == nil)
        let ext = ["system-images;android-34-ext10;google_apis;arm64-v8a", "system-images;android-33;google_apis;arm64-v8a",
                   "system-images;android-CinnamonBun;google_apis;arm64-v8a"]
        #expect(AndroidSdk.pickLatestStable(ext) == ext[0])
    }

    @Test func parseProgressReadsPercent() {
        let p = AndroidSdk.parseProgress("[=====                                  ] 45% Downloading emulator...")
        #expect(p?.percent == 45)
        #expect(p?.label == "Downloading emulator...")
        #expect(AndroidSdk.parseProgress("[=======] 100% Unzipping x")?.percent == 100)
        let redraw = AndroidSdk.parseProgress("[==   ] 10% Downloading x\r[===  ] 11% Downloading x")
        #expect(redraw?.percent == 11)
        let ansi = AndroidSdk.parseProgress("[===  ] 12% Unzipping y\u{1B}[K")
        #expect(ansi?.percent == 12)
        #expect(ansi?.label == "Unzipping y")
        // "\r\n" is one Character in Swift: still a line break
        #expect(AndroidSdk.parseProgress("[==   ] 10% Downloading x\r\n")?.percent == 10)
        #expect(AndroidSdk.parseProgress("[==   ] 10% Downloading x\r\n[===  ] 13% Downloading x")?.percent == 13)
        #expect(AndroidSdk.parseProgress("Warning: nothing here") == nil)
    }

    @Test func parseLicensesSplitsOnTheSeparatorAndKeepsIds() {
        let out = """
        License android-sdk-license:
        ---------------------------------------
        Terms and Conditions

        This is the Android Software Development Kit License Agreement
        ---------------------------------------
        Accept? (y/N):
        License android-sdk-arm-dbt-license:
        ---------------------------------------
        Arm Debug Terms

        Second text.
        ---------------------------------------
        Accept? (y/N):
        """
        let l = AndroidSdk.parseLicenses(out)
        #expect(l.map(\.id) == ["android-sdk-license", "android-sdk-arm-dbt-license"])
        #expect(l[0].title == "Terms and Conditions")
        #expect(l[0].text.contains("License Agreement"))
        #expect(!l[0].text.contains("Accept?"))
        #expect(l[1].text.hasSuffix("Second text."))
    }
}
