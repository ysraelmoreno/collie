import SwiftUI
import CollieClient
import CollieCore
import CollieTheme

fileprivate func trTxt(_ pt: Text, _ en: Text) -> Text { L10n.current == .en ? en : pt }

/// The access cards' copy (tested without the app). Agent-written text (paths, reasons) is shown verbatim, never as markdown.
enum AccessCopy {
    /// The "detecção indisponível" tag and its tooltip: why, what is lost, what still works, how to fix it.
    static func detection(reason: String?) -> (tag: String, help: String) {
        let tag = tr("detecção indisponível", "detection unavailable") + (reason.map { ": " + $0 } ?? "")
        let lost = tr("Sem isso, não aparecem os cartões de liberação quando o agente esbarra no sandbox. ",
                      "Without it, the access cards don't appear when the agent runs into the sandbox. ")
            + tr("O sandbox continua protegendo, e 'collie access request' continua funcionando (o agente pede, você libera).",
                 "The sandbox keeps protecting, and 'collie access request' keeps working (the agent asks, you grant).")
        if reason == SandboxDetection.notAdmin {
            return (tag, tr("O Collie não vê os bloqueios do sandbox: o macOS só deixa contas de administrador lerem o log do sistema (log stream). ",
                            "Collie can't see the sandbox blocks: macOS only lets administrator accounts read the system log (log stream). ")
                + lost + tr(" Para resolver: use uma conta de administrador (Ajustes do Sistema › Usuários e Grupos) e entre de novo na sessão. ",
                            " To fix it: use an administrator account (System Settings › Users & Groups) and log in again. ")
                + tr("Até lá o Collie não tenta de novo.", "Until then Collie won't try again."))
        }
        return (tag, tr("O Collie não está vendo os bloqueios do sandbox agora (\(reason ?? "log stream parado"); tentando de novo). ",
                        "Collie can't see the sandbox blocks right now (\(reason ?? "log stream stopped"); trying again). ") + lost)
    }
    /// The bar's red tag: only while detection may come back (log stream not started or died). Not admin is a fact of
    /// the account, not a fault: no tag, a one-time toast, the detail in the popover and Preferências.
    static func showsDetectionTag(detection: Bool?, reason: String?) -> Bool {
        detection == false && reason != SandboxDetection.notAdmin
    }
    /// Versioned: a new text can be shown again once by bumping it.
    static let notAdminToastKey = "sandbox.detectionNotice.notAdmin.v1"
    static var notAdminToastText: String {
        tr("Nesta conta o Collie não vê os bloqueios do sandbox: o macOS só mostra esse log a administradores. ",
           "On this account Collie can't see the sandbox blocks: macOS only shows that log to administrators. ")
        + tr("Por isso não aparecem os cartões automáticos de liberação. O sandbox continua protegendo, e 'collie access request' continua funcionando. ",
             "So the automatic access cards don't appear. The sandbox keeps protecting, and 'collie access request' keeps working. ")
        + tr("Para ter os cartões, use uma conta de administrador e entre de novo na sessão.",
             "To get the cards, use an administrator account and log in again.")
    }
    /// The not-admin toast, once (recorded in `defaults`); detection back on clears the record, so losing admin again explains again.
    static func notAdminToast(detection: Bool?, reason: String?, defaults: UserDefaults) -> String? {
        if detection == true { defaults.removeObject(forKey: notAdminToastKey); return nil }
        guard detection == false, reason == SandboxDetection.notAdmin, !defaults.bool(forKey: notAdminToastKey) else { return nil }
        defaults.set(true, forKey: notAdminToastKey)
        return notAdminToastText
    }
    static var loopAlwaysHelp: String {
        tr("Os próximos laços deste cercado começam sem cartão; você recebe o aviso e pode parar com collie work stop. Dá para desligar em Preferências, Laços.",
           "The next loops in this paddock start without a card; you get a notice and can stop with collie work stop. You can turn this off in Preferences, Loops.")
    }
    static func sessionHelp(_ app: String) -> String {
        tr("Este comando de \(app) roda sem cartão até a sessão do terminal acabar ou o app mudar",
           "This \(app) command runs without a card until the terminal session ends or the app changes")
    }
    static func verb(_ op: String) -> String {
        switch op {
        case "read": tr("ler", "read")
        case "write": tr("escrever", "write")
        case "delete": tr("apagar", "delete")
        case "exec": tr("executar", "run")
        default: op
        }
    }
    static func resumeNote(_ t: TerminalRecord?) -> String {
        t?.resumesConversation == true
            ? tr("Liberar reinicia o terminal e retoma a conversa anterior, se houver (claude --continue).",
                 "Granting restarts the terminal and resumes the previous conversation, if any (claude --continue).")
            : tr("Liberar reinicia o terminal sem retomar a conversa (a retomada do Codex/Cursor não foi confirmada).",
                 "Granting restarts the terminal without resuming the conversation (resuming in Codex/Cursor wasn't confirmed).")
    }
    /// R24: only this terminal restarts; the lot's other running members get it at their next start.
    static var lotNote: String {
        tr("Vale para todos os terminais do lote, também os que entrarem depois (inclusive os que um Pastor puser no lote). Só este terminal reinicia agora; os outros que estão rodando recebem quando reiniciarem.",
           "Applies to every terminal in the lot, including ones that join later (even ones a Shepherd puts in the lot). Only this terminal restarts now; the others that are running get it when they restart.")
    }
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
        (g.access == .write ? tr("ler e escrever", "read and write") : tr("ler", "read")) + " · " + g.createdAt.formatted(date: .abbreviated, time: .shortened)
            + (g.by.map { tr(" · liberado do \($0.deviceName) (\(RemoteCopy.via($0.via)))", " · granted from \($0.deviceName) (\(RemoteCopy.via($0.via)))") } ?? "")   // from a paired phone
    }
}

/// The not-admin toast: once (`AccessCopy.notAdminToast`), in the update notice's card, dismissed with OK.
struct DetectionNoticeHost: ViewModifier {
    let client: DaemonClient
    @State private var text: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if let text { NoticeCard(text: text) { Button(tr("OK", "OK")) { self.text = nil }.buttonStyle(CollieButtonStyle(.quiet)) } }
            }
            .task(id: "\(String(describing: client.detection))|\(client.detectionReason ?? "")") {
                if let t = AccessCopy.notAdminToast(detection: client.detection, reason: client.detectionReason, defaults: .standard) { text = t }
                else if client.detection == true { text = nil }
            }
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

/// One request waiting on the user, shown inside the node of the terminal that asked (spec lateral única, "Canvas").
enum NodeRequest: Equatable {
    case leash(LeashRequest), access(SandboxDenial), app(AppCard)
    /// Cards Collie refused on purpose: nothing to grant, one **Dispensar** for all of them.
    case refused([SandboxDenial])

    var at: Date {
        switch self {
        case .leash(let r): r.at
        case .access(let c): c.at
        case .app(let c): c.at
        case .refused(let cs): cs.map(\.at).min() ?? .distantFuture
        }
    }
    /// A new request gets a fresh row (its busy/error state is the row's).
    var key: String {
        switch self {
        case .leash(let r): "leash|\(r.id)"
        case .access(let c): "access|\(c.cardId)"
        case .app(let c): "app|\(c.id)"
        case .refused: "refused"
        }
    }

    /// Oldest first; refused cards (nothing to answer) last. Access cards only for a sandboxed terminal.
    static func of(_ id: UUID, sandboxed: Bool, leash: [LeashRequest], cards: [SandboxDenial], apps: [AppCard]) -> [NodeRequest] {
        let mine = sandboxed ? cards.filter { $0.terminal == id } : []
        let open = leash.filter { $0.from == id }.map(NodeRequest.leash) + mine.filter { $0.refusal == nil }.map(NodeRequest.access)
            + apps.filter { $0.by == id }.map(NodeRequest.app)
        let refused = mine.filter { $0.refusal != nil }
        return open.sorted { $0.at < $1.at } + (refused.isEmpty ? [] : [.refused(refused)])
    }

    @MainActor static func of(_ id: UUID, client: DaemonClient) -> [NodeRequest] {
        let sandboxed = client.terminals.first { $0.id == id }.map { $0.sandbox != .free } ?? false
        return of(id, sandboxed: sandboxed, leash: client.leashRequests, cards: client.accessCards, apps: client.appCards)
    }
}

/// The strip over the bottom of a node while its terminal has a request: the oldest one, with its answers, and "+n".
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
            case .pending(1): tr("O agente pediu acesso — ver", "The agent asked for access — view")
            case .pending(let n): tr("\(n) pedidos de acesso — ver", "\(n) access requests — view")
            case .refusedOnly(1): tr("1 acesso bloqueado de propósito", "1 access blocked on purpose")
            case .refusedOnly(let n): tr("\(n) acessos bloqueados de propósito", "\(n) accesses blocked on purpose")
            }
        }
    }
    static let height: CGFloat = 58
    let id: UUID
    let client: DaemonClient

    var body: some View {
        let all = NodeRequest.of(id, client: client)
        if let first = all.first {
            let more = all.count - 1
            Group {
                switch first {
                case .leash(let r): LeashRequestRow(req: r, client: client, more: more)
                case .access(let c): AccessRequestRow(card: c, client: client, more: more)
                case .app(let c): AppRequestRow(card: c, client: client, more: more)
                case .refused(let cs):
                    RequestLayout(more: more, pending: false) {
                        Text(Model(cards: cs).text)
                            .help(tr("Pastas do próprio Collie e segredos nunca são liberadas", "Collie's own folders and secrets are never granted"))
                    } actions: {
                        Button(tr("Dispensar", "Dismiss")) { Task { do { try await client.denyAll(cs) } catch { Log.canvas.error("dispensar: \(error)") } } }
                            .buttonStyle(CollieButtonStyle(.quiet))
                    }
                }
            }
            .id(first.key)
        }
    }
}

/// The strip's two lines: the question over its answers, "+n" when more requests wait behind it.
struct RequestLayout<Q: View, A: View>: View {
    let more: Int
    var pending = true
    var error: String?
    @ViewBuilder let question: () -> Q
    @ViewBuilder let actions: () -> A

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let error { Text(verbatim: error).lineLimit(1).help(error) } else { question().lineLimit(1) }
                Spacer(minLength: 0)
                if more > 0 {
                    Text(verbatim: "+\(more)").font(.collieMono(11))
                        .help(tr("Mais \(more) pedido(s) depois deste", "\(more) more request(s) after this one"))
                }
            }
            HStack(spacing: 6) { Spacer(minLength: 0); actions() }.controlSize(.small)
        }
        .font(.collieUI(12, .medium))
        .foregroundStyle(pending ? Color.collieText : Color.collieTextSecondary)
        .padding(.leading, 10).padding(.trailing, 26).padding(.vertical, 6)   // clear of the node's resize corner
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(pending ? Color.collieAttention.opacity(0.9) : Color.collieSidebar)
        .accessibilityElement(children: .contain).accessibilityLabel(tr("Pedido", "Request"))
    }
}

/// "Quer ler `path`": **Liberar** / **Liberar a pasta** / **Negar**; ⓘ opens the full card (lot, folder, grants).
struct AccessRequestRow: View {
    let card: SandboxDenial
    let client: DaemonClient
    let more: Int
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let t = client.terminals.first { $0.id == card.terminal }
        let path = Text(verbatim: AccessCopy.shown(card.path)).font(.collieMono(11))
        RequestLayout(more: more, error: error) {
            HStack(spacing: 4) {
                trTxt(Text("Quer \(Text(AccessCopy.verb(card.op)).bold()) \(path)"), Text("Wants to \(Text(AccessCopy.verb(card.op)).bold()) \(path)"))
                    .truncationMode(.middle)
                    .help(card.reason.map { tr("Motivo do agente: ", "Agent's reason: ") + AccessCopy.shown($0) } ?? AccessCopy.shown(card.path))
                Button { AccessPopoverState.shared.open.insert(card.terminal) } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).help(tr("Ver o cartão inteiro", "View the whole card")).accessibilityLabel(tr("Detalhes", "Details"))
            }
        } actions: {
            Button(tr("Negar", "Deny")) { deny() }.buttonStyle(CollieButtonStyle(.quiet))
            Button(tr("Liberar a pasta", "Grant the folder")) { grant(folder: true) }.buttonStyle(CollieButtonStyle(.secondary))
                .disabled(card.folderRefusal != nil).help(card.folderRefusal ?? AccessCopy.shown(card.folder))
            Button(tr("Liberar", "Grant")) { grant(folder: false) }.buttonStyle(CollieButtonStyle(.primary)).help(AccessCopy.resumeNote(t))
        }
        .disabled(busy)
    }

    private func grant(folder: Bool) {
        busy = true; error = nil
        Task { do { try await client.grant(card, folder: folder, lot: false) } catch { self.error = "\(error)" }; busy = false }
    }
    private func deny() {
        busy = true; error = nil
        Task { do { try await client.deny(card) } catch { self.error = "\(error)" }; busy = false }
    }
}

/// A Shepherd's leash request (`collie leash request`): **Conectar** leashes, **Recusar** declines.
struct LeashRequestRow: View {
    let req: LeashRequest
    let client: DaemonClient
    let more: Int
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let to = client.terminals.first { $0.id == req.to }?.name ?? "?"
        RequestLayout(more: more, error: error) {
            trTxt(Text("Quer conectar a \(Text(verbatim: to).bold())\(req.reason.map { Text(verbatim: " — " + AccessCopy.shown($0)) } ?? Text(""))"),
                  Text("Wants to connect to \(Text(verbatim: to).bold())\(req.reason.map { Text(verbatim: " — " + AccessCopy.shown($0)) } ?? Text(""))"))
                .truncationMode(.tail).help(req.reason.map(AccessCopy.shown) ?? "")
        } actions: {
            Button(tr("Recusar", "Decline")) { answer(false) }.buttonStyle(CollieButtonStyle(.quiet))
            Button(tr("Conectar", "Connect")) { answer(true) }.buttonStyle(CollieButtonStyle(.primary))
        }
        .disabled(busy)
    }

    private func answer(_ allow: Bool) {
        busy = true; error = nil
        Task {
            do { try await client.answerLeash(req, allow: allow) } catch { self.error = "\(error)"; Log.canvas.error("leash request: \(error)") }
            busy = false
        }
    }
}

/// An app card the terminal raised: a `confirm` call answers in the strip (**Permitir** / **Nesta sessão** / **Negar**);
/// an approval shows what it would run first (**Ver e aprovar…** opens the whole card).
struct AppRequestRow: View {
    let card: AppCard
    let client: DaemonClient
    let more: Int
    @State private var busy = false
    @State private var error: String?
    @State private var details = false

    var body: some View {
        RequestLayout(more: more, error: error) {
            question.truncationMode(.middle)
        } actions: {
            Button(tr("Negar", "Deny")) { answer(false) }.buttonStyle(CollieButtonStyle(.quiet))
            if card.kind == .confirm {
                if card.app == "work-loop" {
                    Button(tr("Sempre neste cercado", "Always in this paddock")) { answer(true, always: true) }.buttonStyle(CollieButtonStyle(.quiet))
                        .help(AccessCopy.loopAlwaysHelp)
                } else if card.app != "network" {
                    Button(tr("Nesta sessão", "This session")) { answer(true, session: true) }.buttonStyle(CollieButtonStyle(.quiet))
                        .help(AccessCopy.sessionHelp(card.name))
                }
                Button(tr("Permitir", "Allow")) { answer(true) }.buttonStyle(CollieButtonStyle(.primary))
            } else {
                Button(tr("Ver e aprovar…", "Review and approve…")) { details = true }.buttonStyle(CollieButtonStyle(.primary))
                    .popover(isPresented: $details, arrowEdge: .bottom) { AppCardView(card: card, client: client) }
            }
        }
        .disabled(busy)
    }

    @ViewBuilder private var question: some View {
        let call = Text(verbatim: AccessCopy.shown(card.call ?? "")).font(.collieMono(11))
        if card.kind == .confirm, card.app == "network" {   // NetworkCommands.cardText: request \n response
            let request = Text(verbatim: AccessCopy.shown((card.call ?? "").split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "")).font(.collieMono(11))
            trTxt(Text("Responder no lugar do servidor? \(request)"), Text("Answer in place of the server? \(request)"))
                .help(AccessCopy.shown(card.call ?? ""))
        } else if card.kind == .confirm {
            trTxt(Text("\(Text(verbatim: card.name).bold()) quer: \(call)"), Text("\(Text(verbatim: card.name).bold()) wants: \(call)"))
                .help(AccessCopy.shown(card.call ?? ""))
        } else {
            trTxt(Text("Aprovar o app \(Text(verbatim: card.name).bold())?"), Text("Approve the app \(Text(verbatim: card.name).bold())?"))
        }
    }

    private func answer(_ allow: Bool, session: Bool = false, always: Bool = false) {
        busy = true; error = nil
        Task {
            do { try await client.answerApp(card, allow: allow, session: session, always: always) } catch { self.error = "\(error)"; Log.canvas.error("app card: \(error)") }
            busy = false
        }
    }
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
                if client.detection == false, client.detectionReason == SandboxDetection.notAdmin {   // neutral: a fact of the account
                    Text(AccessCopy.detection(reason: SandboxDetection.notAdmin).help).font(.collieUI(11)).foregroundStyle(Color.collieMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(cards, id: \.cardId) { AccessCard(card: $0, client: client).id($0.cardId) }
                if !mine.isEmpty {
                    Text(tr("LIBERADOS PARA ESTE TERMINAL", "GRANTED TO THIS TERMINAL")).font(.collieMono(10)).kerning(1.2).foregroundStyle(Color.collieMuted)
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
            trTxt(Text("Agente \(Text(verbatim: t?.name ?? "?").italic()) tentou \(Text(AccessCopy.verb(card.op)).bold()) \(Text(verbatim: AccessCopy.shown(card.path)).font(.collieMono(11)))"),
                  Text("Agent \(Text(verbatim: t?.name ?? "?").italic()) tried to \(Text(AccessCopy.verb(card.op)).bold()) \(Text(verbatim: AccessCopy.shown(card.path)).font(.collieMono(11)))"))
                .font(.collieUI(12)).foregroundStyle(Color.collieText).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if card.count > 1 { Text(tr("\(card.count) vezes nesta pasta", "\(card.count) times in this folder")).font(.collieUI(11)).foregroundStyle(Color.collieMuted) }
            if let r = card.reason { trTxt(Text("Motivo do agente: \(Text(verbatim: AccessCopy.shown(r)))"), Text("Agent's reason: \(Text(verbatim: AccessCopy.shown(r)))")).font(.collieUI(11)).foregroundStyle(Color.collieTextSecondary) }
            if let why = card.refusal {
                Text(why).font(.collieUI(11)).foregroundStyle(Color.collieDanger).fixedSize(horizontal: false, vertical: true)
                Button(tr("Negar", "Deny")) { deny() }.buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small).disabled(busy)
            } else {
                HStack(spacing: 6) {
                    Button(tr("Liberar este caminho", "Grant this path")) { grant(folder: false) }.buttonStyle(CollieButtonStyle(.primary))
                    Button(tr("Liberar a pasta", "Grant the folder")) { grant(folder: true) }.buttonStyle(CollieButtonStyle(.secondary))
                        .disabled(card.folderRefusal != nil).help(card.folderRefusal ?? card.folder)
                    Button(tr("Negar", "Deny")) { deny() }.buttonStyle(CollieButtonStyle(.quiet))
                }
                .controlSize(.small).disabled(busy)
                // R27: the folder a click opens is on the card, not only in a tooltip
                trTxt(Text("A pasta: \(Text(verbatim: AccessCopy.shown(card.folder)).font(.collieMono(11)))\(card.folderRefusal.map { " — \($0)" } ?? "")"),
                      Text("The folder: \(Text(verbatim: AccessCopy.shown(card.folder)).font(.collieMono(11)))\(card.folderRefusal.map { " — \($0)" } ?? "")"))
                    .font(.collieUI(11)).foregroundStyle(Color.collieTextSecondary).fixedSize(horizontal: false, vertical: true)
                Toggle(tr("para o lote", "for the lot"), isOn: $forLot).toggleStyle(.checkbox).controlSize(.small).disabled(lot == nil)
                    .help(lot == nil ? tr("Este terminal não está em um lote", "This terminal isn't in a lot") : AccessCopy.lotNote)
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
                Button(tr("Revogar", "Revoke")) { Task { do { try await client.revoke(grant) } catch { self.error = "\(error)" } } }
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
                    Text(tr("Nada liberado para o lote. Um cartão de acesso com \"para o lote\" marcado aparece aqui.", "Nothing granted to the lot. An access card with \"for the lot\" checked shows up here."))
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

/// Apps do cercado waiting for the user, over the canvas: an approval (**Aprovar** pins the manifest in that paddock) or
/// one call of a `confirm` command (**Permitir** / **Negar**). Spec 2026-11-08-paddock-apps-design.md.
/// Only the cards no node on this canvas shows: one raised by a terminal of this paddock is in that node's strip.
struct AppCardsView: View {
    let client: DaemonClient
    nonisolated static func floating(_ cards: [AppCard], terminals: [TerminalRecord], paddock: UUID?) -> [AppCard] {
        cards.filter { c in !(c.by.flatMap { by in terminals.first { $0.id == by } }.map { $0.paddockId == paddock } ?? false) }
    }
    var body: some View {
        let cards = Self.floating(client.appCards, terminals: client.terminals, paddock: client.currentPaddock)
        if !cards.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(cards) { AppCardView(card: $0, client: client) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 12)
        }
    }
}

struct AppCardView: View {
    let card: AppCard
    let client: DaemonClient
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        let by = card.by.flatMap { id in client.terminals.first { $0.id == id }?.name }
        VStack(alignment: .leading, spacing: 6) {
            if card.kind == .confirm, card.app == "network" {   // a terminal's map rule (NetworkCommands.cardText: request \n response)
                let parts = (card.call ?? "").split(separator: "\n", maxSplits: 1).map(String.init)
                Text(tr("Responder no lugar do servidor?", "Answer in place of the server?")).font(.collieUI(13, .semibold))
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(Array(zip(["Terminal", tr("Requisição", "Request"), tr("Resposta", "Response"), tr("Alcance", "Scope")],
                                      [by ?? "?", parts.first ?? "", parts.count > 1 ? parts[1] : "", tr("todo emulador capturado", "every captured emulator")]).enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.0).font(.collieUI(11)).foregroundStyle(Color.collieTextSecondary)
                            Text(verbatim: AccessCopy.shown(row.1)).font(.collieMono(12))
                        }
                    }
                }
                Text(tr("Sem resposta no prazo vale Negar, e a regra nunca liga.", "No answer in time counts as Deny, and the rule never turns on.")).font(.collieUI(11)).foregroundStyle(Color.collieMuted)
            } else if card.kind == .confirm {
                trTxt(Text("\(Text(verbatim: card.name).bold()) quer: \(Text(verbatim: AccessCopy.shown(card.call ?? "")).font(.collieMono(12)))"),
                      Text("\(Text(verbatim: card.name).bold()) wants: \(Text(verbatim: AccessCopy.shown(card.call ?? "")).font(.collieMono(12)))"))
                    .font(.collieUI(13)).fixedSize(horizontal: false, vertical: true)
                if let by { trTxt(Text("Pedido por \(Text(verbatim: by).italic())"), Text("Requested by \(Text(verbatim: by).italic())")).font(.collieUI(11)).foregroundStyle(Color.collieTextSecondary) }
            } else {
                trTxt(Text("App \(Text(verbatim: card.name).bold()) no cercado \(Text(verbatim: card.paddockName).bold())"),
                      Text("App \(Text(verbatim: card.name).bold()) in paddock \(Text(verbatim: card.paddockName).bold())"))
                    .font(.collieUI(13)).fixedSize(horizontal: false, vertical: true)
                if let by { trTxt(Text("Pedido por \(Text(verbatim: by).italic()); um agente nunca aprova"), Text("Requested by \(Text(verbatim: by).italic()); an agent never approves")).font(.collieUI(11)).foregroundStyle(Color.collieTextSecondary) }
                if let base = card.base { trTxt(Text("Serviço: \(Text(verbatim: base).font(.collieMono(11)))"), Text("Service: \(Text(verbatim: base).font(.collieMono(11)))")).font(.collieUI(12)) }
                if let start = card.start {   // slice 5: the daemon runs it in the app's folder, under the paddock's sandbox
                    trTxt(Text("Vai rodar: \(Text(verbatim: AccessCopy.shown(start)).font(.collieMono(11)))"), Text("Will run: \(Text(verbatim: AccessCopy.shown(start)).font(.collieMono(11)))")).font(.collieUI(12))
                }
                if let cwd = card.cwd {   // service.cwd: the folder it runs in, relative to the paddock
                    trTxt(Text("Pasta: \(Text(verbatim: AccessCopy.shown(cwd)).font(.collieMono(11)))"), Text("Folder: \(Text(verbatim: AccessCopy.shown(cwd)).font(.collieMono(11)))")).font(.collieUI(12))
                }
                if !card.commands.isEmpty {
                    trTxt(Text("Comandos para os agentes: \(Text(verbatim: card.commands.joined(separator: ", ")).font(.collieMono(11)))"),
                          Text("Commands for the agents: \(Text(verbatim: card.commands.joined(separator: ", ")).font(.collieMono(11)))"))
                        .font(.collieUI(12)).fixedSize(horizontal: false, vertical: true)
                }
                if !card.events.isEmpty {
                    trTxt(Text("Eventos: \(Text(verbatim: card.events.joined(separator: ", ")).font(.collieMono(11)))"), Text("Events: \(Text(verbatim: card.events.joined(separator: ", ")).font(.collieMono(11)))")).font(.collieUI(12))
                    if let notify = card.notify {   // consult mode: recorded only, the agent reads them when it wants
                        Text(notify ? tr("Cada evento avisa o agente", "Each event notifies the agent") : tr("Eventos só ficam registrados; o agente não é avisado", "Events are only recorded; the agent isn't notified"))
                            .font(.collieUI(12)).foregroundStyle(Color.collieTextSecondary)
                    }
                }
                Text(tr("Aprovar fixa este manifesto (SHA-256); se ele mudar, o Collie pergunta de novo.", "Approving pins this manifest (SHA-256); if it changes, Collie asks again."))
                    .font(.collieUI(11)).foregroundStyle(Color.collieMuted).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.collieUI(11)).foregroundStyle(Color.collieDanger) }
            HStack {
                Spacer(minLength: 0)
                Button(tr("Negar", "Deny")) { answer(false) }.buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small).disabled(busy)
                if card.app == "work-loop" {   // a loop has no per-session permit: its lasting answer is the paddock's trust
                    Button(tr("Sempre neste cercado", "Always in this paddock")) { answer(true, always: true) }.buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small).disabled(busy)
                        .help(AccessCopy.loopAlwaysHelp)
                } else if card.kind == .confirm, card.app != "network" {
                    Button(tr("Permitir nesta sessão", "Allow this session")) { answer(true, session: true) }.buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small).disabled(busy)
                        .help(AccessCopy.sessionHelp(card.name))
                }
                Button(card.kind == .confirm ? tr("Permitir", "Allow") : tr("Aprovar", "Approve")) { answer(true) }.buttonStyle(CollieButtonStyle(.primary)).controlSize(.small).disabled(busy)
            }
        }
        .foregroundStyle(Color.collieText)
        .padding(12)
        .frame(width: 380, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.collieSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.collieAttention, lineWidth: 1))
    }

    private func answer(_ allow: Bool, session: Bool = false, always: Bool = false) {
        busy = true
        Task {
            do { try await client.answerApp(card, allow: allow, session: session, always: always) } catch { self.error = "\(error)"; Log.canvas.error("app card: \(error)") }
            busy = false
        }
    }
}
