import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

@Suite struct ArtifactTests {
    private func tmp() -> URL { URL(fileURLWithPath: "/tmp/collie-art-\(UUID().uuidString.prefix(8))") }

    @Test func versionsReservedThenCommitted() async throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let s = ArtifactStore(root: root)
        async let x = s.newVersion(fileId: "f", node: "2", page: nil, title: "T", paddockId: nil, by: "M")
        async let y = s.newVersion(fileId: "f", node: "2", page: nil, title: "T", paddockId: nil, by: "M")
        let (a, b) = try await (x, y)
        #expect(a.0.id == b.0.id && Set([a.0.version, b.0.version]) == [1, 2])
        #expect(FileManager.default.fileExists(atPath: a.1.path) && a.1.lastPathComponent == "v\(a.0.version)")
        #expect(try await s.list().isEmpty)   // nothing committed yet: the folders are ignored
        let (hi, lo) = a.0.version == 2 ? (a.0, b.0) : (b.0, a.0)
        try await s.commit(hi); try await s.commit(lo)   // a late commit of an older version keeps the newer record
        #expect(try await s.get(hi.id).version == 2)
        // another (file, node): another artifact
        #expect(try await s.newVersion(fileId: "f", node: nil, page: "A", title: "T", paddockId: nil, by: "M").0.id != hi.id)
        // reloaded from disk; an orphan folder is passed over
        let again = ArtifactStore(root: root)
        #expect(try await again.list().map { [$0.id.uuidString, "\($0.version)", $0.folder] } == [[hi.id.uuidString, "2", hi.folder]])
        let (n, dir) = try await again.newVersion(fileId: "f", node: "2", page: nil, title: "T", paddockId: nil, by: "M")
        #expect(n.version == 3 && n.folder == "\(hi.id.uuidString.lowercased())/v3" && dir.lastPathComponent == "v3")
        let reg = root.appendingPathComponent("artifacts/artifacts.json").path
        #expect(try FileManager.default.attributesOfItem(atPath: reg)[.posixPermissions] as? Int == 0o600)
    }

    @Test func pagesAreSeparateArtifacts() async throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let s = ArtifactStore(root: root)
        let (a, _) = try await s.newVersion(fileId: "f", node: nil, page: "A", title: "T", paddockId: nil, by: "M"); try await s.commit(a)
        let (b, _) = try await s.newVersion(fileId: "f", node: nil, page: "B", title: "T", paddockId: nil, by: "M"); try await s.commit(b)
        #expect(a.id != b.id)
        let (a2, _) = try await s.newVersion(fileId: "f", node: nil, page: "A", title: "T", paddockId: nil, by: "M")
        let (b2, _) = try await s.newVersion(fileId: "f", node: nil, page: "B", title: "T", paddockId: nil, by: "M")
        #expect(a2.id == a.id && a2.version == 2 && b2.id == b.id && b2.version == 2)
        #expect(a2.page == "A" && b2.page == "B")
    }

    @Test func legacyPageRecordAdopted() async throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let s = ArtifactStore(root: root)
        let (old, _) = try await s.newVersion(fileId: "f", node: nil, page: nil, title: "T", paddockId: nil, by: "M"); try await s.commit(old)
        let (a, _) = try await s.newVersion(fileId: "f", node: nil, page: "A", title: "T", paddockId: nil, by: "M")
        #expect(a.id == old.id && a.page == "A" && a.version == 2); try await s.commit(a)
        #expect(try await s.get(old.id).page == "A")
        let (b, _) = try await s.newVersion(fileId: "f", node: nil, page: "B", title: "T", paddockId: nil, by: "M")
        #expect(b.id != old.id)
    }

    @Test func overlappingPagesDoNotShareALegacyRecord() async throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let s = ArtifactStore(root: root)
        let (old, _) = try await s.newVersion(fileId: "f", node: nil, page: nil, title: "T", paddockId: nil, by: "M"); try await s.commit(old)
        let (a, _) = try await s.newVersion(fileId: "f", node: nil, page: "A", title: "T", paddockId: nil, by: "M")
        let (b, _) = try await s.newVersion(fileId: "f", node: nil, page: "B", title: "T", paddockId: nil, by: "M")
        #expect(a.id == old.id && b.id != old.id)
        try await s.commit(a); try await s.commit(b)
        #expect(try await s.list().count == 2)
    }

    @Test func recordsWithoutPageStillDecode() throws {
        var a = Artifact(id: UUID(), kind: .export, title: "T", fileId: "f", node: nil, paddockId: nil, by: "M", at: Date(timeIntervalSince1970: 0),
                         version: 1, folder: "x/v1", stamp: nil, warnings: [])
        let old = try JSONEncoder().encode(a)
        #expect(!String(decoding: old, as: UTF8.self).contains("page"))
        #expect(try JSONDecoder().decode(Artifact.self, from: old).page == nil)
        a.page = "5"
        #expect(try JSONDecoder().decode(Artifact.self, from: try JSONEncoder().encode(a)) == a)
    }

    @Test func agentArtifactThenRemove() async throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let src = Data("<p>hi</p>".utf8)
        let s = ArtifactStore(root: root)
        let a = try await s.addAgent(page: src, title: "Page", paddockId: nil, by: "W")
        #expect(a.kind == .agent && a.version == 1 && a.fileId == nil)
        let copy = root.appendingPathComponent("artifacts/\(a.folder)/source.html").path
        #expect(FileManager.default.contents(atPath: copy) == Data("<p>hi</p>".utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: copy)[.posixPermissions] as? Int == 0o444)
        // concurrent changes: none lost
        async let x = s.addAgent(page: src, title: "X", paddockId: nil, by: "W")
        async let y = s.addAgent(page: src, title: "Y", paddockId: nil, by: "W")
        let (ax, ay) = try await (x, y)
        #expect(Set(try await s.list().map(\.id)) == [a.id, ax.id, ay.id])
        #expect(Set(try await ArtifactStore(root: root).list().map(\.id)) == [a.id, ax.id, ay.id])
        for id in [ax.id, ay.id] { try await s.remove(id) }
        try await s.remove(a.id)
        #expect(try await s.list().isEmpty)
        await #expect(throws: ProtocolError.self) { _ = try await s.get(a.id) }
        let removed = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("artifacts/.removed").path)
        #expect(removed.count == 3 && removed.contains { $0.hasPrefix(a.id.uuidString.lowercased() + "-") })
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/\(a.folder)").path))
    }

    @Test func removeWinsOverExportInFlight() async throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let s = ArtifactStore(root: root)
        let (v1, _) = try await s.newVersion(fileId: "f", node: "2", page: nil, title: "T", paddockId: nil, by: "M")
        try await s.commit(v1)
        let (v2, _) = try await s.newVersion(fileId: "f", node: "2", page: nil, title: "T", paddockId: nil, by: "M")
        try await s.remove(v1.id)
        #expect(try await s.commit(v2) == false)   // finished after the remove: not brought back, and the caller told
        #expect(try await s.list().isEmpty)
        // a later export of the same pair is a new artifact
        let (n, _) = try await s.newVersion(fileId: "f", node: "2", page: nil, title: "T", paddockId: nil, by: "M")
        try await s.commit(n)
        let ids = try await s.list().map(\.id)
        #expect(n.id != v1.id && n.version == 1 && ids == [n.id])
    }

    /// Folders are 0555 after a tree copy: made writable again so the test can delete them.
    private func unlock(_ u: URL) {
        for case let f as URL in FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil) ?? NSEnumerator() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
    }

    private func tree(_ root: URL, count extra: Int = 0) throws {
        let fm = FileManager.default
        for d in ["css", "img", ".git"] { try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
        for (f, c) in [("index.html", "<link href=css/style.css>"), ("css/style.css", "a{}"), ("img/a.png", "png"), (".git/x", "x"), ("notes.txt", "skip")] {
            try Data(c.utf8).write(to: root.appendingPathComponent(f))
        }
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.css"), withDestinationURL: root.appendingPathComponent("css/style.css"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("linkdir"), withDestinationURL: root.appendingPathComponent("css"))
        for i in 0..<extra { try Data().write(to: root.appendingPathComponent("f\(i).css")) }
    }

    @Test func addWithRootCopiesTree() async throws {
        let root = tmp(), src = tmp(); defer { unlock(root); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: src) }
        try tree(src)
        let s = ArtifactStore(root: root)
        let a = try await s.addAgent(root: src, page: src.appendingPathComponent("index.html"), title: "T", paddockId: nil, by: "W")
        let id = a.id.uuidString.lowercased()
        #expect(a.source == "\(id)/source/index.html" && a.kind == .agent)
        let base = root.appendingPathComponent("artifacts/\(id)/source")
        var found: [String] = []
        for sub in try FileManager.default.subpathsOfDirectory(atPath: base.path) {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: base.appendingPathComponent(sub).path, isDirectory: &isDir)
            let mode = try FileManager.default.attributesOfItem(atPath: base.appendingPathComponent(sub).path)[.posixPermissions] as? Int
            #expect(mode == (isDir.boolValue ? 0o555 : 0o444), "\(sub)")
            if !isDir.boolValue { found.append(sub) }
        }
        #expect(Set(found) == ["index.html", "css/style.css", "img/a.png"])
        #expect(try await ArtifactStore(root: root).get(a.id).source == a.source)
    }

    @Test func addRootRefusesOutsideAndHuge() async throws {
        let root = tmp(), src = tmp(), other = tmp()
        defer { for u in [root, src, other] { try? FileManager.default.removeItem(at: u) } }
        try tree(src, count: 2000)   // plus index.html, style.css, a.png: over 2000
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: other.appendingPathComponent("o.html"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("artifacts"), withIntermediateDirectories: true)
        let s = ArtifactStore(root: root)
        for page in [other.appendingPathComponent("o.html"), src.appendingPathComponent("index.html")] {
            await #expect(throws: ProtocolError.self) { _ = try await s.addAgent(root: src, page: page, title: "T", paddockId: nil, by: "W") }
        }
        let kids = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("artifacts").path)) ?? []
        #expect(kids.isEmpty)
        #expect(try await s.list().isEmpty)
    }

    @Test func addRootRefusesOver64MiB() async throws {
        let root = tmp(), src = tmp(); defer { for u in [root, src] { try? FileManager.default.removeItem(at: u) } }
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("<p/>".utf8).write(to: src.appendingPathComponent("index.html"))
        for i in 0..<3 { try Data(count: 22 << 20).write(to: src.appendingPathComponent("big\(i).css")) }
        let s = ArtifactStore(root: root)
        await #expect(throws: ProtocolError.self) { _ = try await s.addAgent(root: src, page: src.appendingPathComponent("index.html"), title: "T", paddockId: nil, by: "W") }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("artifacts").path)) ?? []).isEmpty)
    }

    @Test func symlinkedRootResolves() async throws {
        let root = tmp(), src = tmp(), link = tmp(); defer { unlock(root); for u in [root, src, link] { try? FileManager.default.removeItem(at: u) } }
        try tree(src)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: src)
        let a = try await ArtifactStore(root: root).addAgent(root: link, page: link.appendingPathComponent("index.html"), title: "T", paddockId: nil, by: "W")
        #expect(a.source?.hasSuffix("/source/index.html") == true)
    }

    @Test func oldAgentRecordsDecode() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","kind":"agent","title":"T","by":"M","at":"1970-01-01T00:00:00Z","version":1,"folder":"x","warnings":[]}
        """
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let a = try dec.decode(Artifact.self, from: Data(json.utf8))
        #expect(a.source == nil && a.importError == nil && a.id == id)
    }

    @Test func convertToExportKeepsSourceUntilCommit() async throws {
        let root = tmp(); defer { try? FileManager.default.removeItem(at: root) }
        let s = ArtifactStore(root: root)
        let a = try await s.addAgent(page: Data("<p/>".utf8), title: "T", paddockId: nil, by: "W")
        let (e, dir) = try await s.convertToExport(a.id, fileId: "f", node: "2", page: "1")
        #expect(e.source == "\(a.id.uuidString.lowercased())/source.html" && a.source != nil)
        await #expect(throws: ProtocolError.self) { _ = try await s.convertToExport(a.id, fileId: "f", node: "3", page: nil) }   // one at a time
        #expect(e.id == a.id && e.kind == .export && e.version == 1 && dir.lastPathComponent == "v1")
        #expect(try await s.get(a.id).kind == .agent)   // failed export: still the agent's page
        try await s.setImportError(a.id, "boom")
        #expect(try await s.get(a.id).importError == "boom")
        try await s.commit(e)
        let c = try await s.get(a.id)
        #expect(c.kind == .export && c.fileId == "f" && c.node == "2" && c.page == "1" && c.source == a.source)
        await #expect(throws: ProtocolError.self) { _ = try await s.convertToExport(UUID(), fileId: "f", node: "2", page: nil) }
    }
}

// MARK: html exports on the fake engine

/// The fake figcraft (Tests/Fixtures); its calls in `log`, its flags in `flags`.
private struct Fake {
    let dir = URL(fileURLWithPath: "/tmp/collie-artf-\(UUID().uuidString.prefix(8))")
    var flags: URL { dir.appendingPathComponent("flags") }
    var log: URL { dir.appendingPathComponent("calls.log") }
    init() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: flags, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("figcraft-cli"),
                                                   withDestinationURL: fixtures.appendingPathComponent("fake-figcraft-mcp.py"))
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("figcraft-server"),
                                                   withDestinationURL: fixtures.appendingPathComponent("fake-figcraft-server.sh"))
        try Data().write(to: log)
        setenv("COLLIE_FAKE_FIG_LOG", log.path, 1)
        setenv("COLLIE_FAKE_FIG_FLAGS", flags.path, 1)
    }
    func set(_ flag: String, _ value: String = "") throws { try Data(value.utf8).write(to: flags.appendingPathComponent(flag)) }
    var calls: [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    func cleanup() { unsetenv("COLLIE_FAKE_FIG_FLAGS"); try? FileManager.default.removeItem(at: dir) }
}
private struct Term { var id: String; var token: String }
private func admin(_ d: Daemon, _ p: Paths, _ cmd: String, _ args: [String: String] = [:]) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: cmd, args: args.mapValues { .string($0) }),
                                    to: p.socket, timeoutSeconds: 120)
}
private func call(_ p: Paths, _ t: Term, _ cmd: String, _ args: [String: String] = [:], cwd: String? = nil) async throws -> Response {
    try await UnixSocketClient.send(Request(id: "m", terminalId: t.id, token: t.token, command: cmd, args: args.mapValues { .string($0) }, cwd: cwd),
                                    to: p.socket, timeoutSeconds: 120)
}
/// Shepherd `M`, leashed to canvas panel `design-1` on file `Site`, inside a daemon on the fake engine.
private func withPanel(_ fx: Fake, timeoutCap: Duration? = nil, before: (Daemon, Paths) async throws -> Void = { _, _ in },
                       _ body: (Daemon, Paths, Term) async throws -> Void) async throws {
    try await withDaemon(configure: { $0.figcraftDir = fx.dir; $0.designTimeoutCap = timeoutCap }) { d, p in
        try await before(d, p)
        let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn",
            args: ["name": "M", "preset": "shell", "cwd": "/tmp", "shepherd": true]), to: p.socket, timeoutSeconds: 60)
        guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
        let m = Term(id: id, token: try await tokenOf(d, id))
        #expect(try await call(p, m, "panel.open", ["plugin": "design", "file": "Site", "placement": "canvas"]).ok)
        try await body(d, p, m)
    }
}
private func out(_ r: Response) -> (path: String, id: String, version: Int)? {
    guard case .object(let o)? = r.result, case .string(let path)? = o["path"], case .string(let id)? = o["artifact"],
          case .number(let v)? = o["version"], case .array? = o["warnings"] else { return nil }
    return (path, id, Int(v))
}
private func html(_ p: Paths, _ m: Term) async throws -> Response {
    try await call(p, m, "design.export", ["format": "html", "node": "2"])
}

extension DesignCommandTests { @Suite(.serialized) struct ArtifactExportTests {
    @Test func htmlExportBecomesArtifact() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withPanel(fx) { d, p, m in
            let r = try await html(p, m)
            let a = try #require(out(r), "\(r)")
            let base = p.root.appendingPathComponent("artifacts/\(a.id)")
            #expect(a.version == 1 && a.path == base.appendingPathComponent("v1/index.html").path, "\(a)")
            #expect(try String(contentsOfFile: a.path, encoding: .utf8).hasPrefix("<!doctype html>"))
            let v1 = base.appendingPathComponent("v1")
            #expect(FileManager.default.contents(atPath: v1.appendingPathComponent("thumb.png").path)?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
            let assets = try FileManager.default.contentsOfDirectory(atPath: v1.appendingPathComponent("assets").path)
            #expect(assets.contains { $0.hasSuffix(".png") }, "\(assets)")
            let rec = try await d.router.artifacts.get(try #require(UUID(uuidString: a.id)))
            #expect(rec.kind == .export && rec.title == "Landing" && rec.node == "2" && rec.stamp?.count == 64 && rec.version == 1)
            let before = try Data(contentsOf: URL(fileURLWithPath: a.path))
            let b = try #require(out(try await html(p, m)))
            #expect(b.id == a.id && b.version == 2 && b.path == base.appendingPathComponent("v2/index.html").path, "\(b)")
            #expect(try Data(contentsOf: URL(fileURLWithPath: a.path)) == before)   // v1 intact
            #expect(try await d.router.artifacts.get(try #require(UUID(uuidString: a.id))).version == 2)
        }
    }

    @Test func pageExportRecordsAndReusesItsPage() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withPanel(fx) { d, p, m in
            #expect(try await call(p, m, "design.batch", ["commands": #"[{"command":"node.create","params":{"type":"frame"}}]"#]).ok)
            let a = try #require(out(try await call(p, m, "design.export", ["format": "html"])))
            let b = try #require(out(try await call(p, m, "design.export", ["format": "html"])))
            #expect(b.id == a.id && b.version == 2)
            let rec = try await d.router.artifacts.get(try #require(UUID(uuidString: a.id)))
            #expect(rec.node == nil && rec.page == "1", "\(rec)")   // the snapshot's page reached newVersion
        }
    }

    @Test func concurrentExportsGetDistinctVersions() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withPanel(fx) { _, p, m in
            async let x = html(p, m)
            async let y = html(p, m)
            let a = try #require(out(try await x)), b = try #require(out(try await y))
            #expect(a.id == b.id && Set([a.version, b.version]) == [1, 2], "\(a) \(b)")
            for v in ["v1", "v2"] {
                #expect(FileManager.default.fileExists(atPath: p.root.appendingPathComponent("artifacts/\(a.id)/\(v)/index.html").path))
            }
        }
    }

    @Test func exportUsesActiveSystemTokens() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try fx.set("named-links")   // each file's client logs `variables <file>` on variable.list
        try fx.set("black-dark@Brand")   // the system's color/bg is black in Dark: its list comes last and wins
        try await withPanel(fx, before: { d, p async throws in
            #expect(try await admin(d, p, "design.system.create", ["name": "Brand", "reason": "base"]).ok)
            #expect(try await admin(d, p, "design.system.use", ["name": "Brand", "reason": "r"]).ok)
        }) { _, p, m in
            let n = fx.calls.count
            let r = try await html(p, m)
            let a = try #require(out(r), "\(r)")
            let after = fx.calls.suffix(from: n)
            #expect(after.contains("variables Brand") && after.contains("variables Site"), "\(after)")
            let page = try String(contentsOfFile: a.path, encoding: .utf8)
            let dark = try #require(page.firstRange(of: #"[data-theme="dark"] {"#).map { page[$0.upperBound...].prefix { $0 != "}" } }, "\(page)")
            #expect(dark.contains("--color-bg: #000000;"), "\(dark)")
            #expect(!"\(r.result ?? .null)".contains("design system tokens unavailable"))
        }
    }

    @Test func pageExportRecordsItsPage() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withPanel(fx) { d, p, m in
            #expect(try await call(p, m, "design.batch", ["commands": #"[{"command":"node.create","params":{"type":"frame"}}]"#]).ok)
            let a = try #require(out(try await call(p, m, "design.export", ["format": "html"])))
            let rec = try await d.router.artifacts.get(try #require(UUID(uuidString: a.id)))
            #expect(rec.node == nil && rec.page == "1", "\(rec)")
            #expect(try await rows(p, m).first?["status"] == .string("current"))
        }
    }

    @Test func systemTokensShareTheExportDeadline() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try fx.set("named-links")
        try await withPanel(fx, timeoutCap: .seconds(6), before: { d, p async throws in
            #expect(try await admin(d, p, "design.system.create", ["name": "Brand", "reason": "base"]).ok)
            #expect(try await admin(d, p, "design.system.use", ["name": "Brand", "reason": "r"]).ok)
        }) { _, p, m in
            // the snapshot takes ~4.5 s of the 6: the system's 2 s variable.list no longer fits
            try fx.set("slow-inspect.assets", "2.5"); try fx.set("slow-variable.list", "2")
            let t0 = ContinuousClock.now
            let r = try await html(p, m)
            #expect(out(r) != nil && "\(r.result ?? .null)".contains("design system tokens unavailable"), "\(r)")
            #expect(ContinuousClock.now - t0 < .seconds(7))
        }
    }

    // MARK: artifact.* commands

    @Test func agentRegistersHTML() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withPanel(fx) { _, p, m in
            let cwd = fx.dir.appendingPathComponent("cwd")
            try FileManager.default.createDirectory(at: cwd.appendingPathComponent("site"), withIntermediateDirectories: true)
            try Data("<h1>made by M</h1>".utf8).write(to: cwd.appendingPathComponent("site/index.html"))
            let r = try await call(p, m, "artifact.add", ["path": "site/index.html"], cwd: cwd.path)
            guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { Issue.record("\(r)"); return }
            let row = try #require(try await rows(p, m).first { $0["id"] == .string(id) })
            #expect(o["importing"] == .bool(true), "\(r)")
            // its import started at once (and fails without the app)
            #expect(row["kind"] == .string("agent") && [.string("importing"), .string("failed")].contains(row["status"]) && row["title"] == .string("index.html"), "\(row)")
            #expect(row["file"] == .null && row["thumbnail"] == .null && row["url"] == .string("collie-artifact://app/\(id)/source.html"))
            guard case .string(let by)? = row["by"], case .string(let path)? = row["path"] else { Issue.record("\(row)"); return }
            #expect(by.contains("M") && path == p.root.appendingPathComponent("artifacts/\(id)/source.html").path)
            #expect(FileManager.default.contents(atPath: path) == Data("<h1>made by M</h1>".utf8))
            #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o444)
            let g = try await call(p, m, "artifact.get", ["id": id])
            guard case .object(let one)? = g.result else { Issue.record("\(g)"); return }
            #expect(one["id"] == .string(id) && one["status"] == nil && one["path"] == .string(path), "\(one)")
        }
    }

    @Test func addRefusesSymlinkNonHTMLAndHuge() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withPanel(fx) { _, p, m in
            let cwd = fx.dir.appendingPathComponent("cwd")
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            try Data("<p>x</p>".utf8).write(to: cwd.appendingPathComponent("real.html"))
            try FileManager.default.createSymbolicLink(at: cwd.appendingPathComponent("link.html"), withDestinationURL: cwd.appendingPathComponent("real.html"))
            try Data("x".utf8).write(to: cwd.appendingPathComponent("notes.txt"))
            try Data(count: 9 << 20).write(to: cwd.appendingPathComponent("huge.html"))
            for f in ["link.html", "notes.txt", "huge.html", "nothere.html"] {
                let r = try await call(p, m, "artifact.add", ["path": f], cwd: cwd.path)
                #expect(!r.ok && r.error?.code == .invalidArgs, "\(f): \(r)")
            }
            #expect(try await call(p, m, "artifact.add", ["path": "real.html", "title": "Real"], cwd: cwd.path).ok)
            let titles = try await rows(p, m).map { $0["title"] }
            #expect(titles == [.string("Real")])
        }
    }

    @Test func statusPrecedence() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withPanel(fx) { d, p, m in
            var u: [UUID] = []   // through the store: artifact.add would start importing them
            for _ in 0..<3 { u.append(try await d.router.artifacts.addAgent(page: Data("<p>x</p>".utf8), title: "a", paddockId: nil, by: "M").id) }
            let ids = u.map { $0.uuidString.lowercased() }
            try await d.router.artifacts.setImportError(u[0], "x"); try await d.router.artifacts.setImportError(u[1], "y")
            func status() async throws -> [String: JSONValue] {
                var out: [String: JSONValue] = [:]
                for r in try await rows(p, m) { if case .string(let id)? = r["id"] { out[id] = r["status"] } }
                return out
            }
            var st = try await status()
            #expect(st[ids[0]] == .string("failed") && st[ids[1]] == .string("failed") && st[ids[2]] == .string("pending"))
            await d.router.setImporting(u[0], true)
            st = try await status()
            #expect(st[ids[0]] == .string("importing") && st[ids[1]] == .string("failed") && st[ids[2]] == .string("pending"))
            await d.router.setImporting(u[0], false)
            #expect(try await status()[ids[0]] == .string("failed"))
        }
    }

    @Test func oldAgentRowShowsSource() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        let id = UUID().uuidString.lowercased()
        try await withPanel(fx, before: { _, p in
            try FileManager.default.createDirectory(at: p.root.appendingPathComponent("artifacts"), withIntermediateDirectories: true)
            let json = #"[{"id":"\#(id)","kind":"agent","title":"T","by":"M","at":"2020-01-01T00:00:00Z","version":1,"folder":"\#(id)","warnings":[]}]"#
            try Data(json.utf8).write(to: p.root.appendingPathComponent("artifacts/artifacts.json"))
        }) { _, p, m in
            let row = try #require(try await rows(p, m).first)
            #expect(row["source"] == .string("collie-artifact://app/\(id)/source.html"), "\(row)")
        }
    }

    @Test func listMarksCurrentAndStale() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withPanel(fx) { d, p, m in
            let a = try #require(out(try await html(p, m)))
            var row = try #require(try await rows(p, m).first)
            #expect(row["status"] == .string("current") && row["kind"] == .string("export") && row["file"] == .string("Site"), "\(row)")
            #expect(row["url"] == .string("collie-artifact://app/\(a.id)/v1/index.html") && row["path"] == .string(a.path))
            #expect(row["thumbnail"] == .string(p.root.appendingPathComponent("artifacts/\(a.id)/v1/thumb.png").path), "\(row)")
            #expect(try await call(p, m, "design.run", ["command": "node.set", "params": #"{"id": 4, "characters": "Changed"}"#]).ok)
            row = try #require(try await rows(p, m).first)
            #expect(row["status"] == .string("stale"), "\(row)")
            let r = try await admin(d, p, "artifact.reexport", ["id": a.id])
            #expect(out(r)?.version == 2, "\(r)")
            row = try #require(try await rows(p, m).first)
            #expect(row["version"] == .number(2) && row["status"] == .string("current"), "\(row)")
        }
    }

    @Test func listMarksMissingAndUnknown() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withPanel(fx) { _, p, m in
            #expect(out(try await html(p, m)) != nil)
            #expect(try await call(p, m, "design.run", ["command": "edit.delete", "params": #"{"ids": [2]}"#]).ok)
            let row = try #require(try await rows(p, m).first)
            #expect(row["status"] == .string("missing"), "\(row)")
        }
        let fy = try Fake(); defer { fy.cleanup() }
        try await withPanel(fy) { _, p, m in
            #expect(out(try await html(p, m)) != nil)
            #expect(try await call(p, m, "design.run", ["command": "node.slowreads"]).ok)
            let t0 = ContinuousClock.now
            let row = try #require(try await rows(p, m).first)
            #expect(row["status"] == .string("unknown"), "\(row)")
            #expect(ContinuousClock.now - t0 < .seconds(60))
        }
    }

    @Test func listStopsAskingPastItsDeadline() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withPanel(fx, timeoutCap: .seconds(5)) { d, p, m in   // artifact.list: 5 s in all
            #expect(out(try await html(p, m)) != nil)
            #expect(out(try await call(p, m, "design.export", ["format": "html", "node": "3"])) != nil)
            // an export of a file no longer registered: missing, no engine call
            let (gone, _) = try await d.router.artifacts.newVersion(fileId: "gone", node: nil, page: nil, title: "Gone", paddockId: nil, by: "app")
            try await d.router.artifacts.commit(gone)
            #expect(try await call(p, m, "design.run", ["command": "node.slowreads"]).ok)
            let n = fx.calls.count
            let list = try await rows(p, m)
            #expect(list.count == 3 && list.filter { $0["status"] == .string("unknown") }.count == 2, "\(list)")
            #expect(list.first { $0["title"] == .string("Gone") }?["status"] == .string("missing"), "\(list)")
            let reads = fx.calls.suffix(from: n).filter { $0 == "tools/call get_node " }
            #expect(reads.count == 1, "\(fx.calls.suffix(from: n))")   // the second export: past the deadline, not asked
        }
    }

    @Test func libsListsManifest() async throws {
        let dir = URL(fileURLWithPath: "/tmp/collie-weblibs-\(UUID().uuidString.prefix(8))"); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"[{"name":"react","version":"18.3.1","files":["react.production.min.js"],"licence":"MIT","global":"React"}]"#.utf8)
            .write(to: dir.appendingPathComponent("manifest.json"))
        try await withDaemon(configure: { $0.weblibsDir = dir }) { d, p in
            let r = try await admin(d, p, "artifact.libs")
            #expect(r.result == .array([.object(["name": .string("react"), "version": .string("18.3.1"), "global": .string("React"),
                                                 "url": .string("collie-lib://lib/react@18.3.1/react.production.min.js"), "licence": .string("MIT")])]), "\(r)")
        }
    }

    @Test func libsMissingIsUnavailable() async throws {
        try await withDaemon(configure: { $0.weblibsDir = URL(fileURLWithPath: "/nonexistent") }) { d, p in
            let r = try await admin(d, p, "artifact.libs")
            #expect(r.error?.code == .unavailable && r.error?.message == "Bibliotecas offline ausentes: rode scripts/fetch-weblibs.sh", "\(r)")
        }
        try await withDaemon { d, p in
            let r = try await admin(d, p, "artifact.libs")
            #expect(r.error?.code == .unavailable)
        }
    }

    @Test func reexportAndRemoveAreAppOnly() async throws {
        let fx = try Fake(); defer { fx.cleanup() }
        try await withPanel(fx) { d, p, m in
            let a = try #require(out(try await html(p, m)))
            for c in ["artifact.reexport", "artifact.remove"] {
                let r = try await call(p, m, c, ["id": a.id])
                #expect(r.error?.code == .unauthorized && r.error?.message == "'\(c)' is for the app only", "\(r)")
            }
            #expect(try await admin(d, p, "artifact.remove", ["id": a.id]).ok)
            #expect(try await rows(p, m).isEmpty)
            let removed = try FileManager.default.contentsOfDirectory(atPath: p.root.appendingPathComponent("artifacts/.removed").path)
            #expect(removed.contains { $0.hasPrefix(a.id + "-") }, "\(removed)")
            #expect(try await admin(d, p, "artifact.get", ["id": a.id]).error?.code == .notFound)
        }
    }
} }

private func rows(_ p: Paths, _ t: Term) async throws -> [[String: JSONValue]] {
    let r = try await call(p, t, "artifact.list")
    guard case .array(let a)? = r.result else { throw ProtocolError(code: .internal, message: "\(r)") }
    return a.compactMap { if case .object(let o) = $0 { o } else { nil } }
}

// MARK: artifact new (plan 2U)

extension CommandRouter { func testSetActiveSystem(_ id: UUID?) { ws.designSystem = id } }

@Suite(.serialized) struct ArtifactNewTests {
    /// A terminal `A` (not a Shepherd) in a fresh project folder.
    private func withProject(libs: URL? = nil, _ body: (Daemon, Paths, Term, URL) async throws -> Void) async throws {
        let proj = URL(fileURLWithPath: "/tmp/collie-new-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: proj) }
        try await withDaemon(configure: { $0.weblibsDir = libs }) { d, p in
            let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn",
                args: ["name": "A", "preset": "shell", "cwd": .string(proj.path)]), to: p.socket, timeoutSeconds: 60)
            guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
            try await body(d, p, Term(id: id, token: try await tokenOf(d, id)), proj)
        }
    }
    private func result(_ r: Response) -> [String: JSONValue] { if case .object(let o)? = r.result { o } else { [:] } }
    private func warnings(_ r: Response) -> [String] {
        guard case .array(let ws)? = result(r)["warnings"] else { return [] }
        return ws.compactMap { if case .string(let s) = $0 { s } else { nil } }
    }

    @Test func newWritesPageAndOpensPreview() async throws {
        try await withProject { d, p, a, proj in
            let r = try await call(p, a, "artifact.new", ["kind": "deck"])
            #expect(r.error == nil, "\(r)")
            #expect(result(r)["file"] == .string("docs/pages/deck-1/index.html"), "\(r)")
            let html = try String(contentsOf: proj.appendingPathComponent("docs/pages/deck-1/index.html"), encoding: .utf8)
            #expect(html.hasPrefix("<!doctype html>") && html.contains("class=\"slide"))
            let s = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "ui.snapshot"), to: p.socket, timeoutSeconds: 60)
            let snap = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(s.result))
            let pn = try #require(snap.panels.first { $0.pluginId == "preview" })
            #expect(result(r)["panel"] == .string(pn.name) && pn.state["file"] == .string("docs/pages/deck-1/index.html"))
            #expect(snap.connections.contains { Set([$0.a, $0.b]) == Set([UUID(uuidString: a.id)!, pn.id]) })
        }
    }

    @Test func newDefaultNameCounts() async throws {
        try await withProject { _, p, a, _ in
            #expect(result(try await call(p, a, "artifact.new", ["kind": "deck"]))["file"] == .string("docs/pages/deck-1/index.html"))
            #expect(result(try await call(p, a, "artifact.new", ["kind": "deck"]))["file"] == .string("docs/pages/deck-2/index.html"))
            let named = try await call(p, a, "artifact.new", ["kind": "dashboard", "name": "Meu Deck 2026!"])
            #expect(result(named)["file"] == .string("docs/pages/meu-deck-2026/index.html"), "\(named)")
            #expect(try await call(p, a, "artifact.new", ["kind": "doc", "name": "!!!"]).error?.code == .invalidArgs)
            #expect(result(try await call(p, a, "artifact.new", ["kind": "doc", "name": "../x"]))["file"] == .string("docs/pages/x/index.html"))
        }
    }

    @Test func newRefusesExisting() async throws {
        try await withProject { _, p, a, proj in
            let f = proj.appendingPathComponent("docs/pages/vendas/index.html")
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("meu".utf8).write(to: f)
            let e = try await call(p, a, "artifact.new", ["kind": "dashboard", "name": "vendas"]).error
            #expect(e?.code == .invalidArgs && e?.message.contains("já existe") == true, "\(String(describing: e))")
            #expect(try Data(contentsOf: f) == Data("meu".utf8))
        }
    }

    @Test func newWithoutSystemUsesSeed() async throws {
        try await withProject { _, p, a, proj in
            let r = try await call(p, a, "artifact.new", ["kind": "doc", "title": "Notas"])
            #expect(warnings(r) == ["sem design system ativo: tokens padrão", "bibliotecas offline ausentes"], "\(r)")
            let html = try String(contentsOf: proj.appendingPathComponent("docs/pages/doc-1/index.html"), encoding: .utf8)
            #expect(html.contains("<title>Notas</title>") && html.contains("[data-theme=\"dark\"]") && html.contains("[data-theme=\"light\"]"))
            #expect(html.contains(Fonts.cssURL(["Space Grotesk", "DM Mono"])))   // the bundled fonts, offline
        }
    }

    @Test func newEngineDownUsesSeed() async throws {
        try await withProject { d, p, a, proj in
            await d.router.testSetActiveSystem(UUID())   // active, but no engine (and no such system) here
            let r = try await call(p, a, "artifact.new", ["kind": "prototype"])
            #expect(r.error == nil && warnings(r) == ["design system indisponível: tokens padrão", "bibliotecas offline ausentes"], "\(r)")
            #expect(FileManager.default.fileExists(atPath: proj.appendingPathComponent("docs/pages/prototype-1/index.html").path))
        }
    }

    @Test func newUsesLibs() async throws {
        let dir = URL(fileURLWithPath: "/tmp/collie-weblibs-\(UUID().uuidString.prefix(8))"); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"[{"name":"chart.js","version":"4.4.9","files":["chart.umd.js"],"licence":"MIT","global":"Chart"}]"#.utf8)
            .write(to: dir.appendingPathComponent("manifest.json"))
        try await withProject(libs: dir) { _, p, a, proj in
            let r = try await call(p, a, "artifact.new", ["kind": "dashboard"])
            #expect(warnings(r) == ["sem design system ativo: tokens padrão"], "\(r)")
            let html = try String(contentsOf: proj.appendingPathComponent("docs/pages/dashboard-1/index.html"), encoding: .utf8)
            #expect(html.contains(#"<script src="collie-lib://lib/chart.js@4.4.9/chart.umd.js"></script>"#))
        }
    }

    /// `--connect` (the "Feature com design" Pastor): a Shepherd leashes the new Prévia to terminals it reaches; others are refused.
    @Test func newConnectLeashesTargets() async throws {
        try await withProject { d, p, a, proj in
            let r = try await UnixSocketClient.send(Request(id: "x", token: d.adminToken, command: "admin.spawn",
                args: ["name": "M", "preset": "shell", "cwd": .string(proj.path), "shepherd": true]), to: p.socket, timeoutSeconds: 60)
            guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
            let m = Term(id: id, token: try await tokenOf(d, id))
            #expect(try await call(p, a, "artifact.new", ["kind": "prototype", "connect": "M"]).error?.code == .notShepherd)
            #expect(try await call(p, m, "artifact.new", ["kind": "prototype", "connect": "A"]).error?.code == .notConnected)   // not reached yet
            #expect(!FileManager.default.fileExists(atPath: proj.appendingPathComponent("docs/pages/prototype-1").path))
            #expect(try await admin(d, p, "admin.leash", ["a": "M", "b": "A"]).ok)
            let n = try await call(p, m, "artifact.new", ["kind": "prototype", "name": "feature", "connect": "A"])
            #expect(n.error == nil, "\(n)")
            let pn = try #require(await d.router.ws.panels.first { $0.pluginId == "preview" })
            let conns = await d.router.ws.connections
            for t in [a, m] { #expect(conns.contains { Set([$0.a, $0.b]) == Set([UUID(uuidString: t.id)!, pn.id]) }) }
        }
    }

    @Test func newBadKind() async throws {
        try await withProject { _, p, a, _ in
            let e = try await call(p, a, "artifact.new", ["kind": "slides"]).error
            #expect(e?.code == .invalidArgs && e?.message.contains("deck|dashboard|doc|prototype") == true, "\(String(describing: e))")
        }
    }

    /// Many `artifact new` at once from one terminal: the 8-Prévia cap counts the ones still opening.
    @Test func newCapCountsInFlight() async throws {
        try await withProject { d, p, a, _ in
            let rs = try await withThrowingTaskGroup(of: Response.self) { g in
                for i in 0..<12 { g.addTask { try await call(p, a, "artifact.new", ["kind": "doc", "name": "d\(i)"]) } }
                return try await g.reduce(into: []) { $0.append($1) }
            }
            #expect(rs.count(where: { $0.ok }) == CommandRouter.testerBrowserCap, "\(rs.map { $0.error?.message ?? "ok" })")
            #expect(await d.router.ws.panels.count(where: { $0.pluginId == "preview" }) == CommandRouter.testerBrowserCap)
        }
    }

    /// `artifact.add --nofollow` (the Prévia's save): a root or page reached through a link is refused, nothing copied.
    @Test func addNoFollowRefusesLinkedRoot() async throws {
        try await withProject { d, p, a, proj in
            let outside = URL(fileURLWithPath: "/tmp/collie-out-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            try Data("<body>segredo</body>".utf8).write(to: outside.appendingPathComponent("index.html"))
            let real = DiagramFile.real(proj)
            try FileManager.default.createSymbolicLink(at: real.appendingPathComponent("x"), withDestinationURL: outside)
            let e = try await admin(d, p, "artifact.add", ["path": real.path + "/x/index.html", "root": real.path + "/x", "nofollow": "true"]).error
            #expect(e?.code == .invalidArgs, "\(String(describing: e))")
            #expect(try await d.router.artifacts.list().isEmpty)
        }
    }
}
