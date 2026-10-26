import Foundation
import Testing
import CollieProtocol
@testable import ColliePlugins

private let a = "https://claude.ai/artifact/aaa", b = "https://claude.ai/artifact/bbb"

@Suite struct ClaudeImportProgressTests {
    @Test func rowsFollowTheEvents() {
        var p = ClaudeImportProgress()
        p.started([a, b], nonce: "n1")
        #expect(p.items.map(\.state) == [.pending, .pending])
        // reports of another import (another terminal's, or none) are ignored
        let other = p.apply("artifact.import.failed", .object(["url": .string(a), "reason": .string("x"), "nonce": .string("n9")]))
        let bare = p.apply("artifact.added", .object(["id": .string("x"), "url": .string(a)]))
        #expect(!other && !bare && p.items[0].state == .pending)
        let r1 = p.apply("artifact.added", .object(["id": .string("x"), "url": .string(a), "nonce": .string("n1")]))
        #expect(r1)
        let r2 = p.apply("artifact.import.failed", .object(["url": .string(b), "reason": .string("sem acesso"), "nonce": .string("n1")]))
        #expect(r2)
        #expect(p.items.map(\.state) == [.imported, .failed("sem acesso")])
        let r0 = p.apply("artifact.added", .object(["id": .string("y"), "url": .null, "nonce": .string("n1")]))
        #expect(!r0)   // an add that is not ours
        let r3 = p.apply("artifact.import.failed", .object(["url": .string("https://claude.ai/artifact/zzz"), "reason": .string("x"), "nonce": .string("n1")]))
        #expect(!r3)
        p.started([b], nonce: "n2")   // again: pending again, once
        #expect(p.items.map(\.url) == [a, b] && p.items[1].state == .pending)
        #expect(p.pendingCount == 1)
    }

    @Test func listThenTickABatch() {
        var p = ClaudeImportProgress()
        let early = p.apply("artifact.import.list", .object(["nonce": .string("L1"), "items": .array([.object(["url": .string(a)])])]))
        #expect(!early && p.listed.isEmpty)   // not asked: ignored
        p.listingStarted(nonce: "L1")
        let wrong = p.apply("artifact.import.list", .object(["nonce": .string("L9"), "items": .array([.object(["url": .string(a)])])]))
        #expect(!wrong && p.listed.isEmpty)
        let items = (0..<60).map { JSONValue.object(["url": .string("https://claude.ai/artifact/a\($0)"), "title": $0 == 0 ? .string("Deck") : .null]) }
        let r4 = p.apply("artifact.import.list", .object(["by": .string("C"), "nonce": .string("L1"), "items": .array(items + [.object(["url": .string("https://evil.com")])])]))
        #expect(r4)
        #expect(p.listed.count == 60 && p.listed[0].title == "Deck" && !p.listing)
        p.ticked = Set(p.listed.map(\.url))
        #expect(p.batch.count == 50 && p.batch.first == "https://claude.ai/artifact/a0")   // at most 50 at a time, in list order
        p.listingStarted(nonce: "L2")
        let r5 = p.apply("artifact.import.failed", .object(["url": .string(""), "reason": .string("terminal ocupado"), "nonce": .string("L2")]))
        #expect(r5)
        #expect(p.listError == "terminal ocupado" && !p.listing)
    }
}

@Suite struct ArtifactDropTests {
    @Test func acceptsPagesFoldersAndZips() throws {
        let d = URL(fileURLWithPath: "/tmp/collie-drop-\(UUID().uuidString.prefix(8))"); defer { try? FileManager.default.removeItem(at: d) }
        try FileManager.default.createDirectory(at: d.appendingPathComponent("site"), withIntermediateDirectories: true)
        for f in ["a.html", "b.HTM", "c.zip", "notes.txt"] { try Data().write(to: d.appendingPathComponent(f)) }
        try FileManager.default.createSymbolicLink(at: d.appendingPathComponent("link"), withDestinationURL: d.appendingPathComponent("site"))
        let urls = ["a.html", "b.HTM", "c.zip", "site", "notes.txt", "link", "gone.html"].map { d.appendingPathComponent($0) } + [URL(string: "https://x.com/a.html")!]
        let (ok, refused) = ArtifactDrop.check(urls)
        #expect(ok.map(\.lastPathComponent) == ["a.html", "b.HTM", "c.zip", "site"])
        #expect(refused.count == 4 && refused[0].contains("notes.txt"), "\(refused)")
    }
}

private actor Calls {
    var log: [(String, [String: JSONValue])] = []
    func handle(_ c: String, _ a: [String: JSONValue]) throws(ProtocolError) -> JSONValue {
        log.append((c, a))
        switch c {
        case "artifact.import-terminals": return .array([.object(["id": .string("t1"), "name": .string("C"), "running": .bool(true), "default": .bool(true)])])
        case "artifact.list", "artifact.folders": return .array([])
        case "artifact.import-claude": return .object(["nonce": .string("n1"), "terminal": .string("C")])
        default: return .object([:])
        }
    }
    func args(_ c: String) -> [[String: JSONValue]] { log.filter { $0.0 == c }.map(\.1) }
}

@MainActor @Suite struct ClaudeImportModelTests {
    @Test func sendsTheImportAndAddsDrops() async throws {
        let calls = Calls()
        let m = ArtifactsModel(call: { c, a throws(ProtocolError) in try await calls.handle(c, a) })
        await m.loadTerminals()
        #expect(m.terminals.map(\.name) == ["C"] && m.terminals[0].default)
        #expect(await m.importClaude([a, b], folder: "Cliente", terminal: "t1"))
        #expect(await calls.args("artifact.import-claude") == [["urls": .string("\(a) \(b)"), "folder": .string("Cliente"), "terminal": .string("t1")]])
        #expect(m.claude.items.map(\.url) == [a, b])
        await m.handleEvent("artifact.added", .object(["id": .string("x"), "url": .string(a), "nonce": .string("n1")]))
        #expect(m.claude.items[0].state == .imported)

        let d = URL(fileURLWithPath: "/tmp/collie-mdrop-\(UUID().uuidString.prefix(8))"); defer { try? FileManager.default.removeItem(at: d) }
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Data().write(to: d.appendingPathComponent("p.html")); try Data().write(to: d.appendingPathComponent("x.txt"))
        await m.drop([d.appendingPathComponent("p.html"), d.appendingPathComponent("x.txt")], into: "Cliente")
        #expect(await calls.args("artifact.add") == [["path": .string(d.appendingPathComponent("p.html").path), "folder": .string("Cliente")]])
        #expect(m.error?.contains("x.txt") == true)
    }
}
