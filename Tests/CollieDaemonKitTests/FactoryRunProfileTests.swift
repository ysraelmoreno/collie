import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// A1: `work run` applies the `factory` block of the base's `collie-work.json` (an explicit flag wins over the profile,
/// the profile over the engine's default). Real git in a temp repo and a test daemon (no terminal sandbox).
private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func spawnIn(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL, shepherd: Bool = false, paddock: String? = nil) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path), "shepherd": .bool(shepherd)]
    if let paddock { args["paddock"] = .string(paddock); args["cwd"] = nil }
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func call(_ d: Daemon, _ p: Paths, _ t: Term, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "w", terminalId: t.id, token: t.token, command: cmd, args: args), timeoutSeconds: 60)
}

private let profile = #"""
{ "version": 1, "factory": { "version": 1,
  "review": { "personas": ["testes"], "threshold": "blocker" },
  "guardrails": { "budgetSeconds": 900, "maxTries": 2, "destructive": ["rm -rf", "git push --force"] } } }
"""#

@Suite(.serialized, .timeLimit(.minutes(5))) struct FactoryRunProfileTests {
    // MARK: pure: the profile's personas and threshold in the review

    private func persona(_ name: String, paths: [String] = []) -> Persona { Persona(name: name, model: nil, paths: paths, body: "x") }

    @Test func theProfilesPersonasRestrictTheAutoChoice() throws {
        let catalog = [persona("correcao"), persona("testes", paths: ["Tests/**"]), persona("seguranca", paths: ["Sources/**"])]
        let r = PersonaRouter(catalog: catalog)
        let paths = ["Tests/A.swift", "Sources/B.swift"]
        #expect(try r.select(changedPaths: paths, diffLines: 10).map(\.name) == ["correcao", "seguranca", "testes"])
        // A1 decision: correcao is never cut (the router's invariant), the rest only what the profile names
        #expect(try r.select(changedPaths: paths, diffLines: 10, only: ["testes"]).map(\.name) == ["correcao", "testes"])
        // empty: no restriction; an explicit --personas wins over the profile
        #expect(try r.select(changedPaths: paths, diffLines: 10, only: []).map(\.name) == ["correcao", "seguranca", "testes"])
        #expect(try r.select(changedPaths: paths, diffLines: 10, requested: ["seguranca"], only: ["testes"]).map(\.name) == ["correcao", "seguranca"])
    }

    @Test func thresholdBlockerDoesNotVetoAMajor() {
        let major = PersonaVerdict(persona: "testes", approved: false, findings: [ReviewFinding(severity: .major, file: "A.swift", line: 3, claim: "bug")])
        #expect(ReviewVerdict.aggregate([major]).approved == false)                          // today: a major vetoes
        #expect(ReviewVerdict.aggregate([major], threshold: "major").approved == false)
        let b = ReviewVerdict.aggregate([major], threshold: "blocker")
        #expect(b.approved && b.notes.contains { $0.contains("bug") }, "\(b)")               // a note, not a veto
        let blocker = PersonaVerdict(persona: "testes", approved: false, findings: [ReviewFinding(severity: .blocker, file: "A.swift", line: 3, claim: "bug")])
        #expect(ReviewVerdict.aggregate([blocker], threshold: "blocker").approved == false)
    }

    @Test func statusLinesComeOnlyWithAProfile() {
        var w = Work(title: "W", terminalId: UUID())
        w.loop = WorkLoopState(max: 3, tasks: ["a"])
        #expect(WorkStatusText.originLines(w).isEmpty)
    }

    // MARK: work run, through the daemon

    private struct Pad { let dir: URL; let s: Term }
    private func pad(_ d: Daemon, _ p: Paths) async throws -> Pad {
        let repo = try await makeRepo()
        let m = try await spawnIn(d, p, "M", cwd: repo, shepherd: true)
        #expect(try await call(d, p, m, "paddock.create", ["name": .string("feat")]).ok)
        let s = try await spawnIn(d, p, "S", cwd: repo, shepherd: true, paddock: "feat")
        #expect(try await call(d, p, s, "work.start", ["title": .string("Loop work")]).ok)
        #expect(try await call(d, p, s, "work.task.add", ["title": .string("A"), "check": .string("true")]).ok)
        let dir = repo.appendingPathComponent(".collie/paddocks/feat")
        // a persona catalog at HEAD: --review (from the flag or the profile) needs one
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(CommandRouter.personasDir), withIntermediateDirectories: true)
        try await commit(CommandRouter.personasDir + "testes.md", "x\n", in: dir)
        return Pad(dir: dir, s: s)
    }

    /// `work run`, the owner's Permitir, then the loop as recorded and the `work.status` text; the loop stopped after.
    private func runAndRead(_ d: Daemon, _ p: Paths, _ x: Pad, _ args: [String: JSONValue]) async throws -> (Response, WorkLoopState?, String) {
        let r = try await call(d, p, x.s, "work.run", ["max": .number(3)].merging(args) { $1 })
        guard r.ok else { return (r, nil, "") }
        _ = await waitFor(20) { await d.router.appCards.contains { $0.app == "work-loop" } }
        let card = try #require(await d.router.appCards.first { $0.app == "work-loop" }, "no approval card")
        #expect(try await send(p, Request(id: "a", token: d.adminToken, command: "admin.app.answer",
                                          args: ["id": .string(card.id.uuidString), "allow": .bool(true), "always": .bool(false)])).ok)
        let id = try #require(try await d.router.work.active(terminal: x.s.uuid)?.id)
        _ = await waitFor(20) { (try? await d.router.work.get(id))?.loop != nil }
        let loop = try await d.router.work.get(id)?.loop
        let status = "\(String(describing: try await call(d, p, x.s, "work.status").result))"
        _ = try await call(d, p, x.s, "work.stop")
        return (r, loop, status)
    }

    private func warningOf(_ r: Response) -> String? {
        if case .object(let o)? = r.result, case .string(let w)? = o["warning"] { return w }
        return nil
    }

    @Test func noFactoryChangesNothing() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await commit(ProjectWorkConfig.fileName, #"{ "version": 1 }"#, in: x.dir)
            let (r, loop, status) = try await runAndRead(d, p, x, [:])
            #expect(r.ok && warningOf(r) == nil, "\(r)")
            let l = try #require(loop)
            #expect(l.review == nil && l.tries == 3 && l.budget == Int(CommandRouter.loopBudgetDefault), "\(l)")
            #expect(l.origins == nil && l.reviewOnly == nil && l.reviewThreshold == nil && l.destructive == nil)
            #expect(!status.contains("origem") && !status.contains("destructive"), "\(status)")
        }
    }

    @Test func theProfileSetsReviewTriesAndBudgetAndAFlagWins() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await commit(ProjectWorkConfig.fileName, profile, in: x.dir)
            // --budget given, --tries and --review left out
            let (r, loop, status) = try await runAndRead(d, p, x, ["budget": .number(600)])
            #expect(r.ok, "\(r)")
            let l = try #require(loop)
            #expect(l.review == true && l.reviewOnly == ["testes"] && l.reviewThreshold == "blocker", "\(l)")
            #expect(l.tries == 2 && l.budget == 600 && l.destructive == 2, "\(l)")
            #expect(l.origins == ["review": "perfil", "budget": "flag", "tries": "perfil"], "\(String(describing: l.origins))")
            for line in ["origem revisão: perfil", "origem orçamento: flag", "origem tentativas: perfil", "destructive tem 2", "ainda não bloqueia"] {
                #expect(status.contains(line), "\(line): \(status)")
            }
        }
    }

    @Test func noReviewAndTriesFlagsWinOverTheProfile() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await commit(ProjectWorkConfig.fileName, profile, in: x.dir)
            let (r, loop, status) = try await runAndRead(d, p, x, ["no-review": .bool(true), "tries": .number(5)])
            #expect(r.ok, "\(r)")
            let l = try #require(loop)
            #expect(l.review == nil && l.reviewOnly == nil && l.reviewThreshold == nil, "\(l)")
            #expect(l.tries == 5 && l.budget == 900, "\(l)")
            #expect(l.origins == ["review": "flag", "budget": "perfil", "tries": "flag"], "\(String(describing: l.origins))")
            #expect(status.contains("origem revisão: flag") && status.contains("origem orçamento: perfil"), "\(status)")
            let both = try await call(d, p, x.s, "work.run", ["max": .number(3), "review": .bool(true), "no-review": .bool(true)])
            #expect(both.error?.code == .invalidArgs, "\(both)")
        }
    }

    @Test func noReviewInTheProfileIsTheDefault() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await commit(ProjectWorkConfig.fileName, #"{ "version": 1, "factory": { "version": 1, "guardrails": { "land": "factory-paddock" } } }"#, in: x.dir)
            let (r, loop, _) = try await runAndRead(d, p, x, [:])
            // land factory-paddock in a paddock without the mark: a warning, and the loop goes on as manual
            #expect(r.ok && warningOf(r)?.contains("'manual'") == true, "\(r)")
            let l = try #require(loop)
            #expect(l.review == nil && l.tries == 3, "\(l)")
            #expect(l.origins == ["review": "padrão", "budget": "padrão", "tries": "padrão"], "\(String(describing: l.origins))")
        }
    }

    @Test func anInvalidFactoryIsRefusedBeforeTheLoop() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await commit(ProjectWorkConfig.fileName, #"{ "version": 1, "factory": { "version": 1, "guardrails": { "maxTries": 99 } } }"#, in: x.dir)
            // with --gate and --precheck given too: the factory block is still read
            let r = try await call(d, p, x.s, "work.run", ["max": .number(3), "gate": .string("true"), "precheck": .string("true")])
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("factory.guardrails.maxTries") == true, "\(r)")
            #expect(r.error?.message.contains("\n") == false)
            #expect(await !d.router.appCards.contains { $0.app == "work-loop" })
            #expect(try await d.router.work.active(terminal: x.s.uuid)?.loop == nil)
        }
    }

    @Test func theProfileComesFromTheBaseNotTheTree() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            // in the tree, never committed: not the base's
            try Data(profile.utf8).write(to: x.dir.appendingPathComponent(ProjectWorkConfig.fileName))
            let (r, loop, _) = try await runAndRead(d, p, x, [:])
            #expect(r.ok, "\(r)")
            let l = try #require(loop)
            #expect(l.review == nil && l.tries == 3 && l.origins == nil, "\(l)")
        }
    }
}
