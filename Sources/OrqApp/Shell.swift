import SwiftUI
import OrqCanvas
import OrqClient
import OrqCore
import OrqPlugins
import OrqTheme

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
        .background(Color.orqBackground)
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
                    Text("Desconectado: \(r)").font(.orqMono(11, .medium)).foregroundStyle(Color.orqDanger)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color.orqSurface))
                        .overlay(Capsule().strokeBorder(Color.orqDanger.opacity(0.6), lineWidth: 1))
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
        return background(shape.fill(Color.orqSurface.opacity(0.92))).overlay(shape.strokeBorder(Color.orqBorder, lineWidth: 1))
    }
}

// MARK: - Compacta

private struct CompactBar: View {
    let ctx: ShellContext

    var body: some View {
        HStack(spacing: 10) {
            Text("orq").font(.orqUI(15, .bold)).foregroundStyle(Color.orqText)
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
                Text(split.overflow.isEmpty ? "+" : "+\(split.overflow.count)").font(.orqMono(12, .medium))
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
            .font(.orqUI(13, .medium)).foregroundStyle(selected ? Color.orqText : .orqMuted)
            .padding(.horizontal, 10).frame(height: 28)
            .background(selected ? Color.orqRaised : .clear, in: .rect(cornerRadius: 9))
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
                Text("⌘K").font(.orqMono(11))
            }
            .font(.orqUI(13)).foregroundStyle(Color.orqMuted)
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.orqSunken, in: .rect(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.orqBorder, lineWidth: 1))
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
                Text(summary ?? "uso").font(.orqMono(12)).monospacedDigit()
            }
            .foregroundStyle(Color.orqTextSecondary).padding(.horizontal, 8).frame(height: 28).contentShape(.rect)
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
            Text("\(pct)%").font(.orqMono(12)).monospacedDigit()
                .foregroundStyle(Color.orqTextSecondary).accessibilityLabel("Zoom").accessibilityValue("\(pct)%")
            Button("Ajustar à tela", action: ctx.fit).buttonStyle(OrqButtonStyle(.quiet)).controlSize(.small)
        }
    }
}

struct HostNotice: View {
    let client: DaemonClient

    var body: some View {
        if client.hostStatus == .replaced {
            HStack(spacing: 6) {
                Text("Outra janela do Orq está hospedando os painéis").foregroundStyle(Color.orqAttention)
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
                Text("orq").font(.orqUI(15, .bold)).foregroundStyle(Color.orqText)
                if let n = ctx.workspaceName { Text(n).font(.orqMono(12)).foregroundStyle(Color.orqMuted).lineLimit(1) }
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
                        NewFloorButton(actions: ctx.floors).buttonStyle(OrqButtonStyle(.quiet)).controlSize(.small)
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
        .background(Color.orqSidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.orqBorder).frame(width: 1) }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.orqMono(11)).kerning(1.2).foregroundStyle(Color.orqMuted).accessibilityAddTraits(.isHeader)
    }

    private func row(_ f: Floor?, selected: Bool) -> some View {
        Button { ctx.floors.select(f?.id) } label: {
            HStack(spacing: 8) {
                FloorStatusDot(status: f?.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(f?.name ?? "Térreo").font(.orqUI(13, .medium)).foregroundStyle(Color.orqText).lineLimit(1)
                    if let f { Text(f.branch).font(.orqMono(11)).foregroundStyle(Color.orqMuted).lineLimit(1).truncationMode(.middle) }
                }
                Spacer(minLength: 0)
                if let f { Text(f.status.label).font(.orqMono(10)).foregroundStyle(Color.orqMuted).lineLimit(1).fixedSize() }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected ? Color.orqRaised : .clear, in: .rect(cornerRadius: 8))
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
                else if let e = feed.failure { Text(e).foregroundStyle(Color.orqDanger).lineLimit(2) }
                else if feed.reports.isEmpty { Text("nenhum provedor") }
                ForEach(feed.reports, id: \.providerId) { r in
                    let w = r.windows.max { ($0.usedPercent ?? -1) < ($1.usedPercent ?? -1) }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(w.map { "\(r.label) · \($0.label)" } ?? r.label).lineLimit(1)
                            Spacer()
                            Text(w?.usedPercent.map { "\(Int($0.rounded()))%" } ?? "—").monospacedDigit()
                        }
                        ProgressView(value: min(max((w?.usedPercent ?? 0) / 100, 0), 1)).tint(Color.orqAccent).controlSize(.mini)
                    }
                }
            }
            .font(.orqMono(11)).foregroundStyle(Color.orqTextSecondary).contentShape(.rect)
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
            Text("PARTITURAS").font(.orqMono(11)).kerning(1.2).foregroundStyle(Color.orqMuted).accessibilityAddTraits(.isHeader)
            ForEach(model.items.prefix(6)) { it in
                Button { ctx.openPartituras(it.id) } label: {
                    HStack(spacing: 6) {
                        Text(it.name).font(.orqUI(13)).foregroundStyle(Color.orqText).lineLimit(1)
                        Spacer(minLength: 0)
                        if it.builtIn { OrqTag("de fábrica", tone: .secondary) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4).contentShape(.rect)
                }
                .buttonStyle(.plain).help(it.summary)
            }
            Button("Aplicar…") { ctx.openPartituras(nil) }.buttonStyle(OrqButtonStyle(.quiet)).controlSize(.small)
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
                Text(floor?.name ?? "Térreo").font(.orqUI(22, .semibold)).foregroundStyle(Color.orqText)
                if let floor { Text("\(floor.branch) ← \(floor.baseBranch)").font(.orqMono(12)).foregroundStyle(Color.orqMuted) }
            }
            Spacer()
            if let floor {
                if ctx.floors.busy { ProgressView().controlSize(.small) }
                Menu { FloorMenu(floor: floor, actions: ctx.floors) } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Menu do andar").accessibilityLabel("Menu do andar")
            }
            Button("Novo terminal", action: ctx.newTerminal).buttonStyle(OrqButtonStyle(.secondary))
            Button(action: ctx.openPanel) { Image(systemName: "plus.rectangle") }
                .buttonStyle(OrqButtonStyle(.secondary)).help("Abrir painel…").accessibilityLabel("Abrir painel…")
            ZoomControls(ctx: ctx)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color.orqBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.orqBorder).frame(height: 1) }
    }
}

private struct StatusBar: View {
    let ctx: ShellContext

    var body: some View {
        HStack(spacing: 14) {
            switch ctx.client.state {
            case .connected:
                HStack(spacing: 6) { Circle().fill(Color.orqAccent).frame(width: 7, height: 7); Text("conectado") }
            case .disconnected(let r):
                HStack(spacing: 6) { Circle().fill(Color.orqDanger).frame(width: 7, height: 7); Text("desconectado: \(r)").lineLimit(1) }
            }
            PanelMeter(client: ctx.client)
            HostNotice(client: ctx.client)
            Spacer(minLength: 0)
        }
        .font(.orqMono(11)).foregroundStyle(Color.orqMuted)
        .padding(.horizontal, 12).frame(height: 26)
        .background(Color.orqSidebar)
        .overlay(alignment: .top) { Rectangle().fill(Color.orqBorder).frame(height: 1) }
    }
}
