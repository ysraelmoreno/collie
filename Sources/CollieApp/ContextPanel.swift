import SwiftUI
import CollieCanvas
import CollieClient
import CollieCore
import CollieTheme

/// Trilho's context panel (248 pt, right of `PaddockRail`): the current paddock's header and menu, Novo terminal /
/// Abrir painel, the agent tree (`AgentTree`), the panels, then Rebanhos and Lotes.
/// No LAÇOS section: the app has no loop state today (it lives in the Work panel, which asks the daemon itself) and
/// Trilho is UI only; the section comes with a loop feed in `DaemonClient`.
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
        VStack(alignment: .leading, spacing: 12) {
            // ponytail: zoom lives here until T4 moves it to the tab strip
            ZoomControls(ctx: ctx).frame(maxWidth: .infinity, alignment: .trailing)
            header(paddock)
            HStack(spacing: 6) {
                Button(action: ctx.newTerminal) { Text("Novo terminal").frame(maxWidth: .infinity) }.buttonStyle(CollieButtonStyle(.primary))
                Button(action: ctx.openPanel) { Image(systemName: "plus.rectangle") }
                    .buttonStyle(CollieButtonStyle(.secondary)).help("Abrir painel…").accessibilityLabel("Abrir painel…")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("AGENTES · \(client.terminals.filter { $0.paddockId == client.currentPaddock }.count)")
                    VStack(alignment: .leading, spacing: 0) { ForEach(rows) { agentRow($0) } }
                    section("PAINÉIS · \(panels.count)")
                    VStack(alignment: .leading, spacing: 0) { ForEach(panels) { panelRow($0) } }
                    HerdsSection(ctx: ctx)
                    LotsSection(client: client)
                }
            }
        }
        .padding(14)
        .padding(.top, CanvasChrome<EmptyView>.lightsInset)   // the traffic lights reach past the rail (hidden title bar)
        .frame(width: Self.width, alignment: .leading).frame(maxHeight: .infinity, alignment: .top)
        .background(Color.collieSidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.collieBorder).frame(width: 1) }
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
    private func agentRow(_ r: AgentTree.Row) -> some View {
        let status = NodeStatus(badge: r.status, exitCode: nil)
        let selected = ctx.canvas.selection == [r.id]
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
            Button { ctx.focus(r.id) } label: {
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
    }

    /// A panel of this paddock (docked ones show everywhere): a click selects its dock tab or centers it on the canvas.
    private func panelRow(_ p: Panel) -> some View {
        Button {
            NotificationCenter.default.post(name: .collieFocusPanel, object: p.id)
            ctx.focus(p.id)
        } label: {
            HStack(spacing: 6) {
                Text(p.name).font(.collieUI(13)).foregroundStyle(Color.collieText).lineLimit(1)
                Spacer(minLength: 0)
                CollieTag(p.placement == .canvas ? "canvas" : "dock", tone: .neutral)
            }
            .padding(.vertical, 3).padding(.horizontal, 4).contentShape(.rect)
        }
        .buttonStyle(.plain)
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
