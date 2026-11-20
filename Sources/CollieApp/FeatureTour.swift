import Foundation
import Observation

/// "O que o Collie faz": the table of cards the tour shows, the value-type model that walks it, and the set of cards the
/// user has seen. One source: `scripts/ci/lint.sh` (rule `feature-tour`) fails when a plug-in panel is not named in
/// `panels` of some card below, so the list does not age. No UI here; `FeatureTourView` draws it.
enum FeatureTour {
    enum Group: String, CaseIterable, Sendable {
        case trabalhar = "Trabalhar", paineis = "Painéis", controle = "Controle", personalizar = "Personalizar"
    }

    /// One illustration per card, drawn by `FeatureArt`.
    enum Art: Sendable {
        case canvas, paddock, shepherd, loop, work, palette, browser, device, network, design, preview, diagram, memory,
             sandbox, herds, plugins, themes
    }

    /// What a card's button does. Each case is an entry the app already has; `ContentView` runs it once the tour is closed.
    enum Action: Equatable, Sendable {
        case newTerminal, newPaddock, openPalette, openHerds
        /// A plug-in panel by id: shown if one is open, else opened (Dispositivo and Design ask which one first).
        case panel(String)
        case preferences(PreferencePage)
    }

    struct Shortcut: Equatable, Sendable {
        let label: String
        let action: Action
    }

    struct Card: Identifiable, Equatable, Sendable {
        let id: String
        let group: Group
        let title: String
        let text: String
        /// Shortcut, menu or command that reaches it.
        let how: String
        let art: Art
        /// Nil: no entry in the app takes the user there, so the card has no button.
        let shortcut: Shortcut?
        /// The panel types (`Sources/ColliePlugins/*Panel.swift`) this card covers.
        let panels: [String]
    }

    static let cards: [Card] = [
        Card(id: "canvas", group: .trabalhar, title: "Canvas e terminais",
             text: "Cada agente roda num terminal no canvas, lado a lado. Guias ligam um terminal aos outros terminais e painéis que ele pode usar.",
             how: "clique direito no canvas", art: .canvas, shortcut: Shortcut(label: "Novo terminal", action: .newTerminal), panels: []),
        Card(id: "paddocks", group: .trabalhar, title: "Cercados",
             text: "Cada cercado é uma cópia isolada do repositório, com o próprio ramo. Dois agentes trabalham em paralelo sem pisar um no outro.",
             how: "+ no trilho", art: .paddock, shortcut: Shortcut(label: "Novo cercado", action: .newPaddock), panels: []),
        Card(id: "shepherd", group: .trabalhar, title: "Pastor e delegação",
             text: "Um terminal Pastor chama outros agentes, entrega a tarefa e recebe a resposta. Você fala com um; ele coordena os demais.",
             how: "collie summon <nome>", art: .shepherd, shortcut: nil, panels: []),   // no reference page in the app to open
        Card(id: "loops", group: .trabalhar, title: "Laços",
             text: "Uma lista de tarefas roda sem supervisão: um agente novo por tentativa, e só o check de cada tarefa decide se ela passou.",
             how: "/collie:loop", art: .loop, shortcut: Shortcut(label: "Abrir Trabalho", action: .panel("work")), panels: []),
        Card(id: "work", group: .trabalhar, title: "Trabalho",
             text: "O registro do que cada terminal está fazendo: tarefas, andamento do laço, evidências e um resumo ao final.",
             how: "painel Trabalho", art: .work, shortcut: Shortcut(label: "Abrir Trabalho", action: .panel("work")), panels: ["WorkPanel"]),
        Card(id: "palette", group: .trabalhar, title: "Paleta de comandos",
             text: "Chame um agente, abra um painel ou vá a um cercado sem tirar a mão do teclado.",
             how: "⌘K", art: .palette, shortcut: Shortcut(label: "Abrir a paleta", action: .openPalette), panels: []),
        Card(id: "browser", group: .paineis, title: "Navegador",
             text: "Um navegador que o agente dirige: navega, clica, digita e lê a página. Você vê tudo acontecer.",
             how: "collie panel open browser", art: .browser, shortcut: Shortcut(label: "Abrir Navegador", action: .panel("browser")),
             panels: ["BrowserPanel"]),
        Card(id: "device", group: .paineis, title: "Dispositivo",
             text: "A tela de um emulador Android, de um simulador iOS ou de um aparelho, com toque e teclado, para o agente testar o app.",
             how: "collie panel open device", art: .device, shortcut: Shortcut(label: "Abrir Dispositivo", action: .panel("device")),
             panels: ["DevicePanel"]),
        Card(id: "network", group: .paineis, title: "Rede",
             text: "Inspeciona as requisições do emulador e responde no lugar do servidor por regra, para testar sem depender do backend.",
             how: "collie panel open network", art: .network, shortcut: Shortcut(label: "Abrir Rede", action: .panel("network")),
             panels: ["NetworkPanel"]),
        Card(id: "design", group: .paineis, title: "Design e Design Systems",
             text: "O agente desenha telas num motor de design e segue o design system escolhido para o projeto, com histórico de versões.",
             how: "collie panel open design", art: .design, shortcut: Shortcut(label: "Abrir Design", action: .panel("design")),
             panels: ["DesignPanel", "DesignSystemsPanel"]),
        Card(id: "preview", group: .paineis, title: "Prévia e Artifacts",
             text: "Páginas que o agente escreve (protótipo, deck, dashboard, documento) abrem ao lado, aceitam comentários e ficam guardadas.",
             how: "collie artifact new prototype", art: .preview, shortcut: Shortcut(label: "Abrir Artifacts", action: .panel("artifacts")),
             panels: ["PreviewPanel", "ArtifactsPanel"]),
        Card(id: "diagram", group: .paineis, title: "Diagrama",
             text: "O agente desenha um diagrama e você edita junto, no mesmo arquivo.",
             how: "collie panel open diagram", art: .diagram, shortcut: Shortcut(label: "Abrir Diagrama", action: .panel("diagram")),
             panels: ["DiagramPanel"]),
        Card(id: "memory", group: .controle, title: "Memória",
             text: "Os agentes guardam decisões e armadilhas do projeto e as recebem de volta nas próximas sessões. Você revisa, edita e descarta.",
             how: "painel Memória", art: .memory, shortcut: Shortcut(label: "Abrir Memória", action: .panel("memory")),
             panels: ["MemoryPanel"]),
        Card(id: "sandbox", group: .controle, title: "Sandbox e cartões",
             text: "Todo terminal roda isolado. O que um agente pede fora do sandbox vira um cartão, e só você aprova.",
             how: "Preferências › Desenho e sandbox", art: .sandbox,
             shortcut: Shortcut(label: "Abrir Preferências", action: .preferences(.desenho)), panels: []),
        Card(id: "herds", group: .controle, title: "Rebanhos e Lotes",
             text: "Rebanhos são times prontos de terminais e painéis, aplicados de uma vez. Lotes agrupam terminais de um mesmo esforço.",
             how: "menu Rebanhos", art: .herds, shortcut: Shortcut(label: "Ver rebanhos", action: .openHerds), panels: []),
        Card(id: "plugins", group: .personalizar, title: "Plug-ins",
             text: "Painéis e comandos de terceiros entram sem recompilar o Collie. Um plug-in também pode orientar ou barrar o agente a cada edição.",
             how: "Preferências › Plug-ins", art: .plugins,
             shortcut: Shortcut(label: "Abrir Plug-ins", action: .preferences(.plugins)), panels: ["WebPluginPanel"]),
        Card(id: "themes", group: .personalizar, title: "Temas",
             text: "Crie o seu tema: edite as cores numa lista ou em JSON, com a prévia ao lado. O tema é um arquivo que dá para compartilhar.",
             how: "Preferências › Aparência", art: .themes,
             shortcut: Shortcut(label: "Abrir Aparência", action: .preferences(.aparencia)), panels: []),
    ]

    /// True when some card is not in `seen`. Ids in `seen` that name no card (a card since removed) count for nothing.
    static func hasUnseen(_ seen: Set<String>, cards: [Card] = FeatureTour.cards) -> Bool {
        cards.contains { !seen.contains($0.id) }
    }
}

/// Where the tour stands: the card on screen and the cards shown so far. A card counts as seen when it is shown, which is
/// when it becomes the current one (the first one included).
struct FeatureTourModel: Equatable {
    let cards: [FeatureTour.Card]
    private(set) var index: Int
    private(set) var seen: Set<String>

    /// Starts on the first card not in `seen` (the first card when all were seen). Ids that are no card are dropped.
    init(cards: [FeatureTour.Card] = FeatureTour.cards, seen: Set<String> = []) {
        let known = seen.intersection(cards.map(\.id))
        let start = cards.firstIndex { !known.contains($0.id) } ?? 0
        self.cards = cards
        self.index = start
        self.seen = cards.indices.contains(start) ? known.union([cards[start].id]) : known
    }

    var current: FeatureTour.Card { cards[index] }
    var group: FeatureTour.Group { current.group }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < cards.count - 1 }
    var hasUnseen: Bool { FeatureTour.hasUnseen(seen, cards: cards) }

    /// The next card; stays on the last one.
    mutating func next() { show(index + 1) }
    /// The previous card; stays on the first one.
    mutating func previous() { show(index - 1) }
    /// The first card of `group`.
    mutating func jump(to group: FeatureTour.Group) {
        if let i = cards.firstIndex(where: { $0.group == group }) { show(i) }
    }
    /// The card at `i`, clamped to the table.
    mutating func show(_ i: Int) {
        guard !cards.isEmpty else { return }
        index = min(max(i, 0), cards.count - 1)
        seen.insert(cards[index].id)
    }
}

/// The ids of the cards the user has seen, in `UserDefaults` (`tour.seen`). Read by the info icon (the dot) and written by the tour.
@MainActor @Observable final class FeatureTourSeen {
    static let key = "tour.seen"
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var ids: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    var hasUnseen: Bool { FeatureTour.hasUnseen(ids) }

    func mark(_ id: String) {
        guard !ids.contains(id) else { return }
        ids.insert(id)
        defaults.set(ids.sorted(), forKey: Self.key)
    }
}
