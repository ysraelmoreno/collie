import AppKit
import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit
@testable import ColliePlugins

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures")
let vendorFigcraft = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("vendor/figcraft")
let vendorEngineSrc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("vendor/figcraft-src/crates/engine/src")
let realBuilt = FileManager.default.isExecutableFile(atPath: vendorFigcraft.appendingPathComponent("bin/figcraft-cli").path)
    && FileManager.default.isExecutableFile(atPath: vendorFigcraft.appendingPathComponent("bin/figcraft-server").path)

/// A figcraft dir whose `bin/` holds the fakes; the fake MCP logs to `log` (read from the environment: in-process daemon).
private struct Fx {
    let dir = URL(fileURLWithPath: "/tmp/collie-fig-\(UUID().uuidString.prefix(8))")
    var log: URL { dir.appendingPathComponent("calls.log") }
    init() throws {
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("figcraft-cli"),
                                                   withDestinationURL: fixtures.appendingPathComponent("fake-figcraft-mcp.py"))
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("figcraft-server"),
                                                   withDestinationURL: fixtures.appendingPathComponent("fake-figcraft-server.sh"))
        try Data().write(to: log)
        setenv("COLLIE_FAKE_FIG_LOG", log.path, 1)
    }
    var calls: [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

private func withDesign(_ fx: Fx?, idle: Duration = .seconds(300), timeoutCap: Duration? = nil,
                        _ body: (Daemon, Paths) async throws -> Void) async throws {
    try await withDaemon(configure: { c in
        c.figcraftDir = fx?.dir ?? vendorFigcraft
        c.designIdle = idle
        c.designTimeoutCap = timeoutCap
    }, body)
}
/// The port the daemon's figcraft server is on now.
private func serverPort(_ d: Daemon) async throws -> UInt16 {
    let (url, _) = try await d.router.figcraft.ensureRunning()
    guard let m = url.firstMatch(of: /:(\d+)\//), let port = UInt16(m.1) else { throw ProtocolError(code: .internal, message: url) }
    return port
}
private struct Term { var id: String; var token: String }
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 120)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, shepherd: Bool = false) async throws -> Term {
    let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn",
        args: ["name": .string(name), "preset": .string("shell"), "cwd": .string("/tmp"), "shepherd": .bool(shepherd)]),
        to: p.socket, timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:], cwd: String? = nil) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd,
                                            args: args.mapValues { .string($0) }, cwd: cwd), to: p.socket, timeoutSeconds: 120)
}
private func field(_ r: Response, _ k: String) -> JSONValue? {
    if case .object(let o)? = r.result { return o[k] } else { return nil }
}
private func text(_ r: Response) -> String {
    let e = JSONEncoder(); e.outputFormatting = .withoutEscapingSlashes
    return String(decoding: (try? e.encode(r)) ?? Data(), as: UTF8.self)
}
/// Shepherd `M` with a design panel `design-1` on file `file` (canvas: leashed to M).
private func shepherdWithPanel(_ d: Daemon, _ p: Paths, file: String = "Site", placement: String = "canvas") async throws -> Term {
    let m = try await term(d, p, "M", shepherd: true)
    let r = try await call(p, m, "panel.open", ["plugin": "design", "file": file, "placement": placement])
    #expect(r.ok, "\(r)")
    return m
}

@Suite(.serialized) struct DesignCommandTests {
    @Test func newFileThenOpenPanel() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let r = try await admin(d, p, "design.new", ["name": "Site"])
            #expect(r.ok && field(r, "name") == .string("Site"), "\(r)")
            #expect(fx.calls.contains("initialize collie-bridge"), "\(fx.calls)")
            let m = try await term(d, p, "M", shepherd: true)
            let o = try await call(p, m, "panel.open", ["plugin": "design", "file": "Site", "placement": "dock.right"])
            guard case .object(let st)? = field(o, "state"), case .string(let fid)? = st["file"] else { Issue.record("\(o)"); return }
            #expect(!fid.isEmpty)
            let files = try await call(p, m, "design.files")
            #expect(files.result == .array([.object(["name": .string("Site"), "panels": .array([.string("design-1")])])]), "\(files)")
            // names are unique without case
            let dup = try await admin(d, p, "design.new", ["name": "site"])
            #expect(dup.error?.code == .invalidArgs, "\(dup)")
            // panel.open on a new name creates the file
            #expect(try await call(p, m, "panel.open", ["plugin": "design", "file": "Other", "placement": "dock.left"]).ok)
            guard case .array(let rows)? = try await admin(d, p, "design.files").result else { Issue.record("no files"); return }
            #expect(rows.count == 2)
            // the registry is private to the daemon
            let reg = p.root.appendingPathComponent("design/files.json")
            let mode = try FileManager.default.attributesOfItem(atPath: reg.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
            #expect(try await call(p, m, "panel.open", ["plugin": "design", "placement": "dock.left"]).error?.code == .invalidArgs)
        }
    }

    /// A Shepherd opens a design panel, then summons designers wired to it: each reaches the panel, not each other.
    @Test func summonConnectsDesignersToPanel() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            var designers: [Term] = []
            for n in ["designer-1", "designer-2"] {
                let r = try await call(p, m, "summon", ["name": n, "preset": "shell", "connect": "design-1"])
                guard case .string(let id)? = field(r, "id") else { Issue.record("\(r)"); return }
                designers.append(Term(id: id, token: try await tokenOf(d, id)))
            }
            for t in designers {
                let l = try await call(p, t, "panel.list")
                guard case .array(let rows)? = l.result else { Issue.record("\(l)"); return }
                #expect(rows.contains { if case .object(let o) = $0 { o["name"] == .string("design-1") } else { false } }, "\(l)")
                let files = try await call(p, t, "design.files")   // design gating: the panel is reachable for it
                #expect(files.result == .array([.object(["name": .string("Site"), "panels": .array([.string("design-1")])])]), "\(files)")
            }
            let s = try await UnixSocketClient.send(Request(id: "s", token: d.adminToken, command: "ui.snapshot"), to: p.socket, timeoutSeconds: 30)
            let snap = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(s.result))
            let panel = try #require(snap.panels.first { $0.name == "design-1" })
            #expect(snap.connections.filter { $0.a == panel.id || $0.b == panel.id }.count == 3, "\(snap.connections)")
            let ids = Set(designers.compactMap { UUID(uuidString: $0.id) })
            #expect(!snap.connections.contains { Set([$0.a, $0.b]) == ids })
        }
    }

    @Test func fileNamesAreValidated() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            for bad in ["../x", "a/b", "", String(repeating: "a", count: 81), "con\u{0}", "..", "a..b", "tab\there"] {
                let r = try await admin(d, p, "design.new", ["name": bad])
                #expect(r.error?.code == .invalidArgs, "\(bad.debugDescription): \(r)")
            }
            #expect(try await admin(d, p, "design.new", ["name": String(repeating: "a", count: 80)]).ok)
            #expect(try await admin(d, p, "design.new", ["name": "My site v2.1_final-b"]).ok)
        }
    }

    @Test func runAndBatchUseCallerClient() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            let w = try await term(d, p, "W")
            #expect(try await admin(d, p, "admin.leash", ["a": "W", "b": "design-1"]).ok)
            let a = try await call(p, m, "design.run", ["command": "node.create", "params": #"{"type":"frame"}"#])
            #expect(a.ok && field(a, "command") == .string("node.create"), "\(a)")
            #expect(try await call(p, w, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#]).ok)
            let inits = fx.calls.filter { $0.hasPrefix("initialize ") }
            #expect(inits.contains("initialize M") && inits.contains("initialize W"), "\(inits)")
            // each client joined the file before its first command
            #expect(fx.calls.filter { $0 == "tools/call run_command collab.join" }.count == 2, "\(fx.calls)")
            let b = try await call(p, m, "design.batch", ["commands": #"[{"command":"node.create","params":{"type":"frame"}},{"command":"node.create"}]"#,
                                                         "label": "Two"])
            #expect(b.result == .array([.object(["id": .number(4294967297)]), .object(["id": .number(4294967298)])]), "\(b)")
            #expect(try await call(p, m, "design.run", ["command": "node.set", "params": "[1]"]).error?.code == .invalidArgs)
            #expect(try await call(p, m, "design.batch", ["commands": #"{"command":"x"}"#]).error?.code == .invalidArgs)
        }
    }

    @Test func badBatchLeavesDocumentUnchanged() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            let before = try await call(p, m, "design.inspect")
            let r = try await call(p, m, "design.batch", ["commands": #"[{"command":"node.create"},{"command":"node.bad.x"},{"command":"node.create"}]"#])
            #expect(r.error?.code == .internal && r.error?.message.contains("step 2") == true
                    && r.error?.message.contains("bad.x") == true, "\(r)")
            let after = try await call(p, m, "design.inspect")
            #expect(before.ok && before.result == after.result, "\(before) / \(after)")
            // not an engine refusal (the reply was lost): no claim about what was applied
            let lost = try await call(p, m, "design.batch", ["commands": #"[{"command":"node.big"}]"#])
            #expect(lost.error?.message == "design engine reply too large (over 16 MiB)", "\(lost)")
            // a batch from a .json file relative to the caller's cwd
            let dir = p.root.appendingPathComponent("work")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(#"[{"command":"node.create"}]"#.utf8).write(to: dir.appendingPathComponent("b.json"))
            let f = try await call(p, m, "design.batch", ["file": "b.json"], cwd: dir.path)
            #expect(f.result == .array([.object(["id": .number(4294967297)])]), "\(f)")
            #expect(try await call(p, m, "design.batch", ["file": "nope.json"], cwd: dir.path).error?.code == .invalidArgs)
        }
    }

    @Test func oversizedBatchRefused() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            let big = "[" + String(repeating: #"{"command":"node.create"},"#, count: 5 << 20 / 25) + #"{"command":"node.create"}]"#
            // over the request limit: refused before the daemon sees it
            do { #expect(try await call(p, m, "design.batch", ["commands": big]).error?.code == .invalidArgs) }
            catch let e as ProtocolError { #expect(e.code == .invalidArgs, "\(e)") }
            // the same size from a file (no request limit in the way)
            let dir = p.root.appendingPathComponent("work")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(big.utf8).write(to: dir.appendingPathComponent("big.json"))
            let r = try await call(p, m, "design.batch", ["file": "big.json"], cwd: dir.path)
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("4 MiB") == true, "\(r)")
            #expect(!fx.calls.contains { $0.hasPrefix("tools/call batch") }, "\(fx.calls)")
        }
    }

    @Test func readsSyncFirst() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "design.inspect", ["node": "4294967312", "depth": "2"])
            #expect(field(r, "id") == .number(4294967312), "\(r)")
            let c = fx.calls
            guard let get = c.lastIndex(of: "tools/call get_node ") else { Issue.record("\(c)"); return }
            #expect(c[get - 1] == "tools/call run_command collab.peers", "\(c)")
            let doc = try await call(p, m, "design.inspect")
            #expect(doc.ok && fx.calls.suffix(2) == ["tools/call run_command collab.peers", "tools/call inspect_document "], "\(doc) \(fx.calls)")
        }
    }

    @Test func canvasDesignNeedsLeash() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            _ = try await shepherdWithPanel(d, p)
            let w = try await term(d, p, "w")
            #expect(try await call(p, w, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#, "panel": "design-1"]).error?.code == .notConnected)
            #expect(try await call(p, w, "design.inspect").error?.code == .notFound)
            #expect(try await admin(d, p, "admin.leash", ["a": "w", "b": "design-1"]).ok)
            let r = try await call(p, w, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#])
            #expect(r.ok, "\(r)")
        }
    }

    @Test func linkIsAdminOnly() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            #expect(Commands.spec("design.link")?.exposedToMCP == false)
            #expect(try await call(p, m, "design.link").error?.code == .unauthorized)
            let r = try await admin(d, p, "design.link", ["panel": "design-1"])
            guard case .string(let link)? = field(r, "editLink") else { Issue.record("\(r)"); return }
            #expect(link.hasPrefix("figcraft://") && link.contains("token="), "\(link)")
        }
    }

    @Test func agentsNeverSeeLink() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            var seen: [Response] = []
            for (cmd, args) in [("design.files", [:]), ("design.run", ["command": "align.left", "params": #"{"ids":[1]}"#]), ("design.run", ["command": "node.bad.leak"]),
                                ("design.run", ["command": "collab.peers"]), ("design.run", ["command": "collab.share"]),
                                ("design.batch", ["commands": #"[{"command":"node.bad.leak"}]"#]),
                                ("design.batch", ["commands": #"[{"command":"collab.leave"}]"#]),
                                ("design.inspect", [:]), ("design.help", [:]), ("design.export", ["format": "html"])] as [(String, [String: String])] {
                seen.append(try await call(p, m, cmd, args))
            }
            for r in seen {
                let t = text(r)
                #expect(!t.contains("figcraft://") && !t.contains("token=") && !t.contains("fakeKey_123-abc") && !t.contains("fakeToken"), "\(t)")
            }
            #expect(seen[2].error?.message.contains("cannot reach") == true, "\(seen[2])")   // still says what failed
            #expect(seen[3].error?.code == .invalidArgs && seen[4].error?.code == .invalidArgs && seen[6].error?.code == .invalidArgs)
            #expect(!fx.calls.contains { $0.contains("collab.share") || $0.contains("collab.leave") })
        }
    }

    @Test func onlyEditingCommandsRun() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            for cmd in ["library.publishToServer", "plugin.directory.install", "plugin.run", "file.open", "app.quit", "collab.leave",
                        "command.batch", "pref.publishServer", "edit.paste", "nodot"] {
                let r = try await call(p, m, "design.run", ["command": cmd, "params": #"{"server":"ws://example.com/"}"#])
                #expect(r.error == ProtocolError(code: .invalidArgs, message: "design command '\(cmd)' is not available to agents"), "\(r)")
                let b = try await call(p, m, "design.batch", ["commands": #"[{"command":"node.create"},{"command":"\#(cmd)"}]"#])
                #expect(b.error?.code == .invalidArgs && b.error?.message.contains("'\(cmd)'") == true, "\(b)")
            }
            // allowed commands that could name a file: only their in-memory forms
            for (cmd, params) in [("image.place", #"{"path":"/etc/hosts"}"#), ("variable.export", #"{"path":"/tmp/v.json"}"#),
                                  ("component.playground", #"{"path":"/tmp/p.png"}"#), ("variable.import", #"{"variables":"/etc/v.json"}"#),
                                  ("text.preview", #"{"command":"library.applyStyle","params":{}}"#), ("text.preview", #"{"params":{}}"#)] {
                #expect(try await call(p, m, "design.run", ["command": cmd, "params": params]).error?.code == .invalidArgs, "\(cmd)")
                #expect(try await call(p, m, "design.batch", ["commands": #"[{"command":"\#(cmd)","params":\#(params)}]"#]).error?.code == .invalidArgs)
            }
            #expect(try await call(p, m, "design.run", ["command": "variable.import", "params": #"{"variables":{}}"#]).ok)
            #expect(try await call(p, m, "design.run", ["command": "text.preview", "params": #"{"command":"style.apply","params":{"ids":[1]}}"#]).ok)
            #expect(try await call(p, m, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#]).ok)
            #expect(!fx.calls.contains { $0.contains("publishToServer") || $0.contains("file.open") || $0.contains("app.quit")
                                         || $0.contains("plugin.") || $0.contains("image.place") || $0.contains("tools/call batch") }, "\(fx.calls)")
            let help = text(try await call(p, m, "design.help"))
            #expect(!help.contains("file.open") && !help.contains("plugin.run") && help.contains("node.create"), "\(help)")
        }
    }

    @Test func agentCanLink() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "design.run", ["command": "text.link", "params": #"{"url":"https://example.com","ids":[1]}"#])
            #expect(r.ok, "\(r)")
            #expect(fx.calls.contains { $0.contains("text.link") }, "\(fx.calls)")
        }
    }

    @Test func unsafeLinksRefusedEverywhere() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            let before = fx.calls.count
            for bad in ["javascript:alert(1)", "data:text/html,x", "JAVASCRIPT:x", " javascript:x", "\\njavascript:x", ""] {
                for (cmd, params) in [("text.link", #"{"url":"\#(bad)","ids":[1]}"#), ("text.style", #"{"hyperlink":"\#(bad)","ids":[1]}"#),
                                      ("node.set", #"{"ids":[1],"hyperlink":"\#(bad)"}"#), ("node.set", #"{"ids":[1],"props":{"hyperlink":"\#(bad)"}}"#),
                                      ("node.create", #"{"type":"frame","props":{"hyperlink":"\#(bad)"}}"#), ("text.create", #"{"props":{"hyperlink":"\#(bad)"}}"#),
                                      ("text.preview", #"{"command":"text.style","params":{"hyperlink":"\#(bad)"}}"#)] {
                    let r = try await call(p, m, "design.run", ["command": cmd, "params": params])
                    #expect(r.error == ProtocolError(code: .invalidArgs, message: "link must be http(s), mailto, tel, #anchor or a relative path"), "\(cmd) \(r)")
                    let b = try await call(p, m, "design.batch", ["commands": #"[{"command":"node.create"},{"command":"\#(cmd)","params":\#(params)}]"#])
                    #expect(b.error?.code == .invalidArgs, "\(b)")
                }
            }
            // nor from a variable (its value is never checked)
            for (cmd, params) in [("variable.bind", #"{"ids":[1],"field":"hyperlink","variable":"v"}"#),
                                  ("variable.bind", #"{"ids":[1],"field":" Hyperlink","variable":"v"}"#),
                                  ("style.bind", #"{"style":"s","field":"hyperlink","variable":"v"}"#),
                                  ("node.set", #"{"ids":[1],"boundVariables":{"hyperlink":"v"}}"#),
                                  ("node.set", #"{"ids":[1],"props":{"boundVariables":{"HYPERLINK":"v"}}}"#),
                                  ("node.create", #"{"type":"frame","props":{"boundVariables":{"hyperlink":"v"}}}"#)] {
                let r = try await call(p, m, "design.run", ["command": cmd, "params": params])
                #expect(r.error == ProtocolError(code: .invalidArgs, message: "a link can't be bound to a variable"), "\(cmd) \(r)")
                let b = try await call(p, m, "design.batch", ["commands": #"[{"command":"node.create"},{"command":"\#(cmd)","params":\#(params)}]"#])
                #expect(b.error?.code == .invalidArgs, "\(b)")
            }
            #expect(!fx.calls.dropFirst(before).contains { $0.contains("text.link") || $0.contains("hyperlink") || $0.contains("node.create") }, "\(fx.calls)")
        }
    }

    /// figcraft resolves a batch's `{"$step": n}` references after the daemon's checks: none where a check looks.
    @Test func stepReferencesRefusedInCheckedParams() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            let before = fx.calls.count
            let probe = #"""
                [{"command":"text.create","params":{"props":{"characters":"click"}}},
                 {"command":"variable.createCollection","params":{"name":"c"}},
                 {"command":"variable.create","params":{"collection":"c","name":"v","type":"string","value":"javascript:alert(1)"}},
                 {"command":"node.create","params":{"type":"frame"}},
                 {"command":"component.create","params":{"ids":[{"$step":3}]}},
                 {"command":"component.addProperty","params":{"id":{"$step":4},"name":"hyperlink","type":"boolean","default":true}},
                 {"command":"variable.bind","params":{"ids":[{"$step":0}],"variable":{"$step":2},"field":{"$step":5,"field":"name"}}}]
                """#
            let r = try await call(p, m, "design.batch", ["commands": probe])
            #expect(r.error == ProtocolError(code: .invalidArgs, message: "step references are not allowed in 'field'"), "\(r)")
            for (step, what) in [(#"{"command":"variable.import","params":{"variables":{"$step":0,"field":"name"}}}"#, "variables"),
                                 (#"{"command":"variable.import","params":{"variables":{"a":[{"$step":0}]}}}"#, "variables"),
                                 (#"{"command":"node.set","params":{"$step":0,"field":"x"}}"#, "params"),
                                 (#"{"command":"node.set","params":{"ids":[1],"props":{"$step":0,"field":"x"}}}"#, "props"),
                                 (#"{"command":"node.set","params":{"ids":[1],"boundVariables":{"$step":0}}}"#, "boundVariables"),
                                 (#"{"command":"node.set","params":{"ids":[1],"boundVariables":{"fill":{"$step":0}}}}"#, "boundVariables"),
                                 (#"{"command":"node.create","params":{"type":"frame","props":{"boundVariables":{"hyperlink":{"$step":0}}}}}"#, "props.boundVariables"),
                                 (#"{"command":"node.set","params":{"ids":[1],"hyperlink":{"$step":0,"field":"name"}}}"#, "hyperlink"),
                                 (#"{"command":"text.link","params":{"ids":[1],"url":{"$step":0,"field":"name"}}}"#, "url"),
                                 (#"{"command":"text.preview","params":{"command":"text.style","params":{"$step":0}}}"#, "params"),
                                 (#"{"command":"text.preview","params":{"command":{"$step":0,"field":"name"}}}"#, "command")] {
                let b = try await call(p, m, "design.batch", ["commands": "[{\"command\":\"node.create\"},\(step)]"])
                #expect(b.error == ProtocolError(code: .invalidArgs, message: "step references are not allowed in '\(what)'"), "\(step) \(b)")
            }
            #expect(fx.calls.count == before, "\(fx.calls)")
            // elsewhere they stay allowed
            let ok = try await call(p, m, "design.batch", ["commands": #"""
                [{"command":"node.create","params":{"type":"frame"}},
                 {"command":"node.create","params":{"type":"text","parent":{"$step":0}}},
                 {"command":"variable.bind","params":{"ids":[{"$step":1}],"field":"fill","variable":{"$step":0,"field":"id"}}}]
                """#])
            #expect(ok.ok, "\(ok)")
        }
    }

    @Test func previewParamsMustBeObject() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            let before = fx.calls.count
            for params in [#""{\"hyperlink\":\"javascript:x\"}""#, "[]", "1"] {
                let args = #"{"command":"text.style","params":\#(params)}"#
                let r = try await call(p, m, "design.run", ["command": "text.preview", "params": args])
                #expect(r.error == ProtocolError(code: .invalidArgs, message: "text.preview params must be an object"), "\(r)")
                let b = try await call(p, m, "design.batch", ["commands": #"[{"command":"text.preview","params":\#(args)}]"#])
                #expect(b.error?.code == .invalidArgs, "\(b)")
            }
            #expect(fx.calls.count == before, "\(fx.calls)")
        }
    }

    @Test func linkRemovalAllowed() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            for (cmd, params) in [("text.style", #"{"hyperlink":null,"ids":[1]}"#), ("node.set", #"{"ids":[1],"props":{"hyperlink":null}}"#),
                                  ("variable.bind", #"{"ids":[1],"field":"hyperlink","variable":null}"#),   // unbinding
                                  ("node.set", #"{"ids":[1],"boundVariables":{"hyperlink":null}}"#)] {
                let r = try await call(p, m, "design.run", ["command": cmd, "params": params])
                #expect(r.ok, "\(cmd) \(r)")
            }
        }
    }

    // plan 2O Task 3: an agent's empty filter result is a no-op; selection edits never fall back to the user's selection
    @Test func emptyBatchIsNoOp() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "design.batch", ["commands": "[]"])
            #expect(r.ok && r.result == .object(["results": .array([])]), "\(r)")
            #expect(!fx.calls.contains { $0.hasPrefix("tools/call batch") }, "\(fx.calls)")
        }
    }

    @Test func deleteWithEmptyIdsIsNoOp() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            let skipped = JSONValue.object(["skipped": .string("no ids")])
            let one = try await call(p, m, "design.run", ["command": "edit.delete", "params": #"{"ids": []}"#])
            #expect(one.ok && one.result == skipped, "\(one)")
            let alone = try await call(p, m, "design.batch", ["commands": #"[{"command":"edit.delete","params":{"ids":[]}}]"#])
            #expect(alone.ok && alone.result == .object(["results": .array([skipped])]), "\(alone)")
            #expect(!fx.calls.contains { $0.contains("edit.delete") || $0.hasPrefix("tools/call batch") }, "\(fx.calls)")
            // among other steps: dropped from the engine's batch, its place kept in the results
            let mixed = try await call(p, m, "design.batch", ["commands": #"[{"command":"node.create"},{"command":"edit.delete","params":{"ids":[]}},{"command":"node.create"}]"#])
            #expect(mixed.result == .array([.object(["id": .number(4294967297)]), skipped, .object(["id": .number(4294967298)])]), "\(mixed)")
        }
    }

    @Test func stepRefsRenumberedPastSkippedSteps() throws {
        let steps: [JSONValue] = [
            .object(["command": .string("node.create")]),
            .object(["command": .string("edit.delete"), "params": .object(["ids": .array([])])]),
            .object(["command": .string("node.set"), "params": .object(["ids": .array([.object(["$step": .number(0)])])])]),
            .object(["command": .string("node.set"), "params": .object(["ids": .array([.object(["$step": .number(2)])])])]),
        ]
        let out = try DesignService.withoutSkipped(steps, skip: [1])
        #expect(out == [steps[0], steps[2], .object(["command": .string("node.set"), "params": .object(["ids": .array([.object(["$step": .number(1)])])])])])
        let toSkipped: [JSONValue] = [steps[1], .object(["command": .string("node.set"), "params": .object(["ids": .array([.object(["$step": .number(0)])])])])]
        #expect(throws: ProtocolError.self) { try DesignService.withoutSkipped(toSkipped, skip: [0]) }
    }

    // final review F1: odd `$step` values pass to the engine unchanged (no trap)
    @Test func oddStepRefsPassThrough() async throws {
        for n: JSONValue in [.number(1e300), .number(1.5), .number(-1), .number(.infinity), .string("x")] {
            let s: [JSONValue] = [.object(["command": .string("node.set"), "params": .object(["ids": .array([.object(["$step": n])])])])]
            #expect(try DesignService.withoutSkipped(s, skip: []) == s, "\(n)")
            #expect(try DesignService.withoutSkipped([.object(["command": .string("edit.delete")])] + s, skip: [0]) == s, "\(n)")
        }
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            _ = try await call(p, m, "design.batch", ["commands": #"[{"command":"node.set","params":{"ids":[{"$step":1e300}]}}]"#])
            #expect(try await call(p, m, "design.files").ok)   // the daemon is still up
        }
    }

    // F2: `{"$step": n, "field": f}` renumbered too, `field` kept; a reference to a skipped step refused
    @Test func stepRefWithFieldRenumbered() throws {
        func set(_ ref: JSONValue) -> JSONValue { .object(["command": .string("node.set"), "params": .object(["ids": .array([ref])])]) }
        let a = JSONValue.object(["command": .string("node.create")]), skip = JSONValue.object(["command": .string("edit.delete")])
        let out = try DesignService.withoutSkipped([a, skip, a, a, set(.object(["$step": .number(2), "field": .string("id")]))], skip: [1])
        #expect(out == [a, a, a, set(.object(["$step": .number(1), "field": .string("id")]))])
        #expect(throws: ProtocolError.self) { try DesignService.withoutSkipped([a, skip, set(.object(["$step": .number(1), "field": .string("id")]))], skip: [1]) }
    }

    // F5: the engine counts the steps it was sent; the caller's numbers are given back
    @Test func engineStepNumbersMappedBack() {
        let m = DesignService.callerSteps("step 2: `$step` 1 must be an earlier step (0 to 1); step 1's result has no `x`", sent: [0, 2, 4])
        #expect(m == "step 4: `$step` 2 must be an earlier step (0 to 2); step 2's result has no `x`", "\(m)")
        #expect(DesignService.callerSteps("step 9: x", sent: [0, 2]) == "step 9: x")   // out of range: as is
    }

    // F3 (R7/R10): every engine command that falls back to the selection needs its targets from agents
    @Test func agentCommandsNeedTargets() async throws {
        // the engine's `{ids?}`/`{id?}` commands (the appendix of the final review) are all in the table
        for c in ["fill.set", "object.ungroup", "layout.add", "transform.move", "bool.union", "component.detach", "page.delete",
                  "align.left", "text.style", "style.apply", "inspect.code", "edit.delete", "edit.duplicate", "object.group"] {
            #expect(DesignService.targetCommands.contains(c), "\(c)")
        }
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            func run(_ cmd: String, _ params: String) async throws -> Response { try await call(p, m, "design.run", ["command": cmd, "params": params]) }
            func needs(_ cmd: String, _ what: String = "ids") -> ProtocolError {
                ProtocolError(code: .invalidArgs, message: "\(cmd) needs \(what): agents never act on the user's selection")
            }
            for cmd in DesignService.targetCommands.sorted() {   // table-driven: none reaches the engine without a target
                #expect(try await run(cmd, "{}").error == needs(cmd), "\(cmd)")
            }
            #expect(try await run("fill.set", ##"{"ids":"5","color":"#f00"}"##).error == needs("fill.set"))   // not an array: the engine falls back
            #expect(try await run("fill.set", #"{"ids":null,"id":null}"#).error == needs("fill.set"))
            #expect(!fx.calls.contains { c in DesignService.targetCommands.contains { c.hasSuffix(" " + $0) } }, "\(fx.calls)")
            for (cmd, params) in [("fill.set", ##"{"ids":[1],"color":"#f00"}"##), ("page.delete", #"{"id":"0:1"}"#), ("edit.delete", #"{"id":3}"#),   // F4: id too
                                  ("edit.duplicate", #"{"id":3}"#), ("guide.remove", #"{"index":0}"#), ("text.onPath", #"{"text":1,"path":2}"#),
                                  ("style.create", #"{"type":"paint","name":"a","value":[]}"#), ("proto.flow.add", #"{"start":1}"#), ("select.set", #"{"ids":[1]}"#),
                                  ("select.all", "{}"), ("node.create", #"{"type":"frame"}"#)] {
                #expect(try await run(cmd, params).ok, "\(cmd) \(params)")
            }
            for (cmd, params, what) in [("guide.remove", "{}", "index"), ("proto.flow.add", "{}", "start"), ("proto.present", "{}", "start"),
                                        ("text.onPath", #"{"text":1}"#, "path"), ("text.onPath", #"{"path":1}"#, "text"),
                                        ("style.create", #"{"type":"paint","name":"a"}"#, "from or value")] {
                #expect(try await run(cmd, params).error == needs(cmd, what), "\(cmd) \(params)")
            }
            for cmd in ["transform.nudge", "transform.nudgeSize", "object.hideOthers", "text.listIndent", "text.listOutdent",
                        "transform.rotationOrigin", "transform.setRotationOrigin", "vector.deleteHeal", "vector.edit.begin", "vector.edit.nudge"] {
                let e = ProtocolError(code: .invalidArgs, message: "\(cmd) acts only on the user's selection: not available to agents")
                #expect(try await run(cmd, #"{"ids":[1],"dx":1,"dy":1}"#).error == e, "\(cmd)")
                #expect(try await call(p, m, "design.batch", ["commands": #"[{"command":"\#(cmd)"}]"#]).error == e, "\(cmd)")
            }
            // text.preview's inner command too
            #expect(try await run("text.preview", #"{"command":"text.style","params":{"fontSize":12}}"#).error == needs("text.style"))
        }
    }

    // re-review N1/N2: a target must be one the engine takes; `$step` objects only inside a batch
    @Test func targetsMustBeRealTargets() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            func needs(_ cmd: String, _ what: String = "ids") -> ProtocolError {
                ProtocolError(code: .invalidArgs, message: "\(cmd) needs \(what): agents never act on the user's selection")
            }
            for params in [#"{"ids":{}}"#, #"{"id":{}}"#, #"{"ids":{"x":1}}"#, #"{"ids":{"$step":0}}"#, #"{"id":{"$step":0}}"#,
                           #"{"id":true}"#, #"{"id":[1]}"#] {
                #expect(try await call(p, m, "design.run", ["command": "fill.set", "params": params]).error == needs("fill.set"), "\(params)")
            }
            for (cmd, params, what) in [("proto.flow.add", #"{"start":{}}"#, "start"), ("guide.remove", #"{"index":"x"}"#, "index"),
                                        ("text.onPath", #"{"text":{"$step":0},"path":2}"#, "text"), ("style.create", #"{"type":"paint","name":"a","from":{}}"#, "from or value")] {
                #expect(try await call(p, m, "design.run", ["command": cmd, "params": params]).error == needs(cmd, what), "\(cmd) \(params)")
            }
            let ref = try await call(p, m, "design.batch", ["commands": #"[{"command":"node.create"},{"command":"fill.set","params":{"id":{"$step":0}}},{"command":"text.onPath","params":{"text":{"$step":0},"path":{"$step":0,"field":"id"}}},{"command":"fill.set","params":{"ids":{"$step":0,"field":"ids"}}}]"#])
            #expect(ref.error?.code != .invalidArgs, "\(ref)")
            let bad = try await call(p, m, "design.batch", ["commands": #"[{"command":"node.create"},{"command":"fill.set","params":{"ids":{}}}]"#])
            #expect(bad.error == needs("fill.set"), "\(bad)")
        }
    }

    /// re-review (b): `targetCommands` is the engine's own list, derived here from the vendored spec params docs the way
    /// it was generated: every permitted command whose params doc takes `ids?`/`id?`, minus `proto.evaluate` (its `id?`
    /// is the document's modes), `vector.edit.*` and `selectionOnly` (refused outright). A figcraft upgrade that adds one
    /// fails this test until the table is regenerated.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: vendorEngineSrc.path)))
    func targetCommandsMatchTheEngine() throws {
        let str = #""((?:[^"\\]|\\.)*)""#
        let constRx = try NSRegularExpression(pattern: #"const\s+([A-Z_]+)\s*:\s*&str\s*=\s*"# + str)
        let specRx = try NSRegularExpression(pattern: #"spec!\(\s*"# + str + #"\s*,\s*"# + str + #"\s*,\s*(?:"# + str + #"|([A-Z_]+))"#)
        let targetRx = try NSRegularExpression(pattern: #"(?<![A-Za-z])ids?\?"#)
        var texts: [String] = []
        let files = (FileManager.default.enumerator(at: vendorEngineSrc, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        for u in files where u.pathExtension == "rs" { texts.append(try String(contentsOf: u, encoding: .utf8)) }
        func groups(_ rx: NSRegularExpression, _ t: String) -> [[String?]] {
            rx.matches(in: t, range: NSRange(t.startIndex..., in: t)).map { m in
                (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: t).map { String(t[$0]) } }
            }
        }
        var consts: [String: String] = [:]
        for t in texts { for g in groups(constRx, t) { consts[g[0]!] = g[1]! } }
        var specs: [String: String] = [:]
        for t in texts { for g in groups(specRx, t) { specs[g[0]!] = g[2] ?? g[3].flatMap { consts[$0] } ?? "" } }
        #expect(specs.count > 500, "\(specs.count)")   // the parser still finds the table
        let derived = Set(specs.filter { id, params in
            DesignService.permitted(id) && id != "proto.evaluate" && !id.hasPrefix("vector.edit.") && !DesignService.selectionOnly.contains(id)
                && targetRx.firstMatch(in: params, range: NSRange(params.startIndex..., in: params)) != nil
        }.keys)
        #expect(derived.subtracting(DesignService.targetCommands).sorted() == [], "missing from targetCommands")
        #expect(DesignService.targetCommands.subtracting(derived).sorted() == [], "no longer in the engine")
    }

    @Test func deleteWithoutIdsRefused() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            for cmd in ["edit.delete", "edit.duplicate", "object.group"] {
                let msg = "\(cmd) needs ids: agents never act on the user's selection"
                for params in ["{}", #"{"ids": null}"#] {
                    let r = try await call(p, m, "design.run", ["command": cmd, "params": params])
                    #expect(r.error == ProtocolError(code: .invalidArgs, message: msg), "\(cmd) \(params): \(r)")
                }
                let b = try await call(p, m, "design.batch", ["commands": #"[{"command":"node.create"},{"command":"\#(cmd)"}]"#])
                #expect(b.error == ProtocolError(code: .invalidArgs, message: msg), "\(cmd): \(b)")
                #expect(!fx.calls.contains { $0.contains(cmd) || $0.hasPrefix("tools/call batch") }, "\(fx.calls)")
            }
        }
    }

    @Test func nonArrayBatchStillRefused() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            let r = try await call(p, m, "design.batch", ["commands": "{}"])
            #expect(r.error == ProtocolError(code: .invalidArgs, message: "the batch must be a JSON array of {command, params}"), "\(r)")
        }
    }

    @Test func batchFileStaysInCwd() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            let work = p.root.appendingPathComponent("work/sub"), outside = p.root.appendingPathComponent("outside.json")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try Data(#"[{"command":"node.create"}]"#.utf8).write(to: outside)
            try Data(#"[{"command":"node.create"}]"#.utf8).write(to: work.appendingPathComponent("in.json"))
            try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("link.json"), withDestinationURL: outside)
            let cwd = p.root.appendingPathComponent("work").path
            for f in ["../outside.json", outside.path, "sub/../../outside.json", "sub/link.json"] {
                let r = try await call(p, m, "design.batch", ["file": f], cwd: cwd)
                #expect(r.error == ProtocolError(code: .invalidArgs, message: "--file must be inside the current directory"), "\(f): \(r)")
            }
            #expect(try await call(p, m, "design.batch", ["file": "sub/in.json"], cwd: cwd).ok)
            #expect(try await call(p, m, "design.batch", ["file": "\(cwd)/sub/./in.json"], cwd: cwd).ok)
        }
    }

    @Test func helpListsCommands() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await term(d, p, "M", shepherd: true)
            let all = try await call(p, m, "design.help")
            guard case .array(let rows)? = all.result else { Issue.record("\(all)"); return }
            // collab.* hidden; Collie's own design.system.* follow, one line each
            let own = rows.filter { if case .object(let o) = $0, case .string(let id)? = o["id"] { id.hasPrefix("design.system.") } else { false } }
            #expect(rows.count - own.count == 2 && own.count == 12, "\(rows)")
            #expect(rows.first == .object(["id": .string("node.create"), "help": .string("Create layer [Insert] {type, parent?}")]))
            let q = try await call(p, m, "design.help", ["query": "ALIGN"])
            #expect(q.result == .array([.object(["id": .string("align.left"),
                                                 "help": .string("Align left [Arrange] (Alt+A) {ids?}\n  second line of align docs")])]), "\(q)")
            _ = try await call(p, m, "design.help", ["query": "node"])
            #expect(fx.calls.filter { $0 == "tools/call list_commands " }.count == 1, "\(fx.calls)")   // fetched once
        }
    }

    @Test func screenshotAndExportWriteUnderRoot() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            guard case .object(let pl)? = try await call(p, m, "panel.list").result.flatMap({ if case .array(let a) = $0 { a.first } else { nil } }),
                  case .string(let pid)? = pl["id"], case .object(let st)? = pl["state"], case .string(let fid)? = st["file"] else {
                Issue.record("no panel"); return
            }
            let s = try await call(p, m, "design.screenshot", ["node": "4294967297"])
            guard case .string(let path)? = field(s, "path") else { Issue.record("\(s)"); return }
            #expect(path.hasPrefix(p.root.appendingPathComponent("screens/\(pid)-").path) && path.hasSuffix(".png"), "\(path)")
            #expect(field(s, "width") == .number(4) && field(s, "height") == .number(8))
            #expect(FileManager.default.fileExists(atPath: path))
            let exports = p.root.appendingPathComponent("design/exports/\(fid)").path
            let h = try await call(p, m, "design.export", ["format": "html", "node": "4294967297"])
            guard case .string(let page)? = field(h, "path") else { Issue.record("html: \(h)"); return }
            #expect(page.hasPrefix(p.root.appendingPathComponent("artifacts").path + "/") && page.hasSuffix("/v1/index.html"), "\(page)")
            #expect(((try? String(contentsOfFile: page, encoding: .utf8)) ?? "").hasPrefix("<!doctype html>"))
            for (fmt, ext) in [("css", "css"), ("react", "tsx"), ("figcraft", "figcraft")] {
                let e = try await call(p, m, "design.export", ["format": fmt, "node": "4294967297"])
                guard case .string(let out)? = field(e, "path") else { Issue.record("\(fmt): \(e)"); continue }
                #expect(out.hasPrefix(exports + "/") && out.hasSuffix(".\(ext)"), "\(out)")
                let body = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
                #expect(fmt == "figcraft" ? !body.isEmpty : body == "<div>Hello</div>", "\(fmt): \(body)")
            }
            #expect(try await call(p, m, "design.export", ["format": "pdf"]).error?.code == .invalidArgs)
            #expect(try await call(p, m, "panel.close", ["name": "design-1"]).ok)
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }

    @Test func idleClientCloses() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx, idle: .milliseconds(300)) { d, p in
            let m = try await shepherdWithPanel(d, p)
            #expect(try await call(p, m, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#]).ok)
            #expect(await waitFor(10) { await d.router.design.liveClients == 0 })
            #expect(try await call(p, m, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#]).ok)   // a new client
            #expect(fx.calls.filter { $0 == "initialize M" }.count == 2, "\(fx.calls)")
        }
    }

    @Test func maxEightClients() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await term(d, p, "M", shepherd: true)
            for i in 1...9 {
                #expect(try await call(p, m, "panel.open", ["plugin": "design", "file": "F\(i)", "placement": "dock.right"]).ok)
            }
            for i in 1...8 { #expect(try await call(p, m, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#, "panel": "design-\(i)"]).ok) }
            #expect(await d.router.design.liveClients == 8)
            // a ninth closes the one idle the longest
            #expect(try await call(p, m, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#, "panel": "design-9"]).ok)
            #expect(await d.router.design.liveClients == 8)
            // every client busy: refused
            async let busy: [Response] = withThrowingTaskGroup(of: Response.self) { g in
                for i in 2...9 { g.addTask { try await call(p, m, "design.run", ["command": "node.slow", "panel": "design-\(i)"]) } }
                return try await g.reduce(into: []) { $0.append($1) }
            }
            try await Task.sleep(for: .milliseconds(800))
            let r = try await call(p, m, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#, "panel": "design-1"])
            #expect(r.error == ProtocolError(code: .unavailable, message: "design engine busy"), "\(r)")
            #expect(try await busy.allSatisfy(\.ok))
        }
    }

    @Test func clientRecreatedAfterServerRestart() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            #expect(try await call(p, m, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#]).ok)
            await d.router.figcraft.stop()
            let r = try await call(p, m, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#])
            #expect(r.ok, "\(r)")
            #expect(fx.calls.filter { $0 == "initialize M" }.count == 2, "\(fx.calls)")
            #expect(await d.router.design.liveClients == 1)
            // a client that died is recreated within the same call
            #expect(try await call(p, m, "design.run", ["command": "node.die"]).error?.code == .unavailable)
            #expect(try await call(p, m, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#]).ok)
            #expect(fx.calls.filter { $0 == "initialize M" }.count == 3, "\(fx.calls)")
        }
    }

    @Test func storedLinkFollowsServerPort() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)   // stored link: the fake's host=127.0.0.1:47900
            #expect(try await call(p, m, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#]).ok)
            let before = try await serverPort(d)
            await d.router.figcraft.stop()
            let held = occupy(before)   // the server comes back on another port
            defer { close(held) }
            #expect(try await call(p, m, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#]).ok)
            let now = try await serverPort(d)
            #expect(now != before && fx.calls.last { $0.hasPrefix("join ") } == "join 127.0.0.1:\(now)", "\(now) \(fx.calls)")
            let link = try await admin(d, p, "design.link", ["panel": "design-1"])
            guard case .string(let l)? = field(link, "editLink") else { Issue.record("\(link)"); return }
            #expect(l == "figcraft://join?host=127.0.0.1:\(now)&file=f1&token=fakeToken", "\(l)")
        }
    }

    @Test func timedOutEditDropsItsClient() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx, timeoutCap: .milliseconds(1500)) { d, p in
            let m = try await shepherdWithPanel(d, p)
            #expect(try await call(p, m, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#]).ok)
            let r = try await call(p, m, "design.run", ["command": "node.slow"])   // answers after 2 s
            #expect(r.error?.code == .timeout && r.error?.message.contains("may still have been applied") == true, "\(r)")
            #expect(await d.router.design.liveClients == 0)   // not reused: it may still be applying the edit
            #expect(try await call(p, m, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#]).ok)
            #expect(fx.calls.filter { $0 == "initialize M" }.count == 2, "\(fx.calls)")
        }
    }

    @Test func concurrentOpensOfANewNameShareTheFile() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await term(d, p, "M", shepherd: true)
            async let a = call(p, m, "panel.open", ["plugin": "design", "file": "New", "placement": "dock.right"])
            async let b = call(p, m, "panel.open", ["plugin": "design", "file": "New", "placement": "dock.left"])
            let (ra, rb) = try await (a, b)
            func fid(_ r: Response) -> JSONValue? { if case .object(let st)? = field(r, "state") { st["file"] } else { nil } }
            #expect(ra.ok && rb.ok && fid(ra) != nil && fid(ra) == fid(rb), "\(ra) / \(rb)")
            #expect(fx.calls.filter { $0 == "initialize collie-bridge" }.count == 1, "\(fx.calls)")
        }
    }

    @Test func panelCloseClosesClients() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p)
            let w = try await term(d, p, "W")
            #expect(try await admin(d, p, "admin.leash", ["a": "W", "b": "design-1"]).ok)
            #expect(try await call(p, m, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#]).ok)
            #expect(try await call(p, w, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#]).ok)
            #expect(await d.router.design.liveClients == 2)
            #expect(try await admin(d, p, "admin.kill", ["target": "W"]).ok)   // a removed terminal's clients go
            #expect(await d.router.design.liveClients == 1)
            #expect(try await call(p, m, "panel.close", ["name": "design-1"]).ok)
            #expect(await d.router.design.liveClients == 0)
        }
    }

    // MARK: real engine (vendor build)

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(3)))
    func realEngineRoundTrip() async throws {
        try await withDesign(nil) { d, p in
            let m = try await shepherdWithPanel(d, p, file: "Real")
            let b = try await call(p, m, "design.batch", ["label": "Hero", "commands": #"""
                [{"command":"node.create","params":{"type":"frame","name":"Hero","width":320,"height":200}},
                 {"command":"node.create","params":{"type":"text","text":"Hello Collie","parent":{"$step":0}}},
                 {"command":"node.set","params":{"ids":[{"$step":0}],"fill":"#3366FF"}}]
                """#])
            guard case .array(let steps)? = b.result, case .object(let first)? = steps.first, case .number(let root)? = first["id"] else {
                Issue.record("\(b)"); return
            }
            let node = try await call(p, m, "design.inspect", ["node": String(format: "%.0f", root), "depth": "2"])
            #expect(text(node).contains("Hello Collie") && text(node).contains("Hero"), "\(node)")
            let e = try await call(p, m, "design.export", ["format": "html", "node": String(format: "%.0f", root)])
            guard case .string(let out)? = field(e, "path") else { Issue.record("\(e)"); return }
            #expect(((try? String(contentsOfFile: out, encoding: .utf8)) ?? "").contains("Hello Collie"))
            let page = try await call(p, m, "design.export", ["format": "react"])   // no node: the page's top layers
            guard case .string(let tsx)? = field(page, "path") else { Issue.record("\(page)"); return }
            #expect(((try? String(contentsOfFile: tsx, encoding: .utf8)) ?? "").contains("Hello Collie"))
            let f = try await call(p, m, "design.export", ["format": "figcraft"])
            guard case .string(let fig)? = field(f, "path") else { Issue.record("\(f)"); return }
            // the saved file is the live document (a zip of JSON)
            let unzip = Process(), pipe = Pipe()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); unzip.arguments = ["-p", fig]; unzip.standardOutput = pipe
            try unzip.run()
            let content = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            unzip.waitUntilExit()
            #expect(content.contains("Hello Collie"), "\(content.prefix(300))")
            let s = try await call(p, m, "design.screenshot")
            #expect(s.ok && (field(s, "width").flatMap { if case .number(let n) = $0 { n } else { nil } } ?? 0) > 0, "\(s)")
            let help = try await call(p, m, "design.help", ["query": "node.create"])
            #expect(text(help).contains("\"node.create\""), "\(help)")
            let bad = try await call(p, m, "design.batch", ["commands": #"[{"command":"node.create","params":{"type":"frame"}},{"command":"node.set","params":{"ids":[{"$step":0}],"bogus":1}}]"#])
            #expect(bad.error?.message.contains("step 2") == true, "\(bad)")
            for r in [b, node, e, f, s, help, bad] { #expect(!text(r).contains("figcraft://") && !text(r).contains("token=")) }
            let link = try await admin(d, p, "design.link", ["panel": "design-1"])
            #expect(text(link).contains("figcraft://"))
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(3)))
    func realEngineHTMLArtifact() async throws {
        // doc.json without image.place (agents may not pass a path) + the node.set that renames it, and without the
        // unsafe-scheme text.link (refused for agents): later $steps shift down
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("html-export/doc.json"))) as! [[String: Any]]
        let dropped = Set(raw.indices.flatMap { i -> [Int] in
            switch raw[i]["command"] as? String { case "image.place": [i, i + 1]; case "text.link" where (raw[i]["params"] as? [String: Any])?["url"] as? String == "javascript:alert(1)": [i]; default: [] }
        })
        func remap(_ v: Any) -> Any {
            if let o = v as? [String: Any] {
                if let s = o["$step"] as? Int { return ["$step": s - dropped.filter { $0 < s }.count] }
                return o.mapValues(remap)
            }
            if let a = v as? [Any] { return a.map(remap) }
            return v
        }
        let steps = raw.indices.filter { !dropped.contains($0) }.map { remap(raw[$0]) }
        let commands = String(decoding: try JSONSerialization.data(withJSONObject: steps), as: UTF8.self)
        try await withDesign(nil) { d, p in
            let m = try await shepherdWithPanel(d, p, file: "Landing")
            let b = try await call(p, m, "design.batch", ["commands": commands])
            guard case .array(let res)? = b.result,
                  case .object(let rootStep) = res[4], case .number(let root) = rootStep["id"],
                  case .object(let titleStep) = res[8], case .number(let title) = titleStep["id"] else { Issue.record("\(b)"); return }
            let e = try await call(p, m, "design.export", ["format": "html", "node": String(format: "%.0f", root)])
            guard case .string(let path)? = field(e, "path"), case .string(let id)? = field(e, "artifact") else { Issue.record("\(e)"); return }
            let html = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            for s in ["<h1", #"<ul class="items">"#, #"[data-theme="dark"]"#, "display: grid", "<svg", #"<a href="https://example.com""#] {
                #expect(html.contains(s), "missing \(s)")
            }
            func status() async throws -> (String, JSONValue?) {
                let r = try await call(p, m, "artifact.list")
                guard case .array(let a)? = r.result, case .object(let o)? = a.first(where: { if case .object(let o) = $0 { o["id"] == .string(id) } else { false } }),
                      case .string(let s)? = o["status"] else { throw ProtocolError(code: .internal, message: "\(r)") }
                return (s, o["version"])
            }
            #expect(try await status().0 == "current")
            #expect(try await call(p, m, "design.run", ["command": "node.set", "params": #"{"ids":[\#(String(format: "%.0f", title))],"characters":"Changed"}"#]).ok)
            var seen: [String] = []   // the daemon's own client sees the edit a moment later (collab sync): poll
            for _ in 0..<20 { seen.append(try await status().0); if seen.last == "stale" { break }; try await Task.sleep(for: .milliseconds(500)) }
            #expect(seen.last == "stale", "\(seen)")
            guard seen.last == "stale" else { return }
            let re = try await admin(d, p, "artifact.reexport", ["id": id])
            #expect(field(re, "version") == .number(2), "\(re)")
            let (s, v) = try await status()
            #expect(s == "current" && v == .number(2))
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(3)))
    func realEngineJoinsAfterPortMoves() async throws {
        try await withDesign(nil) { d, p in
            let m = try await shepherdWithPanel(d, p, file: "Moved")
            #expect(try await call(p, m, "design.run", ["command": "node.create", "params": #"{"type":"frame","name":"Kept"}"#]).ok)
            let before = try await serverPort(d)
            await d.router.figcraft.stop()
            let held = occupy(before)
            defer { close(held) }
            let r = try await call(p, m, "design.inspect", ["depth": "2"])   // a new client joins the stored link
            #expect(r.ok, "\(r)")
            let now = try await serverPort(d)
            let link = try await admin(d, p, "design.link", ["panel": "design-1"])
            #expect(now != before && text(link).contains("host=127.0.0.1:\(now)&"), "\(now) \(link)")
        }
    }

    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(3)))
    func twoCallersHaveSeparateUndo() async throws {
        try await withDesign(nil) { d, p in
            let m = try await shepherdWithPanel(d, p, file: "Undo")
            let w = try await term(d, p, "W")
            #expect(try await admin(d, p, "admin.leash", ["a": "W", "b": "design-1"]).ok)
            func create(_ t: Term, _ name: String) async throws -> String {
                let r = try await call(p, t, "design.batch", ["commands": #"[{"command":"node.create","params":{"type":"frame","name":"\#(name)"}}]"#])
                guard case .array(let a)? = r.result, case .object(let o)? = a.first, case .number(let id)? = o["id"] else {
                    throw ProtocolError(code: .internal, message: "\(r)")
                }
                return String(format: "%.0f", id)
            }
            let mine = try await create(m, "FromM"), theirs = try await create(w, "FromW")
            // each sees the other's node (one live document)
            #expect(await waitFor(10) { (try? await call(p, m, "design.inspect", ["node": theirs]))?.ok == true })
            #expect(try await call(p, w, "design.run", ["command": "edit.undo"]).ok)
            // W's undo took back only W's step
            #expect(await waitFor(10) {
                let doc = (try? await call(p, m, "design.inspect", ["depth": "3"])).map(text) ?? ""
                return doc.contains("FromM") && !doc.contains("FromW")
            })
            #expect(try await call(p, m, "design.inspect", ["node": mine]).ok)
        }
    }
}

extension DesignCommandTests {
    @Test func snapshotCollectsEverything() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        let c = try await MCPStdioClient(executable: fx.dir.appendingPathComponent("bin/figcraft-cli"), args: ["mcp"],
                                         env: ProcessInfo.processInfo.environment, runDir: fx.dir, name: "snap-test")
        defer { c.close() }
        let s = try await DesignService.snapshot(c, node: "2", deadline: .now + .seconds(20))
        #expect(s.code.count == 1 && s.code[0].contains("class=\"landing\""))
        #expect(s.layers.count == 1)
        #expect(s.assets.map(\.id).sorted() == ["18", "19"])
        #expect(Set(s.assets.map(\.kind)) == ["icon", "image"])
        #expect(s.thumbnail?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(s.stamp.count == 64 && s.stamp.allSatisfy(\.isHexDigit))
    }

    @Test func instanceSnapshotsThroughDockedPanel() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await shepherdWithPanel(d, p, placement: "dock.right")
            let panel = try #require(await d.router.panel(named: "design-1"))
            let (file, snap) = try await d.router.design.htmlSnapshot(panel: panel, caller: (key: m.id, name: "M"), node: "2",
                                                                        deadline: .now + .seconds(20))
            #expect(snap.code.count == 1 && snap.layers.count == 1 && snap.assets.count == 2 && snap.thumbnail != nil)
            #expect(snap.stamp.count == 64)
            let dump = String(describing: snap.code) + String(describing: snap.layers) + String(describing: snap.variables)
                + snap.assets.map(\.name).joined() + snap.assets.filter { $0.kind == "icon" }.map { String(decoding: $0.data, as: UTF8.self) }.joined()
            #expect(!dump.contains("figcraft://") && !dump.contains("fakeToken"), "\(dump.prefix(300))")
            #expect(dump.contains("[link]") || dump.contains("[hidden]"))
            #expect(snap.assets.contains { $0.name.hasPrefix("Icon Star") && !$0.name.contains("figcraft://") })
            let deadline = ContinuousClock.now + .seconds(20)
            let sys = try await d.router.design.systemSnapshot(fileId: file.id, node: "2", deadline: deadline)
            #expect(sys.stamp == snap.stamp)
            #expect(try await d.router.design.currentStamp(fileId: file.id, node: "2", deadline: deadline) == snap.stamp)
            let vars = try await d.router.design.variables(ofFile: file.id, deadline: deadline)
            #expect(String(describing: vars).contains("collections") && !String(describing: vars).contains("figcraft://"))
        }
    }

    @Test func artifactListNeverCostsATerminalItsClient() async throws {
        let fx = try Fx(); defer { fx.cleanup() }
        try await withDesign(fx) { d, p in
            let m = try await term(d, p, "M", shepherd: true)
            for i in 1...8 {
                #expect(try await call(p, m, "panel.open", ["plugin": "design", "file": "F\(i)", "placement": "dock.right"]).ok)
            }
            #expect(try await call(p, m, "design.export", ["format": "html", "node": "2", "panel": "design-1"]).ok)
            func status() async throws -> JSONValue? {
                guard case .array(let rows)? = try await call(p, m, "artifact.list").result, case .object(let o)? = rows.first else { return nil }
                return o["status"]
            }
            #expect(try await status() == .string("current"))   // the daemon's own client of F1, now idle
            for i in 2...7 { #expect(try await call(p, m, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#, "panel": "design-\(i)"]).ok) }
            #expect(await d.router.design.liveClients == 8)
            // the eighth terminal client closes the daemon's, not M's of F1 (idle the longest)
            #expect(try await call(p, m, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#, "panel": "design-8"]).ok)
            func joins() -> Int { fx.calls.filter { $0.hasPrefix("initialize") }.count }
            let n = joins()
            for i in 1...8 { #expect(try await call(p, m, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#, "panel": "design-\(i)"]).ok) }
            #expect(joins() == n, "\(fx.calls.suffix(30))")
            // all eight are M's: the status check makes no room, so it can't tell
            #expect(try await status() == .string("unknown"))
            for i in 1...8 { #expect(try await call(p, m, "design.run", ["command": "align.left", "params": #"{"ids":[1]}"#, "panel": "design-\(i)"]).ok) }
            #expect(joins() == n)
            #expect(await d.router.design.liveClients == 8)
        }
    }

    @Test func pageExportsReadTheirOwnPage() {
        func page(_ id: Double, _ kids: [Double]) -> JSONValue {
            .object(["id": .number(id), "children": .array(kids.map { .object(["id": .number($0)]) })])
        }
        // figcraft's current page is per client: the daemon's may be another than the exporter's
        let doc = JSONValue.object(["currentPage": .number(5), "pages": .array([page(1, [10, 11]), page(5, [50])])])
        #expect(DesignService.topLayers(doc, page: nil).map { [$0.page] + $0.ids.map { "\($0)" } } == ["5", "\(JSONValue.number(50))"])
        #expect(DesignService.topLayers(doc, page: "1")?.ids == [.number(10), .number(11)])
        #expect(DesignService.topLayers(doc, page: "1")?.page == "1")
        #expect(DesignService.topLayers(doc, page: "9") == nil)   // deleted: the artifact is missing
        let noCurrent = JSONValue.object(["pages": .array([page(1, [10])])])
        #expect(DesignService.topLayers(noCurrent, page: nil)?.page == "1")
    }

    @Test func stampIgnoresPositionOnly() throws {
        let data = try Data(contentsOf: fixtures.appendingPathComponent("html-export/node.json"))
        let base = try JSONDecoder().decode(JSONValue.self, from: data)
        func mutate(_ v: JSONValue, root: Bool, _ f: (inout [String: JSONValue], Bool) -> Void) -> JSONValue {
            switch v {
            case .array(let a): return .array(a.map { mutate($0, root: false, f) })
            case .object(var o): f(&o, root); return .object(o.mapValues { mutate($0, root: false, f) })
            default: return v
            }
        }
        let vars = JSONValue.object([:])
        let moved = mutate(base, root: true) { o, root in
            if o["absoluteBounds"] != nil { o["absoluteBounds"] = .object(["x": .number(99), "y": .number(7)]) }
            if root { o["x"] = .number(500); o["y"] = .number(500) }
        }
        let edited = mutate(base, root: true) { o, _ in if o["characters"] != nil { o["characters"] = .string("changed") } }
        let stamp = DesignService.stamp(layers: [base], variables: vars)
        #expect(DesignService.stamp(layers: [moved], variables: vars) == stamp)
        #expect(DesignService.stamp(layers: [edited], variables: vars) != stamp)
    }
}

// MARK: real WebKit (vendor build)

extension DesignCommandTests {
    /// The Design panel joins its session without the confirmation dialog (`#collie=1&join=`, patch 0004): a second
    /// client of the file sees one more peer, with no click.
    @Test(.enabled(if: realBuilt), .timeLimit(.minutes(3)))
    func designPanelJoinsWithoutClick() async throws {
        try await withDesign(nil) { d, p in
            _ = try await shepherdWithPanel(d, p, file: "Auto")
            guard case .string(let link)? = field(try await admin(d, p, "design.link", ["panel": "design-1"]), "editLink") else {
                Issue.record("no link"); return
            }
            let c = try await MCPStdioClient(executable: vendorFigcraft.appendingPathComponent("bin/figcraft-cli"), args: ["mcp"],
                                             env: ProcessInfo.processInfo.environment, runDir: p.runDir, name: "watcher")
            defer { c.close() }
            _ = try await c.command("collab.join", ["link": .string(link)], timeout: .seconds(30))
            func peers() async -> Int? {
                guard case .object(let o)? = try? await c.command("collab.peers", [:], timeout: .seconds(10)),
                      o["status"] == .string("live"), case .array(let a)? = o["peers"] else { return nil }
                return a.count
            }
            var before: Int?
            #expect(await waitFor(15) { before = await peers(); return before != nil })
            let token = d.adminToken, socket = p.socket
            let panel = Panel(id: UUID(), name: "design-1", pluginId: "design", placement: .canvas, state: ["file": .string("Auto")])
            let host = PanelHostContext(panel: panel, root: p.root, workspaceId: nil, call: { cmd, args throws(ProtocolError) in
                let r: Response
                do { r = try await UnixSocketClient.send(Request(id: "x", token: token, command: cmd, args: args), to: socket, timeoutSeconds: 60) }
                catch { throw ProtocolError(code: .internal, message: "\(error)") }
                if let e = r.error { throw e }
                return r.result ?? .null
            }, emit: { _, _ in })
            let shown = await ShownPanel(panel, host)   // in a window: the panel fetches its link and loads the page
            let base = before ?? 0, deadline = ContinuousClock.now + .seconds(15)
            var joined = false
            while !joined, ContinuousClock.now < deadline {
                joined = (await peers() ?? 0) > base
                if !joined { try await Task.sleep(for: .milliseconds(200)) }
            }
            await shown.close()
            #expect(joined, "the panel did not join within 15 s")
        }
    }
}

/// A real Design panel in a window far off-screen (on-screen sized, so the page gets animation frames).
@MainActor private final class ShownPanel {
    let view: DesignPanel
    let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 800, height: 600), styleMask: .borderless,
                          backing: .buffered, defer: false)
    init(_ panel: Panel, _ host: PanelHostContext) {
        view = DesignPanel(panel: panel, host: host)
        window.isReleasedWhenClosed = false
        window.contentView = view.view
        window.orderFrontRegardless()
    }
    func close() { view.close(); window.close() }
}
