import Foundation
import CollieProtocol

/// `android.status`, decoded tolerantly (like `RemoteStatus.from`): nil only when `sdk`/`items` are missing.
struct AndroidSetupStatus: Equatable {
    struct Sdk: Equatable { var path: String; var source: String }
    struct Item: Equatable { var id: String; var state: String; var detail: String }
    struct Job: Equatable { var phase: String; var item: String?; var percent: Int?; var bytes: Int64?; var total: Int64?; var error: String? }
    var sdk: Sdk
    var items: [Item]
    var needs: String
    var job: Job?
    var lite: Bool

    static func from(_ v: JSONValue) -> AndroidSetupStatus? {
        guard case .object(let o) = v, case .object(let sdk)? = o["sdk"], case .array(let raw)? = o["items"] else { return nil }
        func s(_ d: [String: JSONValue], _ k: String) -> String? { if case .string(let x)? = d[k] { x } else { nil } }
        func n(_ d: [String: JSONValue], _ k: String) -> Double? { if case .number(let x)? = d[k] { x } else { nil } }
        let items = raw.compactMap { v -> Item? in
            guard case .object(let i) = v, let id = s(i, "id"), let state = s(i, "state") else { return nil }
            return Item(id: id, state: state, detail: s(i, "detail") ?? "")
        }
        var job: Job?
        if case .object(let j)? = o["job"], let phase = s(j, "phase") {
            job = Job(phase: phase, item: s(j, "item"), percent: n(j, "percent").flatMap { Int(exactly: $0.rounded()) },
                      bytes: n(j, "bytes").flatMap { Int64(exactly: $0.rounded()) }, total: n(j, "total").flatMap { Int64(exactly: $0.rounded()) }, error: s(j, "error"))
        }
        return AndroidSetupStatus(sdk: Sdk(path: s(sdk, "path") ?? "", source: s(sdk, "source") ?? ""), items: items,
                                  needs: s(o, "needs") ?? "needsPrepare", job: job, lite: o["lite"] == .bool(true))
    }
}

/// One entry of `android.licenses`.
struct AndroidLicense: Equatable, Identifiable {
    var id: String, title: String, text: String
    var accepted: Bool

    static func list(_ v: JSONValue) -> [AndroidLicense] {
        guard case .array(let a) = v else { return [] }
        return a.compactMap { v in
            guard case .object(let o) = v, case .string(let id)? = o["id"] else { return nil }
            func s(_ k: String) -> String { if case .string(let x)? = o[k] { x } else { "" } }
            return AndroidLicense(id: id, title: s("title"), text: s("text"), accepted: o["accepted"] == .bool(true))
        }
    }
}

enum AndroidScreenState: Equatable {
    case nada, parcial, preparando, licenca, instalando, pronto, erro(String), recusou, ocupado(String)

    /// Pure; fixed order: running install, busy, prepare, pending licenses, failed, items. A cancelled/done job is ignored,
    /// so the state is the one before the job. An empty license list (classic already accepted, or 23.0) never asks to accept.
    static func derive(status: AndroidSetupStatus, licenses: [AndroidLicense]?, refused: Bool, busy: String?) -> AndroidScreenState {
        let phase = status.job?.phase
        if phase == "install" { return .instalando }
        if let busy { return .ocupado(busy) }
        if phase == "prepare" { return .preparando }
        // pending licenses win over a stale `failed` (a phase 2 that died before the licenses were written): Retry would send accept [] forever
        if status.needs == "needsLicense", let licenses, licenses.contains(where: { !$0.accepted }) { return refused ? .recusou : .licenca }
        if phase == "failed" { return .erro(status.job?.error ?? "") }
        let ok = status.items.filter { $0.state == "ok" }.count
        if ok == status.items.count, status.needs == "ready" { return .pronto }
        return ok == 0 ? .nada : .parcial
    }
}

enum AndroidCopy {
    /// Mirrors `AndroidInstaller.estimates` (the app does not import the daemon kit).
    static let estimates: [String: Int64] = ["platform-tools": 15 << 20, "emulator": 400 << 20, "image": 6 << 30]
    static let termsURL = URL(string: "https://developer.android.com/studio/terms")!

    static func bytes(_ n: Int64) -> String {
        n >= 1 << 30 ? "~\(Int((Double(n) / Double(1 << 30)).rounded())) GB" : "~\(Int((Double(n) / Double(1 << 20)).rounded())) MB"
    }
    static func totalPending(_ s: AndroidSetupStatus) -> Int64 {
        s.items.filter { $0.state == "missing" }.reduce(0) { $0 + (estimates[$1.id] ?? 0) }
    }
    static func needsFree(_ s: AndroidSetupStatus) -> Int64 { 2 * totalPending(s) }

    /// The fixed notice beside Instalar (owner's decision), linked to `termsURL`.
    static let notice = "Ao instalar, você aceita os termos do Android SDK"

    /// Headline and primary button per state, from `docs/pages/preferencias-b/index.html` (`STATES` and `android(...)`).
    static func label(for s: AndroidScreenState) -> (title: String, button: String) {
        switch s {
        case .nada: ("Nada instalado", "Instalar")
        case .parcial: ("Parcial", "Instalar o que falta")
        case .preparando: ("Preparando (fase 1)", "Cancelar")
        case .licenca: ("Licenças do SDK do Android", "Aceitar e baixar")
        case .instalando: ("Instalando (fase 2)", "Cancelar")
        case .pronto: ("Tudo pronto", "Criar emulador leve")
        case .erro: ("Erro", "Tentar de novo")
        case .recusou: ("Licenças recusadas.", "Rever licenças")
        case .ocupado: ("Outro processo está usando o SDK.", "Tentar de novo")
        }
    }

    /// What `android.install` sends as `accept`: only the pending licenses, and only once the user checked the box.
    static func acceptIds(licenses: [AndroidLicense], checked: Bool) -> [String] {
        checked ? licenses.filter { !$0.accepted }.map(\.id) : []
    }
}
