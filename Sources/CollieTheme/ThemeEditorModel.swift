import Foundation

/// One line of the editor's list: a palette role with its color in use.
public struct ThemeEditorRow: Equatable {
    public let key: String
    public let name: String
    public let group: PaletteRole.Group
    public let color: RGB
    /// True when the role is in the file (even if equal to the inherited color).
    public let changed: Bool
    /// Contrast against the role's background; nil for roles that have no reading.
    public let ratio: Double?
    public let low: Bool
}

/// State behind the theme editor: the list and the JSON are two views of one theme. Pure, no disk, no clock.
public struct ThemeEditorModel {
    /// Last valid theme.
    public private(set) var theme: ThemeFile
    public private(set) var jsonText: String
    public private(set) var jsonError: String?
    private var saved: ThemeFile

    public init(theme: ThemeFile) {
        self.theme = theme
        saved = theme
        jsonText = String(decoding: theme.data, as: UTF8.self)
    }

    public var rows: [ThemeEditorRow] {
        let readings = Dictionary(uniqueKeysWithValues: theme.readings.map { ($0.role, $0) })
        let p = theme.palette
        return Palette.roles.map { r in
            let reading = readings[r.key]
            return ThemeEditorRow(key: r.key, name: r.name, group: r.group, color: p[keyPath: r.keyPath],
                                  changed: theme.colors[r.key] != nil, ratio: reading?.ratio,
                                  low: reading?.low ?? false)
        }
    }

    /// Palette of the last valid theme, for the preview.
    public var palette: Palette { theme.palette }

    /// The theme when it differs from the last one marked as saved; nil otherwise.
    public var pendingSave: ThemeFile? { theme == saved ? nil : theme }

    public mutating func markSaved() { saved = theme }

    public mutating func set(_ role: String, _ color: RGB) {
        guard Palette.roles.contains(where: { $0.key == role }) else { return }
        theme.colors[role] = color
        syncJSON()
    }

    public mutating func reset(_ role: String) {
        theme.colors[role] = nil
        syncJSON()
    }

    /// Refuses empty, over 48 characters or with control characters; nothing changes then.
    public mutating func rename(_ name: String) {
        guard (1...48).contains(name.count),
              !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return }
        theme.name = name
        syncJSON()
    }

    /// Always keeps the text; applies it only when it is a valid theme.
    public mutating func setJSON(_ text: String) {
        jsonText = text
        do {
            theme = try ThemeFile.parse(Data(text.utf8))
            jsonError = nil
        } catch {
            jsonError = "não aplicado: " + error.message
        }
    }

    private mutating func syncJSON() {
        jsonText = String(decoding: theme.data, as: UTF8.self)
        jsonError = nil
    }
}
