import Foundation

/// `X.Y.Z` with non-negative integers (a leading `v` is accepted); compared component by component.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ s: String) {
        let body = s.hasPrefix("v") ? String(s.dropFirst()) : s
        let comps = body.split(separator: ".", omittingEmptySubsequences: false)
        guard comps.count == 3 else { return nil }
        var parts: [Int] = []
        for c in comps {
            guard !c.isEmpty, c.allSatisfy(\.isASCII), c.allSatisfy(\.isNumber), let n = Int(c) else { return nil }
            parts.append(n)
        }
        self.parts = parts
    }

    public static func < (a: Self, b: Self) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
    public var description: String { parts.map(String.init).joined(separator: ".") }
}

/// `update.json`, the asset each `vX.Y.Z` release carries (spec 2026-11-17 §1). Decoded strictly: every field present,
/// coherent with the others; the dmg URL is derived from `tag` and `dmg`, never read from the manifest.
public struct UpdateManifest: Codable, Sendable, Equatable {
    public var format: Int
    public var version, tag, dmg: String
    public var size: Int64
    public var sha256, minimumSystemVersion, teamId, figcraftEngine, page: String
    public var requiresServiceRestart: Bool?

    public static let maxBytes = 65_536
    public static let maxSize: Int64 = 500_000_000
    static let releases = "https://github.com/ysraelmoreno/collie/releases"

    public struct Invalid: Error, CustomStringConvertible, Equatable {
        public let description: String
    }

    public static func decode(_ data: Data) throws -> UpdateManifest {
        guard data.count <= maxBytes else { throw Invalid(description: "manifest larger than \(maxBytes) bytes") }
        let m = try JSONDecoder().decode(UpdateManifest.self, from: data)
        if let why = m.problem { throw Invalid(description: why) }
        return m
    }

    /// Why this manifest is refused (nil: accepted).
    var problem: String? {
        guard format == 1 else { return "format \(format) unsupported" }
        guard let v = AppVersion(version), v.description == version else { return "version \(version) is not X.Y.Z" }
        guard tag == "v\(version)" else { return "tag \(tag) is not v\(version)" }
        guard dmg == "Collie-\(version).dmg" else { return "dmg \(dmg) is not Collie-\(version).dmg" }
        guard page == "\(Self.releases)/tag/\(tag)" else { return "page \(page) is not the release page" }
        guard size > 0, size <= Self.maxSize else { return "size \(size) out of range" }
        guard sha256.count == 64, sha256.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            return "sha256 is not 64 lowercase hex"
        }
        guard Self.system(minimumSystemVersion) != nil else { return "minimumSystemVersion \(minimumSystemVersion) unreadable" }
        return nil
    }

    public var dmgURL: URL { URL(string: "\(Self.releases)/download/\(tag)/\(dmg)")! }

    /// Offered when newer than `installed`, runnable on `system` and not the skipped version.
    public func offer(installed: String, system: OperatingSystemVersion, skipped: String?) -> Bool {
        guard let new = AppVersion(version), let old = AppVersion(installed), new > old, version != skipped,
              let min = Self.system(minimumSystemVersion) else { return false }
        return !([system.majorVersion, system.minorVersion, system.patchVersion].lexicographicallyPrecedes(min))
    }

    /// `15`, `15.0` or `15.0.1` as three integers.
    static func system(_ s: String) -> [Int]? {
        let comps = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(comps.count), comps.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        return comps.map { $0! } + Array(repeating: 0, count: 3 - comps.count)
    }
}
