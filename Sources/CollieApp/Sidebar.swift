import SwiftUI
import AppKit
import CollieCanvas
import CollieClient
import CollieCore
import CollieTheme

/// The single sidebar (240 pt; collapsed 56 pt, ⌘\): "＋ Novo agente", the paddock list by name with its state in
/// words, the current paddock expanded (header, ⋯ menu, agent tree with each agent's panels), and `footer` at the foot
/// (`SidebarFooter` unless one is passed). Rows come from `SidebarModel`.
struct Sidebar: View {
    let ctx: ShellContext
    @Binding var collapsed: Bool
    var footer: AnyView? = nil
    /// Shepherds whose workers are hidden. Local: a relaunch expands everything again.
    @State private var folded: Set<UUID> = []
    @State private var showLots = false
    @State private var showFactory = false

    static var width: CGFloat { 240 }
    static var collapsedWidth: CGFloat { 56 }

    init(ctx: ShellContext, collapsed: Binding<Bool>, footer: AnyView? = nil) {
        self.ctx = ctx; _collapsed = collapsed; self.footer = footer
    }

    var body: some View {
        let client = ctx.client
        let pending = AgentTree.pending(accessCards: client.accessCards, leashRequests: client.leashRequests, appCards: client.appCards)
        let rows = SidebarModel.paddockRows(paddocks: client.paddocks, terminals: client.terminals, badges: client.badges,
                                            pending: pending, current: client.currentPaddock, panels: client.panels)
        VStack(alignment: .leading, spacing: 10) {
            toggle
            if collapsed { collapsedList(rows) } else { expanded(rows, pending: pending) }
            footer ?? AnyView(SidebarFooter(ctx: ctx, collapsed: collapsed))
        }
        .padding(collapsed ? 8 : 12)
        .padding(.top, CanvasChrome<EmptyView>.lightsInset)   // below the traffic lights (hidden title bar)
        .frame(width: collapsed ? Self.collapsedWidth : Self.width, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.collieSidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.collieBorder).frame(width: 1) }
    }

    /// ⌘\ lives on this visible button, so the shortcut works wherever the sidebar is mounted.
    private var toggle: some View {
        HStack {
            if !collapsed { Spacer(minLength: 0) }
            Button { collapsed.toggle() } label: {
                Image(systemName: "sidebar.left").font(.system(size: 13)).foregroundStyle(Color.collieMuted)
                    .frame(width: 28, height: 22).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("\\", modifiers: .command)
            .help(collapsed ? tr("Mostrar a lateral (⌘\\)", "Show sidebar (⌘\\)") : tr("Recolher a lateral (⌘\\)", "Collapse sidebar (⌘\\)"))
            .accessibilityLabel(collapsed ? tr("Mostrar a lateral", "Show sidebar") : tr("Recolher a lateral", "Collapse sidebar"))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: expanded

    private func expanded(_ rows: [SidebarModel.PaddockRow], pending: [UUID: Int]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            newAgent
            HStack {
                Text(tr("Cercados", "Paddocks")).font(.collieUI(12, .medium)).foregroundStyle(Color.collieMuted).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if ctx.paddocks.busy { ProgressView().controlSize(.mini) }
                Button { ctx.paddocks.newPaddock() } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.collieMuted)
                        .frame(width: 20, height: 20).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(tr("Novo cercado…", "New paddock…")).accessibilityLabel(tr("Novo cercado…", "New paddock…"))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { r in
                        if r.isCurrent { current(r, pending: pending) } else { paddockRow(r) }
                    }
                }
            }
        }
    }

    private var newAgent: some View {
        Menu {
            Button(tr("Terminal simples", "Plain terminal"), action: ctx.newTerminal)
            Button(tr("Painel…", "Panel…"), action: ctx.openPanel)
            Button(tr("A partir de rebanho…", "From a herd…")) { ctx.openHerds(nil) }
        } label: {
            Text(tr("＋ Novo agente", "＋ New agent")).font(.collieUI(13, .medium)).foregroundStyle(Color.collieOnAccent)
                .frame(maxWidth: .infinity).frame(height: 32)
                .background(Color.collieAccent, in: .rect(cornerRadius: 9)).contentShape(.rect)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .accessibilityLabel(tr("Novo agente", "New agent"))
    }

    private func select(_ id: UUID?) { ctx.paddocks.select(id) }
    private func paddock(_ id: UUID?) -> Paddock? { id.flatMap { id in ctx.client.paddocks.first { $0.id == id } } }

    /// One paddock: dot + name + state in words; a click moves to it.
    private func paddockRow(_ r: SidebarModel.PaddockRow) -> some View {
        Button { select(r.id) } label: {
            HStack(spacing: 8) {
                StateDot(status: r.activity.dot)
                Text(r.name).font(.collieUI(13)).foregroundStyle(Color.collieText).lineLimit(1)
                Spacer(minLength: 4)
                Text(r.status).font(.collieUI(11)).foregroundStyle(r.needs > 0 ? Color.collieAttention : .collieMuted).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 5).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(r.name) · \(r.status)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(r.name), \(r.status)")
        .accessibilityAddTraits(.isButton)
        .contextMenu { if let p = paddock(r.id) { PaddockMenu(paddock: p, actions: ctx.paddocks) } }
    }

    /// The current paddock: header (name, branch in mono, ⋯) and its tree.
    private func current(_ r: SidebarModel.PaddockRow, pending: [UUID: Int]) -> some View {
        let client = ctx.client
        let tree = SidebarModel.tree(terminals: client.terminals, connections: client.connections, badges: client.badges,
                                     pending: pending, panels: client.panels, paddock: r.id, collapsed: folded)
        let order = tree.map(\.id)   // the rows as shown: what a ⇧-click ranges over
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                StateDot(status: r.activity.dot).padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.name).font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText).lineLimit(1)
                    if let b = r.branch {
                        Text(b).font(.collieMono(11)).foregroundStyle(Color.collieMuted).lineLimit(1).truncationMode(.middle).help(b)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(r.name), \(r.status)")
                .accessibilityAddTraits([.isSelected, .isHeader])
                Spacer(minLength: 0)
                if let p = paddock(r.id) { paddockMenu(p) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            ForEach(tree) { row in
                switch row.kind {
                case .agent(let a): agentRow(a, role: row.role, order: order)
                case .panel(let p): panelRow(p, depth: row.depth, order: order)
                }
            }
        }
        .padding(.bottom, 4)
        .background(Color.collieRaised.opacity(0.5), in: .rect(cornerRadius: 9))
    }

    /// Today's paddock menu plus Lotes… and Fábrica… (both moved out of the always-open sections).
    private func paddockMenu(_ p: Paddock) -> some View {
        Menu {
            PaddockMenu(paddock: p, actions: ctx.paddocks)
            Divider()
            Button(tr("Lotes…", "Lots…")) { showLots = true }
            Button(tr("Fábrica…", "Factory…")) { showFactory = true }
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(tr("Menu do cercado", "Paddock menu")).accessibilityLabel(tr("Menu do cercado", "Paddock menu"))
            .popover(isPresented: $showFactory, arrowEdge: .trailing) { FactoryControls(paddock: p, actions: ctx.paddocks).padding(14).frame(width: 280) }
            .sheet(isPresented: $showLots) { LotsSheet(client: ctx.client) { showLots = false } }
    }

    /// An agent: caret (a Shepherd with workers), dot, name, state in words, pending count, "Pastor" tag.
    /// A click focuses it on the canvas, a double click opens its edit sheet.
    private func agentRow(_ r: AgentTree.Row, role: String?, order: [UUID]) -> some View {
        let status = NodeStatus(badge: r.status, exitCode: nil)
        let state = status.text ?? tr("parado", "idle")
        let selected = ctx.canvas.selection.contains(r.id)
        return HStack(spacing: 4) {
            if r.isParent {
                Button { folded.formSymmetricDifference([r.id]) } label: {
                    Image(systemName: r.isCollapsed ? "chevron.right" : "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.collieMuted).frame(width: 14, height: 22).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(r.isCollapsed ? tr("Expandir \(r.name)", "Expand \(r.name)") : tr("Recolher \(r.name)", "Collapse \(r.name)"))
            } else {
                Color.clear.frame(width: 14, height: 22)
            }
            Button { click(r.id, order: order) } label: {
                HStack(spacing: 6) {
                    StateDot(status: status)
                    Text(r.name).font(.collieUI(13, r.depth == 0 ? .medium : .regular)).foregroundStyle(Color.collieText).lineLimit(1)
                    if let role { CollieTag(role, tone: .accent) }
                    Spacer(minLength: 0)
                    if r.pending > 0 {
                        Text("\(r.pending)").font(.collieMono(10, .medium)).monospacedDigit().foregroundStyle(Color.collieBackground)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Color.collieAttention, in: .capsule)
                    }
                    Text(state).font(.collieUI(11)).foregroundStyle(Color.collieMuted).lineLimit(1)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { ctx.edit(r.id) })
            .help([r.name, r.summonedByName.map { tr("convocado por \($0)", "summoned by \($0)") }, state].compactMap { $0 }.joined(separator: " · "))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([r.name, role, state, r.pending > 0 ? tr("\(r.pending) pedidos", "\(r.pending) requests") : nil]
                .compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        }
        .padding(.vertical, 1).padding(.trailing, 8)
        .padding(.leading, 4 + CGFloat(r.depth) * 12)
        .background(selected ? Color.collieRaised : .clear, in: .rect(cornerRadius: 7))
        .overlay { RightClickCatcher { e, v in rightClick(r.id, e, v) } }
    }

    /// A panel, under the agent that opened it: icon + name. A click selects its dock tab or centers it on the canvas.
    private func panelRow(_ p: Panel, depth: Int, order: [UUID]) -> some View {
        let selected = ctx.canvas.selection.contains(p.id)
        let place = p.placement == .canvas ? "canvas" : "dock"
        return Button {
            if NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty {
                NotificationCenter.default.post(name: .collieFocusPanel, object: p.id)
            }
            click(p.id, order: order)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: p.placement == .canvas ? "rectangle.on.rectangle" : "sidebar.right")
                    .font(.system(size: 10)).foregroundStyle(Color.collieMuted).frame(width: 14).accessibilityHidden(true)
                Text(p.name).font(.collieUI(12)).foregroundStyle(Color.collieTextSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.leading, 22 + CGFloat(depth) * 12).padding(.trailing, 8)
        .background(selected ? Color.collieRaised : .clear, in: .rect(cornerRadius: 7))
        .help("\(p.name) · \(place)")
        .accessibilityLabel(tr("\(p.name), painel", "\(p.name), panel"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .overlay { RightClickCatcher { e, v in rightClick(p.id, e, v) } }
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

    // MARK: collapsed

    /// Two letters per paddock in a square (the current one filled), the request count on it, the name in the help.
    private func collapsedList(_ rows: [SidebarModel.PaddockRow]) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 8) {
                ForEach(rows) { r in
                    Button { select(r.id) } label: {
                        Text(SidebarModel.initials(r.name)).font(.collieUI(13, .semibold))
                            .foregroundStyle(r.isCurrent ? Color.collieOnAccent : .collieTextSecondary)
                            .frame(width: 38, height: 38)
                            .background(r.isCurrent ? Color.collieAccent : .collieRaised, in: .rect(cornerRadius: 10))
                            .overlay(alignment: .topTrailing) {
                                if r.needs > 0 {
                                    Text("\(r.needs)").font(.collieMono(9, .bold)).monospacedDigit().foregroundStyle(Color.collieBackground)
                                        .padding(.horizontal, 4).padding(.vertical, 1).background(Color.collieAttention, in: .capsule)
                                        .offset(x: 4, y: -4)
                                }
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("\(r.name) · \(r.status)")
                    .accessibilityLabel("\(r.name), \(r.status)")
                    .accessibilityAddTraits(r.isCurrent ? [.isButton, .isSelected] : .isButton)
                    .contextMenu { if let p = paddock(r.id) { PaddockMenu(paddock: p, actions: ctx.paddocks) } }
                }
                Button { ctx.paddocks.newPaddock() } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.collieMuted)
                        .frame(width: 38, height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.collieBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(tr("Novo cercado…", "New paddock…")).accessibilityLabel(tr("Novo cercado…", "New paddock…"))
            }
            .padding(.vertical, 4)   // room for the count that overhangs the square
            .frame(maxWidth: .infinity)
        }
    }
}

/// A state mark: a shape per state plus the color the node title bar uses (decorative: the row says it in words).
/// Waiting for you pulses, unless Reduzir movimento is on.
private struct StateDot: View {
    let status: NodeStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        let pulses = status == .attention && !reduceMotion
        Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(color)
            .opacity(pulses && dim ? 0.35 : 1)
            .animation(pulses ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil, value: dim)
            .onAppear { dim = true }
            .accessibilityHidden(true)
    }
    private var symbol: String {
        switch status { case .idle: "circle"; case .working: "circle.fill"; case .attention: "exclamationmark.circle.fill"; case .stopped: "xmark.circle.fill" }
    }
    private var color: Color {
        switch status { case .idle: .collieMuted; case .working: .collieSecondary; case .attention: .collieAttention; case .stopped: .collieDanger }
    }
}

/// The ⋯ menu's Lotes… (and ⌘K's): the lots, in a sheet.
struct LotsSheet: View {
    let client: DaemonClient
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView { LotsSection(client: client) }
            HStack { Spacer(); Button(tr("Fechar", "Close"), action: close).keyboardShortcut(.cancelAction) }
        }
        .padding(18).frame(width: 380, height: 420)
    }
}

/// Fábrica: one sentence on what it does, the switch, the daemon's refusal word for word, the doctor's lines while on.
/// The ⋯ menu's Fábrica… popover and ⌘K's Fábrica… sheet.
struct FactoryControls: View {
    let paddock: Paddock
    let actions: PaddockActions

    var body: some View {
        let p = paddock
        let s = FactorySwitch.make(p, busy: actions.busy, refusal: actions.factoryRefusal[p.id], note: actions.factoryNote[p.id])
        VStack(alignment: .leading, spacing: 8) {
            Toggle(tr("Fábrica", "Factory"), isOn: Binding(get: { s.isOn }, set: { actions.setFactory(p, $0) }))
                .toggleStyle(.switch).disabled(!s.enabled).help(s.label)
            Text(tr("Laços com auto-land integram o trabalho sozinhos: gate, revisão e CI limpos, depois merge local, nunca push.",
                    "Loops with auto-land land their own work: clean gate, review and CI, then a local merge, never a push."))
                .font(.collieUI(12)).foregroundStyle(Color.collieTextSecondary).fixedSize(horizontal: false, vertical: true)
            if let r = s.refusal {
                Text(r).font(.collieMono(11)).foregroundStyle(Color.collieDanger).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            ForEach(s.note, id: \.self) { Text($0).font(.collieMono(11)).foregroundStyle(Color.collieTextSecondary).lineLimit(1) }
        }
        .task(id: p.factory ? p.id : nil) { if p.factory { await actions.loadFactoryNote(p) } }
    }
}
