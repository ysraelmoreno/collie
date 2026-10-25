import SwiftUI
import CollieTheme
import CollieCore
import CollieClient
import CollieProtocol
import ColliePlugins

/// Two pages, Aparência and Plug-ins (`PluginsPreferences`), picked in the header.
extension DesignFirst {
    var label: String { switch self { case .ask: "Perguntar"; case .always: "Sempre"; case .never: "Nunca" } }
    /// The `design.prefer` reply (`{designFirst}`); nil when it is anything else.
    static func from(reply: JSONValue) -> DesignFirst? {
        guard case .object(let o) = reply, case .string(let v)? = o["designFirst"] else { return nil }
        return DesignFirst(rawValue: v)
    }
}

extension SandboxMode {
    var label: String { switch self { case .open: "Aberto (padrão)"; case .strict: "Estrito" } }
    /// The `admin.sandbox` reply (`{mode}`); nil when it is anything else.
    static func from(reply: JSONValue) -> SandboxMode? {
        guard case .object(let o) = reply, case .string(let v)? = o["mode"] else { return nil }
        return SandboxMode(rawValue: v)
    }
}

struct PreferencesView: View {
    let client: DaemonClient
    @State private var designFirst = DesignFirst.ask
    @State private var sandboxMode = SandboxMode.open
    @State private var page = "Aparência"
    @AppStorage(AppearanceKeys.theme) private var theme = ThemeChoice.dark.rawValue
    @AppStorage(AppearanceKeys.structure) private var structure = WindowStructure.compact.rawValue
    @AppStorage(AppearanceKeys.terminalFamily) private var family = TerminalFontChoice.default.family
    @AppStorage(AppearanceKeys.terminalSize) private var size = Double(TerminalFontChoice.default.size)
    @AppStorage(MemoryDigestNotice.defaultsKey) private var dailyNotification = MemoryDigestNotice.defaultOn
    @AppStorage(Notifier.confirmKey) private var confirmNotification = Notifier.confirmDefaultOn

    private let themes: [(ThemeChoice, String, String, Palette?)] = [
        (.dark, "Escuro", "fundo índigo, menta", .dark), (.light, "Claro", "papel, cobalto", .light),
        (.system, "Sistema", "segue o macOS", nil)]
    private let structures: [(WindowStructure, String, String)] = [
        (.compact, "Compacta", "canvas + cabeçalho flutuante"), (.full, "Completa", "barra lateral, cercados e status")]

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(page, subtitle: "Preferências")
            Picker("Página", selection: $page) { ForEach(["Aparência", "Plug-ins"], id: \.self) { Text($0).tag($0) } }
                .labelsHidden().pickerStyle(.segmented).fixedSize().padding(.top, 10)
            if page == "Plug-ins" {
                ScrollView { PluginsPreferences(client: client).padding(20).frame(maxWidth: .infinity, alignment: .leading) }
            } else { appearance }
        }
        .frame(width: 560, height: 560)
        .background(Color.collieBackground)
        .onAppear { AppearanceSettings.normalize(.standard) }   // a stale or hand-edited value would leave a picker blank
        .task(id: client.state == .connected) { await loadDesignFirst(); await loadSandboxMode() }   // no workspace event: read when shown
        .onChange(of: theme) { CollieApp.applyTheme() }
    }

    private var appearance: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("Tema") {
                        HStack(spacing: 12) {
                            ForEach(themes, id: \.0) { t in
                                ChoiceCard(t.1, subtitle: t.2, selected: theme == t.0.rawValue, action: { theme = t.0.rawValue }) {
                                    miniature(t.3, sidebar: false)
                                }
                            }
                        }
                    }
                    section("Estrutura") {
                        HStack(spacing: 12) {
                            ForEach(structures, id: \.0) { s in
                                ChoiceCard(s.1, subtitle: s.2, selected: structure == s.0.rawValue, action: { structure = s.0.rawValue }) {
                                    miniature(currentPalette, sidebar: s.0 == .full)
                                }
                            }
                        }
                        Text("Muda só a moldura. Terminais, guias e painéis ficam onde estão.")
                            .font(.collieMono(12)).foregroundStyle(Color.collieMuted)
                    }
                    section("Terminal") {
                        HStack(spacing: 16) {
                            Picker("Fonte", selection: $family) {
                                ForEach(TerminalFontChoice.families, id: \.self) { Text($0).tag($0) }
                            }
                            Picker("Tamanho", selection: $size) {
                                ForEach(Int(TerminalFontChoice.sizes.lowerBound)...Int(TerminalFontChoice.sizes.upperBound), id: \.self) {
                                    Text("\($0) pt").tag(Double($0))
                                }
                            }
                        }
                        .fixedSize()
                    }
                    section("Design antes da interface") {
                        Picker("Design antes da interface", selection: Binding(get: { designFirst.rawValue }, set: { setDesignFirst(DesignFirst(rawValue: $0) ?? .ask) })) {
                            ForEach(DesignFirst.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                        }
                        .labelsHidden().pickerStyle(.segmented).fixedSize()
                        .disabled(client.state != .connected)
                        Text("Em trabalho de interface, o Pastor desenha antes no FigCraft: pergunta, sempre ou nunca. Vale para o workspace.")
                            .font(.collieMono(12)).foregroundStyle(Color.collieMuted)
                    }
                    section("Modo do sandbox") {
                        Picker("Modo do sandbox", selection: Binding(get: { sandboxMode.rawValue }, set: { setSandboxMode(SandboxMode(rawValue: $0) ?? .strict) })) {
                            ForEach(SandboxMode.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                        }
                        .labelsHidden().pickerStyle(.segmented).fixedSize()
                        .disabled(client.state != .connected)
                        Text(sandboxMode == .open
                             ? "Aberto: o agente lê e escreve tudo na sua conta (chaves e tokens incluídos); só os dados e o app do Collie ficam fechados. Vale para terminais abertos depois."
                             : "Estrito: escrita só no projeto, segredos fechados, cartões para liberar. Vale para terminais abertos depois.")
                            .font(.collieMono(12)).foregroundStyle(Color.collieMuted)
                    }
                    section("Memória") {
                        Toggle("Avisar uma vez por dia o que o Collie aprendeu", isOn: $dailyNotification)
                        Text("Às 18h, se houver algo no Aprendizado de hoje. O resumo fica sempre no painel Memória.")
                            .font(.collieMono(12)).foregroundStyle(Color.collieMuted)
                        Toggle("Avisar quando uma correção precisar de confirmação", isOn: $confirmNotification)
                    }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
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

    private var currentPalette: Palette? { ThemeChoice(rawValue: theme).flatMap { t in t == .dark ? .dark : t == .light ? .light : nil } }

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
