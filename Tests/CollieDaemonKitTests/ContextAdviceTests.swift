import Testing
import Foundation
@testable import CollieDaemonKit

/// M5.5: a Shepherd's Stop says, at most once every 2 h, that its transcript is over 20 MB, measured by `stat` only.
@Suite struct ContextAdviceTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let root = URL(fileURLWithPath: "/tmp/collie-ctx-\(UUID().uuidString.prefix(8))")
    var projects: URL { root.appendingPathComponent("projects") }

    /// A sparse `.jsonl` of `bytes` under `dir` (no content written: the size is what counts).
    func transcript(_ bytes: UInt64, in dir: URL? = nil, name: String = "s.jsonl") throws -> String {
        let d = (dir ?? projects).appendingPathComponent("p")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let f = d.appendingPathComponent(name)
        FileManager.default.createFile(atPath: f.path, contents: Data("{\"secret\":\"abc\"}\n".utf8))
        let h = try FileHandle(forWritingTo: f); try h.truncate(atOffset: bytes); try h.close()
        return f.path
    }
    func advice(_ path: String?, shepherd: Bool = true, asked: Bool = false, last: Date? = nil, now: Date? = nil) -> String? {
        ContextAdvice.advice(transcript: path, projectsDir: projects, isShepherd: shepherd, memoryAsked: asked, last: last, now: now ?? t0)
    }

    @Test func belowAndAboveThreshold() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(advice(try transcript(ContextAdvice.threshold)) == nil)
        let big = try transcript(25 << 20, name: "b.jsonl")
        #expect(advice(big) == ContextAdvice.line(megabytes: 25))
        #expect(advice(big, shepherd: false) == nil)   // only the Shepherd
    }

    @Test func onceEveryTwoHours() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let big = try transcript(30 << 20)
        #expect(advice(big, last: t0, now: t0.addingTimeInterval(60)) == nil)
        #expect(advice(big, last: t0, now: t0.addingTimeInterval(2 * 3600 - 1)) == nil)
        #expect(advice(big, last: t0, now: t0.addingTimeInterval(2 * 3600)) != nil)
    }

    @Test func neverWithTheMemoryAsk() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(advice(try transcript(30 << 20), asked: true) == nil)
    }

    @Test func refusedPathsAreSilent() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(advice(try transcript(30 << 20, in: root.appendingPathComponent("elsewhere"))) == nil)   // outside projects
        #expect(advice(nil) == nil)
        #expect(advice(projects.appendingPathComponent("p/missing.jsonl").path) == nil)
        let real = try transcript(30 << 20)
        let link = projects.appendingPathComponent("p/l.jsonl").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        #expect(advice(link) == nil)
        let fifo = projects.appendingPathComponent("p/f.jsonl").path
        #expect(mkfifo(fifo, 0o600) == 0)
        #expect(advice(fifo) == nil)   // never opened: no hang
    }

    @Test func lineIsFixedAndCarriesNoContent() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try #require(advice(try transcript(42 << 20)))
        #expect(a == "Contexto grande (42 MB): cada turno relê ~esse contexto. Considere uma sessão nova; as decisões estão na memória e nos docs.")
        #expect(!a.contains("secret") && !a.contains("\n"))
        #expect(ContextAdvice.line(megabytes: 999).count - ContextAdvice.line(megabytes: 20).count == 1)
    }

    @Test func systemMessageNeverBlocks() throws {
        let o = try #require(MemoryHookClient.systemMessage("x").flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] })
        #expect(o == ["systemMessage": "x"])
    }
}
