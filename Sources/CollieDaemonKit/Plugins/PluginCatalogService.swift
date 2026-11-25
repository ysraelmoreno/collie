import Foundation
import CollieCore
import CollieProtocol

/// The daemon side of the plug-in catalog (spec 2026-11-24-plugin-marketplace-design.md, "Catálogo"). Keeps the last
/// accepted `plugins.json` + `.sig` in `<root>/plugins/catalog.json(.sig)` (0600): it lists offline and its recalls hold
/// at start without network (decision 8). Installs one package at a time per id: downloaded into a 0700 staging,
/// sha256 checked, its tar listing refused on any absolute or `..` path, extracted, scanned (no links, no special
/// files, the install caps), tree-hashed against `treeSha256`, a helper checked for the item's team, then handed to
/// `PluginStore.install(…, source: .catalog)`. The staging goes on every exit.
actor PluginCatalogService {
    struct Fetch: Sendable {
        /// `plugins.json` and `plugins.json.sig`.
        var catalog: @Sendable () async throws -> (Data, Data)
        /// One package to `to`, at most `limit` bytes.
        var package: @Sendable (_ url: URL, _ to: URL, _ limit: Int64) async throws -> Void

        static let base = "https://github.com/ysraelmoreno/collie/releases/download/plugins-catalog/"
        static let live = Fetch(catalog: {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collie-catalog-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: dir) }
            func get(_ name: String, _ limit: Int64) async throws -> Data {
                guard let u = URL(string: base + name) else { throw ProtocolError(code: .internal, message: "url do catálogo") }
                let to = dir.appendingPathComponent(name)
                try await AndroidDownload.fetch(u, to: to, limit: limit, headers: [:]) { _, _ in }
                return try Data(contentsOf: to)
            }
            return (try await get("plugins.json", 4 << 20), try await get("plugins.json.sig", 1024))
        }, package: { url, to, limit in
            try await AndroidDownload.fetch(url, to: to, limit: limit, headers: [:]) { _, _ in }
        })
    }

    enum State: String, Sendable { case ok, stale, unavailable }

    let root: URL, store: PluginStore, fetch: Fetch, keys: [String], collie: String
    let now: @Sendable () -> Date
    let signature: @Sendable (URL, String, String) -> Bool
    /// Ids a recall just turned off (the router republishes the plug-ins).
    let onRecall: @Sendable ([String]) async -> Void
    private(set) var stored: PluginCatalog?
    private var installing: Set<String> = []
    private var dir: URL { root.appendingPathComponent("plugins") }
    private var file: URL { dir.appendingPathComponent("catalog.json") }
    private var sigFile: URL { dir.appendingPathComponent("catalog.json.sig") }

    /// `collie`: this app's version, for `minCollie` (a dev build passes a high one: it sees everything).
    init(root: URL, store: PluginStore, fetch: Fetch = .live, keys: [String] = PluginCatalog.publicKeys,
         collie: String = "9999", now: @escaping @Sendable () -> Date = Date.init,
         signature: @escaping @Sendable (URL, String, String) -> Bool = FigcraftInstaller.signedByTeam,
         onRecall: @escaping @Sendable ([String]) async -> Void = { _ in }) {
        self.root = root; self.store = store; self.fetch = fetch; self.keys = keys; self.collie = collie; self.now = now
        self.signature = signature; self.onRecall = onRecall
        let d = root.appendingPathComponent("plugins")
        if let data = try? Data(contentsOf: d.appendingPathComponent("catalog.json")),
           let sig = try? Data(contentsOf: d.appendingPathComponent("catalog.json.sig")) {
            stored = try? PluginCatalog.accept(data, signature: sig, keys: keys, lastSequence: nil)
        }
    }

    /// The catalog to list: downloaded again with `refresh` (or when none is stored). Offline: the stored one with its
    /// own state and the reason; a refused download: `unavailable` with the reason, the stored one still listed.
    func current(refresh: Bool) async -> (catalog: PluginCatalog?, state: State, reason: String?) {
        var reason: String?
        if refresh || stored == nil {
            switch await download() {
            case .accepted: break
            case .offline(let why): reason = why
            case .refused(let why): return (stored, .unavailable, why)
            }
        }
        guard let c = stored else { return (nil, .unavailable, reason ?? "catálogo não carregado") }
        return (c, c.isStale(now: now()) ? .stale : .ok, reason)
    }

    /// At daemon start (no network) and from the daily check: the stored or a fresh catalog's recalls applied.
    func applyStored() async { await applyRecalls() }
    func dailyRefresh() async { _ = await current(refresh: true) }

    private enum Outcome { case accepted, offline(String), refused(String) }

    private func download() async -> Outcome {
        let data: Data, sig: Data
        do { (data, sig) = try await fetch.catalog() } catch {
            return .offline("não consegui baixar o catálogo: \((error as? ProtocolError)?.message ?? error.localizedDescription)")
        }
        let c: PluginCatalog
        do throws(ProtocolError) { c = try PluginCatalog.accept(data, signature: sig, keys: keys, lastSequence: stored?.sequence) }
        catch { return .refused(error.message) }
        guard save(data, sig) else { return .refused("não foi possível guardar o catálogo") }
        stored = c
        await applyRecalls()
        return .accepted
    }

    /// sig first, then the catalog: a crash between leaves a pair that fails `accept`, so nothing is trusted from it.
    // ponytail: a torn pair forgets the stored sequence until the next download; one file holding both if that matters.
    private func save(_ data: Data, _ sig: Data) -> Bool {
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil else { return false }
        for (target, bytes) in [(sigFile, sig), (file, data)] {
            let tmp = dir.appendingPathComponent(".catalog-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: tmp.path, contents: bytes, attributes: [.posixPermissions: 0o600]),
                  rename(tmp.path, target.path) == 0 else { try? FileManager.default.removeItem(at: tmp); return false }
        }
        return true
    }

    private func applyRecalls() async {
        guard let c = stored else { return }
        let ids = (try? await store.applyRecalls { c.recall(forTree: $0) }) ?? []
        if !ids.isEmpty { await onRecall(ids) }
    }

    /// Downloads, checks and installs `id` `version` from the stored catalog (`plugin.catalog` loads it first).
    func install(id: String, version: String) async throws(ProtocolError) -> InstalledPlugin {
        guard installing.insert(id).inserted else { throw ProtocolError(code: .conflict, message: "já instalando \(id)") }
        defer { installing.remove(id) }
        guard let c = stored else { throw ProtocolError(code: .unavailable, message: "catálogo não carregado; abra Descobrir de novo") }
        guard let item = c.plugins.first(where: { $0.id == id }), let v = item.versions.first(where: { $0.version == version }) else {
            throw ProtocolError(code: .notFound, message: "\(id) \(version) não está no catálogo")
        }
        if let r = v.recalled { throw InstalledPlugin.recalledRefusal(r) }
        guard PluginCatalog.compare(v.minCollie ?? item.minCollie, collie) != .orderedDescending else {
            throw ProtocolError(code: .unavailable, message: "\(id) \(version) precisa de um Collie mais novo (\(v.minCollie ?? item.minCollie))")
        }
        let fm = FileManager.default
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw ProtocolError(code: .internal, message: "erro de arquivo ao instalar o plug-in") }
        let staging = dir.appendingPathComponent(".staging-\(UUID().uuidString)")
        guard mkdir(staging.path, 0o700) == 0 else { throw ProtocolError(code: .internal, message: "erro de arquivo ao instalar o plug-in") }
        defer { PluginStore.removeTree(staging) }

        let pkg = staging.appendingPathComponent("package.tar.gz"), out = staging.appendingPathComponent("x")
        do { try await fetch.package(v.url, pkg, v.size) } catch {
            throw ProtocolError(code: .unavailable, message: "o download do pacote falhou: \((error as? ProtocolError)?.message ?? error.localizedDescription)")
        }
        do { try AndroidDownload.verify(pkg, sha256: v.sha256) }
        catch { throw ProtocolError(code: .unavailable, message: "o pacote baixado não confere com o catálogo (sha256)") }
        let folder = try await Self.extract(pkg, into: out)
        let files = try PluginStore.scan(folder)
        guard try PluginStore.treeHash(folder, files) == v.treeSha256 else {
            throw ProtocolError(code: .unavailable, message: "o conteúdo do pacote não confere com o catálogo (treeSha256)")
        }
        let m = try PluginManifest.load(folder: folder)
        if let helper = m.helper {
            guard let team = v.helperTeamId,
                  signature(folder.appendingPathComponent(helper), "dev.collie.plugin.\(id)", team) else {
                throw ProtocolError(code: .unavailable, message: "o helper de \(id) não tem a assinatura do time do catálogo")
            }
            chmod(folder.appendingPathComponent(helper).path, 0o755)   // the install sets the bit, not the tar
        }
        let e = try await store.install(from: folder, expect: (id, version), replace: true, source: .catalog)
        guard e.sha256 == v.treeSha256 else {   // the store's own copy, hashed again
            try? await store.setEnabled(id, false)
            throw ProtocolError(code: .unavailable, message: "o conteúdo do pacote mudou durante a instalação")
        }
        await applyRecalls()
        return e
    }

    /// `tar -tzf` first: any absolute or `..` entry, or more than the install's entry cap, refuses before anything is
    /// written; then extracted into `into` (bsdtar's own guards as a second layer). The package is one folder.
    // ponytail: uncompressed bytes are capped after extraction (PluginStore.scan), not during: a gzip bomb can fill the
    // disk for a moment; stream through `tar -tv` sizes if that matters.
    static func extract(_ pkg: URL, into out: URL) async throws(ProtocolError) -> URL {
        let bad = ProtocolError(code: .invalidArgs, message: "pacote recusado: caminho fora da pasta do plug-in")
        let tar = URL(fileURLWithPath: "/usr/bin/tar"), dir = pkg.deletingLastPathComponent(), env = ["PATH": "/usr/bin:/bin"]
        let list = try await BoundedProcess.run(executable: tar, args: ["-tzf", pkg.path], in: dir, env: env,
                                                timeout: .seconds(120), cap: 4 << 20)
        guard list.status == 0, !list.truncated else { throw ProtocolError(code: .invalidArgs, message: "pacote ilegível") }
        let names = list.stdout.split(separator: "\n", omittingEmptySubsequences: true)
        guard names.count <= PluginStore.maxFiles + 1 else {
            throw ProtocolError(code: .invalidArgs, message: "o plug-in tem mais de \(PluginStore.maxFiles) arquivos")
        }
        for n in names where n.hasPrefix("/") || n.split(separator: "/").contains("..") { throw bad }
        guard mkdir(out.path, 0o700) == 0 else { throw ProtocolError(code: .internal, message: "erro de arquivo ao instalar o plug-in") }
        let x = try await BoundedProcess.run(executable: tar, args: ["-xzf", pkg.path, "-C", out.path], in: dir, env: env,
                                             timeout: .seconds(300), cap: 64 << 10)
        guard x.status == 0 else { throw ProtocolError(code: .invalidArgs, message: "pacote recusado: \(x.stderr.prefix(200))") }
        let top = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        guard top.count == 1, let name = top.first,
              (try? FileManager.default.attributesOfItem(atPath: out.appendingPathComponent(name).path)[.type] as? FileAttributeType) == .typeDirectory else {
            throw ProtocolError(code: .invalidArgs, message: "o pacote precisa ter uma só pasta, a do plug-in")
        }
        return out.appendingPathComponent(name)
    }
}
