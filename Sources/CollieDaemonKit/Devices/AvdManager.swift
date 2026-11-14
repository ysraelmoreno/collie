import Foundation
import CollieDevice
import CollieProtocol

/// The Android SDK `avdmanager` command line plus the JDK it needs (a launchd daemon has no useful PATH or JAVA_HOME).
struct AvdManager: Sendable {
    let url: URL
    let javaHome: String

    static let missing = ProtocolError(code: .unavailable,
        message: "avdmanager (or a Java runtime) not found. In Android Studio open SDK Manager → SDK Tools and install "
               + "\"Android SDK Command-line Tools (latest)\", or set COLLIE_AVDMANAGER and COLLIE_JAVA_HOME.")

    private static let studioJbr = "/Applications/Android Studio.app/Contents/jbr/Contents/Home"

    /// Collie's own JDK (downloaded Temurin, extracted with `--strip-components=1`, so `Contents/Home` is its java home).
    static func collieJdk(_ home: String) -> String { "\(home)/Library/Application Support/Collie/jdk/Contents/Home" }

    /// `avdmanager`: `COLLIE_AVDMANAGER`, then the resolved SDK (reused or Collie's). Java home: `COLLIE_JAVA_HOME`, then
    /// `javaCandidates` (default: Android Studio's bundled JBR), then, only if that fails, `/usr/libexec/java_home -v 17+`'s answer, then Collie's JDK; the first dir
    /// holding an executable `bin/java` wins. `nil` when either is missing.
    static func locate(env: [String: String], home: String, javaCandidates: [String]? = nil) -> AvdManager? {
        let fm = FileManager.default
        // avdmanager sits next to sdkmanager: reuse its version order (latest, numbered) by asking for sdkmanager paths
        // and checking the avdmanager beside each.
        func beside(_ p: String) -> String { (p as NSString).deletingLastPathComponent + "/avdmanager" }
        let sdk = AndroidSdk.sdkmanager(in: AndroidSdk.root(env: env, home: home), exists: { fm.isExecutableFile(atPath: beside($0)) })
            .map { [beside($0)] } ?? []
        let tools = (env["COLLIE_AVDMANAGER"].map { [$0] } ?? []) + sdk
        guard let tool = tools.first(where: { fm.isExecutableFile(atPath: $0) }) else { return nil }
        let hasJava = { (d: String) in fm.isExecutableFile(atPath: "\(d)/bin/java") }
        let early = (env["COLLIE_JAVA_HOME"].map { [$0] } ?? []) + (javaCandidates ?? [studioJbr])
        // java_home is spawned only when nothing earlier works (and never when candidates are injected).
        let viaJavaHome = { javaCandidates == nil ? javaHomeOutput().flatMap { hasJava($0) ? $0 : nil } : nil }
        guard let java = early.first(where: hasJava) ?? viaJavaHome() ?? (hasJava(collieJdk(home)) ? collieJdk(home) : nil) else { return nil }
        return AvdManager(url: URL(fileURLWithPath: tool), javaHome: java)
    }

    /// What `/usr/libexec/java_home -v 17+` prints, `nil` when no JDK 17+ is installed (nonzero exit).
    private static func javaHomeOutput() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        let out = Pipe()
        p.arguments = ["-v", "17+"]
        p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        var found = ""
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 { found = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return found.isEmpty ? nil : found
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
