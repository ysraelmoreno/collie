import Foundation
import CollieProtocol

/// The mitmproxy `mitmdump` command line: the network panel's proxy. Not bundled: the user installs mitmproxy.
struct MitmTool: Sendable {
    let url: URL

    static let missing = ProtocolError(code: .unavailable,
        message: "mitmdump not found. Install mitmproxy (brew install --cask mitmproxy) or set COLLIE_MITMDUMP.")

    /// First executable of `COLLIE_MITMDUMP`, Homebrew on Apple silicon, Homebrew on Intel: a launchd daemon has no useful PATH.
    static func locate(env: [String: String], candidates: [String] = ["/opt/homebrew/bin/mitmdump", "/usr/local/bin/mitmdump"]) -> URL? {
        ((env["COLLIE_MITMDUMP"].map { [$0] } ?? []) + candidates)
            .first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// `mitmdump --version`, e.g. "12.3.1".
    func version(timeout: Duration = .seconds(15)) async throws(ProtocolError) -> String {
        let r = try await BoundedProcess.run(executable: url, args: ["--version"], in: URL(fileURLWithPath: "/"),
                                             env: ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("COLLIE_") }, timeout: timeout)
        guard r.status == 0, let v = Self.parseVersion(r.stdout) else {
            throw ProtocolError(code: .internal, message: "mitmdump --version failed: \((r.stderr.isEmpty ? r.stdout : r.stderr).prefix(500))")
        }
        return v
    }

    /// The version from `--version` output: its first line is `Mitmproxy: 12.3.1 binary` (or without " binary").
    static func parseVersion(_ out: String) -> String? {
        for line in out.split(whereSeparator: \.isNewline) where line.hasPrefix("Mitmproxy:") {
            return line.dropFirst("Mitmproxy:".count).split(separator: " ").first.map(String.init)
        }
        return nil
    }
}
