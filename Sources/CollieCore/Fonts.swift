import Foundation

/// A font family pages can use offline through `collie-lib://fonts`: bundled with the app (`vendor/fonts`), or downloaded
/// from Google Fonts by the daemon (`<root>/fonts/<family>/font.json` beside its files).
public struct FontFamily: Codable, Sendable, Equatable {
    public struct Face: Codable, Sendable, Equatable {
        /// `normal` | `italic`.
        public var style: String
        /// `400`, or a variable font's range `300 700`.
        public var weight: String
        /// A file in the family's folder (`Fonts.validFile`).
        public var file: String
        public var unicodeRange: String?
        public init(style: String, weight: String, file: String, unicodeRange: String? = nil) {
            self.style = style; self.weight = weight; self.file = file; self.unicodeRange = unicodeRange
        }
    }
    public var family: String
    public var faces: [Face]
    /// Where it came from (the css2 URL) and its licence's name: downloaded families only.
    public var source: String?
    public var licence: String?
    /// The TTFs for FigCraft were past their caps: `font.add` doesn't download them again (downloaded families only).
    public var ttfSkipped: Bool?
    public init(family: String, faces: [Face], source: String? = nil, licence: String? = nil) {
        self.family = family; self.faces = faces; self.source = source; self.licence = licence
    }
}

public enum Fonts {
    public static let metaFile = "font.json"
    /// The app's own faces (`scripts/fetch-fonts.sh`), all in one folder (Resources/Fonts; vendor/fonts in debug builds).
    public static let bundled: [FontFamily] = [
        FontFamily(family: "Space Grotesk", faces: [.init(style: "normal", weight: "300 700", file: "SpaceGrotesk[wght].ttf")], licence: "OFL-1.1"),
        FontFamily(family: "DM Mono", faces: [.init(style: "normal", weight: "400", file: "DMMono-Regular.ttf"),
                                              .init(style: "normal", weight: "500", file: "DMMono-Medium.ttf")], licence: "OFL-1.1"),
    ]
    /// The page templates' fonts when the design system names none.
    public static let defaultText = "Space Grotesk", defaultMono = "DM Mono"

    /// `[A-Za-z0-9 ]{1,64}`, not blank, no leading/trailing space: safe in a folder name, a URL and a CSS string.
    public static func validFamily(_ s: String) -> Bool {
        (1...64).contains(s.count) && s.trimmingCharacters(in: .whitespaces) == s
            && s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == " " }
    }
    /// A face file name: `[A-Za-z0-9._[]-]`, no leading dot, a font extension.
    public static func validFile(_ s: String) -> Bool {
        (1...128).contains(s.count) && !s.hasPrefix(".") && ["woff2", "ttf", "otf"].contains(URL(fileURLWithPath: s).pathExtension.lowercased())
            && s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "._[]-".unicodeScalars.contains($0) }
    }

    /// `collie-lib://fonts/<family>/<file>`.
    public static func fileURL(family: String, file: String) -> String {
        "\(WebLibs.scheme)://fonts/\(encode(family))/\(encode(file))"
    }
    /// `collie-lib://fonts/css?family=<Family>[:<w>,<w>]&…`: the `@font-face` rules of those families.
    public static func cssURL(_ families: [String]) -> String {
        "\(WebLibs.scheme)://fonts/css?" + families.map { "family=\(encode($0))" }.joined(separator: "&")
    }
    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._"))) ?? s
    }

    /// The `family` query items (`Inter:400,700`; `+` is a space): each valid family once, with its weights (nil: all).
    public static func requests(_ query: [URLQueryItem]) -> [(family: String, weights: [Int]?)] {
        var out: [(String, [Int]?)] = []
        for q in query where q.name == "family" {
            let v = (q.value ?? "").replacingOccurrences(of: "+", with: " ")
            let parts = v.split(separator: ":", maxSplits: 1).map(String.init)
            guard let f = parts.first, validFamily(f), !out.contains(where: { $0.0 == f }) else { continue }
            let ws = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Int($0) } : nil
            out.append((f, ws?.isEmpty == true ? nil : ws))
        }
        return out
    }

    /// `@font-face` rules for each family's faces (those with one of `weights`, when given; a range counts when it holds one).
    public static func css(_ families: [(family: FontFamily, weights: [Int]?)]) -> String {
        var out = ""
        for (f, weights) in families {
            for face in f.faces where validFile(face.file) {
                let range = face.weight.split(separator: " ").compactMap { Int($0) }
                guard let lo = range.first, range.count <= 2 else { continue }
                let hi = range.last ?? lo
                if let weights, !weights.contains(where: { (lo...max(lo, hi)).contains($0) }) { continue }
                let style = face.style == "italic" ? "italic" : "normal"
                let fmt = face.file.hasSuffix(".woff2") ? "woff2" : face.file.hasSuffix(".otf") ? "opentype" : "truetype"
                out += "@font-face {\n  font-family: \"\(f.family)\";\n  font-style: \(style);\n  font-weight: \(lo == hi ? "\(lo)" : "\(lo) \(hi)");\n"
                    + "  font-display: swap;\n  src: url(\"\(fileURL(family: f.family, file: face.file))\") format(\"\(fmt)\");\n"
                if let u = face.unicodeRange, u.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "Uu+0123456789abcdefABCDEF-?, ").contains($0) }) {
                    out += "  unicode-range: \(u);\n"
                }
                out += "}\n"
            }
        }
        return out
    }

    /// A downloaded family's `font.json` in `dir/<family>/`; nil when missing, unreadable or not that family.
    public static func downloaded(_ family: String, in dir: URL) -> FontFamily? {
        guard validFamily(family),
              let d = try? Data(contentsOf: dir.appendingPathComponent(family).appendingPathComponent(metaFile)),
              let f = try? JSONDecoder().decode(FontFamily.self, from: d), f.family == family else { return nil }
        return f
    }
}
