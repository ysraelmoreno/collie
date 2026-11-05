import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Remote API slice 4 (spec §3): the device principal, the allowlist, the read surface and its projections, the
/// scope read live on every message. A paired phone over a real pinned WebSocket.
// ponytail: the real home only names card paths (~/.claude, ~/.ssh): access.request never reads them. A FakeHome as
// sandboxHome makes every spawn fail when the tests run inside an agent's own sandbox (SandboxGrantTests too).
private final class RemoteRig {
    let paths = Paths(root: URL(fileURLWithPath: "/tmp/collie-rs-\(UUID().uuidString.prefix(8))"))
    let home = URL(fileURLWithPath: NSHomeDirectory())
    var d: Daemon!
    let proj = URL(fileURLWithPath: "/tmp")

    init() throws {
        var c = testConfig(paths)
        c.denialSource = LineFeed().source
        c.remoteAllowLoopback = true
        d = try Daemon(config: c)
    }
    func run(_ body: (RemoteRig) async throws -> Void) async throws {
        try await d.start()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        do { try await body(self) } catch { await d.stop(); throw error }
        await d.stop()
    }
    func admin(_ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
        try await send(paths, Request(id: "a", token: d.adminToken, command: cmd, args: args), timeoutSeconds: 60)
    }
    func call(_ t: (id: String, token: String), _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
        try await send(paths, Request(id: "t", terminalId: t.id, token: t.token, command: cmd, args: args, cwd: proj.path), timeoutSeconds: 60)
    }
    func spawn(_ name: String, shepherd: Bool = false) async throws -> (id: String, token: String) {
        let r = try await admin("admin.spawn", ["name": .string(name), "preset": "shell", "cwd": "/tmp", "shepherd": .bool(shepherd)])
        guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
        return (id, try await tokenOf(d, id))
    }

    /// Listener on, a device paired through the app's commands, a phone with its session open.
    func phone() async throws -> (phone: RemotePhone, id: String, token: String, pin: String) {
        guard case .object(let on)? = try await admin("admin.remote", ["action": "on", "port": 0]).result,
              case .number(let port)? = on["listeningPort"], case .string(let pin)? = on["fingerprint"] else { throw ProtocolError(code: .internal, message: "on") }
        guard case .object(let b)? = try await admin("admin.remote.pair.begin").result, case .string(let qr)? = b["qr"],
              let secret = URLComponents(string: qr)?.queryItems?.first(where: { $0.name == "s" })?.value else { throw ProtocolError(code: .internal, message: "begin") }
        let ph = try await RemotePhone.connect(port: Int(port), pin: pin)
        guard case .object(let offer)? = try await ph.call("pair", ["secret": .string(secret), "device": .object(["name": "P", "model": "M"])]).result,
              case .string(let pid)? = offer["pairingId"] else { throw ProtocolError(code: .internal, message: "pair") }
        let w = try await ph.send("pair.wait", ["pairingId": .string(pid)])
        _ = try await admin("admin.remote.pair.confirm", ["pairingId": .string(pid), "decision": "accept"])
        var res: [String: JSONValue] = [:]
        while let o = await ph.next() { if o["id"] == .string(w), case .object(let r)? = o["result"] { res = r; break } }
        guard case .string(let id)? = res["deviceId"], case .string(let token)? = res["token"] else { throw ProtocolError(code: .internal, message: "wait \(res)") }
        guard try await ph.call("session.hello", ["deviceId": .string(id), "token": .string(token)]).ok else { throw ProtocolError(code: .internal, message: "hello") }
        return (ph, id, token, pin)
    }
}

private func obj(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { o } else { [:] } }
private func arr(_ v: JSONValue?) -> [JSONValue] { if case .array(let a)? = v { a } else { [] } }
/// A string as is; anything else as JSON, slashes unescaped (paths must match as typed).
private func text(_ v: JSONValue?) -> String {
    if case .string(let s)? = v { return s }
    let e = JSONEncoder(); e.outputFormatting = .withoutEscapingSlashes
    return String(decoding: (try? e.encode(v ?? .null)) ?? Data(), as: UTF8.self)
}

@Suite(.serialized) struct RemoteSurfaceTests {
    @Test func onlyTheAllowlistAnswers() async throws {
        try await RemoteRig().run { rig in
            let (ph, _, _, _) = try await rig.phone()
            defer { ph.close() }
            let allow = Set(RemoteSurface.commands.keys)
            #expect(allow.isSuperset(of: ["workspace.snapshot", "terminal.screen", "work.list", "work.get", "work.summary",
                                          "approvals.list", "access.cards", "chat.history", "artifact.list", "artifact.get"]))
            #expect(allow.allSatisfy { !$0.hasPrefix("admin.") })
            let names = Commands.all.map(\.name).filter { !allow.contains($0) } + ["pair", "pair.wait", "session.hello", "ui.events", "ui.attach"]
            #expect(names.contains("admin.spawn") && names.contains("admin.remote.devices"))
            for n in names {
                let r = try await ph.call(n, ["terminal": "x", "id": "x"])
                #expect(r.error?.code == .invalidArgs && r.error?.message == "Unknown command '\(n)'", "\(n): \(r)")
            }
            #expect(try await ph.call("workspace.snapshot").ok)   // the socket stayed open through all of it
        }
    }

    @Test func snapshotProjectsWithoutSecrets() async throws {
        try await RemoteRig().run { rig in
            let s = try await rig.spawn("Boss", shepherd: true), w = try await rig.spawn("Worker")
            #expect(try await rig.admin("admin.leash", ["a": "Boss", "b": "Worker"]).ok)
            #expect(try await rig.admin("work.start", ["terminal": "Worker", "title": "Revisar PR 212"]).ok)
            #expect(try await rig.admin("work.task.add", ["terminal": "Worker", "title": "Rodar testes"]).ok)
            let wid = try #require(UUID(uuidString: w.id))
            await rig.d.router.raiseForTests(SandboxDenial(terminal: wid, op: "write", path: rig.home.appendingPathComponent(".claude/settings.json").path,
                                                           requested: true, reason: "config"))
            await rig.d.router.raiseForTests(SandboxDenial(terminal: wid, op: "write", path: rig.home.appendingPathComponent(".ssh/id_ed25519").path,
                                                           requested: true))
            let (ph, _, token, _) = try await rig.phone()
            defer { ph.close() }
            let r = try await ph.call("workspace.snapshot")
            #expect(r.ok, "\(r)")
            let snap = obj(r.result)
            let terms = arr(snap["terminals"]).map { obj($0) }
            let worker = try #require(terms.first { $0["name"] == "Worker" })
            #expect(worker["shepherd"] == "Boss" && worker["shepherdId"] == .string(s.id.lowercased()) && worker["isShepherd"] == .bool(false))
            #expect(obj(worker["activity"])["work"] == "Revisar PR 212" && obj(worker["activity"])["task"] == "Rodar testes")
            #expect(worker["badge"] != nil && worker["sandbox"] == "sandboxed" && worker["running"] != nil)
            #expect(terms.first { $0["name"] == "Boss" }?["shepherdId"] == .null)
            #expect(Set(worker.keys) == ["id", "name", "preset", "paddockId", "isShepherd", "shepherdId", "shepherd", "running", "badge",
                                         "badgeSince", "activity", "sandbox", "lotId"])
            #expect(arr(snap["leashes"]).count == 1)
            #expect(obj(snap["mac"])["keyFingerprint"] != nil && obj(snap["mac"])["via"] == "lan")
            let works = arr(snap["works"]).map { obj($0) }
            #expect(works.first?["title"] == "Revisar PR 212" && works.first?["terminalName"] == "Worker")
            #expect(obj(works.first?["tasks"])["open"] == .number(1))
            let cards = arr(snap["accessCards"]).map { obj($0) }
            let cfg = try #require(cards.first { text($0["path"]).contains(".claude/settings.json") })
            #expect(cfg["isAgentConfig"] == .bool(true) && cfg["terminal"] == "Worker" && text(cfg["id"]).count == 22 && cfg["reason"] == "config")
            let ssh = try #require(cards.first { text($0["path"]).contains("id_ed25519") })
            #expect(ssh["refusal"] != .null && ssh["isAgentConfig"] == .bool(false))
            // nothing secret: tokens, identity files, cwd/commands, file contents
            let all = text(r.result)
            for secret in [token, rig.d.adminToken, s.token, w.token, "identity.p12", "identity.pass", "tokenHash", "BEGIN OPENSSH",
                           rig.proj.path, rig.paths.root.path, "\"cwd\"", "\"command\""] {
                #expect(!all.contains(secret), "leaked \(secret)")
            }
            #expect(try await ph.call("access.cards").ok)
            #expect(try await ph.call("approvals.list").result == .array([]))
        }
    }

    @Test func readSurface() async throws {
        try await RemoteRig().run { rig in
            let w = try await rig.spawn("Worker")
            #expect(try await rig.admin("work.start", ["terminal": "Worker", "title": "T1"]).ok)
            let (ph, _, _, _) = try await rig.phone()
            defer { ph.close() }
            #expect(await waitFor(10) { (try? await ph.call("terminal.screen", ["terminal": .string(w.id)]))?.ok == true })
            let screen = obj(try await ph.call("terminal.screen", ["terminal": .string(w.id), "lines": 5]).result)
            #expect(screen["text"] != nil && screen["truncated"] != nil)
            #expect(try await ph.call("terminal.screen", ["terminal": .string(UUID().uuidString)]).error?.code == .notFound)
            #expect(try await ph.call("terminal.screen", ["terminal": .string(w.id), "lines": 501]).error?.code == .invalidArgs)
            let works = arr(try await ph.call("work.list").result).map { obj($0) }
            let id = try #require(works.first?["id"])
            #expect(works.first?["terminalName"] == "Worker" && works.first?["closedAt"] == .null)
            #expect(obj(try await ph.call("work.get", ["id": id]).result)["title"] == "T1")
            #expect(text(obj(try await ph.call("work.summary", ["id": id]).result)["markdown"]).contains("T1"))
            #expect(try await ph.call("work.get", ["id": .string(UUID().uuidString)]).error?.code == .notFound)
            #expect(try await ph.call("chat.history").result == .array([]))
            #expect(try await ph.call("chat.history", ["terminal": .string(w.id), "limit": 10]).ok)
            #expect(try await ph.call("artifact.list").result == .array([]))
            #expect(try await ph.call("artifact.get", ["id": .string(UUID().uuidString)]).error?.code == .notFound)
        }
    }

    /// The scope is read on every message: a change or a revoke reaches a live session at its next message.
    @Test func scopeAndRevokeApplyAtOnce() async throws {
        try await RemoteRig().run { rig in
            let (ph, id, _, _) = try await rig.phone()
            defer { ph.close() }
            let mutating = RemoteSurface.commands.filter { $0.value == .mutating }.keys.sorted()
            #expect(mutating.contains("approval.answer") && mutating.contains("access.grant"))
            for m in mutating {   // full: past the scope gate (the handlers come in slices 7-8)
                #expect(try await ph.call(m, ["id": "x"]).error?.code != .unauthorized, "\(m)")
            }
            #expect(try await rig.admin("admin.remote.devices.scope", ["id": .string(id), "scope": "read"]).ok)
            for m in mutating {
                let r = try await ph.call(m, ["id": "x"])
                #expect(r.error?.code == .unauthorized && r.error?.message.contains("leitura") == true, "\(m): \(r)")
            }
            #expect(try await ph.call("workspace.snapshot").ok)   // reads still work
            #expect(try await rig.admin("admin.remote.devices.scope", ["id": .string(id), "scope": "full"]).ok)
            #expect(try await ph.call("approval.answer", ["id": "x"]).error?.code != .unauthorized)
            // revoked from the device store alone (not through admin.remote.devices.revoke's socket close): the next
            // message finds no device and closes
            #expect(try rig.d.router.remoteDevices.revoke(UUID(uuidString: id)!))
            let r = try await ph.call("workspace.snapshot")
            #expect(r.error?.code == .unauthorized)
            #expect(await ph.closingCode() == 4001)
        }
    }
}

extension CommandRouter {
    /// A card as a sandboxed terminal's denial would raise it (the terminal counts as one whose profile was rendered):
    /// sandboxed spawns can't run inside an agent's own sandbox, where these tests also run.
    func raiseForTests(_ d: SandboxDenial) async { sandboxKnown.insert(d.terminal); await raise(d) }
}
