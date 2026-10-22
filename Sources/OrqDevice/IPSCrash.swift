import Foundation

/// Parses a simulator `.ips` crash report: line 1 is a JSON header, the rest is the JSON body.
public enum IPSCrash {
    public static func parse(_ ips: Data, udid: String) -> CrashEvent? {
        guard let nl = ips.firstIndex(of: 0x0A),
              let head = (try? JSONSerialization.jsonObject(with: ips[ips.startIndex..<nl])) as? [String: Any],
              head["bug_type"] as? String == "309",
              let body = (try? JSONSerialization.jsonObject(with: ips[(nl + 1)...])) as? [String: Any],
              (body["procPath"] as? String)?.contains("/Devices/\(udid)/") == true else { return nil }
        let name = body["procName"] as? String
        let pkg = (body["bundleInfo"] as? [String: Any])?["CFBundleIdentifier"] as? String ?? name
        var text = "\(pkg ?? "unknown") crashed"
        if let e = body["exception"] as? [String: Any] {
            text += ": " + [e["type"], e["signal"]].compactMap { $0 as? String }.joined(separator: " ")
        }
        if let t = (body["termination"] as? [String: Any])?["indicator"] as? String { text += " (\(t))" }
        return CrashEvent(package: pkg, text: String(text.prefix(4096)))
    }
}
