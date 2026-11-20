import SwiftUI
import CollieCore
import CollieProtocol
import CollieTheme

/// Trilho's left column (64 pt): the mark, Pasto and one square button per paddock (its initial, the status dot in the
/// corner), the dashed "+" (Novo cercado), and at the foot the info icon ("O que o Collie faz"), the usage summary and the
/// Preferências gear.
struct PaddockRail: View {
    let ctx: ShellContext
    static var width: CGFloat { 64 }
    private static var side: CGFloat { 40 }

    /// The first letter or digit of `name`, uppercased ("-x" → "X", "água" → "Á"); "?" when there is none.
    /// Two paddocks with the same initial stay apart by their help text and accessibility label.
    static func initial(of name: String) -> String {
        name.first { $0.isLetter || $0.isNumber }.map { $0.uppercased() } ?? "?"
    }

    /// Whether the Pasto (terminals and canvas panels outside any paddock) has anything in it. Docked panels belong to every paddock.
    static func pastoHasContent(terminals: [TerminalRecord], panels: [Panel]) -> Bool {
        terminals.contains { $0.paddockId == nil } || panels.contains { $0.placement == .canvas && $0.paddockId == nil }
    }

    /// The Pasto is not a paddock: Trilho lists it only while it holds something, while it is the selection, or when there is
    /// no paddock to show instead.
    static func showsPasto(hasContent: Bool, hasPaddocks: Bool, current: UUID?) -> Bool {
        hasContent || !hasPaddocks || current == nil
    }

    /// The paddock to move to when the Pasto is selected, empty, and a real paddock exists; nil: stay.
    static func fallbackPaddock(paddocks: [Paddock], current: UUID?, pastoHasContent: Bool) -> UUID? {
        current == nil && !pastoHasContent ? paddocks.first?.id : nil
    }

    /// The highest used percent among every provider's windows; nil when none reports a number.
    static func topUsage(_ reports: [UsageReport]) -> Double? {
        reports.flatMap { $0.windows.compactMap(\.usedPercent) }.max()
    }

    var body: some View {
        let client = ctx.client
        VStack(spacing: 8) {
            CollieMark(size: 22).padding(.bottom, 4)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    if Self.showsPasto(hasContent: Self.pastoHasContent(terminals: client.terminals, panels: client.panels),
                                       hasPaddocks: !client.paddocks.isEmpty, current: client.currentPaddock) {
                        item(nil, selected: client.currentPaddock == nil)
                    }
                    ForEach(client.paddocks) { f in
                        item(f, selected: client.currentPaddock == f.id).contextMenu { PaddockMenu(paddock: f, actions: ctx.paddocks) }
                    }
                    newButton
                    if ctx.paddocks.busy { ProgressView().controlSize(.small) }
                }
                .padding(.vertical, 2)   // room for the status dot that overhangs the square
            }
            Spacer(minLength: 0)
            TourButton(ctx: ctx, ring: .collieSidebar)
            usage
            Button(action: ctx.openPreferences) {
                Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(Color.collieMuted)
                    .frame(width: Self.side, height: 28).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Preferências (⌘,)").accessibilityLabel("Preferências")
        }
        .padding(.vertical, 10)
        .padding(.top, CanvasChrome<EmptyView>.lightsInset)   // below the traffic lights (hidden title bar)
        .frame(width: Self.width).frame(maxHeight: .infinity, alignment: .top)
        .background(Color.collieSidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.collieBorder).frame(width: 1) }
    }

    /// A paddock's square (nil: Pasto). Selected is the accent fill plus the `.isSelected` trait, never color alone.
    private func item(_ f: Paddock?, selected: Bool) -> some View {
        let name = f?.name ?? "Pasto"
        return Button { ctx.paddocks.select(f?.id) } label: {
            Text(Self.initial(of: name)).font(.collieUI(15, .semibold))
                .foregroundStyle(selected ? Color.collieOnAccent : .collieTextSecondary)
                .frame(width: Self.side, height: Self.side)
                .background(selected ? Color.collieAccent : .collieRaised, in: .rect(cornerRadius: 11))
                .overlay(alignment: .bottomTrailing) {
                    // the sidebar-colored disc keeps the dot readable over the accent fill
                    if let f { PaddockStatusDot(status: f.status).padding(2).background(Color.collieSidebar, in: .circle).offset(x: 3, y: 3) }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(f.map { "\($0.name) · \($0.status.label)" } ?? name)
        .accessibilityLabel(name)
        .accessibilityValue(f?.status.label ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var newButton: some View {
        Button { ctx.paddocks.newPaddock() } label: {
            Image(systemName: "plus").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.collieMuted)
                .frame(width: Self.side, height: Self.side)
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.collieBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Novo cercado…").accessibilityLabel("Novo cercado…")
    }

    /// The highest provider's percent over a mini bar; opens the same usage popover as Compacta's button.
    private var usage: some View {
        let top = Self.topUsage(ctx.usage.reports), text = top.map { "\(Int($0.rounded()))%" }
        return Button { ctx.usageOpen.wrappedValue.toggle() } label: {
            VStack(spacing: 4) {
                Text(text ?? "uso").font(.collieMono(11)).monospacedDigit().foregroundStyle(Color.collieTextSecondary)
                ProgressView(value: min(max((top ?? 0) / 100, 0), 1)).tint(Color.collieAccent).frame(width: 32)
                    .accessibilityHidden(true)
            }
            .frame(width: Self.side).padding(.vertical, 4).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Uso dos agentes").accessibilityLabel("Uso dos agentes").accessibilityValue(text ?? "sem dados")
        .popover(isPresented: ctx.usageOpen, arrowEdge: .trailing) { UsagePopover(client: ctx.client, feed: ctx.usage) }
    }
}
