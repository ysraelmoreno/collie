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

    @Test func onlyNeverCutsSegurancaWhenX4CallsIt() throws {
        let catalog = [persona("correcao"), persona("testes", paths: ["Tests/**"]), persona("seguranca", paths: ["Sources/**"])]
        let r = PersonaRouter(catalog: catalog)
        let only = ["correcao", "testes"]
        #expect(try r.select(changedPaths: ["docs/fabrica/personas/testes.md"], diffLines: 10, only: only).map(\.name) == ["correcao", "seguranca"])
        #expect(try r.select(changedPaths: ["docs/spec.md", "Tests/A.swift"], diffLines: 10, specs: ["docs/spec.md"], only: only).map(\.name)
                == ["correcao", "seguranca", "testes"])
        // by its own globs only (no X4): the profile's list still cuts it
        #expect(try r.select(changedPaths: ["Sources/B.swift"], diffLines: 10, only: only).map(\.name) == ["correcao"])
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

    @Test func theCardTellsTheReviewAsItRuns() throws {
        let w = Work(title: "W", terminalId: UUID()), t = [WorkTask(id: "a", title: "A", check: "true")]
        var l = WorkLoopState(max: 3, tasks: ["a"]); l.review = true; l.reviewOnly = ["testes"]; l.reviewThreshold = "blocker"
        let card = try #require(CommandRouter.loopCardText(w, t, l, paddock: "p"))
        #expect(card.contains("revisão por personas: auto (só «testes»), veto só por blocker (collie-work.json)"), "\(card)")
        let trusted = WorkStatusText.loopTrusted(paddock: "p", t, l)
        #expect(trusted.contains("(só «testes»)") && trusted.contains("veto só por blocker"), "\(trusted)")
        let off = WorkLoopState(max: 3, tasks: ["a"])
        #expect(CommandRouter.loopCardText(w, t, off, paddock: "p", profileReviewOff: true)?.contains("sem revisão: --no-review desliga a do perfil") == true)
        #expect(WorkStatusText.loopTrusted(paddock: "p", t, off, profileReviewOff: true).contains("sem revisão: --no-review desliga a do perfil"))
        #expect(CommandRouter.loopCardText(w, t, off, paddock: "p")?.contains("revisão") == false)
    }

    @Test func theBudgetCutIsToldInStatus() {
        var w = Work(title: "W", terminalId: UUID())
        w.loop = WorkLoopState(max: 3, budget: 43_200, tasks: ["a"]); w.loop?.origins = ["budget": "perfil", "budgetCut": "86400"]
        #expect(WorkStatusText.originLines(w).contains("orçamento do perfil (86400 s) cortado para 43200 s, o teto do laço"))
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
            #expect(status.contains("revisão: desligada") && !status.contains("origem revisão: flag") && status.contains("origem orçamento: perfil"), "\(status)")
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

    @Test func anIgnoredFileWarnsEvenWithEveryFlag() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await commit(ProjectWorkConfig.fileName, #"{ "version": 1, "gate": 3 }"#, in: x.dir)
            let (r, loop, _) = try await runAndRead(d, p, x, ["gate": .string("true"), "precheck": .string("true")])
            let w = try #require(warningOf(r), "\(r)")
            #expect(w.contains("ignorado") && w.contains("revisão, orçamento nem tentativas"), "\(w)")
            #expect(loop?.review == nil)
        }
    }

    @Test func theProfilesPersonasAreCheckedAndItsRefusalNamesTheProfile() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await commit(ProjectWorkConfig.fileName, #"{ "version": 1, "factory": { "version": 1, "review": { "personas": ["seguranca"] } } }"#, in: x.dir)
            let r = try await call(d, p, x.s, "work.run", ["max": .number(3)])
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("factory.review.personas") == true
                    && r.error?.message.contains("testes") == true, "\(r)")
            #expect(await !d.router.appCards.contains { $0.app == "work-loop" })
            // no catalog at HEAD, the profile turning the review on: the refusal says it is the profile's
            try await commit(ProjectWorkConfig.fileName, #"{ "version": 1, "factory": { "version": 1, "review": {} } }"#, in: x.dir)
            let git = try await GitRunner.run(["rm", "-q", "-r", CommandRouter.personasDir], in: x.dir, timeout: .seconds(30))
            #expect(git.status == 0)
            _ = try await GitRunner.run(["commit", "-q", "-m", "no personas"], in: x.dir, timeout: .seconds(30))
            let none = try await call(d, p, x.s, "work.run", ["max": .number(3)])
            #expect(none.error?.message.contains("factory.review do collie-work.json liga a revisão, mas não há personas em HEAD") == true, "\(none)")
        }
    }

    /// C1 (B1-a): the profile's personas are checked even with the review off: an unknown one warns, in the reply
    /// and in `work status`, and refuses nothing.
    @Test func anUnknownProfilePersonaWarnsWithTheReviewOff() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await commit(ProjectWorkConfig.fileName, #"{ "version": 1, "factory": { "version": 1, "review": { "personas": ["testes", "seguranca"] } } }"#, in: x.dir)
            let (r, loop, status) = try await runAndRead(d, p, x, ["no-review": .bool(true)])
            #expect(r.ok && warningOf(r)?.contains("persona desconhecida em HEAD: seguranca") == true, "\(r)")
            #expect(loop?.review == nil && loop?.origins?["unknownPersonas"] == "seguranca", "\(String(describing: loop))")
            #expect(status.contains("persona desconhecida em HEAD: seguranca"), "\(status)")
        }
    }

    @Test func landFactoryPaddockInAMarkedPaddockSaysA4() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try await commit(ProjectWorkConfig.fileName, #"{ "version": 1, "factory": { "version": 1, "guardrails": { "land": "factory-paddock" } } }"#, in: x.dir)
            let id = try #require(await d.router.ws.paddocks.first { $0.name == "feat" }?.id)
            _ = try await d.router.setFactory(id, true)
            let (r, _, _) = try await runAndRead(d, p, x, [:])
            #expect(warningOf(r)?.contains("auto-land ainda não existe (A4); segue manual") == true, "\(r)")
            #expect(warningOf(r)?.contains("não tem a marca") == false, "\(r)")
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
