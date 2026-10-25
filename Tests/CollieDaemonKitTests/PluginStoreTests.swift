import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let notas = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples/plugins/notas")
private var fm: FileManager { .default }

/// A temp dir removed afterwards (read-only installed trees made writable first).
private func withTemp(_ body: (URL) async throws -> Void) async throws {
    let d = URL(fileURLWithPath: "/tmp/collie-ps-\(UUID().uuidString.prefix(8))")
    try fm.createDirectory(at: d, withIntermediateDirectories: true)
    defer { PluginStore.removeTree(d) }
    try await body(d)
}
/// A writable copy of notas at `<dir>/<name>`, with its manifest's version (and more) changed.
private func source(_ dir: URL, _ name: String = "src", version: String = "0.1.0", _ edit: (inout [String: Any]) -> Void = { _ in }) throws -> URL {
    let s = dir.appendingPathComponent(name)
    try fm.copyItem(at: notas, to: s)
    let f = s.appendingPathComponent("collie-plugin.json")
    var m = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String: Any]
    m["version"] = version; edit(&m)
    try JSONSerialization.data(withJSONObject: m, options: .sortedKeys).write(to: f)
    return s
}
private func mode(_ u: URL) throws -> Int { (try fm.attributesOfItem(atPath: u.path)[.posixPermissions] as! NSNumber).intValue }
private func code(_ body: () async throws -> Void) async -> ErrorCode? {
    do { try await body(); return nil } catch let e as ProtocolError { return e.code } catch { return .internal }
}

@Suite struct PluginStoreTests {
    @Test func installCopiesReadOnlyAndHashes() async throws {
        try await withTemp { d in
            let root = d.appendingPathComponent("root"), store = PluginStore(root: root)
            let p = try await store.install(from: try source(d))
            #expect(p.id == "notas" && p.version == "0.1.0" && p.enabled && p.error == nil && p.sha256.count == 64)
            let dir = root.appendingPathComponent("plugins/notas/0.1.0")
            #expect(await store.folder(of: "notas") == dir)
            #expect(try String(contentsOf: dir.appendingPathComponent("ui/app.js"), encoding: .utf8).contains("collie.onCommand"))
            #expect(try mode(dir) == 0o555 && mode(dir.appendingPathComponent("ui")) == 0o555)
            #expect(try mode(dir.appendingPathComponent("ui/index.html")) == 0o444 && mode(dir.appendingPathComponent("LICENSE")) == 0o444)
            #expect(try mode(root.appendingPathComponent("plugins/installed.json")) == 0o600)
            #expect(await store.loaded().map(\.0.id) == ["notas"])
            // the hash is the tree's: same content, same hash
            let again = try await PluginStore(root: d.appendingPathComponent("root2")).install(from: try source(d, "src2"))
            #expect(again.sha256 == p.sha256)
            // a fresh store (daemon restart) reads it back, verified
            #expect(await PluginStore(root: root).loaded().map(\.1.sha256) == [p.sha256])
        }
    }

    @Test func installRefusesSymlink() async throws {
        try await withTemp { d in
            let s = try source(d)
            try fm.createSymbolicLink(atPath: s.appendingPathComponent("ui/secret").path, withDestinationPath: "/etc/hosts")
            let store = PluginStore(root: d.appendingPathComponent("root"))
            #expect(await code { _ = try await store.install(from: s) } == .invalidArgs)
            #expect(await store.list().isEmpty)
            #expect(((try? fm.contentsOfDirectory(atPath: d.appendingPathComponent("root/plugins").path)) ?? []).filter { $0 != "installed.json" }.isEmpty)
        }
    }

    @Test func installRefusesOver64MiB() async throws {
        try await withTemp { d in
            let s = try source(d)
            let big = s.appendingPathComponent("ui/big.bin")
            fm.createFile(atPath: big.path, contents: nil)
            let h = try FileHandle(forWritingTo: big); try h.truncate(atOffset: 64 * 1024 * 1024 + 1); try h.close()   // sparse
            let store = PluginStore(root: d.appendingPathComponent("root"))
            #expect(await code { _ = try await store.install(from: s) } == .invalidArgs)
            #expect(await store.list().isEmpty)
        }
    }

    @Test func installRefusesOutsideFile() async throws {
        try await withTemp { d in
            try "x".write(to: d.appendingPathComponent("outside.html"), atomically: true, encoding: .utf8)
            let store = PluginStore(root: d.appendingPathComponent("root"))
            for ui in ["../outside.html", "ui/../../outside.html", d.appendingPathComponent("outside.html").path] {
                let s = try source(d, "s-\(UUID().uuidString.prefix(4))") { $0["ui"] = ui }
                #expect(await code { _ = try await store.install(from: s) } == .invalidArgs, "\(ui)")
            }
            #expect(await store.list().isEmpty)
        }
    }

    @Test func reinstallNewVersionSwapsAtomically() async throws {
        try await withTemp { d in
            let root = d.appendingPathComponent("root"), store = PluginStore(root: root)
            let old = try await store.install(from: try source(d, "a", version: "0.1.0"))
            let new = try await store.install(from: try source(d, "b", version: "0.2.0") { $0["name"] = "Notas 2" })
            #expect(new.version == "0.2.0" && new.sha256 != old.sha256)
            #expect(await store.list().map(\.version) == ["0.2.0"])
            #expect(await store.loaded().map(\.0.name) == ["Notas 2"])
            #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("plugins/notas").path) == ["0.2.0"])   // old one gone, no leftovers
            // same version again: replaced in place
            _ = try await store.install(from: try source(d, "c", version: "0.2.0"))
            #expect(await store.loaded().map(\.0.name) == ["Notas"])
            #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("plugins/notas").path) == ["0.2.0"])
            #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("plugins").path).sorted() == ["installed.json", "notas"])
        }
    }

    @Test func failedInstallKeepsOld() async throws {
        try await withTemp { d in
            let root = d.appendingPathComponent("root"), store = PluginStore(root: root)
            let old = try await store.install(from: try source(d, "a", version: "0.1.0"))
            let bad = try source(d, "b", version: "0.2.0") { $0["helper"] = "bin/x" }
            #expect(await code { _ = try await store.install(from: bad) } == .invalidArgs)
            let link = try source(d, "c", version: "0.2.0")
            try fm.createSymbolicLink(atPath: link.appendingPathComponent("l").path, withDestinationPath: "/tmp")
            #expect(await code { _ = try await store.install(from: link) } == .invalidArgs)
            #expect(await store.list().map(\.sha256) == [old.sha256])
            #expect(await store.loaded().map(\.0.version) == ["0.1.0"])
            #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("plugins/notas").path) == ["0.1.0"])
            #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("plugins").path).sorted() == ["installed.json", "notas"])
            #expect(await PluginStore(root: root).loaded().map(\.0.version) == ["0.1.0"])
        }
    }

    @Test func loadDisablesChangedFolder() async throws {
        try await withTemp { d in
            let root = d.appendingPathComponent("root"), store = PluginStore(root: root)
            _ = try await store.install(from: try source(d))
            let js = root.appendingPathComponent("plugins/notas/0.1.0/ui/app.js")
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: js.path)
            try "fetch('https://x')".write(to: js, atomically: false, encoding: .utf8)
            let restarted = PluginStore(root: root)
            #expect(await restarted.loaded().isEmpty)
            #expect(await restarted.folder(of: "notas") == nil)
            let e = try #require(await restarted.list().first)
            #expect(e.error == "conteúdo alterado desde a instalação; instale de novo")
            #expect(await code { try await restarted.setEnabled("notas", true) } == .invalidArgs)
            // the changed one is skipped; the others still load
            _ = try await restarted.install(from: try source(d, "k") { $0["id"] = "kanban"; $0["events"] = [] })
            #expect(await PluginStore(root: root).loaded().map(\.0.id) == ["kanban"])
        }
    }

    @Test func enableDisable() async throws {
        try await withTemp { d in
            let root = d.appendingPathComponent("root"), store = PluginStore(root: root)
            _ = try await store.install(from: try source(d))
            try await store.setEnabled("notas", false)
            #expect(await store.loaded().isEmpty); #expect(await store.list().map(\.enabled) == [false])
            #expect(await PluginStore(root: root).loaded().isEmpty)   // persisted
            try await store.setEnabled("notas", true)
            #expect(await store.loaded().map(\.0.id) == ["notas"])
            #expect(await code { try await store.setEnabled("nope", true) } == .notFound)
        }
    }

    @Test func uninstallRemovesFolderAndEntry() async throws {
        try await withTemp { d in
            let root = d.appendingPathComponent("root"), store = PluginStore(root: root)
            _ = try await store.install(from: try source(d))
            try await store.uninstall("notas")
            #expect(await store.list().isEmpty); #expect(await store.loaded().isEmpty)
            #expect(!fm.fileExists(atPath: root.appendingPathComponent("plugins/notas").path))
            #expect(await PluginStore(root: root).list().isEmpty)
            #expect(await code { try await store.uninstall("notas") } == .notFound)
            // an edited installed.json naming a path outside plugins/ is dropped, never followed
            let victim = d.appendingPathComponent("victim"); try fm.createDirectory(at: victim, withIntermediateDirectories: true)
            try #"[{"id":"../../victim","version":"0.1.0","sha256":"x","enabled":true,"installedAt":"2026-01-01T00:00:00Z"}]"#
                .write(to: root.appendingPathComponent("plugins/installed.json"), atomically: true, encoding: .utf8)
            let edited = PluginStore(root: root)
            #expect(await edited.list().isEmpty)
            #expect(await code { try await edited.uninstall("../../victim") } == .notFound)
            #expect(fm.fileExists(atPath: victim.path))
        }
    }

    /// Review 1: one entry this build can't read is skipped, kept verbatim through later writes, never empties the list.
    @Test func badEntryKeptVerbatim() async throws {
        try await withTemp { d in
            let root = d.appendingPathComponent("root"), file = root.appendingPathComponent("plugins/installed.json")
            _ = try await PluginStore(root: root).install(from: try source(d))
            var rows = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
            rows.append(["id": "future", "version": "9.0.0", "newKey": ["x": 1]])   // no sha256 etc.: undecodable here
            try JSONSerialization.data(withJSONObject: rows).write(to: file)
            let store = PluginStore(root: root)
            #expect(await store.list().map(\.id) == ["notas"])
            #expect(await store.loaded().map(\.0.id) == ["notas"])
            _ = try await store.install(from: try source(d, "k") { $0["id"] = "kanban"; $0["events"] = [] })
            let after = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
            #expect(after.compactMap { $0["id"] as? String }.sorted() == ["future", "kanban", "notas"])
            #expect(after.first { $0["id"] as? String == "future" }?["newKey"] != nil)
            #expect(await PluginStore(root: root).list().map(\.id) == ["kanban", "notas"])
            // a file that isn't a list at all is kept aside, never overwritten
            try "{oops".write(to: file, atomically: true, encoding: .utf8)
            let broken = PluginStore(root: root)
            #expect(await broken.list().isEmpty)
            #expect(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("plugins").path).contains { $0.hasPrefix("installed.json.unreadable-") })
        }
    }

    /// Review 2: the copy itself holds the caps (a source that grows after a scan can't fill the disk).
    @Test func copyEnforcesCaps() async throws {
        try await withTemp { d in
            let s = try source(d), dst = d.appendingPathComponent("dst")
            let big = s.appendingPathComponent("ui/big.bin")
            fm.createFile(atPath: big.path, contents: nil)
            let h = try FileHandle(forWritingTo: big); try h.truncate(atOffset: 64 * 1024 * 1024 + 1); try h.close()
            #expect(throws: ProtocolError.self) { try PluginStore.copyTree(s, to: dst) }
            try fm.removeItem(at: big)
            let many = d.appendingPathComponent("many"); try fm.createDirectory(at: many, withIntermediateDirectories: true)
            for i in 0...5000 { fm.createFile(atPath: many.appendingPathComponent("f\(i)").path, contents: nil) }
            #expect(throws: ProtocolError.self) { try PluginStore.copyTree(many, to: d.appendingPathComponent("dst2")) }
            try fm.removeItem(at: many); try fm.removeItem(at: d.appendingPathComponent("dst2"))
            try fm.createSymbolicLink(atPath: s.appendingPathComponent("ui/l").path, withDestinationPath: "/etc/hosts")
            #expect(throws: ProtocolError.self) { try PluginStore.copyTree(s, to: d.appendingPathComponent("dst3")) }
            try fm.removeItem(at: s.appendingPathComponent("ui/l"))
            try PluginStore.copyTree(s, to: d.appendingPathComponent("dst4"))
            #expect(try PluginStore.scan(d.appendingPathComponent("dst4")) == PluginStore.scan(s))
        }
    }

    /// R7 (M6): a directory swapped for a link after the walk can't bring outside files in (the opened file must be
    /// inside the source).
    @Test func copyFileRefusesLinkedParent() async throws {
        try await withTemp { d in
            let s = try source(d), outside = d.appendingPathComponent("outside")
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            try "secret".write(to: outside.appendingPathComponent("k"), atomically: false, encoding: .utf8)
            try fm.createSymbolicLink(atPath: s.appendingPathComponent("swapped").path, withDestinationPath: outside.path)
            try fm.createDirectory(at: d.appendingPathComponent("dst"), withIntermediateDirectories: true)
            var budget = PluginStore.maxBytes
            #expect(throws: ProtocolError.self) {
                try PluginStore.copyFile(s.appendingPathComponent("swapped/k").path, d.appendingPathComponent("dst/k").path, "swapped/k",
                                         inside: SignedAppCheck.realPath(s), budget: &budget)
            }
            #expect(!fm.fileExists(atPath: d.appendingPathComponent("dst/k").path))
        }
    }

    @Test(.timeLimit(.minutes(2))) func adminOnly() async throws {
        try await PluginRegistry.exclusively { () async throws in
        try await withDaemon { d, p in
            let src = try source(p.root, "src")
            let a = try await spawn(d, p, "A")
            let tok = try await tokenOf(d, a.id)
            for (cmd, args) in [("plugin.install", ["path": src.path]), ("plugin.uninstall", ["id": "notas"]),
                                ("plugin.enable", ["id": "notas"]), ("plugin.disable", ["id": "notas"])] {
                let r = try await send(p, Request(id: "t", terminalId: a.id, token: tok, command: cmd, args: args.mapValues { .string($0) }))
                #expect(r.error?.code == .unauthorized, "\(cmd): \(r)")
            }
            #expect(try await send(p, Request(id: "t", token: "nope", command: "plugin.install", args: ["path": .string(src.path)])).error?.code == .unauthorized)
            let ok = try await send(p, Request(id: "i", token: d.adminToken, command: "plugin.install", args: ["path": .string(src.path)]), timeoutSeconds: 60)
            #expect(ok.ok, "\(ok)")
            #expect(try await send(p, Request(id: "t", terminalId: a.id, token: tok, command: "plugin.uninstall", args: ["id": .string("notas")])).error?.code == .unauthorized)
            #expect(try await send(p, Request(id: "u", token: d.adminToken, command: "plugin.disable", args: ["id": .string("notas")])).ok)
            #expect(try await send(p, Request(id: "u", token: d.adminToken, command: "plugin.uninstall", args: ["id": .string("notas")])).ok)   // read-only tree: withDaemon can't remove it
        }
        }
    }

    @Test(.timeLimit(.minutes(2))) func specsReadableByTerminal() async throws {
        try await PluginRegistry.exclusively { () async throws in
        try await withDaemon { d, p in
            let src = try source(p.root, "src")
            #expect(try await send(p, Request(id: "i", token: d.adminToken, command: "plugin.install", args: ["path": .string(src.path)]), timeoutSeconds: 60).ok)
            let a = try await spawn(d, p, "A")
            let tok = try await tokenOf(d, a.id)
            for cmd in ["plugin.specs", "plugin.list"] {
                let r = try await send(p, Request(id: "s", terminalId: a.id, token: tok, command: cmd))
                #expect(r.ok, "\(cmd): \(r)")
                let text = String(decoding: try JSONEncoder().encode(r.result), as: UTF8.self)
                #expect(text.contains("notas") && text.contains("export"), "\(cmd): \(text)")
                #expect(!text.contains(p.root.path) && !text.contains("/tmp") && !text.contains("/Users"), "\(cmd): \(text)")
            }
            // the specs decode back to the manifests (what collie and collie mcp turn into commands)
            let r = try await send(p, Request(id: "s", terminalId: a.id, token: tok, command: "plugin.specs"))
            guard case .object(let o)? = r.result, let list = o["plugins"] else { Issue.record("\(r)"); return }
            let ms = try JSONDecoder().decode([PluginManifest].self, from: JSONEncoder().encode(list))
            #expect(ms.map { $0.pluginSpec().commands.map(\.name) } == [["notas.add", "notas.list", "notas.export"]])
            #expect(try await send(p, Request(id: "s", terminalId: a.id, token: "bad", command: "plugin.list")).error?.code == .unauthorized)
            #expect(try await send(p, Request(id: "u", token: d.adminToken, command: "plugin.uninstall", args: ["id": .string("notas")])).ok)
        }
        }
    }
}
