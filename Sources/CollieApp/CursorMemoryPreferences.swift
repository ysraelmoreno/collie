import SwiftUI
import CollieTheme
import CollieClient
import CollieProtocol

/// Preferências › Memória: "Memória no Cursor" (`memory.cursor-mode`), the ledger's note (`memory.provenance-status`)
/// and "Editadas fora do Collie" (`memory.untrusted` → `memory.trust`, one at a time after its difference: C7).
/// Reads once when shown and connected, and again after each change (like `PluginsPreferences`).
struct CursorMemoryPreferences: View {
    let client: DaemonClient
    @State private var choice: CursorMemoryChoice?
    @State private var note: String?
    @State private var untrusted: [UntrustedMemory] = []
    @State private var open: String?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Memória no Cursor").font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText)
            Picker("", selection: Binding(get: { choice ?? .full }, set: { set($0) })) {
                ForEach(CursorMemoryChoice.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup).labelsHidden().disabled(!connected || working || choice == nil)
            muted((choice ?? .full).detail)
            muted(CursorMemoryChoice.sessionsNote + (choice == .full ? " " + CursorMemoryChoice.allowlistNote : ""))
            muted(CursorMemoryChoice.honest)

            Text("Editadas fora do Collie").font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText).padding(.top, 8)
            muted("Memórias que não foram gravadas pelo Collie (editadas à mão, por um agente ou por git) aparecem para os agentes só pelo título até você confiar em cada uma.")
            if let note { Text(note).font(.collieMono(12)).foregroundStyle(Color.collieAttention).fixedSize(horizontal: false, vertical: true) }
            if untrusted.isEmpty { muted(connected ? "Nenhuma." : "—") }
            ForEach(untrusted) { m in row(m) }
            if let error { Text(error).font(.collieMono(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled) }
        }
        .task(id: connected) { await load() }
    }

    private var connected: Bool { client.state == .connected }

    @ViewBuilder
    private func row(_ m: UntrustedMemory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(m.title).font(.collieUI(13))
                Text("\(m.kind) · \(m.where)").font(.collieMono(11)).foregroundStyle(Color.collieMuted)
                Spacer()
                Button(open == m.id ? "Fechar" : "Ver diferença") { open = open == m.id ? nil : m.id }.buttonStyle(CollieButtonStyle(.quiet))
            }
            muted(m.summary)
            if open == m.id {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(UntrustedMemory.diff(before: m.before, after: m.after).enumerated()), id: \.offset) { _, l in line(l) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220).padding(6).background(Color.collieSurface).textSelection(.enabled)
                HStack {
                    Text(m.file).font(.collieMono(11)).foregroundStyle(Color.collieMuted).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    // only after the difference was shown (C7: never in bulk, never unseen)
                    Button("Confiar") { trust(m) }.buttonStyle(CollieButtonStyle(.primary)).disabled(!connected || working)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func line(_ l: UntrustedMemory.DiffLine) -> some View {
        switch l {
        case .same(let s): Text("  " + s).font(.collieMono(11)).foregroundStyle(Color.collieTextSecondary)
        case .removed(let s): Text("− " + s).font(.collieMono(11)).foregroundStyle(Color.collieDanger)
        case .added(let s): Text("+ " + s).font(.collieMono(11)).foregroundStyle(Color.collieAttention)
        }
    }

    private func load() async {
        guard connected else { return }
        do {
            choice = CursorMemoryChoice.from(reply: try await client.adminCall("memory.cursor-mode", [:]))
            note = UntrustedMemory.ledgerNote(try await client.adminCall("memory.provenance-status", [:]))
            untrusted = UntrustedMemory.list(try await client.adminCall("memory.untrusted", [:]))
            error = nil
        } catch { self.error = (error as? ProtocolError)?.message ?? "\(error)" }
    }

    private func set(_ c: CursorMemoryChoice) {
        let before = choice
        choice = c; working = true
        Task {
            if let r = try? await client.adminCall("memory.cursor-mode", ["value": .string(c.rawValue)]), let got = CursorMemoryChoice.from(reply: r) { choice = got }
            else { choice = before }   // refused or daemon gone: show what is saved
            working = false
        }
    }

    private func trust(_ m: UntrustedMemory) {
        working = true; error = nil
        Task {
            do { _ = try await client.adminCall("memory.trust", m.trustArgs); open = nil } catch { self.error = (error as? ProtocolError)?.message ?? "\(error)" }
            working = false
            await load()
        }
    }

    private func muted(_ s: String) -> some View { Text(s).font(.collieMono(12)).foregroundStyle(Color.collieMuted).fixedSize(horizontal: false, vertical: true) }
}
