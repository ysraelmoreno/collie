import SwiftUI
import UniformTypeIdentifiers
import CollieCanvas
import CollieClient
import CollieCore
import ColliePlugins
import CollieProtocol
import CollieTheme

/// Env overrides (DEBUG builds only, for manual checks): COLLIE_ROOT = daemon root dir, COLLIE_LABEL = LaunchAgent label.
enum Config {
    #if DEBUG
    static let env = ProcessInfo.processInfo.environment
    static let root = env["COLLIE_ROOT"].map { URL(fileURLWithPath: $0) } ?? Paths.defaultRoot
    static let label = env["COLLIE_LABEL"] ?? DaemonLauncher.defaultLabel
    #else
    static let root = Paths.defaultRoot
    static let label = DaemonLauncher.defaultLabel
    #endif
    // Bundled: Collie.app/Contents/Helpers/collied (next to collie; "Collie" and "collie" can't share MacOS/ on case-insensitive APFS).
    // `swift run CollieApp`: collied sits next to CollieApp in the build dir.
    static let collied: String = {
        let exeDir = Bundle.main.executableURL!.deletingLastPathComponent()
        let helper = exeDir.deletingLastPathComponent().appendingPathComponent("Helpers/collied")
        return (FileManager.default.isExecutableFile(atPath: helper.path) ? helper : exeDir.appendingPathComponent("collied")).path
    }()
    /// launchd-run collied from a TCC-protected folder hangs: warn instead of installing a service that cannot start.
    /// Not applied when COLLIE_ROOT/COLLIE_LABEL dev overrides are in use.
    static var tccWarning: String? {
        #if DEBUG
        if env["COLLIE_ROOT"] != nil || env["COLLIE_LABEL"] != nil { return nil }
        #endif
        let home = NSHomeDirectory()
        guard ["Documents", "Desktop", "Downloads"].contains(where: { Bundle.main.bundlePath.hasPrefix("\(home)/\($0)/") }) else { return nil }
        return "Mova o Collie.app para /Applications: em ~/Documents, ~/Desktop ou ~/Downloads o serviço (collied) trava na permissão de pastas do macOS."
    }
    static let consentKey = "daemonConsent"
}

@main struct CollieApp: App {
    @State private var client = DaemonClient(paths: Paths(root: Config.root))
    @State private var canvas = CanvasState()
    @State private var consented: Bool
    @State private var error: String?
    @State private var paletteOpen = false
    @State private var partiturasOpen = false
    @AppStorage(AppearanceKeys.theme) private var theme = ThemeChoice.dark.rawValue

    init() { Self.migrateDefaults(from: Self.legacyDefaultsDomain, into: .standard)
             _consented = State(initialValue: UserDefaults.standard.bool(forKey: Config.consentKey))   // after the migration
             PluginViews.register("browser", BrowserPanel.self); PluginViews.register("memory", MemoryPanel.self)
             PluginViews.register("device", DevicePanel.self); PluginViews.register("design", DesignPanel.self)
             PluginViews.register("designsystems", DesignSystemsPanel.self)
             PluginViews.register("artifacts", ArtifactsPanel.self); PluginViews.register("work", WorkPanel.self)   // before any panel view is made
             Self.applyTheme() }

    static let legacyDefaultsDomain = "dev.orq.app"
    static let migratedKey = "collie.migratedFromOrq"

    /// Copies the Orq app's preferences once (a key already set here wins); returns how many keys it copied.
    @discardableResult
    static func migrateDefaults(from legacyDomain: String, into d: UserDefaults) -> Int {
        guard !d.bool(forKey: migratedKey) else { return 0 }
        let old = UserDefaults(suiteName: legacyDomain)?.persistentDomain(forName: legacyDomain) ?? [:]
        var n = 0
        for (k, v) in old where d.object(forKey: k) == nil { d.set(v, forKey: k); n += 1 }
        d.set(true, forKey: migratedKey)
        return n
    }

    var body: some Scene {
        Window("Collie", id: "main") {
            ContentView(client: client, canvas: canvas, error: $error, paletteOpen: $paletteOpen, partiturasOpen: $partiturasOpen)
                .sheet(isPresented: .constant(!consented)) { consentSheet }
                .task(id: consented) { if consented { startService() } }
                .onAppear(perform: Self.applyTheme)
                .onChange(of: theme) { Self.applyTheme() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("Exportar dados do Collie…") { DataBackupMenu.export(client) }
                Button("Importar dados do Collie…") { DataBackupMenu.import(client) }
            }
            CommandGroup(before: .toolbar) {   // ⌘K: no other menu item, nor the terminal (it takes no ⌘ keys), uses it
                // over any sheet or dialog (consent, panels' own, alerts) ⌘K is dropped: it would pop up once that one closes
                Button("Comandos…") { if !NSApp.windows.contains(where: { $0.isSheet && $0.isVisible }) { paletteOpen = true } }.keyboardShortcut("k")
                Divider()
            }
            CommandMenu("Canvas") {
                Button("Partituras…") { if !NSApp.windows.contains(where: { $0.isSheet && $0.isVisible }) { partiturasOpen = true } }
            }
            CommandGroup(after: .appTermination) {
                Button("Parar serviço") { stopService() }
            }
        }
        Settings { PreferencesView() }
    }

    /// Also from the Preferences window (the main one may be closed). `NSApp` is nil until the app object exists.
    static func applyTheme() { NSApp?.appearance = AppearanceSettings(defaults: .standard).theme.appearance }

    private var consentSheet: some View {
        VStack(spacing: 16) {
            Text("O Collie vai instalar um serviço em segundo plano (collied) que mantém seus terminais vivos mesmo com o app fechado.")
                .font(.collieUI(14)).foregroundStyle(Color.collieText).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Sair") { NSApplication.shared.terminate(nil) }.buttonStyle(CollieButtonStyle(.secondary))
                Button("Continuar") {
                    UserDefaults.standard.set(true, forKey: Config.consentKey)
                    consented = true
                }.keyboardShortcut(.defaultAction).buttonStyle(CollieButtonStyle(.primary))
            }
        }
        .padding(24).frame(width: 420).background(Color.collieSurface).interactiveDismissDisabled()
    }

    // launchctl and file I/O block: keep them off the main actor.
    private func startService() {
        Task {
            let err = await Task.detached { () -> String? in
                if let w = Config.tccWarning { return w }
                guard FileManager.default.isExecutableFile(atPath: Config.collied) else { return "collied não encontrado em \(Config.collied)" }
                do { try DaemonLauncher.ensureRunning(colliedPath: Config.collied, root: Config.root, label: Config.label); return nil }
                catch { return "Falha ao iniciar o serviço: \(error)" }
            }.value
            error = err
            client.start()   // also reconnects to an already-running daemon when install failed
        }
    }

    private func stopService() {
        Task {
            error = await Task.detached { () -> String? in
                do { try DaemonLauncher.stop(label: Config.label); return nil }
                catch { return "Falha ao parar o serviço: \(error)" }
            }.value
        }
    }
}

struct ContentView: View {
    let client: DaemonClient
    let canvas: CanvasState
    @Binding var error: String?
    @Binding var paletteOpen: Bool
    @Binding var partiturasOpen: Bool
    @AppStorage(AppearanceKeys.structure) private var structureRaw = WindowStructure.compact.rawValue
    @Environment(\.openSettings) private var openSettings
    @State private var floors: FloorActions
    @State private var usage = UsageFeed()
    @State private var workspaceName: String?
    @State private var paletteRun: PaletteCommand?   // run once the palette sheet is gone
    @State private var viewport = CGSize(width: 800, height: 600)
    /// `nil` position = from the window chrome or the palette (placed automatically); otherwise a canvas point from a right-click.
    enum SheetKind: Identifiable {
        case newTerminal(CGPoint?), edit(UUID), openPanel(CGPoint?)
        /// Apply: the canvas point (nil: the visible area's corner) and the partitura selected first.
        case partituras(CGPoint?, String?), savePartitura
        var id: String {
            switch self {
            case .partituras(let p, let s): "partituras \(String(describing: p)) \(s ?? "")"
            case .savePartitura: "save partitura"
            case .newTerminal(let p): "new \(String(describing: p))"
            case .edit(let i): "edit \(i)"
            case .openPanel(let p): "panel \(String(describing: p))"
            }
        }
    }
    @State private var sheet: SheetKind?
    @State private var store: PanelViewStore
    @StateObject private var partituras: PartiturasModel
    @State private var usageOpen = false
    @State private var bundledBuild: String?
    @State private var staleDismissed = false
    private var staleDaemon: Bool {
        client.state == .connected && !staleDismissed && DaemonLauncher.isStale(daemonBuild: client.daemonBuild, bundledBuild: bundledBuild)
    }
    private let notifier = Notifier.shared

    init(client: DaemonClient, canvas: CanvasState, error: Binding<String?>, paletteOpen: Binding<Bool>, partiturasOpen: Binding<Bool>) {
        self.client = client; self.canvas = canvas; _error = error; _paletteOpen = paletteOpen; _partiturasOpen = partiturasOpen
        _partituras = StateObject(wrappedValue: PartiturasModel(call: { cmd, args throws(ProtocolError) in try await client.adminCall(cmd, args) },
                                                                nodeName: { client.nodeName($0) }))
        _floors = State(initialValue: FloorActions(client: client))
        _store = State(initialValue: PanelViewStore(panels: { client.panels }, context: { panel in
            PanelHostContext(panel: panel, root: Config.root, workspaceId: client.workspaceId,
                             call: { cmd, args throws(ProtocolError) in try await client.adminCall(cmd, args) },
                             emit: { name, payload in Task { @MainActor in client.emit(panel: panel.id, name: name, payload: payload) } },
                             openStream: { cmd, args throws(ProtocolError) in try await client.openAdminStream(cmd, args) })
        }))
    }

    private var staleBanner: some View {
        HStack(spacing: 10) {
            Text("O serviço do Collie está desatualizado (versão anterior ainda rodando). Reiniciar agora? Os terminais abertos serão encerrados.")
                .font(.collieUI(13)).foregroundStyle(Color.collieText).fixedSize(horizontal: false, vertical: true)
            Button("Reiniciar serviço") {
                Task {
                    error = await Task.detached { () -> String? in
                        do { try DaemonLauncher.restart(label: Config.label); return nil }
                        catch { return "Falha ao reiniciar o serviço: \(error)" }
                    }.value
                }
            }
            .buttonStyle(CollieButtonStyle(.attention))
            Button("Depois") { staleDismissed = true }.buttonStyle(CollieButtonStyle(.quiet))
        }.banner(Color.collieAttention, fill: Color.collieAttentionTint)
    }

    private var structure: WindowStructure { WindowStructure(rawValue: structureRaw) ?? .compact }

    private var shell: ShellContext {
        ShellContext(client: client, canvas: canvas, floors: floors, usage: usage, workspaceName: workspaceName,
                     usageOpen: $usageOpen, newTerminal: { sheet = .newTerminal(nil) }, openPanel: { sheet = .openPanel(nil) },
                     fit: { canvas.fitAll(viewport: viewport) }, openPalette: { paletteOpen = true },
                     partituras: partituras, openPartituras: { sheet = .partituras(nil, $0) })
    }

    /// Each command runs the same closure as its button.
    private var paletteCommands: [PaletteCommand] {
        let s = shell
        return [PaletteCommand(id: "terminal", title: "Novo terminal", run: s.newTerminal),
                PaletteCommand(id: "panel", title: "Abrir painel…", run: s.openPanel),
                PaletteCommand(id: "partitura.apply", title: "Aplicar partitura…", run: { s.openPartituras(nil) }),
                PaletteCommand(id: "partitura.save", title: "Salvar canvas como partitura…", run: { sheet = .savePartitura }),
                PaletteCommand(id: "floor.new", title: "Novo andar…", run: floors.newFloor),
                PaletteCommand(id: "floor.ground", title: "Ir para o Térreo", run: { floors.select(nil) })]
            + client.floors.map { f in PaletteCommand(id: "floor.\(f.id)", title: "Ir para o andar \(f.name)", run: { floors.select(f.id) }) }
            + (client.floors.first { $0.id == client.currentFloor }.map(floors.commands) ?? [])
            + [PaletteCommand(id: "fit", title: "Ajustar à tela", run: s.fit),
               PaletteCommand(id: "usage", title: "Uso dos agentes", run: { usageOpen = true }),
               PaletteCommand(id: "settings", title: "Preferências…", run: { openSettings() })]
    }

    @ViewBuilder private var banners: some View {
        if let error {
            Text(error).font(.collieUI(13)).foregroundStyle(Color.collieDanger).frame(maxWidth: .infinity, alignment: .leading)
                .banner(Color.collieDanger, fill: Color.collieSurface)
        }
        if staleDaemon { staleBanner }
    }

    var body: some View {
        // Built once: the shell only adds chrome around it, so switching structure keeps the canvas and panels.
        Shell(structure: structure, ctx: shell) {
            DockShell(client: client, store: store) {
                CanvasView(client: client, canvas: canvas, root: Config.root, store: store,
                           onNewTerminal: { sheet = .newTerminal($0) }, onOpenPanel: { sheet = .openPanel($0) },
                           onEdit: { sheet = .edit($0) },
                           onApplyPartitura: { sheet = .partituras($0, nil) }, onSavePartitura: { sheet = .savePartitura })
                .onGeometryChange(for: CGSize.self, of: \.size) { viewport = $0 }
                .overlay(alignment: .top) { CanvasChrome(structure: structure, ctx: shell) { banners } }
            }
        }
        .floorDialogs(floors)
        .sheet(isPresented: $paletteOpen, onDismiss: { paletteRun?.run(); paletteRun = nil }) {
            CommandPalette(commands: paletteCommands) { paletteRun = $0; paletteOpen = false }
        }
        .task(id: client.state == .connected) { if client.state == .connected { await usage.poll(client) } }
        .task(id: client.workspaceId) {
            guard let id = client.workspaceId else { return }
            workspaceName = try? await WorkspaceStore(paths: Paths(root: Config.root)).load(id).name
        }
        .task { bundledBuild = await Task.detached { BuildID.of(URL(fileURLWithPath: Config.collied)) }.value }
        .onChange(of: client.floors) { _, fs in   // the current floor was deleted (here or by a Maestro)
            if client.state == .connected, let c = client.currentFloor, !fs.contains(where: { $0.id == c }) {
                client.currentFloor = nil
                UserDefaults.standard.set("", forKey: FloorActions.currentKey)
            }
        }
        .onChange(of: client.state) { _, s in
            if s == .connected { error = nil; store.sessionStarted(client.panels) }   // snapshot is mirrored before `.connected`
        }   // stale install error
        .sheet(item: $sheet) { k in
            switch k {
            case .newTerminal(let p): TerminalSheet(client: client, canvas: canvas, mode: .create(at: p))
            case .edit(let id):
                if let t = client.terminals.first(where: { $0.id == id }) { TerminalSheet(client: client, canvas: canvas, mode: .edit(t)) }
                else { Color.clear.onAppear { sheet = nil } }   // the terminal is gone: nothing to edit
            case .openPanel(let p): OpenPanelSheet(client: client, canvas: canvas, at: p)
            case .partituras(let p, let s):
                PartiturasSheet(model: partituras, client: client, canvas: canvas, anchor: p ?? canvas.toCanvas(CGPoint(x: 40, y: 40)), initial: s)
            case .savePartitura: SavePartituraSheet(model: partituras, client: client, canvas: canvas)
            }
        }
        .onChange(of: partiturasOpen) { _, open in if open { partiturasOpen = false; sheet = .partituras(nil, nil) } }
        .onChange(of: client.panels) { _, ps in store.sync(ps) }   // views of closed panels are released
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.closeAll() }
        .onAppear {
            client.panelHandler = { [store] panel, command, args, timeout throws(ProtocolError) in
                if panel == HostTarget.importer {
                    return try await HTMLSnapshotter.handle(command: command, args: args, artifactsRoot: Config.root.appendingPathComponent("artifacts"),
                                                            timeoutSeconds: timeout)
                }
                return try await store.dispatch(panel, command, args)
            }
            client.pluginEventHandler = { [store] panel, name, payload in store.deliver(panel: panel, event: name, payload: payload) }
            client.onAttention = { [notifier, client] id, why in
                notifier.notify(id, name: client.terminals.first { $0.id == id }?.name ?? "Terminal", reason: why)
            }
            client.onPartituraApplied = { [canvas, partituras, floors] by, anchor, frames, floor in
                let rel = Dictionary(frames.compactMap { k, f in UUID(uuidString: k).map { ($0, CGRect(x: f.x, y: f.y, width: f.w, height: f.h)) } },
                                     uniquingKeysWith: { a, _ in a })
                let corner = canvas.toCanvas(CGPoint(x: 40, y: 40))
                // a Maestro's: to the right of the Maestro (it stays put); the app's: at the clicked point
                let placed = if let by, let m = canvas.frames[anchor ?? by] { placeFrames(rel, rightOf: m, skipping: anchor) }
                             else { placeFrames(rel.filter { $0.key != anchor }, anchor: by == nil ? partituras.takeAnchor() ?? corner : corner) }
                for (id, r) in placed { canvas.setFrame(r, for: id) }   // the model only; views follow (layout.json too)
                if by == nil, let floor { floors.select(floor) }   // the app's apply made a floor: show it
            }
            client.onNotify = { [notifier, client] id, message in
                notifier.notify(id, title: client.terminals.first { $0.id == id }?.name ?? "Maestro", body: message)
            }
            if let s = UserDefaults.standard.string(forKey: FloorActions.currentKey), let id = UUID(uuidString: s) { client.currentFloor = id }
            notifier.onFocus = { [canvas, client, floors] id in
                // a node on another floor: switch to its floor first
                if let t = client.terminals.first(where: { $0.id == id }), t.floorId != client.currentFloor {
                    floors.select(t.floorId)
                }
                guard let f = canvas.frames[id] else { return }
                canvas.offset = CGPoint(x: f.midX - viewport.width / canvas.zoom / 2, y: f.midY - viewport.height / canvas.zoom / 2)
                canvas.selection = [id]
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

/// Spec §6.3 (reduced): the app's resident memory and the open panels per plug-in. Per-webview RAM has no public
/// API (WebKit renders in separate WebContent processes), so it is not shown.
struct PanelMeter: View {
    let client: DaemonClient

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let counts = Dictionary(grouping: client.panels, by: \.pluginId).map { "\($0.key) \($0.value.count)" }.sorted()
            Text(([Self.rss()] + counts).joined(separator: " · ")).monospacedDigit()
                .help("RSS do app e painéis abertos por plug-in. A RAM de cada webview não tem API pública (processo WebContent do WebKit).")
        }
    }

    private static func rss() -> String {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? "\(info.resident_size / 1_048_576) MB" : "? MB"
    }
}

/// Arquivo ▸ Exportar / Importar dados do Collie (`admin.data.export` / `admin.data.import`, app only). An import is
/// applied by collied at its next start, so the app restarts the service once the user has agreed to it.
@MainActor enum DataBackupMenu {
    private static let type = UTType(filenameExtension: "colliebackup") ?? .data   // ponytail: not declared in Info.plist; filters by extension
    private static let legacyType = UTType(filenameExtension: "orqbackup") ?? .data   // Orq backups still open
    private static let timeout: Double = 900

    static func export(_ client: DaemonClient) {
        guard confirm("Exportar os dados do Collie?",
                      "Designs, design systems, artifacts, memória global, workspaces e o registro de trabalho vão para um único arquivo. "
                      + "Os painéis Design vão reconectar. O arquivo contém os links secretos dos seus arquivos de design: guarde como guardaria uma senha.",
                      "Exportar") else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [type]
        let day = Date().formatted(.iso8601.year().month().day())
        p.nameFieldStringValue = "Collie-\(day).colliebackup"
        guard p.runModal() == .OK, let url = p.url else { return }
        Task {
            do {
                _ = try await client.adminCall("admin.data.export", ["out": .string(url.path)], timeout: timeout)
                tell("Dados exportados", url.path)
            } catch { tell("Falha ao exportar", (error as? ProtocolError)?.message ?? "\(error)") }
        }
    }

    static func `import`(_ client: DaemonClient) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [type, legacyType]; p.allowsMultipleSelection = false; p.canChooseDirectories = false
        guard p.runModal() == .OK, let url = p.url else { return }
        Task {
            do {
                let r = try await client.adminCall("admin.data.import", ["from": .string(url.path), "dryRun": .bool(true)], timeout: timeout)
                func n(_ k: String) -> Int { if case .object(let o) = r, case .number(let v)? = o[k] { return Int(v) }; return 0 }
                guard confirm("Importar \(n("designs")) arquivos de design, \(n("systems")) design systems e \(n("artifacts")) artifacts?",
                              "Os dados atuais do Collie vão para uma pasta .replaced-… (nada é apagado) e os do backup tomam o lugar. "
                              + "O serviço vai reiniciar e os terminais abertos vão fechar.",
                              "Importar e reiniciar") else { return }
                _ = try await client.adminCall("admin.data.import", ["from": .string(url.path)], timeout: timeout)
                let err = await Task.detached { () -> String? in
                    do { try DaemonLauncher.restart(label: Config.label); return nil } catch { return "\(error)" }
                }.value
                if let err { tell("Importado; reinicie o serviço para aplicar", err) }
            } catch { tell("Falha ao importar", (error as? ProtocolError)?.message ?? "\(error)") }
        }
    }

    private static func confirm(_ title: String, _ text: String, _ ok: String) -> Bool {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        a.addButton(withTitle: ok); a.addButton(withTitle: "Cancelar")
        return a.runModal() == .alertFirstButtonReturn
    }
    private static func tell(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }
}

private extension View {
    /// A banner card under the top bar: `fill` with a 1 pt `edge` border.
    func banner(_ edge: Color, fill: Color) -> some View {
        padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(edge, lineWidth: 1))
    }
}
