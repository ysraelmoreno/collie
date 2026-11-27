import SwiftUI
import CollieCanvas
import CollieClient
import CollieCore
import ColliePlugins
import CollieTheme

/// What the window chrome reads and the actions it runs; the command palette runs the same closures.
@MainActor struct ShellContext {
    let client: DaemonClient
    let canvas: CanvasState
    let paddocks: PaddockActions
    let usage: UsageFeed
    var usageOpen: Binding<Bool>
    var newTerminal: () -> Void
    var openPanel: () -> Void
    var fit: () -> Void
    var openPalette: () -> Void
    let herds: HerdsModel
    /// The Herds sheet, with that herd selected (nil: the first).
    var openHerds: (String?) -> Void
    /// Selects a terminal or panel and centers it on the canvas (the path of a notification click or `mac.reveal`).
    var focus: (UUID) -> Void = { _ in }
    /// The edit sheet of a terminal.
    var edit: (UUID) -> Void = { _ in }
    /// The Preferências sheet over the window (⌘,): the canvas stays mounted underneath.
    var openPreferences: () -> Void = {}
    /// The cards of "O que o Collie faz" the user has seen (the info icon's dot) and the modal that shows them.
    var tour = FeatureTourSeen()
    var openTour: () -> Void = {}
    /// Brings the Work panel forward (opens it where it was not).
    var openWork: () -> Void = {}
    /// "Abrir no canvas" of a closed work (its id): returns once the Prévia opened or failed (M9.1: the modal waits).
    var onOpenHistory: @MainActor (String) async -> Void = { _ in }
    /// The short warning the Laços modal shows when the Prévia could not be opened (nil: it opened).
    var historyNotice: () -> String? = { nil }
    /// M8.2: "Ver tudo" (or the card) of LAÇOS: the Laços modal (`LoopsSheet`, M8.3) on that tab.
    var onOpenLoops: (LoopsTab) -> Void = { _ in }
    /// M8.3: a closed work's `WorkArchive` (`work.history --id`), for the modal's detail.
    var fetchHistory: (String) async throws -> WorkArchive = { _ in throw CancellationError() }
    /// Zooms the canvas by a factor around the visible area's center (the floating bar's − and +).
    var zoom: (CGFloat) -> Void = { _ in }
}

/// The window: the single sidebar (`Sidebar`, ⌘\\ collapses it) beside `content` (docks + canvas). `content` keeps one
/// position in the hierarchy, so collapsing the sidebar or opening Preferências (a sheet, `ContentView`) never remakes
/// the canvas or the panels.
struct Shell<Content: View>: View {
    let ctx: ShellContext
    @Binding var collapsed: Bool
    let content: Content
    /// One-time sandbox notice (UserDefaults via @AppStorage, like the other UI state); a new key for open mode: shown again once.
    @AppStorage("sandbox.openNoticeSeen") private var noticeSeen = false

    init(ctx: ShellContext, collapsed: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.ctx = ctx; _collapsed = collapsed; self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(ctx: ctx, collapsed: $collapsed)
            content
        }
        .background(Color.collieBackground)
        .alert(tr("Terminais com sandbox", "Sandboxed terminals"), isPresented: Binding(get: { !noticeSeen }, set: { if !$0 { noticeSeen = true } })) {
            Button(tr("Entendi", "Got it")) { noticeSeen = true }
            Button(tr("Ler no README", "Read the README")) {
                noticeSeen = true
                NSWorkspace.shared.open(URL(string: "https://github.com/ysraelmoreno/collie#sandbox-dos-terminais")!)
            }
        } message: {
            Text(tr("Os terminais rodam no sandbox aberto (padrão): o agente lê e escreve tudo na sua conta, inclusive chaves e tokens, e pode apagar qualquer coisa; só os dados, o app e o daemon do Collie ficam fechados ao acesso direto. O que ele gravar e você executar depois (rc do shell, LaunchAgents, binários, hooks do git) roda sem sandbox e alcança tudo, o Collie incluído. Em Preferências, \"Modo do sandbox\" muda para Estrito (escrita só no projeto, segredos fechados, cartões para liberar); vale para terminais abertos depois.",
                    "Terminals run in the open sandbox (default): the agent reads and writes everything in your account, including keys and tokens, and can delete anything; only Collie's data, app and daemon are closed to direct access. Anything it writes and you run later (shell rc, LaunchAgents, binaries, git hooks) runs without a sandbox and reaches everything, Collie included. In Preferences, \"Sandbox mode\" switches to Strict (write only in the project, secrets closed, cards to grant access); it applies to terminals opened afterwards."))
        }
    }
}

/// Floats over the canvas: the thin bar in the top right corner (⌘K, zoom, Ajustar, minimap), then the banners.
/// A disconnection shows at the sidebar's foot (`SidebarFooter`).
struct CanvasChrome<Banners: View>: View {
    let ctx: ShellContext
    @ViewBuilder let banners: Banners
    /// The hidden title bar leaves the traffic lights over the window's top left: the sidebar and this bar start below.
    /// The collapsed sidebar (56 pt) is narrower than the three lights, so the third one sits over the canvas's corner,
    /// where nothing is drawn (this bar is on the right).
    static var lightsInset: CGFloat { 28 }

    var body: some View {
        VStack(spacing: 8) {
            HStack { Spacer(minLength: 0); CanvasBar(ctx: ctx) }
            banners
            HostNotice(client: ctx.client)
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
        .padding(.top, Self.lightsInset)
    }
}

/// The thin bar: the command field (⌘K), zoom − n% +, Ajustar and the minimap switch (off by default).
struct CanvasBar: View {
    let ctx: ShellContext
    @AppStorage(CanvasBar.minimapKey) private var minimap = false
    static let minimapKey = "canvas.minimap"

    var body: some View {
        HStack(spacing: 8) {
            CommandField(ctx: ctx).frame(minWidth: 160, idealWidth: 240, maxWidth: 280)
            // in fullscreen zoom and fit say nothing about what is on screen
            if ctx.canvas.fullscreen == nil {
                let pct = Int((ctx.canvas.zoom * 100).rounded())
                HStack(spacing: 2) {
                    icon("minus", tr("Afastar", "Zoom out")) { ctx.zoom(1 / 1.2) }
                    Text("\(pct)%").font(.collieMono(12)).monospacedDigit().foregroundStyle(Color.collieTextSecondary)
                        .frame(minWidth: 40).accessibilityLabel("Zoom").accessibilityValue("\(pct)%")
                    icon("plus", tr("Aproximar", "Zoom in")) { ctx.zoom(1.2) }
                }
                Button(tr("Ajustar", "Fit"), action: ctx.fit).buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small)
                    .help(tr("Ajustar à tela", "Fit to screen"))
                Toggle(isOn: $minimap) { Image(systemName: "map") }
                    .toggleStyle(.button).buttonStyle(.plain).foregroundStyle(minimap ? Color.collieText : .collieMuted)
                    .frame(width: 24, height: 24)
                    .help(tr("Minimapa", "Minimap")).accessibilityLabel(tr("Minimapa", "Minimap"))
            }
        }
        .padding(.leading, 6).padding(.trailing, 10).frame(height: 40).floating()
    }

    private func icon(_ name: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.collieTextSecondary)
                .frame(width: 22, height: 24).contentShape(.rect)
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

private extension View {
    func floating() -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        return background(shape.fill(Color.collieSurface.opacity(0.92))).overlay(shape.strokeBorder(Color.collieBorder, lineWidth: 1))
    }
}

/// Looks like a search field; opens the command palette (⌘K).
private struct CommandField: View {
    let ctx: ShellContext

    var body: some View {
        Button(action: ctx.openPalette) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text(tr("Chamar, abrir painel, ir para cercado…", "Summon, open panel, go to paddock…")).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text("⌘K").font(.collieMono(11))
            }
            .font(.collieUI(13)).foregroundStyle(Color.collieMuted)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Color.collieSunken, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.collieBorder, lineWidth: 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(tr("Comando (⌘K)", "Command (⌘K)")).accessibilityLabel(tr("Comando", "Command"))
    }
}

struct HostNotice: View {
    let client: DaemonClient

    var body: some View {
        if client.hostStatus == .replaced {
            HStack(spacing: 6) {
                Text(tr("Outra janela do Collie está hospedando os painéis", "Another Collie window is hosting the panels")).foregroundStyle(Color.collieAttention)
                Button(tr("Retomar", "Take over")) { client.resumeHost() }
            }
        }
    }
}

// MARK: - Lotes

// MARK: - Completa

/// Lotes (the paddock ⋯ menu's sheet): terminals grouped by effort (name, goal, members). Only a lot without terminals can be deleted (its memories stay).
struct LotsSection: View {
    let client: DaemonClient
    @State private var deleting: Lot?
    @State private var opened: Lot?
    @State private var creating = false
    @State private var newName = ""
    @State private var newGoal = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr("Lotes", "Lots")).font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText).accessibilityAddTraits(.isHeader)
            ForEach(client.lots) { l in
                let names = LotSummary.memberNames(l, terminals: client.terminals)
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.name).font(.collieUI(13, .medium)).foregroundStyle(Color.collieText).lineLimit(1)
                    if !l.goal.isEmpty { Text(l.goal).font(.collieUI(11)).foregroundStyle(Color.collieTextSecondary).lineLimit(2) }
                    Text(names.isEmpty ? tr("sem terminais", "no terminals") : names.joined(separator: ", "))
                        .font(.collieMono(10)).foregroundStyle(Color.collieMuted).lineLimit(2)
                }
                .padding(.horizontal, 8).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                .help(LotSummary.help(l, names: names))
                .onTapGesture { opened = l }
                .contextMenu {
                    Button(tr("Abrir quadro", "Open board")) { opened = l }
                    Button(tr("Apagar lote…", "Delete lot…")) { deleting = l }.disabled(!client.isEmpty(l))
                }
            }
            Button(tr("Novo lote…", "New lot…")) { newName = ""; newGoal = ""; creating = true }.buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small)
            if let error { Text(error).font(.collieUI(11)).foregroundStyle(Color.collieDanger).lineLimit(3) }
        }
        .sheet(item: $opened) { l in LotView(client: client, lot: l) { opened = nil } }
        .confirmationDialog(tr("Apagar o lote \(deleting?.name ?? "")?", "Delete lot \(deleting?.name ?? "")?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(tr("Apagar lote", "Delete lot"), role: .destructive) { if let l = deleting { run { try await client.deleteLot(l.name) } } }
            Button(tr("Cancelar", "Cancel"), role: .cancel) {}
        } message: { Text(tr("As memórias do lote continuam guardadas.", "The lot's memories stay saved.")) }
        .alert(tr("Novo lote", "New lot"), isPresented: $creating) {
            TextField(tr("Nome", "Name"), text: $newName)
            TextField(tr("Objetivo", "Goal"), text: $newGoal)
            Button(tr("Criar", "Create")) {
                let n = newName.trimmingCharacters(in: .whitespaces), g = newGoal
                if !n.isEmpty { run { try await client.createLot(name: n, goal: g) } }
            }
            Button(tr("Cancelar", "Cancel"), role: .cancel) {}
        } message: { Text(tr("Agrupa terminais de um mesmo esforço. Não liga ninguém: só a guia dá alcance.", "Groups terminals working on the same effort. It connects no one: only a leash gives reach.")) }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        error = nil
        Task { do { try await op() } catch { self.error = "\(error)" } }
    }
}

/// A lot opened from the Lotes sheet. Quadro: its board, newest first — agents' text, shown as plain text (never a link or
/// markdown), read again on open and on Atualizar.
private struct LotView: View {
    let client: DaemonClient
    let lot: Lot
    let close: () -> Void
    @State private var posts: [LotPost] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(lot.name).font(.collieUI(15, .medium)).foregroundStyle(Color.collieText).lineLimit(1)
                Spacer()
                Button(tr("Atualizar", "Refresh")) { Task { await load() } }.buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small)
                Button(tr("Fechar", "Close"), action: close).keyboardShortcut(.cancelAction).controlSize(.small)
            }
            TabView {
                board.tabItem { Text(tr("Quadro", "Board")) }
                LotGrantsList(lot: lot, client: client).tabItem { Text(tr("Liberados", "Granted")) }
            }
        }
        .padding(12).frame(minWidth: 480, minHeight: 360)
        .task { await load() }
    }

    private var board: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let error { Text(error).font(.collieUI(11)).foregroundStyle(Color.collieDanger) }
                if posts.isEmpty && error == nil {
                    Text(tr("Nenhum recado ainda. Os agentes do lote postam com collie lot post.", "No messages yet. The lot's agents post with collie lot post.")).font(.collieUI(12)).foregroundStyle(Color.collieMuted)
                }
                ForEach(posts) { p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LotSummary.postHeader(p)).font(.collieMono(10)).foregroundStyle(Color.collieMuted).lineLimit(1)
                        Text(verbatim: p.text).font(.collieUI(12)).foregroundStyle(Color.collieText).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(4)
        }
    }

    private func load() async {
        do { posts = try await client.lotBoard(lot.name); error = nil } catch { self.error = "\(error)" }
    }
}

/// The Lotes sheet's copy for a lot (tested without the app).
enum LotSummary {
    /// Member names in lot order; ids that are no longer terminals are skipped.
    static func memberNames(_ l: Lot, terminals: [TerminalRecord]) -> [String] {
        l.members.compactMap { m in terminals.first { $0.id == m }?.name }
    }
    /// `entrega · A → B · ref x · 14:03` (kind in the active language).
    static func postHeader(_ p: LotPost) -> String {
        let kind: String = switch p.kind {
        case "handoff": tr("entrega", "handoff")
        case "question": tr("pergunta", "question")
        case "answer": tr("resposta", "answer")
        default: p.kind
        }
        let who = p.from + (p.toName.map { " → \($0)" } ?? "")
        return [kind, who, p.ref.map { "ref \($0)" }, p.at.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · ")
    }
    static func help(_ l: Lot, names: [String]) -> String {
        [l.name, l.goal.isEmpty ? nil : l.goal, names.isEmpty ? tr("sem terminais", "no terminals") : tr("\(names.count) terminal\(names.count == 1 ? "" : "is")", "\(names.count) terminal\(names.count == 1 ? "" : "s")")]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
