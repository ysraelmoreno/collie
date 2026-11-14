import Testing
import Foundation
import CollieProtocol
@testable import CollieDaemonKit

/// `<tmp>/<rel>` as an executable script with `body`; returns `<tmp>`.
private func tmpScript(_ rel: String, _ body: String = "") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collie-avd-\(UUID().uuidString)")
    let f = dir.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\n\(body)\n".write(to: f, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
    return dir
}

@Suite struct AvdManagerTests {
    @Test func locatePrefersOverrideThenSdk() throws {
        let sdk = try tmpScript("cmdline-tools/latest/bin/avdmanager")
        let over = try tmpScript("bin/avdmanager")
        let java = try tmpScript("bin/java")
        let javaEnv = ["COLLIE_JAVA_HOME": java.path]
        let sdkEnv = javaEnv.merging(["ANDROID_HOME": sdk.path]) { $1 }
        #expect(AvdManager.locate(env: sdkEnv, home: "/nonexistent", javaCandidates: [])?.url.path
                == sdk.appendingPathComponent("cmdline-tools/latest/bin/avdmanager").path)
        let both = sdkEnv.merging(["COLLIE_AVDMANAGER": over.appendingPathComponent("bin/avdmanager").path]) { $1 }
        let found = AvdManager.locate(env: both, home: "/nonexistent", javaCandidates: [])
        #expect(found?.url.path == over.appendingPathComponent("bin/avdmanager").path)
        #expect(found?.javaHome == java.path)
        #expect(AvdManager.locate(env: javaEnv, home: "/nonexistent", javaCandidates: []) == nil)
    }

    @Test func locateReturnsNilWithoutJava() throws {
        let sdk = try tmpScript("cmdline-tools/latest/bin/avdmanager")
        #expect(AvdManager.locate(env: ["ANDROID_HOME": sdk.path], home: "/nonexistent", javaCandidates: []) == nil)
        let noJava = FileManager.default.temporaryDirectory.appendingPathComponent("collie-avd-nojava-\(UUID().uuidString)")
        #expect(AvdManager.locate(env: ["ANDROID_HOME": sdk.path], home: "/nonexistent", javaCandidates: [noJava.path]) == nil)
    }

    @Test func javaPrefersCollieOverStudio() throws {
        let sdk = try tmpScript("cmdline-tools/latest/bin/avdmanager")
        let collie = try tmpScript("bin/java"), studio = try tmpScript("bin/java")
        let env = ["ANDROID_HOME": sdk.path, "COLLIE_JAVA_HOME": collie.path]
        #expect(AvdManager.locate(env: env, home: "/nonexistent", javaCandidates: [studio.path])?.javaHome == collie.path)
        // an unusable COLLIE_JAVA_HOME falls through to the next candidate
        let bad = ["ANDROID_HOME": sdk.path, "COLLIE_JAVA_HOME": "/nonexistent"]
        #expect(AvdManager.locate(env: bad, home: "/nonexistent", javaCandidates: [studio.path])?.javaHome == studio.path)
    }

    @Test func runSetsJavaHomeAndGivesChildEofOnStdin() async throws {
        let sdk = try tmpScript("cmdline-tools/latest/bin/avdmanager", "read x; echo \"got:$x java:$JAVA_HOME\"")
        let java = try tmpScript("bin/java")
        let m = try #require(AvdManager.locate(env: ["ANDROID_HOME": sdk.path, "COLLIE_JAVA_HOME": java.path],
                                               home: "/nonexistent", javaCandidates: []))
        let r = try await m.run([], env: ["PATH": "/usr/bin:/bin"], timeout: .seconds(10))
        #expect(r.status == 0)
        #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "got: java:\(java.path)")
    }

    @Test func missingIsUnavailable() {
        #expect(AvdManager.missing.code == .unavailable)
        #expect(AvdManager.missing.message.contains("Android SDK Command-line Tools (latest)"))
    }
}
