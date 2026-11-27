import Foundation
import CollieCore

/// Preferências option B: the sidebar's pages, in group order, with the search keywords of
/// `docs/pages/preferencias-b/index.html` (`NAV`/`PG`).
enum PreferencePage: String, CaseIterable {
    case aparencia, terminal, atualizacoes, diagnostico, desenho, lacos, memoria, plugins, celular, android

    private var titles: (pt: String, en: String) {
        switch self {
        case .aparencia: ("Aparência", "Appearance")
        case .terminal: ("Terminal e fontes", "Terminal and fonts")
        case .atualizacoes: ("Atualizações", "Updates")
        case .diagnostico: ("Diagnóstico", "Diagnostics")
        case .desenho: ("Desenho e sandbox", "Design and sandbox")
        case .lacos: ("Laços", "Loops")
        case .memoria: ("Memória", "Memory")
        case .plugins: ("Plug-ins", "Plug-ins")
        case .celular: ("Celular", "Phone")
        case .android: ("Android", "Android")
        }
    }
    var title: String { tr(titles.pt, titles.en) }

    /// The sidebar's group ids (`group`) are fixed; this is what the header shows.
    static func groupTitle(_ g: String) -> String {
        switch g { case "Agentes": tr("Agentes", "Agents"); case "Dispositivos": tr("Dispositivos", "Devices"); default: g }
    }

    var group: String {
        switch self {
        case .aparencia, .terminal, .atualizacoes, .diagnostico: "Interface"
        case .desenho, .lacos, .memoria, .plugins: "Agentes"
        case .celular, .android: "Dispositivos"
        }
    }

    var icon: String {
        switch self {
        case .aparencia: "◐"
        case .terminal: "›_"
        case .atualizacoes: "↻"
        case .diagnostico: "∿"
        case .desenho: "✎"
        case .lacos: "⟳"
        case .memoria: "◈"
        case .plugins: "⚙"
        case .celular: "▯"
        case .android: "▮"
        }
    }

    /// Portuguese and English together: the search finds a page by either language's words.
    var keywords: String {
        switch self {
        case .aparencia: "tema paleta escuro claro sistema idioma língua tour funções theme palette dark light system language features"
        case .diagnostico: "diagnóstico conexão conectado desconectado ram rss processo painéis contadores status diagnostics connection connected disconnected process panels counters"
        case .terminal: "terminal fonte tamanho google fonts baixar família font size download family"
        case .atualizacoes: "atualização atualizar versão nova instalar pular github release dmg voltar anterior update upgrade version new install skip rollback previous"
        case .desenho: "onde desenhar prévia figcraft perguntar sandbox aberto estrito pastor motor baixar instalar remover atualizar reinstalar where to draw preview ask open strict shepherd engine download install remove update reinstall"
        case .lacos: "laço laços loop cartão aprovar aprovação confiar cercado revogar autônomo work run loops card approve approval trust paddock revoke autonomous"
        case .memoria: "memória aprendizado aviso notificação correção cursor consulta início confiar editada fora curador provedor claude modelo limite consentimento testar memory learning notice notification correction lookup start trust edited outside curator provider model limit consent test"
        case .plugins: "plug-ins extensões extensions"
        case .celular: "celular iphone acesso remoto qr pareamento aparelhos leitura completo phone remote access pairing devices read full"
        case .android: "android java sdk emulador adb imagem licença licenças avd collie-lite platform-tools command-line cmdline emulator image license licenses"
        }
    }

    /// Pages whose title or keywords contain `query`, ignoring case and accents; all of them for an empty query.
    static func matching(_ query: String) -> [PreferencePage] {
        let q = fold(query.trimmingCharacters(in: .whitespaces))
        return q.isEmpty ? allCases : allCases.filter { fold($0.titles.pt + " " + $0.titles.en + " " + $0.keywords).contains(q) }
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
