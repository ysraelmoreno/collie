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

    /// Prefers `cmdline-tools/latest`, else the highest numbered `cmdline-tools/<version>`.
    public static func sdkmanager(
        in sdk: String, exists: (String) -> Bool,
        list: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] }
    ) -> String? {
        let root = "\(sdk)/cmdline-tools"
        func bin(_ v: String) -> String { "\(root)/\(v)/bin/sdkmanager" }
        if exists(bin("latest")) { return bin("latest") }
        let names = list(root).filter { $0 != "latest" }
        let numeric = names.compactMap { v in Double(v).map { (v, $0) } }.sorted { $0.1 > $1.1 }.map(\.0)
        let rest = names.filter { Double($0) == nil }.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        return (numeric + rest).map(bin).first(where: exists)
    }

    /// `system-images;android-N;google_apis;arm64-v8a` rows of `sdkmanager --list` (first column), deduplicated.
    public static func parseImages(_ listOutput: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for line in listOutput.split(separator: "\n") {
            let id = line.split(separator: "|", omittingEmptySubsequences: false).first
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
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
        let last = line.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).last.map(String.init) ?? ""
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
