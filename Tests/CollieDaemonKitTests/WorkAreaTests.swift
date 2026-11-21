import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// M13.2: `work task add --area` builds the task's check from `collie-work.json`, and `work run` takes `--gate` and
/// `--precheck` from the file when the flag is absent. The daemon reads the file with the real reader (`WorkConfigFile`).
private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func spawnIn(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL, shepherd: Bool = false, paddock: String? = nil) async throws -> Term {
    var args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path), "shepherd": .bool(shepherd)]
    if let paddock { args["paddock"] = .string(paddock); args["cwd"] = nil }
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
private func work(_ d: Daemon, _ p: Paths, _ t: Term?, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "w", terminalId: t?.id, token: t?.token ?? d.adminToken, command: cmd, args: args), timeoutSeconds: 60)
}
private func writeConfig(_ dir: URL, _ body: String) throws {
    try Data(body.utf8).write(to: dir.appendingPathComponent(ProjectWorkConfig.fileName))
}
private let withSmoke = """
{ "version": 1, "gate": "scripts/ci/lint.sh", "precheck": "swift build --build-tests", "smoke": "scripts/smoke.sh",
  "areas": { "ask": "swift test --filter AskTests", "quadro": "scripts/check-onda12.sh q12-1" } }
"""

@Suite(.serialized) struct WorkAreaTests {
    // MARK: work task add --area

    @Test func areaBuildsTheCheckWithSmoke() async throws {
        let repo = try await makeRepo()
        try writeConfig(repo, withSmoke)
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: repo)
            let r = try await work(d, p, a, "work.task.add", ["title": .string("T"), "area": .string("quadro,ask")])
            #expect(r.ok, "\(r)")
            let expected = "scripts/check-onda12.sh q12-1 && swift test --filter AskTests && scripts/smoke.sh"
            guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
            #expect(o["check"] == .string(expected), "\(o)")
            if case .string(let out)? = o["output"] { #expect(out.contains(expected), out) } else { Issue.record("no output: \(o)") }
            // the task keeps the built check (the loop runs task.check as always)
            let t = try #require(try await d.router.work.active(terminal: a.uuid)?.tasks.first)
            #expect(t.check == expected)
        }
    }

    @Test func areaBuildsTheCheckWithoutSmokeAndOverMCPArray() async throws {
        let repo = try await makeRepo()
        try writeConfig(repo, #"{ "areas": { "ask": "swift test --filter AskTests", "quadro": "q" } }"#)
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: repo)
            let r = try await work(d, p, a, "work.task.add", ["title": .string("T"), "area": .array([.string("ask")])])
            #expect(r.ok, "\(r)")
            #expect(try await d.router.work.active(terminal: a.uuid)?.tasks.first?.check == "swift test --filter AskTests")
        }
    }

    @Test func areaWithCheckIsRefused() async throws {
        let repo = try await makeRepo()
        try writeConfig(repo, withSmoke)
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: repo)
            let r = try await work(d, p, a, "work.task.add", ["title": .string("T"), "area": .string("ask"), "check": .string("true")])
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("--area") == true && r.error?.message.contains("--check") == true, "\(r)")
            #expect(try await d.router.work.active(terminal: a.uuid)?.tasks.isEmpty ?? true)
        }
    }

    @Test func unknownAreaListsTheValidOnes() async throws {
        let repo = try await makeRepo()
        try writeConfig(repo, withSmoke)
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: repo)
            let r = try await work(d, p, a, "work.task.add", ["title": .string("T"), "area": .string("ask,nope")])
            #expect(r.error?.code == .invalidArgs, "\(r)")
            let m = r.error?.message ?? ""
            #expect(m.contains("nope") && m.contains("ask, quadro"), "\(m)")
            #expect(try await d.router.work.active(terminal: a.uuid)?.tasks.isEmpty ?? true)
        }
    }

    @Test func areaWithoutFileOrWithInvalidFileIsRefused() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let a = try await spawnIn(d, p, "A", cwd: repo)
            let none = try await work(d, p, a, "work.task.add", ["title": .string("T"), "area": .string("ask")])
            #expect(none.error?.code == .invalidArgs && none.error?.message.contains("collie-work.json") == true, "\(none)")
            try writeConfig(repo, #"{ "version": 2, "areas": { "ask": "x" } }"#)
            let bad = try await work(d, p, a, "work.task.add", ["title": .string("T"), "area": .string("ask")])
            #expect(bad.error?.code == .invalidArgs && bad.error?.message.contains("version 2") == true, "\(bad)")
            #expect(try await d.router.work.active(terminal: a.uuid)?.tasks.isEmpty ?? true)
        }
    }

    // MARK: work run: gate and precheck from the file

    private struct Pad { let repo: URL; let dir: URL; let s: Term; let work: UUID }
    private func pad(_ d: Daemon, _ p: Paths) async throws -> Pad {
        let repo = try await makeRepo()
        let m = try await spawnIn(d, p, "M", cwd: repo, shepherd: true)
        #expect(try await work(d, p, m, "paddock.create", ["name": .string("feat")]).ok)
        let s = try await spawnIn(d, p, "S", cwd: repo, shepherd: true, paddock: "feat")
        #expect(try await work(d, p, s, "work.start", ["title": .string("Loop work")]).ok)
        let w = try #require(try await d.router.work.active(terminal: s.uuid))
        #expect(try await work(d, p, s, "work.task.add", ["title": .string("A"), "check": .string("true")]).ok)
        return Pad(repo: repo, dir: repo.appendingPathComponent(".collie/paddocks/feat"), s: s, work: w.id)
    }
    /// `work.run --max 3` plus `args`; the owner's card text, then the card withdrawn (nothing runs).
    private func runCard(_ d: Daemon, _ p: Paths, _ x: Pad, _ args: [String: JSONValue] = [:]) async throws -> (Response, String) {
        var a = args; a["max"] = .number(3)
        let r = try await work(d, p, x.s, "work.run", a)
        #expect(r.ok, "\(r)")
        var text = ""
        if await waitFor(20, { await d.router.appCards.contains { $0.app == "work-loop" } }) {
            text = await d.router.appCards.first { $0.app == "work-loop" }?.call ?? ""
        }
        #expect(try await work(d, p, x.s, "work.stop").ok)
        return (r, text)
    }
    private func warning(_ r: Response) -> String? {
        if case .object(let o)? = r.result, case .string(let s)? = o["warning"] { s } else { nil }
    }

    @Test func runWithoutFileIsAsBefore() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            let (r, card) = try await runCard(d, p, x)
            #expect(warning(r) == nil, "\(r)")
            #expect(!card.contains("portão") && !card.contains("pré-check") && !card.contains("collie-work.json"), "\(card)")
        }
    }

    @Test func runTakesGateAndPrecheckFromTheFile() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try writeConfig(x.dir, withSmoke)   // untracked: the tree stays clean for the loop
            let (r, card) = try await runCard(d, p, x)
            #expect(warning(r) == nil, "\(r)")
            #expect(card.contains("portão (collie-work.json) depois de cada check: «scripts/ci/lint.sh»"), "\(card)")
            #expect(card.contains("pré-check (collie-work.json) no fim de cada turno: «swift build --build-tests»"), "\(card)")
        }
    }

    @Test func flagsWinOverTheFile() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try writeConfig(x.dir, withSmoke)
            let (_, card) = try await runCard(d, p, x, ["gate": .string("echo flag-gate"), "precheck": .string("echo flag-pre")])
            #expect(card.contains("portão depois de cada check: «echo flag-gate»"), "\(card)")
            #expect(card.contains("pré-check no fim de cada turno: «echo flag-pre»"), "\(card)")
            #expect(!card.contains("collie-work.json") && !card.contains("lint.sh"), "\(card)")
        }
    }

    @Test func invalidFileNeverStopsTheRun() async throws {
        try await withDaemon { d, p in
            let x = try await pad(d, p)
            try writeConfig(x.dir, #"{ "gate": 3 }"#)
            let (r, card) = try await runCard(d, p, x)
            let w = try #require(warning(r), "\(r)")
            #expect(!w.contains("\n") && w.contains("collie-work.json"), "\(w)")
            #expect(!card.contains("portão") && !card.contains("pré-check"), "\(card)")
        }
    }

    @Test func trustedNoticeNamesTheGateSource() {
        let tasks = [WorkTask(id: "a", title: "A", check: "true")]
        let l = WorkLoopState(max: 3, gate: "scripts/ci/lint.sh")
        let fromFile = WorkStatusText.loopTrusted(paddock: "p", tasks, l, gateFromFile: true)
        #expect(fromFile.contains("[collie] Laço iniciado") && fromFile.contains("portão (collie-work.json) «scripts/ci/lint.sh»"), "\(fromFile)")
        // a gate given as a flag: the notice as before
        #expect(WorkStatusText.loopTrusted(paddock: "p", tasks, l) == WorkStatusText.loopTrusted(paddock: "p", tasks, l, gateFromFile: false))
        #expect(!WorkStatusText.loopTrusted(paddock: "p", tasks, l).contains("collie-work.json"))
    }

    @Test func cardLimitCountsTheBuiltCheck() {
        // the card's 1500 characters see the check the area became, not the area's name
        let w = Work(title: "W", terminalId: UUID())
        let long = String(repeating: "x", count: 1400)
        #expect(CommandRouter.loopCardText(w, [WorkTask(id: "a", title: "A", check: long)], WorkLoopState(max: 3), paddock: "p") != nil)
        #expect(CommandRouter.loopCardText(w, [WorkTask(id: "a", title: "A", check: long + String(repeating: "y", count: 200))],
                                           WorkLoopState(max: 3), paddock: "p") == nil)
    }
}
