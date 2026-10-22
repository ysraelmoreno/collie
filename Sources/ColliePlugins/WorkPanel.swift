import AppKit
import Foundation
import CollieCore
import CollieProtocol
import CollieTheme
import SwiftUI

/// One `work.list` entry: the terminal's name (a `Work` has only its id) and, for a closed work, when.
public struct WorkListing: Decodable, Identifiable, Equatable, Sendable {
    public let id: UUID, title: String, terminal: String, branch: String?, closedAt: Date?
}

/// State and daemon calls of the Work panel. Only `work.*` and the panel's events: nothing a remote client couldn't do.
@MainActor public final class WorkPanelModel: ObservableObject {
    /// Active works (full: tasks and jobs, from `work.status --all`).
    @Published public private(set) var works: [Work] = []
    /// Every work's listing, closed ones included.
    @Published public private(set) var listings: [WorkListing] = []
    @Published public var selected: UUID?
    /// The selected work's `work.summary` markdown (nil: not loaded, or it failed: the rest of the panel stands).
    @Published public private(set) var summary: String?
    /// The on-device model's rewrite of it (shown first), or why there is none.
    @Published public private(set) var naturalSummary: String?
    @Published public private(set) var summaryReason: String?
    /// "Ver dados": the deterministic markdown instead of the rewrite.
    @Published public var showSummaryData = false
    /// The selected work's rewrite in flight (up to 10 s): nothing else waits on it.
    private(set) var rewriting: Task<Void, Never>?
    /// Oldest first.
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var hasOlder = true
    @Published public private(set) var approvals: [Approval] = []
    @Published public private(set) var error: String?
    /// The last approval's `{sent: false, reason}`.
    @Published public private(set) var notice: String?
    /// Chat send, close and reopen (short calls). Approvals and rerails never wait on it.
    @Published public private(set) var busy = false
    /// Approvals being answered: only their own buttons wait.
    @Published public private(set) var approving: Set<UUID> = []
    /// Terminals a rerail is being typed into (it can wait up to 600 s for the agent).
    @Published public private(set) var rerailing: Set<String> = []
    /// Why the on-device assistant can't answer "?" questions (`work.assistant.status`); nil: it can.
    @Published public private(set) var assistantUnavailable: String?

    public var placeholder: String {
        "Mensagem — @nome para um agente" + (assistantUnavailable.map { " (assistente indisponível: \($0))" } ?? ", ? para perguntar ao assistente")
    }

    /// The quick buttons: label, and the exact phrase the registry answers for free (`StatusQuestion`).
    public static let quickQuestions: [(label: String, phrase: String)] =
        [("Onde estamos", "onde estamos"), ("O que travou", "o que travou"), ("O que está rodando", "o que está rodando"),
         ("Resumo", "resumo")]
    nonisolated static let pageSize = 50

    private let call: PanelHostContext.Call
    private var coalescer: RefreshCoalescer?

    public init(call: @escaping PanelHostContext.Call, window: Duration = .milliseconds(500)) {
        self.call = call
        coalescer = RefreshCoalescer(window: window) { [weak self] in await self?.refreshWorks() }
    }

    public var closed: [WorkListing] { listings.filter { $0.closedAt != nil } }
    /// nil: the work's terminal was removed (or isn't listed yet).
    public func terminalName(of w: Work) -> String? { listings.first { $0.id == w.id }.flatMap { $0.terminal.isEmpty ? nil : $0.terminal } }
    public func pendingApproval(_ w: Work) -> Bool { approvals.contains { $0.terminalId == w.terminalId } }
    /// A job gone or unknown, or the terminal waiting for an approval.
    public func hasAlert(_ w: Work) -> Bool { w.jobs.contains { $0.state == .gone || $0.state == .unknown } || pendingApproval(w) }

    public struct Count: Equatable, Sendable { public let state: TaskState, n: Int }
    /// Tasks per state, in display order, empty states left out.
    public func counts(_ w: Work) -> [Count] {
        Self.stateOrder.compactMap { s in let n = w.tasks.filter { $0.state == s }.count; return n > 0 ? Count(state: s, n: n) : nil }
    }
    public static let stateOrder: [TaskState] = [.inProgress, .open, .deferred, .abandoned, .done]

    // MARK: events

    public func handleEvent(_ name: String, _ payload: JSONValue) async {
        switch name {
        case "work.changed": await coalescer?.fire()
        case "work.chat":
            guard case .object(let o) = payload, let v = o["message"], let m = Self.decode(ChatMessage.self, v),
                  !messages.contains(where: { $0.id == m.id }) else { return }
            messages.append(m)
        case "work.approval": await loadApprovals()
        default: break
        }
    }

    /// The panel closed: events no longer refresh.
    public func stop() { coalescer?.cancel() }

    // MARK: loading

    public func refresh() async {
        error = nil
        await refreshWorks()
        await loadApprovals()
        struct Assistant: Decodable { let available: Bool; let reason: String? }
        if let a = try? await fetch(Assistant.self, "work.assistant.status", [:]) {
            assistantUnavailable = a.available ? nil : a.reason ?? "motivo desconhecido"
        }
        do throws(ProtocolError) {
            let page = try await fetch([ChatMessage].self, "work.chat.history", ["limit": .number(Double(Self.pageSize))])
            messages = page.reversed(); hasOlder = page.count == Self.pageSize
        } catch { self.error = Self.describe(error, nil) }
    }

    /// `work.list --closed` and `work.status --all`; keeps a valid selection.
    private func refreshWorks() async {
        do throws(ProtocolError) {
            listings = try await fetch([WorkListing].self, "work.list", ["closed": .bool(true)])
            struct Status: Decodable { let works: [Work] }
            works = try await fetch(Status.self, "work.status", ["all": .bool(true)]).works
            if !works.contains(where: { $0.id == selected }) { selected = works.first?.id }
        } catch { if !busy { self.error = Self.describe(error, nil) } }
        await loadSummary()
    }

    /// Selects a work and loads its summary.
    public func select(_ id: UUID) async {
        selected = id; showSummaryData = false; naturalSummary = nil; summaryReason = nil
        await loadSummary()
    }

    /// The deterministic summary now; the model's rewrite of it afterwards, in its own task.
    private func loadSummary() async {
        rewriting?.cancel()
        guard let id = selected else { summary = nil; naturalSummary = nil; summaryReason = nil; return }
        struct Sum: Decodable { let markdown: String; let text: String?; let reason: String? }
        let args: [String: JSONValue] = ["id": .string(id.uuidString.lowercased())]
        let s = try? await fetch(Sum.self, "work.summary", args)
        guard selected == id else { return }   // the selection may have moved meanwhile
        if s?.markdown != summary { naturalSummary = nil; summaryReason = nil }   // a rewrite of the old text no longer applies
        summary = s?.markdown
        guard let md = s?.markdown else { return }
        rewriting = Task { [weak self] in
            var a = args; a["natural"] = .bool(true)
            guard let n = try? await self?.fetch(Sum.self, "work.summary", a), let self,
                  !Task.isCancelled, self.selected == id, self.summary == md, n.markdown == md else { return }
            self.naturalSummary = n.text; self.summaryReason = n.reason.map(Self.reasonText)
        }
    }

    /// The daemon's reasons are Portuguese except the deadline's.
    static func reasonText(_ r: String) -> String { r == "timeout" ? "o modelo demorou mais de 10 s" : r }

    private func loadApprovals() async {
        do throws(ProtocolError) {
            let new = try await fetch([Approval].self, "work.approvals", [:])
            if Set(new.map(\.id)) != Set(approvals.map(\.id)) { notice = nil }   // an older result no longer applies
            approvals = new
        } catch { self.error = Self.describe(error, nil) }
    }

    /// The next page of older messages (the chat was scrolled to its top).
    public func loadOlder() async {
        guard hasOlder, let first = messages.first else { return }
        do throws(ProtocolError) {
            let page = try await fetch([ChatMessage].self, "work.chat.history",
                                       ["before": .string(first.id.uuidString.lowercased()), "limit": .number(Double(Self.pageSize))])
            messages.insert(contentsOf: page.reversed().filter { m in !messages.contains { $0.id == m.id } }, at: 0)
            hasOlder = page.count == Self.pageSize
        } catch { self.error = Self.describe(error, nil) }
    }

    // MARK: actions

    /// To the selected work's Maestro (or `@nome`); a status question is answered by the registry. Replies come as `work.chat`.
    public func send(_ text: String) async {
        var args: [String: JSONValue] = ["text": .string(text)]
        if let selected { args["work"] = .string(selected.uuidString.lowercased()) }
        await run(nil) { () throws(ProtocolError) in _ = try await self.call("work.chat.send", args) }
    }

    /// Never waits on another action: only this approval's buttons are disabled meanwhile.
    public func approve(_ id: UUID, allow: Bool) async {
        guard !approving.contains(id) else { return }
        let name = approvals.first { $0.id == id }?.terminal
        approving.insert(id); notice = nil
        var reason: String?
        await attempt(name) { () throws(ProtocolError) in
            let r = try await self.call("work.approve", ["id": .string(id.uuidString.lowercased()), "allow": .bool(allow)])
            if case .object(let o) = r, o["sent"] == .bool(false), case .string(let s)? = o["reason"] { reason = s }
        }
        approving.remove(id)
        await loadApprovals()
        notice = reason   // after the reload: the stale card leaving must not clear it
    }

    /// The user looks at the terminal themselves (an `unknown` approval, or a prompt no longer on screen): the daemon
    /// drops it and types nothing (`work.approval.dismiss`).
    public func dismiss(_ id: UUID) async {
        guard !approving.contains(id) else { return }
        approving.insert(id); notice = nil
        await attempt(approvals.first { $0.id == id }?.terminal) { () throws(ProtocolError) in
            _ = try await self.call("work.approval.dismiss", ["id": .string(id.uuidString.lowercased())])
        }
        approving.remove(id)
        await loadApprovals()
    }

    /// Tracked per terminal: the panel stays usable while the agent is being put back on track.
    public func rerail(_ terminal: String) async {
        guard rerailing.insert(terminal).inserted else { return }
        await attempt(terminal) { () throws(ProtocolError) in _ = try await self.call("work.rerail", ["terminal": .string(terminal)]) }
        rerailing.remove(terminal)
    }

    // ponytail: `work.done --id` rather than `--terminal`: also closes a work whose terminal was removed
    public func closeWork(_ id: UUID) async {
        await run(nil) { () throws(ProtocolError) in _ = try await self.call("work.done", ["id": .string(id.uuidString.lowercased())]) }
        await refreshWorks()
    }

    public func reopenWork(_ id: UUID) async {
        await run(listings.first { $0.id == id }.flatMap { $0.terminal.isEmpty ? nil : $0.terminal }) { () throws(ProtocolError) in _ = try await self.call("work.reopen", ["id": .string(id.uuidString.lowercased())]) }
        await refreshWorks()
    }

    /// Runs `body` with `busy` set (see `attempt`).
    private func run(_ terminal: String?, _ body: () async throws(ProtocolError) -> Void) async {
        busy = true
        await attempt(terminal, body)
        busy = false
    }

    /// Clears the error, runs `body`; a failure is shown in Portuguese.
    private func attempt(_ terminal: String?, _ body: () async throws(ProtocolError) -> Void) async {
        error = nil
        do throws(ProtocolError) { try await body() } catch { self.error = Self.describe(error, terminal) }
    }

    /// Format characters (bidi overrides, zero-width…) made visible as ⟨U+XXXX⟩: a captured prompt can't hide what is approved.
    public nonisolated static func visible(_ prompt: String) -> String {
        var out = ""
        for u in prompt.unicodeScalars {
            if u.properties.generalCategory == .format { out += "⟨U+" + String(format: "%04X", u.value) + "⟩" }
            else { out.unicodeScalars.append(u) }
        }
        return out
    }

    private func fetch<T: Decodable>(_ t: T.Type, _ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> T {
        let v = try await call(command, args)
        guard let r = Self.decode(t, v) else { throw ProtocolError(code: .internal, message: "Resposta inválida de \(command).") }
        return r
    }

    static func decode<T: Decodable>(_ t: T.Type, _ v: JSONValue) -> T? {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(t, from: JSONEncoder().encode(v))
    }

    /// The daemon's English errors in Portuguese; `terminal` names the agent when the message doesn't ('name' in quotes).
    static func describe(_ e: ProtocolError, _ terminal: String?) -> String {
        let m = e.message
        let quoted = m.split(separator: "'", omittingEmptySubsequences: false)
        let name = terminal ?? (quoted.count >= 3 ? String(quoted[1]) : "O terminal")
        if m.contains("no active work") { return "Nenhum trabalho ativo." }
        if m.hasPrefix("work already open: ") {
            return "\(terminal ?? "O terminal") já tem um trabalho aberto (\(m.dropFirst("work already open: ".count)))."
        }
        if m.hasPrefix("no work ") || (m.hasPrefix("Terminal '") && m.hasSuffix("' not found")) { return "Trabalho ou terminal não encontrado." }
        if m.contains("already closed") { return "Esse trabalho já foi fechado." }
        if m.hasPrefix("Multiple terminals named") { return "Mais de um terminal se chama \(name)." }
        if m.contains("waiting for an approval") { return "\(name) está esperando uma aprovação; nada foi enviado." }
        if e.code == .notRunning || m.contains("is not running") { return "\(name) não está rodando." }
        if e.code == .timeout {
            return m.contains("not delivered") || m.contains("not accepting input")
                ? "\(name) ainda não estava pronto; nada foi enviado." : "\(name) demorou demais para responder."
        }
        return isPortuguese(m) ? m : "Algo deu errado: \(m)"
    }

    /// The daemon's own Portuguese messages (`work.chat.*`, `work.approve`, `work.rerail`), shown as they are.
    static func isPortuguese(_ m: String) -> Bool {
        portugueseMessages.contains(m) || m.hasPrefix("Nada para mandar depois de @")
            || portugueseEndings.contains { m.hasSuffix($0) && m.count > $0.count }
    }
    static let portugueseMessages: Set<String> = ["Mensagem não encontrada.", "Mensagem vazia.", "A mensagem passa de 8 000 caracteres.",
                                                  "Trabalho não encontrado.", "Aprovação inválida.",
                                                  "Nada para perguntar depois de ?."]
    /// After the terminal's name.
    static let portugueseEndings = [" está pedindo aprovação; recolocar no trilho depois de responder",
                                    " não aceita colar texto com segurança; recolocar no trilho só em agentes"]
}

/// The Work plug-in: works, approvals and the chat over `work.*`. No agent commands (agents use `collie work …`).
@MainActor public final class WorkPanel: PluginPanelView {
    let model: WorkPanelModel
    public let view: NSView
    public init(panel: Panel, host: PanelHostContext) {
        model = WorkPanelModel(call: host.call)
        view = NSHostingView(rootView: WorkView(model: model))
    }
    public func handle(_ command: String, _ args: [String: JSONValue]) async throws(ProtocolError) -> JSONValue {
        throw ProtocolError(code: .notFound, message: "work has no commands")
    }
    public func close() { model.stop() }
    public func receive(event: String, payload: JSONValue) { Task { [model] in await model.handleEvent(event, payload) } }

    /// One per workspace: the app focuses this one instead of opening another.
    public static func existing(in panels: [Panel]) -> Panel? { panels.first { $0.pluginId == "work" } }
}

// MARK: - View

extension TaskState {
    var label: String {
        switch self {
        case .open: "aberta"
        case .inProgress: "em andamento"
        case .done: "feita"
        case .deferred: "para depois"
        case .abandoned: "não feita"
        }
    }
    var tone: CollieTag.Tone {
        switch self {
        case .inProgress: .accent
        case .open: .secondary
        case .deferred: .attention
        case .done, .abandoned: .neutral
        }
    }
}

extension JobState {
    var label: String {
        switch self {
        case .running: "rodando"
        case .finished: "terminou"
        case .gone: "sumiu"
        case .unknown: "desconhecido"
        }
    }
    var tone: CollieTag.Tone {
        switch self {
        case .running: .accent
        case .finished: .neutral
        case .gone, .unknown: .attention
        }
    }
}

struct WorkView: View {
    @ObservedObject var model: WorkPanelModel
    @State private var draft = ""
    @State private var showClosed = false
    @State private var closing: Work?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Trabalho", subtitle: model.works.count == 1 ? "1 ativo" : "\(model.works.count) ativos") {
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(CollieButtonStyle(.quiet)).help("Atualizar").accessibilityLabel("Atualizar")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let e = model.error { Text(e).font(.collieUI(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled) }
                    if let n = model.notice { Text(n).font(.collieUI(12)).foregroundStyle(Color.collieAttention) }
                    ForEach(model.approvals) { approvalCard($0) }   // first: what waits for the user
                    if model.works.isEmpty { Text("Nenhum trabalho ativo.").font(.collieUI(13)).foregroundStyle(Color.collieMuted) }
                    ForEach(model.works, id: \.id) { workRow($0) }
                    if !model.closed.isEmpty { closedGroup }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            Rectangle().fill(Color.collieBorder).frame(height: 1)
            chat.frame(maxHeight: .infinity)
            PanelFooter("collie work status", trailing: model.selected.flatMap { id in model.works.first { $0.id == id } }.flatMap(model.terminalName))
        }
        .background(Color.collieSidebar)
        .task { await model.refresh() }
        .confirmationDialog("Fechar \(closing?.title ?? "")?", isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
                            titleVisibility: .visible, presenting: closing) { w in
            Button("Fechar") { Task { await model.closeWork(w.id) } }
        } message: { _ in Text("Dá para reabrir depois em Fechados.") }
    }

    // MARK: works

    private func workRow(_ w: Work) -> some View {
        let sel = model.selected == w.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { Task { await model.select(w.id) } } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(w.title).font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText).lineLimit(1)
                            if let t = model.terminalName(of: w), model.rerailing.contains(t) { CollieTag("recolocando…", tone: .secondary) }
                            if model.hasAlert(w) {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.collieAttention)
                                    .help(alertText(w)).accessibilityLabel("Alerta: " + alertText(w))
                            }
                        }
                        Text((model.terminalName(of: w) ?? "terminal removido") + (w.branch.map { " · \($0)" } ?? "")).font(.collieMono(12)).foregroundStyle(Color.collieMuted)
                        HStack(spacing: 4) { ForEach(model.counts(w), id: \.state) { CollieTag("\($0.n) \($0.state.label)", tone: $0.state.tone) } }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(sel ? .isSelected : [])
                Menu {
                    if let t = model.terminalName(of: w) {   // a removed terminal can't be put back on track
                        Button("Recolocar no trilho") { Task { await model.rerail(t) } }.disabled(model.rerailing.contains(t))
                    }
                    Button("Fechar…") { closing = w }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("Ações do trabalho").accessibilityLabel("Ações de \(w.title)")
            }
            if sel { details(w) }
        }
        .padding(12)
        .collieCard(highlight: sel ? Color.collieAccent : nil)
    }

    private func alertText(_ w: Work) -> String {
        var parts: [String] = []
        if w.jobs.contains(where: { $0.state == .gone || $0.state == .unknown }) { parts.append("job sumiu ou desconhecido") }
        if model.pendingApproval(w) { parts.append("esperando aprovação") }
        return parts.joined(separator: ", ")
    }

    private func details(_ w: Work) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let s = model.summary {
                DisclosureGroup("Resumo") {
                    // the title line ("## …") is already the row's
                    let data = s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined()
                    let body = model.showSummaryData ? data : model.naturalSummary ?? data
                    Text((try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                         ?? AttributedString(body))
                        .font(.collieUI(12)).foregroundStyle(Color.collieText).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.naturalSummary != nil {
                        Button(model.showSummaryData ? "Ver resumo" : "Ver dados") { model.showSummaryData.toggle() }
                            .buttonStyle(.link).font(.collieUI(11))
                    } else if let why = model.summaryReason {
                        Text("Resumo sem reescrita: \(why)").font(.collieUI(11)).foregroundStyle(Color.collieTextSecondary)
                    }
                }
                .font(.collieUI(12, .semibold)).foregroundStyle(Color.collieTextSecondary)
            }
            ForEach(WorkPanelModel.stateOrder, id: \.self) { s in
                let ts = w.tasks.filter { $0.state == s }
                if !ts.isEmpty {
                    Text(s.label.capitalized).font(.collieUI(12, .semibold)).foregroundStyle(Color.collieTextSecondary)
                    ForEach(ts, id: \.id) { t in
                        Text("• " + t.title + (t.reason.map { " — \($0)" } ?? "")).font(.collieUI(12)).foregroundStyle(Color.collieText)
                    }
                }
            }
            if !w.jobs.isEmpty {
                Text("Jobs").font(.collieUI(12, .semibold)).foregroundStyle(Color.collieTextSecondary)
                ForEach(w.jobs.filter { $0.state != .finished }, id: \.id) { j in
                    HStack(spacing: 6) { CollieTag(j.state.label, tone: j.state.tone); Text(j.label).font(.collieMono(12)).foregroundStyle(Color.collieText).lineLimit(1) }
                }
            }
        }
    }

    private var closedGroup: some View {
        DisclosureGroup(isExpanded: $showClosed) {
            ForEach(model.closed) { l in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.title).font(.collieUI(13)).foregroundStyle(Color.collieText).lineLimit(1)
                        Text(l.terminal).font(.collieMono(11)).foregroundStyle(Color.collieMuted)
                    }
                    Spacer()
                    Button("Reabrir") { Task { await model.reopenWork(l.id) } }.buttonStyle(CollieButtonStyle(.secondary)).disabled(model.busy)
                }
            }
        } label: { Text("Fechados (\(model.closed.count))").font(.collieUI(13, .semibold)).foregroundStyle(Color.collieTextSecondary) }
    }

    // MARK: approvals

    /// The captured prompt in full: the user sees exactly what they approve. Aprovar is never the default action.
    private func approvalCard(_ a: Approval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                CollieTag(a.kind == .unknown ? "olhe o terminal" : "aprovação", tone: .attention)
                Text(a.terminal).font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText)
            }
            if a.kind == .unknown {
                Text(a.reason).font(.collieUI(12)).foregroundStyle(Color.collieText).textSelection(.enabled)
                Button("Entendi, vou olhar o terminal") { Task { await model.dismiss(a.id) } }.buttonStyle(CollieButtonStyle(.secondary))
                    .disabled(model.approving.contains(a.id))
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(WorkPanelModel.visible(a.prompt)).font(.collieMono(12)).foregroundStyle(Color.collieText).textSelection(.enabled)
                        .fixedSize().padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220).background(Color.collieSunken, in: .rect(cornerRadius: 8))
                .accessibilityLabel("Pedido capturado: " + WorkPanelModel.visible(a.prompt))
                HStack(spacing: 8) {
                    Button("Aprovar") { Task { await model.approve(a.id, allow: true) } }.buttonStyle(CollieButtonStyle(.primary))
                    Button("Negar") { Task { await model.approve(a.id, allow: false) } }.buttonStyle(CollieButtonStyle(.secondary))
                    Spacer()
                    Button("Dispensar") { Task { await model.dismiss(a.id) } }.buttonStyle(CollieButtonStyle(.quiet))
                        .help("o pedido já não está na tela").accessibilityHint("o pedido já não está na tela; nada é digitado")
                }
                .disabled(model.approving.contains(a.id))
            }
        }
        .padding(12)
        .collieCard(highlight: Color.collieAttention)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Aprovação de \(a.terminal)")
    }

    // MARK: chat

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.hasOlder && !model.messages.isEmpty {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                            .onAppear { Task { await model.loadOlder() } }   // scrolled to the top
                    }
                    ForEach(model.messages) { bubble($0) }
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
            HStack(spacing: 6) {
                ForEach(WorkPanelModel.quickQuestions, id: \.phrase) { q in
                    Button(q.label) { Task { await model.send(q.phrase) } }.buttonStyle(CollieButtonStyle(.quiet)).controlSize(.small)
                }
            }
            .disabled(model.busy).padding(.horizontal, 8)
            HStack(alignment: .bottom, spacing: 6) {
                TextField(model.placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...6).collieField()
                    .help("Enter envia, Shift+Enter quebra linha")
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { draft += "\n"; return .handled }
                        submit(); return .handled
                    }
                Button(action: submit) { Image(systemName: "paperplane") }
                    .buttonStyle(CollieButtonStyle(.primary)).help("Enviar").accessibilityLabel("Enviar")
                    .disabled(model.busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(8)
        }
    }

    private func submit() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !model.busy else { return }
        draft = ""
        Task { await model.send(t) }
    }

    private func bubble(_ m: ChatMessage) -> some View {
        let text = (try? AttributedString(markdown: m.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(m.text)
        return VStack(alignment: m.role == .user ? .trailing : .leading, spacing: 2) {
            if m.role == .agent, let n = m.terminal { Text(n).font(.collieMono(11, .medium)).foregroundStyle(Color.collieSecondary) }
            Text(text).font(m.role == .collie ? .collieMono(12) : .collieUI(13))
                .foregroundStyle(m.role == .collie ? Color.collieMuted : .collieText).textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(m.role == .user ? Color.collieRaised : m.role == .agent ? Color.collieSurface : .clear, in: .rect(cornerRadius: 10))
            if m.truncated { Text("(cortada)").font(.collieMono(10)).foregroundStyle(Color.collieMuted) }
        }
        .frame(maxWidth: .infinity, alignment: m.role == .user ? .trailing : .leading)
    }
}
