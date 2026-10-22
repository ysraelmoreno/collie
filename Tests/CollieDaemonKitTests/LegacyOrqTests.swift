import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func tempDir() -> URL {
    let u = URL(fileURLWithPath: "/tmp/collie-legacy-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
private func put(_ dir: URL, _ rel: String, _ text: String = "x") {
    let f = dir.appendingPathComponent(rel)
    try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: f)
}
private func read(_ dir: URL, _ rel: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(rel), encoding: .utf8) }
private func isLink(_ u: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: u.path))?[.type] as? FileAttributeType == .typeSymbolicLink
}

@Suite struct LegacyOrqTests {
    @Test func movesRootAndLeavesSymlink() throws {
        let t = tempDir(); defer { try? FileManager.default.removeItem(at: t) }
        let old = t.appendingPathComponent("Orq"), new = t.appendingPathComponent("Collie")
        put(old, "a.txt", "data")
        #expect(LegacyOrq.migrateDataRoot(old: old, new: new) { false } == .moved)
        #expect(read(new, "a.txt") == "data")
        #expect(isLink(old))
        #expect(old.resolvingSymlinksInPath().path == new.resolvingSymlinksInPath().path)
        #expect(read(old, "a.txt") == "data")
    }

    @Test func secondRunIsNoop() throws {
        let t = tempDir(); defer { try? FileManager.default.removeItem(at: t) }
        let old = t.appendingPathComponent("Orq"), new = t.appendingPathComponent("Collie")
        put(old, "a.txt")
        #expect(LegacyOrq.migrateDataRoot(old: old, new: new) { false } == .moved)
        #expect(LegacyOrq.migrateDataRoot(old: old, new: new) { false } == .nothingToMove)
        #expect(isLink(old))
        #expect(LegacyOrq.migrateDataRoot(old: t.appendingPathComponent("none"), new: t.appendingPathComponent("n2")) { false } == .nothingToMove)
    }

    @Test func bothExistTouchesNothing() throws {
        let t = tempDir(); defer { try? FileManager.default.removeItem(at: t) }
        let old = t.appendingPathComponent("Orq"), new = t.appendingPathComponent("Collie")
        put(old, "a.txt", "old"); put(new, "a.txt", "new")
        #expect(LegacyOrq.migrateDataRoot(old: old, new: new) { false } == .bothExist)
        #expect(read(old, "a.txt") == "old" && read(new, "a.txt") == "new")
        #expect(!isLink(old))
        #expect(try FileManager.default.contentsOfDirectory(atPath: new.path) == ["a.txt"])
    }

    @Test func oldDaemonAliveTouchesNothing() throws {
        let t = tempDir(); defer { try? FileManager.default.removeItem(at: t) }
        let old = t.appendingPathComponent("Orq"), new = t.appendingPathComponent("Collie")
        put(old, "a.txt", "old")
        #expect(LegacyOrq.migrateDataRoot(old: old, new: new) { true } == .oldDaemonAlive)
        #expect(read(old, "a.txt") == "old" && !isLink(old))
        #expect(!FileManager.default.fileExists(atPath: new.path))
    }

    @Test func renamesHerdFiles() throws {
        let t = tempDir(); defer { try? FileManager.default.removeItem(at: t) }
        let old = t.appendingPathComponent("Orq"), new = t.appendingPathComponent("Collie")
        put(old, "herds/x.orqpartitura", "x")
        put(old, "herds/.removed/y-1.orqpartitura", "y")
        put(old, "herds/z.orqpartitura", "old z"); put(old, "herds/z.collieherd", "new z")
        #expect(LegacyOrq.migrateDataRoot(old: old, new: new) { false } == .moved)
        LegacyOrq.renameLegacyHerds(in: new)
        LegacyOrq.renameLegacyHerds(in: new)   // idempotent
        #expect(read(new, "herds/x.collieherd") == "x")
        #expect(read(new, "herds/z.collieherd") == "new z" && read(new, "herds/z.orqpartitura") == "old z")   // never clobbered
        #expect(read(new, "herds/.removed/y-1.collieherd") == "y")
        #expect(read(new, "herds/x.orqpartitura") == nil)
    }

    @Test func linkElsewhereIsLeft() throws {
        let t = tempDir(); defer { try? FileManager.default.removeItem(at: t) }
        let old = t.appendingPathComponent("Orq"), new = t.appendingPathComponent("Collie"), ext = t.appendingPathComponent("Ext")
        put(ext, "a.txt")
        #expect(symlink(ext.path, old.path) == 0)
        #expect(LegacyOrq.migrateDataRoot(old: old, new: new) { false } == .nothingToMove)
        #expect(isLink(old) && read(ext, "a.txt") == "x" && !FileManager.default.fileExists(atPath: new.path))
    }

    @Test func importedOrqBackupHerdsAreRenamed() async throws {
        let t = tempDir(); defer { try? FileManager.default.removeItem(at: t) }
        let src = t.appendingPathComponent("src"), root = t.appendingPathComponent("root"), zip = t.appendingPathComponent("x.orqbackup")
        put(src, "manifest.json", #"{"format":1,"createdAt":"2026-01-01T00:00:00Z","orqVersion":"v1","parts":["partituras"]}"#)
        put(src, "partituras/p.orqpartitura", "p")
        put(src, "partituras/.removed/q-1.orqpartitura", "q")
        let z = Process(); z.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); z.arguments = ["-c", "-k", "--norsrc", src.path, zip.path]
        try z.run(); z.waitUntilExit()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await DataBackup.stage(root: root, from: zip, dryRun: false)
        #expect(DataBackup.applyPending(Paths(root: root)))
        LegacyOrq.renameLegacyHerds(in: root)   // what collied does right after applyPending
        #expect(read(root, "herds/p.collieherd") == "p")
        #expect(read(root, "herds/.removed/q-1.collieherd") == "q")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("partituras").path))
    }

    @Test func legacyRepoPaddockKeepsOrqMemory() async throws {
        let repo = try await makeRepo()
        put(repo, ".orq/memory/g.md", "pasture")   // the pasture's memory: never committed
        let mem = MemoryService(globalDir: tempDir())
        for name in ["a", "b"] {
            var f = try await PaddockManager.create(name: name, repoRoot: repo, createdBy: nil)
            #expect(f.path.hasSuffix("/.orq/paddocks/\(name)"))
            let paddock = URL(fileURLWithPath: f.path)
            let got = await mem.repo(for: f.path).store.dir.path
            #expect(got.hasSuffix("/.orq/paddocks/\(name)/.orq/memory"), "\(got)")   // the paddock of an Orq repo keeps .orq
            put(paddock, ".orq/memory/\(name).md", name)
            _ = try await PaddockManager.land(&f, mode: .merge, message: nil)   // the second land is not blocked by .orq/memory
            #expect(read(repo, ".orq/memory/\(name).md") == name)
            #expect(LegacyOrq.repoDirName(repoRoot: repo) == ".orq")
            #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(".collie").path))
        }
        #expect(read(repo, ".orq/memory/g.md") == "pasture")
    }

    @Test func repoDirKeepsLegacy() throws {
        let r = tempDir(); defer { try? FileManager.default.removeItem(at: r) }
        #expect(LegacyOrq.repoDirName(repoRoot: r) == ".collie")
        put(r, ".orq/memory/a.md")
        #expect(LegacyOrq.repoDirName(repoRoot: r) == ".orq")
        put(r, ".collie/memory/a.md")
        #expect(LegacyOrq.repoDirName(repoRoot: r) == ".collie")
    }

    @Test func pastureDetectsBothDirs() {
        #expect(LegacyOrq.pasture(ofPaddockPath: "/r/.orq/floors/f") == "/r")
        #expect(LegacyOrq.pasture(ofPaddockPath: "/r/.collie/paddocks/f") == "/r")
        #expect(LegacyOrq.pasture(ofPaddockPath: "/r/src") == nil)
    }

    @Test func applierRefusesLegacyBranch() async throws {
        let repo = try await makeRepo()
        #expect(try await GitRunner.run(["branch", "orq/w"], in: repo).status == 0)   // an Orq paddock's branch
        try await withDaemon { d, p in
            let r = try await send(p, Request(id: "a", token: d.adminToken, command: "herd.apply",
                args: ["id": .string("investigar-bug"), "name": .string("w"), "cwd": .string(repo.path), "paddock": .bool(true)]),
                timeoutSeconds: 60)
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("a branch orq/w já existe") == true, "\(r)")
        }
    }

    @Test func backupManifestReadsLegacyKey() throws {
        let t = tempDir(); defer { try? FileManager.default.removeItem(at: t) }
        put(t, "old.json", #"{"format":1,"createdAt":"2026-01-01T00:00:00Z","orqVersion":"v1","parts":["memory"]}"#)
        let m = try #require(DataBackup.manifest(t.appendingPathComponent("old.json")))
        #expect(m.collieVersion == "v1" && m.parts == ["memory"])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let json = String(decoding: try enc.encode(m), as: UTF8.self)
        #expect(json.contains("\"collieVersion\"") && !json.contains("orqVersion"))
    }

    /// A machine that ran a 4R before the herding vocabulary left `partituras/*.colliepartitura`: they move to `herds/`.
    @Test func migratesColliePartituraNames() throws {
        let t = tempDir(); defer { try? FileManager.default.removeItem(at: t) }
        let new = t.appendingPathComponent("Collie")
        put(new, "partituras/x.colliepartitura", "x"); put(new, "partituras/o.orqpartitura", "o")
        put(new, "partituras/.removed/y-1.colliepartitura", "y")
        put(new, "partituras/c.colliepartitura", "old c"); put(new, "herds/c.collieherd", "new c")
        LegacyOrq.renameLegacyHerds(in: new)
        LegacyOrq.renameLegacyHerds(in: new)   // idempotent
        #expect(read(new, "herds/x.collieherd") == "x" && read(new, "herds/o.collieherd") == "o")
        #expect(read(new, "herds/.removed/y-1.collieherd") == "y")
        #expect(read(new, "herds/c.collieherd") == "new c" && read(new, "partituras/c.colliepartitura") == "old c")   // never clobbered
        #expect(read(new, "partituras/x.colliepartitura") == nil)
    }

    /// A Collie backup from before the vocabulary (`partituras` part) restores into `herds/`.
    @Test func backupReadsLegacyDirs() async throws {
        let t = tempDir(); defer { try? FileManager.default.removeItem(at: t) }
        let src = t.appendingPathComponent("src"), root = t.appendingPathComponent("root"), zip = t.appendingPathComponent("x.colliebackup")
        put(src, "manifest.json", #"{"format":1,"createdAt":"2026-01-01T00:00:00Z","collieVersion":"v1","parts":["partituras"]}"#)
        put(src, "partituras/p.colliepartitura", "p")
        let z = Process(); z.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); z.arguments = ["-c", "-k", "--norsrc", src.path, zip.path]
        try z.run(); z.waitUntilExit()
        put(root, "herds/mine.collieherd", "mine")   // the current part moves aside, as for any part
        _ = try await DataBackup.stage(root: root, from: zip, dryRun: false)
        #expect(DataBackup.applyPending(Paths(root: root)))
        LegacyOrq.renameLegacyHerds(in: root)
        #expect(read(root, "herds/p.collieherd") == "p" && read(root, "herds/mine.collieherd") == nil)
        let replaced = try FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasPrefix(".replaced-") }
        #expect(replaced.map { read(root, "\($0)/herds/mine.collieherd") } == "mine")
    }

    /// `.collie/floors/f` (a paddock made before the vocabulary) is still a paddock of its pasture; a new one goes to
    /// `.collie/paddocks/`.
    @Test func repoDirFloorsLegacy() async throws {
        #expect(LegacyOrq.pasture(ofPaddockPath: "/r/.collie/floors/f") == "/r")
        #expect(LegacyOrq.pasture(ofPaddockPath: "/r/.collie/floors/f/src") == "/r")
        #expect(LegacyOrq.pasture(ofPaddockPath: "/r/.orq/floors/f") == "/r")
        let repo = try await makeRepo()
        let f = try await PaddockManager.create(name: "n", repoRoot: repo, createdBy: nil)
        #expect(f.path.hasSuffix("/.collie/paddocks/n") && LegacyOrq.pasture(ofPaddockPath: f.path) == f.repoRoot, "\(f.path)")
    }

    /// Registries written before the vocabulary say `floorId`.
    @Test func legacyFloorIdsDecode() throws {
        let id = UUID()
        func swap<T: Codable>(_ x: T) throws -> T {
            let s = String(decoding: try JSONEncoder().encode(x), as: UTF8.self)
            #expect(s.contains("\"paddockId\""))
            return try JSONDecoder().decode(T.self, from: Data(s.replacingOccurrences(of: "\"paddockId\"", with: "\"floorId\"").utf8))
        }
        let a = Artifact(id: UUID(), kind: .agent, title: "t", fileId: nil, node: nil, paddockId: id, by: "x", at: Date(timeIntervalSince1970: 1),
                         version: 1, folder: "f", stamp: nil, warnings: [])
        #expect(try swap(a) == a)
        let file = DesignService.File(id: "i", name: "n", editLink: "e", viewLink: nil, createdAt: Date(timeIntervalSince1970: 1), paddockId: id)
        #expect(try swap(file).paddockId == id)
        let e = DesignSystemEvent(at: Date(timeIntervalSince1970: 1), kind: "activated", version: nil, scope: "floor:f", by: "app", reason: "r",
                                  snapshot: nil, files: [], paddockId: id)
        #expect(try swap(e) == e)   // its scope stays as it was written
    }
}
