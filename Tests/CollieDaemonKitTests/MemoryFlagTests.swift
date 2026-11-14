import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private struct Term { var id: String; var token: String; var uuid: UUID { UUID(uuidString: id)! } }

@Suite(.serialized) struct MemoryFlagTests {
    private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
        try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args), to: p.socket, timeoutSeconds: 60)
    }
    private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: JSONValue] = [:]) async throws -> Response {
        try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args), to: p.socket, timeoutSeconds: 60)
    }
    private func obj(_ r: Response) -> [String: JSONValue] { if case .object(let o)? = r.result { return o }; return [:] }
    private func str(_ v: JSONValue?) -> String { if case .string(let x)? = v { return x }; return "" }

    /// A terminal in a fresh repo with session "s1" that was injected `n` project memories (and their ids).
    private func setup(_ d: Daemon, _ p: Paths, n: Int = 1, session: String = "s1") async throws -> (Term, [UUID], RepoMemory) {
        let repo = try await makeRepo()
        let r = try await admin(d, p, "admin.spawn", ["name": .string("T"), "preset": .string("shell"), "cwd": .string(repo.path)])
        let id = str(obj(r)["id"])
        let t = Term(id: id, token: try await tokenOf(d, id))
        var ids: [UUID] = []
        for i in 0..<n {
            let saved = try await call(p, t, "memory.save", ["kind": .string("decision"), "subject": .string("db\(i)"), "title": .string("Use Postgres \(i)"), "body": .string("pool")])
            ids.append(UUID(uuidString: str(obj(saved)["id"]))!)
        }
        let mem = d.router.memory
        await mem.noteSession(t.uuid, transcript: "/x/\(session).jsonl")
        await mem.lifecycle.noteInjected(session: session, ids: ids, now: Date())
        return (t, ids, await mem.repo(for: repo.path))
    }
    private func flag(_ p: Paths, _ t: Term, _ id: String, _ verdict: String, reason: String? = nil) async throws -> Response {
        var a: [String: JSONValue] = ["id": .string(id), verdict: .bool(true)]
        if let reason { a["reason"] = .string(reason) }
        return try await call(p, t, "memory.flag", a)
    }

    @Test func flagWrongContestsPenalizesAndQueues() async throws {
        try await withDaemon { d, p in
            let (t, ids, _) = try await setup(d, p)
            let r = try await flag(p, t, ids[0].uuidString, "wrong", reason: "stale")
            #expect(r.ok && obj(r)["contested"] == .bool(true) && obj(r)["queued"] == .bool(true), "\(r)")
            let e = await d.router.memory.lifecycle.entry(ids[0])
            #expect(e?.contestedNow == true && e?.lastContestedAt != nil && e?.flags.map(\.verdict) == [.wrong] && e?.flags.first?.reason == "stale")
            let factor = await d.router.memory.scores.factor(ids[0]), asked = await d.router.memory.verifyRequested
            #expect(factor < 1 && asked == [ids[0]])
        }
    }

    @Test func flagUsefulCountsImmediately() async throws {
        try await withDaemon { d, p in
            let (t, ids, _) = try await setup(d, p)
            let r = try await flag(p, t, ids[0].uuidString, "useful")
            #expect(r.ok && obj(r)["contested"] == .bool(false) && obj(r)["queued"] == .bool(false))
            #expect(await d.router.memory.lifecycle.entry(ids[0])?.usefulUses.map(\.session) == ["s1"])
        }
    }

    @Test func notInjectedIdIsInvalidArgs() async throws {
        try await withDaemon { d, p in
            let (t, _, _) = try await setup(d, p)
            let r = try await flag(p, t, UUID().uuidString, "wrong")
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("não foi injetada nesta sessão") == true, "\(r)")
            #expect(try await flag(p, t, "abc", "wrong").error?.code == .invalidArgs)   // under 4 characters
        }
    }

    @Test func ambiguousPrefixIsInvalidArgsAskingForMore() async throws {
        try await withDaemon { d, p in
            let (t, _, _) = try await setup(d, p)
            let a = UUID(uuidString: "abcd0000-0000-0000-0000-000000000001")!, b = UUID(uuidString: "abcd0000-0000-0000-0000-000000000002")!
            await d.router.memory.lifecycle.noteInjected(session: "s1", ids: [a, b], now: Date())
            let r = try await flag(p, t, "ABCD", "wrong")
            #expect(r.error?.code == .invalidArgs && r.error?.message.contains("mais caracteres") == true, "\(r)")
        }
    }

    @Test func twentyFirstFlagInASessionRefused() async throws {
        try await withDaemon { d, p in
            let (t, ids, _) = try await setup(d, p, n: 21)
            for i in 0..<20 { #expect(try await flag(p, t, ids[i].uuidString, "outdated").ok) }
            let r = try await flag(p, t, ids[20].uuidString, "wrong")
            #expect(r.error?.code == .invalidArgs, "\(r)")
        }
    }

    @Test func sameSessionFlagTwiceIsIdempotent() async throws {
        try await withDaemon { d, p in
            let (t, ids, _) = try await setup(d, p)
            let first = try await flag(p, t, ids[0].uuidString, "wrong")
            let second = try await flag(p, t, ids[0].uuidString, "outdated")
            #expect(first.ok && obj(first)["queued"] == .bool(true))
            #expect(second.ok && obj(second)["contested"] == .bool(true) && obj(second)["queued"] == .bool(false), "\(second)")
            #expect(await d.router.memory.lifecycle.entry(ids[0])?.flags.count == 1)
            let factor = await d.router.memory.scores.factor(ids[0])
            #expect(abs(factor - 0.7) < 0.001, "\(factor)")
        }
    }

    @Test func idInjectedOnlyInAnotherSessionIsInvalidArgs() async throws {
        try await withDaemon { d, p in
            let (t, _, _) = try await setup(d, p)
            let other = UUID()
            await d.router.memory.lifecycle.noteInjected(session: "s2", ids: [other], now: Date())
            #expect(try await flag(p, t, other.uuidString, "wrong").error?.code == .invalidArgs)
        }
    }

    @Test func flagStillAcceptedAfterDaemonRestart() async throws {
        try await withDaemon { d, p in
            let (t, ids, _) = try await setup(d, p)
            #expect(try await flag(p, t, ids[0].uuidString, "wrong").ok)
            let reopened = LifecycleStore(file: d.router.memory.lifecycle.file)
            #expect(await reopened.entry(ids[0])?.flags.count == 1)
            #expect(await reopened.injected(session: "s1") == [ids[0]])
        }
    }

    @Test func reasonScrubbedAndCapped() async throws {
        try await withDaemon { d, p in
            let (t, ids, _) = try await setup(d, p)
            let long = "Bearer abc.def-123 token=SECRETVALUE " + String(repeating: "x", count: 500)
            #expect(try await flag(p, t, ids[0].uuidString, "wrong", reason: long).ok)
            let reason = try #require(await d.router.memory.lifecycle.entry(ids[0])?.flags.first?.reason)
            #expect(reason.count == 200 && !reason.contains("SECRETVALUE") && !reason.contains("abc.def"))
        }
    }

    @Test func pinnedTargetNotPenalized() async throws {
        try await withDaemon { d, p in
            let (t, ids, store) = try await setup(d, p)
            try await store.run { m in
                var rec = try #require(m.store.all().records.first { $0.id == ids[0] }); rec.pinned = true; try m.store.write(rec)
            }
            let r = try await flag(p, t, ids[0].uuidString, "wrong")
            #expect(r.ok && obj(r)["contested"] == .bool(true) && obj(r)["queued"] == .bool(false), "\(r)")
            let e = await d.router.memory.lifecycle.entry(ids[0])
            #expect(e?.flags.count == 1 && e?.contestedNow == true)
            let factor = await d.router.memory.scores.factor(ids[0]), asked = await d.router.memory.verifyRequested
            #expect(factor == 1 && asked.isEmpty)
        }
    }

    @Test func adminAndTerminalTokensAllowed() async throws {
        try await withDaemon { d, p in
            let (t, ids, _) = try await setup(d, p)
            let a = try await admin(d, p, "memory.flag", ["id": .string(ids[0].uuidString), "wrong": .bool(true)])
            #expect(a.error?.code == .invalidArgs, "\(a)")   // authorised, but an admin has no session
            #expect(try await flag(p, t, ids[0].uuidString, "useful").ok)
        }
    }

    @Test func stopReasonMentionsFlag() {
        #expect(MemoryCapture.stopReason.contains("collie memory flag") && MemoryCapture.stopReasonNoLot.contains("collie memory flag"))
    }
}
