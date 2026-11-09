import SwiftUI
import Charts
import CollieCore
import CollieTheme

/// A collie-ui block drawn natively (no HTML/JS from the agent). Header: kind, title, "{ } JSON" (the source as sent).
/// Compact node (< 420 pt): collapsed to one line with "abrir".
struct UIBlockView: View {
    let block: UIBlock
    let json: String
    let compact: Bool
    /// A form's choice, as the text of a normal prompt (the chat queues it while a dialog is up).
    let choose: ((String) -> Void)?
    /// "Anexar como painel" (chat only): opens the block as a panel; returns what to tell the user.
    var attach: (() async -> String)?
    @State private var note: String?
    @State private var open = false
    @State private var showJSON = false
    @State private var chosen: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(block.kind).font(.collieMono(10)).foregroundStyle(Color.collieAccent)
                Text(block.title ?? "").font(.collieMono(11).weight(.semibold)).foregroundStyle(Color.collieText).lineLimit(1)
                Spacer(minLength: 0)
                if let attach, !compact || open { Button("Anexar como painel") { Task { note = await attach() } }.buttonStyle(.plain).font(.collieMono(10)).foregroundStyle(Color.collieAccent) }
                if !compact || open { Button("{ } JSON") { showJSON.toggle() }.buttonStyle(.plain).font(.collieMono(10)).foregroundStyle(showJSON ? Color.collieAccent : Color.collieMuted) }
                if compact { Button(open ? "fechar" : "abrir") { open.toggle() }.buttonStyle(.plain).font(.collieMono(10)).foregroundStyle(Color.collieAccent) }
            }
            if let note { Text(note).font(.collieMono(10)).foregroundStyle(Color.collieMuted) }
            if !compact || open {
                if showJSON { Text(json).font(.collieMono(11)).foregroundStyle(Color.collieMuted).textSelection(.enabled) }
                else { content }
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.collieSidebar))
    }

    @ViewBuilder private var content: some View {
        switch block {
        case .table(_, let columns, let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow { ForEach(Array(columns.enumerated()), id: \.offset) { _, c in Text(c).font(.collieMono(11).weight(.semibold)) } }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        GridRow { ForEach(Array(r.enumerated()), id: \.offset) { _, c in Text(c).font(.collieMono(11)) } }
                    }
                }
                .foregroundStyle(Color.collieText).textSelection(.enabled)
            }
        case .diff(_, let old, let new):
            DiffView(old: old, new: new)
        case .tasks(_, let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, t in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: t.done ? "checkmark.square" : "square").font(.system(size: 11))
                        Text(t.text).strikethrough(t.done).font(.collieUI(12))
                    }
                    .foregroundStyle(t.done ? Color.collieMuted : Color.collieText)
                }
            }
        case .status(_, let items):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, p in
                    GridRow {
                        Text(p.key).foregroundStyle(Color.collieMuted)
                        Text(p.value).foregroundStyle(Color.collieText)
                    }
                    .font(.collieMono(11))
                }
            }
            .textSelection(.enabled)
        case .form(let title, let question, let choices):
            VStack(alignment: .leading, spacing: 6) {
                if let question { Text(question).font(.collieUI(12)).foregroundStyle(Color.collieText) }
                ForEach(choices, id: \.self) { c in
                    Button(c) {
                        chosen = c
                        choose?("[escolha do usuário · \(question ?? title ?? "formulário")] \(c)")
                    }
                    .disabled(chosen != nil || choose == nil).controlSize(.small)
                }
                if let chosen { Text("Escolheu: \(chosen)").font(.collieMono(10)).foregroundStyle(Color.collieMuted) }
            }
        case .chart(_, let type, let labels, let values):
            Chart(Array(values.enumerated()), id: \.offset) { i, v in
                switch type {
                case .bar: BarMark(x: .value("x", labels[i]), y: .value("y", v))
                case .line: LineMark(x: .value("x", labels[i]), y: .value("y", v))
                }
            }
            .frame(height: 140)
        }
    }
}
