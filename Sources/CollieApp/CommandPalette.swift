import SwiftUI
import CollieTheme
import CollieCore

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let run: () -> Void
}

/// ⌘K sheet: a field over the filtered commands; ↑/↓ choose, ↩ runs, Esc closes. `pick` gets the chosen command;
/// the caller runs it once the sheet is gone (a sheet presented while this one closes would be dropped).
struct CommandPalette: View {
    let commands: [PaletteCommand]
    let pick: (PaletteCommand?) -> Void
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    static func filter(_ commands: [PaletteCommand], _ query: String) -> [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? commands : commands.filter { $0.title.localizedStandardContains(q) }
    }

    var body: some View {
        let matches = Self.filter(commands, query)
        VStack(spacing: 0) {
            TextField(tr("Comando", "Command"), text: $query, prompt: Text(tr("Chamar, abrir painel, ir para cercado…", "Summon, open panel, go to paddock…")))
                .textFieldStyle(.plain).font(.collieUI(16)).foregroundStyle(Color.collieText)
                .padding(16)
                .focused($focused)
                .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                .onKeyPress(.downArrow) { selected = min(selected + 1, max(matches.count - 1, 0)); return .handled }
                .onSubmit { if matches.indices.contains(selected) { pick(matches[selected]) } }
                .onExitCommand { pick(nil) }
            Rectangle().fill(Color.collieBorder).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if matches.isEmpty {
                            Text(tr("Nenhum comando", "No commands")).font(.collieUI(13)).foregroundStyle(Color.collieMuted).padding(12)
                        }
                        ForEach(Array(matches.enumerated()), id: \.element.id) { i, c in
                            Button { pick(c) } label: {
                                Text(c.title).font(.collieUI(14)).foregroundStyle(Color.collieText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(i == selected ? Color.collieRaised : .clear, in: .rect(cornerRadius: 8))
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain).id(c.id)
                            .accessibilityAddTraits(i == selected ? .isSelected : [])
                        }
                    }
                    .padding(8)
                }
                .onChange(of: selected) { _, i in if matches.indices.contains(i) { proxy.scrollTo(matches[i].id) } }
            }
            .frame(height: 320)
        }
        .frame(width: 560)
        .background(Color.collieSurface)
        .onChange(of: query) { selected = 0 }
        .onAppear { focused = true }
    }
}

/// L6: the palette's way to what left the screen (the context panel's sections, the rail's icons, the status bar). Each
/// entry reaches what already exists; `ContentView` says what (the switch over every case is exhaustive).
enum PaletteEntry: String, CaseIterable {
    case herds, lots, factory, memory, loops, work, tour, diagnostics

    var title: String {
        switch self {
        case .herds: tr("Rebanhos…", "Herds…")
        case .lots: tr("Lotes…", "Lots…")
        case .factory: tr("Fábrica…", "Factory…")
        case .memory: tr("Memória", "Memory")
        case .loops: tr("Laços…", "Loops…")
        case .work: tr("Trabalho", "Work")
        case .tour: tr("Tour das funções", "Feature tour")
        case .diagnostics: tr("Diagnóstico", "Diagnostics")
        }
    }

    /// One command per entry in `entries`, running `action(entry)`.
    static func commands(_ entries: [PaletteEntry] = allCases, action: (PaletteEntry) -> () -> Void) -> [PaletteCommand] {
        entries.map { PaletteCommand(id: "entry.\($0.rawValue)", title: $0.title, run: action($0)) }
    }
}
