import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// F5, `work prd add`: the PRD kept immutable (O_EXCL, 0444, named by its sha256), the same hash idempotent, other
/// content only with `replace` (the previous file stays), and `--origin` bounded text shown in the summary and notes.
@Suite struct PrdStoreTests {
    private func tmp() -> URL { URL(fileURLWithPath: "/tmp/collie-prd-\(UUID().uuidString.prefix(8))") }
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theFirstPrdIsKeptImmutableWithItsHash() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (list, outcome) = try PrdStore.add("# PRD\n\nLogin por e-mail.\n", origin: "JIRA-12", replace: false, dir: dir, current: [], at: at)
        #expect(outcome == .added && list.count == 1)
        let p = try #require(list.first)
        #expect(p.sha256 == PrdStore.sha256(Data("# PRD\n\nLogin por e-mail.\n".utf8)) && p.sha256.count == 64)
        #expect(p.origin == "JIRA-12" && p.bytes == 25 && p.addedAt == at)
        let url = PrdStore.file(dir, p.sha256)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# PRD\n\nLogin por e-mail.\n")
        let perm = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perm == 0o444)
        // immutable: the file cannot be opened for writing
        #expect(open(url.path, O_WRONLY) < 0)
    }

    @Test func theSameHashAgainChangesNothing() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (first, _) = try PrdStore.add("PRD v1", origin: "A-1", replace: false, dir: dir, current: [], at: at)
        let (again, outcome) = try PrdStore.add("PRD v1", origin: "other", replace: false, dir: dir, current: first, at: at.addingTimeInterval(60))
        #expect(outcome == .same && again == first)   // the first origin stays: the record is immutable
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
    }

    @Test func otherContentNeedsReplaceAndKeepsThePrevious() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (first, _) = try PrdStore.add("PRD v1", origin: nil, replace: false, dir: dir, current: [], at: at)
        #expect(throws: ProtocolError.self) { try PrdStore.add("PRD v2", origin: nil, replace: false, dir: dir, current: first, at: at) }
        let (both, outcome) = try PrdStore.add("PRD v2", origin: "B-2", replace: true, dir: dir, current: first, at: at)
        #expect(outcome == .replaced && both.count == 2 && both[0] == first[0] && both[1].origin == "B-2")
        #expect(try String(contentsOf: PrdStore.file(dir, both[0].sha256), encoding: .utf8) == "PRD v1")
        #expect(try String(contentsOf: PrdStore.file(dir, both[1].sha256), encoding: .utf8) == "PRD v2")
    }

    @Test func aKeptFileThatChangedIsAnError() throws {
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        let (first, _) = try PrdStore.add("PRD v1", origin: nil, replace: false, dir: dir, current: [], at: at)
        let url = PrdStore.file(dir, first[0].sha256)
        chmod(url.path, 0o644); try Data("mexido".utf8).write(to: url)
        #expect(throws: ProtocolError.self) { try PrdStore.add("PRD v1", origin: nil, replace: false, dir: dir, current: first, at: at) }
    }

    @Test func theOriginIsBoundedTextWithoutControl() throws {
        #expect(PrdStore.originRefusal("https://linear.app/x/issue/ABC-1") == nil)
        #expect(PrdStore.originRefusal(String(repeating: "x", count: 200)) == nil)
        #expect(PrdStore.originRefusal(String(repeating: "x", count: 201)) != nil)
        #expect(PrdStore.originRefusal("") != nil)
        #expect(PrdStore.originRefusal("a\nb") != nil && PrdStore.originRefusal("a\u{1B}[31m") != nil && PrdStore.originRefusal("a\tb") != nil)
        let dir = tmp(); defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ProtocolError.self) { try PrdStore.add("PRD", origin: "a\u{07}", replace: false, dir: dir, current: [], at: at) }
        #expect(throws: ProtocolError.self) { try PrdStore.add("  \n", origin: nil, replace: false, dir: dir, current: [], at: at) }
        #expect(!FileManager.default.fileExists(atPath: dir.path))   // a refusal keeps nothing
    }

    @Test func theOriginShowsInTheSummaryAndTheAudit() throws {
        let p = WorkPrd(sha256: String(repeating: "ab", count: 32), origin: "JIRA-12", addedAt: at, bytes: 10)
        #expect(PrdStore.note(p, outcome: .added) == "[prd] PRD guardado: sha256 \(p.sha256), 10 bytes, origem: JIRA-12")
        var w = Work(title: "W", terminalId: UUID())
        #expect(PrdStore.line(w) == nil)
        w.prd = [p]
        #expect(PrdStore.line(w) == "PRD: sha256 abababababab · origem: JIRA-12")
        w.loop = WorkLoopState(state: .finished)
        let summary = AutoLandSummary.text(w, started: at, ended: at, stop: nil, base: nil, doctor: nil)
        #expect(summary.contains("- PRD: sha256 abababababab · origem: JIRA-12"))
        // kept in the work's state, and read back (a malformed one is nil: the work survives)
        let back = try isoDecoder.decode(Work.self, from: isoEncoder.encode(w))
        #expect(back.prd == [p])
        var o = try #require(try JSONSerialization.jsonObject(with: isoEncoder.encode(w)) as? [String: Any])
        o["prd"] = "lixo"
        #expect(try isoDecoder.decode(Work.self, from: JSONSerialization.data(withJSONObject: o)).prd == nil)
    }
}

private let isoEncoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
private let isoDecoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
