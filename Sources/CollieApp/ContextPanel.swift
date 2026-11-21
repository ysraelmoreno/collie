import SwiftUI
import AppKit
import CollieCanvas
import CollieClient
import CollieCore
import CollieTheme

/// Trilho's context panel (248 pt, right of `PaddockRail`): the current paddock's header and menu, Novo terminal /
/// Abrir painel, the agent tree (`AgentTree`), the panels, then Rebanhos and Lotes.
/// LAÇOS (below Lotes) exists only while a loop of this paddock runs (`LoopSection.visible`): otherwise no header, no gap.
/// It is one card (`LoopCard`); "Ver tudo" and the card open the Laços modal. The history lives in that modal (M8.2).
struct ContextPanel: View {
    let ctx: ShellContext
    /// Shepherds whose leashed terminals are hidden. Local: a relaunch expands everything again.
    @State private var collapsed: Set<UUID> = []
    static var width: CGFloat { 248 }

    var body: some View {
        let client = ctx.client
        let paddock = client.paddocks.first { $0.id == client.currentPaddock }
        let rows = AgentTree.rows(terminals: client.terminals, connections: client.connections, badges: client.badges,
                                  pending: AgentTree.pending(accessCards: client.accessCards, leashRequests: client.leashRequests, appCards: client.appCards),
                                  paddock: client.currentPaddock, collapsed: collapsed)
        let panels = visiblePanels(client.panels, paddock: client.currentPaddock)
        let loops = LoopSection.make(work: client.workFeed.work, paddock: client.currentPaddock)
        let card = LoopCard.make(work: client.workFeed.work, paddock: client.currentPaddock)
        let order = rows.map(\.id) + panels.map(\.id)   // the rows as shown: what a ⇧-click ranges over
        VStack(alignment: .leading, spacing: 12) {
            header(paddock)
            HStack(spacing: 6) {
                Button(action: ctx.newTerminal) { Text("Novo terminal").frame(maxWidth: .infinity) }.buttonStyle(CollieButtonStyle(.primary))
                Button(action: ctx.openPanel) { Image(systemName: "plus.rectangle") }
                    .buttonStyle(CollieButtonStyle(.secondary)).help("Abrir painel…").accessibilityLabel("Abrir painel…")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let titles = Self.sectionTitles(agents: client.terminals.filter { $0.paddockId == client.currentPaddock }.count,
                                                    panels: panels.count, loops: loops)
                    section(titles[0])
                    VStack(alignment: .leading, spacing: 0) { ForEach(rows) { agentRow($0, order: order) } }
                    section(titles[1])
                    VStack(alignment: .leading, spacing: 0) { ForEach(panels) { panelRow($0, order: order) } }
                    HerdsSection(ctx: ctx)
                    LotsSection(client: client)
                    if loops.visible, let card { loopsSection(loops.title, card) }
                }
            }
        }
        .padding(14)
        .padding(.top, CanvasChrome<EmptyView>.lightsInset)   // the traffic lights reach past the rail (hidden title bar)
        .frame(width: Self.width, alignment: .leading).frame(maxHeight: .infinity, alignment: .top)
        .background(Color.collieSidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.collieBorder).frame(width: 1) }
    }

    /// The section titles in the order drawn; LAÇOS only while a loop runs. HISTÓRICO is never here (M8.2: the modal has it).
    static func sectionTitles(agents: Int, panels: Int, loops: LoopSection) -> [String] {
        ["AGENTES · \(agents)", "PAINÉIS · \(panels)", "REBANHOS", "LOTES"] + (loops.visible ? [loops.title] : [])
    }

    /// "Ver tudo" and a click on the card: the Laços modal on its running tab (M8.3 wires the hook).
    static func openLoops(ctx: ShellContext) { ctx.onOpenLoops(.running) }

    private func loopsSection(_ title: String, _ card: LoopCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                section(title)
                Spacer(minLength: 0)
                Button("Ver tudo") { Self.openLoops(ctx: ctx) }
                    .buttonStyle(.plain).font(.collieUI(11)).foregroundStyle(Color.collieAccent).accessibilityLabel("Ver tudo")
            }
            Button { Self.openLoops(ctx: ctx) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(card.title).font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        Text(card.progressText).font(.collieMono(11)).monospacedDigit().foregroundStyle(Color.collieSecondary)
                    }
                    LoopProgressBar(fraction: card.fraction)
                    Text(card.statusText).font(.collieMono(10)).foregroundStyle(Color.collieMuted).lineLimit(1)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.collieSurface, in: .rect(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.collieBorder, lineWidth: 1) }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(card.accessibilityLabel)
            .accessibilityAddTraits(.isButton)
        }
    }

    private func header(_ paddock: Paddock?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(paddock?.name ?? "Pasto").font(.collieUI(20, .semibold)).foregroundStyle(Color.collieText).lineLimit(1)
                if let paddock {
                    Text(paddock.isFolder ? paddock.path : "\(paddock.branch) ← \(paddock.baseBranch)")
                        .font(.collieMono(12)).foregroundStyle(Color.collieMuted).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if let paddock {
                if ctx.paddocks.busy { ProgressView().controlSize(.small) }
                Menu { PaddockMenu(paddock: paddock, actions: ctx.paddocks) } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Menu do cercado").accessibilityLabel("Menu do cercado")
            }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.collieMono(11)).kerning(1.2).foregroundStyle(Color.collieMuted).accessibilityAddTraits(.isHeader)
    }

    /// One terminal: caret (a Shepherd with leashed terminals), status mark, name, pending-cards badge, preset chip.
    /// A click focuses it on the canvas (the path of a notification click); a double click also opens its edit sheet.
    private func agentRow(_ r: AgentTree.Row, order: [UUID]) -> some View {
        let status = NodeStatus(badge: r.status, exitCode: nil)
        let selected = ctx.canvas.selection.contains(r.id)
        return HStack(spacing: 4) {
            if r.isParent {
                Button { collapsed.formSymmetricDifference([r.id]) } label: {
                    Image(systemName: r.isCollapsed ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.collieMuted).frame(width: 16, height: 22).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(r.isCollapsed ? "Expandir \(r.name)" : "Recolher \(r.name)")
            } else {
                Color.clear.frame(width: 16, height: 22)
            }
            Button { click(r.id, order: order) } label: {
                HStack(spacing: 6) {
                    AgentStatusDot(status: status)
                    Text(r.name).font(.collieUI(13, r.depth == 0 ? .medium : .regular)).foregroundStyle(Color.collieText).lineLimit(1)
                    Spacer(minLength: 0)
                    if r.pending > 0 {
                        Text("\(r.pending)").font(.collieMono(10, .medium)).monospacedDigit().foregroundStyle(Color.collieBackground)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Color.collieAttention, in: .capsule)
                            .accessibilityLabel(r.pending == 1 ? "1 cartão pendente" : "\(r.pending) cartões pendentes")
                    }
                    CollieTag(r.preset.rawValue, tone: .neutral)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { ctx.edit(r.id) })
            .help([r.name, status.text].compactMap { $0 }.joined(separator: " · "))
            .accessibilityValue(status.text ?? "ocioso")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        .padding(.vertical, 2).padding(.trailing, 4)
        .padding(.leading, r.depth == 0 ? 0 : 12)
        .background(selected ? Color.collieRaised : .clear, in: .rect(cornerRadius: 7))
        .overlay(alignment: .leading) { if r.depth > 0 { Rectangle().fill(Color.collieBorder).frame(width: 1).padding(.leading, 8) } }
        .overlay { RightClickCatcher { e, v in rightClick(r.id, e, v) } }
    }

    /// ⌘-click flips the item in the selection, ⇧-click selects the rows from the anchor to it; a plain click selects it
    /// and centers it on the canvas.
    private func click(_ id: UUID, order: [UUID]) {
        let m = NSEvent.modifierFlags, canvas = ctx.canvas
        if m.contains(.command) { canvas.selectionState = Selecting.toggle(canvas.selectionState, id) }
        else if m.contains(.shift) { canvas.selectionState = Selecting.range(canvas.selectionState, to: id, in: order) }
        else { ctx.focus(id) }
    }

    /// As in the Finder: outside the selection the right-click moves it to the row; the menu acts on the whole selection.
    private func rightClick(_ id: UUID, _ e: NSEvent, _ view: NSView) {
        let canvas = ctx.canvas
        canvas.selectionState = Selecting.contextClick(canvas.selectionState, id)
        if let m = NodeBatch.menu(ids: canvas.selection, client: ctx.client, canvas: canvas, edit: ctx.edit) {
            NSMenu.popUpContextMenu(m, with: e, for: view)
        }
    }

    /// A panel of this paddock (docked ones show everywhere): a click selects its dock tab or centers it on the canvas.
    private func panelRow(_ p: Panel, order: [UUID]) -> some View {
        let selected = ctx.canvas.selection.contains(p.id)
        return Button {
            if NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty {
                NotificationCenter.default.post(name: .collieFocusPanel, object: p.id)
            }
            click(p.id, order: order)
        } label: {
            HStack(spacing: 6) {
                Text(p.name).font(.collieUI(13)).foregroundStyle(Color.collieText).lineLimit(1)
                Spacer(minLength: 0)
                CollieTag(p.placement == .canvas ? "canvas" : "dock", tone: .neutral)
            }
            .padding(.vertical, 3).padding(.horizontal, 4).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(selected ? Color.collieRaised : .clear, in: .rect(cornerRadius: 7))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .overlay { RightClickCatcher { e, v in rightClick(p.id, e, v) } }
    }
}

/// A terminal's status mark: a shape per status plus the color the node title bar uses (decorative: the row's
/// accessibility value says it). Waiting for you pulses, unless Reduzir movimento is on.
private struct AgentStatusDot: View {
    let status: NodeStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        let pulses = status == .attention && !reduceMotion
        Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            .opacity(pulses && dim ? 0.35 : 1)
            .animation(pulses ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil, value: dim)
            .onAppear { dim = true }
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch status {
        case .idle: "circle"
        case .working: "circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .stopped: "xmark.circle.fill"
        }
    }
    private var color: Color {
        switch status {
        case .idle: .collieMuted
        case .working: .collieSecondary
        case .attention: .collieAttention
        case .stopped: .collieDanger
        }
    }
}

/// The LAÇOS card's thin bar (decorative: the card's label says the count). Animates its fill unless Reduzir movimento is on.
private struct LoopProgressBar: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            Capsule().fill(Color.collieBorder)
                .overlay(alignment: .leading) { Capsule().fill(Color.collieSecondary).frame(width: g.size.width * min(max(fraction, 0), 1)) }
        }
        .frame(height: 4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: fraction)
        .accessibilityHidden(true)
    }
}

/// A loop task's state mark: ✓ done, ◐ running (turns, unless Reduzir movimento is on), – deferred, ○ open (decorative:
/// the row's accessibility label says the state).
private struct LoopStateIcon: View {
    let state: LoopSection.State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turn = false

    var body: some View {
        let spins = state == .running && !reduceMotion
        Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(color).frame(width: 14)
            .rotationEffect(.degrees(spins && turn ? 360 : 0))
            .animation(spins ? .linear(duration: 1.6).repeatForever(autoreverses: false) : nil, value: turn)
            .onAppear { turn = true }
            .accessibilityHidden(true)
    }
    private var symbol: String {
        switch state { case .done: "checkmark"; case .running: "circle.lefthalf.filled"; case .deferred: "minus"; case .open: "circle" }
    }
    private var color: Color {
        switch state { case .done: .collieSecondary; case .running: .collieAccent; case .deferred: .collieAttention; case .open: .collieMuted }
    }
}
