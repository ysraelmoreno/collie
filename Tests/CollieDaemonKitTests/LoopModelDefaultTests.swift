import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// M5.6: the daemon's `loopModel` (Preferences › Laços), what `work run` passes as `--model` when given none.
private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

private func spawnIn(_ d: Daemon, _ p: Paths, _ name: String, cwd: URL) async throws -> Term {
    let args: [String: JSONValue] = ["name": .string(name), "preset": .string("shell"), "cwd": .string(cwd.path), "shepherd": .bool(true)]
    let r = try await send(p, Request(id: "s", token: d.adminToken, command: "admin.spawn", args: args), timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}

/// `t` nil: the app (admin token).
private func call(_ d: Daemon, _ p: Paths, _ t: Term?, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "m", terminalId: t?.id, token: t?.token ?? d.adminToken, command: cmd, args: args), timeoutSeconds: 60)
}

private let claude = TerminalRecord(id: UUID(), name: "S", preset: .claude, command: nil, cwd: "/", isShepherd: true)
private let codex = TerminalRecord(id: UUID(), name: "S", preset: .codex, command: nil, cwd: "/", isShepherd: true)

@Suite struct LoopModelDefaultTests {
    @Test func noPreferenceIsTheShepherdsModelAsBefore() {
        #expect(CommandRouter.loopModel(given: nil, preference: nil, preset: nil, command: nil, shepherd: claude) == nil)
        #expect(CommandRouter.loopModel(given: nil, preference: nil, preset: "claude", command: nil, shepherd: codex) == nil)
    }

    @Test func aPreferenceIsUsedForClaudeAgents() {
        #expect(CommandRouter.loopModel(given: nil, preference: "sonnet", preset: nil, command: nil, shepherd: claude) == "sonnet")
        #expect(CommandRouter.loopModel(given: nil, preference: "sonnet", preset: "claude", command: nil, shepherd: codex) == "sonnet")
        // summon refuses --model for any other agent: the preference must never fail every attempt of such a loop
        #expect(CommandRouter.loopModel(given: nil, preference: "sonnet", preset: nil, command: nil, shepherd: codex) == nil)
        #expect(CommandRouter.loopModel(given: nil, preference: "sonnet", preset: "shell", command: nil, shepherd: claude) == nil)
    }

    @Test func anExplicitModelAlwaysWins() {
        #expect(CommandRouter.loopModel(given: "opus", preference: "sonnet", preset: nil, command: nil, shepherd: claude) == "opus")
        #expect(CommandRouter.loopModel(given: "opus", preference: nil, preset: nil, command: nil, shepherd: claude) == "opus")
    }

    @Test func onlyAModelIdIsAccepted() {
        for ok in ["sonnet", "claude-sonnet-5-5", "us.anthropic.claude-opus-5-5:0", "a_b", String(repeating: "x", count: 64)] {
            #expect(CollieSettings.isLoopModel(ok), "\(ok)")
        }
        for bad in ["", " ", "a b", "x;rm -rf", "-x", ".x", "a\nb", "opus[1m]", "a/b", "$(id)", String(repeating: "x", count: 65)] {
            #expect(!CollieSettings.isLoopModel(bad), "\(bad)")
        }
    }

    @Test func theAdminCommandReadsSetsRefusesAndClears() async throws {
        let repo = try await makeRepo()
        try await withDaemon { d, p in
            #expect(try await call(d, p, nil, "admin.loop-model").result == .object(["model": .null]))
            #expect(try await call(d, p, nil, "admin.loop-model", ["model": .string("claude-sonnet-5-5")]).result == .object(["model": .string("claude-sonnet-5-5")]))
            #expect(CollieSettings.load(p.root).loopModel == "claude-sonnet-5-5")
            let bad = try await call(d, p, nil, "admin.loop-model", ["model": .string("x; rm -rf ~")])
            #expect(bad.error?.code == .invalidArgs, "\(bad)")
            #expect(CollieSettings.load(p.root).loopModel == "claude-sonnet-5-5", "a refused value changes nothing")
            // only the app: an agent (a Shepherd too) is refused
            let s = try await spawnIn(d, p, "S", cwd: repo)
            #expect(try await call(d, p, s, "admin.loop-model", ["model": .string("opus")]).error?.code == .unauthorized)
            #expect(try await call(d, p, nil, "admin.loop-model", ["model": .string("")]).result == .object(["model": .null]))
            #expect(CollieSettings.load(p.root).loopModel == nil)
        }
    }

    @Test func workStatusShowsTheAgentsModel() async throws {
        var w = Work(title: "W", terminalId: UUID())
        w.loop = WorkLoopState(max: 3, tasks: ["a"])
        #expect(WorkStatusText.modelLine(w) == nil)
        w.loop?.model = "claude-sonnet-5-5"
        #expect(WorkStatusText.modelLine(w) == "modelo dos agentes: claude-sonnet-5-5")

        let repo = try await makeRepo()
        try await withDaemon { d, p in
            let s = try await spawnIn(d, p, "S", cwd: repo)
            #expect(try await call(d, p, s, "work.start", ["title": .string("Loop work")]).ok)
            let id = try #require(try await d.router.work.active(terminal: s.uuid)?.id)
            try await d.router.work.update(id) { $0.loop = WorkLoopState(state: .stopped, model: "claude-sonnet-5-5", max: 3, tasks: []) }
            let r = try await call(d, p, s, "work.status")
            #expect("\(String(describing: r.result))".contains("modelo dos agentes: claude-sonnet-5-5"), "\(r)")
        }
    }

    @Test func theWaitAdviceIsInTheOrientationWithinTheCapAndInTheLoopCommand() {
        // M6.5 (A6): 540 s in the background, not 3600 in the foreground (the agent's shell tool kills it at 2 to 10 min)
        #expect(CollieOrientation.loopNotify.contains("work wait --timeout 540") && CollieOrientation.loopNotify.contains("no reply"))
        #expect(LoopCommand.body.contains("one long wait beats several short ones") && LoopCommand.body.contains("read the state only when you need it"))
        let t = CollieOrientation.text(terminal: "Ana", isShepherd: true, paddock: "P", peers: ["Bob"], panels: [], agent: "codex")
        #expect(t.count <= 1500 && t.contains(CollieOrientation.loopNotify), "\(t.count)\n\(t)")
        for agent in ["claude", "cursor", "codex"] {
            for shepherd in [true, false] {
                let x = CollieOrientation.text(terminal: "Collie Main", isShepherd: shepherd, paddock: "collie", peers: ["Bob", "A very long peer name that goes on and on"],
                                               panels: [("Home", "design")], paddockPanels: [("Draft", "design")], morePanels: true, agent: agent,
                                               memoryTask: true, candidates: 3)
                #expect(x.count <= 1500, "\(agent) \(shepherd) \(x.count)")
            }
        }
    }
}
