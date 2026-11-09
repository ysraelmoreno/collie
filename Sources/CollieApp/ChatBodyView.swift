import SwiftUI
import CollieClient
import CollieCore
import CollieProtocol
import CollieTheme

/// A chat row: a message, or a tool call with its result (matched by tool id).
struct ChatItem: Identifiable, Equatable {
    var id: Int
    var message: ChatEntry?            // user / assistant text
    var tool: ChatEntry?               // toolUse
    var result: ChatEntry?             // its toolResult, once seen
}

/// The transcript of one Claude terminal as chat items, grown incrementally (`terminal.chat --since`).
@MainActor @Observable final class ChatModel {
    private(set) var items: [ChatItem] = []
    private(set) var error: String?
    private var end: UInt64 = 0
    private var next = 0
    private var byTool: [String: Int] = [:]   // tool id → index in items

    func append(_ entries: [ChatEntry]) {
        for e in entries {
            switch e.kind {
            case .user, .assistant: items.append(ChatItem(id: next, message: e)); next += 1
            case .toolUse:
                if let t = e.toolId { byTool[t] = items.count }
                items.append(ChatItem(id: next, tool: e)); next += 1
            case .toolResult:
                if let t = e.toolId, let i = byTool[t] { items[i].result = e }
            }
        }
    }

    func refresh(_ client: DaemonClient, name: String) async {
        do {
            let r = try await client.chat(name, since: end)
            if r.end < end { items = []; byTool = [:]; next = 0 }   // the transcript was rewritten: from the top
            append(r.entries); end = r.end; error = nil
        } catch { self.error = (error as? ProtocolError)?.message ?? "\(error)" }
    }
}

/// The chat body of a Claude terminal node (slice 1: messages, collapsible tool calls, composer with the dialog queue).
struct ChatBodyView: View {
    static let compactWidth: CGFloat = 420   // below: text only, tool calls collapsed to one line with "abrir"

    let id: UUID
    let client: DaemonClient
    @State private var model = ChatModel()
    @State private var draft = ""
    @State private var queue: [String] = []
    @State private var sendError: String?
    @State private var approval: Approval?
    @State private var answering = false
    @State private var sent: (id: UUID, prompt: String)?   // the key went out; the daemon re-raises the approval if the dialog did not take it
    @State private var notEntered = false
    @FocusState private var composing: Bool

    private var name: String { client.terminals.first { $0.id == id }?.name ?? "" }
    /// A dialog (permission, question, trust folder) is on the terminal's screen: typed text must never reach it.
    private var dialogUp: Bool { client.badges[id] == .attention }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < Self.compactWidth
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(model.items) { item in ChatRow(item: item, compact: compact, choose: { choice in Task { await submit(choice) } }, attach: { json in await attachBlock(json) }).id(item.id) }
                            if dialogUp {
                                DialogCard(approval: approval, busy: answering, waiting: sent != nil, notEntered: notEntered) { allow, option in Task { await answer(allow: allow, option: option) } }
                            }
                            if let e = model.error { Text(e).font(.collieMono(11)).foregroundStyle(Color.collieDanger) }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: model.items.last?.id) { if let l = model.items.last?.id { proxy.scrollTo(l, anchor: .bottom) } }
                }
                composer
            }
        }
        .background(Color.collieSurface)
        .task(id: client.chatEnd[id]) { await model.refresh(client, name: name) }   // first load too: chatEnd is nil until a hook
        .task(id: dialogUp) {   // the dialog's card: the screen the daemon captured, refreshed while it is up (a redraw changes it)
            guard dialogUp else { approval = nil; sent = nil; notEntered = false; return }
            while !Task.isCancelled {
                approval = try? await client.approvals().first { $0.terminalId == id }
                if let s = sent, let a = approval {
                    // back after the answer (the daemon waits 3 s for the dialog to close): the key did not go in; no retry here
                    if a.id == s.id || a.prompt == s.prompt { notEntered = true }   // redrawn dialogs may get a new id
                    sent = nil
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: dialogUp) { if !dialogUp { Task { await flush() } } }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(queue.enumerated()), id: \.offset) { _, q in
                Text("na fila: \(q)").font(.collieMono(11)).foregroundStyle(Color.collieMuted).lineLimit(1)
            }
            if let e = sendError { Text(e).font(.collieMono(11)).foregroundStyle(Color.collieDanger) }
            TextField(dialogUp ? "Na fila até o diálogo fechar…" : "Mensagem para \(name)…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(.collieMono(12)).lineLimit(1...5)
                .onSubmit { Task { await submit() } }
                .focused($composing)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.collieSidebar))
                .contentShape(Rectangle()).onTapGesture { composing = true }   // a plain field only hits its text line: the whole box focuses it
        }
        .padding(10)
    }

    /// Click on the card: by the option's digit or Permitir/Negar, through the chat-approval path, never as text. The
    /// composer's queue goes out when the badge leaves attention (`onChange` above).
    private func answer(allow: Bool, option: Int?) async {
        guard let a = approval, !answering else { return }
        answering = true; defer { answering = false }
        do {
            if try await client.answerApproval(a, allow: allow, option: option) { approval = nil; sendError = nil; notEntered = false; sent = (a.id, a.prompt) }
            else { sendError = "Não foi possível responder daqui; use o terminal." }
        } catch { sendError = (error as? ProtocolError)?.message ?? "\(error)" }
    }

    private func submit() async {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        await submit(t)
    }

    /// The composer's text, or a collie-ui form's choice: a normal prompt, queued while a dialog is up.
    private func submit(_ t: String) async {
        guard !t.isEmpty else { return }
        if dialogUp { queue.append(t); return }   // never typed into the dialog: sent when it closes
        await send(t)
    }

    private func attachBlock(_ json: String) async -> String {
        do {
            let r = try await client.attachBlock(id, json: json)
            return r.linked ? "Painel \(r.panel) aberto, ligado ao app" : "Painel \(r.panel) aberto (instantâneo)" + (r.why.map { ": \($0)" } ?? "")
        } catch { return (error as? ProtocolError)?.message ?? "\(error)" }
    }

    private func flush() async {
        while !queue.isEmpty, !dialogUp { await send(queue.removeFirst()) }
    }

    private func send(_ text: String) async {
        do { try await client.say(name, text); sendError = nil }
        catch { sendError = (error as? ProtocolError)?.message ?? "\(error)" }
    }
}

private struct ChatRow: View {
    let item: ChatItem
    let compact: Bool
    let choose: (String) -> Void   // a collie-ui form's choice
    let attach: (String) async -> String   // "Anexar como painel": the block's JSON → what to tell the user

    var body: some View {
        if let m = item.message {
            let user = m.kind == .user
            VStack(alignment: .leading, spacing: 4) {
                Text(user ? "você" : "agente").font(.collieMono(10)).foregroundStyle(user ? Color.collieSecondary : Color.collieAccent)
                // blocks only in the agent's replies: a collie-ui fence typed by the user (or quoted back) is just text
                ForEach(Array((user ? [ChatSegment.text(m.text)] : ChatSegment.split(m.text)).enumerated()), id: \.offset) { _, seg in
                    switch seg {
                    case .text(let t): Text(Self.markdown(t)).font(.collieUI(13)).foregroundStyle(Color.collieText).textSelection(.enabled)
                    case .ui(let b, let json): UIBlockView(block: b, json: json, compact: compact, choose: choose, attach: { await attach(json) })
                    case .code(let c): Text(c).font(.collieMono(11)).foregroundStyle(Color.collieMuted).textSelection(.enabled)
                    }
                }
            }
        } else if let t = item.tool {
            ToolBlock(tool: t, result: item.result, compact: compact)
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// A tool call: one line (name, input summary, status), its diff or result when opened.
private struct ToolBlock: View {
    let tool: ChatEntry
    let result: ChatEntry?
    let compact: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9))
                    Text(tool.tool ?? "?").font(.collieMono(11).weight(.semibold))
                    if !compact || !open { Text(tool.summary ?? "").lineLimit(1).truncationMode(.middle).foregroundStyle(Color.collieMuted) }
                    Spacer(minLength: 0)
                    if result?.isError == true { Text("erro").foregroundStyle(Color.collieDanger) }
                    else if result == nil { Text("…").foregroundStyle(Color.collieMuted) }
                    if compact && !open { Text("abrir").foregroundStyle(Color.collieAccent) }
                }
                .font(.collieMono(11)).foregroundStyle(Color.collieText).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                if tool.new != nil { DiffView(old: tool.old, new: tool.new ?? "") }
                if let r = result, !r.text.isEmpty {
                    Text(r.text).font(.collieMono(11)).foregroundStyle(r.isError == true ? Color.collieDanger : Color.collieMuted)
                        .lineLimit(40).textSelection(.enabled)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.collieSidebar))
    }
}

/// Edit/Write: the removed lines in red, the added in green.
struct DiffView: View {
    let old: String?, new: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                Text(l.text).font(.collieMono(11)).foregroundStyle(l.add ? Color.green : Color.collieDanger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background((l.add ? Color.green : Color.collieDanger).opacity(0.12))
            }
        }
        .textSelection(.enabled)
    }
    private var lines: [(text: String, add: Bool)] {
        let cap = 60   // ponytail: no real diff, the whole old then the whole new, cut at 60 lines
        let rm = (old ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { ("- " + $0, false) }
        let add = new.split(separator: "\n", omittingEmptySubsequences: false).map { ("+ " + $0, true) }
        return Array((old == nil ? add : rm + add).prefix(cap)).map { (text: $0.0, add: $0.1) }
    }
}

/// A dialog the agent waits on: permission (Permitir / nesta sessão / Negar) or a single-choice question (its options).
/// Trust-folder, multi-select questions and anything unreadable stay terminal-only.
private struct DialogCard: View {
    let approval: Approval?
    let busy: Bool
    let waiting: Bool       // answered; the daemon is checking that the dialog closed
    let notEntered: Bool    // it did not: the approval is back, nothing was retried
    let answer: (_ allow: Bool, _ option: Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if notEntered { Text("não entrou, tente de novo").font(.collieMono(11)).foregroundStyle(Color.collieDanger) }
            if let a = approval {
                Text(a.isQuestion ? "pergunta do agente" : "pede permissão").font(.collieMono(10)).foregroundStyle(Color.collieAttention)
                if !a.question.isEmpty { Text(a.question).font(.collieMono(11)).foregroundStyle(Color.collieText).textSelection(.enabled) }
                let options = a.options
                if options.isEmpty {
                    Text("Responda no terminal: alterne para Terminal no cabeçalho.").font(.collieMono(11)).foregroundStyle(Color.collieMuted)
                } else if a.isQuestion {
                    ForEach(options) { o in Button(o.label) { answer(true, o.number) }.disabled(busy) }
                } else {
                    HStack {
                        if let yes = options.first(where: { !$0.isSession && !$0.isNo }) { Button("Permitir") { answer(true, yes.number) }.disabled(busy) }
                        if let s = options.first(where: \.isSession) { Button("Nesta sessão") { answer(true, s.number) }.disabled(busy) }
                        Button("Negar") { answer(false, nil) }.disabled(busy)   // Esc: "No"
                    }
                }
            } else if waiting {
                Text("resposta enviada…").font(.collieMono(11)).foregroundStyle(Color.collieMuted)
            } else {
                Text("O agente espera uma resposta. Alterne para Terminal para responder.").font(.collieMono(11)).foregroundStyle(Color.collieAttention)
            }
        }
        .controlSize(.small)
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.collieAttentionTint))
    }
}
