import Foundation
import Observation
import CollieCore

/// "O que o Collie faz": the table of cards the tour shows, the value-type model that walks it, and the set of cards the
/// user has seen. One source: `scripts/ci/lint.sh` (rule `feature-tour`) fails when a plug-in panel is not named in
/// `panels` of some card below, so the list does not age. No UI here; `FeatureTourView` draws it.
enum FeatureTour {
    enum Group: String, CaseIterable, Sendable {
        case trabalhar = "Trabalhar", paineis = "Painéis", controle = "Controle", personalizar = "Personalizar"
        var title: String {
            switch self {
            case .trabalhar: tr("Trabalhar", "Work")
            case .paineis: tr("Painéis", "Panels")
            case .controle: tr("Controle", "Control")
            case .personalizar: tr("Personalizar", "Customize")
            }
        }
    }

    /// One illustration per card, drawn by `FeatureArt`.
    enum Art: Sendable {
        case canvas, paddock, shepherd, loop, work, palette, browser, device, network, design, preview, diagram, memory,
             sandbox, herds, plugins, themes
    }

    /// What a card's button does. Each case is an entry the app already has; `ContentView` runs it once the tour is closed.
    enum Action: Equatable, Sendable {
        case newTerminal, newPaddock, openPalette, openHerds, openLoops
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

    static var cards: [Card] { [
        Card(id: "canvas", group: .trabalhar, title: tr("Canvas e terminais", "Canvas and terminals"),
             text: tr("Cada agente roda num terminal no canvas, lado a lado. Guias ligam um terminal aos outros terminais e painéis que ele pode usar.", "Each agent runs in a terminal on the canvas, side by side. Leashes connect a terminal to the other terminals and panels it can use."),
             how: tr("clique direito no canvas", "right-click on the canvas"), art: .canvas, shortcut: Shortcut(label: tr("Novo terminal", "New terminal"), action: .newTerminal), panels: []),
        Card(id: "paddocks", group: .trabalhar, title: tr("Cercados", "Paddocks"),
             text: tr("Cada cercado é uma cópia isolada do repositório, com o próprio ramo. Dois agentes trabalham em paralelo sem pisar um no outro.", "Each paddock is an isolated copy of the repository with its own branch. Two agents work in parallel without stepping on each other."),
             how: tr("＋ ao lado de Cercados", "＋ next to Paddocks"), art: .paddock, shortcut: Shortcut(label: tr("Novo cercado", "New paddock"), action: .newPaddock), panels: []),
        Card(id: "shepherd", group: .trabalhar, title: tr("Pastor e delegação", "Shepherd and delegation"),
             text: tr("Um terminal Pastor chama outros agentes, entrega a tarefa e recebe a resposta. Você fala com um; ele coordena os demais.", "A Shepherd terminal summons other agents, hands over the task and gets the answer back. You talk to one; it coordinates the rest."),
             how: tr("collie summon <nome>", "collie summon <name>"), art: .shepherd, shortcut: nil, panels: []),   // no reference page in the app to open
        Card(id: "loops", group: .trabalhar, title: tr("Laços", "Loops"),
             text: tr("Uma lista de tarefas roda sem supervisão: um agente novo por tentativa, e só o check de cada tarefa decide se ela passou.", "A task list runs unattended: a fresh agent per attempt, and only each task's check decides whether it passed."),
             how: tr("/collie:loop, ⌘K Laços…", "/collie:loop, ⌘K Loops…"), art: .loop, shortcut: Shortcut(label: tr("Ver laços", "See loops"), action: .openLoops), panels: []),
        Card(id: "work", group: .trabalhar, title: tr("Trabalho", "Work"),
             text: tr("O registro do que cada terminal está fazendo: tarefas, andamento do laço, evidências e um resumo ao final.", "The record of what each terminal is doing: tasks, loop progress, evidence and a summary at the end."),
             how: tr("⌘K Trabalho", "⌘K Work"), art: .work, shortcut: Shortcut(label: tr("Abrir Trabalho", "Open Work"), action: .panel("work")), panels: ["WorkPanel"]),
        Card(id: "palette", group: .trabalhar, title: tr("Paleta de comandos", "Command palette"),
             text: tr("Chame um agente, abra um painel ou vá a um cercado sem tirar a mão do teclado.", "Summon an agent, open a panel or jump to a paddock without leaving the keyboard."),
             how: "⌘K", art: .palette, shortcut: Shortcut(label: tr("Abrir a paleta", "Open the palette"), action: .openPalette), panels: []),
        Card(id: "browser", group: .paineis, title: tr("Navegador", "Browser"),
             text: tr("Um navegador que o agente dirige: navega, clica, digita e lê a página. Você vê tudo acontecer.", "A browser the agent drives: it navigates, clicks, types and reads the page. You watch it all happen."),
             how: "collie panel open browser", art: .browser, shortcut: Shortcut(label: tr("Abrir Navegador", "Open Browser"), action: .panel("browser")),
             panels: ["BrowserPanel"]),
        Card(id: "device", group: .paineis, title: tr("Dispositivo", "Device"),
             text: tr("A tela de um emulador Android, de um simulador iOS ou de um aparelho, com toque e teclado, para o agente testar o app.", "The screen of an Android emulator, an iOS simulator or a physical device, with touch and keyboard, so the agent can test the app."),
             how: "collie panel open device", art: .device, shortcut: Shortcut(label: tr("Abrir Dispositivo", "Open Device"), action: .panel("device")),
             panels: ["DevicePanel"]),
        Card(id: "network", group: .paineis, title: tr("Rede", "Network"),
             text: tr("Inspeciona as requisições do emulador e responde no lugar do servidor por regra, para testar sem depender do backend.", "Inspects the emulator's requests and answers in place of the server by rule, so you can test without depending on the backend."),
             how: "collie panel open network", art: .network, shortcut: Shortcut(label: tr("Abrir Rede", "Open Network"), action: .panel("network")),
             panels: ["NetworkPanel"]),
        Card(id: "design", group: .paineis, title: tr("Design e Design Systems", "Design and Design Systems"),
             text: tr("O agente desenha telas num motor de design e segue o design system escolhido para o projeto, com histórico de versões.", "The agent designs screens in a design engine and follows the design system chosen for the project, with version history."),
             how: "collie panel open design", art: .design, shortcut: Shortcut(label: tr("Abrir Design", "Open Design"), action: .panel("design")),
             panels: ["DesignPanel", "DesignSystemsPanel"]),
        Card(id: "preview", group: .paineis, title: tr("Prévia e Artifacts", "Preview and Artifacts"),
             text: tr("Páginas que o agente escreve (protótipo, deck, dashboard, documento) abrem ao lado, aceitam comentários e ficam guardadas.", "Pages the agent writes (prototype, deck, dashboard, document) open alongside, take comments and are kept."),
             how: "collie artifact new prototype", art: .preview, shortcut: Shortcut(label: tr("Abrir Artifacts", "Open Artifacts"), action: .panel("artifacts")),
             panels: ["PreviewPanel", "ArtifactsPanel"]),
        Card(id: "diagram", group: .paineis, title: tr("Diagrama", "Diagram"),
             text: tr("O agente desenha um diagrama e você edita junto, no mesmo arquivo.", "The agent draws a diagram and you edit it together, in the same file."),
             how: "collie panel open diagram", art: .diagram, shortcut: Shortcut(label: tr("Abrir Diagrama", "Open Diagram"), action: .panel("diagram")),
             panels: ["DiagramPanel"]),
        Card(id: "memory", group: .controle, title: tr("Memória", "Memory"),
             text: tr("Os agentes guardam decisões e armadilhas do projeto e as recebem de volta nas próximas sessões. Você revisa, edita e descarta.", "Agents save the project's decisions and pitfalls and get them back in later sessions. You review, edit and discard."),
             how: tr("⌘K Memória", "⌘K Memory"), art: .memory, shortcut: Shortcut(label: tr("Abrir Memória", "Open Memory"), action: .panel("memory")),
             panels: ["MemoryPanel"]),
        Card(id: "sandbox", group: .controle, title: tr("Sandbox e cartões", "Sandbox and cards"),
             text: tr("Todo terminal roda isolado. O que um agente pede fora do sandbox vira um cartão, e só você aprova.", "Every terminal runs isolated. What an agent asks for outside the sandbox becomes a card, and only you approve it."),
             how: tr("Preferências › Desenho e sandbox", "Preferences › Design and sandbox"), art: .sandbox,
             shortcut: Shortcut(label: tr("Abrir Preferências", "Open Preferences"), action: .preferences(.desenho)), panels: []),
        Card(id: "herds", group: .controle, title: tr("Rebanhos e Lotes", "Herds and Lots"),
             text: tr("Rebanhos são times prontos de terminais e painéis, aplicados de uma vez. Lotes agrupam terminais de um mesmo esforço.", "Herds are ready-made teams of terminals and panels, applied at once. Lots group terminals working on the same effort."),
             how: tr("＋ Novo agente › A partir de rebanho…, ⋯ do cercado › Lotes…", "＋ New agent › From a herd…, paddock ⋯ › Lots…"), art: .herds, shortcut: Shortcut(label: tr("Ver rebanhos", "See herds"), action: .openHerds), panels: []),
        Card(id: "plugins", group: .personalizar, title: "Plug-ins",
             text: tr("Painéis e comandos de terceiros entram sem recompilar o Collie. Um plug-in também pode orientar ou barrar o agente a cada edição.", "Third-party panels and commands come in without recompiling Collie. A plug-in can also guide or block the agent on every edit."),
             how: tr("Preferências › Plug-ins", "Preferences › Plug-ins"), art: .plugins,
             shortcut: Shortcut(label: tr("Abrir Plug-ins", "Open Plug-ins"), action: .preferences(.plugins)), panels: ["WebPluginPanel"]),
        Card(id: "themes", group: .personalizar, title: tr("Temas", "Themes"),
             text: tr("Crie o seu tema: edite as cores numa lista ou em JSON, com a prévia ao lado. O tema é um arquivo que dá para compartilhar.", "Make your own theme: edit the colors in a list or in JSON, with the preview alongside. A theme is a file you can share."),
             how: tr("Preferências › Aparência", "Preferences › Appearance"), art: .themes,
             shortcut: Shortcut(label: tr("Abrir Aparência", "Open Appearance"), action: .preferences(.aparencia)), panels: []),
    ] }

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

/// The ids of the cards the user has seen, in `UserDefaults` (`tour.seen`). Written by the tour; the tour opens on the first card not in it.
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
