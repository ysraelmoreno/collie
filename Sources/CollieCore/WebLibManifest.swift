import Foundation

/// One offline web library in `weblibs/manifest.json` (written by `scripts/fetch-weblibs.sh`).
public struct WebLibEntry: Codable, Sendable, Equatable {
    public let name: String
    public let version: String
    public let files: [String]
    public let licence: String
    public let global: String
    public init(name: String, version: String, files: [String], licence: String, global: String) {
        self.name = name; self.version = version; self.files = files; self.licence = licence; self.global = global
    }
}

/// The offline web libraries served as `collie-lib://lib/<name>@<version>/<file>` (app: `WebLibSchemeHandler`;
/// daemon: `artifact.libs`).
public enum WebLibs {
    public static let scheme = "collie-lib"

    /// The manifest's entries; `[]` when the dir or its manifest is missing or unreadable.
    public static func manifest(in dir: URL) -> [WebLibEntry] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")) else { return [] }
        return (try? JSONDecoder().decode([WebLibEntry].self, from: d)) ?? []
    }

    /// The library's first file URL, or nil when it isn't in `entries`.
    public static func url(_ name: String, in entries: [WebLibEntry]) -> String? {
        guard let e = entries.first(where: { $0.name == name }), let f = e.files.first else { return nil }
        return "\(scheme)://lib/\(e.name)@\(e.version)/\(f)"
    }
}
