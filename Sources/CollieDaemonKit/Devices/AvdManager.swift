import Foundation
import CollieProtocol

/// The Android SDK `avdmanager` command line plus the JDK it needs (a launchd daemon has no useful PATH or JAVA_HOME).
struct AvdManager: Sendable {
    let url: URL
    let javaHome: String

    static let missing = ProtocolError(code: .unavailable,
        message: "avdmanager (or a Java runtime) not found. In Android Studio open SDK Manager → SDK Tools and install "
               + "\"Android SDK Command-line Tools (latest)\", or set COLLIE_AVDMANAGER and COLLIE_JAVA_HOME.")

    private static let studioJbr = "/Applications/Android Studio.app/Contents/jbr/Contents/Home"

    /// `avdmanager`: `COLLIE_AVDMANAGER`, the SDK dirs, the default macOS SDK. Java home: `COLLIE_JAVA_HOME`, then
    /// `javaCandidates` (default: Android Studio's bundled JBR, then `/usr/libexec/java_home`'s answer); the first dir
    /// holding an executable `bin/java` wins. `nil` when either is missing.
    static func locate(env: [String: String], home: String, javaCandidates: [String]? = nil) -> AvdManager? {
        let fm = FileManager.default
        let sdk = ["ANDROID_HOME", "ANDROID_SDK_ROOT"].compactMap { env[$0] }.map { "\($0)/cmdline-tools/latest/bin/avdmanager" }
        let tools = (env["COLLIE_AVDMANAGER"].map { [$0] } ?? []) + sdk + ["\(home)/Library/Android/sdk/cmdline-tools/latest/bin/avdmanager"]
        guard let tool = tools.first(where: { fm.isExecutableFile(atPath: $0) }) else { return nil }
        let javas = (env["COLLIE_JAVA_HOME"].map { [$0] } ?? []) + (javaCandidates ?? defaultJavaCandidates())
        guard let java = javas.first(where: { fm.isExecutableFile(atPath: "\($0)/bin/java") }) else { return nil }
        return AvdManager(url: URL(fileURLWithPath: tool), javaHome: java)
    }

    /// Studio's JBR, then whatever `/usr/libexec/java_home` prints (empty when no JDK is installed).
    private static func defaultJavaCandidates() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        let out = Pipe()
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        var found = ""
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 { found = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return [studioJbr] + (found.isEmpty ? [] : [found])
    }

    /// Runs `avdmanager` with `JAVA_HOME` set. stdin is `/dev/null` (`BoundedProcess` always opens it so), so the
    /// hardware-profile question gets EOF and takes its default `no`; output is capped at 1 MiB.
    func run(_ args: [String], env: [String: String], timeout: Duration) async throws(ProtocolError) -> ProcessResult {
        var env = env
        env["JAVA_HOME"] = javaHome
        return try await BoundedProcess.run(executable: url, args: args, in: URL(fileURLWithPath: "/"),
                                            env: env, timeout: timeout, cap: 1 << 20)
    }
}
