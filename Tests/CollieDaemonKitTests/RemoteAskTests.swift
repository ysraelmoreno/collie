import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Remote API slice 8 (spec §3.6, §3.6b, §3.6c): agent.ask, work.status, work.rerail and mac.reveal from a phone.
private func obj(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { o } else { [:] } }
private func str(_ v: JSONValue?) -> String { if case .string(let s)? = v { s } else { "" } }
private func arr(_ v: JSONValue?) -> [JSONValue] { if case .array(let a)? = v { a } else { [] } }
private let agent = "sh '" + URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/fake-agent.sh").path + "'"

/// The next pushed event `t` (passing `match`), skipping others.
private func event(_ ph: RemotePhone, _ t: String, timeout: Double = 20, _ match: ([String: JSONValue]) -> Bool = { _ in true }) async -> [String: JSONValue]? {
    let end = Date() + timeout
    while Date() < end, let o = await ph.next(timeout: max(0.1, end.timeIntervalSinceNow)) {
        let e = obj(o["e"])
        if o["t"] == "event", e["t"] == .string(t), match(e) { return e }
    }
    return nil
}

private func until(_ seconds: Double = 10, _ ok: () async throws -> Bool) async rethrows -> Bool {
    let end = Date() + seconds
    while Date() < end { if try await ok() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
    return false
}

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
    try await send(p, Request(id: "a", token: d.adminToken, command: cmd, args: args), timeoutSeconds: 60)
}

private func spawnAs(_ d: Daemon, _ p: Paths, _ name: String, _ command: String, sandbox: String? = nil) async throws -> String {
    var args: [String: JSONValue] = ["name": .string(name), "preset": "custom", "cwd": "/tmp", "command": .string(command)]
    if let sandbox { args["sandbox"] = .string(sandbox) }
    guard case .object(let o)? = try await admin(d, p, "admin.spawn", args).result, case .string(let id)? = o["id"] else {
        throw ProtocolError(code: .internal, message: "spawn \(name)")
    }
    return id
}

@Suite(.serialized) struct RemoteAskTests {
    @Test func askIsDeliveredThenAnswered() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true; $0.idleQuietSeconds = 1 }) { d, p in
            let (ph, _) = try await helloPhone(d, p)
            defer { ph.close() }
            #expect(try await ph.call("events.subscribe").ok)
            let id = try await spawnAs(d, p, "Agent", agent)
            #expect(try await until { await d.scrollbackText(UUID(uuidString: id)!).contains("fake-agent ready") })
            let r = obj(try await ph.call("agent.ask", ["terminal": .string(id), "text": "oi"]).result)
            let mid = str(r["messageId"])
            #expect(r["queued"] == .bool(true) && mid.count == 36, "\(r)")
            #expect(await event(ph, "askState") { $0["messageId"] == .string(mid) && $0["state"] == "delivered" } != nil)
            let reply = obj(await event(ph, "chat") { obj($0["message"])["replyTo"] == .string(mid) }?["message"])
            #expect(reply["role"] == "agent" && str(reply["text"]).contains("answer:oi") && reply["terminal"] == "Agent", "\(reply)")
            // the Mac's chat shows it came from the phone
            let mine = arr(try await ph.call("chat.history").result).map(obj).first { $0["id"] == .string(mid) }
            #expect(mine?["via"] == "P" && mine?["role"] == "user" && mine?["terminal"] == "Agent", "\(String(describing: mine))")
            let line = try String(contentsOf: p.root.appendingPathComponent("remote/audit.jsonl"), encoding: .utf8)
                .split(separator: "\n").last { $0.contains("agent.ask") } ?? ""
            #expect(line.contains(id.lowercased()) && !line.contains("oi"), "target the terminal, never the text: \(line)")
        }
    }

    @Test func askThatCannotBeTypedFails() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let (ph, _) = try await helloPhone(d, p)
            defer { ph.close() }
            #expect(try await ph.call("events.subscribe").ok)
            // never quiet (a prompt waits for a quiet moment), then gone: the prompt is never typed
            let id = try await spawnAs(d, p, "Busy", "i=0; while [ $i -lt 20 ]; do echo tick$i; i=$((i+1)); sleep 0.2; done")
            let mid = str(obj(try await ph.call("agent.ask", ["terminal": .string(id), "text": "oi"]).result)["messageId"])
            let st = await event(ph, "askState", timeout: 40) { $0["messageId"] == .string(mid) }
            #expect(st?["state"] == "failed" && !str(st?["reason"]).isEmpty, "\(String(describing: st))")
        }
    }

    @Test func refusals() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let (ph, _) = try await helloPhone(d, p)
            defer { ph.close() }
            func ask(_ id: String, _ text: String = "oi") async throws -> ErrorCode? {
                try await ph.call("agent.ask", ["terminal": .string(id), "text": .string(text)]).error?.code
            }
            let live = try await spawnAs(d, p, "Live", agent)
            #expect(try await ask(UUID().uuidString) == .notFound)
            #expect(try await ask(live, "   ") == .invalidArgs)
            #expect(try await ask(live, String(repeating: "a", count: 8001)) == .invalidArgs)
            let (shell, _) = try await spawn(d, p, "Shell")   // preset shell: a phone never types commands (D1)
            #expect(try await ask(shell) == .invalidArgs)
            let free = try await spawnAs(d, p, "Free", agent, sandbox: "free")
            #expect(try await ask(free) == .invalidArgs)
            let gone = try await spawnAs(d, p, "Gone", "true")
            #expect(try await until { (try? await ask(gone)) == .notRunning })
            let asker = try await spawnAs(d, p, "Asker", "printf 'Go? (y/n) '; read x; exec cat")
            #expect(try await until { !arr(try await ph.call("approvals.list").result).isEmpty })
            #expect(try await until { (try? await ask(asker)) == .unavailable })
        }
    }
}

@Suite(.serialized) struct RemoteStatusTests {
    @Test func statusQuestionsAreReadsFromTheRegistry() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let (ph, _) = try await helloPhone(d, p)
            defer { ph.close() }
            let id = try await spawnAs(d, p, "Dev", agent)
            #expect(try await admin(d, p, "work.start", ["terminal": "Dev", "title": "Tela de login"]).ok)
            #expect(try await admin(d, p, "work.task.add", ["terminal": "Dev", "title": "validar e-mail"]).ok)
            let before = arr(try await ph.call("chat.history").result).count
            for q in ["whereAreWe", "stuck", "running"] {
                let r = try await ph.call("work.status", ["question": .string(q)])
                #expect(r.ok && !str(obj(r.result)["text"]).isEmpty, "\(q): \(r)")
            }
            let all = str(obj(try await ph.call("work.status", ["question": "whereAreWe"]).result)["text"])
            #expect(all.contains("Tela de login"), "\(all)")
            let sum = try await ph.call("work.status", ["question": "summary", "terminal": .string(id)])
            #expect(str(obj(sum.result)["text"]).contains("Tela de login") && str(obj(sum.result)["text"]).contains("validar e-mail"), "\(sum)")
            #expect(try await ph.call("work.status", ["question": "summary"]).error?.code == .invalidArgs, "summary needs a terminal")
            #expect(try await ph.call("work.status", ["question": "tudo"]).error?.code == .invalidArgs)
            #expect(arr(try await ph.call("chat.history").result).count == before, "a read: nothing posted")
        }
    }

    @Test func rerailFromThePhone() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let (ph, _) = try await helloPhone(d, p)
            defer { ph.close() }
            let id = try await spawnAs(d, p, "Dev", "sleep 0.5; printf '\\033[?2004h'; exec cat")   // paste mode on, after the tracker hooks in
            #expect(try await ph.call("work.rerail", ["terminal": .string(id)]).error?.code == .invalidArgs, "no active work")
            #expect(try await admin(d, p, "work.start", ["terminal": "Dev", "title": "RERAIL_WORK"]).ok)
            var resp = try await ph.call("work.rerail", ["terminal": .string(id)])
            for _ in 0..<50 where resp.error?.code == .unavailable {   // until the terminal turned paste mode on
                try await Task.sleep(for: .milliseconds(200)); resp = try await ph.call("work.rerail", ["terminal": .string(id)])
            }
            let r = obj(resp.result)
            #expect(r["injected"] == .bool(true), "\(resp)")
            if case .number(let n)? = r["chars"] { #expect(n > 0) } else { Issue.record("\(r)") }
            #expect(try await until { await d.scrollbackText(UUID(uuidString: id)!).contains("RERAIL_WORK") })
        }
    }

    @Test func macRevealAsksTheApp() async throws {
        try await withDaemon(configure: { $0.remoteAllowLoopback = true }) { d, p in
            let (ph, dev) = try await helloPhone(d, p)
            defer { ph.close() }
            let id = try await spawnAs(d, p, "Dev", "sleep 60")
            let ev = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            defer { ev.close() }
            #expect(try await ph.call("mac.reveal", ["terminal": .string(id)]).ok)
            var seen: WorkspaceEvent?
            while seen == nil, case .event(let e)? = try? await ev.next(timeoutSeconds: 10) { if case .remoteReveal = e { seen = e } }
            #expect(seen == .remoteReveal(terminal: UUID(uuidString: id), artifact: nil, device: dev), "\(String(describing: seen))")
            #expect(try await ph.call("mac.reveal", ["terminal": .string(UUID().uuidString)]).error?.code == .notFound)
            #expect(try await ph.call("mac.reveal", ["artifact": .string(UUID().uuidString)]).error?.code == .notFound)
            #expect(try await ph.call("mac.reveal").error?.code == .invalidArgs)
        }
    }
}
