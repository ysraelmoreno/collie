import Testing
import Foundation
import Synchronization
import CollieCore
import CollieProtocol
import CollieClient
@testable import CollieDaemonKit

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
private let deckFixture = fixtures.appendingPathComponent("deck-export")

/// The app's deck exporter, faked: `deck.snapshot` copies the fixture to `<id>/.export/`, `deck.pdf` writes a tiny PDF.
private final class FakeApp: Sendable {
    let calls = Mutex<[String]>([])
    let noSlides = Mutex(false)
    func start(_ d: Daemon, _ p: Paths) async throws -> HostConnection {
        let root = p.root.appendingPathComponent("artifacts")
        let h = HostConnection(paths: p, token: { d.adminToken }) { [self] _, command, args, _ throws(ProtocolError) in
            guard command == "deck.snapshot" || command == "deck.pdf" else { return .object([:]) }
            calls.withLock { $0.append(command) }
            if noSlides.withLock({ $0 }) { throw ProtocolError(code: .invalidArgs, message: "page has no slides") }
            guard case .string(let id)? = args["id"] else { throw ProtocolError(code: .invalidArgs, message: "no id") }
            let out = root.appendingPathComponent("\(id)/.export")
            do {
                try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                if command == "deck.pdf" {
                    try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: out.appendingPathComponent("deck-app.pdf"))
                    return .object(["file": .string(".export/deck-app.pdf"), "slides": .number(2)])
                }
                for f in ["slides.json", "img-1.png"] {
                    try? FileManager.default.removeItem(at: out.appendingPathComponent(f))
                    try FileManager.default.copyItem(at: deckFixture.appendingPathComponent(f), to: out.appendingPathComponent(f))
                }
            } catch { throw ProtocolError(code: .internal, message: "\(error)") }
            return .object(["file": .string(".export/slides.json"), "slides": .number(2), "blocked": .number(2), "truncated": .bool(false)])
        }
        h.start()
        let up = await waitFor(10) {
            do throws(ProtocolError) { _ = try await d.router.host.callApp(command: "ping", args: [:], timeout: .seconds(2)); return true }
            catch { return false }
        }
        #expect(up, "the fake app never connected")
        return h
    }
}

private struct Term { var id: String; var token: String }
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:], cwd: String? = nil) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }, cwd: cwd),
                                    to: p.socket, timeoutSeconds: 120)
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:], cwd: String? = nil) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }, cwd: cwd),
                                    to: p.socket, timeoutSeconds: 120)
}
private func term(_ d: Daemon, _ p: Paths, cwd: String) async throws -> Term {
    let args: [String: JSONValue] = ["name": .string("M"), "preset": .string("shell"), "cwd": .string(cwd)]
    let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn", args: args), to: p.socket, timeoutSeconds: 60)
    guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
    return Term(id: id, token: try await tokenOf(d, id))
}
/// A fresh scratch dir (a terminal's project), removed by the caller.
private func scratch() throws -> URL {
    let u = URL(fileURLWithPath: "/tmp/collie-exp-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
private func agentPage(_ d: Daemon) async throws -> String {
    let a = try await d.router.artifacts.addAgent(page: Data("<div class=slide>Hi</div>".utf8), title: "Deck", paddockId: nil, by: "test")
    return a.id.uuidString.lowercased()
}
private func obj(_ r: Response) -> [String: JSONValue] { if case .object(let o)? = r.result { o } else { [:] } }
private func unzipList(_ path: String) throws -> [String] {
    let pr = Process(), out = Pipe()
    pr.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    pr.arguments = ["-Z1", path]
    pr.standardOutput = out
    pr.standardError = FileHandle.nullDevice
    try pr.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    pr.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
}

/// `artifact.export` (named apart from ArtifactTests' design `ArtifactExportTests`).
@Suite(.serialized) struct DeckExportTests {
    @Test func exportsPptxFromSnapshot() async throws {
        try await withDaemon { d, p in
            let app = FakeApp(), h = try await app.start(d, p); defer { h.stop() }
            let proj = try scratch(); defer { try? FileManager.default.removeItem(at: proj) }
            try Data("<div class=slide>Hi</div>".utf8).write(to: proj.appendingPathComponent("deck.html"))
            let m = try await term(d, p, cwd: proj.path)
            let added = try await call(p, m, "artifact.add", ["path": "deck.html"], cwd: proj.path)
            guard case .string(let id)? = obj(added)["id"] else { Issue.record("\(added)"); return }
            let r = try await call(p, m, "artifact.export", ["id": id, "format": "pptx"], cwd: proj.path)
            let o = obj(r)
            #expect(r.ok && o["slides"] == .number(2) && o["format"] == .string("pptx"), "\(r)")
            let dir = p.root.appendingPathComponent("artifacts/\(id)/.export")
            #expect(o["path"] == .string(dir.appendingPathComponent("deck.pptx").path), "\(r)")
            guard case .string(let path)? = o["path"] else { return }
            #expect(try unzipList(path).contains("ppt/slides/slide2.xml"))
            // the snapshot is gone, only the deck is left
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["deck.pptx"])
        }
    }

    @Test func exportsPdf() async throws {
        try await withDaemon { d, p in
            let app = FakeApp(), h = try await app.start(d, p); defer { h.stop() }
            let id = try await agentPage(d)
            let r = try await admin(d, p, "artifact.export", ["id": id, "format": "pdf"])
            let dir = p.root.appendingPathComponent("artifacts/\(id)/.export")
            #expect(obj(r)["path"] == .string(dir.appendingPathComponent("deck.pdf").path) && obj(r)["slides"] == .number(2), "\(r)")
            #expect(FileManager.default.contents(atPath: dir.appendingPathComponent("deck.pdf").path) == Data("%PDF-1.4\n%%EOF\n".utf8))
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("deck-app.pdf").path))
        }
    }

    @Test func rejectsDesignExport() async throws {
        try await withDaemon { d, p in
            let (a, _) = try await d.router.artifacts.newVersion(fileId: "f1", node: "1:2", page: nil, title: "S", paddockId: nil, by: "test")
            try await d.router.artifacts.commit(a)
            let r = try await admin(d, p, "artifact.export", ["id": a.id.uuidString.lowercased(), "format": "pptx"])
            #expect(r.error?.code == .invalidArgs && r.error?.message == "design exports have no slides", "\(r)")
        }
    }

    @Test func rejectsBadFormat() async throws {
        try await withDaemon { d, p in
            let id = try await agentPage(d)
            let r = try await admin(d, p, "artifact.export", ["id": id, "format": "key"])
            #expect(r.error?.code == .invalidArgs && r.error?.message == "format must be pptx|pdf", "\(r)")
        }
    }

    @Test func outCopiesAndReplaces() async throws {
        try await withDaemon { d, p in
            let app = FakeApp(), h = try await app.start(d, p); defer { h.stop() }
            let proj = try scratch(); defer { try? FileManager.default.removeItem(at: proj) }
            let m = try await term(d, p, cwd: proj.path)
            let id = try await agentPage(d)
            try FileManager.default.createDirectory(at: proj.appendingPathComponent("out"), withIntermediateDirectories: true)
            try Data("old".utf8).write(to: proj.appendingPathComponent("out/x.pdf"))
            let r = try await call(p, m, "artifact.export", ["id": id, "format": "pdf", "out": "out/x.pdf"], cwd: proj.path)
            let real = String(cString: realpath(proj.path, nil)) + "/out/x.pdf"
            #expect(r.ok && obj(r)["path"] == .string(real), "\(r)")
            #expect(FileManager.default.contents(atPath: real) == Data("%PDF-1.4\n%%EOF\n".utf8))
            // a directory is not a file name
            let dirOut = try await call(p, m, "artifact.export", ["id": id, "format": "pdf", "out": "out"], cwd: proj.path)
            #expect(dirOut.error?.code == .invalidArgs, "\(dirOut)")
        }
    }

    @Test func terminalOutOutsideProjectIsRefused() async throws {
        try await withDaemon { d, p in
            let app = FakeApp(), h = try await app.start(d, p); defer { h.stop() }
            let proj = try scratch(), outside = try scratch()
            defer { try? FileManager.default.removeItem(at: proj); try? FileManager.default.removeItem(at: outside) }
            let m = try await term(d, p, cwd: proj.path)
            let id = try await agentPage(d)
            let up = try await call(p, m, "artifact.export", ["id": id, "format": "pdf", "out": "../x.pdf"], cwd: proj.path)
            #expect(up.error?.code == .unauthorized && up.error?.message.contains("use collie access request") == true, "\(up)")
            let abs = try await call(p, m, "artifact.export", ["id": id, "format": "pdf", "out": outside.appendingPathComponent("x.pdf").path], cwd: proj.path)
            #expect(abs.error?.code == .unauthorized, "\(abs)")
            // a link in the project to a folder outside it
            try FileManager.default.createSymbolicLink(at: proj.appendingPathComponent("link"), withDestinationURL: outside)
            let viaLink = try await call(p, m, "artifact.export", ["id": id, "format": "pdf", "out": "link/x.pdf"], cwd: proj.path)
            #expect(viaLink.error?.code == .unauthorized, "\(viaLink)")
            // a file link in the project to a file outside: the link itself is replaced, the target untouched
            try Data("keep".utf8).write(to: outside.appendingPathComponent("t.pdf"))
            try FileManager.default.createSymbolicLink(at: proj.appendingPathComponent("f.pdf"), withDestinationURL: outside.appendingPathComponent("t.pdf"))
            let fileLink = try await call(p, m, "artifact.export", ["id": id, "format": "pdf", "out": "f.pdf"], cwd: proj.path)
            #expect(fileLink.ok, "\(fileLink)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["t.pdf"])
            #expect(FileManager.default.contents(atPath: outside.appendingPathComponent("t.pdf").path) == Data("keep".utf8))
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: proj.appendingPathComponent("f.pdf").path)) == nil)
        }
    }

    @Test func adminMayWriteAnywhere() async throws {
        try await withDaemon { d, p in
            let app = FakeApp(), h = try await app.start(d, p); defer { h.stop() }
            let anywhere = try scratch(); defer { try? FileManager.default.removeItem(at: anywhere) }
            let id = try await agentPage(d)
            let dst = anywhere.appendingPathComponent("deck.pdf").path
            let r = try await admin(d, p, "artifact.export", ["id": id, "format": "pdf", "out": dst])
            #expect(r.ok, "\(r)")
            #expect(FileManager.default.contents(atPath: dst) == Data("%PDF-1.4\n%%EOF\n".utf8))
        }
    }

    @Test func noSlidesFromAppIsInvalidArgs() async throws {
        try await withDaemon { d, p in
            let app = FakeApp(), h = try await app.start(d, p); defer { h.stop() }
            app.noSlides.withLock { $0 = true }
            let id = try await agentPage(d)
            let r = try await admin(d, p, "artifact.export", ["id": id, "format": "pptx"])
            #expect(r.error?.code == .invalidArgs && r.error?.message == "page has no slides", "\(r)")
        }
    }

    @Test func blockedUrlsBecomeWarningsWithoutQuery() async throws {
        try await withDaemon { d, p in
            let app = FakeApp(), h = try await app.start(d, p); defer { h.stop() }
            let id = try await agentPage(d)
            let r = try await admin(d, p, "artifact.export", ["id": id, "format": "pptx"])
            guard case .array(let w)? = obj(r)["warnings"] else { Issue.record("\(r)"); return }
            #expect(w.contains(.string("blocked: https://example.com/remote.png")), "\(w)")
            #expect(w.contains(.string("blocked: https://fonts.googleapis.com/css2")), "\(w)")
            #expect(!w.contains { "\($0)".contains("s3cret") }, "\(w)")
        }
    }
}
