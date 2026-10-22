import Testing
import Foundation
import Synchronization
import OrqCore
import OrqProtocol
import OrqClient
@testable import OrqDaemonKit

private let htmlImport = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/html-import")

/// The fake engine (as ArtifactTests' `Fake`).
private struct Fig {
    let dir = URL(fileURLWithPath: "/tmp/orq-imp-\(UUID().uuidString.prefix(8))")
    var log: URL { dir.appendingPathComponent("calls.log") }
    var flags: URL { dir.appendingPathComponent("flags") }
    init() throws {
        let fixtures = htmlImport.deletingLastPathComponent(), bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("figcraft-cli"),
                                                   withDestinationURL: fixtures.appendingPathComponent("fake-figcraft-mcp.py"))
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("figcraft-server"),
                                                   withDestinationURL: fixtures.appendingPathComponent("fake-figcraft-server.sh"))
        try FileManager.default.createDirectory(at: flags, withIntermediateDirectories: true)
        try Data().write(to: log)
        setenv("ORQ_FAKE_FIG_LOG", log.path, 1)
        setenv("ORQ_FAKE_FIG_FLAGS", flags.path, 1)
    }
    func set(_ flag: String) throws { try Data().write(to: flags.appendingPathComponent(flag)) }
    var calls: [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    func cleanup() { unsetenv("ORQ_FAKE_FIG_FLAGS"); try? FileManager.default.removeItem(at: dir) }
}

/// The app's importer, faked: `html.snapshot` writes the landing fixture's snapshot files where the app would.
private final class FakeApp: Sendable {
    let calls = Mutex<[[String: JSONValue]]>([])
    func start(_ d: Daemon, _ p: Paths) async throws -> HostConnection {
        let root = p.root.appendingPathComponent("artifacts")
        let h = HostConnection(paths: p, token: { d.adminToken }) { [self] _, command, args, _ throws(ProtocolError) in
            guard command == "html.snapshot" else { return .object([:]) }
            calls.withLock { $0.append(args) }
            guard case .string(let id)? = args["id"] else { throw ProtocolError(code: .invalidArgs, message: "no id") }
            let out = root.appendingPathComponent("\(id)/.import")
            do {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                for f in ["snapshot.json", "img-1.png", "svg-1.svg"] {
                    try FileManager.default.copyItem(at: htmlImport.appendingPathComponent("landing-import/\(f)"), to: out.appendingPathComponent(f))
                }
            } catch { throw ProtocolError(code: .internal, message: "\(error)") }
            return .object(["file": .string(".import/snapshot.json"), "blocked": .number(2), "truncated": .bool(false)])
        }
        h.start()
        let up = await waitFor(10) {
            do throws(ProtocolError) { _ = try await d.router.host.callApp(command: "ping", args: [:], timeout: .seconds(2)); return true }
            catch { return false }
        }
        #expect(up, "the fake app never connected")
        return h
    }
}

private struct Term { var id: String; var token: String }
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 120)
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:], cwd: String? = nil) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }, cwd: cwd),
                                    to: p.socket, timeoutSeconds: 120)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, floor: String? = nil, maestro: Bool = false) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "maestro": .bool(maestro)]
    if let floor { args["floor"] = .string(floor) } else { args["cwd"] = .string("/tmp") }
    let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn", args: args), to: p.socket, timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
/// `artifact.add` of the landing fixture (its folder as `--root`): the new id.
private func addLanding(_ p: Paths, _ t: Term, title: String? = nil, width: String? = nil) async throws -> String {
    var args = ["path": "landing/index.html", "root": "landing"]
    if let title { args["title"] = title }
    if let width { args["width"] = width }
    let r = try await call(p, t, "artifact.add", args, cwd: htmlImport.path)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    #expect(o["importing"] == .bool(true), "\(r)")
    return id
}
private func row(_ p: Paths, _ t: Term, _ id: String) async throws -> [String: JSONValue]? {
    guard case .array(let a)? = try await call(p, t, "artifact.list").result else { return nil }
    return a.lazy.compactMap { if case .object(let o) = $0, o["id"] == .string(id) { o } else { nil } }.first
}
/// Polls until the artifact's status is `status`; its row then.
private func until(_ p: Paths, _ t: Term, _ id: String, _ status: String) async throws -> [String: JSONValue] {
    var last: [String: JSONValue]?
    let ok = await waitFor(10) {
        last = try? await row(p, t, id)
        return last?["status"] == .string(status)
    }
    #expect(ok, "never \(status): \(String(describing: last))")
    return last ?? [:]
}
private func withImport(_ fig: Fig, _ body: (Daemon, Paths) async throws -> Void) async throws {
    try await withDaemon(configure: { $0.figcraftDir = fig.dir }, body)
}

extension DesignCommandTests { @Suite(.serialized) struct ArtifactImportTests {
    @Test func agentHTMLBecomesScreen() async throws {
        let fig = try Fig(); defer { fig.cleanup() }
        try await withImport(fig) { d, p in
            let app = FakeApp(), h = try await app.start(d, p); defer { h.stop() }
            let m = try await term(d, p, "M")
            let id = try await addLanding(p, m)
            let r = try await until(p, m, id, "current")
            #expect(r["kind"] == .string("export") && r["file"] == .string("index.html") && r["version"] == .number(1), "\(r)")
            #expect(r["source"] == .string("orq-artifact://app/\(id)/source/index.html"), "\(r)")
            let dir = p.root.appendingPathComponent("artifacts/\(id)")
            #expect(FileManager.default.contents(atPath: dir.appendingPathComponent("source/index.html").path)
                    == FileManager.default.contents(atPath: htmlImport.appendingPathComponent("landing/index.html").path))
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("v1/index.html").path))
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".import").path))
            // the app was asked for the artifact's own page; one batch, one undo step
            let asked = app.calls.withLock { $0 }
            #expect(asked.count == 1 && asked.first?["url"] == .string("orq-artifact://app/\(id)/source/index.html") && asked.first?["id"] == .string(id), "\(asked)")
            let batches = fig.calls.filter { $0.hasPrefix("tools/call batch") }
            #expect(batches == ["tools/call batch Importar index.html"], "\(fig.calls)")
            // import warnings kept with the export's; blocked links lose their query
            guard case .array(let w)? = r["warnings"] else { Issue.record("\(r)"); return }
            #expect(w.contains(.string("blocked network resource: https://example.com/remote.png")), "\(w)")
            #expect(w.contains(.string("blocked network resource: https://fonts.googleapis.com/css2")), "\(w)")
        }
    }

    @Test func importBindsMatchingColors() async throws {
        let fig = try Fig(); defer { fig.cleanup() }
        try fig.set("white-bg")   // the system's first variable (color/bg) = the body's #FFFFFF
        try await withImport(fig) { d, p in
            let app = FakeApp(), h = try await app.start(d, p); defer { h.stop() }
            #expect(try await admin(d, p, "design.system.create", ["name": "Brand", "reason": "base"]).ok)
            #expect(try await admin(d, p, "design.system.use", ["name": "Brand", "reason": "r"]).ok)
            let m = try await term(d, p, "M")
            let id = try await addLanding(p, m)
            let r = try await until(p, m, id, "current")
            guard case .string(let root)? = r["node"] else { Issue.record("\(r)"); return }
            #expect(fig.calls.filter { $0 == "tools/call batch Ligar cores ao design system" }.count == 1, "\(fig.calls)")
            let binds = fig.calls.filter { $0.hasPrefix("bind ") }
            #expect(binds.count == 1 && binds[0].hasPrefix("bind VariableID:1 fill [\(root),"), "\(binds)")   // root first; text fills too
            guard case .array(let w)? = r["warnings"] else { Issue.record("\(r)"); return }
            #expect(w.contains { if case .string(let s) = $0 { s.hasPrefix("bound ") && s.hasSuffix(" colors to Brand") } else { false } }, "\(w)")
        }
    }

    @Test func bindFailureIsWarning() async throws {
        let fig = try Fig(); defer { fig.cleanup() }
        try fig.set("white-bg"); try fig.set("fail-batch-library.bindVariable")
        try await withImport(fig) { d, p in
            let app = FakeApp(), h = try await app.start(d, p); defer { h.stop() }
            #expect(try await admin(d, p, "design.system.create", ["name": "Brand", "reason": "base"]).ok)
            #expect(try await admin(d, p, "design.system.use", ["name": "Brand", "reason": "r"]).ok)
            let m = try await term(d, p, "M")
            let id = try await addLanding(p, m)
            let r = try await until(p, m, id, "current")
            #expect(r["version"] == .number(1), "\(r)")
            guard case .array(let w)? = r["warnings"] else { Issue.record("\(r)"); return }
            // the engine's error (it echoes a share link) comes scrubbed
            let why = w.compactMap { if case .string(let s) = $0, s.hasPrefix("colors not bound to Brand: ") { s } else { nil } }
            #expect(why.count == 1 && why[0].contains("failed (fake)"), "\(w)")
            #expect(!why.joined().contains("figcraft://") && !why.joined().contains("token="), "\(why)")
        }
    }

    @Test func importWithoutAppFails() async throws {
        let fig = try Fig(); defer { fig.cleanup() }
        try await withImport(fig) { d, p in
            let m = try await term(d, p, "M")
            let id = try await addLanding(p, m)
            let r = try await until(p, m, id, "failed")
            guard case .string(let why)? = r["importError"] else { Issue.record("\(r)"); return }
            #expect(why.contains("Orq app is not running") && r["kind"] == .string("agent"), "\(r)")
            let app = FakeApp(), h = try await app.start(d, p); defer { h.stop() }
            let ok = try await call(p, m, "artifact.import", ["id": id, "width": "1280"])
            guard case .object(let o)? = ok.result else { Issue.record("\(ok)"); return }
            #expect(o["artifact"] == .string(id) && o["file"] == .string("index.html") && o["version"] == .number(1), "\(ok)")
            #expect(o["node"] != nil && o["warnings"] != nil, "\(ok)")
            #expect(app.calls.withLock { $0.first?["width"] } == .number(1280))
            let after = try #require(try await row(p, m, id))
            #expect(after["importError"] == .null && after["kind"] == .string("export"), "\(after)")
        }
    }

    @Test func systemChangedReachesDesignSystemsPanels() async throws {
        let fig = try Fig(); defer { fig.cleanup() }
        try await withImport(fig) { d, p in
            let m = try await term(d, p, "M", maestro: true)
            let po = try await call(p, m, "panel.open", ["plugin": "designsystems"])
            #expect(po.ok, "\(po)")
            await d.router.systemChanged(["name": .string("Brand"), "kind": .string("published")])
            guard case .object(let r)? = (try await call(p, m, "events")).result, case .array(let evs)? = r["events"] else { Issue.record("no events"); return }
            let names = evs.compactMap { if case .object(let e) = $0, case .string(let n)? = e["name"] { n } else { nil } }
            #expect(names == ["designsystem.changed"], "\(names)")
        }
    }

    @Test func failedImportEmits() async throws {
        let fig = try Fig(); defer { fig.cleanup() }
        try await withImport(fig) { d, p in
            let m = try await term(d, p, "M", maestro: true)
            let po = try await call(p, m, "panel.open", ["plugin": "artifacts"])
            #expect(po.ok, "\(po)")
            let id = try await addLanding(p, m)   // no app host: the background import fails
            var failed: [String: JSONValue]?
            let ok = await waitFor(10) {
                guard case .object(let r)? = (try? await call(p, m, "events"))?.result, case .array(let evs)? = r["events"] else { return false }
                for case .object(let e) in evs where e["name"] == .string("artifact.imported") {
                    if case .object(let pl)? = e["payload"] { failed = pl }
                }
                return failed != nil
            }
            #expect(ok && failed?["id"] == .string(id), "\(String(describing: failed))")
            guard case .string(let why)? = failed?["error"] else { Issue.record("\(String(describing: failed))"); return }
            #expect(why.contains("Orq app is not running") && failed?["file"] == nil, "\(why)")
            // a foreground import's failure emits too: one event per failure
            _ = try await until(p, m, id, "failed")
            let r = try await call(p, m, "artifact.import", ["id": id])
            #expect(r.error?.message.contains("Orq app is not running") == true, "\(r)")
            guard case .object(let all)? = (try await call(p, m, "events")).result, case .array(let evs)? = all["events"] else { Issue.record("no events"); return }
            let errors = evs.filter { if case .object(let e) = $0, e["name"] == .string("artifact.imported"), case .object(let pl)? = e["payload"] {
                pl["id"] == .string(id) && pl["error"] != nil } else { false } }
            #expect(errors.count == 2, "\(evs)")
        }
    }

    @Test func addTakesAWidth() async throws {
        let fig = try Fig(); defer { fig.cleanup() }
        try await withImport(fig) { d, p in
            let app = FakeApp(), h = try await app.start(d, p); defer { h.stop() }
            let m = try await term(d, p, "M")
            let bad = try await call(p, m, "artifact.add", ["path": "landing/index.html", "root": "landing", "width": "100"], cwd: htmlImport.path)
            #expect(bad.error?.code == .invalidArgs, "\(bad)")
            #expect(try await call(p, m, "artifact.list").result == .array([]))   // refused before anything is kept
            let id = try await addLanding(p, m, width: "390")
            _ = try await until(p, m, id, "current")
            #expect(app.calls.withLock { $0.first?["width"] } == .number(390))
        }
    }

    @Test func reimportOfExportRefused() async throws {
        let fig = try Fig(); defer { fig.cleanup() }
        try await withImport(fig) { d, p in
            let app = FakeApp(), h = try await app.start(d, p); defer { h.stop() }
            let m = try await term(d, p, "M")
            let id = try await addLanding(p, m)
            _ = try await until(p, m, id, "current")
            let r = try await call(p, m, "artifact.import", ["id": id])
            #expect(r.error == ProtocolError(code: .invalidArgs, message: "already imported: edit its design screen"), "\(r)")
        }
    }

    @Test func uniqueFileNames() async throws {
        #expect(CommandRouter.importName("Ateliê/de..telas", taken: []) == "Ateli--de.telas")
        #expect(CommandRouter.importName(" ?! ", taken: []) == "--")
        #expect(CommandRouter.importName("   ", taken: []) == "Importado")
        #expect(CommandRouter.importName("t", taken: ["t", "t 2"]) == "t 3")
        #expect(CommandRouter.importName(String(repeating: "a", count: 90), taken: [String(repeating: "a", count: 80)])
                == String(repeating: "a", count: 78) + " 2")
        let fig = try Fig(); defer { fig.cleanup() }
        try await withImport(fig) { d, p in
            let app = FakeApp(), h = try await app.start(d, p); defer { h.stop() }
            let m = try await term(d, p, "M")
            let a = try await addLanding(p, m, title: "T")
            _ = try await until(p, m, a, "current")
            let b = try await addLanding(p, m, title: "T")
            let rb = try await until(p, m, b, "current")
            #expect(try await row(p, m, a)?["file"] == .string("T") && rb["file"] == .string("T 2"), "\(rb)")
        }
    }

    @Test func importStaysOnAgentFloor() async throws {
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        let fig = try Fig(); defer { fig.cleanup() }
        try await withImport(fig) { d, p in
            let app = FakeApp(), h = try await app.start(d, p); defer { h.stop() }
            #expect(try await admin(d, p, "floor.create", ["name": "f1", "repo": repo.path]).ok)
            let w = try await term(d, p, "W", floor: "f1")
            let id = try await addLanding(p, w)
            _ = try await until(p, w, id, "current")
            let floor = await d.router.ws.floors.first { $0.name == "f1" }?.id
            let f = try await d.router.design.list().first { $0.name == "index.html" }
            #expect(floor != nil && f?.floorId == floor, "\(String(describing: f))")
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(4)))
    func realEngineImportsLanding() async throws {
        try await withDaemon(configure: { $0.figcraftDir = vendorFigcraft }) { d, p in
            let app = FakeApp(), h = try await app.start(d, p); defer { h.stop() }
            // an active system whose bg is the body's color (#FFFFFF), published
            #expect(try await admin(d, p, "design.system.create", ["name": "Brand", "reason": "base"]).ok)
            let sysFile = try #require(try await d.router.design.list().first { $0.name == "Brand" })
            try await d.router.design.onSystemClient(sysFile.id, deadline: .now + .seconds(60)) { c, _ throws(ProtocolError) in
                guard case .object(let o) = try await c.command("variable.list", [:], timeout: .seconds(30)), case .array(let vs)? = o["variables"],
                      let bg = vs.first(where: { if case .object(let v) = $0 { v["name"] == .string("bg") } else { false } }),
                      case .object(let v) = bg, let vid = v["id"] else { throw ProtocolError(code: .internal, message: "no bg") }
                _ = try await c.command("variable.set", ["variable": vid, "mode": .string("Light"), "value": .string("#FFFFFF")], timeout: .seconds(30))
            }
            #expect(try await admin(d, p, "design.system.publish", ["name": "Brand", "reason": "white bg"]).ok)
            #expect(try await admin(d, p, "design.system.use", ["name": "Brand", "reason": "r"]).ok)
            let m = try await term(d, p, "M", maestro: true)
            let id = try await addLanding(p, m)
            let r = try await until(p, m, id, "current")
            guard case .string(let file)? = r["file"], case .string(let node)? = r["node"] else { Issue.record("\(r)"); return }
            #expect(try await call(p, m, "panel.open", ["plugin": "design", "file": file]).ok)
            let got = try await call(p, m, "design.inspect", ["node": node, "depth": "64"])
            guard case .object(let rootNode)? = got.result, case .object(let bound)? = rootNode["boundVariables"],
                  case .string(let fillVar)? = bound["fill"] else { Issue.record("root fill not bound: \(got)"); return }
            #expect(fillVar.contains(":VariableID:"), "\(bound)")
            func layers(_ v: JSONValue) -> Int {
                switch v {
                case .object(let o): (o["id"] != nil && o["type"] != nil ? 1 : 0) + o.values.map(layers).reduce(0, +)
                case .array(let a): a.map(layers).reduce(0, +)
                default: 0
                }
            }
            #expect(layers(got.result ?? .null) >= 20, "\(got)")
            let html = (try? String(contentsOf: p.root.appendingPathComponent("artifacts/\(id)/v1/index.html"), encoding: .utf8)) ?? ""
            #expect(html.contains("display: grid") && html.contains("Construa telas com seus agentes"), "\(html.prefix(500))")
        }
    }
} }
