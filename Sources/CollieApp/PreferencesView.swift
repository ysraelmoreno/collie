import SwiftUI
import CollieTheme

/// Single page (Aparência); a section bar comes with the second page.
struct PreferencesView: View {
    @AppStorage(AppearanceKeys.theme) private var theme = ThemeChoice.dark.rawValue
    @AppStorage(AppearanceKeys.structure) private var structure = WindowStructure.compact.rawValue
    @AppStorage(AppearanceKeys.terminalFamily) private var family = TerminalFontChoice.default.family
    @AppStorage(AppearanceKeys.terminalSize) private var size = Double(TerminalFontChoice.default.size)

    private let themes: [(ThemeChoice, String, String, Palette?)] = [
        (.dark, "Escuro", "fundo índigo, menta", .dark), (.light, "Claro", "papel, cobalto", .light),
        (.system, "Sistema", "segue o macOS", nil)]
    private let structures: [(WindowStructure, String, String)] = [
        (.compact, "Compacta", "canvas + cabeçalho flutuante"), (.full, "Completa", "barra lateral, cercados e status")]

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Aparência", subtitle: "Preferências")
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
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 560)
        .background(Color.collieBackground)
        .onAppear { AppearanceSettings.normalize(.standard) }   // a stale or hand-edited value would leave a picker blank
        .onChange(of: theme) { CollieApp.applyTheme() }
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
