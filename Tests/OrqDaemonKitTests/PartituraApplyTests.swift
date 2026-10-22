import Testing
import Foundation
import OrqCore
import OrqProtocol
@testable import OrqDaemonKit

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures")

/// A fake `claude` on the agents' PATH (never the real one): `prelude` runs first (by `$ORQ_TERMINAL_NAME`), then the
/// fake agent. The launch shell skips the login profile, so path_helper can't put a real claude ahead of it.
private struct FakeAgents {
    let dir = URL(fileURLWithPath: "/tmp/orq-pt-\(UUID().uuidString.prefix(8))")
    init(_ prelude: String = "") throws {
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        func script(_ url: URL, _ body: String) throws {
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try script(bin.appendingPathComponent("claude"), prelude + "\nexec '\(fixtures.appendingPathComponent("fake-agent.sh").path)'")
        try script(dir.appendingPathComponent("sh"), #"if [ "$1" = "-lc" ]; then exec /bin/sh -c "$2"; fi; exec /bin/sh "$@""#)
    }
    func configure(_ c: inout DaemonConfig) {
        c.shell = dir.appendingPathComponent("sh").path
        Self.path(&c, dir.appendingPathComponent("bin").path + ":/usr/bin:/bin")
    }
    static func path(_ c: inout DaemonConfig, _ path: String) {
        c.captureUserEnv = true
        c.envRunner = { _, _, _, _ in Data((UserEnvironment.marker + "\0PATH=\(path)\0").utf8) }
    }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

private struct Term { var id: String; var token: String }
private struct State: Equatable { var terminals: [TerminalRecord]; var connections: [Connection]; var floors: [Floor]; var panels: [Panel] }

private func snapshot(_ d: Daemon, _ p: Paths) async throws -> WorkspaceSnapshot {
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "ui.snapshot"))
    return try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(r.result))
}
private func state(_ d: Daemon, _ p: Paths) async throws -> State {
    let s = try await snapshot(d, p)
    return State(terminals: s.terminals, connections: s.connections, floors: s.floors, panels: s.panels)
}
private func apply(_ d: Daemon, _ p: Paths, _ args: [String: JSONValue]) async throws -> Response {
    try await send(p, Request(id: "a", token: d.adminToken, command: "partitura.apply", args: args), timeoutSeconds: 120)
}
private func term(_ d: Daemon, _ p: Paths, _ name: String, maestro: Bool = false) async throws -> Term {
    let r = try await send(p, Request(id: "x", token: d.adminToken, command: "admin.spawn",
        args: ["name": .string(name), "preset": .string("shell"), "cwd": .string("/tmp"), "maestro": .bool(maestro)]), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: JSONValue]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args), to: p.socket, timeoutSeconds: 120)
}
private func pairs(_ s: State) -> Set<Set<String>> {
    let names = Dictionary(uniqueKeysWithValues: s.terminals.map { ($0.id, $0.name) } + s.panels.map { ($0.id, $0.name) })
    return Set(s.connections.map { Set([names[$0.a] ?? "?", names[$0.b] ?? "?"]) })
}
private let bug = Partitura.factory.first { $0.id == "investigar-bug" }!
private let fullstack = Partitura.factory.first { $0.id == "feature-fullstack" }!

@Suite(.serialized) struct PartituraApplyTests {
    @Test func appliesFactoryBugScore() async throws {
        let fx = try FakeAgents(); defer { fx.cleanup() }
        try await withDaemon(configure: fx.configure) { d, p in
            let r = try await apply(d, p, ["id": .string("investigar-bug"), "name": .string("x"), "cwd": .string("/tmp")])
            #expect(r.ok, "\(r)")
            let s = try await state(d, p)
            #expect(s.terminals.map(\.name).sorted() == ["x-investigador", "x-maestro", "x-testes"])
            #expect(s.terminals.filter(\.isMaestro).map(\.name) == ["x-maestro"])
            #expect(pairs(s) == [["x-maestro", "x-investigador"], ["x-maestro", "x-testes"]])
            #expect(s.floors.isEmpty && s.panels.isEmpty)
            for t in bug.terminals {
                let rec = try #require(s.terminals.first { $0.name == "x-\(t.key)" })
                let role = String(try #require(t.role).prefix(30))
                #expect(await waitFor(20) { await d.scrollbackText(rec.id).contains("answer:" + role) }, "role of \(rec.name)")
            }
        }
    }

    @Test func preflightCreatesNothing() async throws {
        let fx = try FakeAgents(); defer { fx.cleanup() }
        let repo = try await makeRepo()
        try await withDaemon(configure: fx.configure) { d, p in
            _ = try await term(d, p, "x-testes")
            #expect(try await send(p, Request(id: "f", token: d.adminToken, command: "floor.create",
                                              args: ["name": .string("y"), "repo": .string(repo.path)]), timeoutSeconds: 60).ok)
            #expect(try await GitRunner.run(["branch", "orq/w"], in: repo).status == 0)   // a stale floor branch
            let before = try await state(d, p)
            let cases: [([String: JSONValue], String)] = [
                (["name": .string("x"), "cwd": .string("/tmp")], "o nome x-testes já está em uso"),
                (["name": .string("y"), "cwd": .string(repo.path), "floor": .bool(true)], "o andar y já existe"),
                (["name": .string("z"), "cwd": .string("/tmp"), "floor": .bool(true)], "não está num repositório git"),
                (["name": .string("z"), "cwd": .string("/nonexistent-orq")], "não existe"),
                (["name": .string("w"), "cwd": .string(repo.path), "floor": .bool(true)], "a branch orq/w já existe"),
                (["name": .string("z"), "cwd": .string("/tmp"), "floor": .string("sim")], "floor deve ser true ou false"),
            ]
            for (args, msg) in cases {
                let r = try await apply(d, p, args.merging(["id": .string("investigar-bug")]) { a, _ in a })
                #expect(r.error?.code == .invalidArgs && r.error?.message.contains(msg) == true, "\(r)")
                #expect(try await state(d, p) == before)
            }
        }
        // no claude on the agents' PATH
        try await withDaemon(configure: { FakeAgents.path(&$0, "/usr/bin:/bin") }) { d, p in
            let r = try await apply(d, p, ["id": .string("investigar-bug"), "name": .string("x"), "cwd": .string("/tmp")])
            #expect(r.error == ProtocolError(code: .invalidArgs, message: "claude não encontrado"), "\(r)")
            #expect(try await state(d, p).terminals.isEmpty)
        }
    }

    @Test func rollbackOnAgentTimeout() async throws {
        let fx = try FakeAgents(#"case "$ORQ_TERMINAL_NAME" in *-testes) exec sleep 600;; esac"#); defer { fx.cleanup() }
        try await withDaemon(configure: { fx.configure(&$0); $0.partituraReady = .seconds(6) }) { d, p in
            let keep = try await term(d, p, "keep")
            let before = try await state(d, p)
            let r = try await apply(d, p, ["id": .string("investigar-bug"), "name": .string("x"), "cwd": .string("/tmp")])
            #expect(r.error == ProtocolError(code: .timeout, message: "terminal x-testes não ficou pronto em 6 s"), "\(r)")
            #expect(try await state(d, p) == before)
            #expect(await d.process(UUID(uuidString: keep.id)!)?.isRunning == true)
        }
    }

    @Test func rollbackOnPanelFailure() async throws {
        // no figcraft bundled: the design panel can't open, after the floor, terminals and cords were made
        let fx = try FakeAgents(); defer { fx.cleanup() }
        let repo = try await makeRepo()
        try await withDaemon(configure: fx.configure) { d, p in
            let r = try await apply(d, p, ["id": .string("feature-fullstack"), "name": .string("x"), "cwd": .string(repo.path)])
            #expect(r.error?.message.hasPrefix("painel x-design:") == true, "\(r)")
            let s = try await state(d, p)
            #expect(s.terminals.isEmpty && s.connections.isEmpty && s.panels.isEmpty && s.floors.isEmpty, "\(s)")
            #expect(try await GitRunner.run(["show-ref", "--verify", "--quiet", "refs/heads/orq/x"], in: repo).status != 0)
            #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent(".orq/floors/x").path))
        }
    }

    @Test func rollbackKeepsFloorWithCommits() async throws {
        let fx = try FakeAgents(#"case "$ORQ_TERMINAL_NAME" in *-testes) git commit -q --allow-empty -m wip >/dev/null 2>&1; exec sleep 600;; esac"#)
        defer { fx.cleanup() }
        let repo = try await makeRepo()
        try await withDaemon(configure: { fx.configure(&$0); $0.partituraReady = .seconds(6) }) { d, p in
            let r = try await apply(d, p, ["id": .string("investigar-bug"), "name": .string("x"), "cwd": .string(repo.path), "floor": .bool(true)])
            #expect(r.error?.code == .timeout && r.error?.message.contains("andar x mantido: tem commits") == true, "\(r)")
            let s = try await state(d, p)
            #expect(s.floors.map(\.name) == ["x"] && s.terminals.isEmpty && s.connections.isEmpty, "\(s)")
        }
    }

    @Test func rollbackKeepsFloorWithUncommittedWork() async throws {
        let fx = try FakeAgents(#"case "$ORQ_TERMINAL_NAME" in *-testes) echo wip > scratch.txt; exec sleep 600;; esac"#)
        defer { fx.cleanup() }
        let repo = try await makeRepo()
        try await withDaemon(configure: { fx.configure(&$0); $0.partituraReady = .seconds(6) }) { d, p in
            let r = try await apply(d, p, ["id": .string("investigar-bug"), "name": .string("x"), "cwd": .string(repo.path), "floor": .bool(true)])
            #expect(r.error?.code == .timeout && r.error?.message.contains("andar x mantido: tem alterações") == true, "\(r)")
            let s = try await state(d, p)
            #expect(s.floors.map(\.name) == ["x"] && s.terminals.isEmpty, "\(s)")
            #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".orq/floors/x/scratch.txt").path))
        }
    }

    @Test func rollbackKeepsFloorWithIgnoredFiles() async throws {
        // an ignored file (build output, .env) is work too: the floor stays
        let fx = try FakeAgents(#"case "$ORQ_TERMINAL_NAME" in *-testes) printf 'out/\n' >> "$(git rev-parse --git-common-dir)/info/exclude"; mkdir -p out; echo x > out/b; exec sleep 600;; esac"#)
        defer { fx.cleanup() }
        let repo = try await makeRepo()
        try await withDaemon(configure: { fx.configure(&$0); $0.partituraReady = .seconds(6) }) { d, p in
            let r = try await apply(d, p, ["id": .string("investigar-bug"), "name": .string("x"), "cwd": .string(repo.path), "floor": .bool(true)])
            #expect(r.error?.code == .timeout && r.error?.message.contains("andar x mantido: tem alterações") == true, "\(r)")
            #expect(try await state(d, p).floors.map(\.name) == ["x"])
            #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".orq/floors/x/out/b").path))
        }
    }

    @Test func rollbackOnApprovalPrompt() async throws {
        // stdin goes to a file: anything typed into it is recorded
        let fx = try FakeAgents(#"case "$ORQ_TERMINAL_NAME" in *-testes) printf 'Do you trust the files in this folder? (y/n) '; exec cat > "$(dirname "$0")/testes.in";; esac"#)
        defer { fx.cleanup() }
        let input = fx.dir.appendingPathComponent("bin/testes.in")
        try await withDaemon(configure: fx.configure) { d, p in
            let before = try await state(d, p)
            let r = try await apply(d, p, ["id": .string("investigar-bug"), "name": .string("x"), "cwd": .string("/tmp")])
            #expect(r.error?.message.hasPrefix("terminal x-testes está pedindo aprovação; papel não entregue") == true, "\(r)")
            #expect(try await state(d, p) == before)
            let typed = (try? String(contentsOf: input, encoding: .utf8)) ?? ""
            #expect(!typed.contains("teste"), "\(typed)")
        }
    }

    /// R10 at the role's write: a `custom` terminal at a y/n prompt (shown at once, or drawn right after the user's key,
    /// inside the input window) never gets its role typed; the apply fails in Portuguese and rolls back.
    @Test func partituraRoleRefusedAtApprovalPrompt() async throws {
        let fx = try FakeAgents(); defer { fx.cleanup() }
        let input = fx.dir.appendingPathComponent("typed.in")
        let role = "papel secreto do terminal"
        func partitura(_ id: String, _ script: String) -> JSONValue {
            let pt = Partitura(id: id, name: id, terminals: [PartituraTerminal(key: "a", preset: .custom, command: script, role: role)])
            return .string(String(decoding: try! PartituraFormat.encode(pt), as: UTF8.self))
        }
        try await withDaemon(configure: fx.configure) { d, p in
            func admin(_ cmd: String, _ a: [String: JSONValue]) async throws -> Response {
                try await send(p, Request(id: "i", token: d.adminToken, command: cmd, args: a), timeoutSeconds: 30)
            }
            let refused = "terminal t-a está pedindo aprovação; papel não entregue"
            let before = try await state(d, p)

            // the prompt is on screen before the role
            #expect(try await admin("partitura.import", ["json": partitura("ja", "printf 'Proceed? (y/n) '; exec cat > '\(input.path)'")]).ok)
            let r = try await apply(d, p, ["id": .string("ja"), "name": .string("t"), "cwd": .string("/tmp")])
            #expect(r.error == ProtocolError(code: .unavailable, message: refused), "\(r)")
            #expect(try await state(d, p) == before)
            #expect(!((try? String(contentsOf: input, encoding: .utf8)) ?? "").contains(role))

            // silent until the user's key, then the prompt: drawn inside the key's window, not scanned when the role comes
            try? FileManager.default.removeItem(at: input)
            #expect(try await admin("partitura.import", ["json": partitura("depois", "read k; printf 'Proceed? (y/n) '; exec cat > '\(input.path)'")]).ok)
            let asks = await d.router.asks, deferred = await asks.windowDeferrals
            async let late = apply(d, p, ["id": .string("depois"), "name": .string("t"), "cwd": .string("/tmp")])
            var id: UUID?
            #expect(await waitFor(30) {
                id = try? await state(d, p).terminals.first { $0.name == "t-a" }?.id
                guard let id else { return false }
                return await asks.approvalTracker(id) != nil
            })
            let c = try await StreamClient.open(Request(id: "k", token: d.adminToken, command: "ui.attach",
                                                        args: ["terminal": .string(try #require(id).uuidString)]), path: p.socket)
            try await c.send(.in(Data("x\n".utf8)))
            let r2 = try await late
            c.close()
            #expect(r2.error == ProtocolError(code: .unavailable, message: refused), "\(r2)")
            #expect(await asks.windowDeferrals > deferred)   // the role was issued inside the window, and held
            #expect(try await state(d, p) == before)
            #expect(!((try? String(contentsOf: input, encoding: .utf8)) ?? "").contains(role))
        }
    }

    @Test func exitedTerminalIsNamed() async throws {
        let fx = try FakeAgents(#"case "$ORQ_TERMINAL_NAME" in *-testes) exit 0;; esac"#); defer { fx.cleanup() }
        try await withDaemon(configure: fx.configure) { d, p in
            let r = try await apply(d, p, ["id": .string("investigar-bug"), "name": .string("x"), "cwd": .string("/tmp")])
            #expect(r.error == ProtocolError(code: .notRunning, message: "terminal x-testes saiu"), "\(r)")
            #expect(try await state(d, p).terminals.isEmpty)
        }
    }

    @Test func maestroApplyCordsToApplier() async throws {
        let fx = try FakeAgents(); defer { fx.cleanup() }
        try await withDaemon(configure: fx.configure) { d, p in
            let m = try await term(d, p, "M", maestro: true)
            let r = try await call(p, m, "partitura.apply", ["id": .string("investigar-bug"), "name": .string("x")])
            #expect(r.ok, "\(r)")
            let s = try await state(d, p)
            #expect(s.terminals.map(\.name).sorted() == ["M", "x-investigador", "x-testes"])
            #expect(s.terminals.filter(\.isMaestro).map(\.name) == ["M"])
            #expect(pairs(s) == [["M", "x-investigador"], ["M", "x-testes"]])
            #expect(s.terminals.allSatisfy { $0.cwd == "/tmp" })
            let other = try await call(p, m, "partitura.apply", ["id": .string("investigar-bug"), "name": .string("y"), "cwd": .string("/")])
            #expect(other.error?.code == .invalidArgs, "\(other)")
            #expect(try await state(d, p) == s)
        }
    }

    @Test func changedSincePreviewIsRefused() async throws {
        let fx = try FakeAgents(); defer { fx.cleanup() }
        try await withDaemon(configure: fx.configure) { d, p in
            func admin(_ cmd: String, _ a: [String: JSONValue]) async throws -> Response {
                try await send(p, Request(id: "i", token: d.adminToken, command: cmd, args: a), timeoutSeconds: 30)
            }
            var pt = Partitura(id: "time", name: "Time", terminals: [PartituraTerminal(key: "a", preset: .shell)])
            let json = { (x: Partitura) in JSONValue.string(String(decoding: try! PartituraFormat.encode(x), as: UTF8.self)) }
            #expect(try await admin("partitura.import", ["json": json(pt)]).ok)
            let seen = PartituraFormat.digest(pt)   // what the preview showed
            pt.terminals[0] = PartituraTerminal(key: "a", preset: .custom, command: "echo mudou")   // rewritten after the preview
            #expect(try await admin("partitura.import", ["json": json(pt), "replace": .bool(true)]).ok)
            let before = try await state(d, p)
            let r = try await apply(d, p, ["id": .string("time"), "name": .string("t"), "cwd": .string("/tmp"), "expect": .string(seen)])
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("a partitura mudou desde a prévia") == true, "\(r)")
            #expect(try await state(d, p) == before)
            let ok = try await apply(d, p, ["id": .string("time"), "name": .string("t"), "cwd": .string("/tmp"),
                                            "expect": .string(PartituraFormat.digest(pt))])
            #expect(ok.error?.message.contains("mudou desde a prévia") != true, "\(ok)")   // the current digest passes the check
        }
    }

    @Test func appAppliesOnTheFloorOnScreen() async throws {
        let fx = try FakeAgents(); defer { fx.cleanup() }
        let repo = try await makeRepo()
        try await withDaemon(configure: fx.configure) { d, p in
            #expect(try await send(p, Request(id: "f", token: d.adminToken, command: "floor.create",
                                              args: ["name": .string("y"), "repo": .string(repo.path)]), timeoutSeconds: 60).ok)
            let pt = Partitura(id: "time", name: "Time", terminals: [PartituraTerminal(key: "a", preset: .shell)],
                               panels: [PartituraPanel(key: "web", pluginId: "browser")], cords: [["a", "web"]])
            let json = JSONValue.string(String(decoding: try PartituraFormat.encode(pt), as: UTF8.self))
            #expect(try await send(p, Request(id: "i", token: d.adminToken, command: "partitura.import", args: ["json": json])).ok)
            let r = try await apply(d, p, ["id": .string("time"), "name": .string("t"), "onFloor": .string("y")])   // no cwd: the floor's
            #expect(r.ok, "\(r)")
            let s = try await state(d, p)
            let y = try #require(s.floors.first { $0.name == "y" })
            let t = try #require(s.terminals.first { $0.name == "t-a" })
            #expect(t.floorId == y.id && t.cwd == y.path, "\(t)")
            #expect(s.panels.map(\.floorId) == [y.id], "\(s.panels)")
            let bad = try await apply(d, p, ["id": .string("time"), "name": .string("u"), "cwd": .string("/tmp"), "onFloor": .string("nope")])
            #expect(bad.error?.message.contains("andar nope não existe") == true, "\(bad)")
            // a Maestro applies on its own floor only
            let m = try await term(d, p, "M", maestro: true)
            let other = try await call(p, m, "partitura.apply", ["id": .string("time"), "name": .string("v"), "onFloor": .string("y")])
            #expect(other.error?.message.contains("só no seu próprio andar") == true, "\(other)")
        }
    }

    @Test func terminalsCannotApply() async throws {
        try await withDaemon { d, p in
            let a = try await term(d, p, "A")
            let r = try await call(p, a, "partitura.apply", ["id": .string("investigar-bug"), "name": .string("x")])
            #expect(r.error?.code == .notMaestro, "\(r)")
            #expect(try await state(d, p).terminals.map(\.name) == ["A"])
        }
    }

    @Test func appliedEventCarriesFrames() async throws {
        let fx = try FakeAgents(); defer { fx.cleanup() }
        try await withDaemon(configure: fx.configure) { d, p in
            let ev = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            defer { ev.close() }
            let r = try await apply(d, p, ["id": .string("investigar-bug"), "name": .string("x"), "cwd": .string("/tmp")])
            #expect(r.ok, "\(r)")
            let s = try await state(d, p)
            var got: (UUID?, UUID?, [String: PartituraFrame])?
            while got == nil, case .event(let e)? = try await ev.next(timeoutSeconds: 30) {
                if case .partituraApplied(let by, let anchor, let frames, nil) = e { got = (by, anchor, frames) }
            }
            let (by, anchor, frames) = try #require(got)
            #expect(by == nil && anchor == nil)
            #expect(frames.count == 3)
            for t in bug.terminals {
                let id = try #require(s.terminals.first { $0.name == "x-\(t.key)" }?.id)
                #expect(frames[id.uuidString] == t.frame)
            }
            guard case .object(let o)? = r.result, case .object(let f)? = o["frames"] else { Issue.record("\(r)"); return }
            #expect(f.count == 3)
        }
    }
}

/// The fake figcraft engine: serialized with the other design tests.
extension DesignCommandTests {
    @Test func partituraAppliesWithFloor() async throws {
        let fx = try FakeAgents(); defer { fx.cleanup() }
        let fig = URL(fileURLWithPath: "/tmp/orq-fig-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: fig) }
        let bin = fig.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("figcraft-cli"),
                                                   withDestinationURL: fixtures.appendingPathComponent("fake-figcraft-mcp.py"))
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("figcraft-server"),
                                                   withDestinationURL: fixtures.appendingPathComponent("fake-figcraft-server.sh"))
        let log = fig.appendingPathComponent("calls.log")
        try Data().write(to: log)
        setenv("ORQ_FAKE_FIG_LOG", log.path, 1)
        let repo = try await makeRepo()
        try await withDaemon(configure: { fx.configure(&$0); $0.figcraftDir = fig }) { d, p in
            let r = try await apply(d, p, ["id": .string("feature-fullstack"), "name": .string("x"), "cwd": .string(repo.path)])
            #expect(r.ok, "\(r)")
            let s = try await state(d, p)
            let f = try #require(s.floors.first)
            #expect(s.floors.map(\.name) == ["x"] && f.createdBy == nil)
            #expect(s.terminals.map(\.name).sorted() == ["x-backend", "x-interface", "x-maestro", "x-revisor"])
            #expect(s.terminals.allSatisfy { $0.floorId == f.id && $0.cwd == f.path })
            #expect(s.panels.map(\.name).sorted() == ["x-design", "x-navegador"])
            #expect(s.panels.allSatisfy { $0.floorId == f.id && $0.placement == .canvas })
            #expect(pairs(s) == [["x-maestro", "x-backend"], ["x-maestro", "x-interface"], ["x-maestro", "x-revisor"],
                                 ["x-interface", "x-design"], ["x-interface", "x-navegador"]])
        }
    }
}

extension DesignCommandTests {
    @Test func partituraRollbackKeepsDesignFile() async throws {
        let fig = URL(fileURLWithPath: "/tmp/orq-fig-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: fig) }
        let bin = fig.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("figcraft-cli"),
                                                   withDestinationURL: fixtures.appendingPathComponent("fake-figcraft-mcp.py"))
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("figcraft-server"),
                                                   withDestinationURL: fixtures.appendingPathComponent("fake-figcraft-server.sh"))
        let log = fig.appendingPathComponent("calls.log")
        try Data().write(to: log)
        setenv("ORQ_FAKE_FIG_LOG", log.path, 1)
        // the revisor is ready, then (once the design panel talks to figcraft, after every pre-role check) asks for approval:
        // its role fails after the design file was created
        let fx = try FakeAgents(#"case "$ORQ_TERMINAL_NAME" in *-revisor) echo ready; while [ ! -s '\#(log.path)' ]; do sleep 0.1; done; printf 'Do you trust the files in this folder? (y/n) '; exec cat > /dev/null;; esac"#)
        defer { fx.cleanup() }
        let repo = try await makeRepo()
        try await withDaemon(configure: { fx.configure(&$0); $0.figcraftDir = fig }) { d, p in
            let r = try await apply(d, p, ["id": .string("feature-fullstack"), "name": .string("x"), "cwd": .string(repo.path)])
            #expect(r.error?.message.contains("x-revisor está pedindo aprovação") == true, "\(r)")
            #expect(r.error?.message.contains("arquivo de design Feature mantido") == true, "\(r)")
            let s = try await state(d, p)
            #expect(s.terminals.isEmpty && s.panels.isEmpty, "\(s)")
        }
    }
}
