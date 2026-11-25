import SwiftUI
import AppKit
import CollieTheme
import CollieClient
import CollieProtocol

/// Preferências › Atualizações (spec 2026-11-17 §3): the installed version and the last check, the two switches, the
/// offered version's card (download progress, Instalar…, Pular esta versão), "Voltar para <v>" while the previous bundle
/// is kept. Reads `app.update.status` every 1 s while downloading, 3 s otherwise, while shown and connected. A local
/// build ("Collie Local", no team) never updates itself: the page says so and checks nothing.
struct UpdatePreferences: View {
    let client: DaemonClient
    @ObservedObject private var sparkle = SparkleUpdater.shared
    @State private var status: UpdateStatus?
    @State private var refusal: AppUpdateSwap.Refusal?
    @State private var refusalRead = false
    @State private var auto = true
    @State private var background = true
    @State private var loadError: String?
    @State private var error: String?
    @State private var working = false
    @State private var sheetOpen = false
    @State private var installWhenReady = false
    @State private var engine: String?
    @State private var confirmRollback = false

    private var connected: Bool { client.state == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if refusal == .localBuild {
                note(UpdateModel.localBuild)
            } else if refusalRead {
                content
            } else {
                note("Lendo…")
            }
            if let loadError { Text(loadError).font(.collieMono(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled) }
            if let error { Text(error).font(.collieMono(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled) }
        }
        .task { refusal = await UpdateInstaller.refusal(); refusalRead = true }
        .task(id: connected) {
            await loadSettings()
            while connected, !Task.isCancelled {
                await load()
                try? await Task.sleep(for: UpdateStatus.pollInterval(status))
            }
        }
        .sheet(isPresented: $sheetOpen) {
            if let status { UpdateInstallSheet(client: client, status: status, engine: engine) { sheetOpen = false } }
        }
        .confirmationDialog(UpdateModel.rollbackLabel(previous: UpdateInstaller.previousVersion).map { $0 + "?" } ?? "", isPresented: $confirmRollback) {
            Button("Voltar e reabrir", role: .destructive) {
                do throws(AppUpdateSwap.Refusal) { try UpdateInstaller.rollback() } catch { self.error = UpdateModel.text(error) }
            }
        } message: {
            Text("O Collie fecha e reabre na versão anterior. O serviço continua rodando; os terminais não fecham.")
        }
    }

    @ViewBuilder private var content: some View {
        Text("Collie \(UpdateInstaller.installedVersion)").font(.collieMono(12)).foregroundStyle(Color.collieTextSecondary)
        if !sparkle.isEnabled {
            note("Esta é uma versão local (sem a assinatura do time): ela não se atualiza sozinha.")
        } else {
            Toggle("Procurar atualizações automaticamente", isOn: Binding(get: { sparkle.automaticChecks }, set: { sparkle.automaticChecks = $0 }))
            HStack {
                Button("Procurar agora") { sparkle.checkNow() }.buttonStyle(CollieButtonStyle(.quiet)).disabled(!sparkle.canCheck)
                Spacer()
            }
            note("O Collie baixa a nova versão, confere a assinatura e instala; se o macOS pedir a senha de administrador, ela aparece aqui. "
                 + "Com um agente trabalhando, a reabertura espera você decidir.")
        }
        if let n = UpdateModel.sourceNote(status) { note(n) }
        if let label = UpdateModel.rollbackLabel(previous: UpdateInstaller.previousVersion) {
            HStack { Spacer(); Button(label) { confirmRollback = true }.buttonStyle(CollieButtonStyle(.quiet)) }
        }
    }

    @ViewBuilder private func card(_ s: UpdateStatus, _ c: UpdateCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(c.title).font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText)
            if let page = c.page { Button(c.link) { NSWorkspace.shared.open(page) }.buttonStyle(.link) }
            if let e = UpdateModel.engineChange(manifest: s.available?.figcraftEngine, installed: engine) {
                note("Esta versão usa o motor de design \(e): o desenho fica indisponível até baixá-lo, depois de reiniciar o serviço.")
            }
            if let j = s.job, s.running, j.total > 0 {
                ProgressView(value: Double(min(j.bytes, j.total)), total: Double(j.total)).tint(Color.collieAttention)
            }
            if let p = c.progress { note(p) }
            if let e = c.error { Text(e).font(.collieMono(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled) }
            HStack(spacing: 10) {
                Spacer()
                if s.running {
                    Button { call("app.update.cancel") } label: { Text("Cancelar").foregroundStyle(Color.collieDanger) }
                        .buttonStyle(CollieButtonStyle(.quiet))
                }
                if let skip = c.skip, let v = s.available?.version {
                    Button(skip) { call("app.update.skip", ["version": .string(v)]) }.buttonStyle(CollieButtonStyle(.quiet)).disabled(working)
                }
                if let r = refusal, UpdateModel.offersDownloadPage(r) {
                    Button("Baixar o dmg") { if let page = c.page { NSWorkspace.shared.open(page) } }.buttonStyle(CollieButtonStyle(.primary))
                } else if let primary = c.primary {
                    Button(primary) { primaryAction(s) }.buttonStyle(CollieButtonStyle(.primary)).disabled(working || !connected)
                }
            }
            if let r = refusal, UpdateModel.offersDownloadPage(r) { note(UpdateModel.text(r)) }
        }
        .padding(12).background(Color.collieSurface, in: .rect(cornerRadius: 8))
    }

    /// Ready: the sheet. Else download first; the sheet opens once the dmg is verified (`installWhenReady`).
    private func primaryAction(_ s: UpdateStatus) {
        if s.state == "ready", s.staged != nil { sheetOpen = true; return }
        installWhenReady = true
        call("app.update.download")
    }

    private func load() async {
        guard connected else { return }
        do {
            guard let s = UpdateStatus.from(try await client.adminCall("app.update.status", [:])) else {
                loadError = "app.update.status: resposta inesperada"; return
            }
            status = s; loadError = nil
            if installWhenReady, s.state == "ready", s.staged != nil { installWhenReady = false; sheetOpen = true }
            if s.state == "failed" { installWhenReady = false }
            let d = (try? await client.adminCall("design.engine.status", [:])).flatMap(DesignEngineStatus.from)
            engine = d?.source == "appSupport" ? d?.installedVersion : nil
        } catch { loadError = UpdateModel.loadError(error) }
    }

    private func loadSettings() async {
        guard connected, case .object(let o)? = try? await client.adminCall("app.update.settings", [:]) else { return }
        if case .bool(let a)? = o["auto"] { auto = a }
        if case .bool(let b)? = o["download"] { background = b }
    }

    private func save(_ key: String, _ on: Bool) { call("app.update.settings", [key: .string(on ? "on" : "off")]) }

    private func check() { call("app.update.check", ["installed": .string(UpdateInstaller.installedVersion)], timeout: 90) }

    private func call(_ command: String, _ args: [String: JSONValue] = [:], timeout: Double? = nil) {
        working = true; error = nil
        Task {
            do { _ = try await client.adminCall(command, args, timeout: timeout) }
            catch { self.error = (error as? ProtocolError).map(UpdateModel.loadError) ?? "\(error)" }
            working = false
            await load()
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.collieMono(12)).foregroundStyle(Color.collieMuted).fixedSize(horizontal: false, vertical: true)
    }
}
