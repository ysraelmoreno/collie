import Foundation
import OrqProtocol

/// The adb command line. Reuses the running adb server; never kills it (`kill-server` is never sent).
struct Adb: Sendable {
    let url: URL

    static let missing = ProtocolError(code: .unavailable,
        message: "adb not found. Install Android platform-tools (brew install --cask android-platform-tools) or set ORQ_ADB.")

    /// First executable of `ORQ_ADB`, the SDK dirs, Homebrew: a launchd daemon has no useful PATH.
    static func locate(env: [String: String], home: String) -> URL? {
        let sdk = ["ANDROID_HOME", "ANDROID_SDK_ROOT"].compactMap { env[$0] }.map { "\($0)/platform-tools/adb" }
        let candidates = (env["ORQ_ADB"].map { [$0] } ?? []) + sdk
            + ["\(home)/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// `adb start-server` as a plain child outside our process groups, stdio on `/dev/null`, waited up to 10 s off the
    /// cooperative pool. True when it exited 0.
    /// ponytail: why it exists: an adb client that finds no server forks one that inherits its process group and pipes.
    /// Started from a `BoundedProcess`/`LongProcess` group, our timeout or `terminate()` group kill would take down the
    /// shared 5037 server (other tools' sessions too) and the drain would wait on its pipes until the timeout.
    func startServer() async -> Bool {
        let url = url
        return await withCheckedContinuation { c in
            DispatchQueue.global().async {
                let p = Process(), done = DispatchSemaphore(value: 0)
                p.executableURL = url; p.arguments = ["start-server"]
                p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                p.terminationHandler = { _ in done.signal() }
                do { try p.run() } catch { c.resume(returning: false); return }
                guard done.wait(timeout: .now() + 10) == .success else { p.terminate(); c.resume(returning: false); return }
                c.resume(returning: p.terminationReason == .exit && p.terminationStatus == 0)
            }
        }
    }

    /// `adb [-s serial] args`. Non-zero exit: `.internal` with stderr cut to 500 chars. `exec-out` (PNG, files) gets 32 MiB.
    func run(_ args: [String], serial: String?, timeout: Duration, cap: Int = 1 << 20) async throws(ProtocolError) -> ProcessResult {
        let r = try await BoundedProcess.run(executable: url, args: (serial.map { ["-s", $0] } ?? []) + args,
                                             in: URL(fileURLWithPath: "/"), env: ProcessInfo.processInfo.environment,
                                             timeout: timeout, cap: args.first == "exec-out" ? 32 << 20 : cap)
        guard r.status == 0 else {
            let msg = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProtocolError(code: .internal, message: "adb \(args.first ?? "") failed: \(msg.prefix(500))")
        }
        return r
    }
}
