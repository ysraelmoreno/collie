import SwiftUI
import CollieClient
import CollieCore
import CollieTheme

/// The access cards' copy (tested without the app). Agent-written text (paths, reasons) is shown verbatim, never as markdown.
enum AccessCopy {
    static func verb(_ op: String) -> String {
        ["read": "ler", "write": "escrever", "delete": "apagar", "exec": "executar"][op] ?? op
    }
    static func resumeNote(_ t: TerminalRecord?) -> String {
        t?.resumesConversation == true
            ? "Liberar reinicia o terminal e retoma a conversa anterior, se houver (claude --continue)."
            : "Liberar reinicia o terminal sem retomar a conversa (a retomada do Codex/Cursor não foi confirmada)."
    }
    /// R24: only this terminal restarts; the lot's other running members get it at their next start.
    static let lotNote = "Vale para todos os terminais do lote, também os que entrarem depois (inclusive os que um Pastor puser no lote). Só este terminal reinicia agora; os outros que estão rodando recebem quando reiniciarem."
    /// Agent-written text shown as is, but with control and bidi characters spelled out (`\u{202E}`), so a file name
    /// can't lay out a misleading line (R29).
    static func shown(_ s: String) -> String {
        var o = ""
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: o += "\\u{" + String(u.value, radix: 16, uppercase: true) + "}"
            default: o.unicodeScalars.append(u)
            }
        }
        return o
    }
    static func grantLine(_ g: SandboxGrant) -> String {
        (g.access == .write ? "ler e escrever" : "ler") + " · " + g.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}

/// The title-bar entry of a sandboxed terminal's access: its open cards (attention) or its grants, and the
/// "detecção indisponível" state. Opens `AccessPopover`.
/// Which terminals' access popovers are open: the tag, the node's strip (and a notification click) share it.
@MainActor @Observable final class AccessPopoverState {
    static let shared = AccessPopoverState()
    var open: Set<UUID> = []
    /// Called when the tag or the terminal goes away: SwiftUI never runs the binding setter on teardown.
    func close(_ id: UUID) { open.remove(id) }
    func binding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { self.open.contains(id) }, set: { if $0 { self.open.insert(id) } else { self.open.remove(id) } })
    }
}

struct AccessBadge: View {
    let id: UUID
    let client: DaemonClient
    @State private var hover = false

    var body: some View {
        let cards = client.accessCards.filter { $0.terminal == id }
        let mine = client.grants.filter { $0.scope == .terminal && $0.owner == id }
        HStack(spacing: 6) {
            if client.detection == false {
                CollieTag("detecção indisponível", tone: .danger)
                    .help("O Collie não está vendo os bloqueios do sandbox agora (log stream parado; tentando de novo). Os bloqueios continuam valendo.")
            }
            if !cards.isEmpty || !mine.isEmpty {
                let open = AccessPopoverState.shared.binding(id)
                Button { open.wrappedValue = true } label: {
                    HStack(spacing: 3) {
                        CollieTag(cards.isEmpty ? "liberados \(mine.count)" : "acesso \(cards.count)", tone: cards.isEmpty ? .secondary : .attention)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.collieMuted)
                    }
                    .padding(.horizontal, 2).padding(.vertical, 1)
                    .background(hover ? Color.collieText.opacity(0.1) : .clear, in: .rect(cornerRadius: 6))
                }
                .buttonStyle(.plain).onHover { hover = $0 }
                .onDisappear { AccessPopoverState.shared.close(id) }
                .help(cards.isEmpty ? "Caminhos liberados para este terminal" : "O agente tentou acessar fora do sandbox")
                .popover(isPresented: open, arrowEdge: .bottom) { AccessPopover(id: id, client: client) }
            }
        }
    }
}

/// The 28 pt strip over the bottom of a sandboxed node's terminal while it has open cards.
struct AccessStrip: View {
    struct Model: Equatable {
        enum Kind: Equatable { case none, pending(Int), refusedOnly(Int) }
        let kind: Kind
        init(cards: [SandboxDenial]) {
            let grantable = cards.filter { $0.refusal == nil }.count
            kind = grantable > 0 ? .pending(grantable) : cards.isEmpty ? .none : .refusedOnly(cards.count)
        }
        var text: String {
            switch kind {
            case .none: ""
            case .pending(1): "O agente pediu acesso — ver"
            case .pending(let n): "\(n) pedidos de acesso — ver"
            case .refusedOnly(1): "1 acesso bloqueado de propósito"
            case .refusedOnly(let n): "\(n) acessos bloqueados de propósito"
            }
        }
    }
    static let height: CGFloat = 28
    let id: UUID
    let client: DaemonClient

    var body: some View {
        let cards = client.accessCards.filter { $0.terminal == id }
        let m = Model(cards: cards)
        HStack(spacing: 8) {
            Text(m.text).font(.collieUI(12, .medium)).lineLimit(1)
            Spacer(minLength: 0)
            switch m.kind {
            case .none: EmptyView()
            case .pending: Button("Ver") { AccessPopoverState.shared.open.insert(id) }.buttonStyle(CollieButtonStyle(.primary)).controlSize(.small)
            case .refusedOnly:
                Button("Dispensar") { Task { do { try await client.denyAll(cards) } catch { Log.canvas.error("dispensar: \(error)") } } }.buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small)
            }
        }
        .foregroundStyle(m.kind == .none || isPending(m.kind) ? Color.collieText : Color.collieTextSecondary)
        .padding(.leading, 10).padding(.trailing, 26)   // clear of the node's resize corner (14 pt at 4 pt from the edge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isPending(m.kind) ? Color.collieAttention.opacity(0.9) : Color.collieSidebar)
        .help(isPending(m.kind) ? "" : "Pastas do próprio Collie e segredos nunca são liberadas")
    }
    private func isPending(_ k: Model.Kind) -> Bool { if case .pending = k { true } else { false } }
}

/// The node's cards (newest last) and the terminal's own grants with **Revogar**.
struct AccessPopover: View {
    let id: UUID
    let client: DaemonClient

    var body: some View {
        let cards = client.accessCards.filter { $0.terminal == id }
        let mine = client.grants.filter { $0.scope == .terminal && $0.owner == id }
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(cards, id: \.cardId) { AccessCard(card: $0, client: client).id($0.cardId) }
                if !mine.isEmpty {
                    Text("LIBERADOS PARA ESTE TERMINAL").font(.collieMono(10)).kerning(1.2).foregroundStyle(Color.collieMuted)
                    ForEach(mine) { GrantRow(grant: $0, client: client) }
                }
            }
            .padding(12)
        }
        .onAppear { if let last = cards.last { proxy.scrollTo(last.cardId, anchor: .bottom) } }
        }
        .frame(width: 440).frame(maxHeight: 520)
    }
}

/// One card: "Agente *X* tentou **ler** `path`", **Liberar este caminho** / **Liberar a pasta** / **Negar**, "para o lote".
struct AccessCard: View {
    let card: SandboxDenial
    let client: DaemonClient
    @State private var forLot = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let t = client.terminals.first { $0.id == card.terminal }
        let lot = client.lot(of: card.terminal)
        VStack(alignment: .leading, spacing: 6) {
            Text("Agente \(Text(verbatim: t?.name ?? "?").italic()) tentou \(Text(AccessCopy.verb(card.op)).bold()) \(Text(verbatim: AccessCopy.shown(card.path)).font(.collieMono(11)))")
                .font(.collieUI(12)).foregroundStyle(Color.collieText).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if card.count > 1 { Text("\(card.count) vezes nesta pasta").font(.collieUI(11)).foregroundStyle(Color.collieMuted) }
            if let r = card.reason { Text("Motivo do agente: \(Text(verbatim: AccessCopy.shown(r)))").font(.collieUI(11)).foregroundStyle(Color.collieTextSecondary) }
            if let why = card.refusal {
                Text(why).font(.collieUI(11)).foregroundStyle(Color.collieDanger).fixedSize(horizontal: false, vertical: true)
                Button("Negar") { deny() }.buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small).disabled(busy)
            } else {
                HStack(spacing: 6) {
                    Button("Liberar este caminho") { grant(folder: false) }.buttonStyle(CollieButtonStyle(.primary))
                    Button("Liberar a pasta") { grant(folder: true) }.buttonStyle(CollieButtonStyle(.secondary))
                        .disabled(card.folderRefusal != nil).help(card.folderRefusal ?? card.folder)
                    Button("Negar") { deny() }.buttonStyle(CollieButtonStyle(.quiet))
                }
                .controlSize(.small).disabled(busy)
                // R27: the folder a click opens is on the card, not only in a tooltip
                Text("A pasta: \(Text(verbatim: AccessCopy.shown(card.folder)).font(.collieMono(11)))\(card.folderRefusal.map { " — \($0)" } ?? "")")
                    .font(.collieUI(11)).foregroundStyle(Color.collieTextSecondary).fixedSize(horizontal: false, vertical: true)
                Toggle("para o lote", isOn: $forLot).toggleStyle(.checkbox).controlSize(.small).disabled(lot == nil)
                    .help(lot == nil ? "Este terminal não está em um lote" : AccessCopy.lotNote)
                if forLot { Text(AccessCopy.lotNote).font(.collieUI(11)).foregroundStyle(Color.collieMuted).fixedSize(horizontal: false, vertical: true) }
                Text(AccessCopy.resumeNote(t)).font(.collieUI(11)).foregroundStyle(Color.collieMuted)
            }
            if let error { Text(error).font(.collieUI(11)).foregroundStyle(Color.collieDanger).lineLimit(3) }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.collieSidebar, in: .rect(cornerRadius: 10))
    }

    private func grant(folder: Bool) {
        busy = true; error = nil
        Task { do { try await client.grant(card, folder: folder, lot: forLot) } catch { self.error = "\(error)" }; busy = false }
    }
    private func deny() {
        busy = true; error = nil
        Task { do { try await client.deny(card) } catch { self.error = "\(error)" }; busy = false }
    }
}

/// A grant with **Revogar** (the running terminals it reached restart without it).
struct GrantRow: View {
    let grant: SandboxGrant
    let client: DaemonClient
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(verbatim: AccessCopy.shown(grant.path)).font(.collieMono(11)).foregroundStyle(Color.collieText).lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Revogar") { Task { do { try await client.revoke(grant) } catch { self.error = "\(error)" } } }
                    .buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small)
            }
            Text(AccessCopy.grantLine(grant)).font(.collieUI(10)).foregroundStyle(Color.collieMuted)
            if let error { Text(error).font(.collieUI(11)).foregroundStyle(Color.collieDanger).lineLimit(2) }
        }
    }
}

/// The lot view's "Liberados" tab: paths opened to every member of the lot (also the ones that join later).
struct LotGrantsList: View {
    let lot: Lot
    let client: DaemonClient

    var body: some View {
        let gs = client.grants.filter { $0.scope == .lot && $0.owner == lot.id }
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(AccessCopy.lotNote).font(.collieUI(11)).foregroundStyle(Color.collieMuted).fixedSize(horizontal: false, vertical: true)
                if gs.isEmpty {
                    Text("Nada liberado para o lote. Um cartão de acesso com \"para o lote\" marcado aparece aqui.")
                        .font(.collieUI(12)).foregroundStyle(Color.collieMuted)
                }
                ForEach(gs) { GrantRow(grant: $0, client: client) }
            }
            .padding(4).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension SandboxDenial {
    /// One card per (op, folder) of a terminal (R29: a read and a write card in one folder are two).
    var cardId: String { op + "|" + folder }
}
