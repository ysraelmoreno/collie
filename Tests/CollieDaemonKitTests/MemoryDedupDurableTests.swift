import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// ma1 (docs/superpowers/specs/memory-a/ma1.md): what a session got is not injected again, across a daemon restart, a
/// session start and a lot change (3a); the automatic injection does not count as a read (3e).
@Suite(.serialized) struct MemoryDedupDurableTests {
    private let t = UUID(), prompt = "postgres pool sizing"

    private func rec() -> MemoryRecord {
        MemoryRecord(kind: .decision, subject: "db", title: "Use Postgres pool", body: "postgres pool sizing")
    }
    /// A service over a fresh repo holding `r`, with `t`'s session "s1"; `root` is where its stores and lifecycle live.
    private func setup(_ r: MemoryRecord) async throws -> (mem: MemoryService, repo: URL, root: URL) {
        let repo = try await makeRepo(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mem = MemoryService(globalDir: root.appendingPathComponent("memory"))
        _ = try await mem.repo(for: repo.path).run { try $0.store.save(r) }
        await mem.noteSession(t, transcript: "/x/s1.jsonl")
        return (mem, repo, root)
    }
    private func injects(_ mem: MemoryService, _ repo: URL, _ r: MemoryRecord, terminal: UUID? = nil, lot: UUID? = nil) async -> Bool {
        await mem.relevant(for: terminal ?? t, cwd: repo.path, lot: lot, prompt: prompt).contains(r.title)
    }

    @Test func daemonRestartKeepsWhatTheSessionGot() async throws {
        let r = rec()
        let (mem, repo, root) = try await setup(r)
        #expect(await injects(mem, repo, r))
        let again = MemoryService(globalDir: root.appendingPathComponent("memory"))   // a new daemon, same files
        await again.noteSession(t, transcript: "/x/s1.jsonl")
        #expect(await !injects(again, repo, r))
        _ = await again.context(for: t, cwd: repo.path, source: "startup")
        #expect(await !injects(again, repo, r))
    }

    @Test(arguments: ["startup", "resume", "clear"]) func sessionStartKeepsWhatTheSessionGot(_ source: String) async throws {
        let r = rec()
        let (mem, repo, _) = try await setup(r)
        #expect(await injects(mem, repo, r))
        _ = await mem.context(for: t, cwd: repo.path, source: source)
        #expect(await !injects(mem, repo, r))
    }

    @Test func lotChangeKeepsWhatTheSessionGot() async throws {
        let r = rec()
        let (mem, repo, _) = try await setup(r)
        #expect(await injects(mem, repo, r))
        #expect(await !injects(mem, repo, r, lot: UUID()))
        #expect(await !injects(mem, repo, r))
    }

    @Test func compactReinjectsEachIdOnce() async throws {
        let r = rec()
        let (mem, repo, _) = try await setup(r)
        #expect(await injects(mem, repo, r))
        _ = await mem.context(for: t, cwd: repo.path, source: "compact")
        #expect(await injects(mem, repo, r))    // the context was emptied: once more
        #expect(await !injects(mem, repo, r))
        _ = await mem.context(for: t, cwd: repo.path, source: "compact")
        #expect(await !injects(mem, repo, r))   // a second compact: not again
    }

    @Test func dedupIsPerSession() async throws {
        let r = rec(), other = UUID()
        let (mem, repo, _) = try await setup(r)
        #expect(await injects(mem, repo, r))
        await mem.noteSession(other, transcript: "/x/s2.jsonl")
        #expect(await injects(mem, repo, r, terminal: other))
        await mem.noteSession(t, transcript: "/x/s3.jsonl")   // a new session in the same terminal
        #expect(await injects(mem, repo, r))
    }

    @Test func automaticInjectionIsNoRead() async throws {
        let r = rec()
        let (mem, repo, _) = try await setup(r)
        #expect(await injects(mem, repo, r))
        let reads = try await mem.repo(for: repo.path).run { $0.index()?.stats(r.id)?.reads ?? 0 }
        #expect(reads == 0)
    }

    @Test func getAndSearchAreReads() async throws {
        let repo = try await makeRepo(), r = rec()
        try await withDaemon { d, p in
            let store = await d.router.memory.repo(for: repo.path)
            _ = try await store.run { try $0.store.save(r) }
            func reads() async throws -> Int { try await store.run { $0.index()?.stats(r.id)?.reads ?? 0 } }
            func admin(_ cmd: String, _ args: [String: JSONValue]) async throws -> Response {
                try await send(p, Request(id: "x", token: d.adminToken, command: cmd, args: args.merging(["repo": .string(repo.path)]) { a, _ in a }),
                               timeoutSeconds: 60)
            }
            #expect(try await admin("memory.get", ["id": .string(r.id.uuidString)]).ok)
            #expect(try await reads() == 1)
            #expect(try await admin("memory.search", ["query": .string("postgres pool")]).ok)
            #expect(try await reads() == 2)
        }
    }
}
