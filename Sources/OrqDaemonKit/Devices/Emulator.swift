import Foundation
import OrqDevice
import OrqProtocol

/// The Android SDK `emulator` command line. Read-only: never writes to the SDK or `~/.android`.
struct Emulator: Sendable {
    let url: URL

    static let missing = ProtocolError(code: .unavailable,
        message: "Android emulator not found. Install it with Android Studio (SDK Manager → Android Emulator) or set ORQ_EMULATOR.")

    /// First executable of `ORQ_EMULATOR`, the SDK dirs, the default macOS SDK: a launchd daemon has no useful PATH.
    static func locate(env: [String: String], home: String) -> URL? {
        let sdk = ["ANDROID_HOME", "ANDROID_SDK_ROOT"].compactMap { env[$0] }.map { "\($0)/emulator/emulator" }
        let candidates = (env["ORQ_EMULATOR"].map { [$0] } ?? []) + sdk + ["\(home)/Library/Android/sdk/emulator/emulator"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// AVD names from `emulator -list-avds` (short, exits on its own), run with `env` (the daemon's minus `ORQ_*`, as `launch`).
    func listAvds(timeout: Duration, env: [String: String]) async throws(ProtocolError) -> [String] {
        let r = try await BoundedProcess.run(executable: url, args: ["-list-avds"], in: URL(fileURLWithPath: "/"),
                                             env: env, timeout: timeout, cap: 1 << 20)
        guard r.status == 0 else {
            let msg = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProtocolError(code: .internal, message: "emulator -list-avds failed: \(msg.prefix(500))")
        }
        return AdbParsing.avds(r.stdout)
    }

    /// `emulator -avd <avd>` in its own session (setsid), so no timeout, group kill, daemon stop or launchd ending the
    /// job takes it along; stdin `/dev/null`, stdout+stderr into `log` (truncated), cwd `/`, no other fd inherited.
    /// `env` plus `ANDROID_SDK_ROOT = sdkRoot`. Returns its pid; it is reaped when it exits, never stopped by us.
    func launch(avd: String, log: URL, sdkRoot: URL, env: [String: String]) async throws(ProtocolError) -> Int32 {
        var env = env
        env["ANDROID_SDK_ROOT"] = sdkRoot.path
        let path = url.path, logPath = log.path, environment = env
        let r: Result<Int32, ProtocolError> = await withCheckedContinuation { c in
            DispatchQueue.global().async {
                var attr: posix_spawnattr_t?, acts: posix_spawn_file_actions_t?
                posix_spawnattr_init(&attr); posix_spawn_file_actions_init(&acts)
                defer { posix_spawnattr_destroy(&attr); posix_spawn_file_actions_destroy(&acts) }
                var defaults = sigset_t(), empty = sigset_t()
                sigfillset(&defaults); sigemptyset(&empty)
                posix_spawnattr_setsigdefault(&attr, &defaults); posix_spawnattr_setsigmask(&attr, &empty)
                posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                      | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
                posix_spawn_file_actions_addopen(&acts, 0, "/dev/null", O_RDONLY, 0)
                posix_spawn_file_actions_addopen(&acts, 1, logPath, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0o600)
                posix_spawn_file_actions_adddup2(&acts, 1, 2)
                posix_spawn_file_actions_addchdir_np(&acts, "/")
                let args: [String] = [path, "-avd", avd]
                let argv = args.map { strdup($0) } + [nil]
                let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
                defer { (argv + envp).forEach { free($0) } }
                var pid: pid_t = 0
                let rc = posix_spawn(&pid, path, &acts, &attr, argv, envp)
                guard rc == 0 else {
                    c.resume(returning: .failure(ProtocolError(code: .internal, message: "cannot run emulator: \(String(cString: strerror(rc)))"))); return
                }
                Self.reapWhenDone(pid)
                c.resume(returning: .success(pid))
            }
        }
        return try r.get()
    }

    /// Reaps `pid` when it exits (a zombie would still answer `kill(pid, 0)`), however fast that is.
    // ponytail: one parked global-queue thread per emulator Orq launched; a kqueue source if that ever adds up
    private static func reapWhenDone(_ pid: pid_t) {
        DispatchQueue.global().async { var st: Int32 = 0; while waitpid(pid, &st, 0) == -1 && errno == EINTR {} }
    }
}
