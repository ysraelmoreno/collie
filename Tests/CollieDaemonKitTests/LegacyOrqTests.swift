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

    @Test func renamesPartituraFiles() throws {
        let t = tempDir(); defer { try? FileManager.default.removeItem(at: t) }
        let old = t.appendingPathComponent("Orq"), new = t.appendingPathComponent("Collie")
        put(old, "partituras/x.orqpartitura", "x")
        put(old, "partituras/.removed/y-1.orqpartitura", "y")
        #expect(LegacyOrq.migrateDataRoot(old: old, new: new) { false } == .moved)
        #expect(read(new, "partituras/x.colliepartitura") == "x")
        #expect(read(new, "partituras/.removed/y-1.colliepartitura") == "y")
        #expect(read(new, "partituras/x.orqpartitura") == nil)
    }

    @Test func repoDirKeepsLegacy() throws {
        let r = tempDir(); defer { try? FileManager.default.removeItem(at: r) }
        #expect(LegacyOrq.repoDirName(repoRoot: r) == ".collie")
        put(r, ".orq/memory/a.md")
        #expect(LegacyOrq.repoDirName(repoRoot: r) == ".orq")
        put(r, ".collie/memory/a.md")
        #expect(LegacyOrq.repoDirName(repoRoot: r) == ".collie")
    }

    @Test func groundDetectsBothDirs() {
        #expect(LegacyOrq.ground(ofFloorPath: "/r/.orq/floors/f") == "/r")
        #expect(LegacyOrq.ground(ofFloorPath: "/r/.collie/floors/f") == "/r")
        #expect(LegacyOrq.ground(ofFloorPath: "/r/src") == nil)
    }

    @Test func applierRefusesLegacyBranch() async throws {
        let repo = try await makeRepo()
        #expect(try await GitRunner.run(["branch", "orq/w"], in: repo).status == 0)   // an Orq floor's branch
        try await withDaemon { d, p in
            let r = try await send(p, Request(id: "a", token: d.adminToken, command: "partitura.apply",
                args: ["id": .string("investigar-bug"), "name": .string("w"), "cwd": .string(repo.path), "floor": .bool(true)]),
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
}
