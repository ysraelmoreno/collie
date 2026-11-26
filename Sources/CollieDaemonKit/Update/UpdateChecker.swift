import Foundation
import CollieCore
import CollieProtocol

/// One GET written to `to`, at most `limit` bytes (nil: no cap). The daemon's is `AndroidDownload.fetch` with the
/// updater's User-Agent; tests inject a fake.
typealias UpdateFetch = @Sendable (_ url: URL, _ to: URL, _ limit: Int64?, _ progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> Void

/// Preferences › Atualizações, in `preferences.json` (`updates`); nil: on.
struct UpdateSettings: Codable, Equatable, Sendable {
    var auto: Bool?
    var download: Bool?
}

/// The app updater's daemon side (spec 2026-11-17 §1, §2, §4.1): reads `update.json`, offers a newer version, downloads
/// its dmg into `<root>/.update-staging` (0700, closed to terminals) and checks the sha256 and the notarized team
/// signature. Mounting, copying and swapping the app are the app's (`AppUpdateSwap`). A sha256 that failed the check
/// (mismatch or signature) is never downloaded again (`refused.json`); a 404, a network error or a cancel is retried at
/// the next check. A `file://` manifest (the `COLLIE_UPDATE_MANIFEST` test source) is read from disk with its dmg next
/// to it, never through the network fetch.
actor UpdateChecker {
    struct Job: Codable, Sendable, Equatable {
        /// downloading | verifying | ready | failed | cancelled
        var phase: String
        var bytes: Int64 = 0
        var total: Int64 = 0
        var error: String?
    }

    struct Status: Codable, Sendable, Equatable {
        /// none | available | ready | failed | disabled
        var state: String
        var available: UpdateManifest?
        var job: Job?
        var lastCheck: Date?
        var error: String?
        var override: String?
        /// The verified dmg, once `ready` (the app mounts it).
        var staged: String?
    }

    static let changed = "a release mudou durante o download"
    static var badSignature: String { tr("o dmg baixado não é um Collie assinado e notarizado; nada foi instalado", "the downloaded dmg is not a signed, notarized Collie; nothing was installed") }
    static var refusedVersion: String { tr("esta versão já foi recusada na verificação", "this version was already refused at verification") }
    static let margin: Int64 = 100_000_000

    let root: URL, manifestURL: URL
    private var installed: String
    let fetch: UpdateFetch
    let dmgCheck: @Sendable (URL) -> Bool
    let freeSpace: @Sendable (String) -> Int64?
    let maintenance: Maintenance
    let now: @Sendable () -> Date
    let system: OperatingSystemVersion
    let enabled: @Sendable () -> Bool

    private var available: UpdateManifest?
    private var lastCheck: Date?, lastError: String?
    private(set) var job: Job?
    private var work: Task<Void, Never>?

    init(root: URL, installedVersion: String, manifestURL: URL, fetch: @escaping UpdateFetch,
         dmgCheck: @escaping @Sendable (URL) -> Bool, freeSpace: @escaping @Sendable (String) -> Int64?,
         maintenance: Maintenance, now: @escaping @Sendable () -> Date = Date.init,
         system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
         enabled: @escaping @Sendable () -> Bool = { true }) {
        self.root = root; self.installed = installedVersion; self.manifestURL = manifestURL; self.fetch = fetch
        self.dmgCheck = dmgCheck; self.freeSpace = freeSpace; self.maintenance = maintenance; self.now = now
        self.system = system; self.enabled = enabled
    }

    var staging: URL { root.appendingPathComponent(".update-staging") }
    private var refusedFile: URL { staging.appendingPathComponent("refused.json") }
    private var skippedFile: URL { staging.appendingPathComponent("skipped") }
    private func dmgPath(_ m: UpdateManifest) -> URL { staging.appendingPathComponent(m.dmg) }
    private func readyMarker(_ m: UpdateManifest) -> URL { staging.appendingPathComponent(m.dmg + ".ok") }

    /// The verified dmg of the offered version, when one is ready.
    var stagedDMG: URL? {
        guard let m = available, let ok = try? String(contentsOf: readyMarker(m), encoding: .utf8),
              ok.trimmingCharacters(in: .whitespacesAndNewlines) == m.sha256,
              FileManager.default.fileExists(atPath: dmgPath(m).path) else { return nil }
        return dmgPath(m)
    }

    func status() -> Status {
        var s = Status(state: "none", available: available, job: job, lastCheck: lastCheck, error: lastError,
                       override: manifestURL.isFileURL ? manifestURL.absoluteString : nil, staged: stagedDMG?.path)
        if job?.phase == "failed" { s.state = "failed"; s.error = job?.error }
        else if available != nil { s.state = stagedDMG != nil ? "ready" : "available" }
        else if !enabled() { s.state = "disabled" }
        return s
    }

    /// Reads the manifest and decides what is offered. `installed`: the app's own version (the app can be newer than
    /// this daemon after an "only the app" update); the higher one counts.
    func check(installed app: String? = nil) async -> Status {
        if let app, let a = AppVersion(app), AppVersion(installed).map({ a > $0 }) ?? true { installed = app }
        do {
            let tmp = try prepareStaging().appendingPathComponent("manifest.json")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try await get(manifestURL, to: tmp, limit: Int64(UpdateManifest.maxBytes))
            let m = try UpdateManifest.decode(Data(contentsOf: tmp))
            let skipped = try? String(contentsOf: skippedFile, encoding: .utf8)
            available = m.offer(installed: installed, system: system, skipped: skipped) ? m : nil
            if job?.phase == "failed", available?.sha256 != nil, !refused().contains(m.sha256) { job = nil }   // a new try
            lastError = nil
        } catch let e as ProtocolError where e.message.contains("answered 404") {
            available = nil; lastError = nil   // no update.json (older releases): nothing new
        } catch {
            lastError = (error as? ProtocolError)?.message ?? error.localizedDescription
            return status()
        }
        lastCheck = now()
        return status()
    }

    /// Starts the download of the offered version and replies at once; while one runs, its status.
    func download() async throws(ProtocolError) -> Status {
        if work != nil { return status() }
        guard let m = available else { throw ProtocolError(code: .notFound, message: tr("nenhuma versão nova disponível", "no new version available")) }
        if stagedDMG != nil { return status() }
        guard !refused().contains(m.sha256) else { throw ProtocolError(code: .unavailable, message: Self.refusedVersion) }
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        catch { throw ProtocolError(code: .internal, message: tr("atualização: \(error.localizedDescription)", "update: \(error.localizedDescription)")) }
        if let free = freeSpace(root.path), free < m.size * 3 + Self.margin {
            throw ProtocolError(code: .unavailable, message: tr("Espaço insuficiente", "Not enough disk space"))
        }
        try await maintenance.enter(tr("atualização", "update"))
        job = Job(phase: "downloading", total: m.size)
        work = Task { await self.run(m) }
        return status()
    }

    func cancel() { work?.cancel() }

    /// collied's periodic check: `first` after the start, then every `every`, only while the automatic check is on;
    /// with `download()` on, a new version is downloaded and verified in the background. Never throws.
    func loop(first: Duration = .seconds(60), every: Duration = .seconds(12 * 3600),
              download: @escaping @Sendable () -> Bool, tick: @escaping @Sendable () async -> Void = {}) async {
        try? await Task.sleep(for: first)
        while !Task.isCancelled {
            await tick()   // the plug-in catalog's refresh rides this clock, whether updates are on or not
            if enabled() {
                let s = await check()
                if s.state == "available", download() { _ = try? await self.download() }
            }
            try? await Task.sleep(for: every)
        }
    }

    /// The status once the current download ended (tests; the app polls `app.update.status`).
    func finished() async -> Status {
        await work?.value
        return status()
    }

    func skip(_ version: String) -> Status {
        _ = try? prepareStaging()
        try? Data(version.utf8).write(to: skippedFile, options: .atomic)
        if available?.version == version { available = nil }
        if job?.phase != "downloading", job?.phase != "verifying" { job = nil }
        return status()
    }

    // MARK: -

    private func run(_ m: UpdateManifest) async {
        defer { work = nil }
        let dest = dmgPath(m), part = staging.appendingPathComponent(m.dmg + ".part")
        do {
            _ = try prepareStaging()
            try? FileManager.default.removeItem(at: readyMarker(m))
            try? FileManager.default.removeItem(at: part)
            try await get(dmgSource(m), to: part, limit: m.size)
            try Task.checkCancellation()
            job?.phase = "verifying"
            do { try AndroidDownload.verify(part, sha256: m.sha256) }
            catch { refuse(m.sha256); throw ProtocolError(code: .unavailable, message: Self.changed) }
            guard dmgCheck(part) else { refuse(m.sha256); throw ProtocolError(code: .unavailable, message: Self.badSignature) }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: part, to: dest)
            try Data((m.sha256 + "\n").utf8).write(to: readyMarker(m))
            job?.phase = "ready"
        } catch {
            try? FileManager.default.removeItem(at: part)
            if Task.isCancelled { job?.phase = "cancelled"; job?.error = nil }
            else { job?.phase = "failed"; job?.error = (error as? ProtocolError)?.message ?? error.localizedDescription }
        }
        await maintenance.leave(tr("atualização", "update"))
    }

    private func progress(_ b: Int64, _ t: Int64) {
        guard job?.phase == "downloading" else { return }
        job?.bytes = b
        if t > 0 { job?.total = t }
    }

    /// `file://`: copied from disk under the same cap; else the injected fetch.
    private func get(_ url: URL, to: URL, limit: Int64?) async throws {
        guard url.isFileURL else {
            try await fetch(url, to, limit) { [weak self] b, t in Task { await self?.progress(b, t) } }
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        guard let size else { throw ProtocolError(code: .unavailable, message: "download answered 404 from \(url.path)") }
        if let limit, size > limit { throw ProtocolError(code: .unavailable, message: AndroidDownload.tooLarge) }
        try? FileManager.default.removeItem(at: to)
        try FileManager.default.copyItem(at: url, to: to)
    }

    private func dmgSource(_ m: UpdateManifest) -> URL {
        manifestURL.isFileURL ? manifestURL.deletingLastPathComponent().appendingPathComponent(m.dmg) : m.dmgURL
    }

    private func prepareStaging() throws -> URL {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(staging.path, 0o700)
        return staging
    }

    private func refused() -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(contentsOf: refusedFile))) ?? []
    }

    private func refuse(_ sha: String) {
        var r = refused()
        guard !r.contains(sha) else { return }
        r.append(sha)
        try? JSONEncoder().encode(r).write(to: refusedFile, options: .atomic)
    }
}
