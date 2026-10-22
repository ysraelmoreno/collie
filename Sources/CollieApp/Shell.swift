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
    let floors: FloorActions
    let usage: UsageFeed
    var workspaceName: String?
    var usageOpen: Binding<Bool>
    var newTerminal: () -> Void
    var openPanel: () -> Void
    var fit: () -> Void
    var openPalette: () -> Void
    let partituras: PartiturasModel
    /// The Partituras sheet, with that partitura selected (nil: the first).
    var openPartituras: (String?) -> Void
}

/// The window frame around `content` (docks + canvas). Compacta adds nothing here (its bar floats over the canvas,
/// see `CanvasChrome`); Completa adds the sidebar, the floor header and the status bar in optional slots around
/// `content`, which keeps one position in the hierarchy: switching structure never remakes the canvas or the panels.
struct Shell<Content: View>: View {
    let structure: WindowStructure
    let ctx: ShellContext
    @ViewBuilder let content: Content

    var body: some View {
        let full = structure == .full
        HStack(spacing: 0) {
            if full { WorkspaceSidebar(ctx: ctx) }
            VStack(spacing: 0) {
                if full { FloorHeader(ctx: ctx) }
                content
                if full { StatusBar(ctx: ctx) }
            }
        }
        .background(Color.collieBackground)
        .toolbar(.hidden, for: .windowToolbar)   // the traffic lights stay
    }
}

/// Floats over the canvas: Compacta's bar (top left) and zoom (top right), then the banners and, disconnected, the chip.
struct CanvasChrome<Banners: View>: View {
    let structure: WindowStructure
    let ctx: ShellContext
    @ViewBuilder let banners: Banners

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
        .padding(structure == .compact ? 12 : 0)
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
            Text("collie").font(.collieUI(15, .bold)).foregroundStyle(Color.collieText)
            FloorChips(ctx: ctx)
            CommandField(ctx: ctx).frame(minWidth: 160, idealWidth: 280, maxWidth: 320)
            UsageButton(ctx: ctx)
        }
        .padding(.horizontal, 12).frame(height: 44).floating()
    }
}

/// Térreo, up to 4 floor chips (the current one always among them) and "+N" with the rest and "Novo andar…".
private struct FloorChips: View {
    let ctx: ShellContext

    var body: some View {
        let client = ctx.client, floors = client.floors
        let split = chipSplit(floors.map(\.id), current: client.currentFloor, max: 4)
        HStack(spacing: 4) {
            FloorChip(title: "Térreo", status: nil, selected: client.currentFloor == nil) { ctx.floors.select(nil) }
            ForEach(split.shown, id: \.self) { id in
                if let f = floors.first(where: { $0.id == id }) {
                    FloorChip(title: f.name, status: f.status, selected: client.currentFloor == id) { ctx.floors.select(id) }
                        .contextMenu { FloorMenu(floor: f, actions: ctx.floors) }
                }
            }
            if let f = floors.first(where: { $0.id == client.currentFloor }) {
                Menu { FloorMenu(floor: f, actions: ctx.floors) } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Ações do andar").accessibilityLabel("Ações do andar")
            }
            if ctx.floors.busy { ProgressView().controlSize(.small) }
            Menu {
                ForEach(floors.filter { split.overflow.contains($0.id) }) { f in
                    Button("\(f.name) · \(f.status.label)") { ctx.floors.select(f.id) }
                }
                if !split.overflow.isEmpty { Divider() }
                NewFloorButton(actions: ctx.floors)
            } label: {
                Text(split.overflow.isEmpty ? "+" : "+\(split.overflow.count)").font(.collieMono(12, .medium))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(split.overflow.isEmpty ? "Novo andar…" : "Mais andares")
            .accessibilityLabel(split.overflow.isEmpty ? "Novo andar…" : "Mais \(split.overflow.count) andares")
        }
    }
}

private struct FloorChip: View {
    let title: String
    let status: FloorStatus?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let status { FloorStatusDot(status: status) }
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
                Text("Recrutar, abrir painel, ir para andar…").lineLimit(1).truncationMode(.tail)
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

    var body: some View {
        let client = ctx.client
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("collie").font(.collieUI(15, .bold)).foregroundStyle(Color.collieText)
                if let n = ctx.workspaceName { Text(n).font(.collieMono(12)).foregroundStyle(Color.collieMuted).lineLimit(1) }
            }
            CommandField(ctx: ctx)
            section("ANDARES")
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(nil, selected: client.currentFloor == nil)
                    ForEach(client.floors) { f in
                        row(f, selected: client.currentFloor == f.id).contextMenu { FloorMenu(floor: f, actions: ctx.floors) }
                    }
                    HStack {
                        NewFloorButton(actions: ctx.floors).buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small)
                        if ctx.floors.busy { ProgressView().controlSize(.small) }
                    }
                }
            }
            PartiturasSection(ctx: ctx)
            section("USO")
            usage
        }
        .padding(14)
        .frame(width: 240, alignment: .leading).frame(maxHeight: .infinity, alignment: .top)
        .background(Color.collieSidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.collieBorder).frame(width: 1) }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.collieMono(11)).kerning(1.2).foregroundStyle(Color.collieMuted).accessibilityAddTraits(.isHeader)
    }

    private func row(_ f: Floor?, selected: Bool) -> some View {
        Button { ctx.floors.select(f?.id) } label: {
            HStack(spacing: 8) {
                FloorStatusDot(status: f?.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(f?.name ?? "Térreo").font(.collieUI(13, .medium)).foregroundStyle(Color.collieText).lineLimit(1)
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
        .help(f.map { "\($0.name) · \($0.status.label)" } ?? "Térreo")
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

/// PARTITURAS: the list (a click opens the sheet with that one) and "Aplicar…".
private struct PartiturasSection: View {
    let ctx: ShellContext
    @ObservedObject var model: PartiturasModel
    init(ctx: ShellContext) { self.ctx = ctx; model = ctx.partituras }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PARTITURAS").font(.collieMono(11)).kerning(1.2).foregroundStyle(Color.collieMuted).accessibilityAddTraits(.isHeader)
            ForEach(model.items.prefix(6)) { it in
                Button { ctx.openPartituras(it.id) } label: {
                    HStack(spacing: 6) {
                        Text(it.name).font(.collieUI(13)).foregroundStyle(Color.collieText).lineLimit(1)
                        Spacer(minLength: 0)
                        if it.builtIn { CollieTag("de fábrica", tone: .secondary) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4).contentShape(.rect)
                }
                .buttonStyle(.plain).help(it.summary)
            }
            Button("Aplicar…") { ctx.openPartituras(nil) }.buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small)
        }
        .task(id: ctx.client.state == .connected) { if ctx.client.state == .connected { await model.refresh() } }
    }
}

private struct FloorHeader: View {
    let ctx: ShellContext

    var body: some View {
        let floor = ctx.client.floors.first { $0.id == ctx.client.currentFloor }
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(floor?.name ?? "Térreo").font(.collieUI(22, .semibold)).foregroundStyle(Color.collieText)
                if let floor { Text("\(floor.branch) ← \(floor.baseBranch)").font(.collieMono(12)).foregroundStyle(Color.collieMuted) }
            }
            Spacer()
            if let floor {
                if ctx.floors.busy { ProgressView().controlSize(.small) }
                Menu { FloorMenu(floor: floor, actions: ctx.floors) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Menu do andar").accessibilityLabel("Menu do andar")
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
