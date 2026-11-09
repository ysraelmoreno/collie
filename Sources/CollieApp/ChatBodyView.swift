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
                            ForEach(model.items) { item in ChatRow(item: item, compact: compact).id(item.id) }
                            if dialogUp {
                                Text("O agente espera uma resposta no terminal. Alterne para Terminal para responder.")
                                    .font(.collieMono(11)).foregroundStyle(Color.collieAttention)
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
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.collieSidebar))
        }
        .padding(10)
    }

    private func submit() async {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        draft = ""
        if dialogUp { queue.append(t); return }   // never typed into the dialog: sent when it closes
        await send(t)
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

    var body: some View {
        if let m = item.message {
            let user = m.kind == .user
            VStack(alignment: .leading, spacing: 2) {
                Text(user ? "você" : "agente").font(.collieMono(10)).foregroundStyle(user ? Color.collieSecondary : Color.collieAccent)
                Text(Self.markdown(m.text)).font(.collieUI(13)).foregroundStyle(Color.collieText).textSelection(.enabled)
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
private struct DiffView: View {
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
