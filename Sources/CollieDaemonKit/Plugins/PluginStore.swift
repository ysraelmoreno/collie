import Foundation
import CryptoKit
import CollieCore
import CollieProtocol

/// External plug-ins installed by the user (admin only: `plugin.*` in `PluginAdminCommands`). A copy of the plug-in's
/// folder lives at `<root>/plugins/<id>/<version>/`, files 0444 and dirs 0555, its tree hash pinned in `installed.json`
/// (0600). Every load (this init: daemon start) hashes it again: a changed or broken one is skipped with its reason,
/// never the others.
// ponytail: verified at load only; an edit between loads goes unseen until the next start. The tree is read-only and
// under the Collie root, which the terminals' sandbox never opens for writing.
actor PluginStore {
    static let maxBytes = 64 * 1024 * 1024, maxFiles = 5000
    static let changed = "conteúdo alterado desde a instalação; instale de novo"
    let dir: URL
    private var entries: [InstalledPlugin]
    private var manifests: [String: PluginManifest] = [:]   // the verified ones, by id
    private var file: URL { dir.appendingPathComponent("installed.json") }

    init(root: URL) {
        dir = root.appendingPathComponent("plugins")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        entries = (try? Data(contentsOf: root.appendingPathComponent("plugins/installed.json")))
            .flatMap { try? dec.decode([InstalledPlugin].self, from: $0) }?
            .filter { PluginManifest.safeFolderNames(id: $0.id, version: $0.version) } ?? []   // an edited file never names a path
        for i in entries.indices {
            switch Self.verify(entries[i], in: dir) {
            case .success(let m): manifests[m.id] = m; entries[i].error = nil
            case .failure(let e): entries[i].error = e.message
            }
        }
    }

    /// Every installed plug-in, loadable or not, by id.
    func list() -> [InstalledPlugin] { entries.sorted { $0.id < $1.id } }
    func manifest(_ id: String) -> PluginManifest? { manifests[id] }
    /// The enabled plug-ins that passed verification.
    func loaded() -> [(PluginManifest, InstalledPlugin)] {
        list().compactMap { e in e.enabled && e.error == nil ? manifests[e.id].map { ($0, e) } : nil }
    }
    /// The installed folder of a loaded plug-in.
    func folder(of id: String) -> URL? {
        loaded().first { $0.0.id == id }.map { versionDir($0.1.id, $0.1.version) }
    }

    /// Copies `source` in (refusing links, special files, > 64 MiB, > 5 000 entries), validates its manifest, hashes
    /// it and swaps it in: the previous version keeps working until the new one is complete, then goes.
    func install(from source: URL) throws(ProtocolError) -> InstalledPlugin {
        let src = source.resolvingSymlinksInPath()   // the folder the user picked; links inside it are refused
        _ = try Self.scan(src)   // cheap refusal before copying anything
        let fm = FileManager.default
        try io { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let staging = dir.appendingPathComponent(".staging-\(UUID().uuidString)")
        defer { Self.removeTree(staging) }
        try io { try FileManager.default.copyItem(at: src, to: staging) }
        let files = try Self.scan(staging)   // the copy is what counts: the source may have changed meanwhile
        let m = try PluginManifest.load(folder: staging)
        let hash = try Self.treeHash(staging, files)
        try Self.lock(staging, files)

        let idDir = dir.appendingPathComponent(m.id), dest = versionDir(m.id, m.version)
        try io { try FileManager.default.createDirectory(at: idDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]) }
        let old = entries.first { $0.id == m.id }
        // same version again: the current folder moves aside first (a dir moves only while it is writable)
        let aside = idDir.appendingPathComponent(".old-\(UUID().uuidString)")
        let replacing = fm.fileExists(atPath: dest.path)
        func restore() { if replacing, (try? fm.moveItem(at: aside, to: dest)) != nil { chmod(dest.path, 0o555) } }
        if replacing {
            chmod(dest.path, 0o755)
            do { try fm.moveItem(at: dest, to: aside) } catch {
                chmod(dest.path, 0o555)
                throw ProtocolError(code: .internal, message: "não foi possível instalar o plug-in")
            }
        }
        do {
            try fm.moveItem(at: staging, to: dest)
            chmod(dest.path, 0o555)
        } catch {
            restore()
            throw ProtocolError(code: .internal, message: "não foi possível instalar o plug-in")
        }
        let entry = InstalledPlugin(id: m.id, version: m.version, sha256: hash, enabled: true, installedAt: Date(), error: nil)
        let before = entries
        entries.removeAll { $0.id == m.id }; entries.append(entry)
        do { try save() } catch {
            entries = before
            Self.removeTree(dest)
            restore()
            throw error
        }
        manifests[m.id] = m
        Self.removeTree(aside)
        if let old, old.version != m.version { Self.removeTree(versionDir(old.id, old.version)) }
        return entry
    }

    func uninstall(_ id: String) throws(ProtocolError) {
        guard entries.contains(where: { $0.id == id }) else { throw notInstalled(id) }
        let before = entries
        entries.removeAll { $0.id == id }
        do { try save() } catch { entries = before; throw error }
        manifests[id] = nil
        Self.removeTree(dir.appendingPathComponent(id))
    }

    /// Enabling verifies the folder again: a changed one stays off.
    func setEnabled(_ id: String, _ on: Bool) throws(ProtocolError) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { throw notInstalled(id) }
        if on {
            switch Self.verify(entries[i], in: dir) {
            case .success(let m): manifests[id] = m; entries[i].error = nil
            case .failure(let e): entries[i].error = e.message; throw e
            }
        }
        let was = entries[i].enabled
        entries[i].enabled = on
        do { try save() } catch { entries[i].enabled = was; throw error }
    }

    // MARK: - files

    private func versionDir(_ id: String, _ version: String) -> URL { dir.appendingPathComponent(id).appendingPathComponent(version) }
    private func notInstalled(_ id: String) -> ProtocolError { ProtocolError(code: .notFound, message: "plug-in '\(id)' não está instalado") }

    private func save() throws(ProtocolError) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmp = dir.appendingPathComponent(".installed-\(UUID().uuidString)")
        do {
            let data = try enc.encode(list())
            guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard rename(tmp.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw ProtocolError(code: .internal, message: "não foi possível gravar a lista de plug-ins")
        }
    }

    private func io(_ body: () throws -> Void) throws(ProtocolError) {
        do { try body() } catch { throw ProtocolError(code: .internal, message: "erro de arquivo ao instalar o plug-in") }
    }

    /// The tree's regular files, relative and sorted. Refuses links and special files, > 5 000 entries, > 64 MiB.
    /// Messages name paths inside the plug-in only.
    static func scan(_ root: URL) throws(ProtocolError) -> [String] {
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType) == .typeDirectory,
              let walk = fm.enumerator(atPath: root.path) else {
            throw ProtocolError(code: .invalidArgs, message: "o plug-in precisa ser uma pasta")
        }
        var files: [String] = [], count = 0, bytes = 0
        while let rel = walk.nextObject() as? String {
            count += 1
            guard count <= maxFiles else { throw ProtocolError(code: .invalidArgs, message: "o plug-in tem mais de \(maxFiles) arquivos") }
            guard let a = try? fm.attributesOfItem(atPath: root.appendingPathComponent(rel).path),   // lstat
                  let type = a[.type] as? FileAttributeType else {
                throw ProtocolError(code: .invalidArgs, message: "'\(rel)' ilegível")
            }
            switch type {
            case .typeDirectory: continue
            case .typeRegular:
                bytes += (a[.size] as? Int) ?? 0
                guard bytes <= maxBytes else { throw ProtocolError(code: .invalidArgs, message: "o plug-in passa de 64 MiB") }
                files.append(rel)
            case .typeSymbolicLink: throw ProtocolError(code: .invalidArgs, message: "'\(rel)' é um link simbólico: não aceito em plug-ins")
            default: throw ProtocolError(code: .invalidArgs, message: "'\(rel)' não é um arquivo comum")
            }
        }
        return files.sorted()
    }

    /// SHA-256 over each file's relative path and content hash, in path order.
    static func treeHash(_ root: URL, _ files: [String]) throws(ProtocolError) -> String {
        var h = SHA256()
        for rel in files {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(rel), options: .mappedIfSafe) else {
                throw ProtocolError(code: .invalidArgs, message: "'\(rel)' ilegível")
            }
            h.update(data: Data(rel.utf8)); h.update(data: Data([0])); h.update(data: Data(SHA256.hash(data: data)))
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Files 0444, dirs below the root 0555 (deepest first). The root itself is locked after its last move.
    static func lock(_ root: URL, _ files: [String]) throws(ProtocolError) {
        for f in files where chmod(root.appendingPathComponent(f).path, 0o444) != 0 {
            throw ProtocolError(code: .internal, message: "não foi possível proteger '\(f)'")
        }
        let dirs = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? [])
            .filter { (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent($0).path)[.type] as? FileAttributeType) == .typeDirectory }
        for d in dirs.sorted(by: { $0.count > $1.count }) { chmod(root.appendingPathComponent(d).path, 0o555) }
    }

    /// Removes a tree that may hold read-only dirs (made writable first). Missing: nothing.
    static func removeTree(_ u: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: u.path) else { return }
        chmod(u.path, 0o700)
        for rel in (fm.enumerator(atPath: u.path)?.allObjects as? [String]) ?? [] {
            let p = u.appendingPathComponent(rel).path
            if (try? fm.attributesOfItem(atPath: p)[.type] as? FileAttributeType) == .typeDirectory { chmod(p, 0o700) }
        }
        try? fm.removeItem(at: u)
    }

    /// The installed folder still is what was installed: present, no links, same manifest id and version, same hash.
    static func verify(_ e: InstalledPlugin, in dir: URL) -> Result<PluginManifest, ProtocolError> {
        let folder = dir.appendingPathComponent(e.id).appendingPathComponent(e.version)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return .failure(ProtocolError(code: .invalidArgs, message: "a pasta do plug-in sumiu; instale de novo"))
        }
        do throws(ProtocolError) {
            let files = try scan(folder)
            let m = try PluginManifest.load(folder: folder)
            guard m.id == e.id, m.version == e.version, try treeHash(folder, files) == e.sha256 else {
                return .failure(ProtocolError(code: .invalidArgs, message: changed))
            }
            return .success(m)
        } catch {
            return .failure(ProtocolError(code: .invalidArgs, message: changed))
        }
    }
}
