import Foundation
import OrqProtocol

/// The iOS Simulator command lines: `xcrun simctl` (list, boot, screenshot, logs, install, launch) and AXe (input, UI tree).
/// Both get argv, never a shell.
struct Simulator: Sendable {
    static var defaultCrashReports: URL { URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/DiagnosticReports") }
    let xcrun: URL
    let axe: URL?

    static let missingAXe = ProtocolError(code: .unavailable,
        message: "AXe not found. Install it with brew install cameroncooke/axe/axe or set ORQ_AXE.")
    static let missingXcrun = ProtocolError(code: .unavailable,
        message: "xcrun simctl not available. Install Xcode and run xcode-select --switch.")

    /// First executable of `ORQ_AXE`, Homebrew: a launchd daemon has no useful PATH.
    static func locateAXe(env: [String: String]) -> URL? {
        ((env["ORQ_AXE"].map { [$0] } ?? []) + ["/opt/homebrew/bin/axe", "/usr/local/bin/axe"])
            .first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// `xcrun simctl args`. No xcrun, or no simctl (Command Line Tools only): `missingXcrun`.
    func simctl(_ args: [String], timeout: Duration, cap: Int = 1 << 20) async throws(ProtocolError) -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: xcrun.path) else { throw Self.missingXcrun }
        return try await Self.run(xcrun, ["simctl"] + args, "simctl \(args.first ?? "")", timeout, cap)
    }

    /// `axe args --udid U` (`--udid` goes before a `--`, after which everything is text).
    func axe(_ args: [String], udid: String, timeout: Duration, cap: Int = 1 << 20) async throws(ProtocolError) -> ProcessResult {
        guard let axe, FileManager.default.isExecutableFile(atPath: axe.path) else { throw Self.missingAXe }
        var a = args
        a.insert(contentsOf: ["--udid", udid], at: args.firstIndex(of: "--") ?? args.endIndex)
        return try await Self.run(axe, a, "axe \(args.first ?? "")", timeout, cap)
    }

    /// Non-zero exit: `.internal` with stderr cut to 500 chars.
    private static func run(_ exe: URL, _ args: [String], _ what: String, _ timeout: Duration, _ cap: Int) async throws(ProtocolError) -> ProcessResult {
        let r = try await BoundedProcess.run(executable: exe, args: args, in: URL(fileURLWithPath: "/"),
                                             env: ProcessInfo.processInfo.environment, timeout: timeout, cap: cap)
        guard r.status == 0 else {
            let msg = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if msg.contains("unable to find utility") { throw missingXcrun }   // xcrun without Xcode
            throw ProtocolError(code: .internal, message: "\(what) failed: \(msg.prefix(500))")
        }
        return r
    }
}
