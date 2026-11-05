import SwiftUI
import CoreImage.CIFilterBuiltins
import CollieTheme
import CollieCore
import CollieClient
import CollieProtocol

/// Preferências → Celular (remote API slice 10): the listener's switch and network, the paired phones (scope, Revogar),
/// Trocar certificado and Parear iPhone. Read when shown and every 3 s while shown (the live dots); no event for it.
struct CelularPreferences: View {
    let client: DaemonClient
    @State private var status: RemoteStatus?
    @State private var devices: [RemoteDeviceRow] = []
    @State private var portText = ""
    @State private var error: String?
    @State private var busy = false
    @State private var pairing: PairOffer?
    @State private var revoking: RemoteDeviceRow?
    @State private var rotating = false

    /// `status`/`devices`: what to show before the first read (previews and snapshots).
    init(client: DaemonClient, status: RemoteStatus? = nil, devices: [RemoteDeviceRow] = []) {
        self.client = client
        _status = State(initialValue: status); _devices = State(initialValue: devices); _portText = State(initialValue: status.map { "\($0.port)" } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            section("Acesso pelo iPhone") {
                Toggle("Permitir que iPhones pareados vejam e respondam os agentes", isOn: Binding(get: { status?.enabled ?? false }, set: { set(["action": .string($0 ? "on" : "off")]) }))
                    .toggleStyle(.switch).disabled(!connected || busy)
                HStack(spacing: 8) {
                    Circle().fill(status?.listening == true ? Color.collieAccent : Color.collieBorder).frame(width: 8, height: 8)
                    Text(statusLine).font(.collieMono(12)).foregroundStyle(status?.error == nil ? Color.collieTextSecondary : Color.collieDanger)
                }
                note("Desligado, nada escuta na rede. Ligado, só aceita redes locais e Tailscale, e só aparelhos pareados aqui.")
            }
            section("Rede") {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        label("Porta")
                        TextField("47820", text: $portText).frame(width: 90).onSubmit(setPort).disabled(!connected || busy)
                    }
                    GridRow {
                        label("Só Tailscale")
                        Toggle("recusa a rede local (Wi-Fi)", isOn: Binding(get: { status?.tailscaleOnly ?? false }, set: { set(["tailscale-only": .string($0 ? "on" : "off")]) }))
                            .toggleStyle(.switch).disabled(!connected || busy)
                    }
                    GridRow {
                        label("Alcançável por")
                        Text(status.map { $0.addresses.isEmpty ? "nenhum endereço de rede" : $0.addresses.map(RemoteCopy.address).joined(separator: " · ") } ?? "—")
                            .font(.collieMono(12)).foregroundStyle(Color.collieText).textSelection(.enabled)
                    }
                    GridRow {
                        label("Certificado")
                        Text(RemoteCopy.fingerprint(status?.fingerprint)).font(.collieMono(12)).foregroundStyle(Color.collieText)
                            .help(status?.fingerprint ?? "").textSelection(.enabled)
                    }
                }
            }
            section("Aparelhos") {
                if devices.isEmpty { note("Nenhum iPhone pareado.") }
                VStack(spacing: 0) {
                    ForEach(devices) { d in
                        deviceRow(d)
                        if d.id != devices.last?.id { Rectangle().fill(Color.collieBorderSoft).frame(height: 1) }
                    }
                }
                .background(Color.collieSurface, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(devices.isEmpty ? .clear : Color.collieBorder))
                HStack {
                    Button("Trocar certificado…") { rotating = true }.buttonStyle(CollieButtonStyle(.quiet)).disabled(!connected || busy || status?.fingerprint == nil)
                    Spacer()
                    Button("Parear iPhone…", action: beginPairing).buttonStyle(CollieButtonStyle(.primary)).disabled(!connected || busy)
                }
                note("Leitura: vê terminais, aprovações e Prévias, sem responder nada. Trocar certificado desconecta e exige parear de novo todos os aparelhos.")
                if let error { Text(error).font(.collieMono(12)).foregroundStyle(Color.collieDanger) }
            }
        }
        .task(id: connected) {
            while connected, !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .sheet(item: $pairing) { offer in PairSheet(offer: offer, status: status) { pairing = nil } }
        .alert("Revogar \(revoking?.name ?? "")?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button("Revogar", role: .destructive) { if let d = revoking { run("admin.remote.devices.revoke", ["id": .string(d.id)]) } }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Ele desconecta agora e precisa ser pareado de novo.") }
        .alert("Trocar o certificado do Mac?", isPresented: $rotating) {
            Button("Trocar", role: .destructive) { run("admin.remote.identity.rotate", [:]) }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Todos os aparelhos desconectam e precisam ser pareados de novo.") }
    }

    private var connected: Bool { client.state == .connected }

    private var statusLine: String {
        guard let s = status else { return "—" }
        if let e = s.error { return "Não escuta: \(e)" }
        guard s.enabled else { return "Desligado" }
        guard s.listening else { return "Ligando…" }
        let n = s.connected
        return "Escutando na porta \(s.port) · " + (n == 0 ? "nenhum aparelho conectado" : n == 1 ? "1 aparelho conectado" : "\(n) aparelhos conectados")
    }

    private func deviceRow(_ d: RemoteDeviceRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(d.live ? Color.collieAccent : Color.collieBorder).frame(width: 8, height: 8)
                    Text(d.name).font(.collieUI(13.5, .semibold)).foregroundStyle(Color.collieText)
                }
                Text([d.model, d.pairedAt.map { "pareado " + $0.formatted(.dateTime.day().month(.abbreviated)) }, RemoteCopy.seen(d)]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.collieMono(11.5)).foregroundStyle(Color.collieMuted)
            }
            Spacer()
            Picker("Escopo", selection: Binding(get: { d.readOnly }, set: { run("admin.remote.devices.scope", ["id": .string(d.id), "scope": .string($0 ? "read" : "full")]) })) {
                Text("Leitura").tag(true); Text("Completo").tag(false)
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize().disabled(!connected || busy)
            Button { revoking = d } label: { Text("Revogar").foregroundStyle(Color.collieDanger) }
                .buttonStyle(CollieButtonStyle(.quiet)).disabled(!connected || busy)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func load() async {
        guard connected else { return }
        if let r = try? await client.adminCall("admin.remote", [:]), let s = RemoteStatus.from(r) {
            if status?.port != s.port || portText.isEmpty { portText = "\(s.port)" }
            status = s
        }
        if let r = try? await client.adminCall("admin.remote.devices", [:]) { devices = RemoteDeviceRow.rows(r) }
    }

    private func set(_ args: [String: JSONValue]) {
        busy = true; error = nil
        Task {
            do { status = RemoteStatus.from(try await client.adminCall("admin.remote", args)) ?? status } catch { self.error = (error as? ProtocolError)?.message ?? "\(error)" }
            busy = false
        }
    }

    private func setPort() {
        guard let p = Int(portText.trimmingCharacters(in: .whitespaces)), p != status?.port else { return }
        set(["port": .number(Double(p))])
    }

    private func run(_ command: String, _ args: [String: JSONValue]) {
        busy = true; error = nil
        Task {
            do { _ = try await client.adminCall(command, args) } catch { self.error = (error as? ProtocolError)?.message ?? "\(error)" }
            busy = false
            await load()
        }
    }

    /// Turns the listener on when it is off (pair.begin refuses then), then shows the QR.
    private func beginPairing() {
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                if status?.listening != true { status = RemoteStatus.from(try await client.adminCall("admin.remote", ["action": .string("on")])) ?? status }
                guard let o = PairOffer.from(try await client.adminCall("admin.remote.pair.begin", [:])) else { return }
                pairing = o
            } catch { self.error = (error as? ProtocolError)?.message ?? "\(error)" }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.collieUI(14, .semibold)).foregroundStyle(Color.collieText)
            content()
        }
    }
    private func label(_ s: String) -> some View { Text(s).font(.collieUI(13)).foregroundStyle(Color.collieTextSecondary) }
    private func note(_ s: String) -> some View { Text(s).font(.collieMono(12)).foregroundStyle(Color.collieMuted).fixedSize(horizontal: false, vertical: true) }
}

/// The pairing confirmation, over the main window wherever the app is (a phone read the QR).
struct PairingConfirmHost: ViewModifier {
    let client: DaemonClient
    func body(content: Content) -> some View {
        content.background(Color.clear.sheet(item: Binding(get: { client.remotePairing },
                                                           set: { if $0 == nil, let r = client.remotePairing { client.clearRemotePairing(r.pairingId) } })) { r in
            PairingConfirmSheet(request: r) { accept in
                client.clearRemotePairing(r.pairingId)
                let args: [String: JSONValue] = ["pairingId": .string(r.pairingId.uuidString.lowercased()), "decision": .string(accept ? "accept" : "refuse")]
                Task { _ = try? await client.adminCall("admin.remote.pair.confirm", args) }
            }
        })
    }
}

/// `admin.remote.pair.begin`'s reply.
struct PairOffer: Identifiable, Equatable {
    var id: String, qr: String, expiresAt: Date
    static func from(_ v: JSONValue) -> PairOffer? {
        guard case .object(let o) = v, case .string(let id)? = o["pairingId"], case .string(let qr)? = o["qr"],
              case .string(let e)? = o["expiresAt"], let at = ISO8601DateFormatter().date(from: e) else { return nil }
        return PairOffer(id: id, qr: qr, expiresAt: at)
    }
}

/// The QR to scan (the pairing URL), its countdown and where the Mac is reachable. Closes itself on expiry.
struct PairSheet: View {
    let offer: PairOffer
    let status: RemoteStatus?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Parear iPhone").font(.collieUI(16, .semibold)).foregroundStyle(Color.collieText)
            Text("No iPhone, abra o Collie e escaneie. O código vale uma vez.").font(.collieUI(13)).foregroundStyle(Color.collieTextSecondary)
            if let img = QRCode.image(offer.qr) {
                Image(nsImage: img).interpolation(.none).resizable().frame(width: 196, height: 196)
                    .padding(12).background(.white, in: .rect(cornerRadius: 10))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .accessibilityLabel("Código QR para parear")
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, Int(offer.expiresAt.timeIntervalSince(ctx.date)))
                Text((left > 0 ? String(format: "Expira em %d:%02d", left / 60, left % 60) : "Expirou: gere outro")
                     + (status?.addresses.isEmpty == false ? " · " + status!.addresses.map(RemoteCopy.address).joined(separator: " · ") : ""))
                    .font(.collieMono(12)).foregroundStyle(Color.collieMuted).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .onChange(of: left == 0) { _, gone in if gone { close() } }
            }
            HStack { Spacer(); Button("Cancelar", action: close).buttonStyle(CollieButtonStyle(.secondary)).keyboardShortcut(.cancelAction) }
                .padding(.top, 14)
        }
        .padding(22).frame(width: 400).background(Color.collieBackground)
    }
}

/// A phone read the QR and waits for this click: its name, model and where it connects from, and the code it shows.
/// 60 s (the daemon refuses after it); Recusar is the default.
struct PairingConfirmSheet: View {
    let request: RemotePairingRequest
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Parear “\(request.name)”?").font(.collieUI(16, .semibold)).foregroundStyle(Color.collieText)
            Text("\(request.model) · \(RemoteCopy.via(request.via)) \(request.address)").font(.collieUI(13)).foregroundStyle(Color.collieTextSecondary)
            Text(RemoteCopy.code(request.code)).font(.collieMono(34, .medium)).tracking(4).foregroundStyle(Color.collieAccent)
                .frame(maxWidth: .infinity).padding(.top, 16).padding(.bottom, 6)
                .accessibilityLabel("Código \(request.code.map(String.init).joined(separator: " "))")
            Text("Confira se o iPhone mostra o mesmo código.").font(.collieMono(12)).foregroundStyle(Color.collieMuted).frame(maxWidth: .infinity)
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let left = max(0, request.deadline.timeIntervalSince(ctx.date))
                GeometryReader { g in   // the 60 s running out
                    Capsule().fill(Color.collieBorder)
                        .overlay(alignment: .leading) { Capsule().fill(Color.collieAttention).frame(width: g.size.width * min(1, left / 60)) }
                }
                .frame(height: 3).padding(.top, 14)
                .onChange(of: left == 0) { _, gone in if gone { answer(false) } }
            }
            HStack {
                Spacer()
                Button("Recusar") { answer(false) }.buttonStyle(CollieButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                Button("Parear") { answer(true) }.buttonStyle(CollieButtonStyle(.primary))
            }
            .padding(.top, 14)
        }
        .padding(22).frame(width: 400).background(Color.collieBackground)
    }
}

extension RemotePairingRequest: Identifiable { public var id: UUID { pairingId } }

/// A QR image (CoreImage, error correction M), sharp at any size with `.interpolation(.none)`.
enum QRCode {
    static func image(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8); f.correctionLevel = "M"
        // 10 px a module already: shown at ~196 pt it is only scaled down (never blurred up)
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: out.extent.width, height: out.extent.height))
    }
}
