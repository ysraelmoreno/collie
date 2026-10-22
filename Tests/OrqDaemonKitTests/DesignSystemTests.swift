import Testing
import Foundation
import OrqCore
import OrqProtocol
@testable import OrqDaemonKit

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral,
                     ExpressibleByDictionaryLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int) { self = .number(Double(v)) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(arrayLiteral v: JSONValue...) { self = .array(v) }
    public init(dictionaryLiteral v: (String, JSONValue)...) { self = .object(Dictionary(v) { $1 }) }
}

fileprivate extension JSONValue {
    subscript(_ k: String) -> JSONValue? { if case .object(let o) = self { o[k] } else { nil } }
    var s: String? { if case .string(let v) = self { v } else { nil } }
    var n: Double? { if case .number(let v) = self { v } else { nil } }
    var a: [JSONValue] { if case .array(let v) = self { v } else { [] } }
}

/// The fake figcraft (Tests/Fixtures), with `flags` for its fail-/slow- files; its calls in `log`.
private struct Fake {
    let dir = URL(fileURLWithPath: "/tmp/orq-dsf-\(UUID().uuidString.prefix(8))")
    var flags: URL { dir.appendingPathComponent("flags") }
    var log: URL { dir.appendingPathComponent("calls.log") }
    init() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: flags, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("figcraft-cli"),
                                                   withDestinationURL: fixtures.appendingPathComponent("fake-figcraft-mcp.py"))
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("figcraft-server"),
                                                   withDestinationURL: fixtures.appendingPathComponent("fake-figcraft-server.sh"))
        try Data().write(to: log)
        setenv("ORQ_FAKE_FIG_LOG", log.path, 1)
        setenv("ORQ_FAKE_FIG_FLAGS", flags.path, 1)
    }
    func set(_ flag: String, _ value: String = "") throws { try Data(value.utf8).write(to: flags.appendingPathComponent(flag)) }
    func clear(_ flag: String) { try? FileManager.default.removeItem(at: flags.appendingPathComponent(flag)) }
    var calls: [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    func cleanup() { unsetenv("ORQ_FAKE_FIG_FLAGS"); try? FileManager.default.removeItem(at: dir) }
}
private func withFake(_ fx: Fake, timeoutCap: Duration? = nil, _ body: (Daemon, Paths) async throws -> Void) async throws {
    try await withDaemon(configure: { $0.figcraftDir = fx.dir; $0.designTimeoutCap = timeoutCap }, body)
}

private func withEngine(_ body: (Daemon, Paths) async throws -> Void) async throws {
    try await withDaemon(configure: { $0.figcraftDir = vendorFigcraft }, body)
}


private struct Term { var id: String; var token: String }
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 150)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, maestro: Bool = false, cwd: String = "/tmp", floor: String? = nil) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string(cwd), "maestro": .bool(maestro)]
    if let floor { args["floor"] = .string(floor) }
    let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn", args: args),
        to: p.socket, timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 150)
}
private func text(_ r: Response) -> String {
    let e = JSONEncoder(); e.outputFormatting = .withoutEscapingSlashes
    return String(decoding: (try? e.encode(r)) ?? Data(), as: UTF8.self)
}
private func leaks(_ s: String) -> Bool { s.contains("figcraft://") || s.contains("token=") || s.contains("key=") }
/// Runs one figcraft command on `t`'s design panel `panel`.
private func run(_ p: Paths, _ t: Term, _ panel: String, _ cmd: String, _ params: String = "{}") async throws -> JSONValue {
    let r = try await call(p, t, "design.run", ["command": cmd, "params": params, "panel": panel])
    guard r.ok, let v = r.result else { throw ProtocolError(code: .internal, message: "\(cmd): \(r)") }
    return v
}

// nested in DesignCommandTests: one serialized run for every suite that starts a figcraft server (they share a port range)
extension DesignCommandTests { @Suite(.serialized) struct DesignSystemTests {
    /// What Orq relies on from figcraft's team libraries, on the real engine: headless clients on a real server.
    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(4)))
    func teamLibraryContract() async throws {
        try await withEngine { d, p in
            let ep = try await d.router.figcraft.ensureRunning()
            let cli = vendorFigcraft.appendingPathComponent("bin/figcraft-cli"), t = Duration.seconds(30)
            var clients: [MCPStdioClient] = []
            defer { clients.forEach { $0.close() } }
            func client(_ name: String) async throws -> MCPStdioClient {
                let c = try await MCPStdioClient(executable: cli, args: ["mcp"], env: ProcessInfo.processInfo.environment,
                                                 runDir: p.runDir, name: name)
                clients.append(c)
                return c
            }
            func live(_ c: MCPStdioClient) async throws -> JSONValue {
                for _ in 0..<150 {
                    let o = try await c.command("collab.peers", [:], timeout: t)
                    if o["status"] == .string("live"), o["readOnly"] == .bool(false) { return o }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw ProtocolError(code: .timeout, message: "not live")
            }
            /// A new server file holding a `Tokens` collection (Light/Dark) with a color `bg`; its client and links.
            func file(_ name: String, bg: String) async throws -> (c: MCPStdioClient, edit: String, view: String, bg: String) {
                let c = try await client("orq-\(name)")
                _ = try await c.command("collab.publish", ["server": .string(ep.wsURL), "name": .string(name)], timeout: t)
                var pub: JSONValue?
                for _ in 0..<150 where pub == nil {
                    let o = try await live(c)
                    if o["published"]?["edit"]?.s != nil { pub = o["published"] } else { try await Task.sleep(for: .milliseconds(100)) }
                }
                let col = try await c.command("variable.createCollection", ["name": "Tokens", "modes": ["Light", "Dark"]], timeout: t)
                let v = try await c.command("variable.create", ["collection": col["id"] ?? .null, "name": "bg", "type": "color",
                                                                "values": ["Light": .string(bg), "Dark": "#000000"]], timeout: t)
                return (c, pub?["edit"]?.s ?? "", pub?["view"]?.s ?? "", v["id"]?.s ?? "")
            }
            func fill(_ c: MCPStdioClient, _ id: JSONValue) async throws -> String? {
                let r = try await c.call("get_node", ["id": id], timeout: t).texts.joined()
                let node = try JSONDecoder().decode(JSONValue.self, from: Data(r.utf8))
                return node["fills"]?.a.first?["color"]?.s
            }

            // (a) A, in its session with edit access, publishes its library: version 1; again with no changes: refused
            let a = try await file("A", bg: "#FF0000")
            #expect(a.edit.hasPrefix("figcraft://") && a.view.hasPrefix("figcraft://") && a.edit != a.view)
            let v1 = try await a.c.command("library.publishToServer", [:], timeout: t)
            #expect(v1["version"] == .number(1) && v1["variables"] == .number(1) && v1["collections"] == .number(1), "\(v1)")
            #expect(v1["edit"] == nil && v1["view"] == nil, "\(v1)")   // no new file, no links
            await #expect(throws: ProtocolError.self) { _ = try await a.c.command("library.publishToServer", [:], timeout: t) }
            do { _ = try await a.c.command("library.publishToServer", [:], timeout: t) } catch let e as ProtocolError {
                #expect(e.message.contains("no changes to publish"), "\(e)")
            }
            let libA = try #require(v1["id"])

            // (b) B adds A by its view link; the listing shows its assets; a bound fill takes A's color
            let b = try await file("B", bg: "#00FF00")
            let added = try await b.c.command("library.add", ["path": .string(a.view)], timeout: t)
            #expect(added["id"] == libA && added["name"] == .string("A") && added["version"] == .number(1), "\(added)")
            let list = try await b.c.command("library.list", ["assets": true], timeout: t)
            let row = try #require(list["libraries"]?.a.first)
            #expect(row["server"] == .bool(true) && row["variables"]?.a.first?["name"] == .string("bg")
                    && row["collections"]?.a.first?["name"] == .string("Tokens"), "\(list)")
            let rect = try #require(try await b.c.command("node.create", ["type": "rectangle", "width": 10, "height": 10], timeout: t)["id"])
            let bound = try await b.c.command("library.bindVariable", ["library": libA, "variable": "bg", "field": "fill", "ids": [rect]], timeout: t)
            #expect(bound["variable"]?.s?.hasPrefix((libA.s ?? "") + ":") == true, "\(bound)")
            #expect(try await fill(b.c, rect) == "#FF0000")

            // (c) A changes bg and publishes v2; B sees the update and takes it
            _ = try await a.c.command("variable.set", ["variable": .string(a.bg), "mode": "Light", "value": "#0000FF"], timeout: t)
            #expect(try await a.c.command("library.publishToServer", [:], timeout: t)["version"] == .number(2))
            let ups = try await b.c.command("library.updates", [:], timeout: t)
            #expect(ups["count"] == .number(1) && ups["libraries"]?.a.first?["version"] == .number(2), "\(ups)")
            let took = try await b.c.command("library.acceptUpdates", [:], timeout: t)
            #expect(took["variables"] == .number(1), "\(took)")
            #expect(try await fill(b.c, rect) == "#0000FF")

            // (d) another library C with a different bg; B swaps A for C
            let c = try await file("C", bg: "#ABCDEF")
            let libC = try #require(try await c.c.command("library.publishToServer", [:], timeout: t)["id"])
            #expect(try await b.c.command("library.add", ["path": .string(c.view)], timeout: t)["id"] == libC)
            let swap = try await b.c.command("library.swap", ["from": libA, "to": libC], timeout: t)
            #expect(swap["unmatched"] == .array([]) && swap["variables"] == .number(1) && swap["removed"] == .bool(true), "\(swap)")
            #expect(try await fill(b.c, rect) == "#ABCDEF")

            // (e) a second client in B's session sees it without reloading
            let b2 = try await client("orq-B2")
            _ = try await b2.command("collab.join", ["link": .string(b.edit)], timeout: t)
            _ = try await live(b2)
            #expect(await waitFor(10) {
                _ = try? await self.sync(b2, t)
                return (try? await fill(b2, rect)) == "#ABCDEF"
            })

            // `--from`: a client in A's session publishes to the server's address+key: a new file with its own library v1
            let copy = try await a.c.command("library.publishToServer", ["server": .string(ep.wsURL)], timeout: t)
            #expect(copy["version"] == .number(1) && copy["id"] != libA && copy["edit"]?.s?.hasPrefix("figcraft://") == true
                    && copy["view"]?.s?.hasPrefix("figcraft://") == true && copy["file"]?.s != nil, "\(copy["version"] ?? .null)")
            let n = try await client("orq-N")
            _ = try await n.command("collab.join", ["link": copy["edit"] ?? .null], timeout: t)
            _ = try await live(n)
            #expect(await waitFor(10) {
                ((try? await n.command("variable.list", [:], timeout: t))?["variables"]?.a.compactMap { $0["name"]?.s }) == ["bg"]
            })
            // A is still in its own session
            #expect(try await a.c.command("collab.peers", [:], timeout: t)["fileName"] == .string("A"))
        }
    }


    // MARK: design systems (real engine)

    /// Maestro M with a canvas design panel `design-1` on the file of design system `name` (corded to M).
    private func panel(_ d: Daemon, _ p: Paths, _ name: String, cwd: String = "/tmp") async throws -> Term {
        let m = try await term(d, p, "M", maestro: true, cwd: cwd)
        let r = try await call(p, m, "panel.open", ["plugin": "design", "file": name, "placement": "canvas"])
        #expect(r.ok, "\(r)")
        return m
    }
    private func snapshot(_ p: Paths, _ name: String, _ v: Int) throws -> URL? {
        let reg = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: p.root.appendingPathComponent("design/systems.json")))
        guard let id = reg.a.first(where: { $0["name"]?.s == name })?["id"]?.s else { return nil }
        let u = p.root.appendingPathComponent("design/systems/\(id)/v\(v).figcraft")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    private func setBg(_ p: Paths, _ m: Term, _ hex: String) async throws {
        let vars = try await run(p, m, "design-1", "variable.list")
        let bg = try #require(vars["variables"]?.a.first { $0["name"]?.s == "bg" }?["id"]?.s)
        _ = try await run(p, m, "design-1", "variable.set", #"{"variable":"\#(bg)","mode":"Light","value":"\#(hex)"}"#)
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(4)))
    func createSeedsTokensAndPublishesV1() async throws {
        try await withEngine { d, p in
            let r = try await admin(d, p, "design.system.create", ["name": "Brand", "reason": "our brand"])
            #expect(r.result == .object(["name": "Brand", "version": 1]), "\(r)")
            let m = try await panel(d, p, "Brand")
            let vars = try await run(p, m, "design-1", "variable.list")
            let names = Set(vars["variables"]?.a.compactMap { $0["name"]?.s } ?? [])
            #expect(names == ["bg", "surface", "text", "muted", "accent", "space/s", "space/m", "space/l", "space/xl", "radius/card",
                              "type/body", "type/h3", "type/h2", "type/h1"], "\(names)")
            #expect(vars["collections"]?.a.first?["modes"]?.a.compactMap { $0["name"]?.s } == ["Light", "Dark"], "\(vars)")
            #expect(try await run(p, m, "design-1", "style.list").a.contains { $0["name"]?.s == "Heading" })
            #expect(try await run(p, m, "design-1", "component.list").a.contains { $0["name"]?.s == "Button" })
            #expect(try snapshot(p, "Brand", 1) != nil)
            let list = try await call(p, m, "design.system.list")
            #expect(list.result == .array([.object(["name": "Brand", "version": 1, "active": []])]), "\(list)")
            #expect(try await admin(d, p, "design.system.create", ["name": "brand", "reason": "again"]).error?.code == .invalidArgs)
            #expect(try await admin(d, p, "design.system.create", ["name": "X"]).error?.code == .invalidArgs)   // a reason is needed
            #expect(try await admin(d, p, "design.system.create", ["name": "Y", "from": "Nope", "reason": "r"]).error?.code == .notFound)
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(4)))
    func createFromCopiesTokens() async throws {
        try await withEngine { d, p in
            #expect(try await admin(d, p, "design.system.create", ["name": "Brand", "reason": "base"]).ok)
            let m = try await panel(d, p, "Brand")
            try await setBg(p, m, "#123456")
            let r = try await call(p, m, "design.system.create", ["name": "Sub", "from": "Brand", "reason": "a variant"])
            #expect(r.result == .object(["name": "Sub", "version": 1]), "\(r)")
            #expect(try await call(p, m, "panel.open", ["plugin": "design", "file": "Sub", "placement": "canvas"]).ok)
            let vars = try await run(p, m, "design-2", "variable.list")
            let bg = vars["variables"]?.a.first { $0["name"]?.s == "bg" }
            #expect(vars["variables"]?.a.count == 14, "\(vars)")
            // #123456 in Light
            let lightMode = vars["collections"]?.a.first?["modes"]?.a.first { $0["name"] == "Light" }?["id"]?.s ?? ""
            let light = bg?["values"]?[lightMode]?["value"]
            #expect(light?["r"]?.n.map { ($0 * 255).rounded() } == 0x12 && light?["b"]?.n.map { ($0 * 255).rounded() } == 0x56, "\(bg ?? .null)")
            #expect(try snapshot(p, "Sub", 1) != nil)
            // the copy is its own file: the source is unchanged by edits to it
            #expect(try await run(p, m, "design-2", "component.list").a.contains { $0["name"]?.s == "Button" })
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(4)))
    func publishBumpsVersionAndSnapshots() async throws {
        try await withEngine { d, p in
            #expect(try await admin(d, p, "design.system.create", ["name": "Brand", "reason": "base"]).ok)
            let m = try await panel(d, p, "Brand")
            try await setBg(p, m, "#654321")
            let r = try await call(p, m, "design.system.publish", ["name": "Brand", "reason": "darker bg"])
            #expect(r.result == .object(["name": "Brand", "version": 2]), "\(r)")
            #expect(try snapshot(p, "Brand", 2) != nil)
            let h = try await call(p, m, "design.system.history", ["name": "Brand"])
            #expect(h.result?.a.compactMap { $0["kind"]?.s } == ["created", "published"], "\(h)")
            #expect(h.result?.a.last?["version"] == .number(2) && h.result?.a.last?["reason"] == .string("darker bg")
                    && h.result?.a.last?["by"] == .string("M") && h.result?.a.last?["snapshot"] == .string("v2.figcraft"), "\(h)")
            #expect(try await call(p, m, "design.system.list").result?.a.first?["version"] == .number(2))
            // every design panel heard of it
            let ev = try await call(p, m, "events")
            #expect(text(ev).contains("designsystem.changed"), "\(ev)")
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(4)))
    func publishWithoutChangesIsRefused() async throws {
        try await withEngine { d, p in
            #expect(try await admin(d, p, "design.system.create", ["name": "Brand", "reason": "base"]).ok)
            let r = try await admin(d, p, "design.system.publish", ["name": "Brand", "reason": "nothing"])
            #expect(r.error == ProtocolError(code: .invalidArgs, message: "no changes to publish"), "\(r)")
            #expect(try await admin(d, p, "design.system.publish", ["name": "Nope", "reason": "r"]).error?.code == .notFound)
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(4)))
    func publishNeedsReachToItsPanel() async throws {
        try await withEngine { d, p in
            #expect(try await admin(d, p, "design.system.create", ["name": "Brand", "reason": "base"]).ok)
            let m = try await panel(d, p, "Brand")
            let w = try await term(d, p, "W")
            try await setBg(p, m, "#111111")
            #expect(try await call(p, w, "design.system.publish", ["name": "Brand", "reason": "r"]).error?.code == .notConnected)
            #expect(try await call(p, w, "design.system.list").ok)   // listing needs no panel
            #expect(try await admin(d, p, "design.system.publish", ["name": "Brand", "reason": "admin"]).result
                    == .object(["name": "Brand", "version": 2]))
            try await setBg(p, m, "#222222")
            #expect(try await call(p, m, "design.system.publish", ["name": "Brand", "reason": "corded"]).ok)
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(4)))
    func decisionRecordedWithReason() async throws {
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        try await withEngine { d, p in
            let m = try await panel(d, p, "Brand", cwd: repo.path)   // the panel's file is made by panel.open
            // the panel's ordinary design file of that name is not taken over
            let taken = try await call(p, m, "design.system.create", ["name": "Brand", "reason": "the first brand"])
            #expect(taken.error?.code == .invalidArgs && taken.error?.message.contains("not a design system") == true, "\(taken)")
            #expect(try await call(p, m, "design.system.create", ["name": "Brand2", "reason": "the first brand"]).ok)
            #expect(try await call(p, m, "panel.open", ["plugin": "design", "file": "Brand2", "placement": "canvas"]).ok)
            func decisions() async throws -> [JSONValue] {
                let l = try await call(p, m, "memory.list", ["kind": "decision"])
                return (l.result?["records"]?.a ?? []).filter { $0["subject"] == .string("design system brand2") }
            }
            var recs = try await decisions()
            #expect(recs.count == 1 && recs.first?["body"]?.s?.contains("the first brand") == true, "\(recs)")
            // a system's decisions are the workspace's, whoever made them: the global store, not the caller's repo
            #expect(recs.first?["file"]?.s?.hasPrefix(p.root.appendingPathComponent("memory").path) == true, "\(recs)")
            let vars = try await run(p, m, "design-2", "variable.list")
            let bg = try #require(vars["variables"]?.a.first { $0["name"]?.s == "bg" }?["id"]?.s)
            _ = try await run(p, m, "design-2", "variable.set", ##"{"variable":"\##(bg)","mode":"Light","value":"#333333"}"##)
            #expect(try await call(p, m, "design.system.publish", ["name": "Brand2", "reason": "a darker bg"]).ok)
            recs = try await decisions()   // active ones only: the second replaced the first
            #expect(recs.count == 1 && recs.first?["body"]?.s?.contains("a darker bg") == true, "\(recs)")
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(4)))
    func noLinkInAnyResult() async throws {
        try await withEngine { d, p in
            var seen = [try await admin(d, p, "design.system.create", ["name": "Brand", "reason": "see figcraft://join?host=x&token=abc key=k"])]
            let m = try await panel(d, p, "Brand")
            seen.append(try await call(p, m, "design.system.create", ["name": "Sub", "from": "Brand", "reason": "copy"]))
            seen.append(try await call(p, m, "design.system.publish", ["name": "Brand", "reason": "nothing changed"]))
            try await setBg(p, m, "#444444")
            seen.append(try await call(p, m, "design.system.publish", ["name": "Brand", "reason": "changed"]))
            seen.append(try await call(p, m, "design.system.list"))
            seen.append(try await call(p, m, "design.system.history", ["name": "Brand"]))
            seen.append(try await call(p, m, "design.system.history", ["name": "Sub"]))
            seen.append(try await call(p, m, "design.system.create", ["name": "Bad/name", "reason": "r"]))
            seen.append(try await call(p, m, "memory.list"))
            for r in seen { #expect(!leaks(text(r)), "\(text(r))") }
            #expect(seen[2].error != nil && seen[3].ok, "\(seen)")
            #expect(seen[5].result?.a.first?["reason"]?.s?.contains("[link]") == true, "\(seen[5])")
        }
    }


    // MARK: fake engine

    @Test func publishRecordedWhenSnapshotFails() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        try await withFake(fx) { d, p in
            let m = try await term(d, p, "M", maestro: true, cwd: repo.path)
            #expect(try await call(p, m, "design.system.create", ["name": "Brand", "reason": "base"]).result == .object(["name": "Brand", "version": 1]))
            #expect(try await call(p, m, "panel.open", ["plugin": "design", "file": "Brand", "placement": "canvas"]).ok)
            try fx.set("fail-file.save")
            let r = try await call(p, m, "design.system.publish", ["name": "Brand", "reason": "no snapshot"])
            #expect(r.ok && r.result?["version"] == .number(2) && r.result?["snapshotError"]?.s?.contains("snapshot") == true, "\(r)")
            #expect(try await call(p, m, "design.system.list").result?.a.first?["version"] == .number(2))
            let h = try await call(p, m, "design.system.history", ["name": "Brand"]).result?.a.last
            #expect(h?["kind"] == .string("published") && h?["version"] == .number(2) && h?["snapshot"] == nil, "\(h ?? .null)")
            let recs = try await call(p, m, "memory.list", ["kind": "decision"]).result?["records"]?.a ?? []
            #expect(recs.contains { $0["subject"] == .string("design system brand") && $0["body"]?.s?.contains("no snapshot") == true }, "\(recs)")
            #expect(text(try await call(p, m, "events")).contains(#""version":2"#))
            // a create whose first snapshot fails is registered all the same
            let c = try await admin(d, p, "design.system.create", ["name": "Other", "reason": "r"])
            #expect(c.ok && c.result?["snapshotError"] != nil, "\(c)")
            #expect(try await admin(d, p, "design.system.list").result?.a.count == 2)
        }
    }

    @Test func createAndPublishKeepOneDeadline() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withFake(fx, timeoutCap: .seconds(4)) { d, p in
            #expect(try await admin(d, p, "design.system.create", ["name": "Brand", "reason": "base"]).ok)
            // each step alone fits in 4 s, all together they don't
            try fx.set("slow-library.publishToServer", "2"); try fx.set("slow-file.save", "2.5")
            let t0 = ContinuousClock.now
            let r = try await admin(d, p, "design.system.publish", ["name": "Brand", "reason": "slow"])
            #expect(ContinuousClock.now - t0 < .seconds(5), "\(ContinuousClock.now - t0)")
            // the version went out: recorded, its snapshot reported missing
            #expect(r.result?["version"] == .number(2) && r.result?["snapshotError"] != nil, "\(r)")
            fx.clear("slow-file.save"); try fx.set("slow-library.publishToServer", "5")
            let t1 = ContinuousClock.now
            let c = try await admin(d, p, "design.system.create", ["name": "Late", "reason": "slow"])
            #expect(c.error?.code == .timeout && ContinuousClock.now - t1 < .seconds(5), "\(c) \(ContinuousClock.now - t1)")
        }
    }

    @Test func createRetryAdoptsTheFileLeftBehind() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withFake(fx) { d, p in
            try fx.set("fail-library.publishToServer")
            #expect(try await admin(d, p, "design.system.create", ["name": "Brand", "reason": "first try"]).error != nil)
            #expect(try await admin(d, p, "design.system.list").result == .array([]))
            fx.clear("fail-library.publishToServer")
            let r = try await admin(d, p, "design.system.create", ["name": "Brand", "reason": "second try"])
            #expect(r.result == .object(["name": "Brand", "version": 1]), "\(r)")
            #expect(try await admin(d, p, "design.files").result?.a.count == 1)   // the same file, not a second one
            #expect(fx.calls.filter { $0 == "tools/call run_command collab.publish" }.count == 1, "\(fx.calls)")
            #expect(try await admin(d, p, "design.system.create", ["name": "Brand", "reason": "third"]).error?.code == .invalidArgs)
        }
    }


    @Test func createRefusesOrdinaryFileName() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withFake(fx) { d, p in
            #expect(try await admin(d, p, "design.new", ["name": "Site"]).ok)
            let before = fx.calls.count
            for args in [["name": "Site", "reason": "r"], ["name": "site", "reason": "r"]] {
                let r = try await admin(d, p, "design.system.create", args)
                #expect(r.error == ProtocolError(code: .invalidArgs,
                                                 message: "a design file named '\(args["name"]!)' already exists (not a design system); pick another name"), "\(r)")
            }
            // the file was not touched: no client of it, no seed, no publish
            #expect(fx.calls.count == before, "\(fx.calls.suffix(from: before))")
            #expect(try await admin(d, p, "design.system.list").result == .array([]))
        }
    }

    @Test func failedCopyRetryKeepsTheCopy() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withFake(fx) { d, p in
            #expect(try await admin(d, p, "design.system.create", ["name": "Base", "reason": "r"]).ok)
            // the copy is made and published, then the registry can't be written
            let blocker = p.root.appendingPathComponent("design/.systems.json.tmp")
            try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
            #expect(try await admin(d, p, "design.system.create", ["name": "Copy", "from": "Base", "reason": "r"]).error != nil)
            try FileManager.default.removeItem(at: blocker)
            let r = try await admin(d, p, "design.system.create", ["name": "Copy", "from": "Base", "reason": "retry"])
            #expect(r.result == .object(["name": "Copy", "version": 1]), "\(r)")
            // the copy left behind became the system: no second copy
            #expect(fx.calls.filter { $0 == "tools/call run_command library.publishToServer" }.count == 2, "\(fx.calls)")
            #expect(try await admin(d, p, "design.files").result?.a.count == 2)
            #expect(try await admin(d, p, "design.system.list").result?.a.count == 2)
        }
    }

    // MARK: active design system (real engine)

    /// `body` on the daemon's own client of design file `name` (tests reach library.* through it; agents can't).
    private func sys<T: Sendable>(_ d: Daemon, _ name: String,
                                  _ body: @escaping @Sendable (MCPStdioClient) async throws -> T) async throws -> T {
        let f = try #require(try await d.router.design.list().first { $0.name == name }, "no file \(name)")
        return try await d.router.design.onSystemClient(f.id, deadline: .now + .seconds(60)) { c, _ throws(ProtocolError) in
            do { return try await body(c) } catch let e as ProtocolError { throw e } catch { throw ProtocolError(code: .internal, message: "\(error)") }
        }
    }
    /// Design system `name` (admin), its `bg` set to `bg` (Light) and published as version 2 when given.
    private func system(_ d: Daemon, _ p: Paths, _ name: String, bg: String? = nil) async throws {
        #expect(try await admin(d, p, "design.system.create", ["name": name, "reason": "base"]).ok)
        guard let bg else { return }
        try await setVar(d, name, "bg", bg)
        let r = try await admin(d, p, "design.system.publish", ["name": name, "reason": "bg \(bg)"])
        #expect(r.result?["version"] == .number(2), "\(r)")
    }
    private func setVar(_ d: Daemon, _ file: String, _ v: String, _ hex: String) async throws {
        try await sys(d, file) { c in
            let vars = try await c.command("variable.list", [:], timeout: .seconds(30))
            let id = vars["variables"]?.a.first { $0["name"]?.s == v }?["id"] ?? .null
            _ = try await c.command("variable.set", ["variable": id, "mode": "Light", "value": .string(hex)], timeout: .seconds(30))
        }
    }
    /// A rectangle in screen file `file` whose fill is bound to library `lib`'s variable `v`; its id.
    private func bound(_ d: Daemon, _ file: String, _ lib: String, _ v: String = "bg") async throws -> JSONValue {
        try await sys(d, file) { c in
            let rect = try await c.command("node.create", ["type": "rectangle", "width": 10, "height": 10], timeout: .seconds(30))["id"] ?? .null
            _ = try await c.command("library.bindVariable", ["library": .string(lib), "variable": .string(v), "field": "fill", "ids": [rect]],
                                    timeout: .seconds(30))
            return rect
        }
    }
    private func fill(_ d: Daemon, _ file: String, _ rect: JSONValue) async throws -> String? {
        try await sys(d, file) { c in
            _ = try await c.command("collab.peers", [:], timeout: .seconds(30))
            let t = try await c.call("get_node", ["id": rect], timeout: .seconds(30)).texts.joined()
            return try JSONDecoder().decode(JSONValue.self, from: Data(t.utf8))["fills"]?.a.first?["color"]?.s?.uppercased()
        }
    }
    private func libraries(_ d: Daemon, _ file: String) async throws -> [String] {
        try await sys(d, file) { c in
            try await c.command("library.list", [:], timeout: .seconds(30))["libraries"]?.a.compactMap { $0["name"]?.s } ?? []
        }
    }
    private func use(_ d: Daemon, _ p: Paths, _ name: String, floor: String? = nil, reason: String = "r") async throws -> Response {
        var a = ["name": name, "reason": reason]
        if let floor { a["floor"] = floor }
        return try await admin(d, p, "design.system.use", a)
    }
    private func active(_ d: Daemon, _ p: Paths) async throws -> [String: [String]] {
        let l = try await admin(d, p, "design.system.list").result?.a ?? []
        return Dictionary(uniqueKeysWithValues: l.map { ($0["name"]?.s ?? "", $0["active"]?.a.compactMap(\.s) ?? []) })
    }
    private func outcomes(_ r: Response) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: (r.result?["files"]?.a ?? []).map { ($0["file"]?.s ?? "", $0["ok"] == .bool(true)) })
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(5)))
    func useAppliesToScopeFiles() async throws {
        try await withEngine { d, p in
            try await system(d, p, "A")
            try await system(d, p, "C", bg: "#ABCDEF")
            for f in ["S1", "S2"] { #expect(try await admin(d, p, "design.new", ["name": f]).ok) }
            let first = try await use(d, p, "A", reason: "brand A")
            #expect(first.result?["scope"] == "workspace" && first.result?["system"] == "A", "\(first)")
            #expect(outcomes(first) == ["S1": true, "S2": true], "\(first)")   // the systems' own files are left out
            let r1 = try await bound(d, "S1", "A"), r2 = try await bound(d, "S2", "A")
            #expect(try await fill(d, "S1", r1) == "#FAFAF7")
            let r = try await use(d, p, "C", reason: "brand C")
            #expect(outcomes(r) == ["S1": true, "S2": true], "\(r)")
            #expect(try await fill(d, "S1", r1) == "#ABCDEF")
            #expect(try await fill(d, "S2", r2) == "#ABCDEF")
            #expect(try await libraries(d, "S1") == ["C"])
            #expect(try await active(d, p) == ["A": [], "C": ["workspace"]])
            let h = try await admin(d, p, "design.system.history", ["name": "C"]).result?.a.last
            #expect(h?["kind"] == "activated" && h?["scope"] == "workspace" && h?["reason"] == "brand C" && h?["files"]?.a.count == 2, "\(h ?? .null)")
            #expect(!leaks(text(r)))
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(5)))
    func swapReportsUnmatched() async throws {
        try await withEngine { d, p in
            try await system(d, p, "A")
            #expect(try await admin(d, p, "design.system.create", ["name": "C", "reason": "base"]).ok)
            try await sys(d, "C") { c in
                let vars = try await c.command("variable.list", [:], timeout: .seconds(30))
                let muted = vars["variables"]?.a.first { $0["name"]?.s == "muted" }?["id"] ?? .null
                _ = try await c.command("variable.delete", ["variable": muted], timeout: .seconds(30))
            }
            #expect(try await admin(d, p, "design.system.publish", ["name": "C", "reason": "no muted"]).ok)
            #expect(try await admin(d, p, "design.new", ["name": "S"]).ok)
            #expect(try await use(d, p, "A").ok)
            _ = try await bound(d, "S", "A", "muted")
            let r = try await use(d, p, "C")
            let row = r.result?["files"]?.a.first
            #expect(row?["ok"] == .bool(true) && row?["unmatched"]?.a.contains { $0.s?.contains("muted") == true } == true, "\(r)")
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(5)))
    func swapReachesOtherSessionClient() async throws {
        try await withEngine { d, p in
            try await system(d, p, "A")
            try await system(d, p, "C", bg: "#ABCDEF")
            #expect(try await admin(d, p, "design.new", ["name": "S"]).ok)
            #expect(try await use(d, p, "A").ok)
            let rect = try await bound(d, "S", "A")
            let m = try await panel(d, p, "S")   // M's own client of S
            #expect(try await use(d, p, "C").ok)
            #expect(await waitFor(10) {
                let n = try? await call(p, m, "design.inspect", ["panel": "design-1", "node": "\(Int(rect.n ?? 0))"])
                return n?.result?["fills"]?.a.first?["color"]?.s?.uppercased() == "#ABCDEF"
            })
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(6)))
    func floorInheritsWorkspaceUnlessOverridden() async throws {
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        try await withEngine { d, p in
            try await system(d, p, "A")
            try await system(d, p, "C", bg: "#ABCDEF")
            for f in ["f1", "f2"] { #expect(try await admin(d, p, "floor.create", ["name": f, "repo": repo.path]).ok) }
            #expect(try await admin(d, p, "design.new", ["name": "G"]).ok)
            #expect(try await admin(d, p, "design.new", ["name": "F1", "floor": "f1"]).ok)
            #expect(try await admin(d, p, "design.new", ["name": "F2", "floor": "f2"]).ok)
            #expect(outcomes(try await use(d, p, "A")) == ["G": true, "F1": true, "F2": true])
            let r = try await use(d, p, "C", floor: "f1", reason: "f1 tries C")
            #expect(r.result?["scope"] == "floor:f1" && outcomes(r) == ["F1": true], "\(r)")
            #expect(try await libraries(d, "F1") == ["C"])
            #expect(try await libraries(d, "F2") == ["A"])
            // the workspace changes again: f1 keeps its own
            let w = try await use(d, p, "C")
            #expect(outcomes(w) == ["G": true, "F2": true], "\(w)")
            #expect(try await use(d, p, "A").ok)
            #expect(try await libraries(d, "F1") == ["C"])
            #expect(try await libraries(d, "G") == ["A"])
            #expect(try await active(d, p) == ["A": ["workspace"], "C": ["floor:f1"]])
            // the workspace's decision in the global store, the floor's in the floor's worktree repo
            let recs = try await admin(d, p, "memory.list", ["kind": "decision"]).result?["records"]?.a ?? []
            #expect(recs.contains { $0["subject"] == "design system ativo" }, "\(recs)")
            #expect(!recs.contains { $0["subject"] == "design system ativo (andar f1)" }, "\(recs)")
            let f1 = try #require(try await admin(d, p, "floor.list").result?.a.first { $0["name"] == "f1" }?["path"]?.s)
            let floorRecs = try await admin(d, p, "memory.list", ["kind": "decision", "repo": f1]).result?["records"]?.a ?? []
            #expect(floorRecs.contains { $0["subject"] == "design system ativo (andar f1)" && $0["body"]?.s?.contains("f1 tries C") == true }, "\(floorRecs)")
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(5)))
    func publishPropagatesToUsers() async throws {
        try await withEngine { d, p in
            try await system(d, p, "A")
            #expect(try await admin(d, p, "design.new", ["name": "B"]).ok)
            #expect(try await use(d, p, "A").ok)
            let rect = try await bound(d, "B", "A")
            try await setVar(d, "A", "bg", "#123456")
            let r = try await admin(d, p, "design.system.publish", ["name": "A", "reason": "new bg"])
            #expect(r.result?["version"] == .number(2) && outcomes(r) == ["B": true], "\(r)")
            #expect(try await fill(d, "B", rect) == "#123456")
            #expect(try await admin(d, p, "design.system.history", ["name": "A"]).result?.a.last?["files"]?.a.count == 1)
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(5)))
    func revertRepublishesSnapshot() async throws {
        try await withEngine { d, p in
            try await system(d, p, "A", bg: "#222222")   // v1 seed bg, v2 #222222
            #expect(try await admin(d, p, "design.new", ["name": "B"]).ok)
            #expect(try await use(d, p, "A").ok)
            let rect = try await bound(d, "B", "A")
            #expect(try await fill(d, "B", rect) == "#222222")
            let r = try await admin(d, p, "design.system.revert", ["name": "A", "to": "1", "reason": "back to the seed"])
            #expect(r.result?["name"] == "A" && r.result?["version"] == .number(3) && outcomes(r) == ["B": true], "\(r)")
            #expect(try await fill(d, "B", rect) == "#FAFAF7")
            #expect(try snapshot(p, "A", 3) != nil)
            let h = try await admin(d, p, "design.system.history", ["name": "A"]).result?.a.last
            #expect(h?["kind"] == "reverted" && h?["version"] == .number(3) && h?["reason"] == "back to the seed", "\(h ?? .null)")
            #expect(try await admin(d, p, "design.system.revert", ["name": "A", "to": "9", "reason": "r"]).error?.code == .notFound)
            #expect(!leaks(text(r)))
            // the file still shows v2's content: a publish would put it back out, so it needs --force
            try await setVar(d, "A", "bg", "#333333")
            let refused = try await admin(d, p, "design.system.publish", ["name": "A", "reason": "an edit"])
            #expect(refused.error == ProtocolError(code: .invalidArgs, message: "design system 'A' was reverted to v1, but its file still shows the newer content — edit the file back to v1, or publish with --force to publish it as it is"), "\(refused)")
            #expect(try await admin(d, p, "design.system.list").result?.a.first?["reverted"] == .number(1))
            let copy = try await admin(d, p, "design.system.create", ["name": "A2", "from": "A", "reason": "a copy"])
            #expect(copy.error == ProtocolError(code: .invalidArgs, message: "design system 'A' was reverted to v1 and its file still shows newer content; publish it (or --force) before copying"), "\(copy)")
            let forced = try await admin(d, p, "design.system.publish", ["name": "A", "reason": "keep the file", "force": "true"])
            #expect(forced.result?["version"] == .number(4) && outcomes(forced) == ["B": true], "\(forced)")
            #expect(try await admin(d, p, "design.system.list").result?.a.first?["reverted"] == nil)
            #expect(try await fill(d, "B", rect) == "#333333")
            try await setVar(d, "A", "bg", "#444444")   // the mark is gone with the forced publish
            #expect(try await admin(d, p, "design.system.publish", ["name": "A", "reason": "next"]).result?["version"] == .number(5))
            // back to v4, then to v5 (what the file shows): the second leaves no mark
            #expect(try await admin(d, p, "design.system.revert", ["name": "A", "to": "4", "reason": "r"]).result?["version"] == .number(6))
            #expect(try await admin(d, p, "design.system.list").result?.a.first?["reverted"] == .number(4))
            #expect(try await admin(d, p, "design.system.revert", ["name": "A", "to": "5", "reason": "r"]).result?["version"] == .number(7))
            #expect(try await admin(d, p, "design.system.list").result?.a.first?["reverted"] == nil)
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(6)))
    func floorNoneInheritsWorkspace() async throws {
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        try await withEngine { d, p in
            try await system(d, p, "A")
            try await system(d, p, "C", bg: "#ABCDEF")
            #expect(try await admin(d, p, "floor.create", ["name": "f1", "repo": repo.path]).ok)
            #expect(try await admin(d, p, "design.new", ["name": "F1", "floor": "f1"]).ok)
            #expect(try await use(d, p, "A").ok)
            #expect(try await use(d, p, "C", floor: "f1").ok)
            let rect = try await bound(d, "F1", "C")
            let r = try await admin(d, p, "design.system.use", ["floor": "f1", "none": "true", "reason": "back to the brand"])
            #expect(r.result?["system"] == "A" && r.result?["inherits"] == .bool(true) && outcomes(r) == ["F1": true], "\(r)")
            #expect(try await libraries(d, "F1") == ["A"])
            #expect(try await fill(d, "F1", rect) == "#FAFAF7")
            #expect(try await active(d, p) == ["A": ["workspace"], "C": []])
            let h = try await admin(d, p, "design.system.history", ["name": "A"]).result?.a.last
            #expect(h?["kind"] == "activated" && h?["scope"] == "floor:f1", "\(h ?? .null)")
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(6)))
    func undoFirstFloorOverrideInherits() async throws {
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        try await withEngine { d, p in
            try await system(d, p, "A")
            try await system(d, p, "C", bg: "#ABCDEF")
            #expect(try await admin(d, p, "floor.create", ["name": "f1", "repo": repo.path]).ok)
            #expect(try await admin(d, p, "design.new", ["name": "F1", "floor": "f1"]).ok)
            #expect(try await use(d, p, "A").ok)
            #expect(try await use(d, p, "C", floor: "f1").ok)
            let u = try await admin(d, p, "design.system.undo", ["floor": "f1", "reason": "follow the workspace"])
            #expect(u.result?["system"] == "A" && u.result?["inherits"] == .bool(true) && outcomes(u) == ["F1": true], "\(u)")
            #expect(try await libraries(d, "F1") == ["A"])
            #expect(try await active(d, p) == ["A": ["workspace"], "C": []])
            // undo again: C, the floor's own, is back
            #expect(try await admin(d, p, "design.system.undo", ["floor": "f1", "reason": "C after all"]).result?["system"] == "C")
            #expect(try await libraries(d, "F1") == ["C"])
            #expect(try await active(d, p) == ["A": ["workspace"], "C": ["floor:f1"]])
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(6)))
    func floorDeleteAppliesWorkspaceSystem() async throws {
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        try await withEngine { d, p in
            try await system(d, p, "A")
            try await system(d, p, "C", bg: "#ABCDEF")
            #expect(try await admin(d, p, "floor.create", ["name": "f1", "repo": repo.path]).ok)
            #expect(try await admin(d, p, "design.new", ["name": "F1", "floor": "f1"]).ok)
            #expect(try await use(d, p, "A").ok)
            #expect(try await use(d, p, "C", floor: "f1").ok)
            let del = try await admin(d, p, "floor.delete", ["name": "f1", "force": "true"])
            #expect(del.result?["designSystem"]?["system"] == "A" && del.result?["designSystem"]?["memoryError"] == nil, "\(del)")
            #expect(try await libraries(d, "F1") == ["A"])
            let recs = (try await admin(d, p, "memory.list", ["kind": "decision"]).result?["records"]?.a ?? [])
                .filter { $0["subject"] == "design system ativo" }
            #expect(recs.count == 1 && recs.first?["body"]?.s?.contains("floor 'f1' was deleted") == true, "\(recs)")
            #expect(try await active(d, p) == ["A": ["workspace"], "C": []])
        }
    }

    /// A copy's library is named after the copy (not its source), so `use` swaps between them both ways.
    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(6)))
    func copySwapsWithItsSource() async throws {
        try await withEngine { d, p in
            try await system(d, p, "Brand")
            #expect(try await admin(d, p, "design.system.create", ["name": "Sub", "from": "Brand", "reason": "a variant"]).ok)
            try await setVar(d, "Sub", "bg", "#ABCDEF")
            #expect(try await admin(d, p, "design.system.publish", ["name": "Sub", "reason": "its own bg"]).result?["version"] == .number(2))
            #expect(try await admin(d, p, "design.new", ["name": "S"]).ok)
            #expect(try await use(d, p, "Sub").ok)
            #expect(try await libraries(d, "S") == ["Sub"])
            let rect = try await bound(d, "S", "Sub")
            #expect(try await fill(d, "S", rect) == "#ABCDEF")
            let back = try await use(d, p, "Brand")
            #expect(outcomes(back) == ["S": true], "\(back)")
            #expect(try await libraries(d, "S") == ["Brand"])
            #expect(try await fill(d, "S", rect) == "#FAFAF7")
            #expect(try await use(d, p, "Sub").ok)
            #expect(try await libraries(d, "S") == ["Sub"])
            #expect(try await fill(d, "S", rect) == "#ABCDEF")
            // a figcraft export of a file using team libraries would carry their links: refused
            let m = try await panel(d, p, "S")
            let ex = try await call(p, m, "design.export", ["panel": "design-1", "format": "figcraft"])
            #expect(ex.error?.code == .invalidArgs && ex.error?.message.contains("team libraries") == true, "\(ex)")
            #expect(try await call(p, m, "design.export", ["panel": "design-1", "format": "html"]).ok)
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(5)))
    func undoSwapsBack() async throws {
        try await withEngine { d, p in
            try await system(d, p, "A")
            try await system(d, p, "C", bg: "#ABCDEF")
            #expect(try await admin(d, p, "design.new", ["name": "S"]).ok)
            #expect(try await admin(d, p, "design.system.undo", ["reason": "r"]).error?.code == .notFound)   // nothing before
            #expect(try await use(d, p, "A").ok)
            let rect = try await bound(d, "S", "A")
            #expect(try await use(d, p, "C").ok)
            let u = try await admin(d, p, "design.system.undo", ["reason": "C was a mistake"])
            #expect(u.result?["system"] == "A" && outcomes(u) == ["S": true], "\(u)")
            #expect(try await fill(d, "S", rect) == "#FAFAF7")
            #expect(try await active(d, p) == ["A": ["workspace"], "C": []])
            let h = try await admin(d, p, "design.system.history", ["name": "A"]).result?.a.last
            #expect(h?["kind"] == "undone" && h?["scope"] == "workspace" && h?["reason"] == "C was a mistake", "\(h ?? .null)")
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(5)))
    func newFileInScopeGetsLibrary() async throws {
        try await withEngine { d, p in
            try await system(d, p, "A")
            #expect(try await use(d, p, "A").ok)
            #expect(try await admin(d, p, "design.new", ["name": "N"]).ok)
            #expect(try await libraries(d, "N") == ["A"])
            _ = try await panel(d, p, "P")   // panel.open --file P: made, with the library
            #expect(try await libraries(d, "P") == ["A"])
        }
    }

    // MARK: active design system (fake engine)

    @Test func scopeWritePermissions() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        try await withFake(fx) { d, p in
            #expect(try await admin(d, p, "design.system.create", ["name": "A", "reason": "r"]).ok)
            let w = try await term(d, p, "W", cwd: repo.path)
            let m1 = try await term(d, p, "M1", maestro: true, cwd: repo.path)
            let m2 = try await term(d, p, "M2", maestro: true, cwd: repo.path)
            #expect(try await call(p, m1, "floor.create", ["name": "f1"]).ok)
            #expect(try await admin(d, p, "floor.create", ["name": "u1", "repo": repo.path]).ok)   // a user-created floor
            let mf = try await term(d, p, "MF", maestro: true, floor: "f1")   // a Maestro standing on f1 (made by M1)
            let mu = try await term(d, p, "MU", maestro: true, floor: "u1")
            func decisions() async throws -> Int {   // workspace ones in the global store
                (try await admin(d, p, "memory.list", ["kind": "decision"]).result?["records"]?.a ?? [])
                    .filter { $0["subject"]?.s?.hasPrefix("design system ativo") == true }.count
            }
            for (t, args) in [(w, ["name": "A", "reason": "r"]), (w, ["name": "A", "floor": "f1", "reason": "r"]),
                              (m2, ["name": "A", "floor": "f1", "reason": "r"])] {
                #expect(try await call(p, t, "design.system.use", args).error?.code == .notMaestro, "\(args)")
            }
            #expect(try await call(p, w, "design.system.undo", ["reason": "r"]).error?.code == .notMaestro)
            #expect(try await call(p, m2, "design.system.undo", ["floor": "f1", "reason": "r"]).error?.code == .notMaestro)
            // a Maestro on a floor: not the workspace (nor --none, nor undo), and not a floor it neither made nor stands in
            let onFloor = ProtocolError(code: .notMaestro, message: "only the app or a Maestro on the ground can change the workspace design system; use --floor for your floor")
            for args in [["name": "A", "reason": "r"], ["none": "true", "reason": "r"]] {
                #expect(try await call(p, mf, "design.system.use", args).error == onFloor, "\(args)")
            }
            #expect(try await call(p, mf, "design.system.undo", ["reason": "r"]).error == onFloor)
            #expect(try await call(p, mf, "design.system.use", ["name": "A", "floor": "f1", "reason": "r"]).error?.code == .notMaestro)   // M1's floor
            #expect(try await call(p, mu, "design.system.use", ["name": "A", "floor": "f1", "reason": "r"]).error?.code == .notMaestro)
            #expect(try await decisions() == 0)
            #expect(try await call(p, m1, "design.system.use", ["name": "A", "floor": "f1", "reason": "mine"]).ok)
            #expect(try await call(p, mu, "design.system.use", ["name": "A", "floor": "u1", "reason": "where I stand"]).ok)
            #expect(try await admin(d, p, "design.system.use", ["name": "A", "reason": "the app"]).ok)
            #expect(try await call(p, m2, "design.system.use", ["name": "A", "reason": "a ground Maestro"]).ok)
            // the app's and the Maestro's workspace decisions are one subject in one store: the later supersedes
            #expect(try await decisions() == 1)
            #expect(try await admin(d, p, "design.system.use", ["name": "A", "floor": "f1", "reason": "admin"]).ok)
            #expect(try await active(d, p) == ["A": ["floor:f1", "floor:u1", "workspace"]])
            #expect(try await admin(d, p, "design.system.use", ["none": "true", "reason": "clear"]).ok)
            #expect(try await active(d, p) == ["A": ["floor:f1", "floor:u1"]])
            #expect(try await decisions() == 1)
        }
    }

    @Test func newFileWarnsWhenScopeLockIsHeld() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withFake(fx, timeoutCap: .seconds(2)) { d, p in
            #expect(try await admin(d, p, "design.system.create", ["name": "A", "reason": "r"]).ok)
            #expect(try await use(d, p, "A").ok)
            try await d.router.lockDesignScopes(.now + .seconds(1))   // a scope change in flight, held for the rest of the test
            let warning = JSONValue.string("design systems are changing; library not enabled — run design.system.use again or retry")
            let n = try await admin(d, p, "design.new", ["name": "N"])
            #expect(n.ok && n.result?["designSystemError"] == warning && n.result?["designSystem"] == nil, "\(n)")
            let m = try await term(d, p, "M", maestro: true)
            let o = try await call(p, m, "panel.open", ["plugin": "design", "file": "P", "placement": "canvas"])
            #expect(o.ok && o.result?["designSystemError"] == warning && o.result?["name"] == "design-1", "\(o)")
        }
    }

    @Test func publishWaitsForScopeChanges() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withFake(fx, timeoutCap: .seconds(2)) { d, p in
            #expect(try await admin(d, p, "design.system.create", ["name": "A", "reason": "r"]).ok)
            try await d.router.lockDesignScopes(.now + .seconds(1))   // a scope change in flight, held for the rest of the test
            let r = try await admin(d, p, "design.system.publish", ["name": "A", "reason": "r"])
            #expect(r.error == ProtocolError(code: .timeout, message: "design systems are changing; try again"), "\(r)")
            #expect(try await admin(d, p, "design.system.list").result?.a.first?["version"] == .number(1))
        }
    }

    @Test func useWithNoneRejected() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withFake(fx) { d, p in
            #expect(try await admin(d, p, "design.system.create", ["name": "A", "reason": "r"]).ok)
            let r = try await admin(d, p, "design.system.use", ["name": "A", "none": "true", "reason": "r"])
            #expect(r.error == ProtocolError(code: .invalidArgs, message: "pass a design system or --none, not both"), "\(r)")
            #expect(try await active(d, p) == ["A": []])
        }
    }

    @Test func useMissingSystemNotFound() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withFake(fx) { d, p in
            #expect(try await use(d, p, "Nope").error?.code == .notFound)
            #expect(try await admin(d, p, "design.system.use", ["name": "Nope", "floor": "nofloor", "reason": "r"]).error?.code == .notFound)
            #expect(try await admin(d, p, "design.system.use", ["name": "A"]).error?.code == .invalidArgs)   // a reason is needed
            let recs = try await admin(d, p, "memory.list", ["kind": "decision"]).result?["records"]?.a ?? []
            #expect(recs.isEmpty, "\(recs)")
        }
    }

    @Test func floorDeleteClearsOverride() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        let repo = try await makeRepo(); defer { try? FileManager.default.removeItem(at: repo) }
        try await withFake(fx) { d, p in
            #expect(try await admin(d, p, "design.system.create", ["name": "A", "reason": "r"]).ok)
            #expect(try await admin(d, p, "floor.create", ["name": "f1", "repo": repo.path]).ok)
            #expect(try await admin(d, p, "design.new", ["name": "F", "floor": "f1"]).ok)
            #expect(try await use(d, p, "A", floor: "f1").ok)
            #expect(try await active(d, p) == ["A": ["floor:f1"]])
            #expect(try await admin(d, p, "floor.delete", ["name": "f1", "force": "true"]).ok)
            let after = try await active(d, p)
            #expect(after == ["A": []], "\(after)")
            // its file is on the ground now: the workspace's system reaches it
            let r = try await use(d, p, "A")
            #expect(outcomes(r) == ["F": true], "\(r)")
        }
    }

    @Test func oneFileFailureDoesNotUndoOthers() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withFake(fx) { d, p in
            try fx.set("named-links")   // each file's link names it: a flag can break one file's clients
            #expect(try await admin(d, p, "design.system.create", ["name": "A", "reason": "r"]).ok)
            for f in ["Good", "Bad"] { #expect(try await admin(d, p, "design.new", ["name": f]).ok) }
            try fx.set("fail-collab.join@Bad")
            let r = try await use(d, p, "A", reason: "half")
            #expect(r.ok && outcomes(r) == ["Good": true, "Bad": false], "\(r)")
            #expect(!leaks(text(r)))
            #expect(try await active(d, p) == ["A": ["workspace"]])
            let h = try await admin(d, p, "design.system.history", ["name": "A"]).result?.a.last
            #expect(h?["files"]?.a.count == 2, "\(h ?? .null)")
            let recs = try await admin(d, p, "memory.list", ["kind": "decision"]).result?["records"]?.a ?? []
            #expect(recs.contains { $0["subject"] == "design system ativo" && $0["body"]?.s?.contains("Bad") == true }, "\(recs)")
        }
    }

    // MARK: agent wrappers (Task 3)

    /// M (corded to canvas panel `design-1` on screen file `S`), with system `A` active in the workspace.
    private func screen(_ d: Daemon, _ p: Paths, systems: [(String, String?)] = [("A", nil)]) async throws -> Term {
        for (n, bg) in systems { try await system(d, p, n, bg: bg) }
        #expect(try await use(d, p, systems[0].0).ok)
        return try await panel(d, p, "S")
    }
    private func node(_ p: Paths, _ m: Term, _ params: String) async throws -> String {
        let r = try await run(p, m, "design-1", "node.create", params)
        return "\(Int(try #require(r["id"]?.n, "\(r)")))"
    }
    /// S's layer `id` shows fill `hex` on the daemon's client within 10 s (an agent's edit reaches it through the server).
    private func filled(_ d: Daemon, _ id: String, _ hex: String) async -> Bool {
        await waitFor(10) { (try? await self.fill(d, "S", .number(Double(id) ?? 0))) == hex }
    }
    private func ds(_ p: Paths, _ t: Term, _ verb: String, _ args: [String: String]) async throws -> Response {
        var a = args; a["panel"] = "design-1"
        return try await call(p, t, "design.system.\(verb)", a)
    }
    private func inspect(_ p: Paths, _ m: Term, _ id: String) async throws -> JSONValue {
        let r = try await call(p, m, "design.inspect", ["panel": "design-1", "node": id])
        return try #require(r.result, "\(r)")
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(5)))
    func agentBindsTokenFromActiveSystem() async throws {
        try await withEngine { d, p in
            let m = try await screen(d, p, systems: [("A", nil), ("C", "#ABCDEF")])
            let rect = try await node(p, m, #"{"type":"rectangle","width":10,"height":10}"#)
            let r = try await ds(p, m, "bind", ["variable": "bg", "field": "fill", "ids": rect])
            #expect(r.ok, "\(r)")
            #expect(await filled(d, rect, "#FAFAF7"))
            #expect(try await use(d, p, "C").ok)
            #expect(await filled(d, rect, "#ABCDEF"))
            // the agent's next binding comes from C now
            let r2 = try await node(p, m, #"{"type":"rectangle","width":10,"height":10}"#)
            #expect(try await ds(p, m, "bind", ["variable": "bg", "field": "fill", "ids": r2]).ok)
            #expect(await filled(d, r2, "#ABCDEF"))
            let t = try await ds(p, m, "tokens", [:])
            #expect(t.result?["name"] == "C" && t.result?["path"] == nil && t.result?["server"] == nil, "\(t)")
            let vars = Set(t.result?["variables"]?.a.compactMap { $0["name"]?.s } ?? [])
            #expect(vars.isSuperset(of: ["bg", "accent", "type/h2"]), "\(t)")
            #expect(t.result?["collections"]?.a.first?["modes"]?.a.compactMap { $0["name"]?.s } == ["Light", "Dark"], "\(t)")
            #expect(t.result?["styles"]?.a.contains { $0["name"] == "Heading" } == true, "\(t)")
            #expect(t.result?["components"]?.a.contains { $0["name"] == "Button" } == true, "\(t)")
            #expect(!leaks(text(r)) && !leaks(text(t)))
            let bad = try await ds(p, m, "bind", ["variable": "nope", "field": "fill", "ids": rect])
            #expect(bad.error != nil && !leaks(text(bad)), "\(bad)")
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(5)))
    func agentAppliesStyleAndPlacesComponent() async throws {
        try await withEngine { d, p in
            let m = try await screen(d, p)
            let label = try await node(p, m, #"{"type":"text","text":"Hello"}"#)
            let s = try await ds(p, m, "style", ["style": "Heading", "ids": label])
            #expect(s.ok, "\(s)")
            let t = try await inspect(p, m, label)
            #expect(t["fontSize"] == .number(28) && t["styles"]?["text"]?.s?.contains(":S:") == true, "\(t)")   // Heading (type/h2)
            let pl = try await ds(p, m, "place", ["component": "Button", "x": "40", "y": "-20.5"])
            #expect(pl.ok, "\(pl)")
            let id = try #require(pl.result?["id"]?.n, "\(pl)")
            let inst = try await inspect(p, m, "\(Int(id))")
            #expect(inst["type"]?.s?.uppercased() == "INSTANCE" && inst["name"] == "Button", "\(inst)")
            #expect(inst["boundVariables"]?["fill"]?.s?.contains(":VariableID:") == true, "\(inst)")   // accent, from the library
            #expect(try await ds(p, m, "place", ["component": "Nope"]).error != nil)
            #expect(try await ds(p, m, "place", ["component": "Button", "x": "nan"]).error?.code == .invalidArgs)
            #expect(try await ds(p, m, "style", ["style": "Heading", "ids": label, "target": "glow"]).error?.code == .invalidArgs)
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(5)))
    func modeSwitchesLightDark() async throws {
        try await withEngine { d, p in
            let m = try await screen(d, p)
            let frame = try await node(p, m, #"{"type":"frame","width":100,"height":100}"#)
            let rect = try await node(p, m, #"{"type":"rectangle","width":10,"height":10,"parent":\#(frame)}"#)
            #expect(try await ds(p, m, "bind", ["variable": "bg", "field": "fill", "ids": rect]).ok)
            let dark = try await ds(p, m, "mode", ["mode": "Dark", "ids": frame])
            #expect(dark.ok, "\(dark)")
            #expect(await filled(d, rect, "#111317"))
            #expect(try await ds(p, m, "mode", ["mode": "Light", "ids": frame]).ok)
            #expect(await filled(d, rect, "#FAFAF7"))
            #expect(try await ds(p, m, "mode", ["mode": "Sepia"]).error != nil)
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(5)))
    func agentCannotPickLibraryOrServer() async throws {
        try await withEngine { d, p in
            let m = try await screen(d, p, systems: [("A", nil), ("C", "#ABCDEF")])
            let rect = try await node(p, m, #"{"type":"rectangle","width":10,"height":10}"#)
            // extra fields naming another library, a server or a path are ignored: the file's system (A) is used
            let r = try await ds(p, m, "bind", ["variable": "bg", "field": "fill", "ids": rect, "library": "C",
                                                "server": "ws://127.0.0.1:1/?key=x", "path": "/etc/passwd"])
            #expect(r.ok, "\(r)")
            #expect(await filled(d, rect, "#FAFAF7"))
            // the 2A allowlist still refuses library.* to agents
            let run = try await call(p, m, "design.run", ["panel": "design-1", "command": "library.bindVariable",
                                                          "params": #"{"library":"C","variable":"bg","field":"fill","ids":[\#(rect)]}"#])
            #expect(run.error?.code == .invalidArgs, "\(run)")
            let batch = try await call(p, m, "design.batch", ["panel": "design-1",
                                                              "commands": #"[{"command":"library.list"}]"#])
            #expect(batch.error?.code == .invalidArgs, "\(batch)")
        }
    }

    @Test func wrappersNeedCord() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withFake(fx) { d, p in
            #expect(try await admin(d, p, "design.system.create", ["name": "A", "reason": "r"]).ok)
            #expect(try await use(d, p, "A").ok)
            let m = try await panel(d, p, "S")
            let w = try await term(d, p, "W")
            for (verb, a) in [("tokens", [:]), ("bind", ["variable": "bg", "field": "fill", "ids": "2"]),
                              ("style", ["style": "Heading", "ids": "2"]), ("place", ["component": "Button"]),
                              ("mode", ["mode": "Dark"])] as [(String, [String: String])] {
                #expect(try await ds(p, w, verb, a).error?.code == .notConnected, "\(verb)")
            }
            // validated before the engine is reached
            for a in [["variable": "bg", "field": "fill", "ids": "x1"], ["variable": "bg", "field": "fill", "ids": ""],
                      ["variable": String(repeating: "v", count: 201), "field": "fill", "ids": "2"],
                      ["variable": "bg", "ids": "2"]] {
                #expect(try await ds(p, m, "bind", a).error?.code == .invalidArgs, "\(a)")
            }
            for f in ["hyperlink", "Hyperlink "] {   // a variable's value is never checked as a link
                #expect(try await ds(p, m, "bind", ["variable": "bg", "field": f, "ids": "2"]).error
                        == ProtocolError(code: .invalidArgs, message: "a link can't be bound to a variable"))
            }
            let help = try await call(p, m, "design.help", ["query": "design.system"]).result?.a ?? []
            let ids = Set(help.compactMap { $0["id"]?.s })
            #expect(ids.isSuperset(of: ["design.system.tokens", "design.system.bind", "design.system.style", "design.system.place",
                                        "design.system.mode", "design.system.use"]), "\(help)")
            #expect(help.allSatisfy { ($0["help"]?.s?.isEmpty == false) })
        }
    }

    @Test func noActiveSystemIsClearError() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withFake(fx) { d, p in
            #expect(try await admin(d, p, "design.system.create", ["name": "A", "reason": "r"]).ok)
            let m = try await panel(d, p, "S")   // nothing active
            let want = ProtocolError(code: .invalidArgs, message: "no active design system for this file")
            #expect(try await ds(p, m, "bind", ["variable": "bg", "field": "fill", "ids": "2"]).error == want)
            #expect(try await ds(p, m, "tokens", [:]).error == want)
            // a design system's own file uses no system
            #expect(try await use(d, p, "A").ok)
            let r = try await call(p, m, "panel.open", ["plugin": "design", "file": "A", "placement": "canvas"])
            #expect(r.ok, "\(r)")
            let name = try #require(r.result?["name"]?.s)
            #expect(try await call(p, m, "design.system.place", ["panel": name, "component": "Button"]).error == want)
        }
    }

    private func sync(_ c: MCPStdioClient, _ t: Duration) async throws { _ = try await c.command("collab.peers", [:], timeout: t) }
} }
