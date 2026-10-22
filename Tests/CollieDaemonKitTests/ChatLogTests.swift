import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private func withDir(_ body: (URL) async throws -> Void) async throws {
    let dir = URL(fileURLWithPath: "/tmp/collie-chat-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir)
}
private func lines(_ url: URL) -> [String] {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}
private func msg(_ i: Int) -> ChatMessage { ChatMessage(role: .user, text: "m\(i)") }

@Suite struct ChatLogTests {
    @Test func appendAndPage() async throws {
        try await withDir { dir in
            let log = ChatLog(dir: dir)
            let ms = (0..<10).map(msg)
            for m in ms { try await log.append(m) }
            #expect(try await log.page(before: nil, limit: 3).map(\.text) == ["m9", "m8", "m7"])
            #expect(try await log.page(before: ms[7].id, limit: 3).map(\.text) == ["m6", "m5", "m4"])
            #expect(try await log.page(before: ms[2].id, limit: 50).map(\.text) == ["m1", "m0"])
            await #expect(throws: ProtocolError.self) { try await log.page(before: UUID(), limit: 5) }
            // read back from disk by a fresh log; the file is private
            #expect(try await ChatLog(dir: dir).page(before: nil, limit: 100).map(\.id) == ms.reversed().map(\.id))
            let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("work-chat.jsonl").path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
            // a long text is cut and marked
            let long = ChatMessage(role: .agent, text: String(repeating: "x", count: 9_000))
            #expect(long.text.count == ChatMessage.maxText && long.truncated)
        }
    }

    /// 1 200 is the high-water mark, 1 000 what stays: at 5 000 the file holds 1 000 + the 181 since the last roll.
    @Test func chatLogCapped() async throws {
        try await withDir { dir in
            let log = ChatLog(dir: dir)
            for i in 0..<5_000 { try await log.append(msg(i)) }
            let cur = lines(dir.appendingPathComponent("work-chat.jsonl"))
            let old = lines(dir.appendingPathComponent("work-chat-archive.jsonl"))
            #expect(cur.count >= ChatLog.keep && cur.count <= ChatLog.high)
            #expect(cur.count == 1_181 && old.count == 3_819)
            // none lost, none twice, in order
            let texts = (old + cur).compactMap { try? JSONDecoder().decode(Probe.self, from: Data($0.utf8)).text }
            #expect(texts == (0..<5_000).map { "m\($0)" })
            #expect(try await log.page(before: nil, limit: 1).first?.text == "m4999")
        }
    }

    @Test func clearArchives() async throws {
        try await withDir { dir in
            let log = ChatLog(dir: dir)
            for i in 0..<5 { try await log.append(msg(i)) }
            try await log.clear()
            #expect(try await log.page(before: nil, limit: 50).isEmpty)
            #expect(lines(dir.appendingPathComponent("work-chat.jsonl")).isEmpty)
            #expect(lines(dir.appendingPathComponent("work-chat-archive.jsonl")).count == 5)
            try await log.append(msg(5))
            try await log.clear()
            #expect(lines(dir.appendingPathComponent("work-chat-archive.jsonl")).count == 6)   // only added to
            try await ChatLog(dir: dir.appendingPathComponent("none")).clear()   // nothing to move: fine
        }
    }

    /// Paused (the backup copies `work/`): a write queued meanwhile reaches the disk only after.
    @Test func pausedHoldsWrites() async throws {
        try await withDir { dir in
            let log = ChatLog(dir: dir)
            try await log.append(msg(0))   // loaded: the next append needs no read
            let file = await log.file
            let late = try await log.withPaused { () async throws -> Task<Void, Error> in
                let t = Task { try await log.append(msg(1)) }
                // in memory, so its write is queued: still not on disk
                #expect(await waitFor(10) { (try? await log.page(before: nil, limit: 5))?.first?.text == "m1" })
                #expect(lines(file).count == 1)
                return t
            }
            try await late.value
            #expect(lines(file).count == 2)
        }
    }
}

private struct Probe: Decodable { var text: String }
