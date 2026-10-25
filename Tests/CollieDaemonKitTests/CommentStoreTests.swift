import Testing
import Foundation
import CollieProtocol
@testable import CollieDaemonKit

private func tempDir() -> URL {
    URL(fileURLWithPath: "/tmp/collie-cm-\(UUID().uuidString.prefix(8))").appendingPathComponent("comments")
}
private func mode(_ path: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int) ?? -1 }
private func code(_ f: () async throws -> Void) async -> ErrorCode? {
    do { try await f(); return nil } catch let e as ProtocolError { return e.code } catch { return .internal }
}
private let anchor = CommentAnchor(selector: "h1", x: 0.5, y: 0.1, text: "Título")

@Suite struct CommentStoreTests {
    @Test func addPersistsAndReloads() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let page = PageRef.artifact(UUID()), to = UUID()
        let c = try await CommentStore(dir: dir).add(page: page, title: "Doc", anchor: anchor, body: "deixe maior", to: to, toName: "A")
        let again = await CommentStore(dir: dir).comments(page)
        #expect(again == [c] && again[0].messages[0].byName == "você" && again[0].messages[0].byTerminal == nil)
        #expect(mode(dir.appendingPathComponent("\(page.key).json").path) == 0o600 && mode(dir.path) == 0o700)
    }

    @Test func pageKeyStable() throws {
        let real = URL(fileURLWithPath: "/tmp/collie-cmk-\(UUID().uuidString.prefix(8))")
        let link = URL(fileURLWithPath: real.path + "-link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { for u in [real, link] { try? FileManager.default.removeItem(at: u) } }
        let a = PageRef.project(root: real.path, path: "index.html").key, b = PageRef.project(root: link.path, path: "index.html").key
        #expect(a == b && a.hasPrefix("page-") && a.count == 5 + 16)
        #expect(a != PageRef.project(root: real.path, path: "other.html").key)
        let id = UUID()
        #expect(PageRef.artifact(id).key == "artifact-\(id.uuidString.lowercased())")
    }

    @Test func limitsEnforced() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let s = CommentStore(dir: dir), page = PageRef.artifact(UUID()), to = UUID()
        #expect(await code { _ = try await s.add(page: page, title: "T", anchor: anchor, body: String(repeating: "x", count: 2001), to: to, toName: "A") } == .invalidArgs)
        #expect(await code { _ = try await s.add(page: page, title: "T", anchor: anchor, body: "  ", to: to, toName: "A") } == .invalidArgs)
        var first: PageComment?
        for i in 0..<500 { let c = try await s.add(page: page, title: "T", anchor: anchor, body: "c\(i)", to: to, toName: "A"); first = first ?? c }
        #expect(await code { _ = try await s.add(page: page, title: "T", anchor: anchor, body: "501", to: to, toName: "A") } == .invalidArgs)
        let id = try #require(first?.id)   // 1 message already
        for i in 0..<199 { _ = try await s.message(id, body: "m\(i)") }
        #expect(await code { _ = try await s.message(id, body: "201") } == .invalidArgs)
        #expect(await code { _ = try await s.reply(id, from: to, name: "A", body: "201") } == .invalidArgs)
        let other = try await CommentStore(dir: dir).find(String(id.uuidString.prefix(8))).1
        #expect(other.messages.count == 200)
    }

    @Test func replyOnlyByAddressee() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let s = CommentStore(dir: dir), page = PageRef.artifact(UUID()), to = UUID()
        let c = try await s.add(page: page, title: "T", anchor: anchor, body: "oi", to: to, toName: "A")
        #expect(await code { _ = try await s.reply(c.id, from: UUID(), name: "B", body: "x") } == .unauthorized)
        #expect(try await s.comments(page)[0].messages.count == 1)
        let r = try await s.reply(c.id, from: to, name: "A", body: String(repeating: "y", count: 4000))
        #expect(r.messages.last?.byTerminal == to && r.messages.last?.byName == "A")
        #expect(await code { _ = try await s.reply(c.id, from: to, name: "A", body: String(repeating: "y", count: 4001)) } == .invalidArgs)
    }

    @Test func pendingIsUserMessagesNotDelivered() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let s = CommentStore(dir: dir), page = PageRef.artifact(UUID()), to = UUID()
        let a = try await s.add(page: page, title: "T", anchor: anchor, body: "um", to: to, toName: "A")
        _ = try await s.reply(a.id, from: to, name: "A", body: "feito")
        let b = try await s.add(page: page, title: "T", anchor: anchor, body: "dois", to: to, toName: "A")
        _ = try await s.add(page: page, title: "T", anchor: anchor, body: "outro", to: UUID(), toName: "B")
        let r = try await s.add(page: page, title: "T", anchor: anchor, body: "resolvido", to: to, toName: "A")
        _ = try await s.setResolved(r.id, true)
        #expect(try await s.pending(for: to).map(\.message.body) == ["dois", "um"])
        _ = try await s.setResolved(r.id, false)
        #expect(try await s.pending(for: to).map(\.comment.id) == [r.id, b.id, a.id])
    }

    @Test func markDeliveredSurvivesReload() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let s = CommentStore(dir: dir), page = PageRef.artifact(UUID()), to = UUID()
        _ = try await s.add(page: page, title: "T", anchor: anchor, body: "um", to: to, toName: "A")
        _ = try await s.add(page: page, title: "T", anchor: anchor, body: "dois", to: to, toName: "A")
        let p = await s.pending(for: to)
        try await s.markDelivered([(p[0].comment.id, p[0].message.id)])
        #expect(try await CommentStore(dir: dir).pending(for: to).map(\.message.body) == ["um"])
    }

    @Test func findByPrefix() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let s = CommentStore(dir: dir), page = PageRef.artifact(UUID())
        let c = try await s.add(page: page, title: "T", anchor: anchor, body: "um", to: nil, toName: nil)
        #expect(try await s.find(c.short).1.id == c.id)
        #expect(try await CommentStore(dir: dir).find(c.id.uuidString).0 == page)   // index rebuilt from the dir
        #expect(await code { _ = try await s.find("00000000") } == .notFound)
        // two ids sharing the first 8 hex: written by hand, as a fresh store finds them on disk
        let base = c.id.uuidString.lowercased()
        var twin = c; twin.id = UUID(uuidString: String(base.prefix(8)) + "-0000-4000-8000-000000000000")!
        let file = CommentStore.PageFile(page: .artifact(UUID()), title: "U", comments: [twin])
        try JSONEncoder().encode(file).write(to: dir.appendingPathComponent("\(file.page.key).json"))
        let fresh = CommentStore(dir: dir)
        #expect(await code { _ = try await fresh.find(c.short) } == .invalidArgs)
        #expect(try await fresh.find(base).1.id == c.id)
    }

    @Test func pageKeyIgnoresCaseOnCaseInsensitiveVolume() throws {
        let real = URL(fileURLWithPath: "/tmp/collie-cmc-\(UUID().uuidString.prefix(8).lowercased())")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        try Data("x".utf8).write(to: real.appendingPathComponent("index.html"))
        let upper = real.path.uppercased()
        guard FileManager.default.fileExists(atPath: upper) else { return }   // a case-sensitive volume: different pages
        #expect(PageRef.project(root: upper, path: "INDEX.html").key == PageRef.project(root: real.path, path: "index.html").key)
    }

    @Test func followUpReopensResolved() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let s = CommentStore(dir: dir), to = UUID()
        let c = try await s.add(page: .artifact(UUID()), title: "T", anchor: anchor, body: "um", to: to, toName: "A")
        _ = try await s.setResolved(c.id, true)
        #expect(try await s.message(c.id, body: "de novo").resolved == false)
        #expect(await s.pending(for: to).map(\.message.body) == ["de novo", "um"])
    }

    /// Two prompts at once never get the same comment.
    @Test func concurrentInjectDeliversOnce() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let s = CommentStore(dir: dir), to = UUID()
        _ = try await s.add(page: .artifact(UUID()), title: "T", anchor: anchor, body: "uma vez", to: to, toName: "A")
        async let x = s.inject(to: to, limit: 2048)
        async let y = s.inject(to: to, limit: 2048)
        let both = await [x, y]
        #expect(both.filter { $0.contains("uma vez") }.count == 1, "\(both)")
    }

    @Test func anchorClamped() {
        let a = CommentAnchor(selector: nil, x: 1.7, y: -2, text: String(repeating: "é", count: 100))
        #expect(a.x == 1 && a.y == 0 && a.text?.count == 80)
        #expect(CommentAnchor(selector: nil, x: .nan, y: 0.25, text: nil).x == 0)
    }
}
