import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CollieCanvas
import CollieClient
import CollieCore
import ColliePlugins
import CollieTheme

// Orq's and Collie's earlier files still open
private let legacyHerdTypes = ["orqpartitura", "colliepartitura"].map { UTType(filenameExtension: $0) ?? .json }
private let herdType = UTType(filenameExtension: "collieherd") ?? .json   // ponytail: not declared in Info.plist; filters by extension

/// List (factory marked "de fábrica"), the selected one's full preview, and Aplicar (name, paddock, folder); Importar…,
/// Exportar…, Remover. An imported file first shows the trust screen; nothing is saved until "Importar".
struct HerdsSheet: View {
    @ObservedObject var model: HerdsModel
    let client: DaemonClient
    let canvas: CanvasState
    /// Canvas point the herd's corner lands on.
    let anchor: CGPoint
    var initial: String?
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var name = ""
    @State private var paddock = false
    @State private var cwd = ""
    @State private var error: String?
    /// The preview (token) scrolled to its end: confirming is possible only once all it creates has been on screen.
    @State private var rendered: UUID?

    static let cwdKey = "herd.cwd"

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Rebanhos", "Herds"), subtitle: tr("times prontos: terminais, painéis, guias e cercado", "ready-made teams: terminals, panels, leashes and paddock")) {
                if model.preview?.imported != true {
                    Button(tr("Importar…", "Import…"), action: pickImport).buttonStyle(CollieButtonStyle(.secondary))
                }
            }
            if let pv = model.preview, pv.imported { trust(pv) } else { main }
            PanelFooter(model.error ?? error ?? tr("\(model.items.count) rebanhos", "\(model.items.count) herds"), trailing: model.busy ? tr("aguarde…", "wait…") : nil)
        }
        .frame(width: 820, height: 600).background(Color.collieSurface)
        .task {
            await model.refresh()
            if let id = initial ?? model.items.first?.id { await pick(id) }
        }
        .onAppear { cwd = Self.defaultCwd(client: client, canvas: canvas) }
    }

    /// The selected terminal's folder, else the paddock's worktree, else the last one used, else home.
    static func defaultCwd(client: DaemonClient, canvas: CanvasState) -> String {
        if let t = client.terminals.first(where: { canvas.selection.contains($0.id) }) { return t.cwd }
        if let f = client.paddocks.first(where: { $0.id == client.currentPaddock }) { return f.path }
        let d = UserDefaults.standard
        return d.string(forKey: cwdKey) ?? d.string(forKey: "new.cwd") ?? NSHomeDirectory()
    }

    private func pick(_ id: String) async {
        selected = id; rendered = nil
        await model.select(id)
        if let pv = model.preview, pv.id == id {
            paddock = pv.herd.wantsPaddock
            if name.isEmpty { name = pv.herd.name }
        }
    }

    // MARK: list + preview + form

    private var main: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.items) { it in
                        ChoiceCard(it.name, subtitle: tr("\(it.terminals) terminais · \(it.panels) painéis\(it.wantsPaddock ? " · cria cercado" : "")", "\(it.terminals) terminals · \(it.panels) panels\(it.wantsPaddock ? " · creates a paddock" : "")"),
                                   selected: selected == it.id, action: { Task { await pick(it.id) } }) {
                            if it.builtIn { HStack { CollieTag(tr("de fábrica", "built-in"), tone: .secondary); Spacer() } }
                        }
                    }
                    if model.items.isEmpty { Text(tr("Nenhum rebanho", "No herds")).font(.collieUI(13)).foregroundStyle(Color.collieMuted) }
                }.padding(14)
            }
            .frame(width: 260)
            .overlay(alignment: .trailing) { Rectangle().fill(Color.collieBorder).frame(width: 1) }
            VStack(alignment: .leading, spacing: 12) {
                if let pv = model.preview, pv.id == selected {
                    HerdPreviewScroll(preview: pv) { rendered = pv.token }
                    form(pv)
                } else {
                    Spacer()
                    Text(selected == nil ? tr("Escolha um rebanho", "Pick a herd") : tr("carregando…", "loading…")).font(.collieUI(13)).foregroundStyle(Color.collieMuted)
                    Spacer()
                }
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func form(_ pv: HerdPreview) -> some View {
        let item = model.items.first { $0.id == pv.id }
        let ready = rendered == pv.token && !name.trimmingCharacters(in: .whitespaces).isEmpty && !cwd.isEmpty && !model.busy
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField(tr("Nome (obrigatório)", "Name (required)"), text: $name).collieField()
                Toggle(tr("Criar cercado", "Create paddock"), isOn: $paddock).toggleStyle(.checkbox).font(.collieUI(13)).foregroundStyle(Color.collieText)
            }
            HStack(spacing: 8) {
                TextField(tr("Pasta", "Folder"), text: $cwd).collieField(mono: true)
                Button(tr("Escolher…", "Choose…"), action: pickFolder)
            }
            if let error { Text(error).font(.collieUI(12)).foregroundStyle(Color.collieDanger).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                Button(tr("Exportar…", "Export…")) { export(pv.id) }
                if item?.builtIn == false {
                    Button(tr("Remover", "Remove")) { Task { await model.remove(id: pv.id); selected = nil } }
                        .help(tr("Sai da lista; fica guardado em herds/.removed", "Leaves the list; kept in herds/.removed"))
                }
                Spacer()
                if rendered != pv.token { Text(tr("role até o fim da prévia", "scroll to the end of the preview")).font(.collieUI(12)).foregroundStyle(Color.collieMuted) }
                Button(tr("Cancelar", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                // not the default action: Enter never applies
                Button(model.busy ? tr("Aplicando…", "Applying…") : tr("Aplicar", "Apply")) { apply(pv) }
                    .buttonStyle(CollieButtonStyle(.primary)).disabled(!ready)
            }
        }
        .buttonStyle(CollieButtonStyle(.secondary))
    }

    private func apply(_ pv: HerdPreview) {
        error = nil
        let n = name.trimmingCharacters(in: .whitespaces), dir = cwd
        let on = client.paddocks.first { $0.id == client.currentPaddock }?.name
        Task {
            if let e = await model.apply(id: pv.id, name: n, paddock: paddock, cwd: dir, onPaddock: on, at: anchor) { error = e; return }
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
        p.allowedContentTypes = [herdType]
        p.nameFieldStringValue = "\(id).collieherd"
        guard p.runModal() == .OK, let url = p.url else { return }
        Task { await model.export(id: id, to: url) }
    }

    private func pickImport() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [herdType] + legacyHerdTypes; p.allowsMultipleSelection = false; p.canChooseDirectories = false
        guard p.runModal() == .OK, let url = p.url else { return }
        rendered = nil
        Task { _ = await model.importFile(url) }
    }

    // MARK: trust screen (imported file)

    private func confirm(replace: Bool) {
        Task {
            await model.confirmImport(replace: replace)
            if let pv = model.preview, !pv.imported { selected = pv.id; paddock = pv.herd.wantsPaddock; name = pv.herd.name }
        }
    }

    private func trust(_ pv: HerdPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Arquivo importado: confira cada comando e cada prompt. Importar só guarda o rebanho; nada é criado até você aplicar.", "Imported file: check every command and every prompt. Importing only saves the herd; nothing is created until you apply it."))
                .font(.collieUI(13, .medium)).foregroundStyle(Color.collieAttention).fixedSize(horizontal: false, vertical: true)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).collieCard(highlight: .collieAttention)
            HStack(spacing: 8) {
                Text(verbatim: pv.herd.name).font(.collieUI(16, .semibold)).foregroundStyle(Color.collieText)
                CollieTag(pv.id, tone: .neutral)
            }
            Text(tr("Este rebanho vai criar:", "This herd will create:")).font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText)
            HerdPreviewScroll(preview: pv) { rendered = pv.token }
            HStack {
                Spacer()
                if rendered != pv.token { Text(tr("role até o fim da prévia", "scroll to the end of the preview")).font(.collieUI(12)).foregroundStyle(Color.collieMuted) }
                Button(tr("Cancelar", "Cancel")) { model.cancelImport() }.keyboardShortcut(.cancelAction).buttonStyle(CollieButtonStyle(.secondary)).disabled(model.busy)
                // a saved one with this id: importing says it exists; replacing is offered (never over a factory one)
                if model.items.contains(where: { $0.id == pv.id && !$0.builtIn }) {
                    Button(tr("Substituir", "Replace")) { confirm(replace: true) }
                        .buttonStyle(CollieButtonStyle(.secondary)).disabled(rendered != pv.token || model.busy)
                }
                Button(tr("Importar", "Import")) { confirm(replace: false) }
                    .buttonStyle(CollieButtonStyle(.primary)).disabled(rendered != pv.token || model.busy)
            }
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The preview in a scroll view with visible indicators; `atEnd` runs once its end has come on screen (lazy row).
struct HerdPreviewScroll: View {
    let preview: HerdPreview
    let atEnd: () -> Void
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HerdPreviewList(preview: preview).padding(.trailing, 6)
                Color.clear.frame(height: 1).onAppear(perform: atEnd)
            }
        }
        .scrollIndicators(.visible)
        .id(preview.token)
    }
}

/// Everything a herd creates: first, set apart, each command that will run and each prompt that will be sent,
/// verbatim; then terminals (preset, Shepherd), panels with their full state, leashes, the paddock.
struct HerdPreviewList: View {
    let preview: HerdPreview

    var body: some View {
        let p = preview.herd
        VStack(alignment: .leading, spacing: 14) {
            if !p.summary.isEmpty { Text(verbatim: p.summary).font(.collieUI(13)).foregroundStyle(Color.collieTextSecondary).fixedSize(horizontal: false, vertical: true) }
            if !preview.commands.isEmpty {
                verbatim(tr("Comandos que serão executados", "Commands that will run"), preview.commands.map { ($0.key, $0.command) }, tone: .collieAttention)
            }
            if !preview.prompts.isEmpty {
                verbatim(tr("Prompts que serão enviados", "Prompts that will be sent"), preview.prompts.map { ($0.key, $0.role) }, tone: .collieBorder)
            }
            group(tr("Terminais (\(p.terminals.count))", "Terminals (\(p.terminals.count))")) {
                ForEach(p.terminals, id: \.key) { t in
                    HStack(spacing: 6) {
                        Text(t.key).font(.collieMono(12, .medium)).foregroundStyle(Color.collieText)
                        CollieTag(t.preset.rawValue, tone: t.preset == .custom ? .attention : .neutral)
                        if t.isShepherd { CollieTag(tr("Pastor", "Shepherd"), tone: .accent) }
                        if t.role != nil { CollieTag(tr("com prompt", "with prompt"), tone: .neutral) }
                    }
                }
            }
            group(tr("Painéis (\(p.panels.count))", "Panels (\(p.panels.count))")) {
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
            group(tr("Guias (\(p.leashes.count))", "Leashes (\(p.leashes.count))")) {
                ForEach(Array(p.leashes.enumerated()), id: \.offset) { _, c in
                    Text(c.joined(separator: " — ")).font(.collieMono(12)).foregroundStyle(Color.collieTextSecondary)
                }
            }
            Text(p.wantsPaddock ? tr("Cercado: cria um cercado novo (branch própria)", "Paddock: creates a new paddock (its own branch)") : tr("Cercado: nenhum (no cercado atual)", "Paddock: none (in the current paddock)"))
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

/// Name, description, the nodes to keep (the selection, else everything on this paddock's canvas), each terminal's
/// optional initial prompt and "Pede cercado"; shows the daemon's warnings.
struct SaveHerdSheet: View {
    @ObservedObject var model: HerdsModel
    let client: DaemonClient
    let canvas: CanvasState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""
    @State private var wantsPaddock = false
    @State private var picked: Set<UUID> = []
    @State private var roles: [UUID: String] = [:]
    @State private var warnings: [String]?

    private var terminals: [TerminalRecord] { visibleTerminals(client.terminals, paddock: client.currentPaddock) }
    private var panels: [Panel] { visiblePanels(client.panels, paddock: client.currentPaddock).filter { $0.placement == .canvas } }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(tr("Salvar como rebanho", "Save as herd"), subtitle: tr("sem histórico, tokens, variáveis nem caminhos", "no history, tokens, variables or paths"))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField(tr("Nome", "Name"), text: $name).collieField()
                    TextField(tr("Descrição", "Description"), text: $summary).collieField()
                    Toggle(tr("Pede cercado", "Asks for paddock"), isOn: $wantsPaddock).toggleStyle(.checkbox).font(.collieUI(13)).foregroundStyle(Color.collieText)
                    Text(tr("TERMINAIS", "TERMINALS")).font(.collieMono(11)).kerning(1.2).foregroundStyle(Color.collieMuted)
                    ForEach(terminals) { t in
                        HStack(spacing: 8) {
                            Toggle(t.name, isOn: binding(t.id)).toggleStyle(.checkbox).font(.collieMono(12)).frame(width: 160, alignment: .leading)
                            CollieTag(t.preset.rawValue, tone: .neutral)
                            TextField(tr("Papel (prompt inicial, opcional)", "Role (initial prompt, optional)"), text: Binding(get: { roles[t.id] ?? "" }, set: { roles[t.id] = $0 })).collieField()
                        }
                    }
                    if !panels.isEmpty { Text(tr("PAINÉIS", "PANELS")).font(.collieMono(11)).kerning(1.2).foregroundStyle(Color.collieMuted) }
                    ForEach(panels) { p in
                        HStack(spacing: 8) {
                            Toggle(p.name, isOn: binding(p.id)).toggleStyle(.checkbox).font(.collieMono(12))
                            CollieTag(p.pluginId, tone: .neutral)
                        }
                    }
                    if let warnings, !warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(tr("Salva, com avisos:", "Saved, with warnings:")).font(.collieUI(13, .semibold))
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
                    Button(tr("Fechar", "Close")) { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(CollieButtonStyle(.primary))
                } else {
                    Button(tr("Cancelar", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(model.busy ? tr("Salvando…", "Saving…") : tr("Salvar", "Save"), action: save).keyboardShortcut(.defaultAction).buttonStyle(CollieButtonStyle(.primary))
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
                                     frames: canvas.frames, roles: roles, wantsPaddock: wantsPaddock)
            guard let w else { return }
            if w.isEmpty { dismiss() } else { warnings = w }
        }
    }
}
