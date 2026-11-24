import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// A2: the "cercado fábrica" mark. Persisted on the paddock, set only by the owner (the admin principal: the app or the
/// owner's CLI), never by an agent's terminal nor MCP; on needs a profile the doctor passes (static and judge >= 1).
private struct Term { var id: String; var token: String }

private func spawnIn(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL, shepherd: Bool = false, paddock: String? = nil) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path), "shepherd": .bool(shepherd)]
    if let paddock { args["paddock"] = .string(paddock); args["cwd"] = nil }
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
/// `t` nil: the owner (admin token, outside any terminal).
private func call(_ d: Daemon, _ p: Paths, _ t: Term?, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "f", terminalId: t?.id, token: t?.token ?? d.adminToken, command: cmd, args: args), timeoutSeconds: 60)
}
private func put(_ dir: URL, _ rel: String, _ body: String) throws {
    let u = dir.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(body.utf8).write(to: u)
}
/// A folder (its own project root: it has `.git`) the test removes at the end.
private func folder(_ body: (URL) async throws -> Void) async throws {
    let dir = URL(fileURLWithPath: SignedAppCheck.realPath(FileManager.default.temporaryDirectory)).appendingPathComponent("pfac-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir)
}
/// A profile like the repository's `collie-work.json`: a gate whose script runs the tests, areas, a factory block.
private func collieProfile(_ dir: URL, land: String = "manual") throws {
    try put(dir, "collie-work.json", """
    { "version": 1, "gate": "scripts/ci/gate.sh", "precheck": "swift build --build-tests",
      "smoke": "swift test --filter WorkLoopTests",
      "areas": { "work": "swift test --filter WorkCommandTests" },
      "factory": { "version": 1, "static": { "architecture": ["scripts/ci/check-architecture.sh"] },
        "review": { "personas": ["correcao", "testes"], "threshold": "major" },
        "guardrails": { "budgetSeconds": 14400, "maxTries": 3, "destructive": ["git push"], "land": "\(land)" } } }
    """)
    try put(dir, "scripts/ci/gate.sh", "#!/bin/bash\nscripts/ci/lint.sh\nswift test --disable-sandbox\n")
    try put(dir, "scripts/ci/check-architecture.sh", "#!/bin/bash\nexit 0\n")
}

@Suite(.serialized) struct PaddockFactoryTests {
    @Test func missingFieldDecodesFalseAndRoundTrips() throws {
        let old = #"{"id":"\#(UUID().uuidString)","name":"feat","repoRoot":"/r","path":"/r/.collie/paddocks/feat","branch":"collie/feat","baseBranch":"main","status":"working"}"#
        var f = try JSONDecoder().decode(Paddock.self, from: Data(old.utf8))
        #expect(f.factory == false)
        #expect(try JSONDecoder().decode(Paddock.self, from: Data(old.replacingOccurrences(of: #""status""#, with: #""factory":"yes","status""#).utf8)).factory == false)
        f.factory = true
        #expect(try JSONDecoder().decode(Paddock.self, from: try JSONEncoder().encode(f)).factory == true)
    }

    @Test func commandIsOwnerOnlyAndNotOnMCP() throws {
        let spec = try #require(Commands.spec("paddock.factory"))
        #expect(!spec.exposedToMCP && spec.params.map(\.name) == ["name", "state"])
        let names = String(decoding: try JSONEncoder().encode(JSONValue.array(MCPSchema.tools(shepherd: true))), as: UTF8.self)
        #expect(!names.contains("paddock_factory"))
        let r = try ArgvParser.parse(["paddock", "factory", "feat", "on"])
        #expect(r.command == "paddock.factory" && r.args["name"] == .string("feat") && r.args["state"] == .string("on"))
        #expect(try ArgvParser.parse(["paddock", "create", "k", "--factory"]).args["factory"] == .bool(true))
    }

    @Test func humanLineShowsFabricaBesideTheName() {
        #expect(PaddockText.line(["name": .string("k"), "status": .string("working"), "factory": .bool(true), "branch": .string("collie/k")]) == "k (fábrica)\tworking\tcollie/k")
        #expect(PaddockText.line(["name": .string("k"), "status": .string("idle"), "factory": .bool(false), "branch": .string("")]) == "k\tidle")
        // B1: the path too (docs/referencia.md: list and status bring the paths)
        #expect(PaddockText.line(["name": .string("k"), "status": .string("idle"), "branch": .string("collie/k"), "path": .string("/r/k")]) == "k\tidle\tcollie/k\t/r/k")
    }

    @Test func mcpNeverCreatesAMarkedPaddock() throws {
        let tool = try #require(MCPSchema.tools(shepherd: true).first { if case .object(let o) = $0 { o["name"] == .string("paddock_create") } else { false } })
        guard case .object(let o) = tool, case .object(let schema)? = o["inputSchema"], case .object(let props)? = schema["properties"] else { Issue.record("\(tool)"); return }
        #expect(props["factory"] == nil && props["name"] != nil, "\(props)")
        #expect(MCPSchema.refusal(command: "paddock.create", args: ["name": .string("k"), "factory": .bool(true)])?.contains("never by MCP") == true)
        #expect(MCPSchema.refusal(command: "paddock.create", args: ["name": .string("k")]) == nil)
    }

    @Test func doctorLines() {
        let f = Paddock.folder(name: "k", path: "/x")
        var on = f; on.factory = true
        #expect(FactoryDoctorReader.factoryPaddockLines(f, land: .manual) == ["cercado fábrica: não"])
        #expect(FactoryDoctorReader.factoryPaddockLines(on, land: .factoryPaddock) == ["cercado fábrica: sim"])
        let warn = FactoryDoctorReader.factoryPaddockLines(f, land: .factoryPaddock)
        #expect(warn.count == 2 && warn[1].hasPrefix("aviso: guardrails.land = factory-paddock") && warn[1].contains("paddock factory k on"))
        let none = FactoryDoctorReader.factoryPaddockLines(nil, land: .factoryPaddock)
        #expect(none[0] == "cercado fábrica: não (cercado não reconhecido)" && none[1].contains("não foi reconhecido"))
    }

    /// On and off from the owner persist (and survive reloading the store); list and status carry `factory`.
    @Test func ownerTurnsItOnAndOffAndItPersists() async throws {
        try await folder { dir in
            try collieProfile(dir)
            try await withDaemon { d, p in
                #expect(try await call(d, p, nil, "paddock.create", ["name": .string("k"), "folder": .string(dir.path)]).ok)
                func mark() async -> Bool? { await d.router.ws.paddocks.first { $0.name == "k" }?.factory }
                #expect(await mark() == false)
                let on = try await call(d, p, nil, "paddock.factory", ["name": .string("k"), "state": .string("on")])
                guard case .object(let o)? = on.result else { Issue.record("\(on)"); return }
                #expect(o["factory"] == .bool(true) && o["name"] == .string("k"), "\(o)")
                #expect(await mark() == true)
                let wsId = await d.router.ws.id
                #expect(try await WorkspaceStore(paths: p).load(wsId).paddocks.first { $0.name == "k" }?.factory == true)   // a restart reads it

                guard case .array(let rows)? = try await call(d, p, nil, "paddock.list").result,
                      case .object(let row)? = rows.first(where: { if case .object(let x) = $0 { x["name"] == .string("k") } else { false } })
                else { Issue.record("no list"); return }
                #expect(row["factory"] == .bool(true))
                guard case .object(let st)? = try await call(d, p, nil, "paddock.status", ["name": .string("k")]).result else { Issue.record("no status"); return }
                #expect(st["factory"] == .bool(true))
                #expect(try await call(d, p, nil, "paddock.status", ["name": .string("k"), "status": .string("review")]).ok)
                #expect(await mark() == true)   // setting the status keeps it

                #expect(try await call(d, p, nil, "paddock.factory", ["name": .string("k"), "state": .string("maybe")]).error?.code == .invalidArgs)
                // off never refuses, even with the profile gone
                try FileManager.default.removeItem(at: dir.appendingPathComponent("collie-work.json"))
                #expect(try await call(d, p, nil, "paddock.factory", ["name": .string("k"), "state": .string("off")]).ok)
                #expect(await mark() == false)
                #expect(try await WorkspaceStore(paths: p).load(wsId).paddocks.first { $0.name == "k" }?.factory == false)
                guard case .object(let off)? = try await call(d, p, nil, "paddock.status", ["name": .string("k")]).result else { Issue.record("no status"); return }
                #expect(off["factory"] == .bool(false))
            }
        }
    }

    @Test func createFactoryMarksItAtOnce() async throws {
        try await folder { dir in
            try collieProfile(dir)
            try await withDaemon { d, p in
                let r = try await call(d, p, nil, "paddock.create", ["name": .string("k"), "folder": .string(dir.path), "factory": .bool(true)])
                guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
                #expect(o["factory"] == .bool(true))
                #expect(await d.router.ws.paddocks.first { $0.name == "k" }?.factory == true)
            }
        }
    }

    /// An agent's terminal (a Shepherd too) can neither turn it on nor off, nor create a marked paddock: the mark stays.
    @Test func anAgentCannotTouchTheMark() async throws {
        try await folder { dir in
            try collieProfile(dir)
            try await withDaemon { d, p in
                let agent = try await spawnIn(d, p, "S", cwd: dir, shepherd: true)
                #expect(try await call(d, p, nil, "paddock.create", ["name": .string("k"), "folder": .string(dir.path)]).ok)
                let on = try await call(d, p, agent, "paddock.factory", ["name": .string("k"), "state": .string("on")])
                #expect(on.error?.code == .unauthorized, "\(on)")
                #expect(await d.router.ws.paddocks.first { $0.name == "k" }?.factory == false)
                #expect(try await call(d, p, nil, "paddock.factory", ["name": .string("k"), "state": .string("on")]).ok)
                let off = try await call(d, p, agent, "paddock.factory", ["name": .string("k"), "state": .string("off")])
                #expect(off.error?.code == .unauthorized, "\(off)")
                #expect(await d.router.ws.paddocks.first { $0.name == "k" }?.factory == true)
                let made = try await call(d, p, agent, "paddock.create", ["name": .string("k2"), "folder": .string(dir.path), "factory": .bool(true)])
                #expect(made.error?.code == .unauthorized, "\(made)")
                #expect(await d.router.ws.paddocks.contains { $0.name == "k2" } == false)
            }
        }
    }

    /// On (and create --factory) refuses with the layer and the next action: no profile or no gate (static 0), an invalid
    /// profile. Nothing is marked; the repository-like profile passes.
    @Test func onNeedsAValidProfile() async throws {
        try await folder { dir in
            try await withDaemon { d, p in
                #expect(try await call(d, p, nil, "paddock.create", ["name": .string("k"), "folder": .string(dir.path)]).ok)
                func on() async throws -> Response { try await call(d, p, nil, "paddock.factory", ["name": .string("k"), "state": .string("on")]) }
                let none = try await on()
                #expect(none.error?.code == .invalidArgs && none.error?.message.contains("camada static 0/3") == true
                        && none.error?.message.contains("próxima ação") == true, "\(String(describing: none.error))")
                try put(dir, "collie-work.json", #"{"version": 1, "smoke": "swift test"}"#)   // no gate: static 0
                let noGate = try await on()
                #expect(noGate.error?.message.contains("camada static 0/3") == true, "\(String(describing: noGate.error))")
                try put(dir, "collie-work.json", #"{"version": 1, "gate": 3}"#)
                let bad = try await on()
                #expect(bad.error?.code == .invalidArgs && bad.error?.message.contains("perfil inválido") == true, "\(String(describing: bad.error))")
                let made = try await call(d, p, nil, "paddock.create", ["name": .string("k2"), "folder": .string(dir.path), "factory": .bool(true)])
                #expect(made.error?.message.contains("perfil inválido") == true, "\(made)")
                #expect(await d.router.ws.paddocks.contains { $0.name == "k2" } == false)
                #expect(await d.router.ws.paddocks.first { $0.name == "k" }?.factory == false)
                try collieProfile(dir)
                #expect(try await on().ok)
            }
        }
    }

    /// B1: on reads the profile the loop reads (HEAD): a good profile only in the tree, HEAD without it, refuses.
    @Test func onRefusesAProfileThatIsNotHEADs() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            #expect(try await call(d, p, nil, "paddock.create", ["name": .string("k"), "repo": .string(repo.path)]).ok)
            let dir = repo.appendingPathComponent(".collie/paddocks/k")
            try collieProfile(dir)
            let on = try await call(d, p, nil, "paddock.factory", ["name": .string("k"), "state": .string("on")])
            #expect(on.error?.code == .invalidArgs && on.error?.message.contains("difere do commit HEAD") == true
                    && on.error?.message.contains("\n") == false, "\(on)")
            #expect(await d.router.ws.paddocks.first { $0.name == "k" }?.factory == false)
        }
    }

    /// `factory doctor` says whether the paddock is marked, and warns on land = factory-paddock without the mark.
    @Test func doctorShowsTheMark() async throws {
        try await folder { dir in
            try collieProfile(dir, land: "factory-paddock")
            try await withDaemon { d, p in
                #expect(try await call(d, p, nil, "paddock.create", ["name": .string("k"), "folder": .string(dir.path)]).ok)
                let t = try await spawnIn(d, p, "T", cwd: dir, paddock: "k")
                func out() async throws -> String {
                    let r = try await call(d, p, t, "factory.doctor", ["min": .number(0)])
                    guard case .object(let o)? = r.result, case .string(let s)? = o["output"] else { Issue.record("\(r)"); return "" }
                    return s
                }
                let before = try await out()
                #expect(before.contains("cercado fábrica: não") && before.contains("aviso: guardrails.land = factory-paddock"), "\(before)")
                #expect(try await call(d, p, nil, "paddock.factory", ["name": .string("k"), "state": .string("on")]).ok)
                let after = try await out()
                #expect(after.contains("cercado fábrica: sim") && !after.contains("aviso: guardrails.land"), "\(after)")
            }
        }
    }
}
