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
    var workspaceName: String?
    var usageOpen: Binding<Bool>
    var newTerminal: () -> Void
    var openPanel: () -> Void
    var fit: () -> Void
    var openPalette: () -> Void
    let herds: HerdsModel
    /// The Herds sheet, with that herd selected (nil: the first).
    var openHerds: (String?) -> Void
}

/// The window frame around `content` (docks + canvas). Compacta adds nothing here (its bar floats over the canvas,
/// see `CanvasChrome`); Completa adds the sidebar, the paddock header and the status bar in optional slots around
/// `content`, which keeps one position in the hierarchy: switching structure never remakes the canvas or the panels.
struct Shell<Content: View>: View {
    let structure: WindowStructure
    let ctx: ShellContext
    @ViewBuilder let content: Content
    /// One-time sandbox notice (UserDefaults via @AppStorage, like the other UI state).
    @AppStorage("sandbox.noticeSeen") private var noticeSeen = false

    var body: some View {
        let full = structure == .full
        HStack(spacing: 0) {
            if full { WorkspaceSidebar(ctx: ctx) }
            VStack(spacing: 0) {
                if full { PaddockHeader(ctx: ctx) }
                content
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
            Text("Os terminais agora rodam num sandbox: o agente só escreve no projeto e lê tudo, menos segredos, perfis de navegador, e-mail e os dados do Collie (esses nunca são liberados). Quando ele tenta escrever fora do projeto, aparece um cartão no terminal para você liberar ou negar. Terminais já abertos entram no sandbox na próxima vez que iniciarem. Para o seu trabalho, use \"Terminal livre (sem sandbox)\".")
        }
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

private struct ZoomControls: View {
    let ctx: ShellContext

    var body: some View {
        HStack(spacing: 8) {
            let pct = Int((ctx.canvas.zoom * 100).rounded())
            Text("\(pct)%").font(.collieMono(12)).monospacedDigit()
                .foregroundStyle(Color.collieTextSecondary).accessibilityLabel("Zoom").accessibilityValue("\(pct)%")
            Button("Ajustar à tela", action: ctx.fit).buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small)
        }
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

private struct WorkspaceSidebar: View {
    let ctx: ShellContext
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let client = ctx.client
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 6) { CollieMark(size: 18); Text("collie").font(.collieUI(15, .bold)).foregroundStyle(Color.collieText) }
                if let n = ctx.workspaceName { Text(n).font(.collieMono(12)).foregroundStyle(Color.collieMuted).lineLimit(1) }
            }
            CommandField(ctx: ctx)
            section("CERCADOS")
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(nil, selected: client.currentPaddock == nil)
                    ForEach(client.paddocks) { f in
                        row(f, selected: client.currentPaddock == f.id).contextMenu { PaddockMenu(paddock: f, actions: ctx.paddocks) }
                    }
                    HStack {
                        NewPaddockButton(actions: ctx.paddocks).buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small)
                        if ctx.paddocks.busy { ProgressView().controlSize(.small) }
                    }
                }
            }
            HerdsSection(ctx: ctx)
            LotsSection(client: client)
            section("USO")
            usage
            Button { openSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 14)).foregroundStyle(Color.collieMuted).frame(width: 24, height: 24).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Preferências (⌘,)").accessibilityLabel("Preferências")
        }
        .padding(14)
        .padding(.top, CanvasChrome<EmptyView>.lightsInset)   // "collie" sits below the traffic lights (hidden title bar)
        .frame(width: 240, alignment: .leading).frame(maxHeight: .infinity, alignment: .top)
        .background(Color.collieSidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.collieBorder).frame(width: 1) }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.collieMono(11)).kerning(1.2).foregroundStyle(Color.collieMuted).accessibilityAddTraits(.isHeader)
    }

    private func row(_ f: Paddock?, selected: Bool) -> some View {
        Button { ctx.paddocks.select(f?.id) } label: {
            HStack(spacing: 8) {
                PaddockStatusDot(status: f?.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(f?.name ?? "Pasto").font(.collieUI(13, .medium)).foregroundStyle(Color.collieText).lineLimit(1)
                    if let f { Text(f.branch).font(.collieMono(11)).foregroundStyle(Color.collieMuted).lineLimit(1).truncationMode(.middle) }
                }
                Spacer(minLength: 0)
                if let f { Text(f.status.label).font(.collieMono(10)).foregroundStyle(Color.collieMuted).lineLimit(1).fixedSize() }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected ? Color.collieRaised : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(f.map { "\($0.name) · \($0.status.label)" } ?? "Pasto")
        .accessibilityValue(f?.status.label ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// One line per provider: its highest window ("claude · 5h", 41%) over a thin bar; a click opens the details.
    private var usage: some View {
        let feed = ctx.usage
        return Button { ctx.usageOpen.wrappedValue.toggle() } label: {
            VStack(alignment: .leading, spacing: 8) {
                if !feed.loaded { Text("carregando…") }
                else if let e = feed.failure { Text(e).foregroundStyle(Color.collieDanger).lineLimit(2) }
                else if feed.reports.isEmpty { Text("nenhum provedor") }
                ForEach(feed.reports, id: \.providerId) { r in
                    let w = r.windows.max { ($0.usedPercent ?? -1) < ($1.usedPercent ?? -1) }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(w.map { "\(r.label) · \($0.label)" } ?? r.label).lineLimit(1)
                            Spacer()
                            Text(w?.usedPercent.map { "\(Int($0.rounded()))%" } ?? "—").monospacedDigit()
                        }
                        ProgressView(value: min(max((w?.usedPercent ?? 0) / 100, 0), 1)).tint(Color.collieAccent).controlSize(.mini)
                    }
                }
            }
            .font(.collieMono(11)).foregroundStyle(Color.collieTextSecondary).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Uso dos agentes")
        .popover(isPresented: ctx.usageOpen) { UsagePopover(client: ctx.client, feed: feed) }
    }
}

/// HERDS: the list (a click opens the sheet with that one) and "Aplicar…".
private struct HerdsSection: View {
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
private struct LotsSection: View {
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

/// A lot opened from the sidebar. Quadro: its board, newest first — agents' text, shown as plain text (never a link or
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

/// The sidebar's copy for a lot (tested without the app).
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

private struct PaddockHeader: View {
    let ctx: ShellContext

    var body: some View {
        let paddock = ctx.client.paddocks.first { $0.id == ctx.client.currentPaddock }
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(paddock?.name ?? "Pasto").font(.collieUI(22, .semibold)).foregroundStyle(Color.collieText)
                if let paddock { Text("\(paddock.branch) ← \(paddock.baseBranch)").font(.collieMono(12)).foregroundStyle(Color.collieMuted) }
            }
            Spacer()
            if let paddock {
                if ctx.paddocks.busy { ProgressView().controlSize(.small) }
                Menu { PaddockMenu(paddock: paddock, actions: ctx.paddocks) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Menu do cercado").accessibilityLabel("Menu do cercado")
            }
            Button("Novo terminal", action: ctx.newTerminal).buttonStyle(CollieButtonStyle(.secondary))
            Button(action: ctx.openPanel) { Image(systemName: "plus.rectangle") }
                .buttonStyle(CollieButtonStyle(.secondary)).help("Abrir painel…").accessibilityLabel("Abrir painel…")
            ZoomControls(ctx: ctx)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color.collieBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.collieBorder).frame(height: 1) }
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
            HostNotice(client: ctx.client)
            Spacer(minLength: 0)
        }
        .font(.collieMono(11)).foregroundStyle(Color.collieMuted)
        .padding(.horizontal, 12).frame(height: 26)
        .background(Color.collieSidebar)
        .overlay(alignment: .top) { Rectangle().fill(Color.collieBorder).frame(height: 1) }
    }
}
