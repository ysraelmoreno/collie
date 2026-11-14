import Foundation

/// Pure pieces of the lightweight AVD ("collie-lite"): spec values, image choice, config.ini merge.
public enum LiteAvd {
    public static let name = "collie-lite"

    public static let overrides: [String: String] = [
        "hw.lcd.width": "720", "hw.lcd.height": "1280", "hw.lcd.density": "320",
        "hw.ramSize": "1536", "hw.cpu.ncore": "2", "disk.dataPartition.size": "2G",
        "hw.camera.back": "none", "hw.camera.front": "none",
        "hw.audioInput": "no", "hw.audioOutput": "no",
        "hw.sensors.orientation": "no", "hw.sensors.proximity": "no", "hw.sensors.humidity": "no",
        "hw.sensors.pressure": "no", "hw.sensors.magnetic_field": "no", "hw.sensors.temperature": "no",
        "showDeviceFrame": "no",
        // avdmanager writes hw.gpu.enabled=no: the guest then renders in software (measured 385% CPU under swipes vs 36% on the host GPU)
        "hw.gpu.enabled": "yes", "hw.gpu.mode": "host",
    ]

    public static let launchFlags = ["-no-audio", "-no-boot-anim", "-no-metrics"]

    /// Packages look like `system-images;android-37.0;google_apis;arm64-v8a`.
    public static func pickImage(_ packages: [String]) -> String? {
        func parts(_ p: String) -> (api: Double, tag: String)? {
            let c = p.split(separator: ";").map(String.init)
            guard c.count == 4, c[0] == "system-images", c[3] == "arm64-v8a" else { return nil }
            return (Double(c[1].replacingOccurrences(of: "android-", with: "")) ?? -1, c[2])
        }
        let cands = packages.compactMap { p in parts(p).map { (p, $0.api, $0.tag) } }
        let best = { (tagOK: (String) -> Bool) in
            cands.filter { tagOK($0.2) }.max { $0.1 < $1.1 }?.0
        }
        return best { $0 == "google_apis" } ?? best { $0.hasPrefix("google_apis_playstore") }
    }

    /// Replaces override keys (any `key = v` / `key=v` spacing, once) and appends the missing ones.
    public static func mergeConfig(_ existing: String, _ overrides: [String: String]) -> String {
        var seen = Set<String>()
        var out: [String] = []
        for line in existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let key = line.split(separator: "=", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
            if let key, let v = overrides[key] {
                if seen.insert(key).inserted { out.append("\(key)=\(v)") }
            } else { out.append(line) }
        }
        while out.last == "" { out.removeLast() }
        for k in overrides.keys.sorted() where !seen.contains(k) { out.append("\(k)=\(overrides[k]!)") }
        return out.joined(separator: "\n") + "\n"
    }

    /// `system-images;<api>;<tag>;arm64-v8a` packages present under `<sdkRoot>/system-images`.
    public static func installedImages(sdkRoot: URL) -> [String] {
        let fm = FileManager.default
        func dirs(_ u: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).sorted() }
        let root = sdkRoot.appendingPathComponent("system-images")
        var out: [String] = []
        for api in dirs(root) { for tag in dirs(root.appendingPathComponent(api)) {
            if fm.fileExists(atPath: root.appendingPathComponent("\(api)/\(tag)/arm64-v8a").path) {
                out.append("system-images;\(api);\(tag);arm64-v8a")
            }
        } }
        return out
    }
}
