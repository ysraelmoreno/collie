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
            section(tr("Acesso pelo iPhone", "iPhone access")) {
                Toggle(tr("Permitir que iPhones pareados vejam e respondam os agentes", "Allow paired iPhones to see and answer the agents"), isOn: Binding(get: { status?.enabled ?? false }, set: { set(["action": .string($0 ? "on" : "off")]) }))
                    .toggleStyle(.switch).disabled(!connected || busy)
                HStack(spacing: 8) {
                    Circle().fill(status?.listening == true ? Color.collieAccent : Color.collieBorder).frame(width: 8, height: 8)
                    Text(statusLine).font(.collieMono(12)).foregroundStyle(status?.error == nil ? Color.collieTextSecondary : Color.collieDanger)
                }
                note(tr("Desligado, nada escuta na rede. Ligado, só aceita redes locais e Tailscale, e só aparelhos pareados aqui.", "Off, nothing listens on the network. On, it only accepts local networks and Tailscale, and only devices paired here."))
            }
            section(tr("Rede", "Network")) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        label(tr("Porta", "Port"))
                        TextField("47820", text: $portText).frame(width: 90).onSubmit(setPort).disabled(!connected || busy)
                    }
                    GridRow {
                        label(tr("Só Tailscale", "Tailscale only"))
                        Toggle(tr("recusa a rede local (Wi-Fi)", "refuses the local network (Wi-Fi)"), isOn: Binding(get: { status?.tailscaleOnly ?? false }, set: { set(["tailscale-only": .string($0 ? "on" : "off")]) }))
                            .toggleStyle(.switch).disabled(!connected || busy)
                    }
                    GridRow {
                        label(tr("Alcançável por", "Reachable at"))
                        Text(status.map { $0.addresses.isEmpty ? tr("nenhum endereço de rede", "no network address") : $0.addresses.map(RemoteCopy.address).joined(separator: " · ") } ?? "—")
                            .font(.collieMono(12)).foregroundStyle(Color.collieText).textSelection(.enabled)
                    }
                    GridRow {
                        label(tr("Certificado", "Certificate"))
                        Text(RemoteCopy.fingerprint(status?.fingerprint)).font(.collieMono(12)).foregroundStyle(Color.collieText)
                            .help(status?.fingerprint ?? "").textSelection(.enabled)
                    }
                }
            }
            section(tr("Aparelhos", "Devices")) {
                if devices.isEmpty { note(tr("Nenhum iPhone pareado.", "No paired iPhone.")) }
                VStack(spacing: 0) {
                    ForEach(devices) { d in
                        deviceRow(d)
                        if d.id != devices.last?.id { Rectangle().fill(Color.collieBorderSoft).frame(height: 1) }
                    }
                }
                .background(Color.collieSurface, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(devices.isEmpty ? .clear : Color.collieBorder))
                HStack {
                    Button(tr("Trocar certificado…", "Rotate certificate…")) { rotating = true }.buttonStyle(CollieButtonStyle(.quiet)).disabled(!connected || busy || status?.fingerprint == nil)
                    Spacer()
                    Button(tr("Parear iPhone…", "Pair iPhone…"), action: beginPairing).buttonStyle(CollieButtonStyle(.primary)).disabled(!connected || busy)
                }
                note(tr("Leitura: vê terminais, aprovações e Prévias, sem responder nada. Trocar certificado desconecta e exige parear de novo todos os aparelhos.", "Read: sees terminals, approvals and Previews, answers nothing. Rotating the certificate disconnects and requires pairing every device again."))
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
        .alert(tr("Revogar \(revoking?.name ?? "")?", "Revoke \(revoking?.name ?? "")?"), isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button(tr("Revogar", "Revoke"), role: .destructive) { if let d = revoking { run("admin.remote.devices.revoke", ["id": .string(d.id)]) } }
            Button(tr("Cancelar", "Cancel"), role: .cancel) {}
        } message: { Text(tr("Ele desconecta agora e precisa ser pareado de novo.", "It disconnects now and must be paired again.")) }
        .alert(tr("Trocar o certificado do Mac?", "Rotate the Mac's certificate?"), isPresented: $rotating) {
            Button(tr("Trocar", "Rotate"), role: .destructive) { run("admin.remote.identity.rotate", [:]) }
            Button(tr("Cancelar", "Cancel"), role: .cancel) {}
        } message: { Text(tr("Todos os aparelhos desconectam e precisam ser pareados de novo.", "All devices disconnect and must be paired again.")) }
    }

    private var connected: Bool { client.state == .connected }

    private var statusLine: String {
        guard let s = status else { return "—" }
        if let e = s.error { return tr("Não escuta: \(e)", "Not listening: \(e)") }
        guard s.enabled else { return tr("Desligado", "Off") }
        guard s.listening else { return tr("Ligando…", "Starting…") }
        let n = s.connected, p = s.port
        return n == 0 ? tr("Escutando na porta \(p) · nenhum aparelho conectado", "Listening on port \(p) · no device connected")
            : n == 1 ? tr("Escutando na porta \(p) · 1 aparelho conectado", "Listening on port \(p) · 1 device connected")
            : tr("Escutando na porta \(p) · \(n) aparelhos conectados", "Listening on port \(p) · \(n) devices connected")
    }

    private func deviceRow(_ d: RemoteDeviceRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Circle().fill(d.live ? Color.collieAccent : Color.collieBorder).frame(width: 8, height: 8)
                    Text(d.name).font(.collieUI(13.5, .semibold)).foregroundStyle(Color.collieText)
                }
                Text([d.model, d.pairedAt.map { let day = $0.formatted(.dateTime.day().month(.abbreviated)); return tr("pareado \(day)", "paired \(day)") }, RemoteCopy.seen(d)]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.collieMono(11.5)).foregroundStyle(Color.collieMuted)
            }
            Spacer()
            Picker(tr("Escopo", "Scope"), selection: Binding(get: { d.readOnly }, set: { run("admin.remote.devices.scope", ["id": .string(d.id), "scope": .string($0 ? "read" : "full")]) })) {
                Text(tr("Leitura", "Read")).tag(true); Text(tr("Completo", "Full")).tag(false)
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize().disabled(!connected || busy)
            Button { revoking = d } label: { Text(tr("Revogar", "Revoke")).foregroundStyle(Color.collieDanger) }
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
            Text(tr("Parear iPhone", "Pair iPhone")).font(.collieUI(16, .semibold)).foregroundStyle(Color.collieText)
            Text(tr("No iPhone, abra o Collie e escaneie. O código vale uma vez.", "On the iPhone, open Collie and scan. The code works once.")).font(.collieUI(13)).foregroundStyle(Color.collieTextSecondary)
            if let img = QRCode.image(offer.qr) {
                Image(nsImage: img).interpolation(.none).resizable().frame(width: 196, height: 196)
                    .padding(12).background(.white, in: .rect(cornerRadius: 10))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .accessibilityLabel(tr("Código QR para parear", "QR code to pair"))
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, Int(offer.expiresAt.timeIntervalSince(ctx.date)))
                Text((left > 0 ? String(format: tr("Expira em %d:%02d", "Expires in %d:%02d"), left / 60, left % 60) : tr("Expirou: gere outro", "Expired: generate another"))
                     + (status?.addresses.isEmpty == false ? " · " + status!.addresses.map(RemoteCopy.address).joined(separator: " · ") : ""))
                    .font(.collieMono(12)).foregroundStyle(Color.collieMuted).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .onChange(of: left == 0) { _, gone in if gone { close() } }
            }
            HStack { Spacer(); Button(tr("Cancelar", "Cancel"), action: close).buttonStyle(CollieButtonStyle(.secondary)).keyboardShortcut(.cancelAction) }
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
            Text(tr("Parear “\(request.name)”?", "Pair “\(request.name)”?")).font(.collieUI(16, .semibold)).foregroundStyle(Color.collieText)
            Text("\(request.model) · \(RemoteCopy.via(request.via)) \(request.address)").font(.collieUI(13)).foregroundStyle(Color.collieTextSecondary)
            Text(RemoteCopy.code(request.code)).font(.collieMono(34, .medium)).tracking(4).foregroundStyle(Color.collieAccent)
                .frame(maxWidth: .infinity).padding(.top, 16).padding(.bottom, 6)
                .accessibilityLabel(tr("Código \(request.code.map(String.init).joined(separator: " "))", "Code \(request.code.map(String.init).joined(separator: " "))"))
            Text(tr("Confira se o iPhone mostra o mesmo código.", "Check that the iPhone shows the same code.")).font(.collieMono(12)).foregroundStyle(Color.collieMuted).frame(maxWidth: .infinity)
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
                Button(tr("Recusar", "Decline")) { answer(false) }.buttonStyle(CollieButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                Button(tr("Parear", "Pair")) { answer(true) }.buttonStyle(CollieButtonStyle(.primary))
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
