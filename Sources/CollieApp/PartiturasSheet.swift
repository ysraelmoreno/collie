import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CollieCanvas
import CollieClient
import CollieCore
import ColliePlugins
import CollieTheme

private let legacyPartituraType = UTType(filenameExtension: "orqpartitura") ?? .json   // Orq files still open
private let partituraType = UTType(filenameExtension: "colliepartitura") ?? .json   // ponytail: not declared in Info.plist; filters by extension

/// List (factory marked "de fábrica"), the selected one's full preview, and Aplicar (name, floor, folder); Importar…,
/// Exportar…, Remover. An imported file first shows the trust screen; nothing is saved until "Importar".
struct PartiturasSheet: View {
    @ObservedObject var model: PartiturasModel
    let client: DaemonClient
    let canvas: CanvasState
    /// Canvas point the partitura's corner lands on.
    let anchor: CGPoint
    var initial: String?
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var name = ""
    @State private var floor = false
    @State private var cwd = ""
    @State private var error: String?
    /// The preview (token) scrolled to its end: confirming is possible only once all it creates has been on screen.
    @State private var rendered: UUID?

    static let cwdKey = "partitura.cwd"

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Partituras", subtitle: "times prontos: terminais, painéis, cordas e andar") {
                if model.preview?.imported != true {
                    Button("Importar…", action: pickImport).buttonStyle(CollieButtonStyle(.secondary))
                }
            }
            if let pv = model.preview, pv.imported { trust(pv) } else { main }
            PanelFooter(model.error ?? error ?? "\(model.items.count) partituras", trailing: model.busy ? "aguarde…" : nil)
        }
        .frame(width: 820, height: 600).background(Color.collieSurface)
        .task {
            await model.refresh()
            if let id = initial ?? model.items.first?.id { await pick(id) }
        }
        .onAppear { cwd = Self.defaultCwd(client: client, canvas: canvas) }
    }

    /// The selected terminal's folder, else the floor's worktree, else the last one used, else home.
    static func defaultCwd(client: DaemonClient, canvas: CanvasState) -> String {
        if let t = client.terminals.first(where: { canvas.selection.contains($0.id) }) { return t.cwd }
        if let f = client.floors.first(where: { $0.id == client.currentFloor }) { return f.path }
        let d = UserDefaults.standard
        return d.string(forKey: cwdKey) ?? d.string(forKey: "new.cwd") ?? NSHomeDirectory()
    }

    private func pick(_ id: String) async {
        selected = id; rendered = nil
        await model.select(id)
        if let pv = model.preview, pv.id == id {
            floor = pv.partitura.wantsFloor
            if name.isEmpty { name = pv.partitura.name }
        }
    }

    // MARK: list + preview + form

    private var main: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.items) { it in
                        ChoiceCard(it.name, subtitle: "\(it.terminals) terminais · \(it.panels) painéis\(it.wantsFloor ? " · cria andar" : "")",
                                   selected: selected == it.id, action: { Task { await pick(it.id) } }) {
                            if it.builtIn { HStack { CollieTag("de fábrica", tone: .secondary); Spacer() } }
                        }
                    }
                    if model.items.isEmpty { Text("Nenhuma partitura").font(.collieUI(13)).foregroundStyle(Color.collieMuted) }
                }.padding(14)
            }
            .frame(width: 260)
            .overlay(alignment: .trailing) { Rectangle().fill(Color.collieBorder).frame(width: 1) }
            VStack(alignment: .leading, spacing: 12) {
                if let pv = model.preview, pv.id == selected {
                    PartituraPreviewScroll(preview: pv) { rendered = pv.token }
                    form(pv)
                } else {
                    Spacer()
                    Text(selected == nil ? "Escolha uma partitura" : "carregando…").font(.collieUI(13)).foregroundStyle(Color.collieMuted)
                    Spacer()
                }
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func form(_ pv: PartituraPreview) -> some View {
        let item = model.items.first { $0.id == pv.id }
        let ready = rendered == pv.token && !name.trimmingCharacters(in: .whitespaces).isEmpty && !cwd.isEmpty && !model.busy
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Nome (obrigatório)", text: $name).collieField()
                Toggle("Criar andar", isOn: $floor).toggleStyle(.checkbox).font(.collieUI(13)).foregroundStyle(Color.collieText)
            }
            HStack(spacing: 8) {
                TextField("Pasta", text: $cwd).collieField(mono: true)
                Button("Escolher…", action: pickFolder)
            }
            if let error { Text(error).font(.collieUI(12)).foregroundStyle(Color.collieDanger).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                Button("Exportar…") { export(pv.id) }
                if item?.builtIn == false {
                    Button("Remover") { Task { await model.remove(id: pv.id); selected = nil } }
                        .help("Sai da lista; fica guardada em partituras/.removed")
                }
                Spacer()
                if rendered != pv.token { Text("role até o fim da prévia").font(.collieUI(12)).foregroundStyle(Color.collieMuted) }
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                // not the default action: Enter never applies
                Button(model.busy ? "Aplicando…" : "Aplicar") { apply(pv) }
                    .buttonStyle(CollieButtonStyle(.primary)).disabled(!ready)
            }
        }
        .buttonStyle(CollieButtonStyle(.secondary))
    }

    private func apply(_ pv: PartituraPreview) {
        error = nil
        let n = name.trimmingCharacters(in: .whitespaces), dir = cwd
        let on = client.floors.first { $0.id == client.currentFloor }?.name
        Task {
            if let e = await model.apply(id: pv.id, name: n, floor: floor, cwd: dir, onFloor: on, at: anchor) { error = e; return }
            UserDefaults.standard.set(dir, forKey: Self.cwdKey)
            dismiss()
        }
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.directoryURL = URL(fileURLWithPath: cwd)
        if p.runModal() == .OK, let u = p.url { cwd = u.path }
    }

    private func export(_ id: String) {
        let p = NSSavePanel()
        p.allowedContentTypes = [partituraType]
        p.nameFieldStringValue = "\(id).colliepartitura"
        guard p.runModal() == .OK, let url = p.url else { return }
        Task { await model.export(id: id, to: url) }
    }

    private func pickImport() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [partituraType, legacyPartituraType]; p.allowsMultipleSelection = false; p.canChooseDirectories = false
        guard p.runModal() == .OK, let url = p.url else { return }
        rendered = nil
        Task { _ = await model.importFile(url) }
    }

    // MARK: trust screen (imported file)

    private func confirm(replace: Bool) {
        Task {
            await model.confirmImport(replace: replace)
            if let pv = model.preview, !pv.imported { selected = pv.id; floor = pv.partitura.wantsFloor; name = pv.partitura.name }
        }
    }

    private func trust(_ pv: PartituraPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Arquivo importado: confira cada comando e cada prompt. Importar só guarda a partitura; nada é criado até você aplicar.")
                .font(.collieUI(13, .medium)).foregroundStyle(Color.collieAttention).fixedSize(horizontal: false, vertical: true)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).collieCard(highlight: .collieAttention)
            HStack(spacing: 8) {
                Text(verbatim: pv.partitura.name).font(.collieUI(16, .semibold)).foregroundStyle(Color.collieText)
                CollieTag(pv.id, tone: .neutral)
            }
            Text("Esta partitura vai criar:").font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText)
            PartituraPreviewScroll(preview: pv) { rendered = pv.token }
            HStack {
                Spacer()
                if rendered != pv.token { Text("role até o fim da prévia").font(.collieUI(12)).foregroundStyle(Color.collieMuted) }
                Button("Cancelar") { model.cancelImport() }.keyboardShortcut(.cancelAction).buttonStyle(CollieButtonStyle(.secondary)).disabled(model.busy)
                // a saved one with this id: importing says it exists; replacing is offered (never over a factory one)
                if model.items.contains(where: { $0.id == pv.id && !$0.builtIn }) {
                    Button("Substituir") { confirm(replace: true) }
                        .buttonStyle(CollieButtonStyle(.secondary)).disabled(rendered != pv.token || model.busy)
                }
                Button("Importar") { confirm(replace: false) }
                    .buttonStyle(CollieButtonStyle(.primary)).disabled(rendered != pv.token || model.busy)
            }
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The preview in a scroll view with visible indicators; `atEnd` runs once its end has come on screen (lazy row).
struct PartituraPreviewScroll: View {
    let preview: PartituraPreview
    let atEnd: () -> Void
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PartituraPreviewList(preview: preview).padding(.trailing, 6)
                Color.clear.frame(height: 1).onAppear(perform: atEnd)
            }
        }
        .scrollIndicators(.visible)
        .id(preview.token)
    }
}

/// Everything a partitura creates: first, set apart, each command that will run and each prompt that will be sent,
/// verbatim; then terminals (preset, Maestro), panels with their full state, cords, the floor.
struct PartituraPreviewList: View {
    let preview: PartituraPreview

    var body: some View {
        let p = preview.partitura
        VStack(alignment: .leading, spacing: 14) {
            if !p.summary.isEmpty { Text(verbatim: p.summary).font(.collieUI(13)).foregroundStyle(Color.collieTextSecondary).fixedSize(horizontal: false, vertical: true) }
            if !preview.commands.isEmpty {
                verbatim("Comandos que serão executados", preview.commands.map { ($0.key, $0.command) }, tone: .collieAttention)
            }
            if !preview.prompts.isEmpty {
                verbatim("Prompts que serão enviados", preview.prompts.map { ($0.key, $0.role) }, tone: .collieBorder)
            }
            group("Terminais (\(p.terminals.count))") {
                ForEach(p.terminals, id: \.key) { t in
                    HStack(spacing: 6) {
                        Text(t.key).font(.collieMono(12, .medium)).foregroundStyle(Color.collieText)
                        CollieTag(t.preset.rawValue, tone: t.preset == .custom ? .attention : .neutral)
                        if t.isMaestro { CollieTag("Maestro", tone: .accent) }
                        if t.role != nil { CollieTag("com prompt", tone: .neutral) }
                    }
                }
            }
            group("Painéis (\(p.panels.count))") {
                ForEach(p.panels, id: \.key) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(a.key).font(.collieMono(12, .medium)).foregroundStyle(Color.collieText)
                            CollieTag(a.pluginId, tone: .neutral)
                        }
                        ForEach(a.state.keys.sorted(), id: \.self) { k in   // in full: a url's host must never be cut off
                            if case .string(let v)? = a.state[k] {
                                Text(verbatim: "\(k): \(v)").font(.collieMono(11)).foregroundStyle(Color.collieTextSecondary)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            group("Cordas (\(p.cords.count))") {
                ForEach(Array(p.cords.enumerated()), id: \.offset) { _, c in
                    Text(c.joined(separator: " — ")).font(.collieMono(12)).foregroundStyle(Color.collieTextSecondary)
                }
            }
            Text(p.wantsFloor ? "Andar: cria um andar novo (branch própria)" : "Andar: nenhum (no andar atual)")
                .font(.collieUI(13)).foregroundStyle(Color.collieTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.collieMono(11)).kerning(1.2).foregroundStyle(Color.collieMuted).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// Text shown exactly as stored, selectable, monospaced, one card per item.
    private func verbatim(_ title: String, _ rows: [(String, String)], tone: Color) -> some View {
        group(title) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.0).font(.collieMono(11, .medium)).foregroundStyle(Color.collieMuted)
                    Text(verbatim: r.1).font(.collieMono(12)).foregroundStyle(Color.collieText).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.collieSunken))
                .collieCard(highlight: tone)
            }
        }
    }
}

/// Name, description, the nodes to keep (the selection, else everything on this floor's canvas), each terminal's
/// optional initial prompt and "Pede andar"; shows the daemon's warnings.
struct SavePartituraSheet: View {
    @ObservedObject var model: PartiturasModel
    let client: DaemonClient
    let canvas: CanvasState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""
    @State private var wantsFloor = false
    @State private var picked: Set<UUID> = []
    @State private var roles: [UUID: String] = [:]
    @State private var warnings: [String]?

    private var terminals: [TerminalRecord] { visibleTerminals(client.terminals, floor: client.currentFloor) }
    private var panels: [Panel] { visiblePanels(client.panels, floor: client.currentFloor).filter { $0.placement == .canvas } }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Salvar como partitura", subtitle: "sem histórico, tokens, variáveis nem caminhos")
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Nome", text: $name).collieField()
                    TextField("Descrição", text: $summary).collieField()
                    Toggle("Pede andar", isOn: $wantsFloor).toggleStyle(.checkbox).font(.collieUI(13)).foregroundStyle(Color.collieText)
                    Text("TERMINAIS").font(.collieMono(11)).kerning(1.2).foregroundStyle(Color.collieMuted)
                    ForEach(terminals) { t in
                        HStack(spacing: 8) {
                            Toggle(t.name, isOn: binding(t.id)).toggleStyle(.checkbox).font(.collieMono(12)).frame(width: 160, alignment: .leading)
                            CollieTag(t.preset.rawValue, tone: .neutral)
                            TextField("Papel (prompt inicial, opcional)", text: Binding(get: { roles[t.id] ?? "" }, set: { roles[t.id] = $0 })).collieField()
                        }
                    }
                    if !panels.isEmpty { Text("PAINÉIS").font(.collieMono(11)).kerning(1.2).foregroundStyle(Color.collieMuted) }
                    ForEach(panels) { p in
                        HStack(spacing: 8) {
                            Toggle(p.name, isOn: binding(p.id)).toggleStyle(.checkbox).font(.collieMono(12))
                            CollieTag(p.pluginId, tone: .neutral)
                        }
                    }
                    if let warnings, !warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Salva, com avisos:").font(.collieUI(13, .semibold))
                            ForEach(warnings, id: \.self) { Text($0).font(.collieUI(12)) }
                        }
                        .foregroundStyle(Color.collieAttention).padding(10).frame(maxWidth: .infinity, alignment: .leading).collieCard(highlight: .collieAttention)
                    }
                    if let e = model.error { Text(e).font(.collieUI(12)).foregroundStyle(Color.collieDanger) }
                }.padding(20)
            }
            HStack {
                Spacer()
                if warnings != nil {
                    Button("Fechar") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(CollieButtonStyle(.primary))
                } else {
                    Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(model.busy ? "Salvando…" : "Salvar", action: save).keyboardShortcut(.defaultAction).buttonStyle(CollieButtonStyle(.primary))
                        .disabled(model.busy || name.trimmingCharacters(in: .whitespaces).isEmpty || !terminals.contains { picked.contains($0.id) })
                }
            }
            .buttonStyle(CollieButtonStyle(.secondary)).padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 620, height: 560).background(Color.collieSurface)
        .onAppear {
            let shown = Set(terminals.map(\.id) + panels.map(\.id))
            let sel = canvas.selection.intersection(shown)
            picked = sel.isEmpty ? shown : sel
        }
    }

    private func binding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { picked.contains(id) }, set: { if $0 { picked.insert(id) } else { picked.remove(id) } })
    }

    private func save() {
        let t = terminals.map(\.id).filter(picked.contains), p = panels.map(\.id).filter(picked.contains)
        Task {
            let w = await model.save(name: name.trimmingCharacters(in: .whitespaces), summary: summary, terminals: t, panels: p,
                                     frames: canvas.frames, roles: roles, wantsFloor: wantsFloor)
            guard let w else { return }
            if w.isEmpty { dismiss() } else { warnings = w }
        }
    }
}
