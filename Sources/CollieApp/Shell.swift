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
    /// The rail's gear. The Ajustes window for now; T5 points it at the embedded Preferências.
    var openPreferences: () -> Void = {}
    /// The cards of "O que o Collie faz" the user has seen (the info icon's dot) and the modal that shows them.
    var tour = FeatureTourSeen()
    var openTour: () -> Void = {}
    /// Brings the Work panel forward (opens it where it was not).
    var openWork: () -> Void = {}
    /// A HISTÓRICO row was clicked (a closed work's id). Empty until T6.5 opens its detail.
    var onOpenHistory: (String) -> Void = { _ in }
    /// The short warning the HISTÓRICO section shows when a detail could not be opened.
    var historyNotice: () -> String? = { nil }
    /// M8.2: "Ver tudo" (or the card) of LAÇOS: the Laços modal on that tab. Empty until M8.3 opens the modal.
    var onOpenLoops: (LoopsTab) -> Void = { _ in }
}

/// The window frame around `content` (docks + canvas). Compacta adds nothing here (its bar floats over the canvas,
/// see `CanvasChrome`); Completa (Trilho) adds the paddock rail, the context panel, the tab strip and the status bar in
/// optional slots around `content`, which keeps one position in the hierarchy: switching structure never remakes the
/// canvas or the panels. In Completa, `mainView == .preferences` shows `preferences` in place of `content`, which stays
/// mounted underneath (invisible, no hits, hidden from accessibility): terminals, zoom and positions survive.
struct Shell<Content: View, Preferences: View>: View {
    let structure: WindowStructure
    let ctx: ShellContext
    @Binding var mainView: MainViewState
    let content: Content
    let preferences: Preferences
    /// One-time sandbox notice (UserDefaults via @AppStorage, like the other UI state); a new key for open mode: shown again once.
    @AppStorage("sandbox.openNoticeSeen") private var noticeSeen = false

    init(structure: WindowStructure, ctx: ShellContext, mainView: Binding<MainViewState>,
         @ViewBuilder content: () -> Content, @ViewBuilder preferences: () -> Preferences) {
        self.structure = structure; self.ctx = ctx; _mainView = mainView
        self.content = content(); self.preferences = preferences()
    }

    var body: some View {
        let full = structure == .full
        let prefs = full && mainView.isPreferences   // Compacta keeps the Ajustes window
        HStack(spacing: 0) {
            if full { PaddockRail(ctx: ctx); ContextPanel(ctx: ctx) }
            VStack(spacing: 0) {
                if full { MainTabs(ctx: ctx, mainView: $mainView) }
                ZStack {
                    content.opacity(prefs ? 0 : 1).allowsHitTesting(!prefs).accessibilityHidden(prefs)
                    if prefs { preferences.background(EscCatcher { mainView.back() }) }
                }
                if full { StatusBar(ctx: ctx) }
            }
        }
        .background(Color.collieBackground)
        .alert("Terminais com sandbox", isPresented: Binding(get: { !noticeSeen }, set: { if !$0 { noticeSeen = true } })) {
            Button("Entendi") { noticeSeen = true }
            Button("Ler no README") {
                noticeSeen = true
                NSWorkspace.shared.open(URL(string: "https://github.com/ysraelmoreno/collie#sandbox-dos-terminais")!)
            }
        } message: {
            Text("Os terminais rodam no sandbox aberto (padrão): o agente lê e escreve tudo na sua conta, inclusive chaves e tokens, e pode apagar qualquer coisa; só os dados, o app e o daemon do Collie ficam fechados ao acesso direto. O que ele gravar e você executar depois (rc do shell, LaunchAgents, binários, hooks do git) roda sem sandbox e alcança tudo, o Collie incluído. Em Preferências, \"Modo do sandbox\" muda para Estrito (escrita só no projeto, segredos fechados, cartões para liberar); vale para terminais abertos depois.")
        }
    }
}

/// Behind Completa's Preferências: Esc goes back to the canvas. It also takes the keyboard from whatever had it on the
/// hidden canvas (a terminal would keep receiving the typing). A monitor, like `CanvasViewport`'s: clicking empty space
/// leaves the window itself as first responder and no view would see the key. Esc stays with a text field or editor
/// (`NSText`, the field editor included) and with a sheet (another window, or attached to this one).
private struct EscCatcher: NSViewRepresentable {
    let back: () -> Void
    func makeNSView(context: Context) -> Catcher { Catcher() }
    func updateNSView(_ v: Catcher, context: Context) { v.back = back }

    final class Catcher: NSView {
        var back: () -> Void = {}
        private var monitor: Any?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with e: NSEvent) {}   // typing with nothing focused: no beep (⌘ shortcuts never come here)

        override func viewDidMoveToWindow() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard let window else { return }
            window.makeFirstResponder(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                MainActor.assumeIsolated { self?.escape(e) ?? false } ? nil : e
            }
        }

        private func escape(_ e: NSEvent) -> Bool {
            guard e.keyCode == 53, e.window === window, window?.attachedSheet == nil,
                  !(window?.firstResponder is NSText) else { return false }
            back()
            return true
        }
    }
}

extension Shell where Preferences == EmptyView {
    /// Without Preferências in the main area (Compacta only, and tests of the frame).
    init(structure: WindowStructure, ctx: ShellContext, @ViewBuilder content: () -> Content) {
        self.init(structure: structure, ctx: ctx, mainView: .constant(MainViewState()), content: content) { EmptyView() }
    }
}

/// Floats over the canvas: Compacta's bar (top left) and zoom (top right), then the banners and, disconnected, the chip.
struct CanvasChrome<Banners: View>: View {
    let structure: WindowStructure
    let ctx: ShellContext
    @ViewBuilder let banners: Banners
    static var lightsInset: CGFloat { 28 }

    var body: some View {
        VStack(spacing: 8) {
            if structure == .compact {
                HStack(alignment: .top, spacing: 8) {
                    CompactBar(ctx: ctx)
                    Spacer(minLength: 0)
                    ZoomControls(ctx: ctx).padding(.horizontal, 10).frame(height: 44).floating()
                }
                if case .disconnected(let r) = ctx.client.state {
                    Text("Desconectado: \(r)").font(.collieMono(11, .medium)).foregroundStyle(Color.collieDanger)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color.collieSurface))
                        .overlay(Capsule().strokeBorder(Color.collieDanger.opacity(0.6), lineWidth: 1))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            banners
            if structure == .compact { HostNotice(client: ctx.client) }
        }
        .padding(.horizontal, structure == .compact ? 12 : 0)
        .padding(.bottom, structure == .compact ? 12 : 0)
        .padding(.top, structure == .compact ? Self.lightsInset : 0)   // the hidden title bar leaves the traffic lights over the canvas
    }
}

private extension View {
    func floating() -> some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        return background(shape.fill(Color.collieSurface.opacity(0.92))).overlay(shape.strokeBorder(Color.collieBorder, lineWidth: 1))
    }
}

// MARK: - Compacta

private struct CompactBar: View {
    let ctx: ShellContext

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) { CollieMark(size: 18); Text("collie").font(.collieUI(15, .bold)).foregroundStyle(Color.collieText) }
            PaddockChips(ctx: ctx)
            CommandField(ctx: ctx).frame(minWidth: 160, idealWidth: 280, maxWidth: 320)
            TourButton(ctx: ctx, ring: .collieSurface, size: CGSize(width: 28, height: 28), tint: .collieTextSecondary)
            UsageButton(ctx: ctx)
        }
        .padding(.horizontal, 12).frame(height: 44).floating()
    }
}

/// Pasto, up to 4 paddock chips (the current one always among them) and "+N" with the rest and "Novo cercado…".
private struct PaddockChips: View {
    let ctx: ShellContext

    var body: some View {
        let client = ctx.client, paddocks = client.paddocks
        let split = chipSplit(paddocks.map(\.id), current: client.currentPaddock, max: 4)
        HStack(spacing: 4) {
            PaddockChip(title: "Pasto", status: nil, selected: client.currentPaddock == nil) { ctx.paddocks.select(nil) }
            ForEach(split.shown, id: \.self) { id in
                if let f = paddocks.first(where: { $0.id == id }) {
                    PaddockChip(title: f.name, status: f.status, selected: client.currentPaddock == id) { ctx.paddocks.select(id) }
                        .contextMenu { PaddockMenu(paddock: f, actions: ctx.paddocks) }
                }
            }
            if let f = paddocks.first(where: { $0.id == client.currentPaddock }) {
                Menu { PaddockMenu(paddock: f, actions: ctx.paddocks) } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Ações do cercado").accessibilityLabel("Ações do cercado")
            }
            if ctx.paddocks.busy { ProgressView().controlSize(.small) }
            Menu {
                ForEach(paddocks.filter { split.overflow.contains($0.id) }) { f in
                    Button("\(f.name) · \(f.status.label)") { ctx.paddocks.select(f.id) }
                }
                if !split.overflow.isEmpty { Divider() }
                NewPaddockButton(actions: ctx.paddocks)
            } label: {
                Text(split.overflow.isEmpty ? "+" : "+\(split.overflow.count)").font(.collieMono(12, .medium))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(split.overflow.isEmpty ? "Novo cercado…" : "Mais cercados")
            .accessibilityLabel(split.overflow.isEmpty ? "Novo cercado…" : "Mais \(split.overflow.count) cercados")
        }
    }
}

private struct PaddockChip: View {
    let title: String
    let status: PaddockStatus?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let status { PaddockStatusDot(status: status) }
                Text(title).lineLimit(1)
            }
            .font(.collieUI(13, .medium)).foregroundStyle(selected ? Color.collieText : .collieMuted)
            .padding(.horizontal, 10).frame(height: 28)
            .background(selected ? Color.collieRaised : .clear, in: .rect(cornerRadius: 9))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(status.map { "\(title) · \($0.label)" } ?? title)
        .accessibilityValue(status?.label ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Looks like a search field; opens the command palette (⌘K).
private struct CommandField: View {
    let ctx: ShellContext

    var body: some View {
        Button(action: ctx.openPalette) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text("Chamar, abrir painel, ir para cercado…").lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text("⌘K").font(.collieMono(11))
            }
            .font(.collieUI(13)).foregroundStyle(Color.collieMuted)
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.collieSunken, in: .rect(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.collieBorder, lineWidth: 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Comando (⌘K)").accessibilityLabel("Comando")
    }
}

/// "41% · 12%" (each provider's highest window), "uso" without numbers; opens the usage popover.
private struct UsageButton: View {
    let ctx: ShellContext

    var body: some View {
        let summary = UsageFeed.summary(ctx.usage.reports)
        Button { ctx.usageOpen.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "gauge")
                Text(summary ?? "uso").font(.collieMono(12)).monospacedDigit()
            }
            .foregroundStyle(Color.collieTextSecondary).padding(.horizontal, 8).frame(height: 28).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Uso dos agentes").accessibilityLabel("Uso dos agentes").accessibilityValue(summary ?? "sem dados")
        .popover(isPresented: ctx.usageOpen) { UsagePopover(client: ctx.client, feed: ctx.usage) }
    }
}

struct ZoomControls: View {
    let ctx: ShellContext

    var body: some View {
        // in fullscreen zoom and fit say nothing about what is on screen
        if ctx.canvas.fullscreen == nil { HStack(spacing: 8) {
            let pct = Int((ctx.canvas.zoom * 100).rounded())
            Text("\(pct)%").font(.collieMono(12)).monospacedDigit()
                .foregroundStyle(Color.collieTextSecondary).accessibilityLabel("Zoom").accessibilityValue("\(pct)%")
            Button("Ajustar à tela", action: ctx.fit).buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small)
        } }
    }
}

struct HostNotice: View {
    let client: DaemonClient

    var body: some View {
        if client.hostStatus == .replaced {
            HStack(spacing: 6) {
                Text("Outra janela do Collie está hospedando os painéis").foregroundStyle(Color.collieAttention)
                Button("Retomar") { client.resumeHost() }
            }
        }
    }
}

// MARK: - Completa

/// HERDS: the list (a click opens the sheet with that one) and "Aplicar…".
struct HerdsSection: View {
    let ctx: ShellContext
    @ObservedObject var model: HerdsModel
    init(ctx: ShellContext) { self.ctx = ctx; model = ctx.herds }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("REBANHOS").font(.collieMono(11)).kerning(1.2).foregroundStyle(Color.collieMuted).accessibilityAddTraits(.isHeader)
            ForEach(model.items.prefix(6)) { it in
                Button { ctx.openHerds(it.id) } label: {
                    HStack(spacing: 6) {
                        Text(it.name).font(.collieUI(13)).foregroundStyle(Color.collieText).lineLimit(1)
                        Spacer(minLength: 0)
                        if it.builtIn { CollieTag("de fábrica", tone: .secondary) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4).contentShape(.rect)
                }
                .buttonStyle(.plain).help(it.summary)
            }
            Button("Aplicar…") { ctx.openHerds(nil) }.buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small)
        }
        .task(id: ctx.client.state == .connected) { if ctx.client.state == .connected { await model.refresh() } }
    }
}

/// LOTES: terminals grouped by effort (name, goal, members). Only a lot without terminals can be deleted (its memories stay).
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
            Text("LOTES").font(.collieMono(11)).kerning(1.2).foregroundStyle(Color.collieMuted).accessibilityAddTraits(.isHeader)
            ForEach(client.lots) { l in
                let names = LotSummary.memberNames(l, terminals: client.terminals)
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.name).font(.collieUI(13, .medium)).foregroundStyle(Color.collieText).lineLimit(1)
                    if !l.goal.isEmpty { Text(l.goal).font(.collieUI(11)).foregroundStyle(Color.collieTextSecondary).lineLimit(2) }
                    Text(names.isEmpty ? "sem terminais" : names.joined(separator: ", "))
                        .font(.collieMono(10)).foregroundStyle(Color.collieMuted).lineLimit(2)
                }
                .padding(.horizontal, 8).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                .help(LotSummary.help(l, names: names))
                .onTapGesture { opened = l }
                .contextMenu {
                    Button("Abrir quadro") { opened = l }
                    Button("Apagar lote…") { deleting = l }.disabled(!client.isEmpty(l))
                }
            }
            Button("Novo lote…") { newName = ""; newGoal = ""; creating = true }.buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small)
            if let error { Text(error).font(.collieUI(11)).foregroundStyle(Color.collieDanger).lineLimit(3) }
        }
        .sheet(item: $opened) { l in LotView(client: client, lot: l) { opened = nil } }
        .confirmationDialog("Apagar o lote \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Apagar lote", role: .destructive) { if let l = deleting { run { try await client.deleteLot(l.name) } } }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("As memórias do lote continuam guardadas.") }
        .alert("Novo lote", isPresented: $creating) {
            TextField("Nome", text: $newName)
            TextField("Objetivo", text: $newGoal)
            Button("Criar") {
                let n = newName.trimmingCharacters(in: .whitespaces), g = newGoal
                if !n.isEmpty { run { try await client.createLot(name: n, goal: g) } }
            }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Agrupa terminais de um mesmo esforço. Não liga ninguém: só a guia dá alcance.") }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        error = nil
        Task { do { try await op() } catch { self.error = "\(error)" } }
    }
}

/// A lot opened from the context panel. Quadro: its board, newest first — agents' text, shown as plain text (never a link or
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
                Button("Atualizar") { Task { await load() } }.buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small)
                Button("Fechar", action: close).keyboardShortcut(.cancelAction).controlSize(.small)
            }
            TabView {
                board.tabItem { Text("Quadro") }
                LotGrantsList(lot: lot, client: client).tabItem { Text("Liberados") }
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
                    Text("Nenhum recado ainda. Os agentes do lote postam com collie lot post.").font(.collieUI(12)).foregroundStyle(Color.collieMuted)
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

/// The context panel's copy for a lot (tested without the app).
enum LotSummary {
    /// Member names in lot order; ids that are no longer terminals are skipped.
    static func memberNames(_ l: Lot, terminals: [TerminalRecord]) -> [String] {
        l.members.compactMap { m in terminals.first { $0.id == m }?.name }
    }
    /// `entrega · A → B · ref x · 14:03` (kind in pt-BR).
    static func postHeader(_ p: LotPost) -> String {
        let kind = ["handoff": "entrega", "question": "pergunta", "status": "status", "answer": "resposta"][p.kind] ?? p.kind
        let who = p.from + (p.toName.map { " → \($0)" } ?? "")
        return [kind, who, p.ref.map { "ref \($0)" }, p.at.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · ")
    }
    static func help(_ l: Lot, names: [String]) -> String {
        [l.name, l.goal.isEmpty ? nil : l.goal, names.isEmpty ? "sem terminais" : "\(names.count) terminal\(names.count == 1 ? "" : "is")"]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// The tab strip over Completa's main area: Canvas and Preferências, then the command field (⌘K) and the zoom.
private struct MainTabs: View {
    let ctx: ShellContext
    @Binding var mainView: MainViewState

    var body: some View {
        HStack(spacing: 0) {
            tab("Canvas", .canvas)
            tab("Preferências", .preferences, shortcut: "⌘,")
            Spacer(minLength: 8)
            CommandField(ctx: ctx).frame(minWidth: 160, idealWidth: 280, maxWidth: 320)
            // zoom says nothing about Preferências
            if !mainView.isPreferences { ZoomControls(ctx: ctx).padding(.leading, 10) }
        }
        .padding(.trailing, 10).frame(height: 38)
        .background(Color.collieSidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.collieBorder).frame(height: 1) }
    }

    /// The selected tab: lighter fill, full-color text and the accent underline (never color alone), plus the selected trait.
    private func tab(_ title: String, _ view: MainView, shortcut: String? = nil) -> some View {
        let on = mainView.current == view
        return Button { mainView.show(view) } label: {
            HStack(spacing: 8) {
                Text(title).font(.collieUI(13, on ? .medium : .regular))
                if let shortcut { Text(shortcut).font(.collieMono(11)).opacity(0.7).accessibilityHidden(true) }
            }
            .foregroundStyle(on ? Color.collieText : .collieMuted)
            .padding(.horizontal, 16).frame(maxHeight: .infinity)
            .background(on ? Color.collieBackground : .clear)
            .overlay(alignment: .bottom) { if on { Rectangle().fill(Color.collieAccent).frame(height: 2) } }
            .overlay(alignment: .trailing) { Rectangle().fill(Color.collieBorder).frame(width: 1) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct StatusBar: View {
    let ctx: ShellContext

    var body: some View {
        HStack(spacing: 14) {
            switch ctx.client.state {
            case .connected:
                HStack(spacing: 6) { Circle().fill(Color.collieAccent).frame(width: 7, height: 7); Text("conectado") }
            case .disconnected(let r):
                HStack(spacing: 6) { Circle().fill(Color.collieDanger).frame(width: 7, height: 7); Text("desconectado: \(r)").lineLimit(1) }
            }
            PanelMeter(client: ctx.client)
            if ctx.canvas.fullscreen != nil { Text("tela cheia").foregroundStyle(Color.collieTextSecondary) }
            HostNotice(client: ctx.client)
            Spacer(minLength: 0)
        }
        .font(.collieMono(11)).foregroundStyle(Color.collieMuted)
        .padding(.horizontal, 12).frame(height: 26)
        .background(Color.collieSidebar)
        .overlay(alignment: .top) { Rectangle().fill(Color.collieBorder).frame(height: 1) }
    }
}
