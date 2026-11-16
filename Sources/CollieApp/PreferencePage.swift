import Foundation

/// Preferências option B: the sidebar's pages, in group order, with the search keywords of
/// `docs/pages/preferencias-b/index.html` (`NAV`/`PG`).
enum PreferencePage: String, CaseIterable {
    case aparencia, terminal, desenho, memoria, plugins, celular, android

    var title: String {
        switch self {
        case .aparencia: "Aparência"
        case .terminal: "Terminal e fontes"
        case .desenho: "Desenho e sandbox"
        case .memoria: "Memória"
        case .plugins: "Plug-ins"
        case .celular: "Celular"
        case .android: "Android"
        }
    }

    var group: String {
        switch self {
        case .aparencia, .terminal: "Interface"
        case .desenho, .memoria, .plugins: "Agentes"
        case .celular, .android: "Dispositivos"
        }
    }

    var icon: String {
        switch self {
        case .aparencia: "◐"
        case .terminal: "›_"
        case .desenho: "✎"
        case .memoria: "◈"
        case .plugins: "⚙"
        case .celular: "▯"
        case .android: "▮"
        }
    }

    var keywords: String {
        switch self {
        case .aparencia: "tema paleta escuro claro sistema estrutura moldura completa compacta barra"
        case .terminal: "terminal fonte tamanho google fonts baixar família"
        case .desenho: "onde desenhar prévia figcraft perguntar sandbox aberto estrito pastor motor baixar instalar remover atualizar reinstalar"
        case .memoria: "memória aprendizado aviso notificação correção"
        case .plugins: "plug-ins extensões"
        case .celular: "celular iphone acesso remoto qr pareamento aparelhos leitura completo"
        case .android: "android java sdk emulador adb imagem licença licenças avd collie-lite platform-tools command-line cmdline"
        }
    }

    /// Pages whose title or keywords contain `query`, ignoring case and accents; all of them for an empty query.
    static func matching(_ query: String) -> [PreferencePage] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        return q.isEmpty ? allCases : allCases.filter { fold($0.title + " " + $0.keywords).contains(q) }
    }

    /// The Android item's badge from `android.status`: `↓` while a job runs, `!` after a failed one or while licenses wait.
    /// ponytail: "ocupado" (`busy:` from `android.install`) is local to the Android page, so it gets no badge here.
    static func androidBadge(_ s: AndroidSetupStatus?) -> String? {
        switch s?.job?.phase {
        case "prepare", "install": "↓"
        case "failed": "!"
        default: s?.needs == "needsLicense" ? "!" : nil
        }
    }

    /// Desenho e sandbox's badge from `design.engine.status`, the same row the page draws: `↓` while a job runs, `!` after
    /// a failed one or while the engine needs updating or reinstalling.
    static func designBadge(_ s: DesignEngineStatus?) -> String? {
        switch s.map({ DesignEngineStatus.row($0) }) {
        case .downloading, .verifying: "↓"
        case .failed, .needsUpdate: "!"
        default: nil
        }
    }

    /// Defaults key for the page a `collieOpenPreferences` notification asked for: `PreferencesView` shows it and clears
    /// it, whether its window was already open or opens now. ponytail: defaults as the mailbox, the window may not exist yet.
    static let requestKey = "preferences.requestedPage"
    /// The page named by a `collieOpenPreferences` notification's object (`"desenho"`); nil for anything else.
    static func requested(_ object: Any?) -> PreferencePage? { (object as? String).flatMap(PreferencePage.init(rawValue:)) }

    private static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
}
