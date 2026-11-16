import Foundation
import CollieProtocol

/// `design.engine.status`, decoded tolerantly (like `AndroidSetupStatus.from`): nil only when `state` is missing.
struct DesignEngineStatus: Equatable {
    struct Job: Equatable { var phase: String; var bytes: Int64 = 0; var total: Int64 = 0; var error: String? }
    var state: String
    var installedVersion: String?
    var source: String?
    var reinstall = false
    var pinnedVersion: String?
    var pinnedSize: Int64?
    var job: Job?

    static let runningPhases: Set<String> = ["downloading", "verifying", "installing"]
    var running: Bool { job.map { Self.runningPhases.contains($0.phase) } ?? false }

    static func from(_ v: JSONValue) -> DesignEngineStatus? {
        guard case .object(let o) = v, case .string(let state)? = o["state"] else { return nil }
        func s(_ d: [String: JSONValue]?, _ k: String) -> String? { if case .string(let x)? = d?[k] { x } else { nil } }
        func n(_ d: [String: JSONValue]?, _ k: String) -> Int64? { if case .number(let x)? = d?[k] { Int64(exactly: x.rounded()) } else { nil } }
        func obj(_ k: String) -> [String: JSONValue]? { if case .object(let x)? = o[k] { x } else { nil } }
        let installed = obj("installed"), pinned = obj("pinned"), job = obj("job")
        return DesignEngineStatus(
            state: state, installedVersion: s(installed, "version"), source: s(installed, "source"),
            reinstall: o["reinstall"] == .bool(true), pinnedVersion: s(pinned, "version"), pinnedSize: n(pinned, "size"),
            job: s(job, "phase").map { Job(phase: $0, bytes: n(job, "bytes") ?? 0, total: n(job, "total") ?? 0, error: s(job, "error")) })
    }

    /// Fixed order: a running job, a failed one (unless an engine runs), then the engine's state. A done or cancelled job
    /// is history. Sizes in decimal MB (`ByteCountFormatter` `.file`).
    static func row(_ s: DesignEngineStatus, locale: Locale = .current) -> DesignEngineRow {
        func size(_ n: Int64) -> String { n.formatted(.byteCount(style: .file).locale(locale)) }
        let download = s.pinnedSize.map(size) ?? ""
        switch s.job?.phase {
        case "downloading": return .downloading(done: size(s.job!.bytes), total: size(s.job!.total))
        case "verifying", "installing": return .verifying
        case "failed" where s.state != "installed": return .failed(s.job?.error ?? "")
        default: break
        }
        switch s.state {
        case "installed": return .installed(version: s.installedVersion ?? "", bundled: s.source != "appSupport")
        case "needsUpdate": return .needsUpdate(installed: s.installedVersion, pinned: s.pinnedVersion ?? "", download: download, reinstall: s.reinstall)
        default: return .absent(download: download)
        }
    }

    static func pollInterval(_ s: DesignEngineStatus?) -> Duration { s?.running == true ? .seconds(1) : .seconds(3) }
}

/// One line of the "Motor de design" section (spec §7) and its copy.
enum DesignEngineRow: Equatable {
    case absent(download: String)
    case downloading(done: String, total: String)
    case verifying
    /// `bundled`: not in Application Support (bundle, `COLLIE_FIGCRAFT_DIR`, vendor), so nothing to remove.
    case installed(version: String, bundled: Bool)
    case needsUpdate(installed: String?, pinned: String, download: String, reinstall: Bool)
    case failed(String)

    var text: String {
        switch self {
        case .absent: "Necessário para o painel Design e collie design."
        case .downloading(let done, let total): "\(done) de \(total)"
        case .verifying: "Conferindo assinatura…"
        case .installed(let v, let bundled): (v.isEmpty ? "" : "v\(v) · ") + (bundled ? "embutido no app" : "Application Support")
        case .needsUpdate(let i, let p, _, false):
            "Motor \(i.map { "v" + $0 } ?? "instalado") desatualizado: este Collie usa v\(p). O painel Design fica indisponível até atualizar."
        case .needsUpdate(let i, let p, _, true): "Motor \(i.map { "v" + $0 } ?? "instalado") não é o deste Collie (v\(p))."
        case .failed(let m): "Falhou: \(m)"
        }
    }

    /// The primary button; nil while a job runs (Cancelar is the view's) or when an engine runs.
    var button: String? {
        func sized(_ b: String, _ d: String) -> String { d.isEmpty ? b : "\(b) (\(d))" }
        switch self {
        case .absent(let d): return sized("Baixar", d)
        case .needsUpdate(_, _, let d, let reinstall): return sized(reinstall ? "Reinstalar" : "Atualizar", d)
        case .failed: return "Tentar de novo"
        case .downloading, .verifying, .installed: return nil
        }
    }

    var canRemove: Bool {
        switch self {
        case .installed(_, let bundled): !bundled
        case .needsUpdate: true
        default: false
        }
    }
}
