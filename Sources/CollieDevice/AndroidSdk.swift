import Foundation

/// Pure pieces of Android SDK setup: where the SDK is, and parsing `sdkmanager` output.
public enum AndroidSdk {
    static let markers = ["platform-tools", "emulator", "cmdline-tools", "system-images"]

    public static func looksLikeSdk(_ dir: String, exists: (String) -> Bool) -> Bool {
        markers.contains { exists("\(dir)/\($0)") }
    }

    /// Order: COLLIE_ANDROID_SDK, ANDROID_HOME, ANDROID_SDK_ROOT, Studio's default, then `colliePath`.
    /// COLLIE_ANDROID_SDK is an explicit override (tests and the E2E point it at an empty dir the install fills),
    /// so it wins whenever set, without the looks-like-an-SDK check.
    public static func resolve(env: [String: String], home: String, colliePath: String,
                               exists: (String) -> Bool) -> (path: String, source: String) {
        if let p = env["COLLIE_ANDROID_SDK"], !p.isEmpty { return (p, "env") }
        let candidates = [
            (env["ANDROID_HOME"], "android-home"),
            (env["ANDROID_SDK_ROOT"], "android-sdk-root"),
            ("\(home)/Library/Android/sdk", "studio"),
        ]
        for (p, source) in candidates {
            if let p, !p.isEmpty, looksLikeSdk(p, exists: exists) { return (p, source) }
        }
        return (colliePath, "collie")
    }

    /// Newest classic cmdline-tools revision: what Collie downloads, and the first choice to run. 21+ ships `sdkmanager`
    /// as a deprecated wrapper over the new `android` CLI, which writes the license acceptance by itself.
    public static let maxCmdlineTools = [20, 0]
    /// The one `android` CLI revision verified live (installs with `--sdk_root`, ignores `--licenses`, accepts on install).
    public static let androidCliTools = [23, 0]

    /// How a cmdline-tools `sdkmanager` behaves. `unknown(rev)` (21.x, 22.x, 23.1+, 24+): untested, the daemon probes it.
    public enum SdkManagerKind: Equatable, Sendable { case classic, androidCli, unknown(String) }

    /// major.minor of `Pkg.Revision=` in a cmdline-tools `source.properties` (`23.0` -> [23, 0]); nil when absent or not a number.
    public static func cmdlineToolsRevision(_ properties: String) -> [Int]? {
        guard let line = properties.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Pkg.Revision=") }) else { return nil }
        let parts = line.dropFirst("Pkg.Revision=".count).trimmingCharacters(in: .whitespaces).split(separator: ".")
            .prefix(2).map { Int($0.prefix { $0.isNumber }) }
        guard let major = parts.first ?? nil else { return nil }
        return [major, parts.count > 1 ? parts[1] ?? 0 : 0]
    }

    /// Each `cmdline-tools/<dir>` with its revision (dirs without a readable one left out).
    static func cmdlineTools(in sdk: String, list: (String) -> [String], read: (String) -> String?) -> [(dir: String, rev: [Int])] {
        let root = "\(sdk)/cmdline-tools"
        return Set(list(root) + ["latest"]).compactMap { v in read("\(root)/\(v)/source.properties").flatMap(cmdlineToolsRevision).map { (v, $0) } }
    }

    /// The `sdkmanager` to run and its kind. Only dirs with a `source.properties` revision count. First a classic
    /// (<= `maxCmdlineTools`), then `androidCliTools` (23.0, patch ignored), then any other revision; within each,
    /// `cmdline-tools/latest` wins, else the highest revision.
    public static func sdkmanagerTool(
        in sdk: String, exists: (String) -> Bool,
        list: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
        read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> (path: String, kind: SdkManagerKind)? {
        func bin(_ v: String) -> String { "\(sdk)/cmdline-tools/\(v)/bin/sdkmanager" }
        let usable = cmdlineTools(in: sdk, list: list, read: read).filter { exists(bin($0.dir)) }
        func kind(_ rev: [Int]) -> SdkManagerKind {
            !maxCmdlineTools.lexicographicallyPrecedes(rev) ? .classic : rev == androidCliTools ? .androidCli
                : .unknown(rev.map(String.init).joined(separator: "."))
        }
        func rank(_ k: SdkManagerKind) -> Int { switch k { case .classic: 0; case .androidCli: 1; case .unknown: 2 } }
        let found = usable.map { (dir: $0.dir, rev: $0.rev, kind: kind($0.rev)) }
        guard let top = found.map({ rank($0.kind) }).min() else { return nil }
        let group = found.filter { rank($0.kind) == top }
        guard let pick = group.first(where: { $0.dir == "latest" }) ?? group.max(by: { $0.rev.lexicographicallyPrecedes($1.rev) })
        else { return nil }
        return (bin(pick.dir), pick.kind)
    }

    /// `sdkmanagerTool`'s path.
    public static func sdkmanager(
        in sdk: String, exists: (String) -> Bool,
        list: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
        read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> String? {
        sdkmanagerTool(in: sdk, exists: exists, list: list, read: read)?.path
    }

    /// A classic `sdkmanager` (<= 20.0) failed for a Java older than 17: its script's check ("requires JDK 17 or
    /// later"), or the JVM's class-version error when that check is skipped. The android CLI (23.0) brings its own Java.
    public static func needsNewerJava(_ output: String) -> Bool {
        output.contains("requires JDK 17 or later") || output.contains("UnsupportedClassVersionError")
    }

    /// `system-images;android-N;google_apis;arm64-v8a` rows of `sdkmanager --list` (first column), deduplicated. Reads
    /// the classic table (`id | ver | desc`) and the android CLI's (`system-images/android-N/...   ver   desc`, slashes
    /// normalized to `;`, the form both install).
    public static func parseImages(_ listOutput: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in listOutput.split(separator: "\n") {
            let first = line.split(separator: "|", omittingEmptySubsequences: false).first?
                .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            let id = first.hasPrefix("system-images/") ? first.replacingOccurrences(of: "/", with: ";") : first
            let c = id.split(separator: ";").map(String.init)
            if c.count == 4, c[0] == "system-images", c[1].hasPrefix("android-"), c[2] == "google_apis",
               c[3] == "arm64-v8a", seen.insert(id).inserted { out.append(id) }
        }
        return out
    }

    /// Highest API whose level is numeric (`android-36`, `android-37.0`); `android-CinnamonBun` and the like are previews.
    public static func pickLatestStable(_ packages: [String]) -> String? {
        packages.compactMap { p -> (String, Double)? in
            let c = p.split(separator: ";")
            // leading number only: `android-34-ext10` counts as 34, `android-CinnamonBun` has none
            guard c.count > 1, c[1].hasPrefix("android-"),
                  let n = Double(String(c[1].dropFirst("android-".count).prefix { $0.isNumber || $0 == "." })) else { return nil }
            return (p, n)
        }.max { $0.1 < $1.1 }?.0
    }

    /// `[=====   ] 45% Downloading emulator...` -> (45, "Downloading emulator...")
    public static func parseProgress(_ line: String) -> (percent: Int, label: String)? {
        // sdkmanager redraws in place with \r and ANSI erase codes: only the last segment is current
        let last = line.split(whereSeparator: { $0.isNewline || $0 == "\r" }).last.map(String.init) ?? ""
        let line = last.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        guard line.contains("["), let pct = line.firstIndex(of: "%") else { return nil }
        let digits = line[..<pct].reversed().prefix { $0.isNumber }
        guard !digits.isEmpty, let n = Int(String(digits.reversed())), (0...100).contains(n) else { return nil }
        let label = line[line.index(after: pct)...].trimmingCharacters(in: .whitespaces)
        return (n, label)
    }

    /// Blocks `License <id>:`, a dashes line, the text, a dashes line, `Accept? (y/N):`. `id` is the name of the
    /// file sdkmanager writes in `<sdk>/licenses/`; `title` is the first text line.
    public static func parseLicenses(_ output: String) -> [(id: String, title: String, text: String)] {
        var out: [(id: String, title: String, text: String)] = []
        var id: String?
        var body: [String] = []
        func flush() {
            if let id {
                let lines = body.map { $0.trimmingCharacters(in: .whitespaces) }
                let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                out.append((id, lines.first { !$0.isEmpty } ?? id, text))
            }
            id = nil; body = []
        }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("License "), t.hasSuffix(":") {
                flush()
                id = String(t.dropFirst("License ".count).dropLast())
            } else if t.hasPrefix("Accept?") || (t.count >= 10 && t.allSatisfy { $0 == "-" }) {
                // the dashes right under the header open the text; only the ones after text (or Accept?) close it
                if t.hasPrefix("Accept?") || body.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { flush() }
            } else if id != nil { body.append(line) }
        }
        flush()
        return out
    }
}
