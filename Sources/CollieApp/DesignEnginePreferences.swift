import SwiftUI
import CollieTheme
import CollieCore
import CollieClient
import CollieProtocol

/// Preferências › Desenho e sandbox, "Motor de design (FigCraft)": draws `DesignEngineStatus.row`; reads
/// `design.engine.status` every 1 s while a job runs, 3 s otherwise, while shown and connected (like `AndroidPreferences`).
/// The job lives in the daemon: leaving the page only stops the reads. The Baixar click is the only confirmation.
struct DesignEnginePreferences: View {
    let client: DaemonClient
    @State private var status: DesignEngineStatus?
    @State private var error: String?
    @State private var loadError: String?
    @State private var working = false
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Motor de design (FigCraft)", "Design engine (FigCraft)")).font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText)
            if let s = status { content(s, DesignEngineStatus.row(s)) } else { note(connected ? tr("Lendo o estado do motor…", "Reading the engine state…") : "—") }
            if let loadError { Text(loadError).font(.collieMono(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled) }
            if let error { Text(error).font(.collieMono(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled) }
        }
        .task(id: connected) {
            while connected, !Task.isCancelled {
                await load()
                try? await Task.sleep(for: DesignEngineStatus.pollInterval(status))
            }
        }
        .confirmationDialog(tr("Remover o motor de design?", "Remove the design engine?"), isPresented: $confirmRemove) {
            Button(tr("Remover", "Remove"), role: .destructive) { run("design.engine.remove") }
        } message: {
            Text(tr("Os arquivos de design continuam; o painel Design fica indisponível até baixar de novo.", "Design files stay; the Design panel is unavailable until you download again."))
        }
    }

    private var connected: Bool { client.state == .connected }
    private var enabled: Bool { connected && !working }

    @ViewBuilder
    private func content(_ s: DesignEngineStatus, _ row: DesignEngineRow) -> some View {
        if case .downloading = row, let j = s.job, j.total > 0 {
            ProgressView(value: Double(min(j.bytes, j.total)), total: Double(j.total)).tint(Color.collieAttention)
        }
        HStack(spacing: 12) {
            Text(row.text).font(.collieMono(12))
                .foregroundStyle(row == .failed(s.job?.error ?? "") ? Color.collieDanger : Color.collieTextSecondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer()
            if s.running {
                Button { run("design.engine.cancel") } label: { Text(tr("Cancelar", "Cancel")).foregroundStyle(Color.collieDanger) }
                    .buttonStyle(CollieButtonStyle(.quiet)).disabled(!enabled)
            }
            if let b = row.button {
                Button(b) { run("design.engine.install") }.buttonStyle(CollieButtonStyle(.primary)).disabled(!enabled)
            }
            if row.canRemove {
                Button { confirmRemove = true } label: { Text(tr("Remover", "Remove")).foregroundStyle(Color.collieDanger) }
                    .buttonStyle(CollieButtonStyle(.quiet)).disabled(!enabled)
            }
        }
        // installing over or removing a running engine closes its clients
        if row.canRemove { note(tr("Os painéis Design abertos vão reconectar.", "Open Design panels will reconnect.")) }
    }

    private func load() async {
        guard connected else { return }
        do {
            guard let s = DesignEngineStatus.from(try await client.adminCall("design.engine.status", [:])) else {
                loadError = tr("design.engine.status: resposta inesperada", "design.engine.status: unexpected reply"); return
            }
            status = s; loadError = nil
        } catch { loadError = error.message }
    }

    private func run(_ command: String) {
        working = true; error = nil
        Task {
            do { _ = try await client.adminCall(command, [:]) } catch { self.error = (error as? ProtocolError)?.message ?? "\(error)" }
            working = false
            await load()
        }
    }

    private func note(_ s: String) -> some View { Text(s).font(.collieMono(12)).foregroundStyle(Color.collieMuted).fixedSize(horizontal: false, vertical: true) }
}
