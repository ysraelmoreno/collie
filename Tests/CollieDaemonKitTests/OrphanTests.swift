import Testing
import Foundation
import Darwin
import CollieCore
import CollieProtocol
import CollieTerminal
@testable import CollieDaemonKit

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue]) async throws -> Response {
    try await send(p, Request(id: "x", token: d.adminToken, command: cmd, args: args))
}
private func pidfile(_ p: Paths, _ id: String) -> String { p.runDir.appendingPathComponent("terminals/\(id).pid").path }

@Suite struct OrphanTests {
    @Test func pidfileRemovedOnNormalExit() async throws {
        try await withDaemon { d, p in
            let a = try await spawn(d, p, "A", preset: "custom", command: "sleep 300")
            #expect(FileManager.default.fileExists(atPath: pidfile(p, a.id)))
            await d.process(UUID(uuidString: a.id)!)?.terminate()
            #expect(await waitFor(5) { !FileManager.default.fileExists(atPath: pidfile(p, a.id)) })
        }
    }

    @Test func restartRelaunchesStoppedRecordKeepingCords() async throws {
        try await withDaemon { d, p in
            let a = try await spawn(d, p, "A"), b = try await spawn(d, p, "B", preset: "custom", command: "exec sleep 300")
            #expect(try await admin(d, p, "admin.connect", ["a": .string("A"), "b": .string("B")]).ok)
            let live = try await admin(d, p, "admin.restart", ["name": .string("B")])
            #expect(live.error?.code == .invalidArgs, "\(live)")
            #expect(try await admin(d, p, "admin.restart", ["name": .string("nope")]).error?.code == .notFound)
            await d.process(UUID(uuidString: b.id)!)?.terminate()
            #expect(await waitFor(5) { await d.process(UUID(uuidString: b.id)!)?.isRunning == false })
            let r = try await admin(d, p, "admin.restart", ["name": .string("B")])
            guard case .object(let o)? = r.result else { Issue.record("\(r)"); return }
            #expect(o["id"] == .string(b.id) && o["name"] == .string("B"))
            #expect(await d.process(UUID(uuidString: b.id)!)?.isRunning == true)
            let tok = try await tokenOf(d, a.id)
            let l = try await send(p, Request(id: "l", terminalId: a.id, token: tok, command: "list"))
            guard case .array(let rows)? = l.result, case .object(let row)? = rows.first else { Issue.record("\(l)"); return }
            #expect(rows.count == 1 && row["name"] == .string("B") && row["running"] == .bool(true))
        }
    }

    @Test func disconnectIsIdempotent() async throws {
        try await withDaemon { d, p in
            let a = try await spawn(d, p, "A"); _ = try await spawn(d, p, "B")
            let tok = try await tokenOf(d, a.id)
            func rows() async throws -> [JSONValue] {
                let l = try await send(p, Request(id: "l", terminalId: a.id, token: tok, command: "list"))
                guard case .array(let r)? = l.result else { throw ProtocolError(code: .internal, message: "\(l)") }
                return r
            }
            let ev = try await StreamClient.open(Request(id: "e", token: d.adminToken, command: "ui.events"), path: p.socket)
            defer { ev.close() }
            let ab: [String: JSONValue] = ["a": .string("A"), "b": .string("b")]
            #expect(try await admin(d, p, "admin.connect", ab).ok)
            #expect(try await rows().count == 1)
            #expect(try await admin(d, p, "admin.disconnect", ab).ok)
            #expect(try await rows().isEmpty)
            #expect(try await admin(d, p, "admin.disconnect", ab).ok)
            #expect(try await admin(d, p, "admin.disconnect", ["a": .string("A"), "b": .string("zz")]).error?.code == .notFound)
            // sentinel: once C's .spawned arrives, every earlier event has been seen
            let c = try await spawn(d, p, "C")
            var disconnected = 0
            while true {
                guard case .event(let e)? = try await ev.next(timeoutSeconds: 30) else { Issue.record("no sentinel"); break }
                if case .disconnected = e { disconnected += 1 }
                if case .spawned(let r) = e, r.id.uuidString == c.id { break }
            }
            #expect(disconnected == 1)
        }
    }

    /// The "reused" pid is a live process in its own session; a regressed guard would SIGHUP its group, not ours.
    @Test func reaperIgnoresReusedPid() throws {
        let run = URL(fileURLWithPath: "/tmp/collie-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: run) }
        let child = try PTYProcess(spec: LaunchSpec(executable: "/bin/sleep", arguments: ["300"], cwd: "/tmp"),
                                   scrollback: ScrollbackBuffer(memoryCapBytes: 1024, spillURL: run.appendingPathComponent("s.log")))
        defer { kill(-child.pid, SIGKILL); kill(child.pid, SIGKILL) }
        let id = UUID()
        try OrphanReaper.record(pid: child.pid, terminal: id, in: run)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)],
                                              ofItemAtPath: run.appendingPathComponent("terminals/\(id.uuidString).pid").path)
        #expect(OrphanReaper.reapAll(in: run) == 0)
        #expect(child.isRunning && kill(child.pid, 0) == 0)
    }
}
