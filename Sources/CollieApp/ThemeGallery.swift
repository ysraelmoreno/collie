import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CollieTheme

/// One card of the gallery: a built-in theme, a valid file of the user's, or a broken file.
struct ThemeCard: Identifiable, Equatable {
    enum Kind: Equatable { case builtin(ThemeSelection), custom(String), broken(String) }
    let kind: Kind
    let name: String
    /// "do Collie", the file name, or (broken) the reason in one line.
    let subtitle: String
    /// Colors of the thumbnail; nil for Sistema (follows the macOS appearance) and for broken files.
    let palette: Palette?

    var id: String {
        switch kind {
        case .builtin(let s): "builtin:\(s.rawValue)"
        case .custom(let id): "custom:\(id)"
        case .broken(let id): "broken:\(id)"
        }
    }

    /// What selecting the card stores; nil for a broken one.
    var selection: ThemeSelection? {
        switch kind {
        case .builtin(let s): s
        case .custom(let id): .custom(id)
        case .broken: nil
        }
    }

    var isBroken: Bool { if case .broken = kind { true } else { false } }
    var isCustom: Bool { if case .custom = kind { true } else { false } }
    /// "Novo a partir de…" offers valid themes only, never Sistema.
    var canBeBase: Bool { selection != nil && selection != .system }
}

/// State behind the gallery in Preferências › Aparência: built-in themes plus the library, the selected one, and the
/// actions. Applying goes through `apply`, so tests need no window. `sync` and `reload` are idempotent: the library
/// watcher may call them more than once per change, and the theme is applied only when it differs from what is applied.
@MainActor @Observable final class ThemeGalleryModel {
    static let shared = ThemeGalleryModel(library: ThemeLibrary(), defaults: .standard,
                                          apply: { CollieApp.applyTheme(selection: $0, theme: $1) })

    private struct Applied: Equatable { var selection: ThemeSelection; var theme: ThemeFile? }

    private(set) var entries: [ThemeLibrary.Entry] = []
    private(set) var selection: ThemeSelection = .dark
    /// Reason of the last action that failed, for an alert; the view clears it.
    var error: String?

    @ObservationIgnored private let library: ThemeLibrary
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let apply: (ThemeSelection, ThemeFile?) -> Void
    @ObservationIgnored private var applied: Applied?

    init(library: ThemeLibrary, defaults: UserDefaults, apply: @escaping (ThemeSelection, ThemeFile?) -> Void) {
        self.library = library
        self.defaults = defaults
        self.apply = apply
        library.onChange = { [weak self] in self?.reload() }
    }

    // MARK: Cards

    var cards: [ThemeCard] {
        var out = [ThemeCard(kind: .builtin(.dark), name: "Escuro", subtitle: "do Collie", palette: .dark),
                   ThemeCard(kind: .builtin(.light), name: "Claro", subtitle: "do Collie", palette: .light),
                   ThemeCard(kind: .builtin(.system), name: "Sistema", subtitle: "segue o macOS", palette: nil)]
        for e in entries {
            if let t = e.theme {
                out.append(ThemeCard(kind: .custom(e.id), name: t.name, subtitle: e.file.lastPathComponent, palette: t.palette))
            }
        }
        for e in entries where e.theme == nil {
            out.append(ThemeCard(kind: .broken(e.id), name: e.file.lastPathComponent, subtitle: e.problem ?? "", palette: nil))
        }
        return out
    }

    func isSelected(_ card: ThemeCard) -> Bool { card.selection == selection }

    /// Thumbnail colors of the selected theme (nil: Sistema, or a custom theme that is not loaded).
    var selectedPalette: Palette? {
        switch selection {
        case .dark: .dark
        case .light: .light
        case .system: nil
        case .custom(let id): entries.first { $0.id == id }?.theme?.palette
        }
    }

    /// The selected theme when it is a valid file of the user's: what the editor shows. Nil otherwise.
    var editable: (id: String, theme: ThemeFile)? {
        guard case .custom(let id) = selection, let theme = entries.first(where: { $0.id == id })?.theme else { return nil }
        return (id, theme)
    }

    /// Editing state for one theme; its writes go to the library, and are skipped once the file left the list
    /// (deleted while a write was pending), so a deleted theme does not come back.
    func editorSession(id: String, theme: ThemeFile) -> ThemeEditorSession {
        ThemeEditorSession(id: id, theme: theme, scheduler: TimerScheduler()) { [weak self] t in
            guard let self, entries.contains(where: { $0.id == id }) else { return }
            try library.save(t, id: id)
        }
    }

    // MARK: Loading and applying

    /// App start: reads the folder and applies the saved choice. A `custom:<id>` that is missing or broken applies
    /// Escuro and keeps the preference.
    func start() {
        entries = library.reload()
        sync()
    }

    /// The library told it changed (possibly more than once for one change).
    func reload() {
        entries = library.reload()
        sync()
    }

    /// Reads the saved choice and applies it if it differs from what is applied. A custom theme that was on screen
    /// and is now missing or broken sends the app back to Escuro and saves that.
    func sync() {
        var sel = AppearanceSettings(defaults: defaults).theme
        var theme: ThemeFile?
        if case .custom(let id) = sel {
            theme = entries.first { $0.id == id }?.theme
            if theme == nil, applied?.theme != nil {
                sel = .dark
                defaults.set(sel.rawValue, forKey: AppearanceKeys.theme)
            }
        }
        selection = sel
        let next = Applied(selection: sel, theme: theme)
        guard next != applied else { return }
        applied = next
        apply(sel, theme)
    }

    /// Applies again what is applied (the window did not exist yet at the first apply).
    func reapply() {
        if let applied { apply(applied.selection, applied.theme) } else { sync() }
    }

    // MARK: Actions

    /// Stores the choice and applies it. A broken card, or a custom one that is not loaded, does nothing.
    func select(_ card: ThemeCard) {
        guard let sel = card.selection else { return }
        if case .custom(let id) = sel, entries.first(where: { $0.id == id })?.theme == nil { return }
        defaults.set(sel.rawValue, forKey: AppearanceKeys.theme)
        sync()
    }

    /// A copy of the theme, named "<nome> (cópia)", selected. Not offered for Sistema or a broken card.
    func newFrom(_ card: ThemeCard) {
        guard card.canBeBase, let base = baseTheme(of: card) else { return }
        do {
            let id = try library.create(from: base, name: base.name + " (cópia)")
            entries = library.reload()
            defaults.set(ThemeSelection.custom(id).rawValue, forKey: AppearanceKeys.theme)
            sync()
        } catch { fail(error) }
    }

    /// Validates the file first; an invalid one never enters and the reason goes to `error`.
    func importFile(_ url: URL) {
        do {
            _ = try library.importFile(url)
            entries = library.reload()
        } catch { fail(error) }
    }

    /// To the Trash. If it was the selected one the app goes back to Escuro.
    func delete(_ card: ThemeCard) {
        let id: String
        switch card.kind {
        case .custom(let i), .broken(let i): id = i
        case .builtin: return
        }
        do {
            try library.delete(id: id)
        } catch { fail(error); return }
        if card.selection == selection { defaults.set(ThemeSelection.dark.rawValue, forKey: AppearanceKeys.theme) }
        entries = library.reload()
        sync()
    }

    /// The themes folder (created if needed), or one file selected in Finder.
    func reveal(_ card: ThemeCard? = nil) {
        if case .broken(let id)? = card?.kind, ThemeFile.validId(id) {
            library.reveal(id: id)
        } else if case .custom(let id)? = card?.kind {
            library.reveal(id: id)
        } else {
            try? FileManager.default.createDirectory(
                at: library.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            library.reveal()
        }
    }

    private func baseTheme(of card: ThemeCard) -> ThemeFile? {
        switch card.kind {
        case .builtin(.dark): ThemeFile(name: card.name, extends: .dark)
        case .builtin(.light): ThemeFile(name: card.name, extends: .light)
        case .custom(let id): entries.first { $0.id == id }?.theme
        default: nil
        }
    }

    private func fail(_ e: any Error) {
        switch e {
        case let t as ThemeError: error = t.message
        case let l as ThemeLibrary.LibraryError: error = l.message
        default: error = "não foi possível concluir (\(e.localizedDescription))"
        }
    }
}

/// The gallery: one card per theme, then "Novo a partir de…"; "Importar…" and "Mostrar no Finder" above; the editor
/// of the selected theme below it when that theme is the user's.
struct ThemeGallery: View {
    @State private var model = ThemeGalleryModel.shared
    @State private var toDelete: ThemeCard?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Spacer()
                Button("Importar…") { importPanel() }.buttonStyle(CollieButtonStyle(.secondary))
                Button("Mostrar no Finder") { model.reveal() }.buttonStyle(CollieButtonStyle(.secondary))
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(model.cards) { card in cardView(card) }
                newCard
            }
            if let e = model.editable {
                ThemeEditorView(id: e.id, theme: e.theme, gallery: model).id(e.id)
            }
        }
        .alert("Tema", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("Apagar \"\(toDelete?.name ?? "")\"?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Apagar", role: .destructive) { if let c = toDelete { model.delete(c) }; toDelete = nil }
            Button("Cancelar", role: .cancel) { toDelete = nil }
        } message: { Text("O arquivo vai para o Lixo.") }
    }

    @ViewBuilder private func cardView(_ card: ThemeCard) -> some View {
        if card.isBroken {
            brokenCard(card)
        } else {
            ChoiceCard(card.name, subtitle: card.subtitle, selected: model.isSelected(card), action: { model.select(card) }) {
                ThemeThumbnail(palette: card.palette)
            }
            .contextMenu {
                if card.isCustom {
                    Button("Mostrar no Finder") { model.reveal(card) }
                    Button("Apagar…", role: .destructive) { toDelete = card }
                }
            }
        }
    }

    /// Reason in one line; cannot be selected.
    private func brokenCard(_ card: ThemeCard) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        return VStack(alignment: .leading, spacing: 8) {
            ThemeThumbnail(palette: nil).opacity(0.5).clipShape(RoundedRectangle(cornerRadius: 8))
            Text(card.name).font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText).lineLimit(1)
            Text(card.subtitle).font(.collieMono(12)).foregroundStyle(Color.collieDanger).lineLimit(1)
            HStack(spacing: 8) {
                Button("Mostrar no Finder") { model.reveal(card) }
                Button("Apagar…", role: .destructive) { toDelete = card }
            }.buttonStyle(.link).font(.collieMono(11))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(shape.strokeBorder(Color.collieBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(card.name), com erro: \(card.subtitle)")
    }

    /// A menu of the valid themes; the copy is made and selected.
    private var newCard: some View {
        Menu {
            ForEach(model.cards.filter(\.canBeBase)) { c in Button(c.name) { model.newFrom(c) } }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text("+").font(.collieUI(22)).foregroundStyle(Color.collieMuted)
                    .frame(maxWidth: .infinity).frame(height: 64)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.collieSunken))
                Text("Novo a partir de…").font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText)
                Text("copia um tema").font(.collieMono(12)).foregroundStyle(Color.collieMuted)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.collieBorder, lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .accessibilityLabel("Novo a partir de…")
    }

    private func importPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json]
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        p.message = "Escolha um arquivo de tema (.json)"
        if p.runModal() == .OK, let url = p.url { model.importFile(url) }
    }
}

/// Background, two lines of text and an accent block, in the theme's colors. Sistema (nil) uses the current ones.
struct ThemeThumbnail: View {
    let palette: Palette?
    @Environment(\.collieThemeRevision) private var revision

    var body: some View {
        let _ = revision
        let bg = palette.map { Color(nsColor: $0.background.nsColor) } ?? .collieBackground
        let text = palette.map { Color(nsColor: $0.text.nsColor) } ?? .collieText
        let accent = palette.map { Color(nsColor: $0.accent.nsColor) } ?? .collieAccent
        return ZStack(alignment: .topLeading) {
            bg
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(text.opacity(0.85)).frame(width: 70, height: 4)
                Capsule().fill(text.opacity(0.5)).frame(width: 44, height: 4)
            }.padding(.top, 10).padding(.leading, 10)
            RoundedRectangle(cornerRadius: 3).fill(accent).frame(width: 24, height: 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(8)
        }
        .frame(height: 64)
        .accessibilityHidden(true)
    }
}
