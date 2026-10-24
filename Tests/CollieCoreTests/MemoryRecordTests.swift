import Testing
import Foundation
import CollieProtocol
@testable import CollieCore

@Suite struct MemoryRecordTests {
    func full() -> MemoryRecord {
        MemoryRecord(id: UUID(), kind: .map, scope: .paddock, paddock: "auth", subject: "Auth: Flow  #1", title: "Title: with \"quotes\" # hash",
                     body: "line one\n---\nafter rule\n\nend", path: "Sources/A.swift", status: .superseded, reviewed: true, pinned: true,
                     supersedes: UUID(), supersededBy: UUID(), origin: "claude-1 (claude)",
                     createdAt: Date(timeIntervalSince1970: 1_700_000_000.123), updatedAt: Date(timeIntervalSince1970: 1_700_000_100.5))
    }

    @Test func renderParseRoundTrip() throws {
        let r = full()
        #expect(try MemoryFile.parse(MemoryFile.render(r)) == r)
        let min = MemoryRecord(kind: .decision, subject: "x", title: "plain", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(try MemoryFile.parse(MemoryFile.render(min)) == min)
        #expect(MemoryFile.render(r) == MemoryFile.render(r))
        #expect(MemoryFile.render(r).hasPrefix("---\nid: "))
    }

    @Test func hitsRoundTrip() throws {
        var r = full(); r.hits = 7
        let text = MemoryFile.render(r)
        #expect(text.contains("pinned: true\nhits: 7\n"))
        #expect(try MemoryFile.parse(text) == r)
    }

    @Test func fileWithoutHitsDecodes() throws {
        #expect(try MemoryFile.parse(MemoryFile.render(full())).hits == nil)
        #expect(throws: ProtocolError.self) { try MemoryFile.parse(MemoryFile.render(full()).replacingOccurrences(of: "pinned: true", with: "pinned: true\nhits: x")) }
    }

    /// An old record's file (no `hits`) is byte-identical after a parse and a rewrite.
    @Test func renderOmitsNilHits() throws {
        let old = MemoryFile.render(full())
        #expect(!old.contains("hits:"))
        #expect(MemoryFile.render(try MemoryFile.parse(old)) == old)
    }

    @Test func subjectIsNormalized() {
        #expect(MemoryRecord(kind: .decision, subject: "  Use   SQLite\tNow ", title: "t").subject == "use sqlite now")
    }

    @Test func fileNameIsStableAndSafe() {
        let r = MemoryRecord(id: UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!, kind: .pitfall, subject: "../x / Ç", title: "t")
        #expect(MemoryFile.fileName(r) == "pitfall/x-c-abcdef12.md")
        let long = MemoryRecord(kind: .map, subject: String(repeating: "ab ", count: 50), title: "t")
        let slug = MemoryFile.fileName(long).dropFirst("map/".count).dropLast(".md".count + 9)
        #expect(slug.count <= 48 && slug.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") })
        #expect(MemoryFile.fileName(MemoryRecord(kind: .map, subject: "///", title: "t")).hasPrefix("map/memory-"))
    }

    @Test func invalidFilesThrow() {
        let good = MemoryFile.render(full())
        #expect(throws: ProtocolError.self) { try MemoryFile.parse("no frontmatter") }
        #expect(throws: ProtocolError.self) { try MemoryFile.parse("<<<<<<< HEAD\n" + good + "=======\n>>>>>>> x\n") }
        #expect(throws: ProtocolError.self) { try MemoryFile.parse(good.replacingOccurrences(of: "kind: map", with: "kind: nope")) }
        #expect(throws: ProtocolError.self) { try MemoryFile.parse(good.replacingOccurrences(of: "id: ", with: "idx: ")) }
    }

    @Test func bodyQuotingOneMarkerRoundTrips() throws {
        let r = MemoryRecord(kind: .pitfall, subject: "git", title: "t", body: "seen:\n<<<<<<< x\nmore")
        #expect(try MemoryFile.parse(MemoryFile.render(r)) == r)
        let full = MemoryRecord(kind: .pitfall, subject: "git", title: "t", body: "<<<<<<< a\nx\n=======\ny\n>>>>>>> b")
        #expect(throws: ProtocolError.self) { try MemoryFile.parse(MemoryFile.render(full)) }
    }

    @Test func datesTruncatedToMilliseconds() throws {
        let r = MemoryRecord(kind: .map, subject: "x", title: "t", createdAt: Date(timeIntervalSince1970: 1_700_000_000.123456789))
        #expect(try MemoryFile.parse(MemoryFile.render(r)) == r)
    }

    @Test func feedbackRoundTrips() throws {
        let r = MemoryRecord(kind: .feedback, scope: .global, subject: "idioma", title: "Sempre responda em português", body: "o usuário pediu")
        #expect(try MemoryFile.parse(MemoryFile.render(r)) == r)
        #expect(MemoryFile.render(r).contains("\nkind: feedback\n"))
        #expect(MemoryFile.fileName(r).hasPrefix("feedback/"))
    }

    /// A file written before `feedback` existed still parses; the three old kinds keep their raw values.
    @Test func oldFilesDecode() throws {
        let old = "---\nid: abcdef12-0000-0000-0000-000000000000\nkind: pitfall\nscope: project\nsubject: git\ntitle: t\nstatus: active\nreviewed: false\npinned: false\norigin: app\ncreated: 2025-01-01T00:00:00Z\nupdated: 2025-01-01T00:00:00Z\n---\n\nbody\n"
        let r = try MemoryFile.parse(old)
        #expect(r.kind == .pitfall && r.body == "body")
        #expect([MemoryKind.decision, .map, .pitfall].map(\.rawValue) == ["decision", "map", "pitfall"])
    }

    @Test func aliasesRoundTrip() throws {
        let r = MemoryRecord(kind: .decision, subject: "testes", title: "Rodar só o filtro", body: "b", aliases: ["Suíte", "swift  test", "suíte"])
        #expect(r.aliases == ["suíte", "swift test"])
        let text = MemoryFile.render(r)
        #expect(text.contains("\ntitle: Rodar só o filtro\naliases: [\"suíte\",\"swift test\"]\n"), "\(text)")
        #expect(try MemoryFile.parse(text) == r)
        #expect(try MemoryFile.parse(text.replacingOccurrences(of: "aliases: [", with: "aliases: [\"x\",")).aliases == ["x", "suíte", "swift test"])
        #expect(throws: ProtocolError.self) { try MemoryFile.parse(text.replacingOccurrences(of: "aliases: [", with: "aliases: [1,")) }
        // Codable without the key (an index row or digest entry from before aliases) decodes to none
        let json = String(decoding: try JSONEncoder().encode(MemoryRecord(kind: .map, subject: "x", title: "t")), as: UTF8.self)
        #expect(!json.contains("aliases"))
        #expect(try JSONDecoder().decode(MemoryRecord.self, from: Data(json.utf8)).aliases.isEmpty)
    }

    @Test func noAliasesFileUnchanged() throws {
        let old = "---\nid: abcdef12-0000-0000-0000-000000000000\nkind: pitfall\nscope: project\nsubject: git\ntitle: t\nstatus: active\nreviewed: false\npinned: false\norigin: app\ncreated: 2025-01-01T00:00:00.000Z\nupdated: 2025-01-01T00:00:00.000Z\n---\n\nbody\n"
        #expect(MemoryFile.render(try MemoryFile.parse(old)) == old)
    }

    @Test func aliasesNormalized() {
        let raw = (0..<12).map { "a\($0)" + String(repeating: "x", count: 60) } + ["dup\"x\ny", " "]
        let n = MemoryRecord.normalizeAliases(raw)
        #expect(n.count == 8 && n.allSatisfy { $0.count <= 40 } && n[0].hasPrefix("a0x"))
        #expect(MemoryRecord.normalizeAliases(["dup\"x\ny", "", "\u{202E}z"]) == ["dupx y", "z"])
    }
}
