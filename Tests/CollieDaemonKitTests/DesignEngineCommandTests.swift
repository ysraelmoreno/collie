import Testing
import Foundation
import CryptoKit
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

/// A pin file and its asset (`figcraft/{bin/*, web/index.html, engine.json}` packed with /usr/bin/tar) in a temp dir.
private struct Asset {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("collie-engcmd-\(UUID().uuidString.prefix(8))")
    var file: URL { dir.appendingPathComponent("asset.tar.gz") }
    var pinFile: URL { dir.appendingPathComponent("figcraft-engine.json") }
    let pin: FigcraftPin

    init(version: String = "0.8.0-c1") throws {
        let fm = FileManager.default, f = dir.appendingPathComponent("src/figcraft")
        try fm.createDirectory(at: f.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: f.appendingPathComponent("web"), withIntermediateDirectories: true)
        for b in ["figcraft-server", "figcraft-cli"] {
            try Data("#!/bin/sh\n".utf8).write(to: f.appendingPathComponent("bin/\(b)"))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.appendingPathComponent("bin/\(b)").path)
        }
        try Data("<html>".utf8).write(to: f.appendingPathComponent("web/index.html"))
        try Data("{\"version\":\"\(version)\"}".utf8).write(to: f.appendingPathComponent("engine.json"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-czf", dir.appendingPathComponent("asset.tar.gz").path, "-C", dir.appendingPathComponent("src").path, "figcraft"]
        try p.run(); p.waitUntilExit()
        let data = try Data(contentsOf: dir.appendingPathComponent("asset.tar.gz"))
        pin = FigcraftPin(version: version, figcraft: "v0.8.0", commit: "c", inputs: "i",
                          url: "https://github.com/ysraelmoreno/collie/releases/download/figcraft-v\(version)/figcraft-\(version)-arm64.tar.gz",
                          size: Int64(data.count), unpackedSize: 1000,
                          sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), teamId: "TEAM123456")
        try JSONEncoder().encode(pin).write(to: pinFile)
    }

    /// The daemon config: this pin, the asset as the download (after `gate`), signatures always good.
    func configure(_ c: inout DaemonConfig, pin: Bool = true, gate: (@Sendable () async throws -> Void)? = nil) {
        c.figcraftPinFile = pin ? pinFile : nil
        let file = file
        c.figcraftFetch = { _, to, progress in
            try await gate?()
            try FileManager.default.copyItem(at: file, to: to)
            progress(1, 1)
        }
        c.figcraftSignatureCheck = { _, _, _ in true }
    }
}

/// A `<root>/figcraft` some older install left (no marker unless `marker`).
private func staleEngine(_ root: URL, version: String, marker: String? = nil) {
    let fm = FileManager.default, e = root.appendingPathComponent("figcraft")
    try? fm.createDirectory(at: e.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: e.appendingPathComponent("web"), withIntermediateDirectories: true)
    for b in ["figcraft-server", "figcraft-cli"] {
        try? Data("#!/bin/sh\n".utf8).write(to: e.appendingPathComponent("bin/\(b)"))
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: e.appendingPathComponent("bin/\(b)").path)
    }
    try? Data("<html>".utf8).write(to: e.appendingPathComponent("web/index.html"))
    try? Data("{\"version\":\"\(version)\"}".utf8).write(to: e.appendingPathComponent("engine.json"))
    if let marker { try? Data(marker.utf8).write(to: e.appendingPathComponent(FigcraftEngine.marker)) }
}

private func admin(_ d: Daemon, _ p: Paths, _ cmd: String) async throws -> Response {
    try await send(p, Request(id: "a", token: d.adminToken, command: cmd), timeoutSeconds: 30)
}
private func obj(_ r: Response) -> [String: JSONValue] { if case .object(let o)? = r.result { o } else { [:] } }

/// Polls `design.engine.status` until the job leaves downloading/verifying/installing.
private func ended(_ d: Daemon, _ p: Paths) async throws -> [String: JSONValue] {
    for _ in 0..<200 {
        let st = obj(try await admin(d, p, "design.engine.status"))
        if case .object(let j)? = st["job"], case .string(let ph)? = j["phase"],
           !["downloading", "verifying", "installing"].contains(ph) { return st }
        try await Task.sleep(for: .milliseconds(50))
    }
    return [:]
}

@Suite struct DesignEngineCommandTests {
    private let names = ["design.engine.status", "design.engine.install", "design.engine.cancel", "design.engine.remove"]

    @Test func terminalIsRefused() async throws {
        let a = try Asset()
        try await withDaemon(configure: { a.configure(&$0) }) { d, p in
            let t = try await spawn(d, p, "W")
            let tok = try await tokenOf(d, t.id)
            for c in names {
                let asTerminal = try await send(p, Request(id: "t", terminalId: t.id, token: tok, command: c))
                #expect(asTerminal.error?.code == .unauthorized, "\(c): \(asTerminal)")
                let noToken = try await send(p, Request(id: "n", command: c))
                #expect(noToken.error?.code == .unauthorized, "\(c)")
            }
            #expect(!FileManager.default.fileExists(atPath: p.root.appendingPathComponent("figcraft").path))
        }
    }

    @Test func notListedInMCP() {
        for c in names {
            #expect(Commands.spec(c)?.exposedToMCP == false, "\(c)")
            #expect(PluginRegistry.command(c) == nil, "\(c)")   // a built-in: its own admin-only route, not the design plug-in's
        }
    }

    @Test func cliParsesEngineCommands() throws {
        for (argv, c) in [(["design", "engine", "status"], "design.engine.status"), (["design", "engine", "install"], "design.engine.install"),
                          (["design", "engine", "remove"], "design.engine.remove")] {
            #expect(try ArgvParser.parse(argv).command == c)
        }
    }

    @Test func statusAbsentWithPin() async throws {
        let a = try Asset()
        try await withDaemon(configure: { a.configure(&$0) }) { d, p in
            let st = obj(try await admin(d, p, "design.engine.status"))
            #expect(st["state"] == .string("absent"), "\(st)")
            #expect(st["pinned"] == .object(["version": .string("0.8.0-c1"), "size": .number(Double(a.pin.size))]), "\(st)")
            #expect(st["installed"] == nil && st["job"] == nil)
        }
    }

    @Test func statusWithoutPinHasNoPinned() async throws {
        let a = try Asset()
        try await withDaemon(configure: { a.configure(&$0, pin: false) }) { d, p in
            let st = obj(try await admin(d, p, "design.engine.status"))
            #expect(st["state"] == .string("absent") && st["pinned"] == nil, "\(st)")
            let r = try await admin(d, p, "design.engine.install")
            #expect(r.error?.code == .unavailable, "\(r)")
        }
    }

    @Test func statusNeedsUpdateWithReinstall() async throws {
        let a = try Asset()
        try await withDaemon(configure: { a.configure(&$0); staleEngine($0.paths.root, version: "0.9.0-c1") }) { d, p in
            let st = obj(try await admin(d, p, "design.engine.status"))
            #expect(st["state"] == .string("needsUpdate"), "\(st)")
            #expect(st["reinstall"] == .bool(true))
            #expect(st["installed"] == .object(["version": .string("0.9.0-c1"), "source": .string("appSupport")]), "\(st)")
        }
    }

    @Test func installThenInstalled() async throws {
        let a = try Asset()
        try await withDaemon(configure: { a.configure(&$0) }) { d, p in
            let r = try await admin(d, p, "design.engine.install")
            guard case .object(let j)? = obj(r)["job"] else { Issue.record("\(r)"); return }
            #expect(j["phase"] == .string("downloading"))
            let st = try await ended(d, p)
            #expect(st["state"] == .string("installed"), "\(st)")
            #expect(st["installed"] == .object(["version": .string("0.8.0-c1"), "source": .string("appSupport")]), "\(st)")
            if case .object(let j)? = st["job"] { #expect(j["phase"] == .string("done")) }
        }
    }

    @Test func removeWithoutAppSupportIsNotFound() async throws {
        let a = try Asset()
        try await withDaemon(configure: { a.configure(&$0) }) { d, p in
            let r = try await admin(d, p, "design.engine.remove")
            #expect(r.error?.code == .notFound, "\(r)")
        }
    }

    @Test func removeStaleEngineWorks() async throws {
        let a = try Asset()
        try await withDaemon(configure: { a.configure(&$0); staleEngine($0.paths.root, version: "0.7.0-c1") }) { d, p in
            let r = try await admin(d, p, "design.engine.remove")
            #expect(r.ok, "\(r)")
            #expect(!FileManager.default.fileExists(atPath: p.root.appendingPathComponent("figcraft").path))
            let st = obj(try await admin(d, p, "design.engine.status"))
            #expect(st["state"] == .string("absent"), "\(st)")
        }
    }

    @Test func removeWhileJobIsBusy() async throws {
        let a = try Asset()
        try await withDaemon(configure: {
            a.configure(&$0, gate: { try await Task.sleep(for: .seconds(30)) })
            staleEngine($0.paths.root, version: "0.7.0-c1")
        }) { d, p in
            let i = try await admin(d, p, "design.engine.install")
            #expect(i.ok, "\(i)")
            let r = try await admin(d, p, "design.engine.remove")
            #expect(r.error?.code == .conflict, "\(r)")
            let c = try await admin(d, p, "design.engine.cancel")
            #expect(c.ok, "\(c)")
            let st = try await ended(d, p)
            if case .object(let j)? = st["job"] { #expect(j["phase"] == .string("cancelled"), "\(st)") }
        }
    }
}
