import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// A fake `sdkmanager`: `--licenses` asks like the real one (one unaccepted license), sleeping first when `sleep` exists;
/// every call is appended to `calls`. Never touches anything outside its temp dir.
private let fakeSdkmanager = #"""
#!/bin/sh
d=$(dirname "$0")
echo "$*" >> "$d/calls"
case "$*" in *--licenses*)
  if [ -f "$d/sleep" ]; then sleep 5; fi
  printf '1 of 1 SDK package license not accepted.\nReview license that has not been accepted (y/N)? '
  read a; [ "$a" = y ] || exit 0
  printf '\n1/1: License android-sdk-license:\n---------------------------------------\nTerms and Conditions\n---------------------------------------\nAccept? (y/N): '
  read a; echo; exit 0;;
esac
"""#

private struct Fixture {
    let home: URL, sdk: URL, bin: URL
    var calls: [String] {
        ((try? String(contentsOf: bin.appendingPathComponent("calls"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    /// `prepared`: Java and cmdline-tools in place (else the SDK is empty and the job would download: the fetch fails).
    init(prepared: Bool) throws {
        let fm = FileManager.default
        home = fm.temporaryDirectory.appendingPathComponent("collie-andcmd-\(UUID().uuidString)")
        sdk = home.appendingPathComponent("sdk")
        bin = sdk.appendingPathComponent("cmdline-tools/latest/bin")
        try fm.createDirectory(at: sdk, withIntermediateDirectories: true)
        guard prepared else { return }
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fakeSdkmanager.write(to: bin.appendingPathComponent("sdkmanager"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("sdkmanager").path)
        try "Pkg.Revision=20.0\n".write(to: bin.deletingLastPathComponent().appendingPathComponent("source.properties"), atomically: true, encoding: .utf8)
        let java = home.appendingPathComponent("java/bin/java")
        try fm.createDirectory(at: java.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: java, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
    }
    var installer: AndroidInstaller {
        AndroidInstaller(root: home, env: ["COLLIE_ANDROID_SDK": sdk.path, "ANDROID_AVD_HOME": home.appendingPathComponent("avd").path,
                                           "COLLIE_JAVA_HOME": home.appendingPathComponent("java").path],
                         home: home.path, runDir: home.appendingPathComponent("run"),
                         fetch: { url, _, _ in throw ProtocolError(code: .notFound, message: "no network: \(url)") },
                         isAppleSilicon: true, javaCandidates: [], freeSpace: { _ in 1 << 40 }, othersRunning: { _ in nil })
    }
}

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "a", token: d.adminToken, command: cmd, args: args), timeoutSeconds: 30)
}

/// Polls `android.status` until the job leaves `prepare`/`install`.
private func ended(_ d: Daemon, _ p: Paths) async throws -> [String: JSONValue] {
    for _ in 0..<200 {
        if case .object(let o)? = try await admin(d, p, "android.status").result, case .object(let j)? = o["job"],
           case .string(let ph)? = j["phase"], !["prepare", "install"].contains(ph) { return j }
        try await Task.sleep(for: .milliseconds(50))
    }
    return [:]
}

@Suite struct AndroidCommandTests {
    private let names = ["android.status", "android.licenses", "android.install", "android.cancel"]

    @Test func commandsAreAdminOnly() async throws {
        let f = try Fixture(prepared: false)
        defer { try? FileManager.default.removeItem(at: f.home) }
        try await withDaemon(configure: { $0.androidInstaller = f.installer }) { d, p in
            let t = try await spawn(d, p, "W")
            let tok = try await tokenOf(d, t.id)
            for c in names {
                let asTerminal = try await send(p, Request(id: "t", terminalId: t.id, token: tok, command: c))
                #expect(asTerminal.error?.code == .unauthorized, "\(c)")
                let noToken = try await send(p, Request(id: "n", command: c))
                #expect(noToken.error?.code == .unauthorized, "\(c)")
            }
            #expect(try await admin(d, p, "android.status").ok)
        }
    }

    @Test func statusReturnsTheContract() async throws {
        let f = try Fixture(prepared: false)
        defer { try? FileManager.default.removeItem(at: f.home) }
        try await withDaemon(configure: { $0.androidInstaller = f.installer }) { d, p in
            let r = try await admin(d, p, "android.status")
            guard case .object(let o)? = r.result, case .object(let sdk)? = o["sdk"], case .array(let items)? = o["items"] else {
                Issue.record("shape: \(r)"); return
            }
            #expect(sdk["path"] == .string(f.sdk.path) && sdk["source"] == .string("env"))
            #expect(items.count == 5)
            guard case .object(let first) = items[0] else { return }
            #expect(Set(first.keys) == ["id", "state", "detail"])
            #expect(o["needs"] == .string("needsPrepare") && o["lite"] == .bool(false) && o["job"] == nil)
        }
    }

    @Test func installWithoutAcceptAcceptsNothing() async throws {
        let f = try Fixture(prepared: true)
        defer { try? FileManager.default.removeItem(at: f.home) }
        try await withDaemon(configure: { $0.androidInstaller = f.installer }) { d, p in
            let r = try await admin(d, p, "android.install")
            #expect(r.ok, "\(r)")
            guard case .object(let o)? = r.result, case .object(let job)? = o["job"] else { Issue.record("no job: \(r)"); return }
            #expect(job["phase"] == .string("prepare"))
            // nothing was accepted, no package asked: the job only read the licenses and stopped
            let end = try await ended(d, p)
            #expect(end["phase"] == .string("failed"))
            #expect(f.calls.allSatisfy { $0.contains("--licenses") })
            #expect(!FileManager.default.fileExists(atPath: f.sdk.appendingPathComponent("licenses").path))
        }
    }

    @Test func installBusyReturnsBusy() async throws {
        let f = try Fixture(prepared: true)
        defer { try? FileManager.default.removeItem(at: f.home) }
        try "".write(to: f.bin.appendingPathComponent("sleep"), atomically: true, encoding: .utf8)
        try await withDaemon(configure: { $0.androidInstaller = f.installer }) { d, p in
            #expect(try await admin(d, p, "android.install").ok)
            let second = try await admin(d, p, "android.install")
            #expect(second.error?.code == .conflict, "\(second)")
            #expect(try await admin(d, p, "android.cancel").ok)
            _ = try await ended(d, p)
        }
    }

    @Test func helpListsFourCommands() {
        let help = ArgvParser.help(["help", "android"]) ?? ""
        for c in ["status", "licenses", "install", "cancel"] { #expect(help.contains("collie android \(c)"), "\(c)") }
        #expect(!help.contains("--accept-all"))
    }

    @Test func acceptIsANamedFlag() throws {
        let (cmd, args) = try ArgvParser.parse(["android", "install", "--accept", "a", "--accept", "b"])
        #expect(cmd == "android.install" && args["accept"] == .string("a,b"))
        #expect(throws: ProtocolError.self) { try ArgvParser.parse(["android", "install", "--accept-all"]) }
    }

    @Test func commandsAreHiddenFromMCP() {
        for c in names { #expect(Commands.spec(c)?.exposedToMCP == false, "\(c)") }
        #expect(Commands.spec("android.licenses")?.timeoutSeconds == 300)
    }
}
