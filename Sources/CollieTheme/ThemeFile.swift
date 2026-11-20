import Foundation

/// Why a theme file is broken. `message` is one line in Portuguese, shown to the owner.
public enum ThemeError: Error, Equatable {
    case tooLarge
    case invalidJSON
    case missing(String)
    case badName
    case badExtends
    case badColors
    case unknownRole(String)
    case badColor(String)

    public var message: String {
        switch self {
        case .tooLarge: "arquivo grande demais"
        case .invalidJSON: "JSON inválido"
        case .missing(let k): "falta \"\(k)\""
        case .badName: "\"name\": use de 1 a 48 caracteres, sem controle"
        case .badExtends: "\"extends\": use \"dark\" ou \"light\""
        case .badColors: "\"colors\": use um objeto"
        case .unknownRole(let k): "papel desconhecido: \"\(k)\""
        case .badColor(let k): "\"\(k)\": use #RRGGBB"
        }
    }
}

/// A custom theme file: name, built-in base and color overrides. Pure, no disk.
public struct ThemeFile: Sendable, Equatable {
    public enum Base: String, Sendable { case dark, light }

    public static let maxBytes = 64 * 1024

    public var name: String
    public var extends: Base
    public var colors: [String: RGB]

    public init(name: String, extends: Base, colors: [String: RGB] = [:]) {
        self.name = name
        self.extends = extends
        self.colors = colors
    }

    public static func parse(_ data: Data) throws(ThemeError) -> ThemeFile {
        guard data.count <= maxBytes else { throw .tooLarge }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch { throw .invalidJSON }
        guard let top = object as? [String: Any] else { throw .invalidJSON }

        guard let rawName = top["name"] else { throw .missing("name") }
        guard let name = rawName as? String, (1...48).contains(name.count),
              !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { throw .badName }

        guard let rawBase = top["extends"] else { throw .missing("extends") }
        guard let base = (rawBase as? String).flatMap(Base.init(rawValue:)) else { throw .badExtends }

        var colors: [String: RGB] = [:]
        if let rawColors = top["colors"] {
            guard let dict = rawColors as? [String: Any] else { throw .badColors }
            let known = Set(Palette.roles.map(\.key))
            for key in dict.keys.sorted() { // sorted: the first error is deterministic
                guard known.contains(key) else { throw .unknownRole(key) }
                guard let rgb = (dict[key] as? String).flatMap(RGB.init(hexString:)) else { throw .badColor(key) }
                colors[key] = rgb
            }
        }
        return ThemeFile(name: name, extends: base, colors: colors)
    }

    /// The built-in palette of `extends` with this file's colors on top.
    public var palette: Palette {
        (extends == .dark ? Palette.dark : Palette.light).replacing(colors)
    }

    /// JSON, 2 spaces, keys `name`, `extends`, `colors` (role-table order), trailing newline.
    public var data: Data {
        func quoted(_ s: String) -> String {
            let e = JSONEncoder()
            e.outputFormatting = .withoutEscapingSlashes
            return (try? e.encode(s)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        }
        let lines = Palette.roles.compactMap { r in
            colors[r.key].map { "    \"\(r.key)\": \"\($0.hexString)\"" }
        }
        let body = lines.isEmpty ? "  \"colors\": {}" : "  \"colors\": {\n" + lines.joined(separator: ",\n") + "\n  }"
        let text = "{\n  \"name\": \(quoted(name)),\n  \"extends\": \"\(extends.rawValue)\",\n\(body)\n}\n"
        return Data(text.utf8)
    }

    /// Contrast of every role that has a reading; `low` is below WCAG AA (4.5).
    public var readings: [(role: String, ratio: Double, low: Bool)] {
        let p = palette
        return Palette.roles.compactMap { r in
            guard let against = r.readsAgainst, let fg = p[role: r.key], let bg = p[role: against] else { return nil }
            let ratio = contrastRatio(fg, bg)
            return (r.key, ratio, ratio < 4.5)
        }
    }

    /// `[a-z0-9][a-z0-9-]{0,47}`
    public static func validId(_ id: String) -> Bool {
        let u = Array(id.utf8)
        guard (1...48).contains(u.count) else { return false }
        func lowerDigit(_ c: UInt8) -> Bool { (97...122).contains(c) || (48...57).contains(c) }
        return lowerDigit(u[0]) && u.dropFirst().allSatisfy { lowerDigit($0) || $0 == UInt8(ascii: "-") }
    }
}
