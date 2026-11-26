import Foundation
import Darwin
import Security
import CollieProtocol
import CollieCore

/// Downloads, checks and installs the design engine the pin names into `<root>/figcraft` (spec §3), only when the app
/// asks (`design.engine.install`). Everything happens in `<root>/.figcraft-staging` and nothing outside it is touched
/// until the swap: the whole asset's sha256 is checked against the pin before anything is extracted (a mismatch is not
/// retried), the extracted tree is scanned (no symlink, nothing but files and dirs, no setuid/setgid, `go-w`), both
/// binaries must carry the pin team's Developer ID Application signature with their identifier, the quarantine flag is
/// dropped, the dir is kept out of backups and gets the asset's sha256 as its marker (`FigcraftEngine.marker`). The
/// swap (`swap`: the router's `swapEngine`, which holds the server and closes its clients) exchanges it with the
/// installed one; the staging, then holding the old engine, is deleted. `<root>/design/` is never touched.
actor FigcraftInstaller {
    /// phase: downloading | verifying | installing | done | failed | cancelled. Kept after the end (a failure stays visible).
    struct Job: Codable, Sendable, Equatable {
        var phase: String
        var bytes: Int64 = 0
        var total: Int64 = 0
        var error: String?
    }

    static var badSha: String { tr("O arquivo baixado não confere (sha256). Nada foi instalado.", "The downloaded file does not match (sha256). Nothing was installed.") }
    /// Free space an install needs beyond the asset and the extracted tree.
    static let margin: Int64 = 100_000_000

    let root: URL, pin: FigcraftPin?
    let fetch: AndroidFetch
    let signature: @Sendable (_ binary: URL, _ identifier: String, _ teamId: String) -> Bool
    let freeSpace: @Sendable (String) -> Int64?
    let busy: @Sendable () async -> Bool
    let swap: @Sendable (_ op: @Sendable () throws -> Void) async throws -> Void
    private(set) var job: Job?
    private var work: Task<Void, Never>?

    init(root: URL, pin: FigcraftPin?, fetch: @escaping AndroidFetch = AndroidDownload.fetch,
         signature: @escaping @Sendable (URL, String, String) -> Bool = FigcraftInstaller.signedByTeam,
         freeSpace: @escaping @Sendable (String) -> Int64? = AndroidInstaller.free,
         busy: @escaping @Sendable () async -> Bool,
         swap: @escaping @Sendable (_ op: @Sendable () throws -> Void) async throws -> Void) {
        self.root = root; self.pin = pin; self.fetch = fetch; self.signature = signature
        self.freeSpace = freeSpace; self.busy = busy; self.swap = swap
    }

    private var running: Bool { work != nil }
    private var engine: URL { root.appendingPathComponent("figcraft") }
    private var staging: URL { FigcraftEngine.staging(root: root) }

    /// Starts the install and replies at once; while one runs, its job (no second download).
    func install() throws(ProtocolError) -> Job {
        if running, let job { return job }
        guard let pin else {
            throw ProtocolError(code: .unavailable, message: tr("este Collie não tem pin do motor de design (figcraft-engine.json)", "this Collie has no design engine pin (figcraft-engine.json)"))
        }
        let j = Job(phase: "downloading", total: pin.size)
        job = j
        work = Task { await self.run(pin) }
        return j
    }

    func cancel() { work?.cancel() }

    /// The current job once its work ended (tests; the app polls `design.engine.status`).
    func finished() async -> Job? {
        await work?.value
        return job
    }

    /// Swaps the installed engine out (the server held and its clients closed) and deletes it.
    func remove() async throws(ProtocolError) {
        let held = await busy()
        if running || held {
            throw ProtocolError(code: .conflict, message: tr("motor de design ocupado (instalação, troca ou backup em andamento)", "design engine busy (install, swap or backup in progress)"))
        }
        guard FileManager.default.fileExists(atPath: engine.path) else {
            throw ProtocolError(code: .notFound, message: tr("nenhum motor de design baixado", "no design engine downloaded"))
        }
        let root = root
        do { try await swap { try Self.swapInto(root: root, staged: nil) } }
        catch let e as ProtocolError { throw e }
        catch { throw ProtocolError(code: .internal, message: "remover o motor: \(error.localizedDescription)") }
        FigcraftEngine.cleanStaging(root: root)
    }

    private func progress(_ bytes: Int64, _ total: Int64) {
        guard job?.phase == "downloading" else { return }
        job?.bytes = bytes
        if total > 0 { job?.total = total }
    }

    private func phase(_ p: String) { job?.phase = p }

    private func run(_ pin: FigcraftPin) async {
        defer { FigcraftEngine.cleanStaging(root: root); work = nil }
        do {
            try await steps(pin)
            phase("done")
        } catch {
            if Task.isCancelled { job?.phase = "cancelled"; job?.error = nil; return }
            job?.phase = "failed"
            job?.error = (error as? ProtocolError)?.message ?? error.localizedDescription
        }
    }

    private func steps(_ pin: FigcraftPin) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if let free = freeSpace(root.path), free < pin.size + pin.unpackedSize + Self.margin {
            throw ProtocolError(code: .unavailable, message: tr("Espaço insuficiente", "Not enough space"))
        }
        FigcraftEngine.cleanStaging(root: root)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let url = URL(string: pin.url) else { throw ProtocolError(code: .invalidArgs, message: tr("pin url inválida", "invalid pin url")) }
        let asset = staging.appendingPathComponent("asset.tar.gz")
        try await fetch(url, asset) { [weak self] b, t in Task { await self?.progress(b, t) } }
        try Task.checkCancellation()

        phase("verifying")
        do { try AndroidDownload.verify(asset, sha256: pin.sha256) }
        catch { throw ProtocolError(code: .unavailable, message: Self.badSha) }   // nothing extracted, no retry

        phase("installing")
        try await AndroidInstaller.run("/usr/bin/tar", ["-xzf", asset.path, "-C", staging.path], staging)
        let staged = staging.appendingPathComponent("figcraft")
        try Self.scan(staged)
        guard FigcraftEngine.isValid(staged), FigcraftEngine.version(staged) == pin.version else {
            throw ProtocolError(code: .unavailable, message: tr("o motor baixado não tem o formato esperado (versão \(pin.version))", "the downloaded engine does not have the expected format (version \(pin.version))"))
        }
        for id in ["figcraft-server", "figcraft-cli"] where !signature(staged.appendingPathComponent("bin/\(id)"), id, pin.teamId) {
            throw ProtocolError(code: .unavailable, message: tr("a assinatura do motor baixado não confere (\(id))", "the downloaded engine's signature does not match (\(id))"))
        }
        Self.stripQuarantine(staged)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        var s = staged; try s.setResourceValues(v)
        try Data((pin.sha256 + "\n").utf8).write(to: staged.appendingPathComponent(FigcraftEngine.marker))
        try Task.checkCancellation()
        let root = root
        try await swap { try Self.swapInto(root: root, staged: staged) }
    }

    /// `staged` → `<root>/figcraft`: exchanged with the installed one in one `renamex_np(RENAME_SWAP)` (the old one ends at
    /// `staged`), a plain rename when none is installed. `staged == nil` removes: `<root>/figcraft` → the staging.
    static func swapInto(root: URL, staged: URL?) throws {
        let dest = root.appendingPathComponent("figcraft"), fm = FileManager.default
        func fail(_ what: String) -> ProtocolError {
            ProtocolError(code: .internal, message: "\(what): \(String(cString: strerror(errno)))")
        }
        guard let staged else {
            let st = FigcraftEngine.staging(root: root)
            try fm.createDirectory(at: st, withIntermediateDirectories: true)
            guard rename(dest.path, st.appendingPathComponent("old").path) == 0 else { throw fail("remover o motor") }
            return
        }
        if fm.fileExists(atPath: dest.path) {
            guard renamex_np(staged.path, dest.path, UInt32(RENAME_SWAP)) == 0 else { throw fail("trocar o motor") }
        } else {
            guard rename(staged.path, dest.path) == 0 else { throw fail("instalar o motor") }
        }
    }

    /// Refuses a symlink, anything but files and dirs, setuid/setgid; drops group/other write everywhere.
    static func scan(_ dir: URL) throws {
        let fm = FileManager.default
        let items = [""] + (fm.subpaths(atPath: dir.path) ?? [])
        for rel in items {
            let path = rel.isEmpty ? dir.path : dir.appendingPathComponent(rel).path
            var st = stat()
            guard lstat(path, &st) == 0 else { throw ProtocolError(code: .unavailable, message: tr("motor baixado: \(rel) ilegível", "downloaded engine: \(rel) unreadable")) }
            if let why = refusal(mode: st.st_mode) { throw ProtocolError(code: .unavailable, message: "motor baixado: \(rel) \(why)") }
            if st.st_mode & 0o022 != 0 { chmod(path, st.st_mode & 0o7755) }
        }
    }

    /// Why an extracted entry of this mode is refused (nil: kept): only files and dirs, no setuid/setgid.
    static func refusal(mode: mode_t) -> String? {
        let type = mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else { return tr("não é arquivo nem pasta", "not a file or folder") }
        guard mode & (S_ISUID | S_ISGID) == 0 else { return "com setuid/setgid" }
        return nil
    }

    /// `com.apple.quarantine` off every file (URLSession does not set it; a future path might).
    static func stripQuarantine(_ dir: URL) {
        let items = [""] + (FileManager.default.subpaths(atPath: dir.path) ?? [])
        for rel in items { removexattr(rel.isEmpty ? dir.path : dir.appendingPathComponent(rel).path, "com.apple.quarantine", XATTR_NOFOLLOW) }
    }

    /// Developer ID Application of `teamId`, with `identifier`, every architecture, strict (spec §3.6).
    static let signedByTeam: @Sendable (URL, String, String) -> Bool = { binary, identifier, teamId in
        CodeSignature.signedByTeam(binary, identifier: identifier, teamId: teamId)
    }
}
