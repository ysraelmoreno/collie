import AppKit
import SwiftUI
import CollieClient
import CollieCore
import CollieProtocol
import CollieTheme

/// What the install confirmation shows for a picked folder: its manifest (read and validated here, the daemon checks
/// again), its commands, and the installed plug-in of the same id it would replace.
struct PluginInstallPrompt: Identifiable {
    let folder: URL
    let manifest: PluginManifest
    let replacing: PluginRow?
    var id: String { folder.path }

    static func make(folder: URL, installed: [PluginRow]) throws(ProtocolError) -> PluginInstallPrompt {
        let m = try PluginManifest.load(folder: folder)
        return PluginInstallPrompt(folder: folder, manifest: m, replacing: installed.first { $0.id == m.id })
    }

    var title: String { replacing.map { "Substituir \($0.name)?" } ?? "Instalar \(manifest.name) \(manifest.version)?" }
    var confirm: String { replacing == nil ? "Instalar" : "Substituir" }
    var replaceLine: String? {
        replacing.map { old in
            "Substitui \(old.name) \(old.version) (de \(Self.author(old.author))) por \(manifest.name) \(manifest.version) (de \(Self.author(manifest.author)))."
        }
    }
    var details: [String] {
        ["Autor: \(Self.author(manifest.author)) · Licença: \(manifest.license.isEmpty ? "não informada" : manifest.license)",
         manifest.commands.count == 1 ? "1 comando" : "\(manifest.commands.count) comandos"]
    }
    var commands: [String] { manifest.commands.map { "collie \(manifest.id) \($0.name) — \($0.summary)" } }
    private static func author(_ a: String?) -> String { (a ?? "").isEmpty ? "autor desconhecido" : a! }
}

/// Preferências → Plug-ins: the installed external plug-ins (name, version, author, license, commands, state or the
/// daemon's error verbatim), **Instalar…** (a folder → confirmation listing its commands, and what it replaces),
/// **Remover** (confirmation) and the enable switch. Everything is disabled while disconnected.
struct PluginsPreferences: View {
    let client: DaemonClient
    @State private var rows: [PluginRow] = []
    @State private var error: String?
    @State private var prompt: PluginInstallPrompt?
    @State private var removing: PluginRow?
    @State private var busy = false
    private var connected: Bool { client.state == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Painéis e comandos de terceiros. Só você instala; os agentes usam os comandos pela guia, como os do Collie.")
                    .font(.collieMono(12)).foregroundStyle(Color.collieMuted).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Instalar…") { pick() }.disabled(!connected || busy)
            }
            if let error {
                Text(error).font(.collieMono(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if rows.isEmpty {
                Text(connected ? "Nenhum plug-in instalado." : "Sem conexão com o serviço do Collie.")
                    .font(.collieUI(13)).foregroundStyle(Color.collieMuted)
            }
            ForEach(rows) { row($0) }
        }
        .task(id: connected) { await reload() }
        .onChange(of: client.plugins) { Task { await reload() } }   // installed, removed, switched elsewhere
        .sheet(item: $prompt) { confirmSheet($0) }
        .confirmationDialog(removing.map { "Remover \($0.name)?" } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remover", role: .destructive) { if let r = removing { run { try await client.uninstallPlugin(r.id) } } }
        } message: {
            Text("Os painéis abertos dele mostram um aviso e guardam o estado; os comandos somem para os agentes.")
        }
    }

    private func row(_ r: PluginRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(r.name) \(r.version)").font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText)
                Text([r.author.map { "de \($0)" }, r.license, r.commands.map { $0.count == 1 ? "1 comando" : "\($0.count) comandos" }]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.collieMono(12)).foregroundStyle(Color.collieMuted)
                if let e = r.error {
                    Text(e).font(.collieMono(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled)
                } else {
                    Text(r.enabled ? "Ativo" : "Desativado").font(.collieMono(12)).foregroundStyle(Color.collieMuted)
                }
            }
            Spacer()
            Toggle("Ativo", isOn: Binding(get: { r.enabled }, set: { on in run { try await client.setPluginEnabled(r.id, on) } }))
                .labelsHidden().toggleStyle(.switch).disabled(!connected || busy)
            Button("Remover") { removing = r }.disabled(!connected || busy)
        }
        .padding(10).background(Color.collieSurface).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func confirmSheet(_ p: PluginInstallPrompt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(p.title).font(.collieUI(15, .semibold)).foregroundStyle(Color.collieText)
            if let line = p.replaceLine { Text(line).font(.collieUI(13)).foregroundStyle(Color.collieAttention) }
            ForEach(p.details, id: \.self) { Text($0).font(.collieMono(12)).foregroundStyle(Color.collieMuted) }
            Text("Comandos que os agentes ligados a um painel dele poderão usar:").font(.collieUI(13)).foregroundStyle(Color.collieText)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(p.commands, id: \.self) { Text($0).font(.collieMono(12)).foregroundStyle(Color.collieText).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 200)
            Text("Sem rede, sem acesso ao projeto: a página vê só os argumentos de cada comando.")
                .font(.collieMono(12)).foregroundStyle(Color.collieMuted)
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { prompt = nil }.keyboardShortcut(.cancelAction)
                Button(p.confirm) { prompt = nil; run { try await client.installPlugin(folder: p.folder, id: p.manifest.id, version: p.manifest.version, replace: p.replacing != nil) } }
                    .keyboardShortcut(.defaultAction).disabled(!connected)
            }
        }
        .padding(20).frame(width: 480)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Escolha a pasta do plug-in (com collie-plugin.json)"
        panel.prompt = "Escolher"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do throws(ProtocolError) { error = nil; prompt = try PluginInstallPrompt.make(folder: folder, installed: rows) }
        catch { self.error = error.message }
    }

    /// One plug-in action; its error is the daemon's, verbatim. The list is read again either way.
    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            do { try await action(); error = nil } catch let e as ProtocolError { error = e.message } catch { self.error = "\(error)" }
            await reload()
            busy = false
        }
    }

    private func reload() async {
        guard connected else { rows = []; return }
        do throws(ProtocolError) { rows = try await client.listPlugins() } catch { self.error = error.message }
    }
}
