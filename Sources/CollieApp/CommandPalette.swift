import SwiftUI
import CollieTheme

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
            TextField("Comando", text: $query, prompt: Text("Recrutar, abrir painel, ir para andar…"))
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
                            Text("Nenhum comando").font(.collieUI(13)).foregroundStyle(Color.collieMuted).padding(12)
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
