import SwiftUI
import CollieClient
import CollieCore
import CollieProtocol
import CollieTheme

/// "Precisa de você": every request waiting for the user, one per card, with the terminal that asked. Same source as
/// the cards inside the terminals (the client), so answering in one place clears the other.
enum NeedsYou {
    struct Item: Equatable, Identifiable {
        /// The terminal that asked; nil: an app card the user raised (no node shows it).
        let terminal: UUID?
        let agent: String?
        let phrase: String
        let request: NodeRequest
        var at: Date { request.at }
        var id: String { request.key + "|" + (terminal?.uuidString ?? "user") }
    }

    /// Oldest first. Every card the client holds, also an app card with no terminal (`by == nil`, the user's own).
    /// A card Collie refused on purpose is `.refused`: only **Dispensar**, as in the node's strip.
    static func items(accessCards: [SandboxDenial], leashRequests: [LeashRequest], appCards: [AppCard],
                      terminals: [TerminalRecord]) -> [Item] {
        func name(_ id: UUID) -> String { terminals.first { $0.id == id }?.name ?? "?" }
        let access = accessCards.map { c in
            Item(terminal: c.terminal, agent: name(c.terminal),
                 phrase: c.refusal != nil ? tr("teve um acesso bloqueado de propósito", "had an access blocked on purpose")
                                          : tr("quer \(AccessCopy.verb(c.op)) fora do projeto", "wants to \(AccessCopy.verb(c.op)) outside the project"),
                 request: c.refusal != nil ? .refused([c]) : .access(c))
        }
        let leash = leashRequests.map { r in
            Item(terminal: r.from, agent: name(r.from),
                 phrase: tr("quer uma coleira para \(name(r.to))", "wants a leash to \(name(r.to))"), request: .leash(r))
        }
        let apps = appCards.map { c in
            Item(terminal: c.by, agent: c.by.map(name),
                 phrase: c.kind == .confirm ? tr("app \(c.name) pede: \(AccessCopy.shown(c.call ?? ""))", "app \(c.name) asks: \(AccessCopy.shown(c.call ?? ""))")
                                            : tr("app \(c.name) pede aprovação", "app \(c.name) asks for approval"),
                 request: .app(c))
        }
        return (access + leash + apps).sorted { $0.at < $1.at }
    }

    /// The highest window of any provider, for "Uso n%"; nil when none has a number.
    static func topUsage(_ reports: [UsageReport]) -> Double? {
        reports.flatMap { $0.windows.compactMap(\.usedPercent) }.max()
    }
}

/// The sidebar's foot: disconnection warning (only while it lasts), "Precisa de você (n)" (only with n > 0),
/// "Uso n%" and "Preferências ⌘,". Collapsed: icons with their numbers.
struct SidebarFooter: View {
    let ctx: ShellContext
    let collapsed: Bool
    @State private var needsOpen = false

    var body: some View {
        let client = ctx.client
        let items = NeedsYou.items(accessCards: client.accessCards, leashRequests: client.leashRequests,
                                   appCards: client.appCards, terminals: client.terminals)
        VStack(alignment: collapsed ? .center : .leading, spacing: 2) {
            if case .disconnected(let reason) = client.state { disconnected(reason) }
            if !items.isEmpty { needs(items) }
            usage
            preferences
        }
        .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
        .padding(.top, 6)
        .overlay(alignment: .top) { Rectangle().fill(Color.collieBorder).frame(height: 1) }
    }

    private func disconnected(_ reason: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.horizontal.circle").font(.system(size: 12))
            if !collapsed { Text(tr("Desconectado", "Disconnected")).font(.collieUI(12, .medium)).lineLimit(1) }
        }
        .foregroundStyle(Color.collieDanger)
        .padding(.horizontal, collapsed ? 0 : 8).padding(.vertical, 4)
        .help(tr("Sem contato com o daemon: \(reason). Tentando de novo.", "No contact with the daemon: \(reason). Trying again."))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("Desconectado: \(reason)", "Disconnected: \(reason)"))
    }

    private func needs(_ items: [NeedsYou.Item]) -> some View {
        row(help: tr("Pedidos esperando você", "Requests waiting for you"), action: { needsOpen.toggle() }) {
            Circle().fill(Color.collieAttention).frame(width: 7, height: 7)
            if collapsed {
                Text(verbatim: "\(items.count)").font(.collieMono(11, .medium)).monospacedDigit()
            } else {
                Text(tr("Precisa de você (\(items.count))", "Needs you (\(items.count))")).font(.collieUI(12, .medium))
            }
        }
        .accessibilityLabel(tr("Precisa de você: \(items.count)", "Needs you: \(items.count)"))
        .popover(isPresented: $needsOpen, arrowEdge: .trailing) {
            NeedsYouList(items: items, client: ctx.client) { id in needsOpen = false; ctx.focus(id) }
        }
    }

    private var usage: some View {
        let text = NeedsYou.topUsage(ctx.usage.reports).map { "\(Int($0.rounded()))%" }
        return row(help: tr("Uso dos agentes", "Agent usage"), action: { ctx.usageOpen.wrappedValue.toggle() }) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 12))
            if collapsed {
                if let text { Text(verbatim: text).font(.collieMono(10)).monospacedDigit() }
            } else {
                Text(text.map { tr("Uso \($0)", "Usage \($0)") } ?? tr("Uso", "Usage")).font(.collieUI(12)).monospacedDigit()
            }
        }
        .accessibilityValue(text ?? tr("sem dados", "no data"))
        .popover(isPresented: ctx.usageOpen, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 0) {
                Text(tr("Quanto da cota do plano os agentes já gastaram na janela atual; o número da lateral é o maior.",
                        "How much of the plan's quota the agents have spent in the current window; the sidebar shows the highest."))
                    .font(.collieUI(11)).foregroundStyle(Color.collieMuted).fixedSize(horizontal: false, vertical: true)
                    .padding([.horizontal, .top], 14)
                UsagePopover(client: ctx.client, feed: ctx.usage)
            }
            .frame(width: 280)
        }
    }

    private var preferences: some View {
        row(help: tr("Preferências (⌘,)", "Preferences (⌘,)"), action: ctx.openPreferences) {
            Image(systemName: "gearshape").font(.system(size: 12))
            if !collapsed {
                Text(tr("Preferências", "Preferences")).font(.collieUI(12))
                Spacer(minLength: 0)
                Text(verbatim: "⌘,").font(.collieMono(11)).foregroundStyle(Color.collieMuted)
            }
        }
    }

    /// One foot row: icon + words (collapsed: icon + number), the whole row clickable.
    private func row<L: View>(help: String, action: @escaping () -> Void, @ViewBuilder label: () -> L) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { label() }
                .foregroundStyle(Color.collieTextSecondary)
                .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
                .padding(.horizontal, collapsed ? 0 : 8).padding(.vertical, 4)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help).accessibilityLabel(help)
    }
}

/// The "Precisa de você" popover: each request with the node strip's answers and "Ver no canvas".
private struct NeedsYouList: View {
    let items: [NeedsYou.Item]
    let client: DaemonClient
    let reveal: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Group {
                                if let agent = item.agent { Text("\(Text(verbatim: agent).bold()) \(item.phrase)") }
                                else { Text(verbatim: item.phrase) }
                            }
                            .font(.collieUI(12)).foregroundStyle(Color.collieText).lineLimit(2)
                            Spacer(minLength: 4)
                            if let t = item.terminal {
                                Button(tr("Ver no canvas", "Show on canvas")) { reveal(t) }
                                    .buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small)
                            }
                        }
                        row(item.request)
                            .frame(height: AccessStrip.height)
                            .clipShape(.rect(cornerRadius: 8))
                            .id(item.id)
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 420).frame(maxHeight: 520)
    }

    /// The same rows (and answers) as the node's strip.
    @ViewBuilder private func row(_ r: NodeRequest) -> some View {
        switch r {
        case .leash(let r): LeashRequestRow(req: r, client: client, more: 0)
        case .access(let c): AccessRequestRow(card: c, client: client, more: 0)
        case .app(let c): AppRequestRow(card: c, client: client, more: 0)
        case .refused(let cs):
            RequestLayout(more: 0, pending: false) {
                Text(AccessStrip.Model(cards: cs).text)
            } actions: {
                Button(tr("Dispensar", "Dismiss")) { Task { do { try await client.denyAll(cs) } catch { Log.canvas.error("dispensar: \(error)") } } }
                    .buttonStyle(CollieButtonStyle(.quiet))
            }
        }
    }
}
