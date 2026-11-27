import AppKit
import SwiftUI
import CollieClient
import CollieCore
import CollieProtocol
import CollieTheme

/// What the install confirmation shows: a picked folder's manifest (read and validated here, the daemon checks again),
/// or a catalog version (its publisher, size and permission lines; the daemon checks the download), and the installed
/// plug-in of the same id it would replace.
struct PluginInstallPrompt: Identifiable {
    let pluginId: String
    let name: String
    let version: String
    let author: String
    let license: String?
    let commands: [String]
    /// What it may do beyond its page (`PluginManifest.permissionLines`); empty: nothing.
    let permissions: [String]
    let replacing: PluginRow?
    /// nil: from the catalog.
    let folder: URL?
    /// "Do catálogo, publicado por <publisherName> · revisado"; nil for a folder.
    let catalogLine: String?
    /// A plug-in from someone other than Collie: who wrote it and that Collie reviewed this version; nil for Collie's own.
    let authorNotice: String?
    /// "Roda um programa assinado por <author> (time <id>)": a third party's helper; nil without one.
    let helperLine: String?
    let size: Int?
    var id: String { folder?.path ?? "catalog:\(pluginId)" }

    init(folder: URL, manifest m: PluginManifest, replacing: PluginRow?) {
        pluginId = m.id; name = m.name; version = m.version; author = m.author; license = m.license
        commands = m.commands.map { "collie \(m.id) \($0.name) — \($0.summary)" }
        permissions = m.permissionLines; self.replacing = replacing; self.folder = folder; catalogLine = nil; authorNotice = nil; helperLine = nil; size = nil
    }

    init(catalog item: PluginCatalogView.Item, latest: PluginCatalogView.Latest, replacing: PluginRow?) {
        pluginId = item.id; name = item.name; version = latest.version; author = item.publisherName; license = nil
        commands = []   // ponytail: the catalog doesn't list commands; the Instalados row shows them once installed
        permissions = latest.permissionLines; self.replacing = replacing; folder = nil; size = latest.size
        let own = item.publisher == "collie"
        catalogLine = own ? tr("Do catálogo, publicado por \(item.publisherName) · revisado", "From the catalog, published by \(item.publisherName) · reviewed")
            : tr("Do catálogo, publicado por \(item.publisherName) · revisado pelo Collie", "From the catalog, published by \(item.publisherName) · reviewed by Collie")
        authorNotice = own ? nil : tr("O autor é \(item.publisherName), não o Collie. O Collie revisou esta versão.", "The author is \(item.publisherName), not Collie. Collie reviewed this version.")
        helperLine = !own ? latest.helperTeamId.map { tr("Roda um programa assinado por \(item.publisherName) (time \($0))", "Runs a program signed by \(item.publisherName) (team \($0))") } : nil
    }

    static func make(folder: URL, installed: [PluginRow]) throws(ProtocolError) -> PluginInstallPrompt {
        let m = try PluginManifest.load(folder: folder)
        return PluginInstallPrompt(folder: folder, manifest: m, replacing: installed.first { $0.id == m.id })
    }

    var title: String { replacing.map { tr("Substituir \($0.name)?", "Replace \($0.name)?") } ?? tr("Instalar \(name) \(version)?", "Install \(name) \(version)?") }
    var confirm: String { replacing == nil ? tr("Instalar", "Install") : tr("Substituir", "Replace") }
    var replaceLine: String? {
        replacing.map { old in
            tr("Substitui \(old.name) \(old.version) (de \(Self.author(old.author))) por \(name) \(version) (de \(Self.author(author))).",
               "Replaces \(old.name) \(old.version) (by \(Self.author(old.author))) with \(name) \(version) (by \(Self.author(author))).")
        }
    }
    var details: [String] {
        if let size { return [tr("Autor: \(Self.author(author))", "Author: \(Self.author(author))"), PluginCatalogModel.size(size)] }
        let lic = (license ?? "").isEmpty ? nil : license
        return [tr("Autor: \(Self.author(author)) · Licença: \(lic ?? "não informada")", "Author: \(Self.author(author)) · License: \(lic ?? "not provided")"),
                commands.count == 1 ? tr("1 comando", "1 command") : tr("\(commands.count) comandos", "\(commands.count) commands")]
    }
    /// The lines the installed version didn't have: a replacement that asks for more says so on the confirmation
    /// (and a catalog update without any is one click, no confirmation).
    var newPermissions: [String] {
        guard let old = replacing else { return [] }
        return permissions.filter { !(old.permissions ?? []).contains($0) }
    }
    private static func author(_ a: String?) -> String { (a ?? "").isEmpty ? tr("autor desconhecido", "unknown author") : a! }
}

/// Preferências → Plug-ins, two tabs. **Instalados**: the installed external plug-ins (name, version, author, license,
/// commands, state or the daemon's error verbatim), "do catálogo", "atualização disponível", a recalled one locked off,
/// **Instalar de uma pasta…**, **Remover** (confirmation) and the enable switch. **Descobrir**: the signed catalog by kind,
/// Instalar (the confirmation), Atualizar (one click unless it asks for more), a motor opens Desenho. Everything is
/// disabled while disconnected.
struct PluginsPreferences: View {
    enum Tab: Hashable { case installed, discover }
    let client: DaemonClient
    /// Preferências → Desenho (a motor's own installer, e.g. FigCraft).
    var openDesign: () -> Void = {}
    @State private var tab = Tab.installed
    @State private var rows: [PluginRow] = []
    @State private var catalog: PluginCatalogView?
    @State private var filter = CatalogFilter.all
    @State private var error: String?
    @State private var prompt: PluginInstallPrompt?
    @State private var removing: PluginRow?
    @State private var busy = false
    private var connected: Bool { client.state == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $tab) {
                Text(tr("Instalados", "Installed")).tag(Tab.installed)
                Text(tr("Descobrir", "Discover")).tag(Tab.discover)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
            if let error {
                Text(error).font(.collieMono(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch tab {
            case .installed: installedTab
            case .discover: discoverTab
            }
        }
        .task(id: connected) { await reload() }
        .task(id: tab) { if tab == .discover { await loadCatalog(refresh: true) } }
        .onChange(of: client.plugins) { Task { await reload() } }   // installed, removed, switched, recalled elsewhere
        .sheet(item: $prompt) { confirmSheet($0) }
        .confirmationDialog(removing.map { tr("Remover \($0.name)?", "Remove \($0.name)?") } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(tr("Remover", "Remove"), role: .destructive) { if let r = removing { run { try await client.uninstallPlugin(r.id) } } }
        } message: {
            Text(tr("Os painéis abertos dele mostram um aviso e guardam o estado; os comandos somem para os agentes.", "Its open panels show a notice and keep their state; the commands disappear for agents."))
        }
    }

    // MARK: Instalados

    private var installedTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Painéis e comandos de terceiros. Só você instala; os agentes usam os comandos pela guia, como os do Collie.", "Third-party panels and commands. Only you install; agents use the commands through the guide, like Collie's."))
                .font(.collieMono(12)).foregroundStyle(Color.collieMuted).fixedSize(horizontal: false, vertical: true)
            if rows.isEmpty {
                Text(connected ? tr("Nenhum plug-in instalado.", "No plug-in installed.") : tr("Sem conexão com o serviço do Collie.", "No connection to the Collie service."))
                    .font(.collieUI(13)).foregroundStyle(Color.collieMuted)
            }
            ForEach(rows) { row($0) }
            Button(tr("Instalar de uma pasta…", "Install from a folder…")) { pick() }.disabled(!connected || busy)
        }
    }

    private func row(_ r: PluginRow) -> some View {
        let item = catalog?.items.first { $0.id == r.id }
        let target = item.flatMap(PluginCatalogModel.target)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("\(r.name) \(r.version)").font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText)
                    if r.source == .catalog { tag(tr("do catálogo", "from the catalog"), Color.collieAccent) }
                    if r.recalled != nil { tag(tr("recolhido", "recalled"), Color.collieDanger) }
                    else if let target { tag(tr("atualização disponível: \(target.version)", "update available: \(target.version)"), Color.collieAttention) }
                }
                Text([r.author.map { tr("de \($0)", "by \($0)") }, r.license, r.commands.map { $0.count == 1 ? tr("1 comando", "1 command") : tr("\($0.count) comandos", "\($0.count) commands") }]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.collieMono(12)).foregroundStyle(Color.collieMuted)
                if let rc = r.recalled {
                    Text(tr("recolhido: \(rc.reason). Só atualizar ou remover.", "recalled: \(rc.reason). Only update or remove.")).font(.collieMono(12)).foregroundStyle(Color.collieDanger)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(r.permissions ?? [], id: \.self) { Text($0).font(.collieMono(12)).foregroundStyle(Color.collieAttention) }
                }
                if let e = r.error {
                    Text(e).font(.collieMono(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled)
                } else {
                    Text(r.recalled != nil ? tr("Bloqueado: versão recolhida", "Blocked: recalled version") : r.enabled ? tr("Ativo", "Active") : tr("Desativado", "Disabled"))
                        .font(.collieMono(12)).foregroundStyle(Color.collieMuted)
                }
            }
            Spacer()
            // a recalled version never comes back on (plugin.enable refuses it): the switch shows off and does nothing
            Toggle(tr("Ativo", "Active"), isOn: Binding(get: { r.enabled && r.recalled == nil }, set: { on in run { try await client.setPluginEnabled(r.id, on) } }))
                .labelsHidden().toggleStyle(.switch).disabled(!connected || busy || r.recalled != nil)
                .help(r.recalled != nil ? tr("Versão recolhida: não religa. Atualize ou remova.", "Recalled version: does not turn back on. Update or remove.") : "")
            if let item, let target {
                Button(r.recalled != nil ? tr("Instalar \(target.version)", "Install \(target.version)") : tr("Atualizar", "Update")) { update(item, to: target) }
                    .buttonStyle(.borderedProminent).disabled(!connected || busy)
            }
            Button(tr("Remover", "Remove")) { removing = r }.disabled(!connected || busy)
        }
        .padding(10).background(Color.collieSurface).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Descobrir

    private var discoverTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Plug-ins publicados no catálogo do Collie. Só você instala; confirme o que cada um pode fazer.", "Plug-ins published in Collie's catalog. Only you install; confirm what each can do."))
                .font(.collieMono(12)).foregroundStyle(Color.collieMuted).fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $filter) {
                ForEach(CatalogFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 340)
            if let c = catalog, c.state == "stale", let b = PluginCatalogModel.banner(c) {
                Text(b).font(.collieMono(12)).foregroundStyle(Color.collieAttention).fixedSize(horizontal: false, vertical: true)
            }
            if catalog == nil || catalog?.state == "unavailable" {
                VStack(spacing: 6) {
                    Text(tr("O catálogo não carregou.", "The catalog did not load.")).font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText)
                    Text(tr("Os plug-ins instalados seguem funcionando.", "Installed plug-ins keep working.")).font(.collieUI(13)).foregroundStyle(Color.collieMuted)
                    if let reason = catalog?.reason { Text(reason).font(.collieMono(12)).foregroundStyle(Color.collieMuted).textSelection(.enabled) }
                    Button(tr("Tentar de novo", "Try again")) { Task { await loadCatalog(refresh: true) } }.disabled(!connected || busy)
                }
                .frame(maxWidth: .infinity).padding(20)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.collieBorder, style: StrokeStyle(lineWidth: 1, dash: [4])))
            }
            if let c = catalog {
                let list = PluginCatalogModel.rows(c, filter: filter, installed: rows)
                if list.isEmpty && c.state != "unavailable" { Text(tr("Nada neste filtro.", "Nothing in this filter.")).font(.collieUI(13)).foregroundStyle(Color.collieMuted) }
                ForEach(list) { card($0) }
            }
        }
    }

    private func card(_ row: CatalogRow) -> some View {
        let item = row.item, lines = item.latest?.permissionLines ?? []
        return HStack(alignment: .top, spacing: 12) {
            Text(String(item.name.prefix(1))).font(.collieUI(15, .bold)).foregroundStyle(Color.collieAccent)
                .frame(width: 34, height: 34).background(Color.collieRaised, in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.name).font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText)
                    tag(Self.kindLabel(item.kind), Color.collieMuted)
                    Text(PluginCatalogModel.byline(item)).font(.collieMono(12)).foregroundStyle(Color.collieMuted)
                }
                Text(item.summary).font(.collieUI(13)).foregroundStyle(Color.collieText).fixedSize(horizontal: false, vertical: true)
                if case .recalled(let reason) = row.action {
                    Text(tr("recolhido: \(reason)", "recalled: \(reason)")).font(.collieMono(12)).foregroundStyle(Color.collieDanger)
                } else if lines.isEmpty {
                    Text(tr("Sem rede e sem acesso ao projeto", "No network and no project access")).font(.collieMono(12)).foregroundStyle(Color.collieMuted)
                } else {
                    ForEach(lines, id: \.self) { Text("⚠ \($0)").font(.collieMono(12)).foregroundStyle(Color.collieAttention) }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if let l = item.latest {
                    Text("\(l.version) · \(PluginCatalogModel.size(l.size))").font(.collieMono(12)).foregroundStyle(Color.collieMuted)
                }
                button(row)
            }
        }
        .padding(12).background(Color.collieSurface).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func button(_ row: CatalogRow) -> some View {
        let item = row.item
        switch row.action {
        case .install:
            if let l = item.latest {
                Button(tr("Instalar", "Install")) { error = nil; prompt = PluginInstallPrompt(catalog: item, latest: l, replacing: nil) }
                    .buttonStyle(.borderedProminent).disabled(!connected || busy)
            }
        case .installed:
            Text(tr("Instalado ✓", "Installed ✓")).font(.collieUI(13, .semibold)).foregroundStyle(Color.collieAccent)
        case .update:
            if let l = item.latest { Button(tr("Atualizar", "Update")) { update(item, to: l) }.buttonStyle(.borderedProminent).disabled(!connected || busy) }
        case .recalled:
            if let l = PluginCatalogModel.target(item) {
                Button(tr("Instalar \(l.version)", "Install \(l.version)")) { update(item, to: l) }.buttonStyle(.borderedProminent).disabled(!connected || busy)
            }
        case .engine:
            Button(tr("Abrir em Desenho", "Open in Design")) { openDesign() }
        }
    }

    /// No new permission line: one click, no confirmation (owner, 2026-11-24); else the confirmation marks what's new.
    private func update(_ item: PluginCatalogView.Item, to latest: PluginCatalogView.Latest) {
        let p = PluginInstallPrompt(catalog: item, latest: latest, replacing: rows.first { $0.id == item.id })
        if p.newPermissions.isEmpty { install(p) } else { error = nil; prompt = p }
    }

    private func install(_ p: PluginInstallPrompt) {
        if let folder = p.folder {
            run { try await client.installPlugin(folder: folder, id: p.pluginId, version: p.version, replace: p.replacing != nil) }
        } else {
            run { try await client.installFromCatalog(id: p.pluginId, version: p.version) }
        }
    }

    private static func kindLabel(_ k: PluginCatalog.Kind) -> String {
        switch k { case .panel: tr("Painel", "Panel"); case .agent: tr("Agente", "Agent"); case .engine: tr("Motor", "Engine") }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.collieMono(11)).foregroundStyle(color)
            .padding(.horizontal, 8).overlay(Capsule().strokeBorder(color, lineWidth: 1))
    }

    // MARK: confirmation

    private func confirmSheet(_ p: PluginInstallPrompt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(p.title).font(.collieUI(15, .semibold)).foregroundStyle(Color.collieText)
            if let line = p.catalogLine {
                Text(line).font(.collieUI(13)).foregroundStyle(Color.collieText)
                    .padding(.leading, 10).overlay(alignment: .leading) { Rectangle().fill(Color.collieAccent).frame(width: 3) }
            }
            if let line = p.authorNotice { Text(line).font(.collieUI(13, .semibold)).foregroundStyle(Color.collieAttention) }
            if let line = p.helperLine { Text(line).font(.collieMono(12)).foregroundStyle(Color.collieAttention) }
            if let line = p.replaceLine { Text(line).font(.collieUI(13)).foregroundStyle(Color.collieAttention) }
            ForEach(p.details, id: \.self) { Text($0).font(.collieMono(12)).foregroundStyle(Color.collieMuted) }
            if !p.commands.isEmpty {
                Text(tr("Comandos que os agentes ligados a um painel dele poderão usar:", "Commands that agents attached to one of its panels may use:")).font(.collieUI(13)).foregroundStyle(Color.collieText)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(p.commands, id: \.self) { Text($0).font(.collieMono(12)).foregroundStyle(Color.collieText).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 200)
            }
            if p.permissions.isEmpty {
                Text(tr("Sem rede, sem acesso ao projeto: a página vê só os argumentos de cada comando.", "No network, no project access: the page sees only each command's arguments."))
                    .font(.collieMono(12)).foregroundStyle(Color.collieMuted)
            } else {
                Text(p.replacing == nil ? tr("Este plug-in pode:", "This plug-in can:") : tr("Esta versão pode:", "This version can:")).font(.collieUI(13, .semibold)).foregroundStyle(Color.collieAttention)
                ForEach(p.permissions, id: \.self) {
                    Text(p.newPermissions.contains($0) ? tr("• \($0) (novo)", "• \($0) (new)") : "• \($0)").font(.collieMono(12)).foregroundStyle(Color.collieAttention)
                }
                Text(tr("Sem rede. O programa roda isolado e vê só caminhos, nunca a conversa.", "No network. The program runs isolated and sees only paths, never the conversation.")).font(.collieMono(12)).foregroundStyle(Color.collieMuted)
            }
            HStack {
                Spacer()
                Button(tr("Cancelar", "Cancel"), role: .cancel) { prompt = nil }.keyboardShortcut(.cancelAction)
                Button(p.confirm) { prompt = nil; install(p) }.keyboardShortcut(.defaultAction).disabled(!connected)
            }
        }
        .padding(20).frame(width: 480)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = tr("Escolha a pasta do plug-in (com collie-plugin.json)", "Choose the plug-in folder (with collie-plugin.json)")
        panel.prompt = tr("Escolher", "Choose")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do throws(ProtocolError) { error = nil; prompt = try PluginInstallPrompt.make(folder: folder, installed: rows) }
        catch { self.error = error.message }
    }

    /// One plug-in action; its error is the daemon's, verbatim. The list and the catalog are read again either way.
    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            do { try await action(); error = nil } catch let e as ProtocolError { error = e.message } catch { self.error = "\(error)" }
            await reload()
            busy = false
        }
    }

    /// The installed list, and the stored catalog (no download) for the badges and the update buttons.
    private func reload() async {
        guard connected else { rows = []; return }
        do throws(ProtocolError) { rows = try await client.listPlugins() } catch { self.error = error.message }
        await loadCatalog(refresh: false)
    }

    private func loadCatalog(refresh: Bool) async {
        guard connected else { return }
        do throws(ProtocolError) { catalog = try await client.pluginCatalog(refresh: refresh) }
        catch { if tab == .discover { self.error = error.message } }   // an older daemon: Instalados still works without badges
    }
}
