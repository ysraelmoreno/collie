import Testing
import Foundation
@testable import CollieDevice

@Suite struct LiteAvdTests {
    private func img(_ api: String, _ tag: String, _ abi: String = "arm64-v8a") -> String {
        "system-images;\(api);\(tag);\(abi)"
    }

    @Test func pickImageTakesHighestGoogleApisArm64() {
        #expect(LiteAvd.pickImage([img("android-35", "google_apis"), img("android-37.0", "google_apis")]) == img("android-37.0", "google_apis"))
        #expect(LiteAvd.pickImage([img("android-35", "google_apis"), img("android-37.0", "google_apis_playstore")]) == img("android-35", "google_apis"))
        #expect(LiteAvd.pickImage([img("android-35", "google_apis_playstore")]) == img("android-35", "google_apis_playstore"))
        #expect(LiteAvd.pickImage([img("android-35", "default")]) == nil)
        #expect(LiteAvd.pickImage([img("android-37.0", "google_apis", "x86_64")]) == nil)
        #expect(LiteAvd.pickImage([]) == nil)
    }

    @Test func mergeReplacesBothSpacings() {
        let out = LiteAvd.mergeConfig("hw.ramSize = 3072\nhw.ramSize=2048\nfoo=bar\n", ["hw.ramSize": "1536"])
        #expect(out.components(separatedBy: "hw.ramSize").count == 2)
        #expect(out.contains("hw.ramSize=1536\n"))
    }

    @Test func mergeAppendsMissingKeysAndKeepsTheRest() {
        let out = LiteAvd.mergeConfig("foo=bar\n# note\n", ["hw.cpu.ncore": "2"])
        #expect(out == "foo=bar\n# note\nhw.cpu.ncore=2\n")
    }

    @Test func overridesCarryTheSpecValues() {
        let spec = ["hw.lcd.width": "720", "hw.lcd.height": "1280", "hw.lcd.density": "320", "hw.ramSize": "1536",
                    "hw.cpu.ncore": "2", "disk.dataPartition.size": "2G", "hw.camera.back": "none",
                    "hw.camera.front": "none", "hw.audioInput": "no", "hw.audioOutput": "no",
                    "hw.sensors.orientation": "no", "hw.sensors.proximity": "no", "hw.sensors.humidity": "no",
                    "hw.sensors.pressure": "no", "hw.sensors.magnetic_field": "no", "hw.sensors.temperature": "no",
                    "showDeviceFrame": "no", "hw.gpu.enabled": "yes", "hw.gpu.mode": "host"]
        #expect(LiteAvd.overrides == spec)
        #expect(LiteAvd.launchFlags == ["-no-audio", "-no-boot-anim", "-no-metrics"])
        #expect(LiteAvd.name == "collie-lite")
    }

    @Test func installedImagesReadsTheTree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for p in ["android-37.0/google_apis/arm64-v8a", "android-35/google_apis_playstore/arm64-v8a", "android-35/default/x86_64"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("system-images/\(p)"), withIntermediateDirectories: true)
        }
        #expect(Set(LiteAvd.installedImages(sdkRoot: root)) == [img("android-37.0", "google_apis"), img("android-35", "google_apis_playstore")])
        #expect(LiteAvd.installedImages(sdkRoot: root.appendingPathComponent("none")).isEmpty)
    }
}
