import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

@Suite struct ArtifactFolderPathTests {
    @Test func normalizes() throws {
        #expect(try ArtifactFolder.normalize("") == nil && ArtifactFolder.normalize("   ") == nil)
        #expect(try ArtifactFolder.normalize(" Cliente / Landing /v2 ") == "Cliente/Landing/v2")
        #expect(try ArtifactFolder.normalize(String(repeating: "a", count: 40)) == String(repeating: "a", count: 40))
    }

    @Test func refusesBadPaths() {
        for bad in ["/Cliente", "Cliente/", "a//b", "a/b/c/d", String(repeating: "a", count: 41), "a/\u{7}b", "a\nb", "a/ /b",
                    "a\u{200B}b", "\u{FEFF}a", "a\u{2060}", "a\u{202E}b", "a/\u{2067}b", ".", "a/..", "../a", "a/./b"] {
            #expect(throws: ProtocolError.self, "\(bad)") { try ArtifactFolder.normalize(bad) }
        }
    }

    @Test func comparesCaseInsensitively() {
        #expect(ArtifactFolder.same("Cliente/Landing", "cliente/LANDING") && !ArtifactFolder.same("Cliente", "Clientes"))
        #expect(ArtifactFolder.isUnder("cliente/landing/v2", "Cliente") && ArtifactFolder.isUnder("Cliente", "cliente"))
        #expect(!ArtifactFolder.isUnder("Clientes/x", "Cliente") && !ArtifactFolder.isUnder(nil, "Cliente"))
        // the panel's rule (lowercased), not Foundation's folding (ß = SS)
        #expect(!ArtifactFolder.same("Straße", "STRASSE") && ArtifactFolder.same("ÁRVORE", "árvore"))
    }
}

@Suite struct ArtifactFolderStoreTests {
    private func tmp() -> URL { URL(fileURLWithPath: "/tmp/collie-fold-\(UUID().uuidString.prefix(8))") }
    private let page = Data("<p>x</p>".utf8)

    @Test func addAndMoveKeepExistingSpelling() async throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let s = ArtifactStore(root: root)
        let a = try await s.addAgent(page: page, title: "A", paddockId: nil, by: "W", inFolder: "Cliente/Landing")
        let b = try await s.addAgent(page: page, title: "B", paddockId: nil, by: "W", inFolder: "cliente/landing/v2")
        #expect(a.inFolder == "Cliente/Landing" && b.inFolder == "Cliente/Landing/v2")
        try await s.move(a.id, to: nil)
        #expect(try await ArtifactStore(root: root).get(a.id).inFolder == nil)
        let f = try await s.folders()
        #expect(f.map(\.path) == ["Cliente", "Cliente/Landing", "Cliente/Landing/v2"])
        #expect(f.map(\.count) == [0, 0, 1] && f.map(\.total) == [1, 1, 1])
    }

    @Test func oldRecordsDecodeWithoutFolder() throws {
        let a = Artifact(id: UUID(), kind: .agent, title: "T", fileId: nil, node: nil, paddockId: nil, by: "M", at: Date(timeIntervalSince1970: 0),
                         version: 1, folder: "x", stamp: nil, warnings: [])
        let old = try JSONEncoder().encode(a)
        #expect(!String(decoding: old, as: UTF8.self).contains("inFolder"))
        let d = try JSONDecoder().decode(Artifact.self, from: old)
        #expect(d.inFolder == nil && d.byId == nil)
        var b = a; b.inFolder = "Cliente"; b.byId = UUID()
        #expect(try JSONDecoder().decode(Artifact.self, from: try JSONEncoder().encode(b)) == b)
    }

    @Test func createListsEmptyFolderInOrder() async throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let s = ArtifactStore(root: root)
        _ = try await s.addAgent(page: page, title: "A", paddockId: nil, by: "W", inFolder: "Zeta")
        try await s.createFolder("Landing"); try await s.createFolder("Cliente")
        await #expect(throws: ProtocolError.self) { try await s.createFolder("cliente") }
        try await s.setFolder("Zeta", color: "#ff0000", pinned: true, presentation: nil, order: nil)
        // explicit first in their order, then implicit by name
        let f = try await ArtifactStore(root: root).folders()
        #expect(f.map(\.path) == ["Landing", "Cliente", "Zeta"])
        #expect(f[2].pinned && f[2].color == "#ff0000" && f[0].count == 0)
        let json = try String(contentsOf: root.appendingPathComponent("artifacts/folders.json"), encoding: .utf8)
        #expect(json.contains("Landing"))
    }

    @Test func renameRewritesPrefix() async throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let s = ArtifactStore(root: root)
        let a = try await s.addAgent(page: page, title: "A", paddockId: nil, by: "W", inFolder: "Cliente")
        let b = try await s.addAgent(page: page, title: "B", paddockId: nil, by: "W", inFolder: "Cliente/Landing")
        let c = try await s.addAgent(page: page, title: "C", paddockId: nil, by: "W", inFolder: "Clientes")
        try await s.createFolder("Cliente/Vazia")
        try await s.renameFolder("cliente", to: "Marca")
        let again = ArtifactStore(root: root)
        let moved = [try await again.get(a.id).inFolder, try await again.get(b.id).inFolder, try await again.get(c.id).inFolder]
        #expect(moved == ["Marca", "Marca/Landing", "Clientes"])
        #expect(try await again.folders().map(\.path).contains("Marca/Vazia"))
        // into an existing one, too deep, or under itself: refused, nothing changed
        await #expect(throws: ProtocolError.self) { try await s.renameFolder("Marca", to: "Clientes") }
        await #expect(throws: ProtocolError.self) { try await s.renameFolder("Marca", to: "x/y/z") }   // Marca/Landing → 4 levels
        await #expect(throws: ProtocolError.self) { try await s.renameFolder("Marca", to: "Marca/Sub") }
        await #expect(throws: ProtocolError.self) { try await s.renameFolder("Nada", to: "Outra") }
        #expect(try await s.get(b.id).inFolder == "Marca/Landing")
        // case-only rename of the same folder
        try await s.renameFolder("Marca", to: "MARCA")
        #expect(try await s.get(b.id).inFolder == "MARCA/Landing")
    }

    @Test func removeOnlyEmptyOrMoveTo() async throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let s = ArtifactStore(root: root)
        let a = try await s.addAgent(page: page, title: "A", paddockId: nil, by: "W", inFolder: "Cliente/Landing")
        try await s.createFolder("Vazia")
        try await s.removeFolder("vazia", moveTo: nil)
        await #expect(throws: ProtocolError.self) { try await s.removeFolder("Cliente", moveTo: nil) }   // not empty
        await #expect(throws: ProtocolError.self) { try await s.removeFolder("Cliente", moveTo: .some("Cliente/Landing")) }
        try await s.removeFolder("Cliente", moveTo: .some("Arquivo"))
        #expect(try await s.get(a.id).inFolder == "Arquivo")
        #expect(try await s.list().count == 1)   // never deletes artifacts
        try await s.removeFolder("Arquivo", moveTo: .some(nil))
        #expect(try await s.get(a.id).inFolder == nil)
        #expect(try await s.folders().isEmpty)
    }

    @Test func corruptFoldersFileNeverBlocksAdd() async throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("folders.json"))
        let s = ArtifactStore(root: root)
        let a = try await s.addAgent(page: page, title: "A", paddockId: nil, by: "W", inFolder: "Cliente")
        #expect(a.inFolder == "Cliente")
        #expect(try await s.folders().map(\.path) == ["Cliente"])
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("folders.json.bad-") }
        #expect(aside.count == 1)
        #expect(try FileManager.default.contents(atPath: dir.appendingPathComponent(aside[0]).path) == Data("{not json".utf8))
    }

    @Test func presentationOrder() async throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let s = ArtifactStore(root: root)
        var ids: [UUID] = []
        for t in ["1", "2", "3"] { ids.append(try await s.addAgent(page: page, title: t, paddockId: nil, by: "W", inFolder: "Deck").id) }
        #expect(try await s.folders()[0].items == ids)   // by creation
        try await s.setFolder("Deck", color: nil, pinned: nil, presentation: true, order: [ids[2], ids[0]])
        let f = try await s.folders()[0]
        #expect(f.presentation && f.items == [ids[2], ids[0], ids[1]])   // listed first, the rest by creation
    }
}

// MARK: commands

private struct Term { var id: String; var token: String }
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 60)
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:], cwd: String? = nil) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }, cwd: cwd),
                                    to: p.socket, timeoutSeconds: 60)
}
private func spawn(_ d: Daemon, _ p: Paths, _ name: String, cwd: String) async throws -> Term {
    let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn",
        args: ["name": .string(name), "preset": "shell", "cwd": .string(cwd)]), to: p.socket, timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func obj(_ r: Response) -> [String: JSONValue] { if case .object(let o)? = r.result { o } else { [:] } }

@Suite(.serialized) struct ArtifactFolderCommandTests {
    private func withProject(_ body: (Daemon, Paths, URL) async throws -> Void) async throws {
        let proj = URL(fileURLWithPath: "/tmp/collie-foldc-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: proj) }
        try Data("<h1>x</h1>".utf8).write(to: proj.appendingPathComponent("p.html"))
        try await withDaemon { d, p in try await body(d, p, proj) }
    }
    private func add(_ p: Paths, _ t: Term, _ proj: URL, _ extra: [String: String] = [:]) async throws -> String {
        let r = try await call(p, t, "artifact.add", ["path": "p.html"].merging(extra) { _, b in b }, cwd: proj.path)
        guard case .string(let id)? = obj(r)["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
        return id
    }
    private func folder(_ d: Daemon, _ p: Paths, _ id: String) async throws -> JSONValue? { obj(try await admin(d, p, "artifact.get", ["id": id]))["folder"] }

    @Test func addWithFolderAndLotDefault() async throws {
        try await withProject { d, p, proj in
            let a = try await spawn(d, p, "A", cwd: proj.path)
            #expect(try await folder(d, p, try await add(p, a, proj, ["folder": "Cliente/Landing"])) == .string("Cliente/Landing"))
            #expect(try await folder(d, p, try await add(p, a, proj)) == .null)
            #expect(try await call(p, a, "artifact.add", ["path": "p.html", "folder": "a/b/c/d"], cwd: proj.path).error?.code == .invalidArgs)
            #expect(try await admin(d, p, "lot.create", ["name": "Login", "members": "A"]).ok)
            #expect(try await folder(d, p, try await add(p, a, proj)) == .string("Login"))
            #expect(try await folder(d, p, try await add(p, a, proj, ["folder": "Outra"])) == .string("Outra"))   // explicit wins
            let list = try await call(p, a, "artifact.folders")
            guard case .array(let fs)? = list.result else { Issue.record("\(list)"); return }
            #expect(fs.count == 4, "\(fs)")   // Cliente, Cliente/Landing, Login, Outra
        }
    }

    @Test func newRecordsFolderOnThePreview() async throws {
        try await withProject { d, p, proj in
            let a = try await spawn(d, p, "A", cwd: proj.path)
            #expect(try await admin(d, p, "lot.create", ["name": "Login", "members": "A"]).ok)
            let r = try await call(p, a, "artifact.new", ["kind": "doc"])
            let r2 = try await call(p, a, "artifact.new", ["kind": "doc", "folder": "Cliente"])
            #expect(r.ok && r2.ok, "\(r) \(r2)")
            let s = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "ui.snapshot"), to: p.socket, timeoutSeconds: 60)
            let snap = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(s.result))
            let folders = Set(snap.panels.filter { $0.pluginId == "preview" }.compactMap { if case .string(let f)? = $0.state["folder"] { f } else { nil } })
            #expect(folders == ["Login", "Cliente"], "\(folders)")
        }
    }

    @Test func agentMovesOnlyItsOwn() async throws {
        try await withProject { d, p, proj in
            let a = try await spawn(d, p, "A", cwd: proj.path), b = try await spawn(d, p, "B", cwd: proj.path)
            let mine = try await add(p, a, proj), theirs = try await add(p, b, proj)
            #expect(try await call(p, a, "artifact.move", ["id": mine, "folder": "Cliente"]).ok)
            #expect(try await folder(d, p, mine) == .string("Cliente"))
            #expect(try await call(p, a, "artifact.move", ["id": theirs, "folder": "Cliente"]).error?.code == .unauthorized)
            #expect(try await admin(d, p, "artifact.move", ["id": theirs, "folder": "Cliente"]).ok)
            #expect(try await admin(d, p, "artifact.move", ["id": theirs, "folder": ""]).ok)
            #expect(try await folder(d, p, theirs) == .null)
        }
    }

    @Test func folderOpsAreAppOnly() async throws {
        try await withProject { d, p, proj in
            let a = try await spawn(d, p, "A", cwd: proj.path)
            for (c, args) in [("artifact.folder.create", ["path": "X"]), ("artifact.folder.rename", ["path": "X", "to": "Y"]),
                              ("artifact.folder.remove", ["path": "X"]), ("artifact.folder.set", ["path": "X", "pin": "true"])] {
                #expect(try await call(p, a, c, args).error?.code == .unauthorized, "\(c)")
            }
            #expect(try await admin(d, p, "artifact.folder.create", ["path": "Cliente"]).ok)
            let id = try await add(p, a, proj, ["folder": "Cliente"])
            #expect(try await admin(d, p, "artifact.folder.remove", ["path": "Cliente"]).error?.code == .invalidArgs)
            #expect(try await admin(d, p, "artifact.folder.rename", ["path": "Cliente", "to": "Marca"]).ok)
            #expect(try await folder(d, p, id) == .string("Marca"))
            #expect(try await admin(d, p, "artifact.folder.set", ["path": "Marca", "present": "true", "order": id]).ok)
            #expect(try await admin(d, p, "artifact.folder.remove", ["path": "Marca", "move-to": ""]).ok)
            #expect(try await folder(d, p, id) == .null)
        }
    }
}
