import Testing
import Foundation
import CollieDevice
import CollieProtocol
@testable import CollieDaemonKit

/// Temp ANDROID_AVD_HOME, SDK root with an image, fake avdmanager (logs args; `create` writes config.ini) and fake Java.
private struct Lite {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lite-\(UUID().uuidString.prefix(8))")
    var avdHome: URL { dir.appendingPathComponent("avd") }
    var sdk: URL { dir.appendingPathComponent("sdk") }
    var log: URL { dir.appendingPathComponent("args.log") }
    var config: URL { avdHome.appendingPathComponent("collie-lite.avd/config.ini") }

    init(image: Bool = true) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: avdHome, withIntermediateDirectories: true)
        try fm.createDirectory(at: sdk.appendingPathComponent("emulator"), withIntermediateDirectories: true)
        if image { try fm.createDirectory(at: sdk.appendingPathComponent("system-images/android-37.0/google_apis/arm64-v8a"), withIntermediateDirectories: true) }
        try fm.createDirectory(at: dir.appendingPathComponent("jdk/bin"), withIntermediateDirectories: true)
        try script("jdk/bin/java", "exit 0")
        try script("avdmanager", """
        echo "$@" >> '\(log.path)'
        if [ "$1" = create ]; then mkdir -p "$ANDROID_AVD_HOME/collie-lite.avd"; printf 'hw.ramSize=2048\\nimage.sysdir.1=x\\n' > "$ANDROID_AVD_HOME/collie-lite.avd/config.ini"; fi
        if [ "$1" = delete ]; then rm -rf "$ANDROID_AVD_HOME/collie-lite.avd"; fi
        """)
    }
    func script(_ name: String, _ body: String) throws {
        let u = dir.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
    }
    func service(manager: Bool = true) -> DeviceService {
        let mgr = AvdManager(url: dir.appendingPathComponent("avdmanager"), javaHome: dir.appendingPathComponent("jdk").path)
        let emu = sdk.appendingPathComponent("emulator/emulator")
        return DeviceService(root: dir, runDir: dir, adb: { nil }, emulator: { emu },
                             emulatorEnv: ["ANDROID_AVD_HOME": avdHome.path], avdManager: { manager ? mgr : nil }) { _, _, _ in }
    }
    func calls() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

@Suite struct LiteAvdServiceTests {
    @Test func createRunsAvdmanagerWithTheChosenImage() async throws {
        let fx = try Lite(); defer { fx.cleanup() }
        let r = try await fx.service().createLiteAvd()
        #expect(fx.calls() == ["create avd -n collie-lite -k system-images;android-37.0;google_apis;arm64-v8a -d pixel --force"])
        #expect(r["created"] == "true" && r["name"] == "collie-lite" && r["path"] == fx.config.deletingLastPathComponent().path)
        #expect(r["image"] == "system-images;android-37.0;google_apis;arm64-v8a")
    }

    @Test func createMergesTheOverrides() async throws {
        let fx = try Lite(); defer { fx.cleanup() }
        _ = try await fx.service().createLiteAvd()
        let text = try String(contentsOf: fx.config, encoding: .utf8)
        #expect(text.contains("hw.ramSize=1536") && !text.contains("hw.ramSize=2048") && text.contains("image.sysdir.1=x"))
    }

    @Test func createTwiceDoesNotRecreate() async throws {
        let fx = try Lite(); defer { fx.cleanup() }
        let svc = fx.service()
        _ = try await svc.createLiteAvd()
        try "hw.ramSize=4096\n".write(to: fx.config, atomically: true, encoding: .utf8)
        let r = try await svc.createLiteAvd()
        #expect(r["created"] == "false" && fx.calls().count == 1)
        #expect(try String(contentsOf: fx.config, encoding: .utf8).contains("hw.ramSize=1536"))
    }

    @Test func noImageFailsNamingThePackage() async throws {
        let fx = try Lite(image: false); defer { fx.cleanup() }
        do { _ = try await fx.service().createLiteAvd(); Issue.record("should throw") } catch {
            #expect(error.message.contains("system-images;android-") && error.message.contains("google_apis;arm64-v8a"))
        }
        #expect(fx.calls().isEmpty)
    }

    @Test func noAvdmanagerFailsUnavailable() async throws {
        let fx = try Lite(); defer { fx.cleanup() }
        do { _ = try await fx.service(manager: false).createLiteAvd(); Issue.record("should throw") } catch {
            #expect(error.code == .unavailable)
        }
    }

    @Test func removeRunsDelete() async throws {
        let fx = try Lite(); defer { fx.cleanup() }
        let svc = fx.service()
        try await svc.removeLiteAvd()
        #expect(fx.calls().isEmpty)   // nothing to delete
        _ = try await svc.createLiteAvd()
        try await svc.removeLiteAvd()
        #expect(fx.calls().last == "delete avd -n collie-lite")
        #expect(!FileManager.default.fileExists(atPath: fx.config.path))
    }
}
