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
        return tr("Mova o Collie.app para /Applications: em ~/Documents, ~/Desktop ou ~/Downloads o serviço (collied) trava na permissão de pastas do macOS.", "Move Collie.app to /Applications: in ~/Documents, ~/Desktop or ~/Downloads the service (collied) hangs on the macOS folder permission.")
    }
    static let consentKey = "daemonConsent"
}

@main struct CollieApp: App {
    @State private var client = DaemonClient(paths: Paths(root: Config.root))
    @State private var canvas = CanvasState()
    @State private var consented: Bool
    @State private var error: String?
    @State private var paletteOpen = false
    @State private var herdsOpen = false
    /// The Preferências sheet. Here, not in `ContentView`: ⌘, with the main window closed sets it and the window
    /// reopens with the sheet up.
    @State private var preferencesOpen = false
    @AppStorage(AppearanceKeys.theme) private var theme = ThemeSelection.dark.rawValue
    /// Bumped on every theme swap and set on the roots as an environment value: SwiftUI views that read it are
    /// evaluated again and resolve their dynamic colors anew. The roots' `id` stays (a new one would recreate the terminals).
    @State private var themeRevision = 0

    init() { Self.migrateDefaults(from: Self.legacyDefaultsDomain, into: .standard); Self.renameDefaults(in: .standard)
             Self.migrateStructure(.standard)
             L10n.set(Lang.resolve(.parse(UserDefaults.standard.string(forKey: AppearanceKeys.language))))   // before any view
             _consented = State(initialValue: UserDefaults.standard.bool(forKey: Config.consentKey))   // after the migration
             PluginViews.register("browser", BrowserPanel.self); PluginViews.register("memory", MemoryPanel.self)
             PluginViews.register("device", DevicePanel.self); PluginViews.register("design", DesignPanel.self)
             PluginViews.register("network", NetworkPanel.self)
             PluginViews.register("diagram", DiagramPanel.self); PluginViews.register("preview", PreviewPanel.self)
             PluginViews.register("designsystems", DesignSystemsPanel.self)
             PluginViews.register("artifacts", ArtifactsPanel.self); PluginViews.register("work", WorkPanel.self)   // before any panel view is made
             ThemeGalleryModel.shared.start()   // before the first window: the saved theme is on screen from the start
             #if DEBUG
             // Unbundled `.build/debug/CollieApp` from a shell: no Dock icon and the window stays behind; make it a regular app.
             if Bundle.main.bundleIdentifier == nil {
                 NSApplication.shared.setActivationPolicy(.regular)
                 DispatchQueue.main.async { NSApp.activate() }
             }
             #endif
           }

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

    /// Preference keys from before the herding vocabulary → their names now.
    static let renamedKeys = ["floor.current": PaddockActions.currentKey, "floor.repo": PaddockActions.repoKey,
                              "partitura.cwd": HerdsSheet.cwdKey, "new.maestro": "new.shepherd"]
    /// The sidebar's collapsed state (⌘\), the single structure's only memory of Compacta.
    static let sidebarCollapsedKey = "sidebar.collapsed"
    /// The old Completa/Compacta choice (removed in L3).
    static let legacyStructureKey = "appearance.structure"
    /// Compacta saved → the sidebar starts collapsed (it plays Compacta's part); the old key is read once and removed.
    static func migrateStructure(_ d: UserDefaults) {
        guard let old = d.string(forKey: legacyStructureKey) else { return }
        if old == "compact" { d.set(true, forKey: sidebarCollapsedKey) }
        d.removeObject(forKey: legacyStructureKey)
    }

    /// Each old key's value under its new name, unless that one is set (the old key stays). Runs on every start.
    static func renameDefaults(in d: UserDefaults) {
        for (old, new) in renamedKeys where d.object(forKey: new) == nil {
            if let v = d.object(forKey: old) { d.set(v, forKey: new) }
        }
    }

    var body: some Scene {
        Window("Collie", id: "main") {
            ContentView(client: client, canvas: canvas, error: $error, paletteOpen: $paletteOpen, herdsOpen: $herdsOpen,
                        preferencesOpen: $preferencesOpen)
                .sheet(isPresented: .constant(!consented)) { consentSheet }
                .task(id: consented) { if consented { startService() } }
                .onAppear { ThemeGalleryModel.shared.reapply() }   // NSApp did not exist at init
                .onChange(of: theme) { ThemeGalleryModel.shared.sync() }
                .environment(\.collieThemeRevision, themeRevision)
                .onReceive(NotificationCenter.default.publisher(for: .collieThemeChanged)) { _ in themeRevision += 1 }
        }
        .windowStyle(.hiddenTitleBar)   // no title bar band; the traffic lights stay, over the content (the sidebar/bar are inset)
        .commands {
            // in place of the standard Ajustes… item, which always opens the Ajustes window
            CommandGroup(replacing: .appSettings) { PreferencesMenuItem(open: $preferencesOpen) }
            CommandGroup(after: .newItem) {
                Divider()
                Button(tr("Exportar dados do Collie…", "Export Collie data…")) { DataBackupMenu.export(client) }
                Button(tr("Importar dados do Collie…", "Import Collie data…")) { DataBackupMenu.import(client) }
            }
            CommandGroup(before: .toolbar) {   // ⌘K: no other menu item, nor the terminal (it takes no ⌘ keys), uses it
                // over any sheet or dialog (consent, panels' own, alerts) ⌘K is dropped: it would pop up once that one closes
                Button(tr("Comandos…", "Commands…")) { if !NSApp.windows.contains(where: { $0.isSheet && $0.isVisible }) { paletteOpen = true } }.keyboardShortcut("k")
                Divider()
            }
            CommandMenu("Canvas") {
                Button(tr("Rebanhos…", "Herds…")) { if !NSApp.windows.contains(where: { $0.isSheet && $0.isVisible }) { herdsOpen = true } }
            }
            CommandGroup(after: .appTermination) {
                Button(tr("Parar serviço", "Stop service")) { stopService() }
            }
        }
    }

    /// Built-in choice: the built-in palettes and today's appearance. Custom: the palette of `theme.extends` becomes
    /// `theme.palette` (the other side stays built-in) and the app appearance becomes that side. A custom choice
    /// without a loaded theme applies dark. Then everything on screen is told to resolve its colors again.
    static func applyTheme(selection: ThemeSelection, theme: ThemeFile?) {
        switch (selection, theme) {
        case (.custom, let t?):
            if t.extends == .dark { ActivePalette.set(dark: t.palette, light: Palette.light) }
            else { ActivePalette.set(dark: Palette.dark, light: t.palette) }
            NSApp?.appearance = NSAppearance(named: t.extends == .dark ? .darkAqua : .aqua)
        default:
            ActivePalette.reset()
            NSApp?.appearance = selection.appearance
        }
        redrawAllWindows()
    }

    /// No appearance round trip (it flashes). The notification reaches the views that keep fixed colors (terminals,
    /// node chrome, plug-in pages) and the SwiftUI roots; the walk marks every view for display and runs
    /// `viewDidChangeEffectiveAppearance` by hand, where views set `CALayer` colors from it.
    private static func redrawAllWindows() {
        NotificationCenter.default.post(name: .collieThemeChanged, object: nil)
        for w in NSApp?.windows ?? [] { if let v = w.contentView { redraw(v) } }
    }

    private static func redraw(_ v: NSView) {
        v.viewDidChangeEffectiveAppearance()
        v.needsDisplay = true
        for sub in v.subviews { redraw(sub) }
    }

    private var consentSheet: some View {
        VStack(spacing: 16) {
            Text(tr("O Collie vai instalar um serviço em segundo plano (collied) que mantém seus terminais vivos mesmo com o app fechado.", "Collie will install a background service (collied) that keeps your terminals alive even with the app closed."))
                .font(.collieUI(14)).foregroundStyle(Color.collieText).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(tr("Sair", "Quit")) { NSApplication.shared.terminate(nil) }.buttonStyle(CollieButtonStyle(.secondary))
                Button(tr("Continuar", "Continue")) {
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
                guard FileManager.default.isExecutableFile(atPath: Config.collied) else { return tr("collied não encontrado em \(Config.collied)", "collied not found at \(Config.collied)") }
                do { try DaemonLauncher.ensureRunning(colliedPath: Config.collied, root: Config.root, label: Config.label); return nil }
                catch { return tr("Falha ao iniciar o serviço: \(error)", "Failed to start the service: \(error)") }
            }.value
            error = err
            client.start()   // also reconnects to an already-running daemon when install failed
        }
    }

    private func stopService() {
        Task {
            error = await Task.detached { () -> String? in
                do { try DaemonLauncher.stop(label: Config.label); return nil }
                catch { return tr("Falha ao parar o serviço: \(error)", "Failed to stop the service: \(error)") }
            }.value
        }
    }
}

/// The app menu's "Preferências…" (⌘,): the sheet over the main window, which comes back (or forward) if closed.
/// Over another sheet or dialog it is dropped, like ⌘K: it would pop up once that one closes.
private struct PreferencesMenuItem: View {
    @Binding var open: Bool
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(tr("Preferências…", "Preferences…")) {
            guard !NSApp.windows.contains(where: { $0.isSheet && $0.isVisible }) else { return }
            open = true
            openWindow(id: "main")
        }
        .keyboardShortcut(",")
    }
}

/// Runs `settle` when what decides the Pasto's visibility changes (own modifier: `ContentView.body` is at the type-checker's limit).
private struct PastoWatch: ViewModifier {
    let client: DaemonClient
    let settle: () -> Void
    func body(content: Content) -> some View {
        content
            .onChange(of: client.terminals) { settle() }
            .onChange(of: client.panels) { settle() }
            .onChange(of: client.paddocks) { settle() }
            .onChange(of: client.state) { settle() }
    }
}

struct ContentView: View {
    let client: DaemonClient
    let canvas: CanvasState
    @Binding var error: String?
    @State private var historyOpener: HistoryOpener?
    @Binding var paletteOpen: Bool
    @Binding var herdsOpen: Bool
    @AppStorage(CollieApp.sidebarCollapsedKey) private var sidebarCollapsed = false
    @Environment(\.collieThemeRevision) private var themeRevision
    @Binding var preferencesOpen: Bool
    /// The page last shown in the sheet: it is unmounted on close, so reopening would otherwise restart on the first page.
    @State private var preferencesPage = PreferencePage.aparencia
    @State private var paddocks: PaddockActions
    @State private var usage = UsageFeed()
    @State private var paletteRun: PaletteCommand?   // run once the palette sheet is gone
    @State private var viewport = CGSize(width: 800, height: 600)
    /// `nil` position = from the window chrome or the palette (placed automatically); otherwise a canvas point from a right-click.
    enum SheetKind: Identifiable {
        case newTerminal(CGPoint?), edit(UUID), openPanel(CGPoint?)
        /// Apply: the canvas point (nil: the visible area's corner) and the herd selected first.
        case herds(CGPoint?, String?), saveHerd
        /// "O que o Collie faz", and the panel sheet with that plug-in selected (a tour button).
        case tour, openPanelFor(String)
        /// M8.3: the Laços modal on that tab.
        case loops(LoopsTab)
        /// ⌘K's Lotes… and Fábrica… (the sidebar ⋯ menu's, for the current paddock).
        case lots, factory(UUID)
        var id: String {
            switch self {
            case .tour: "tour"
            case .loops: "loops"
            case .lots: "lots"
            case .factory(let p): "factory \(p)"
            case .openPanelFor(let p): "panel for \(p)"
            case .herds(let p, let s): "herds \(String(describing: p)) \(s ?? "")"
            case .saveHerd: "save herd"
            case .newTerminal(let p): "new \(String(describing: p))"
            case .edit(let i): "edit \(i)"
            case .openPanel(let p): "panel \(String(describing: p))"
            }
        }
    }
    @State private var sheet: SheetKind?
    @State private var store: PanelViewStore
    @StateObject private var herds: HerdsModel
    @State private var usageOpen = false
    @State private var tour = FeatureTourSeen()
    /// The tour's button, kept until its sheet is gone (`runTourAction`).
    @State private var tourAction: FeatureTour.Action?
    /// Preferências › Aparência's "Tour das funções": the tour opens once that sheet is gone (two sheets cannot stack here).
    @State private var tourAfterPreferences = false
    @State private var bundledBuild: String?
    @State private var staleDismissed = false
    private var staleDaemon: Bool {
        client.state == .connected && !staleDismissed && DaemonLauncher.isStale(daemonBuild: client.daemonBuild, bundledBuild: bundledBuild)
    }
    private let notifier = Notifier.shared

    init(client: DaemonClient, canvas: CanvasState, error: Binding<String?>, paletteOpen: Binding<Bool>, herdsOpen: Binding<Bool>,
         preferencesOpen: Binding<Bool>) {
        self.client = client; self.canvas = canvas; _error = error; _paletteOpen = paletteOpen; _herdsOpen = herdsOpen
        _preferencesOpen = preferencesOpen
        _herds = StateObject(wrappedValue: HerdsModel(call: { cmd, args throws(ProtocolError) in try await client.adminCall(cmd, args) },
                                                                nodeName: { client.nodeName($0) }))
        _paddocks = State(initialValue: PaddockActions(client: client))
        _store = State(initialValue: PanelViewStore(panels: { client.panels }, context: { panel in
            PanelHostContext(panel: panel, root: Config.root, workspaceId: client.workspaceId,
                             call: { cmd, args throws(ProtocolError) in try await client.adminCall(cmd, args) },
                             emit: { name, payload in Task { @MainActor in client.emit(panel: panel.id, name: name, payload: payload) } },
                             openStream: { cmd, args throws(ProtocolError) in try await client.openAdminStream(cmd, args) })
        }))
    }

    private var staleBanner: some View {
        HStack(spacing: 10) {
            Text(tr("O serviço do Collie está desatualizado (versão anterior ainda rodando). Reiniciar agora? Os terminais abertos serão encerrados.", "Collie's service is out of date (a previous version is still running). Restart now? Open terminals will be closed."))
                .font(.collieUI(13)).foregroundStyle(Color.collieText).fixedSize(horizontal: false, vertical: true)
            Button(tr("Reiniciar serviço", "Restart service")) {
                Task {
                    error = await Task.detached { () -> String? in
                        do { try DaemonLauncher.restart(label: Config.label); return nil }
                        catch { return tr("Falha ao reiniciar o serviço: \(error)", "Failed to restart the service: \(error)") }
                    }.value
                }
            }
            .buttonStyle(CollieButtonStyle(.attention))
            Button(tr("Depois", "Later")) { staleDismissed = true }.buttonStyle(CollieButtonStyle(.quiet))
        }.banner(Color.collieAttention, fill: Color.collieAttentionTint)
    }

    /// The sidebar hides the Pasto while it is empty (it is not a paddock): leave it for the first paddock. Only once
    /// connected, when the snapshot (terminals, panels) is already mirrored.
    private func settlePasto() {
        guard client.state == .connected else { return }
        let has = SidebarModel.pastoHasContent(terminals: client.terminals, panels: client.panels)
        if let id = SidebarModel.fallbackPaddock(paddocks: client.paddocks, current: client.currentPaddock, pastoHasContent: has) { paddocks.select(id) }
    }

    /// The opt-in daily notification: every 10 minutes, at most one a day (`MemoryDigestNotice`); never throws.
    private func dailyDigestLoop() async {
        let d = UserDefaults.standard
        while !Task.isCancelled {
            if d.bool(forKey: MemoryDigestNotice.defaultsKey), Calendar.current.component(.hour, from: Date()) >= MemoryDigestNotice.hour {
                let start = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: Date()))
                struct Digest: Decodable { var entries: [DigestRow] }
                if let v = try? await client.adminCall("memory.digest", ["since": .string(start)]), let data = try? JSONEncoder().encode(v) {
                    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
                    let last = d.object(forKey: MemoryDigestNotice.lastPostedKey) as? Date
                    if let dg = try? dec.decode(Digest.self, from: data),
                       let text = MemoryDigestNotice.message(enabled: true, items: MemoryDigestNotice.items(dg.entries), now: Date(), lastPosted: last) {
                        notifier.notify(UUID(), title: tr("Memória", "Memory"), body: text)
                        d.set(Date(), forKey: MemoryDigestNotice.lastPostedKey)
                    }
                }
            }
            try? await Task.sleep(for: .seconds(600))
        }
    }

    private var shell: ShellContext {
        ShellContext(client: client, canvas: canvas, paddocks: paddocks, usage: usage,
                     usageOpen: $usageOpen, newTerminal: { sheet = .newTerminal(nil) }, openPanel: { sheet = .openPanel(nil) },
                     fit: { canvas.fitAll(viewport: viewport) }, openPalette: { paletteOpen = true },
                     herds: herds, openHerds: { sheet = .herds(nil, $0) },
                     focus: { notifier.onFocus?($0) }, edit: { sheet = .edit($0) }, openPreferences: openPreferences,
                     tour: tour, openTour: { sheet = .tour }, openWork: { showPanel("work") },
                     onOpenHistory: { id in
                         if historyOpener == nil { historyOpener = .live(client: client, focus: { notifier.onFocus?($0) }) }
                         await historyOpener?.show(id) },
                     historyNotice: { historyOpener?.message }, onOpenLoops: { sheet = .loops($0) },
                     fetchHistory: { [client] in try await HistoryOpener.archive($0, client: client) },
                     zoom: { [canvas, viewport] in canvas.zoom(by: $0, around: CGPoint(x: viewport.width / 2, y: viewport.height / 2)) })
    }

    /// The tour's button, once the tour sheet has closed: the same entries as the sidebar, the palette and the menus.
    private func runTourAction() {
        guard let action = tourAction else { return }
        tourAction = nil
        switch action {
        case .newTerminal: sheet = .newTerminal(nil)
        case .newPaddock: paddocks.newPaddock()
        case .openPalette: paletteOpen = true
        case .openHerds: sheet = .herds(nil, nil)
        case .openLoops: sheet = .loops(.history)
        case .preferences(let page): openPreferences(on: page)
        case .panel(let id): showPanel(id)
        }
    }

    /// An open panel of that plug-in is brought forward; else the plug-in opens in its default place. Dispositivo and Design
    /// need a choice (the device, the file), so they open the panel sheet with that plug-in selected.
    private func showPanel(_ id: String) {
        if let p = client.panels.first(where: { $0.pluginId == id }) {
            NotificationCenter.default.post(name: .collieFocusPanel, object: p.id)   // its dock tab
            notifier.onFocus?(p.id)   // a canvas panel: centered
            return
        }
        guard let spec = PluginRegistry.spec(id) else { return }
        if id == "device" || id == "design" { sheet = .openPanelFor(id); return }
        Task {
            do { _ = try await client.openPanel(plugin: id, name: nil, placement: spec.defaultPlacement, url: nil, storage: .isolated) }
            catch { self.error = "\(error)" }
        }
    }

    /// Every way into Preferências (the palette, the sidebar's foot, the tour, `collieOpenPreferences`) comes through
    /// here; ⌘, sets the same flag (`PreferencesMenuItem`). The sheet sits over the canvas, which stays mounted.
    func openPreferences() { preferencesOpen = true }

    /// Each command runs the same closure as its button.
    private var paletteCommands: [PaletteCommand] {
        let s = shell
        return [PaletteCommand(id: "terminal", title: tr("Novo terminal", "New terminal"), run: s.newTerminal),
                PaletteCommand(id: "panel", title: tr("Abrir painel…", "Open panel…"), run: s.openPanel),
                PaletteCommand(id: "herd.save", title: tr("Salvar canvas como rebanho…", "Save canvas as herd…"), run: { sheet = .saveHerd }),
                PaletteCommand(id: "paddock.new", title: tr("Novo cercado…", "New paddock…"), run: paddocks.newPaddock),
                PaletteCommand(id: "paddock.pasture", title: tr("Ir para o Pasto", "Go to the Pasture"), run: { paddocks.select(nil) })]
            + client.paddocks.map { f in PaletteCommand(id: "paddock.\(f.id)", title: tr("Ir para o cercado \(f.name)", "Go to paddock \(f.name)"), run: { paddocks.select(f.id) }) }
            + (client.paddocks.first { $0.id == client.currentPaddock }.map(paddocks.commands) ?? [])
            + [PaletteCommand(id: "fit", title: tr("Ajustar à tela", "Fit to screen"), run: s.fit),
               PaletteCommand(id: "usage", title: tr("Uso dos agentes", "Agent usage"), run: { usageOpen = true }),
               PaletteCommand(id: "settings", title: tr("Preferências…", "Preferences…"), run: openPreferences)]
            + PaletteEntry.commands(PaletteEntry.allCases.filter { $0 != .factory || factoryPaddock != nil }) { e in
                switch e {
                case .herds: { s.openHerds(nil) }
                case .lots: { sheet = .lots }
                case .factory: { if let p = factoryPaddock { sheet = .factory(p) } }
                case .memory: { showPanel("memory") }
                case .loops: { s.onOpenLoops(.history) }
                case .work: s.openWork
                case .tour: s.openTour
                case .diagnostics: { openPreferences(on: .diagnostico) }
                }
            }
    }

    /// The current paddock when it can be a factory one (a git paddock: the Pasture and folders cannot).
    private var factoryPaddock: UUID? {
        client.paddocks.first { $0.id == client.currentPaddock && !$0.isFolder }?.id
    }

    /// Preferências on `page` (through the defaults mailbox `PreferencesView` reads).
    private func openPreferences(on page: PreferencePage) {
        UserDefaults.standard.set(page.rawValue, forKey: PreferencePage.requestKey)
        openPreferences()
    }

    @ViewBuilder private var banners: some View {
        if let error {
            Text(error).font(.collieUI(13)).foregroundStyle(Color.collieDanger).frame(maxWidth: .infinity, alignment: .leading)
                .banner(Color.collieDanger, fill: Color.collieSurface)
        }
        if staleDaemon { staleBanner }
    }

    var body: some View {
        let _ = themeRevision   // a theme swap evaluates this root again (its id stays, so nothing is recreated)
        // Built once: the shell only adds the sidebar beside it, so collapsing it or opening Preferências keeps the canvas.
        Shell(ctx: shell, collapsed: $sidebarCollapsed) {
            DockShell(client: client, store: store) {
                CanvasView(client: client, canvas: canvas, root: Config.root, store: store,
                           onNewTerminal: { sheet = .newTerminal($0) }, onOpenPanel: { sheet = .openPanel($0) },
                           onEdit: { sheet = .edit($0) },
                           onApplyHerd: { sheet = .herds($0, nil) }, onSaveHerd: { sheet = .saveHerd },
                           active: !preferencesOpen)
                .onGeometryChange(for: CGSize.self, of: \.size) { viewport = $0 }
                .overlay {
                    if FirstRun.shows(connected: client.state == .connected, terminals: client.terminals, current: client.currentPaddock) {
                        FirstRunView(ctx: shell)
                    }
                }
                .overlay(alignment: .top) { CanvasChrome(ctx: shell) { banners } }
            }
        }
        .sheet(isPresented: $preferencesOpen, onDismiss: { if tourAfterPreferences { tourAfterPreferences = false; sheet = .tour } }) {
            PreferencesView(client: client, remembered: $preferencesPage, openTour: { tourAfterPreferences = true; preferencesOpen = false }) {
                preferencesOpen = false
            }
                .frame(minWidth: 680, idealWidth: 860, maxWidth: .infinity, minHeight: 480, idealHeight: 620, maxHeight: .infinity)
        }
        .paddockDialogs(paddocks)
        .sheet(isPresented: $paletteOpen, onDismiss: { paletteRun?.run(); paletteRun = nil }) {
            CommandPalette(commands: paletteCommands) { paletteRun = $0; paletteOpen = false }
        }
        .task(id: client.state == .connected) { if client.state == .connected { _ = await LanguagePreference.sync(client) } }
        .task(id: client.state == .connected) { if client.state == .connected { await usage.poll(client) } }
        .task { bundledBuild = await Task.detached { BuildID.of(URL(fileURLWithPath: Config.collied)) }.value }
        .task(id: client.state == .connected) { if client.state == .connected { await dailyDigestLoop() } }
        .onChange(of: client.paddocks) { _, fs in   // the current paddock was deleted (here or by a Shepherd)
            if client.state == .connected, let c = client.currentPaddock, !fs.contains(where: { $0.id == c }) {
                client.currentPaddock = nil
                UserDefaults.standard.set("", forKey: PaddockActions.currentKey)
            }
        }
        .modifier(PastoWatch(client: client, settle: settlePasto))
        .onChange(of: client.state) { _, s in
            if s == .connected { error = nil; store.sessionStarted(client.panels) }   // snapshot is mirrored before `.connected`
        }   // stale install error
        .sheet(item: $sheet, onDismiss: runTourAction) { k in
            switch k {
            case .newTerminal(let p): TerminalSheet(client: client, canvas: canvas, mode: .create(at: p))
            case .edit(let id):
                if let t = client.terminals.first(where: { $0.id == id }) { TerminalSheet(client: client, canvas: canvas, mode: .edit(t)) }
                else { Color.clear.onAppear { sheet = nil } }   // the terminal is gone: nothing to edit
            case .openPanel(let p): OpenPanelSheet(client: client, canvas: canvas, at: p)
            case .openPanelFor(let id): OpenPanelSheet(client: client, canvas: canvas, initial: id)
            case .tour: FeatureTourView(store: tour) { tourAction = $0 }
            case .loops(let tab): LoopsSheet(ctx: shell, initial: tab)
            case .lots: LotsSheet(client: client) { sheet = nil }
            case .factory(let id):
                if let p = client.paddocks.first(where: { $0.id == id }) {
                    VStack(alignment: .trailing, spacing: 12) {
                        FactoryControls(paddock: p, actions: paddocks)
                        Button(tr("Fechar", "Close")) { sheet = nil }.keyboardShortcut(.cancelAction)
                    }
                    .padding(18).frame(width: 320)
                } else { Color.clear.onAppear { sheet = nil } }   // the paddock is gone
            case .herds(let p, let s):
                HerdsSheet(model: herds, client: client, canvas: canvas, anchor: p ?? canvas.toCanvas(CGPoint(x: 40, y: 40)), initial: s)
            case .saveHerd: SaveHerdSheet(model: herds, client: client, canvas: canvas)
            }
        }
        .onChange(of: herdsOpen) { _, open in if open { herdsOpen = false; sheet = .herds(nil, nil) } }
        .modifier(PairingConfirmHost(client: client))   // a phone read the pairing QR: the Mac's click (remote API)
        .modifier(DetectionNoticeHost(client: client))   // not admin: explained once
        .modifier(UpdateLaunchHost(client: client, bundledBuild: bundledBuild))   // launch check, notice, "Instalar ao sair"
        .onChange(of: client.panels) { _, ps in store.sync(ps) }   // views of closed panels are released
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.closeAll() }
        // the Design panel's Abrir Preferências (a plug-in has no openSettings): open Preferências on the page it names.
        // The page goes through the defaults mailbox: `PreferencesView` reads it on appear and while shown.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("collieOpenPreferences"))) { n in
            if let p = PreferencePage.requested(n.object) { UserDefaults.standard.set(p.rawValue, forKey: PreferencePage.requestKey) }
            openPreferences()
        }
        .onAppear {
            client.panelHandler = { [store] panel, command, args, timeout throws(ProtocolError) in
                if panel == HostTarget.importer, command.hasPrefix("deck.") {
                    return try await DeckExporter.handle(command: command, args: args, artifactsRoot: Config.root.appendingPathComponent("artifacts"),
                                                         timeoutSeconds: timeout)
                }
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
            client.onHerdApplied = { [canvas, herds, paddocks] by, anchor, frames, paddock in
                let rel = Dictionary(frames.compactMap { k, f in UUID(uuidString: k).map { ($0, CGRect(x: f.x, y: f.y, width: f.w, height: f.h)) } },
                                     uniquingKeysWith: { a, _ in a })
                let corner = canvas.toCanvas(CGPoint(x: 40, y: 40))
                // a Shepherd's: to the right of the Shepherd (it stays put); the app's: at the clicked point
                let placed = if let by, let m = canvas.frames[anchor ?? by] { placeFrames(rel, rightOf: m, skipping: anchor) }
                             else { placeFrames(rel.filter { $0.key != anchor }, anchor: by == nil ? herds.takeAnchor() ?? corner : corner) }
                for (id, r) in placed { canvas.setFrame(r, for: id) }   // the model only; views follow (layout.json too)
                if by == nil, let paddock { paddocks.select(paddock) }   // the app's apply made a paddock: show it
            }
            client.onRemoteReveal = { [notifier, client] terminal, artifact in   // mac.reveal: the view only
                if let terminal { notifier.onFocus?(terminal) }
                if let artifact {
                    let args: [String: JSONValue] = ["plugin": .string("preview"), "artifact": .string(artifact.uuidString.lowercased()), "placement": .string("dock.right")]
                    Task { _ = try? await client.adminCall("panel.open", args) }
                }
            }
            client.onNotify = { [notifier, client] id, message in
                notifier.notify(id, title: client.terminals.first { $0.id == id }?.name ?? "Pastor", body: message)
            }
            if let s = UserDefaults.standard.string(forKey: PaddockActions.currentKey), let id = UUID(uuidString: s) { client.currentPaddock = id }
            client.onAccessCard = { [notifier, client, canvas] d in
                // the strip is enough while the app is frontmost and the node is on screen
                if NSApp.isActive, let t = client.terminals.first(where: { $0.id == d.terminal }), t.paddockId == client.currentPaddock,
                   let f = canvas.frames[d.terminal], f.intersects(CGRect(origin: canvas.offset, size: CGSize(width: viewport.width / canvas.zoom, height: viewport.height / canvas.zoom))) { return }
                notifier.notifyAccess(d, name: client.terminals.first { $0.id == d.terminal }?.name ?? "Terminal")
            }
            client.onConfirmCorrection = { [notifier, client, store] terminal, entry, title in
                let mem = client.panels.first { $0.pluginId == "memory" }
                if let mem { (store.instance(for: mem.id) as? MemoryPanel)?.refresh() }
                notifier.notifyConfirm(terminal: terminal, entry: entry, rule: title, shown: NSApp.isActive && mem.map { store.isShown($0.id) } == true)
            }
            notifier.onConfirm = { [client, store, notifier] _ in
                Task { @MainActor in
                    var id = client.panels.first { $0.pluginId == "memory" }?.id
                    if id == nil { id = try? await client.openPanel(plugin: "memory", name: nil, placement: .dockRight, url: nil, storage: .isolated) }
                    guard let id else { return }
                    NotificationCenter.default.post(name: .collieFocusPanel, object: id)   // its dock tab
                    notifier.onFocus?(id)   // a canvas panel: centered
                    (store.instance(for: id) as? MemoryPanel)?.refresh(learning: true)
                }
            }
            notifier.onFocus = { [canvas, client, paddocks] id in
                if client.accessCards.contains(where: { $0.terminal == id }) { AccessPopoverState.shared.open.insert(id) }   // only with cards: a stale id would pop open later
                // a node on another paddock: switch to its paddock first
                if let t = client.terminals.first(where: { $0.id == id }), t.paddockId != client.currentPaddock {
                    paddocks.select(t.paddockId)
                }
                guard let f = canvas.frames[id] else { return }
                canvas.offset = CGPoint(x: f.midX - viewport.width / canvas.zoom / 2, y: f.midY - viewport.height / canvas.zoom / 2)
                canvas.selection = [id]
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}

/// Arquivo ▸ Exportar / Importar dados do Collie (`admin.data.export` / `admin.data.import`, app only). An import is
/// applied by collied at its next start, so the app restarts the service once the user has agreed to it.
@MainActor enum DataBackupMenu {
    private static let type = UTType(filenameExtension: "colliebackup") ?? .data   // ponytail: not declared in Info.plist; filters by extension
    private static let legacyType = UTType(filenameExtension: "orqbackup") ?? .data   // Orq backups still open
    private static let timeout: Double = 900

    static func export(_ client: DaemonClient) {
        guard confirm(tr("Exportar os dados do Collie?", "Export Collie data?"),
                      tr("Designs, design systems, artifacts, memória global, workspaces e o registro de trabalho vão para um único arquivo. Os painéis Design vão reconectar. O arquivo contém os links secretos dos seus arquivos de design: guarde como guardaria uma senha.",
                         "Designs, design systems, artifacts, global memory, workspaces and the work log go into a single file. Design panels will reconnect. The file contains the secret links to your design files: keep it as you would a password."),
                      tr("Exportar", "Export")) else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [type]
        let day = Date().formatted(.iso8601.year().month().day())
        p.nameFieldStringValue = "Collie-\(day).colliebackup"
        guard p.runModal() == .OK, let url = p.url else { return }
        Task {
            do {
                _ = try await client.adminCall("admin.data.export", ["out": .string(url.path)], timeout: timeout)
                tell(tr("Dados exportados", "Data exported"), url.path)
            } catch { tell(tr("Falha ao exportar", "Export failed"), (error as? ProtocolError)?.message ?? "\(error)") }
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
                guard confirm(tr("Importar \(n("designs")) arquivos de design, \(n("systems")) design systems e \(n("artifacts")) artifacts?",
                                 "Import \(n("designs")) design files, \(n("systems")) design systems and \(n("artifacts")) artifacts?"),
                              tr("Os dados atuais do Collie vão para uma pasta .replaced-… (nada é apagado) e os do backup tomam o lugar. O serviço vai reiniciar e os terminais abertos vão fechar.",
                                 "Collie's current data goes to a .replaced-… folder (nothing is deleted) and the backup's takes its place. The service will restart and open terminals will close."),
                              tr("Importar e reiniciar", "Import and restart")) else { return }
                _ = try await client.adminCall("admin.data.import", ["from": .string(url.path)], timeout: timeout)
                let err = await Task.detached { () -> String? in
                    do { try DaemonLauncher.restart(label: Config.label); return nil } catch { return "\(error)" }
                }.value
                if let err { tell(tr("Importado; reinicie o serviço para aplicar", "Imported; restart the service to apply"), err) }
            } catch { tell(tr("Falha ao importar", "Import failed"), (error as? ProtocolError)?.message ?? "\(error)") }
        }
    }

    private static func confirm(_ title: String, _ text: String, _ ok: String) -> Bool {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        a.addButton(withTitle: ok); a.addButton(withTitle: tr("Cancelar", "Cancel"))
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
