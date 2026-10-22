import Testing
import Foundation
import OrqProtocol
@testable import OrqCore

@Suite struct MemoryRecordTests {
    func full() -> MemoryRecord {
        MemoryRecord(id: UUID(), kind: .map, scope: .floor, floor: "auth", subject: "Auth: Flow  #1", title: "Title: with \"quotes\" # hash",
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
}
