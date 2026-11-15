import SwiftUI
import CollieTheme
import CollieClient
import CollieProtocol

/// Preferências → Android: installs the SDK (phase 1 Java + cmdline-tools, licenses, phase 2), and creates `collie-lite`.
/// Draws `AndroidScreenState.derive`; reads `android.status` every 1 s while a job runs, 3 s otherwise, while shown and
/// connected. The job lives in the daemon: leaving the page only stops the reads.
struct AndroidPreferences: View {
    let client: DaemonClient
    @State private var status: AndroidSetupStatus?
    @State private var licenses: [AndroidLicense]?
    @State private var licensesFailed = false
    @State private var checked = false
    @State private var refused = false
    @State private var busyMessage: String?
    @State private var error: String?
    @State private var loadError: String?
    @State private var working = false

    /// `status`/`licenses`: what to show before the first read (previews and snapshots).
    init(client: DaemonClient, status: AndroidSetupStatus? = nil, licenses: [AndroidLicense]? = nil) {
        self.client = client
        _status = State(initialValue: status); _licenses = State(initialValue: licenses)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !connected { Text("Sem conexão com o daemon. O que aparece abaixo pode estar desatualizado.").font(.collieMono(12)).foregroundStyle(Color.collieDanger) }
            if let s = status {
                Group {
                    sdkSection(s)
                    setupSection(s, state)
                    liteSection(s, ready: state == .pronto)
                }
                .opacity(connected ? 1 : 0.5)
                note("Tamanhos com “~” são estimados.")
            } else {
                note(connected ? "Lendo o estado do Android…" : "—")
            }
            if let loadError { Text(loadError).font(.collieMono(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled) }
            if let error { Text(error).font(.collieMono(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled) }
        }
        .task(id: connected) {
            // a stale "ocupado" must not outlive the page/connection; a polling clear would hide the banner within 3 s of showing it
            if !running { busyMessage = nil }
            while connected, !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(running ? 1 : 3))
            }
        }
        .task(id: wantsLicenses) { if wantsLicenses { await loadLicenses() } }
        .onChange(of: status?.needs) { _, needs in
            if needs != "needsLicense" { licenses = nil; licensesFailed = false; checked = false; refused = false }
        }
    }

    // MARK: state

    private var connected: Bool { client.state == .connected }
    private var running: Bool { ["prepare", "install"].contains(status?.job?.phase ?? "") }
    private var state: AndroidScreenState {
        status.map { AndroidScreenState.derive(status: $0, licenses: licenses, refused: refused, busy: busyMessage) } ?? .nada
    }
    /// `android.licenses` is read once on entering `needsLicense` (it runs `sdkmanager`, up to 300 s), never during a job.
    private var wantsLicenses: Bool { connected && status?.needs == "needsLicense" && !running && licenses == nil && !licensesFailed }
    private var readingLicenses: Bool { status?.needs == "needsLicense" && licenses == nil }
    private var enabled: Bool { connected && !working }

    // MARK: sections

    private func sdkSection(_ s: AndroidSetupStatus) -> some View {
        let none = s.sdk.source == "collie" && s.items.allSatisfy { $0.state != "ok" }
        return section("SDK em uso") {
            Text(none ? "Será criado em \(s.sdk.path)" : s.sdk.path).font(.collieMono(12)).foregroundStyle(Color.collieText)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 8) {
                badge(none ? "Nenhum SDK encontrado" : Self.source(s.sdk.source))
                Spacer()
                Button("Ver na pasta") { NSWorkspace.shared.open(URL(fileURLWithPath: s.sdk.path)) }
                    .buttonStyle(CollieButtonStyle(.quiet)).disabled(none)
            }
        }
    }

    private func setupSection(_ s: AndroidSetupStatus, _ st: AndroidScreenState) -> some View {
        var label = AndroidCopy.label(for: st)
        if Self.readingLicensesJob(s, st) { label.title = "Lendo as licenças…" }
        return section(label.title) {
            VStack(alignment: .leading, spacing: 0) {
                phaseHeader("Fase 1 · Preparar", "começa ao clicar em Instalar")
                ForEach(s.items.filter { Self.phase1.contains($0.id) }, id: \.id) { row($0, s) }
                Rectangle().fill(Color.collieBorderSoft).frame(height: 1)
                phaseHeader("Fase 2 · Instalar", "só depois de você aceitar as licenças")
                ForEach(s.items.filter { !Self.phase1.contains($0.id) }, id: \.id) { row($0, s) }
            }
            .background(Color.collieSurface, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.collieBorder))
            if st != .pronto {
                note("A baixar \(AndroidCopy.bytes(AndroidCopy.totalPending(s))) (estimado) · Espaço livre necessário \(AndroidCopy.bytes(AndroidCopy.needsFree(s))) (2× a soma)")
            }
            actions(s, st, label.button)
            // outside the switch: every state whose Install waits on the read (nada, parcial, erro) can retry it
            if readingLicenses && !running {
                if licensesFailed {
                    HStack {
                        note("Não deu para ler as licenças.")
                        Button("Ler de novo") { error = nil; licensesFailed = false }.buttonStyle(CollieButtonStyle(.quiet)).disabled(!enabled)
                    }
                } else { note("Lendo licenças…") }
            }
        }
    }

    @ViewBuilder
    private func actions(_ s: AndroidSetupStatus, _ st: AndroidScreenState, _ button: String) -> some View {
        switch st {
        case .nada, .parcial:
            HStack(spacing: 12) {
                Button(button, action: install).buttonStyle(CollieButtonStyle(.primary)).disabled(!enabled || readingLicenses)
                termsNotice
            }
        case .preparando, .instalando:
            HStack(spacing: 12) {
                Button { run("android.cancel") } label: { Text(button).foregroundStyle(Color.collieDanger) }
                    .buttonStyle(CollieButtonStyle(.quiet)).disabled(!enabled)
                note(Self.readingLicensesJob(s, st) ? "Lendo as licenças do SDK. Nada foi baixado ainda." : st == .preparando
                     ? "Fase 1: baixando \(s.items.contains { $0.id == "java" && $0.state != "ok" } ? "o JDK Temurin e o Command-line Tools" : "o Command-line Tools"). Sem licença do SDK até aqui."
                     : "Fase 2: baixando \(s.job?.item.map(Self.name) ?? "os pacotes"). Continua em segundo plano.")
            }
        case .licenca:
            licenseBlock(s, button)
        case .recusou:
            banner(Color.collieAttention) {
                Text("A fase 2 não rodou: nada do SDK foi baixado além do que a fase 1 trouxe.").font(.collieUI(13)).foregroundStyle(Color.collieText)
                Button(button) { refused = false; checked = false }.buttonStyle(CollieButtonStyle(.primary)).disabled(!enabled)
            }
        case .erro(let message):
            banner(Color.collieDanger) {
                Text("Não deu para instalar. O que já foi baixado fica guardado.").font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText)
                if !message.isEmpty { Text(message).font(.collieMono(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled) }
                Button(button, action: install).buttonStyle(CollieButtonStyle(.primary)).disabled(!enabled || readingLicenses)
            }
        case .ocupado(let message):
            banner(Color.collieAttention) {
                Text("Feche o Android Studio ou espere o outro sdkmanager terminar.").font(.collieUI(13)).foregroundStyle(Color.collieText)
                Text(message.hasPrefix("busy: ") ? String(message.dropFirst(6)) : message).font(.collieMono(12)).foregroundStyle(Color.collieMuted).textSelection(.enabled)
                Button(button) { busyMessage = nil; install() }.buttonStyle(CollieButtonStyle(.primary)).disabled(!enabled)
            }
        case .pronto:
            HStack(spacing: 12) {
                badge("Tudo pronto")
                note("Java, ferramentas, emulador e imagem instalados.")
            }
        }
    }

    /// Only the pending licenses (an accepted one is never asked again); Recusar stays on this side and calls nothing.
    private func licenseBlock(_ s: AndroidSetupStatus, _ button: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if s.job?.phase == "failed", let e = s.job?.error, !e.isEmpty { Text(e).font(.collieMono(12)).foregroundStyle(Color.collieDanger).textSelection(.enabled) }
            note("Obrigatório aceitar para a fase 2 (\(AndroidCopy.bytes(AndroidCopy.totalPending(s)))). Nada da fase 2 é baixado antes disso.")
            ForEach((licenses ?? []).filter { !$0.accepted }) { l in
                VStack(alignment: .leading, spacing: 4) {
                    Text(l.title).font(.collieUI(13, .semibold)).foregroundStyle(Color.collieText)
                    Text(l.id).font(.collieMono(11.5)).foregroundStyle(Color.collieMuted).textSelection(.enabled)
                    ScrollView {
                        Text(l.text).font(.collieMono(11.5)).foregroundStyle(Color.collieTextSecondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
                .padding(12).background(Color.collieSurface, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.collieBorder))
            }
            Toggle("Li e aceito as licenças do Google", isOn: $checked).toggleStyle(.checkbox).font(.collieUI(13)).disabled(!enabled)
            HStack {
                Button("Recusar") { refused = true; checked = false }.buttonStyle(CollieButtonStyle(.quiet)).disabled(!enabled)
                Button(button, action: install).buttonStyle(CollieButtonStyle(.primary)).disabled(!enabled || !checked)
            }
        }
    }

    private func liteSection(_ s: AndroidSetupStatus, ready: Bool) -> some View {
        section("Emulador") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.lite ? "collie-lite" : "Emulador leve (collie-lite)").font(.collieUI(13.5, .semibold)).foregroundStyle(Color.collieText)
                    Text("720×1280 · 1,5 GB de RAM · 2 núcleos · GPU do host").font(.collieMono(11.5)).foregroundStyle(Color.collieMuted)
                    if !s.lite && !ready { note("Disponível quando tudo estiver instalado.") }
                }
                Spacer()
                if s.lite {
                    Button { run("device.lite.remove") } label: { Text("Remover").foregroundStyle(Color.collieDanger) }
                        .buttonStyle(CollieButtonStyle(.quiet)).disabled(!enabled)
                } else {
                    Button("Criar emulador leve") { run("device.lite.create", timeout: 300) }
                        .buttonStyle(CollieButtonStyle(.primary)).disabled(!enabled || !ready)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color.collieSurface, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.collieBorder))
        }
    }

    private func row(_ i: AndroidSetupStatus.Item, _ s: AndroidSetupStatus) -> some View {
        // progress only while connected: a job read before the connection fell is not shown as current
        let job = connected && running && s.job?.item == i.id ? s.job : nil
        let failed = s.job?.phase == "failed" && s.job?.item == i.id
        let right = Self.progress(i, job: job, failed: failed)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Circle().fill(i.state == "ok" ? Color.collieAccent : failed ? Color.collieDanger : job != nil ? Color.collieAttention : Color.collieBorder)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.name(i.id)).font(.collieUI(13, .medium)).foregroundStyle(Color.collieText)
                    Text([Self.about[i.id], i.detail.isEmpty ? nil : i.detail].compactMap { $0 }.joined(separator: " · "))
                        .font(.collieMono(11.5)).foregroundStyle(Color.collieMuted).lineLimit(2)
                }
                Spacer()
                Text(right).font(.collieMono(12)).foregroundStyle(failed ? Color.collieDanger : Color.collieTextSecondary)
            }
            if let p = job?.percent { ProgressView(value: Double(min(max(p, 0), 100)), total: 100).tint(Color.collieAttention) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var termsNotice: some View {
        HStack(spacing: 4) {
            Text(AndroidCopy.notice).font(.collieMono(12)).foregroundStyle(Color.collieMuted)
            Link("(ler)", destination: AndroidCopy.termsURL).font(.collieMono(12))
        }
    }

    // MARK: daemon

    private func load() async {
        guard connected else { return }
        do {
            guard let s = AndroidSetupStatus.from(try await client.adminCall("android.status", [:])) else { loadError = "android.status: resposta inesperada"; return }
            status = s; loadError = nil
        } catch { loadError = error.message }
    }

    private func loadLicenses() async {
        do {
            let r = try await client.adminCall("android.licenses", [:], timeout: 300)
            if !Task.isCancelled { licenses = AndroidLicense.list(r) }
        } catch {
            guard !Task.isCancelled else { return }
            licensesFailed = true; self.error = error.message
        }
    }

    /// `accept`: only what the user checked (`AndroidCopy.acceptIds`), empty when there is nothing to accept.
    private func install() {
        let ids = AndroidCopy.acceptIds(licenses: licenses ?? [], checked: checked)
        run("android.install", ["accept": .array(ids.map { .string($0) })])
    }

    private func run(_ command: String, _ args: [String: JSONValue] = [:], timeout: Double? = nil) {
        working = true; error = nil
        Task {
            do { _ = try await client.adminCall(command, args, timeout: timeout) } catch {
                let m = (error as? ProtocolError)?.message ?? "\(error)"
                if command == "android.install", m.hasPrefix("busy:") { busyMessage = m } else { self.error = m }
            }
            working = false
            await load()
        }
    }

    // MARK: copy and helpers

    /// Phase 1 done, the daemon is reading the licenses (up to 300 s): an install job with no item yet.
    private static func readingLicensesJob(_ s: AndroidSetupStatus, _ st: AndroidScreenState) -> Bool { st == .instalando && s.job?.item == nil }
    private static let phase1: Set<String> = ["java", "cmdline-tools"]
    private static let names = ["java": "Java (JDK)", "cmdline-tools": "Command-line Tools", "platform-tools": "Platform-tools",
                                "emulator": "Emulator", "image": "Imagem de sistema"]
    private static let about = ["java": "JDK 17 ou maior, para o sdkmanager", "cmdline-tools": "sdkmanager e avdmanager",
                                "platform-tools": "adb e fastboot", "emulator": "emulador do Android", "image": "google_apis · arm64-v8a"]
    private static func name(_ id: String) -> String { names[id] ?? id }
    /// The right side of an item row: OK, falhou, the running job's percent of its size, or ausente with the estimate.
    private static func progress(_ i: AndroidSetupStatus.Item, job: AndroidSetupStatus.Job?, failed: Bool) -> String {
        let estimate: String? = AndroidCopy.estimates[i.id].map { AndroidCopy.bytes($0) }
        if i.state == "ok" { return "OK" }
        if failed { return "falhou" }
        if let job {
            let size: String? = job.total.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? estimate
            return (job.percent.map { "\($0)%" } ?? "baixando") + (size.map { " de " + $0 } ?? "")
        }
        if i.state == "installing" { return "instalando" }
        return "ausente" + (estimate.map { " · " + $0 } ?? "")
    }
    private static func source(_ s: String) -> String {
        switch s {
        case "studio": "SDK do Android Studio (reaproveitado)"
        case "collie": "SDK do Collie"
        case "env": "COLLIE_ANDROID_SDK"
        case "android-home": "ANDROID_HOME"
        case "android-sdk-root": "ANDROID_SDK_ROOT"
        default: s
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText)
            content()
        }
    }
    private func phaseHeader(_ title: String, _ hint: String) -> some View {
        HStack {
            Text(title).font(.collieUI(12.5, .semibold)).foregroundStyle(Color.collieTextSecondary)
            Spacer()
            Text(hint).font(.collieMono(11.5)).foregroundStyle(Color.collieMuted)
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 2)
    }
    private func banner<C: View>(_ tint: Color, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint))
    }
    private func badge(_ s: String) -> some View {
        Text(s).font(.collieMono(11.5)).foregroundStyle(Color.collieTextSecondary)
            .padding(.horizontal, 8).padding(.vertical, 3).background(Color.collieSunken, in: .capsule)
    }
    private func note(_ s: String) -> some View { Text(s).font(.collieMono(12)).foregroundStyle(Color.collieMuted).fixedSize(horizontal: false, vertical: true) }
}
