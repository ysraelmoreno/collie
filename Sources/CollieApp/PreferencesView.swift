import SwiftUI
import CollieTheme
import CollieCore
import CollieClient
import CollieProtocol
import ColliePlugins

/// Nine pages in a sidebar with search (`PreferencePage`): Interface, Agentes and Dispositivos (Celular, Android).
extension DesignFirst {
    var label: String { switch self { case .artifact: tr("Página (Prévia)", "Page (Preview)"); case .figcraft: "FigCraft"; case .ask: tr("Perguntar", "Ask") } }
    /// The `design.prefer` reply (`{designFirst}`); nil when it is anything else.
    static func from(reply: JSONValue) -> DesignFirst? {
        guard case .object(let o) = reply, case .string(let v)? = o["designFirst"] else { return nil }
        return DesignFirst.parse(v)
    }
}

extension SandboxMode {
    var label: String { switch self { case .open: tr("Aberto (padrão)", "Open (default)"); case .strict: tr("Estrito", "Strict") } }
    /// The `admin.sandbox` reply (`{mode}`); nil when it is anything else.
    static func from(reply: JSONValue) -> SandboxMode? {
        guard case .object(let o) = reply, case .string(let v)? = o["mode"] else { return nil }
        return SandboxMode(rawValue: v)
    }
}

/// Preferences › Interface › "Idioma": what is stored (`system|pt|en`) and whether a change needs the app restarted.
enum LanguagePreference {
    static func label(_ l: LanguageSetting) -> String {
        switch l { case .system: tr("Sistema", "System"); case .pt: "Português"; case .en: "English" }
    }
    /// The `admin.language` reply (`{language, active}`); nil when it is anything else.
    static func from(reply: JSONValue) -> LanguageSetting? {
        guard case .object(let o) = reply, case .string(let v)? = o["language"] else { return nil }
        return LanguageSetting(rawValue: v)
    }
    /// The app reads its language once, at launch: a choice needs a restart when it resolves to another language than the
    /// one running (pt → en → pt again needs none).
    static func needsRestart(running: Lang, new: LanguageSetting, preferred: [String] = Locale.preferredLanguages) -> Bool {
        Lang.resolve(new, preferred: preferred) != running
    }
    /// On every connection (app level, not only with Preferences open): the app's stored value wins over the daemon's;
    /// with none stored yet, the daemon's is adopted and stored. Returns the value the app now holds; nil: no answer.
    @MainActor static func sync(_ client: DaemonClient) async -> LanguageSetting? {
        guard client.state == .connected, let r = try? await client.adminCall("admin.language", [:]),
              let remote = from(reply: r) else { return nil }
        guard let stored = UserDefaults.standard.string(forKey: AppearanceKeys.language) else {
            UserDefaults.standard.set(remote.rawValue, forKey: AppearanceKeys.language)
            return remote
        }
        let local = LanguageSetting.parse(stored)
        if local != remote { _ = try? await client.adminCall("admin.language", ["language": .string(local.rawValue)]) }
        return local
    }
    /// Opens a new instance of this bundle and quits this one; unbundled (`swift run`) it only quits.
    @MainActor static func relaunch() {
        if Bundle.main.bundleIdentifier != nil {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-n", Bundle.main.bundlePath]
            try? p.run()
        }
        NSApplication.shared.terminate(nil)
    }
}

/// A `font.list` row: downloaded (Google Fonts, removable) or bundled.
struct FontRow: Equatable, Identifiable {
    var family: String
    var downloaded: Bool
    var id: String { family }
    static func rows(_ reply: JSONValue) -> [FontRow] {
        guard case .array(let a) = reply else { return [] }
        return a.compactMap { v in
            guard case .object(let o) = v, case .string(let f)? = o["family"] else { return nil }
            return FontRow(family: f, downloaded: o["source"] == .string("google"))
        }
    }
    /// The `admin.fonts` reply (`{download}`).
    static func download(_ reply: JSONValue) -> Bool? {
        guard case .object(let o) = reply, case .bool(let b)? = o["download"] else { return nil }
        return b
    }
}

struct PreferencesView: View {
    let client: DaemonClient
    /// Completa's tab (`MainViewState.page`): the page survives this view being unmounted. Nil in the Ajustes window.
    var remembered: Binding<PreferencePage>?
    @State private var designFirst = DesignFirst.artifact
    @State private var sandboxMode = SandboxMode.open
    @State private var googleFonts = true
    @State private var loopModel = ""
    @State private var loopModelError: String?
    @State private var fonts: [FontRow] = []
    @State private var newFont = ""
    @State private var fontBusy = false
    @State private var fontError: String?
    @State private var page = PreferencePage.aparencia
    @State private var query = ""
    @State private var androidBadge: String?
    @State private var designBadge: String?
    @State private var updateBadge: String?
    @State private var loopTrustError: String?
    @AppStorage(PreferencePage.requestKey) private var requestedPage = ""
    @AppStorage(AppearanceKeys.theme) private var theme = ThemeSelection.dark.rawValue
    @State private var gallery = ThemeGalleryModel.shared
    /// Read in `body`: a theme swap evaluates this root again and the dynamic colors below resolve anew.
    @Environment(\.collieThemeRevision) private var themeRevision
    @AppStorage(AppearanceKeys.structure) private var structure = WindowStructure.compact.rawValue
    @AppStorage(AppearanceKeys.language) private var language = LanguageSetting.system.rawValue
    @State private var restartNotice = false
    @AppStorage(AppearanceKeys.terminalFamily) private var family = TerminalFontChoice.default.family
    @AppStorage(AppearanceKeys.terminalSize) private var size = Double(TerminalFontChoice.default.size)
    @AppStorage(MemoryDigestNotice.defaultsKey) private var dailyNotification = MemoryDigestNotice.defaultOn
    @AppStorage(Notifier.confirmKey) private var confirmNotification = Notifier.confirmDefaultOn

    private var structures: [(WindowStructure, String, String)] { [
        (.compact, tr("Compacta", "Compact"), tr("canvas + cabeçalho flutuante", "canvas + floating header")),
        (.full, tr("Completa", "Full"), tr("barra lateral, cercados e status", "sidebar, paddocks and status"))] }

    var body: some View {
        let _ = themeRevision
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.collieBorder).frame(width: 1)
            VStack(spacing: 0) {
                PanelHeader(page.title, subtitle: tr("Preferências", "Preferences"))
                ScrollView { pageContent.padding(20).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // free size: the Ajustes scene sets its window's, the main area fills
        .background(Color.collieBackground)
        .onAppear {
            AppearanceSettings.normalize(.standard)
            if let remembered { page = remembered.wrappedValue }   // before the request: a page asked for wins
            showRequestedPage()
        }   // a stale or hand-edited value would leave a picker blank
        .onChange(of: requestedPage) { showRequestedPage() }
        .onChange(of: page) { remembered?.wrappedValue = page }
        .task(id: client.state == .connected) { await loadDesignFirst(); await loadSandboxMode(); await loadFonts(); await syncLanguage() }   // no workspace event: read when shown
        // ponytail: one `android.status` and one `design.engine.status` read every 5 s, only while this window is shown and connected (the task dies with it)
        .task(id: client.state == .connected) {
            while client.state == .connected, !Task.isCancelled {
                let r = try? await client.adminCall("android.status", [:])
                androidBadge = PreferencePage.androidBadge(r.flatMap(AndroidSetupStatus.from))
                let d = try? await client.adminCall("design.engine.status", [:])
                designBadge = PreferencePage.designBadge(d.flatMap(DesignEngineStatus.from))
                let u = try? await client.adminCall("app.update.status", [:])
                updateBadge = UpdateModel.badge(u.flatMap(UpdateStatus.from))
                try? await Task.sleep(for: .seconds(5))
            }
            androidBadge = nil; designBadge = nil; updateBadge = nil   // connection dropped: no stale ↓
        }
        .onChange(of: theme) { gallery.sync() }
        .onChange(of: query) {   // the search hid the open page: show the first match (none: keep it)
            let m = PreferencePage.matching(query)
            if let first = m.first, !m.contains(page) { page = first }
        }
    }

    /// A `collieOpenPreferences` asked for a page (`ContentView`): show it, with the search cleared so it is not hidden.
    private func showRequestedPage() {
        guard let p = PreferencePage(rawValue: requestedPage) else { return }
        query = ""; page = p; requestedPage = ""
    }

    private var sidebar: some View {
        let pages = PreferencePage.matching(query)
        return VStack(alignment: .leading, spacing: 2) {
            TextField(tr("Buscar", "Search"), text: $query).textFieldStyle(.roundedBorder).padding(.bottom, 8)
            ForEach(["Interface", "Agentes", "Dispositivos"], id: \.self) { g in
                let items = pages.filter { $0.group == g }
                if !items.isEmpty {
                    Text(PreferencePage.groupTitle(g).uppercased()).font(.collieMono(10)).foregroundStyle(Color.collieMuted).padding(.top, 10).padding(.horizontal, 8)
                    ForEach(items, id: \.self) { p in sidebarItem(p) }
                }
            }
            if pages.isEmpty { Text(tr("Nada encontrado.", "Nothing found.")).font(.collieMono(12)).foregroundStyle(Color.collieMuted).padding(8) }
            Spacer()
        }
        .padding(12)
        .frame(width: 200)
        .background(Color.collieSidebar)
    }

    private func sidebarItem(_ p: PreferencePage) -> some View {
        Button { page = p } label: {
            HStack(spacing: 8) {
                Text(p.icon).font(.collieMono(12)).foregroundStyle(Color.collieMuted).frame(width: 18)
                Text(p.title).font(.collieUI(13)).foregroundStyle(Color.collieText)
                Spacer()
                if let b = p == .android ? androidBadge : p == .desenho ? designBadge : p == .atualizacoes ? updateBadge : nil {
                    Text(b).font(.collieMono(11, .semibold))
                        .foregroundStyle(b == "!" ? Color.collieDanger : Color.collieAccent)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(page == p ? Color.collieSurface : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// The sections of the old single Aparência page, split per sidebar page (text and bindings unchanged).
    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .aparencia: VStack(alignment: .leading, spacing: 22) { themeSection; structureSection; languageSection }
        case .terminal: VStack(alignment: .leading, spacing: 22) { terminalSection; fontsSection }
        case .atualizacoes: UpdatePreferences(client: client)
        case .desenho: VStack(alignment: .leading, spacing: 22) { DesignEnginePreferences(client: client); designSection; sandboxSection }
        case .lacos: VStack(alignment: .leading, spacing: 22) { loopTrustSection; loopModelSection }
        case .memoria: VStack(alignment: .leading, spacing: 22) { memorySection; CuratorPreferences(client: client); CursorMemoryPreferences(client: client) }
        case .plugins: PluginsPreferences(client: client, openDesign: { page = .desenho })
        case .celular: CelularPreferences(client: client)
        case .android: AndroidPreferences(client: client)
        }
    }

    private var themeSection: some View {
        section(tr("Tema", "Theme")) { ThemeGallery() }
    }

    private var structureSection: some View {
        section(tr("Estrutura", "Layout")) {
            HStack(spacing: 12) {
                ForEach(structures, id: \.0) { s in
                    ChoiceCard(s.1, subtitle: s.2, selected: structure == s.0.rawValue, action: { structure = s.0.rawValue }) {
                        miniature(currentPalette, sidebar: s.0 == .full)
                    }
                }
            }
            Text(tr("Muda só a moldura. Terminais, guias e painéis ficam onde estão.", "Only changes the frame. Terminals, tabs and panels stay where they are."))
                .font(.collieMono(12)).foregroundStyle(Color.collieMuted)
        }
    }

    private var languageSection: some View {
        section(tr("Idioma", "Language")) {
            Picker(tr("Idioma", "Language"), selection: Binding(get: { LanguageSetting.parse(language) }, set: { setLanguage($0) })) {
                ForEach(LanguageSetting.allCases, id: \.self) { Text(LanguagePreference.label($0)).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            Text(tr("Vale para o app, a CLI e os agentes. Terminais já abertos mantêm o idioma anterior.",
                    "Applies to the app, the CLI and the agents. Terminals already open keep the previous language."))
                .font(.collieMono(12)).foregroundStyle(Color.collieMuted)
            if restartNotice {
                Text(tr("O idioma muda depois de reiniciar o Collie.", "The language changes after Collie restarts."))
                    .font(.collieMono(12)).foregroundStyle(Color.collieAttention)
                HStack {
                    Button(tr("Reiniciar agora", "Restart now")) { LanguagePreference.relaunch() }
                    Button(tr("Depois", "Later")) { restartNotice = false }
                }
            }
        }
    }

    /// Stores the choice here (the app reads it at launch) and in the daemon (agents, CLI, new terminals). No daemon:
    /// local only; `syncLanguage` sends it on the next connection.
    private func setLanguage(_ v: LanguageSetting) {
        language = v.rawValue
        restartNotice = LanguagePreference.needsRestart(running: L10n.current, new: v)
        guard client.state == .connected else { return }
        Task { _ = try? await client.adminCall("admin.language", ["language": .string(v.rawValue)]) }
    }

    /// `LanguagePreference.sync`, plus the restart notice when an adopted daemon value isn't the language running.
    private func syncLanguage() async {
        guard let now = await LanguagePreference.sync(client) else { return }
        language = now.rawValue
        if LanguagePreference.needsRestart(running: L10n.current, new: now) { restartNotice = true }
    }

    private var terminalSection: some View {
        section(tr("Terminal", "Terminal")) {
            HStack(spacing: 16) {
                Picker(tr("Fonte", "Font"), selection: $family) {
                    ForEach(TerminalFontChoice.families, id: \.self) { Text($0).tag($0) }
                }
                Picker(tr("Tamanho", "Size"), selection: $size) {
                    ForEach(Int(TerminalFontChoice.sizes.lowerBound)...Int(TerminalFontChoice.sizes.upperBound), id: \.self) {
                        Text("\($0) pt").tag(Double($0))
                    }
                }
            }
            .fixedSize()
        }
    }

    private var designSection: some View {
        section(tr("Onde desenhar", "Where to design")) {
            Picker(tr("Onde desenhar", "Where to design"), selection: Binding(get: { designFirst.rawValue }, set: { setDesignFirst(DesignFirst(rawValue: $0) ?? .artifact) })) {
                ForEach(DesignFirst.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            .disabled(client.state != .connected)
            Text(tr("Em trabalho de interface, o Pastor desenha antes: numa página na Prévia (fontes, animação, bibliotecas offline), no FigCraft, ou pergunta. Vale para o workspace e para o rebanho Feature com design.",
                    "On interface work, the Shepherd designs first: in a page in the Preview (fonts, animation, offline libraries), in FigCraft, or asks. Applies to the workspace and to the Feature herd with design."))
                .font(.collieMono(12)).foregroundStyle(Color.collieMuted)
        }
    }

    private var sandboxSection: some View {
        section(tr("Modo do sandbox", "Sandbox mode")) {
            Picker(tr("Modo do sandbox", "Sandbox mode"), selection: Binding(get: { sandboxMode.rawValue }, set: { setSandboxMode(SandboxMode(rawValue: $0) ?? .strict) })) {
                ForEach(SandboxMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            .disabled(client.state != .connected)
            Text(sandboxMode == .open
                 ? tr("Aberto: o agente lê e escreve tudo na sua conta (chaves e tokens incluídos); só os dados e o app do Collie ficam fechados. Vale para terminais abertos depois.",
                      "Open: the agent reads and writes everything in your account (keys and tokens included); only Collie's data and app stay closed. Applies to terminals opened afterwards.")
                 : tr("Estrito: escrita só no projeto, segredos fechados, cartões para liberar. Vale para terminais abertos depois.",
                      "Strict: writes only in the project, secrets closed, cards to release them. Applies to terminals opened afterwards."))
                .font(.collieMono(12)).foregroundStyle(Color.collieMuted)
            if client.detection == false, client.detectionReason == SandboxDetection.notAdmin {   // neutral, for who wants to know
                Text(AccessCopy.detection(reason: SandboxDetection.notAdmin).help).font(.collieMono(12)).foregroundStyle(Color.collieMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The paddocks trusted for loops (the loop card's "Sempre neste cercado"), each with **Revogar** ("Revoke"); `client.paddocks`
    /// follows the daemon, so a revoked one leaves the list by itself.
    private var loopTrustSection: some View {
        let trusted = client.paddocks.filter { $0.trustLoops == true }
        return section(tr("Laços sem cartão", "Loops without a card")) {
            Text(tr("Quando você escolhe \"Sempre neste cercado\" no cartão de um laço, os próximos laços desse cercado começam sem cartão. Você recebe o aviso e pode parar com collie work stop.",
                    "When you choose \"Always in this paddock\" on a loop's card, the next loops in that paddock start without a card. You get the notice and can stop with collie work stop."))
                .font(.collieMono(12)).foregroundStyle(Color.collieMuted).fixedSize(horizontal: false, vertical: true)
            if trusted.isEmpty {
                Text(tr("Nenhum cercado. Todo laço pede o cartão antes de começar.", "No paddock. Every loop asks for the card before it starts.")).font(.collieMono(12)).foregroundStyle(Color.collieMuted)
            }
            ForEach(trusted) { f in
                HStack {
                    Text(verbatim: f.name).font(.collieUI(13)).foregroundStyle(Color.collieText)
                    Spacer(minLength: 12)
                    Button(tr("Revogar", "Revoke")) {
                        Task { loopTrustError = await call("admin.paddock.trust-loops", ["paddock": .string(f.id.uuidString)]) }
                    }
                    .buttonStyle(CollieButtonStyle(.secondary)).controlSize(.small).disabled(client.state != .connected)
                }
                .frame(maxWidth: 420)
            }
            if let loopTrustError { Text(loopTrustError).font(.collieMono(12)).foregroundStyle(Color.collieDanger) }
            if !trusted.isEmpty {
                Text(tr("Revogar traz o cartão de volta.", "Revoking brings the card back."))
                    .font(.collieMono(12)).foregroundStyle(Color.collieMuted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// M5.6: `admin.loop-model`, what `work run` uses when given no --model (Claude agents); empty: the Shepherd's.
    private var loopModelSection: some View {
        section(tr("Modelo dos agentes", "Agents' model")) {
            Text(tr("O modelo dos agentes de um laço quando collie work run não traz --model (só agentes Claude). Vazio: o modelo do Pastor.",
                    "The model of a loop's agents when collie work run has no --model (Claude agents only). Empty: the Shepherd's model."))
                .font(.collieMono(12)).foregroundStyle(Color.collieMuted).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(tr("ex.: claude-sonnet-5-5", "e.g. claude-sonnet-5-5"), text: $loopModel).frame(width: 220).onSubmit(saveLoopModel)
                Button(tr("Salvar", "Save"), action: saveLoopModel).disabled(client.state != .connected)
            }
            if let loopModelError { Text(loopModelError).font(.collieMono(12)).foregroundStyle(Color.collieDanger) }
        }
        .task {
            guard client.state == .connected, case .object(let o)? = try? await client.adminCall("admin.loop-model", [:]) else { return }
            if case .string(let m)? = o["model"] { loopModel = m } else { loopModel = "" }
        }
    }

    private func saveLoopModel() {
        Task { loopModelError = await call("admin.loop-model", ["model": .string(loopModel.trimmingCharacters(in: .whitespaces))]) }
    }

    private var fontsSection: some View {
        section(tr("Fontes", "Fonts")) {
            Toggle(tr("Baixar fontes do Google Fonts", "Download fonts from Google Fonts"), isOn: Binding(get: { googleFonts }, set: { setGoogleFonts($0) }))
                .disabled(client.state != .connected)
            Text(tr("Para as páginas da Prévia, offline: o daemon baixa cada família uma vez (só o nome da fonte e o download vão ao Google); as páginas nunca acessam a rede. Os agentes pedem com collie font add.",
                    "For Preview pages, offline: the daemon downloads each family once (only the font name and the download go to Google); the pages never touch the network. Agents ask with collie font add."))
                .font(.collieMono(12)).foregroundStyle(Color.collieMuted)
            HStack {
                TextField(tr("Família (ex.: Inter)", "Family (e.g. Inter)"), text: $newFont).frame(width: 220).onSubmit(addFont)
                Button(fontBusy ? tr("Baixando…", "Downloading…") : tr("Baixar", "Download"), action: addFont)
                    .disabled(!googleFonts || fontBusy || newFont.trimmingCharacters(in: .whitespaces).isEmpty || client.state != .connected)
            }
            if let fontError { Text(fontError).font(.collieMono(12)).foregroundStyle(Color.collieMuted) }
            ForEach(fonts) { f in
                HStack {
                    Text(f.family).font(.collieUI(13))
                    Text(f.downloaded ? "Google Fonts" : tr("vem com o Collie", "ships with Collie")).font(.collieMono(11)).foregroundStyle(Color.collieMuted)
                    Spacer()
                    if f.downloaded { Button(tr("Remover", "Remove")) { removeFont(f.family) }.disabled(client.state != .connected) }
                }
            }
        }
    }

    private var memorySection: some View {
        section(tr("Memória", "Memory")) {
            Toggle(tr("Avisar uma vez por dia o que o Collie aprendeu", "Notify once a day about what Collie learned"), isOn: $dailyNotification)
            Text(tr("Às 18h, se houver algo no Aprendizado de hoje. O resumo fica sempre no painel Memória.", "At 6 pm, if there is anything in today's Learning. The summary always stays in the Memory panel."))
                .font(.collieMono(12)).foregroundStyle(Color.collieMuted)
            Toggle(tr("Avisar quando uma correção precisar de confirmação", "Notify when a correction needs confirmation"), isOn: $confirmNotification)
        }
    }

    private func loadDesignFirst() async {
        guard client.state == .connected, let r = try? await client.adminCall("design.prefer", [:]),
              let v = DesignFirst.from(reply: r) else { return }
        designFirst = v
    }

    private func setDesignFirst(_ v: DesignFirst) {
        let before = designFirst
        designFirst = v
        Task {
            if let r = try? await client.adminCall("design.prefer", ["value": .string(v.rawValue)]), let got = DesignFirst.from(reply: r) { designFirst = got }
            else { designFirst = before }   // refused or daemon gone: show what is saved
        }
    }

    private func loadFonts() async {
        guard client.state == .connected else { return }
        if let r = try? await client.adminCall("admin.fonts", [:]), let on = FontRow.download(r) { googleFonts = on }
        if let r = try? await client.adminCall("font.list", [:]) { fonts = FontRow.rows(r) }
    }

    private func setGoogleFonts(_ on: Bool) {
        let before = googleFonts
        googleFonts = on
        Task {
            if let r = try? await client.adminCall("admin.fonts", ["download": .string(on ? "on" : "off")]), let got = FontRow.download(r) { googleFonts = got }
            else { googleFonts = before }   // refused or daemon gone: show what is saved
        }
    }

    private func addFont() {
        let f = newFont.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, !fontBusy else { return }
        fontBusy = true; fontError = nil
        Task {
            switch await call("font.add", ["family": .string(f)]) { case nil: newFont = ""; case let m?: fontError = m }
            fontBusy = false
            await loadFonts()
        }
    }

    private func removeFont(_ family: String) {
        Task {
            if let m = await call("font.remove", ["family": .string(family)]) { fontError = m }
            await loadFonts()
        }
    }

    /// An admin call's error message; nil when it worked.
    private func call(_ command: String, _ args: [String: JSONValue]) async -> String? {
        do { _ = try await client.adminCall(command, args); return nil } catch { return error.message }
    }

    private func loadSandboxMode() async {
        guard client.state == .connected, let r = try? await client.adminCall("admin.sandbox", [:]),
              let v = SandboxMode.from(reply: r) else { return }
        sandboxMode = v
    }

    private func setSandboxMode(_ v: SandboxMode) {
        let before = sandboxMode
        sandboxMode = v
        Task {
            if let r = try? await client.adminCall("admin.sandbox", ["mode": .string(v.rawValue)]), let got = SandboxMode.from(reply: r) { sandboxMode = got }
            else { sandboxMode = before }   // refused or daemon gone: show what is saved
        }
    }

    private var currentPalette: Palette? { gallery.selectedPalette }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText)
            content()
        }
    }

    /// Rectangles in the theme's colors; `nil` palette (Sistema) = the current appearance's colors.
    private func miniature(_ p: Palette?, sidebar: Bool) -> some View {
        let bg = p.map { Color(nsColor: $0.background.nsColor) } ?? .collieBackground
        let surface = p.map { Color(nsColor: $0.surface.nsColor) } ?? .collieSurface
        let side = p.map { Color(nsColor: $0.sidebar.nsColor) } ?? .collieSidebar
        let accent = p.map { Color(nsColor: $0.accent.nsColor) } ?? .collieAccent
        return HStack(spacing: 4) {
            if sidebar { Rectangle().fill(side).frame(width: 22) }
            VStack(spacing: 4) {
                Capsule().fill(accent).frame(width: 30, height: 4).frame(maxWidth: .infinity, alignment: .leading)
                RoundedRectangle(cornerRadius: 4).fill(surface)
            }.padding(6)
        }
        .frame(height: 64).background(bg)
        .accessibilityHidden(true)
    }
}
