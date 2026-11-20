import AppKit
import SwiftUI
import CollieTheme

// MARK: Coordinator (no view, testable)

/// Defers one piece of work. Injected, so tests own the clock. Scheduling again replaces the pending work.
@MainActor protocol ThemeEditScheduler: AnyObject {
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void)
    func cancel()
}

/// The real clock: a run loop timer in the common modes, so it still fires while a color panel is being dragged.
@MainActor final class TimerScheduler: ThemeEditScheduler {
    private var timer: Timer?

    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        cancel()
        let t = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { work() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    isolated deinit { timer?.invalidate() }
}

/// Between the editor model, the wait and the library: every valid change schedules a write 300 ms later (a burst is
/// one write); leaving writes what is pending; a change from disk reloads the model only when nothing of the user's
/// is pending. `external` and `flush` are idempotent (the library watcher may report one change more than once).
@MainActor @Observable final class ThemeEditorSession {
    static let delay: TimeInterval = 0.3

    let id: String
    private(set) var model: ThemeEditorModel
    /// One line when the last write failed; the text stays.
    private(set) var saveError: String?

    @ObservationIgnored private let scheduler: any ThemeEditScheduler
    @ObservationIgnored private let save: @MainActor (ThemeFile) throws -> Void

    init(id: String, theme: ThemeFile, scheduler: any ThemeEditScheduler,
         save: @escaping @MainActor (ThemeFile) throws -> Void) {
        self.id = id
        self.scheduler = scheduler
        self.save = save
        model = ThemeEditorModel(theme: theme)
    }

    func set(_ role: String, _ color: RGB) { model.set(role, color); changed() }
    func reset(_ role: String) { model.reset(role); changed() }
    func rename(_ name: String) { model.rename(name); changed() }
    func setJSON(_ text: String) { model.setJSON(text); changed() }

    /// Writes what is pending now (leaving the page, closing the window).
    func flush() {
        scheduler.cancel()
        guard let theme = model.pendingSave else { return }
        do {
            try save(theme)
            model.markSaved()
            saveError = nil
        } catch {
            saveError = "não gravado: " + Self.describe(error)
        }
    }

    /// The file on disk, as the library read it. Ignored while the user has something pending (that edit wins and is
    /// written) or invalid text in the JSON view; ignored when equal to what the editor has.
    func external(_ theme: ThemeFile?) {
        guard let theme, model.pendingSave == nil, model.jsonError == nil, theme != model.theme else { return }
        model = ThemeEditorModel(theme: theme)
        saveError = nil
    }

    private func changed() {
        if model.pendingSave != nil {
            scheduler.schedule(after: Self.delay) { [weak self] in self?.flush() }
        } else {
            scheduler.cancel()
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let t as ThemeError: t.message
        case let l as ThemeLibrary.LibraryError: l.message
        default: error.localizedDescription
        }
    }
}

/// Text of the list's reading column: "5,8", or "3,7 baixo"; nil for roles without one.
enum ThemeEditorFormat {
    static func reading(_ ratio: Double?, low: Bool) -> String? {
        guard let ratio else { return nil }
        let n = String(format: "%.1f", ratio).replacingOccurrences(of: ".", with: ",")
        return low ? n + " baixo" : n
    }

    /// Accepts `#RRGGBB` or `RRGGBB`.
    static func parseHex(_ text: String) -> RGB? {
        let t = text.trimmingCharacters(in: .whitespaces)
        return RGB(hexString: t.hasPrefix("#") ? t : "#" + t)
    }
}

// MARK: View

/// The editor under the gallery: header, Lista | JSON, preview on the right (below under 720 pt).
struct ThemeEditorView: View {
    private enum Pane: String { case list = "Lista", json = "JSON" }

    let id: String
    let gallery: ThemeGalleryModel
    @State private var session: ThemeEditorSession
    @State private var pane: Pane = .list
    @State private var nameText: String
    @FocusState private var nameFocused: Bool

    private static let groups: [PaletteRole.Group] = [.fundos, .texto, .destaques, .outros]

    init(id: String, theme: ThemeFile, gallery: ThemeGalleryModel) {
        self.id = id
        self.gallery = gallery
        _session = State(initialValue: gallery.editorSession(id: id, theme: theme))
        _nameText = State(initialValue: theme.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    editor.frame(minWidth: 452, idealWidth: 452, maxWidth: .infinity, alignment: .topLeading)
                    Divider()
                    previewColumn.frame(width: 268)
                }
                VStack(alignment: .leading, spacing: 0) {
                    editor.frame(maxWidth: .infinity, alignment: .topLeading)
                    Divider()
                    previewColumn.frame(maxWidth: .infinity)
                }
            }
            if let e = session.saveError {
                Divider()
                Text(e).font(.collieMono(11)).foregroundStyle(Color.collieAttention)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(e)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.collieBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onDisappear { session.flush() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in session.flush() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in session.flush() }
        .onChange(of: gallery.entries) { session.external(gallery.entries.first { $0.id == id }?.theme) }
        .onChange(of: session.model.theme.name) { if !nameFocused { nameText = session.model.theme.name } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Nome do tema", text: $nameText)
                .textFieldStyle(.plain)
                .font(.collieUI(13, .semibold))
                .focused($nameFocused)
                .frame(maxWidth: 180)
                .onSubmit(commitName)
                .onChange(of: nameFocused) { if !nameFocused { commitName() } }
                .accessibilityLabel("Nome do tema")
            Text("estende \(session.model.theme.extends == .dark ? "Escuro" : "Claro") · \(id).json")
                .font(.collieMono(10.5)).foregroundStyle(Color.collieMuted)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Picker("Vista", selection: $pane) {
                Text(Pane.list.rawValue).tag(Pane.list)
                Text(Pane.json.rawValue).tag(Pane.json)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 120)
            .accessibilityLabel("Vista")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.collieSidebar)
    }

    /// An invalid name (empty, over 48 characters) goes back to the current one.
    private func commitName() {
        let trimmed = nameText.trimmingCharacters(in: .whitespaces)
        if trimmed != session.model.theme.name { session.rename(trimmed) }
        nameText = session.model.theme.name
    }

    // MARK: Editor

    @ViewBuilder private var editor: some View {
        switch pane {
        case .list: list
        case .json: jsonPane
        }
    }

    private var list: some View {
        let rows = session.model.rows
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.groups, id: \.self) { group in
                Text(group.rawValue).font(.collieUI(11)).foregroundStyle(Color.collieMuted)
                    .padding(.horizontal, 12).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.collieSunken)
                    .accessibilityAddTraits(.isHeader)
                ForEach(rows.filter { $0.group == group }, id: \.key) { row in
                    ThemeEditorRowView(row: row, session: session)
                }
            }
        }
    }

    private var jsonPane: some View {
        VStack(spacing: 0) {
            ThemeJSONTextView(text: Binding(get: { session.model.jsonText }, set: { session.setJSON($0) }))
                .frame(height: 388)
                .accessibilityLabel("Arquivo do tema")
            if let e = session.model.jsonError {
                Text(e).font(.collieMono(11)).foregroundStyle(Color.collieAttention)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.collieSunken)
                    .accessibilityLabel(e)
            }
        }
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Prévia").font(.collieUI(11)).foregroundStyle(Color.collieMuted)
            ThemePreview(palette: session.model.palette).frame(minHeight: 300)
        }
        .padding(10)
        .background(Color.collieSunken)
    }
}

/// One role: name, system color picker, hex, reading, "alterado" with reset or "herdado".
private struct ThemeEditorRowView: View {
    let row: ThemeEditorRow
    let session: ThemeEditorSession
    @State private var hex: String
    @FocusState private var focused: Bool

    init(row: ThemeEditorRow, session: ThemeEditorSession) {
        self.row = row
        self.session = session
        _hex = State(initialValue: row.color.hexString)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(row.name).font(.collieUI(12)).foregroundStyle(Color.collieText)
                .frame(width: 118, alignment: .leading)
            ColorPicker(row.name, selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .accessibilityLabel(row.name)
            TextField("", text: $hex)
                .textFieldStyle(.roundedBorder)
                .font(.collieMono(11))
                .frame(width: 82)
                .focused($focused)
                .onSubmit(commitHex)
                .onChange(of: focused) { if !focused { commitHex() } }
                .accessibilityLabel("\(row.name), valor hexadecimal")
            reading.frame(width: 64, alignment: .leading)
            Spacer(minLength: 4)
            if row.changed {
                Text("alterado").font(.collieUI(11)).foregroundStyle(Color.collieAccent)
                Button { session.reset(row.key) } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.plain).foregroundStyle(Color.collieMuted)
                    .help("Voltar ao herdado")
                    .accessibilityLabel("Voltar \(row.name) ao herdado")
            } else {
                Text("herdado").font(.collieUI(11)).foregroundStyle(Color.collieMuted)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .overlay(alignment: .top) { Color.collieBorder.frame(height: 1) }
        .onChange(of: row.color) { if !focused { hex = row.color.hexString } }
    }

    @ViewBuilder private var reading: some View {
        if let text = ThemeEditorFormat.reading(row.ratio, low: row.low) {
            Text(text).font(.collieMono(11))
                .foregroundStyle(row.low ? Color.collieAttention : Color.collieTextSecondary)
                .accessibilityLabel(row.low ? "contraste baixo, \(text)" : "contraste \(text)")
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: row.color.nsColor) },
            set: { new in
                guard let rgb = rgb(from: new), rgb != row.color else { return }
                hex = rgb.hexString
                session.set(row.key, rgb)
            })
    }

    /// Valid hex (with or without `#`) is applied; invalid goes back to the previous value.
    private func commitHex() {
        if let rgb = ThemeEditorFormat.parseHex(hex), rgb != row.color { session.set(row.key, rgb) }
        hex = row.color.hexString
    }

    private func rgb(from color: Color) -> RGB? {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return RGB(hex: byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent))
    }
}

/// Monospaced text view with every automatic substitution off (quotes, dashes, spelling), so the JSON stays JSON.
private struct ThemeJSONTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textColor = CollieColor.text
        tv.insertionPointColor = CollieColor.accent
        tv.backgroundColor = CollieColor.sunken
        tv.drawsBackground = true
        tv.textContainerInset = NSSize(width: 8, height: 10)
        tv.string = text
        scroll.drawsBackground = true
        scroll.backgroundColor = CollieColor.sunken
        scroll.setAccessibilityLabel("Arquivo do tema")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        let at = min(tv.selectedRange().location, (text as NSString).length)
        tv.string = text
        tv.setSelectedRange(NSRange(location: at, length: 0))
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}
