import Foundation

public struct SimDevice: Equatable, Sendable, Codable {
    public var udid: String; public var name: String; public var state: String; public var runtime: String
    public init(udid: String, name: String, state: String, runtime: String) {
        self.udid = udid; self.name = name; self.state = state; self.runtime = runtime
    }
}

/// Parses `xcrun simctl list devices -j`.
public enum SimCtl {
    /// Available iOS devices only; `state` is simctl's, lowercased; runtime "…SimRuntime.iOS-26-3" becomes "iOS 26.3".
    public static func devices(_ json: Data) -> [SimDevice] {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let groups = root["devices"] as? [String: [[String: Any]]] else { return [] }
        var out: [SimDevice] = []
        for (key, list) in groups {
            let rt = runtime(key)
            guard rt.hasPrefix("iOS") else { continue }   // watchOS/tvOS/visionOS sims are not AXe targets
            for d in list where d["isAvailable"] as? Bool == true {
                guard let udid = d["udid"] as? String, let name = d["name"] as? String else { continue }
                out.append(SimDevice(udid: udid, name: name, state: (d["state"] as? String ?? "").lowercased(), runtime: rt))
            }
        }
        // ponytail: JSON dictionaries are unordered; sort so callers get a stable list.
        return out.sorted { ($0.runtime, $0.name, $0.udid) < ($1.runtime, $1.name, $1.udid) }
    }

    private static func runtime(_ key: String) -> String {
        let id = key.split(separator: ".").last.map(String.init) ?? key   // "iOS-26-3"
        let p = id.split(separator: "-").map(String.init)
        guard p.count > 1 else { return id }
        return p[0] + " " + p.dropFirst().joined(separator: ".")
    }
}
