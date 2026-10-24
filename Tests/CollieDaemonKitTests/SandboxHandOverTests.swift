import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// Plan 2O Task 1: a file the daemon made for a sandboxed terminal (screenshot, export) is cloned into its `files/`,
/// which its profile can read. Fake home (R2), temp roots only.
@Suite(.serialized) struct SandboxHandOverTests {
    /// A daemon on the fake home's Collie root with one sandboxed terminal `S` and one free terminal `F` (records only).
    func withTerminals(_ body: (Daemon, Paths, FakeHome, _ sandboxed: UUID, _ free: UUID) async throws -> Void) async throws {
        let f = try FakeHome(git: false, socket: false)
        let paths = Paths(root: f.collie)
        var c = testConfig(paths); c.sandboxHome = f.home
        let d = try Daemon(config: c)
        try await d.start()
        do {
            func spawn(_ name: String, _ extra: [String: JSONValue]) async throws -> UUID {
                let r = try await send(paths, Request(id: "s", token: d.adminToken, command: "admin.spawn",
                    args: ["name": .string(name), "preset": .string("shell"), "cwd": .string(f.other.path)].merging(extra) { $1 }))
                guard case .object(let o)? = r.result, case .string(let id)? = o["id"] else { throw ProtocolError(code: .internal, message: "\(r)") }
                return UUID(uuidString: id)!
            }
            let s = try await spawn("S", [:]), free = try await spawn("F", ["sandbox": .string("free")])
            try await body(d, paths, f, s, free)
        } catch { await d.stop(); throw error }
        await d.stop()
    }
    static func shot(_ root: URL, _ name: String = "panel-1.png") throws -> URL {
        let u = root.appendingPathComponent("screens/\(name)")
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("PNG-\(name)".utf8).write(to: u)
        return u
    }
    func pathResult(_ u: URL) -> JSONValue { .object(["path": .string(u.path), "width": .number(1)]) }
    func path(_ v: JSONValue) -> String? { if case .object(let o) = v, case .string(let p)? = o["path"] { return p } else { return nil } }
    func req(_ cmd: String, _ id: UUID?) -> Request { Request(id: "x", terminalId: id?.uuidString, command: cmd) }
    func files(_ id: UUID, _ root: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: SandboxLaunch.filesDir(id, root: root).path)) ?? []
    }

    @Test func sandboxedScreenshotPathIsReadable() async throws {
        try await withTerminals { d, p, f, s, _ in
            let src = try Self.shot(p.root)
            let out = try #require(path(await d.router.handedOver(pathResult(src), for: req("design.screenshot", s))))
            #expect(out.hasPrefix(SignedAppCheck.realPath(SandboxLaunch.filesDir(s, root: p.root)) + "/"), "\(out)")
            let profile = SandboxLaunch.profileFile(s, root: p.root)
            let r = try f.run(profile, "cat " + AgentLaunch.quote(out), cwd: f.other)
            #expect(r.status == 0 && r.out == "PNG-panel-1.png", "\(r)")
            #expect(try f.run(profile, "cat " + AgentLaunch.quote(src.path), cwd: f.other).status != 0)   // why: the root is closed
            #expect(FileManager.default.fileExists(atPath: src.path))   // the original stays
        }
    }

    @Test func freeTerminalPathUnchanged() async throws {
        try await withTerminals { d, p, _, _, free in
            let src = try Self.shot(p.root)
            #expect(path(await d.router.handedOver(pathResult(src), for: req("design.screenshot", free))) == src.path)
            #expect(files(free, p.root).isEmpty)
        }
    }

    @Test func adminPathUnchanged() async throws {
        try await withTerminals { d, p, _, _, _ in
            let src = try Self.shot(p.root)
            #expect(path(await d.router.handedOver(pathResult(src), for: req("device.screenshot", nil))) == src.path)
        }
    }

    @Test func notListedCommandUnchanged() async throws {
        try await withTerminals { d, p, _, s, _ in
            let src = try Self.shot(p.root, "memory.md")
            #expect(path(await d.router.handedOver(pathResult(src), for: req("memory.get", s))) == src.path)
            #expect(files(s, p.root).isEmpty)
        }
    }

    @Test func symlinkSourceNotHandedOver() async throws {
        try await withTerminals { d, p, f, s, _ in
            let link = p.root.appendingPathComponent("screens/x.png")
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.home.appendingPathComponent(".ssh/id_ed25519"))
            #expect(path(await d.router.handedOver(pathResult(link), for: req("browser.screenshot", s))) == link.path)
            // a regular file outside the root: unchanged too
            let outside = f.home.appendingPathComponent(".ssh/id_ed25519")
            #expect(path(await d.router.handedOver(pathResult(outside), for: req("browser.screenshot", s))) == outside.path)
            #expect(files(s, p.root).isEmpty)
        }
    }

    @Test func prunesToHundred() throws {
        let root = URL(fileURLWithPath: SignedAppCheck.realPath(FileManager.default.temporaryDirectory.appendingPathComponent("ho-\(UUID().uuidString)")))
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), dir = SandboxLaunch.filesDir(id, root: root), fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<100 {   // older than the new one; old-0 the oldest
            let u = dir.appendingPathComponent("old-\(i).png")
            try Data().write(to: u)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000 + Double(i))], ofItemAtPath: u.path)
        }
        let src = try Self.shot(root)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: src.path)   // an old source
        let out = try SandboxLaunch.handOver(src, terminal: id, root: root)
        let left = try fm.contentsOfDirectory(atPath: dir.path)
        #expect(left.count == 100)
        #expect(left.contains(out.lastPathComponent) && !left.contains("old-0.png") && left.contains("old-1.png"))
    }

    @Test func nameCollisionGetsSuffix() throws {
        let root = URL(fileURLWithPath: SignedAppCheck.realPath(FileManager.default.temporaryDirectory.appendingPathComponent("ho-\(UUID().uuidString)")))
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), src = try Self.shot(root)
        let a = try SandboxLaunch.handOver(src, terminal: id, root: root), b = try SandboxLaunch.handOver(src, terminal: id, root: root)
        #expect(a.lastPathComponent == "panel-1.png" && b.lastPathComponent == "panel-1-2.png")
        #expect(try Data(contentsOf: a) == Data(contentsOf: b))
        #expect(try FileManager.default.attributesOfItem(atPath: a.deletingLastPathComponent().path)[.posixPermissions] as? Int == 0o700)   // made when missing
    }

    @Test func claudeSettingsAddFilesDir() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ho-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: dir) }
        let r = TerminalRecord(id: UUID(), name: "A", preset: .claude, command: nil, cwd: "/tmp", isShepherd: false)
        let collie = URL(fileURLWithPath: "/opt/collie"), files = dir.appendingPathComponent("sandbox/x/files")
        func settings() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: AgentLaunch.settingsFile(r.id, in: dir))) as! [String: Any]
        }
        _ = try AgentLaunch.launchSpec(for: r, env: [:], hooksDir: dir, collie: collie, shell: "/bin/zsh", innerSandboxOff: true, filesDir: files)
        #expect((try settings()["permissions"] as? [String: Any])?["additionalDirectories"] as? [String] == [files.path])
        _ = try AgentLaunch.launchSpec(for: r, env: [:], hooksDir: dir, collie: collie, shell: "/bin/zsh")   // a free terminal
        #expect(try settings()["permissions"] == nil)
    }
}
