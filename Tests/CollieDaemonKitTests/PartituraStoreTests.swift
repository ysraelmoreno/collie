import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

extension CommandRouter {
    /// Test fixture: a panel (and cords to terminals) put straight in the workspace.
    func testAdd(_ p: Panel, cords: [UUID] = []) {
        ws.panels.append(p)
        for c in cords { ws.connections.append(Connection(a: c, b: p.id)) }
    }
}

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "a", token: d.adminToken, command: cmd, args: args), timeoutSeconds: 60)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, maestro: Bool = false) async throws -> (id: String, token: String) {
    let r = try await admin(d, p, "admin.spawn", ["name": .string(name), "preset": .string("shell"), "cwd": .string("/tmp"), "maestro": .bool(maestro)])
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return (id, try await tokenOf(d, id))
}
private func asTerm(_ p: Paths, _ t: (id: String, token: String), _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "t", terminalId: t.id, token: t.token, command: cmd, args: args), timeoutSeconds: 60)
}
private func obj(_ r: Response) -> [String: JSONValue] { if case .object(let o)? = r.result { o } else { [:] } }
private func ids(_ r: Response) -> [String] {
    guard case .array(let a)? = r.result else { return [] }
    return a.compactMap { if case .object(let o) = $0, case .string(let i)? = o["id"] { i } else { nil } }
}
private func tmpDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("collie-pt-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
private func sample(_ id: String = "mine", name: String = "Minha") -> Partitura {
    Partitura(id: id, name: name, summary: "s", terminals: [PartituraTerminal(key: "a", preset: .shell), PartituraTerminal(key: "b", preset: .shell)],
              panels: [PartituraPanel(key: "web", pluginId: "browser", state: ["url": .string("https://x.dev")])], cords: [["a", "b"], ["a", "web"]])
}

@Suite(.serialized) struct PartituraStoreTests {
    @Test func factoryListedAndReadOnly() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = PartituraStore(dir: dir)
        #expect(await s.list().map(\.id) == Partitura.factory.sorted { $0.name.lowercased() < $1.name.lowercased() }.map(\.id))
        #expect(await s.get("feature-fullstack")?.builtIn == true)
        var f = Partitura.factory[0]; f.name = "Outro"
        await #expect(throws: ProtocolError.self) { try await s.put(f) }
        await #expect(throws: ProtocolError.self) { try await s.setAside(f.id) }
        #expect(await s.get(f.id)?.name != "Outro")
    }

    @Test func putGetListAtomic0600() async throws {
        let dir = tmpDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = PartituraStore(dir: dir)
        try await s.put(sample())
        let got = await s.get("mine"), all = await s.list()
        #expect(got == sample() && all.contains { $0.id == "mine" })
        let f = dir.appendingPathComponent("mine.colliepartitura")
        #expect(try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? Int == 0o600)
        #expect(await s.get("../x") == nil)
        var bad = sample("bad"); bad.cords = [["a", "zz"]]
        await #expect(throws: ProtocolError.self) { try await s.put(bad) }
    }

    @Test func removeSetsAside() async throws {
        try await withDaemon { d, p in
            try await d.router.partituras.put(sample())
            let dir = p.root.appendingPathComponent("partituras")
            #expect(try await admin(d, p, "partitura.remove", ["id": .string("mine")]).ok)
            #expect(await d.router.partituras.get("mine") == nil)
            let kept = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(".removed").path)
            #expect(kept.count == 1 && kept[0].hasPrefix("mine-") && kept[0].hasSuffix(".colliepartitura"))
            // set aside twice in the same millisecond: both kept
            for _ in 0..<2 { try await d.router.partituras.put(sample()); try await d.router.partituras.setAside("mine") }
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(".removed").path).count == 3)
            #expect(try await admin(d, p, "partitura.remove", ["id": .string("mine")]).error?.code == .notFound)
            #expect(try await admin(d, p, "partitura.remove", ["id": .string("investigar-bug")]).error?.code == .invalidArgs)
        }
    }

    @Test func saveFromCanvas() async throws {
        try await withDaemon { d, p in
            _ = try await admin(d, p, "admin.spawn", ["name": .string("feat-api"), "preset": .string("shell"), "cwd": .string("/tmp")])
            _ = try await admin(d, p, "admin.spawn", ["name": .string("feat-ui"), "preset": .string("shell"), "cwd": .string("/tmp")])
            #expect(try await admin(d, p, "admin.connect", ["a": .string("feat-api"), "b": .string("feat-ui")]).ok)
            #expect(try await admin(d, p, "panel.open", ["plugin": .string("browser"), "name": .string("feat-web"), "placement": .string("canvas"),
                                                         "url": .string("https://x.dev")]).ok)
            #expect(try await admin(d, p, "admin.connect", ["a": .string("feat-ui"), "b": .string("feat-web")]).ok)
            let frames: JSONValue = .object([
                "feat-api": .object(["x": 100, "y": 50, "w": 640, "h": 400]), "feat-ui": .object(["x": 800, "y": 50, "w": 640, "h": 400]),
                "feat-web": .object(["x": 800, "y": 500, "w": 640, "h": 400])])
            let r = try await admin(d, p, "partitura.save", ["name": .string("Minha Feature"), "terminals": .string("feat-api, feat-ui"),
                                                            "panels": .array([.string("feat-web")]), "frames": frames,
                                                            "roles": .object(["feat-api": .string("faça a API")])])
            #expect(r.ok, "\(r)")
            #expect(obj(r)["id"] == .string("minha-feature") && obj(r)["warnings"] == .array([]))
            let pt = try #require(await d.router.partituras.get("minha-feature"))
            #expect(pt.terminals.map(\.key) == ["api", "ui"] && pt.panels.map(\.key) == ["web"])
            #expect(pt.terminals[0].role == "faça a API" && pt.terminals[1].role == nil)
            #expect(Set(pt.cords.map { Set($0) }) == [["api", "ui"], ["ui", "web"]])
            #expect(pt.panels[0].state == ["url": .string("https://x.dev"), "storage": .string("isolated")])
            #expect(pt.terminals[0].frame == PartituraFrame(x: 0, y: 0, w: 640, h: 400))
            #expect(pt.panels[0].frame == PartituraFrame(x: 700, y: 450, w: 640, h: 400))
            // again: refused without replace, accepted with it
            let again: [String: JSONValue] = ["name": .string("Minha Feature"), "terminals": .string("feat-api")]
            #expect(try await admin(d, p, "partitura.save", again).error?.code == .invalidArgs)
            #expect(try await admin(d, p, "partitura.save", again.merging(["replace": .bool(true)]) { $1 }).ok)
            #expect(try await admin(d, p, "partitura.save", ["name": .string("X"), "terminals": .string("nope")]).error?.code == .notFound)
        }
    }

    @Test func saveKeepsOnlyAllowedState() async throws {
        let fid = "file-id-123", link = "https://www.figma.com/design/SECRETLINK"
        try await withDaemon(configure: { c in
            let dir = c.paths.root.appendingPathComponent("design")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data(#"[{"id":"\#(fid)","name":"Feature","editLink":"\#(link)","createdAt":"2026-10-24T00:00:00Z"},{"id":"f2","name":".oculto","editLink":"\#(link)","createdAt":"2026-10-24T00:00:00Z"}]"#.utf8)
                .write(to: dir.appendingPathComponent("files.json"))
        }) { d, p in
            let t = try await term(d, p, "W")
            let tid = UUID(uuidString: t.id)!
            await d.router.testAdd(Panel(id: UUID(), name: "des", pluginId: "design", placement: .canvas,
                                         state: ["file": .string(fid), "storage": .string("workspace"), "token": .string("secret")]), cords: [tid])
            await d.router.testAdd(Panel(id: UUID(), name: "gone", pluginId: "design", placement: .canvas, state: ["file": .string("missing")]), cords: [tid])
            await d.router.testAdd(Panel(id: UUID(), name: "phone", pluginId: "device", placement: .canvas,
                                         state: ["serial": .string("ABC123")]), cords: [tid])
            await d.router.testAdd(Panel(id: UUID(), name: "web", pluginId: "browser", placement: .canvas,
                                         state: ["url": .string("https://x.dev"), "extra": .string("x"), "cwd": .string("/Users/me")]), cords: [tid])
            await d.router.testAdd(Panel(id: UUID(), name: "local", pluginId: "browser", placement: .canvas,
                                         state: ["url": .string("file:///etc/passwd")]), cords: [tid])
            await d.router.testAdd(Panel(id: UUID(), name: "dot", pluginId: "design", placement: .canvas, state: ["file": .string("f2")]), cords: [tid])
            await d.router.testAdd(Panel(id: UUID(), name: "auth", pluginId: "browser", placement: .canvas,
                                         state: ["url": .string("https://user:pass@x.dev/a?q=1")]), cords: [tid])
            let r = try await admin(d, p, "partitura.save", ["name": .string("Estado"), "terminals": .string("W"),
                                                            "panels": .string("des,gone,phone,web,local,dot,auth")])
            #expect(r.ok, "\(r)")
            guard case .array(let w)? = obj(r)["warnings"] else { Issue.record("\(r)"); return }
            let warnings = w.compactMap { if case .string(let s) = $0 { s } else { nil } }
            #expect(warnings.contains("painel phone (device) não entra em partituras") && warnings.count == 6, "\(warnings)")
            #expect(warnings.contains { $0.hasPrefix("painel dot: o nome do arquivo de design não cabe") }, "\(warnings)")
            #expect(warnings.contains("painel auth: usuário e senha tirados do endereço"), "\(warnings)")
            #expect(warnings.contains { $0.hasPrefix("painel auth: o endereço tem parâmetros") }, "\(warnings)")
            let pt = try #require(await d.router.partituras.get("estado"))
            func state(_ k: String) -> [String: JSONValue]? { pt.panels.first { $0.key == k }?.state }
            #expect(state("des") == ["file": .string("Feature"), "storage": .string("workspace")])
            #expect(state("gone") == [:] && state("web") == ["url": .string("https://x.dev")] && state("local") == [:])
            #expect(state("dot") == [:] && state("auth") == ["url": .string("https://x.dev/a?q=1")])
            #expect(pt.panels.map(\.key).contains("phone") == false)
            let raw = try String(decoding: PartituraFormat.encode(pt), as: UTF8.self)
            for leak in [fid, link, "ABC123", "secret", "/Users/me", "passwd", "user:pass"] { #expect(!raw.contains(leak), "\(leak)") }
            _ = try PartituraFormat.decode(Data(raw.utf8))
        }
    }

    @Test func maestroSavesOnlyReach() async throws {
        try await withDaemon { d, p in
            let m = try await term(d, p, "M", maestro: true)
            _ = try await term(d, p, "in")
            _ = try await term(d, p, "out")
            #expect(try await admin(d, p, "admin.connect", ["a": .string("M"), "b": .string("in")]).ok)
            let bad = try await asTerm(p, m, "partitura.save", ["name": .string("X"), "terminals": .string("M,out")])
            #expect(bad.error?.code == .notConnected, "\(bad)")
            let ok = try await asTerm(p, m, "partitura.save", ["name": .string("Equipe"), "terminals": .string("M,in"),
                                                             "frames": .object(["M": .object(["x": 0, "y": 0, "w": 10, "h": 10])])])
            #expect(ok.ok, "\(ok)")
            let pt = try #require(await d.router.partituras.get("equipe"))
            #expect(pt.terminals.map(\.isMaestro) == [true, false] && pt.terminals.allSatisfy { $0.frame == nil } && pt.cords == [["m", "in"]])
            #expect(ids(try await asTerm(p, m, "partitura.list")).contains("equipe"))
            #expect(try await asTerm(p, m, "partitura.get", ["id": .string("equipe")]).ok)
        }
    }

    @Test func terminalsCannotImportOrRemove() async throws {
        try await withDaemon { d, p in
            let m = try await term(d, p, "M", maestro: true), s = try await term(d, p, "S")
            try await d.router.partituras.put(sample())
            for cmd in ["partitura.import", "partitura.remove", "partitura.export"] {
                let args: [String: JSONValue] = ["id": .string("mine"), "json": .string("{}")]
                #expect(try await asTerm(p, m, cmd, args).error?.code == .unauthorized, Comment(rawValue: cmd))
            }
            #expect(try await asTerm(p, s, "partitura.list").error?.code == .notMaestro)
            #expect(await d.router.partituras.get("mine") != nil)
        }
    }

    @Test func importRejectsAndKeepsLibrary() async throws {
        try await withDaemon { d, p in
            try await d.router.partituras.put(sample())
            let before = await d.router.partituras.list()
            func doc(_ edit: (inout [String: Any]) -> Void) throws -> String {
                var o = try #require(try JSONSerialization.jsonObject(with: PartituraFormat.encode(sample("novo", name: "Novo"))) as? [String: Any])
                edit(&o)
                return String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self)
            }
            let big = try doc { $0["summary"] = String(repeating: "x", count: 300 * 1024) }
            let docs = [big, try doc { $0["format"] = 2 }, try doc { $0["cords"] = [["a", "zz"]] },
                        try doc { $0["terminals"] = [["key": "a", "preset": "custom", "command": "x\u{1b}[2Jy"]] }, "not json"]
            for j in docs {
                let r = try await admin(d, p, "partitura.import", ["json": .string(j)])
                #expect(!r.ok && r.error?.code == .invalidArgs, "\(r.error?.message ?? "ok")")
            }
            #expect(await d.router.partituras.list() == before)
            #expect(await d.router.partituras.get("novo") == nil)
            // an id already saved is not replaced unless asked
            let dup = try doc { $0["id"] = "mine" }
            #expect(try await admin(d, p, "partitura.import", ["json": .string(dup)]).error?.code == .invalidArgs)
            #expect(await d.router.partituras.list() == before)
        }
    }

    @Test func exportImportRoundTrip() async throws {
        try await withDaemon { d, p in
            let pt = sample()
            try await d.router.partituras.put(pt)
            let ex = try await admin(d, p, "partitura.export", ["id": .string("mine")])
            guard case .string(let json)? = obj(ex)["json"] else { Issue.record("\(ex)"); return }
            _ = try PartituraFormat.decode(Data(json.utf8))
            #expect(try await admin(d, p, "partitura.remove", ["id": .string("mine")]).ok)
            let im = try await admin(d, p, "partitura.import", ["json": .string(json)])
            #expect(im.ok && obj(im)["id"] == .string("mine"), "\(im)")
            #expect(await d.router.partituras.get("mine") == pt)
            guard case .object(let prev)? = obj(im)["preview"], case .array(let ts)? = prev["terminals"] else { Issue.record("no preview"); return }
            #expect(ts.count == 2 && prev["wantsFloor"] == .bool(false))
            // a factory one exports and re-imports as "factory cannot be replaced"
            guard case .string(let f)? = obj(try await admin(d, p, "partitura.export", ["id": .string("investigar-bug")]))["json"] else { return }
            #expect(try await admin(d, p, "partitura.import", ["json": .string(f), "replace": .bool(true)]).error?.code == .invalidArgs)
        }
    }
}
