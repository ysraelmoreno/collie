import Testing
import Foundation
import CryptoKit
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let notas = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples/plugins/notas")
private let key = Curve25519.Signing.PrivateKey()
private let pub = key.publicKey.rawRepresentation.base64EncodedString()
private var fm: FileManager { .default }
private func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

private func withTemp(_ body: (URL) async throws -> Void) async throws {
    let d = URL(fileURLWithPath: "/tmp/collie-pcs-\(UUID().uuidString.prefix(8))")
    try fm.createDirectory(at: d, withIntermediateDirectories: true)
    defer { PluginStore.removeTree(d) }
    try await body(d)
}

private func tar(_ args: [String], in dir: URL) throws {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); p.arguments = args; p.currentDirectoryURL = dir
    p.standardError = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    #expect(p.terminationStatus == 0)
}

/// notas at `version` (optionally changed by `edit`), packed as `<dir>/notas-<version>.tar.gz` holding `notas/`.
private struct Pkg { var data: Data, tree: String, url: URL }
private func pack(_ d: URL, version: String, _ edit: (URL) throws -> Void = { _ in }) throws -> Pkg {
    let parent = d.appendingPathComponent("build-\(version)-\(UUID().uuidString.prefix(4))"), s = parent.appendingPathComponent("notas")
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    try fm.copyItem(at: notas, to: s)
    let f = s.appendingPathComponent("collie-plugin.json")
    var m = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String: Any]
    m["version"] = version
    try JSONSerialization.data(withJSONObject: m, options: .sortedKeys).write(to: f)
    try edit(s)
    let tree = (try? PluginStore.treeHash(s, PluginStore.scan(s))) ?? ""
    let out = d.appendingPathComponent("notas-\(version)-\(UUID().uuidString.prefix(4)).tar.gz")
    try tar(["-czf", out.path, "-C", parent.path, "notas"], in: d)
    return Pkg(data: try Data(contentsOf: out), tree: tree,
               url: URL(string: "https://github.com/ysraelmoreno/collie/releases/download/plugin-notas-v\(version)/notas-\(version).tar.gz")!)
}

private func version(_ p: Pkg, _ v: String, sha: String? = nil, tree: String? = nil, team: String? = nil,
                     recalled: [String: Any]? = nil) -> [String: Any] {
    var o: [String: Any] = ["version": v, "url": p.url.absoluteString, "sha256": sha ?? hex(p.data), "size": p.data.count,
                            "treeSha256": tree ?? p.tree]
    if let team { o["helperTeamId"] = team }
    if let recalled { o["recalled"] = recalled }
    return o
}
private func catalog(_ versions: [[String: Any]], sequence: Int = 1, generatedAt: Date = Date()) -> (Data, Data) {
    let c: [String: Any] = [
        "format": 1, "generatedAt": ISO8601DateFormatter().string(from: generatedAt), "sequence": sequence,
        "plugins": [["id": "notas", "name": "Notas", "publisher": "collie", "summary": "s", "kind": "panel", "minCollie": "0.1.0",
                     "versions": versions]],
        "publishers": [["id": "collie", "name": "Collie", "reviewedBy": "collie"]],
    ]
    let data = (try? JSONSerialization.data(withJSONObject: c)) ?? Data()
    return (data, (try? key.signature(for: data)) ?? Data())
}

/// The fake network: the catalog bytes to serve (nil: offline) and packages by URL.
private actor Net {
    var catalog: (Data, Data)?
    var packages: [URL: Data] = [:]
    var gate: CheckedContinuation<Void, Never>?, waiting: CheckedContinuation<Void, Never>?
    var hold = false
    func set(_ c: (Data, Data)?) { catalog = c }
    func add(_ p: Pkg) { packages[p.url] = p.data }
    func holdNext() { hold = true }
    /// Resumes once a held download is waiting.
    func held() async { if gate != nil { return }; await withCheckedContinuation { waiting = $0 } }
    func release() { gate?.resume(); gate = nil }
    func serve(_ url: URL, _ to: URL, _ limit: Int64) async throws {
        if hold {
            hold = false
            await withCheckedContinuation { c in gate = c; waiting?.resume(); waiting = nil }
        }
        guard let d = packages[url] else { throw ProtocolError(code: .unavailable, message: "404") }
        guard Int64(d.count) <= limit else { throw ProtocolError(code: .unavailable, message: AndroidDownload.tooLarge) }
        try d.write(to: to)
    }
    func fetch() -> AnyFetch { AnyFetch(net: self) }
}
private struct AnyFetch: Sendable {
    let net: Net
    var value: PluginCatalogService.Fetch {
        let net = net
        return .init(catalog: {
            guard let c = await net.catalog else { throw ProtocolError(code: .unavailable, message: "sem rede") }
            return c
        }, package: { u, to, limit in try await net.serve(u, to, limit) })
    }
}

private func service(_ root: URL, _ net: Net, store: PluginStore? = nil, now: @escaping @Sendable () -> Date = Date.init) async -> (PluginCatalogService, PluginStore) {
    let s = store ?? PluginStore(root: root)
    return (PluginCatalogService(root: root, store: s, fetch: await net.fetch().value, keys: [pub], collie: "1.0.0", now: now), s)
}
private func refusal(_ body: () async throws -> Void) async -> ProtocolError? {
    do { try await body(); return nil } catch let e as ProtocolError { return e } catch { return nil }
}
/// What is left in `<root>/plugins` besides the store's and the catalog's own files.
private func leftovers(_ root: URL) -> [String] {
    ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("plugins").path)) ?? [])
        .filter { !["installed.json", "catalog.json", "catalog.json.sig"].contains($0) }.sorted()
}

@Suite(.daemonPt) struct PluginCatalogServiceTests {
    @Test func installsFromCatalog() async throws {
        try await withTemp { d in
            let root = d.appendingPathComponent("root"), net = Net(), p = try pack(d, version: "0.1.0")
            await net.add(p); await net.set(catalog([version(p, "0.1.0")]))
            let (svc, store) = await service(root, net)
            #expect(await svc.current(refresh: true).state == .ok)
            let e = try await svc.install(id: "notas", version: "0.1.0")
            #expect(e.source == .catalog && e.sha256 == p.tree && e.enabled)
            #expect(await store.loaded().map(\.0.id) == ["notas"])
            #expect(leftovers(root) == ["notas"])
            #expect(try (fm.attributesOfItem(atPath: root.appendingPathComponent("plugins/catalog.json").path)[.posixPermissions] as! NSNumber).intValue == 0o600)
        }
    }

    @Test func refusesShaMismatch() async throws {
        try await withTemp { d in
            let root = d.appendingPathComponent("root"), net = Net(), p = try pack(d, version: "0.1.0")
            await net.add(p); await net.set(catalog([version(p, "0.1.0", sha: String(repeating: "0", count: 64))]))
            let (svc, store) = await service(root, net)
            _ = await svc.current(refresh: true)
            #expect(await refusal { _ = try await svc.install(id: "notas", version: "0.1.0") }?.message.contains("sha256") == true)
            #expect(await store.list().isEmpty && leftovers(root).isEmpty)
        }
    }

    @Test func refusesTreeMismatch() async throws {
        try await withTemp { d in
            let root = d.appendingPathComponent("root"), net = Net(), p = try pack(d, version: "0.1.0")
            await net.add(p); await net.set(catalog([version(p, "0.1.0", tree: String(repeating: "c", count: 64))]))
            let (svc, store) = await service(root, net)
            _ = await svc.current(refresh: true)
            #expect(await refusal { _ = try await svc.install(id: "notas", version: "0.1.0") }?.message.contains("treeSha256") == true)
            #expect(await store.list().isEmpty && leftovers(root).isEmpty)
        }
    }

    @Test func refusesTraversal() async throws {
        try await withTemp { d in
            // `../evil` and an absolute path kept in the archive (-P), and a symlink inside the folder
            let src = d.appendingPathComponent("t/notas"), evil = d.appendingPathComponent("evil")
            try fm.createDirectory(at: src.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: notas, to: src)
            try "x".write(to: evil, atomically: false, encoding: .utf8)
            let dotdot = d.appendingPathComponent("dotdot.tar.gz"), abs = d.appendingPathComponent("abs.tar.gz")
            try tar(["-czPf", dotdot.path, "notas", "../evil"], in: src.deletingLastPathComponent())
            try tar(["-czPf", abs.path, evil.path], in: d)
            let link = try pack(d, version: "0.1.0") { s in
                try fm.createSymbolicLink(atPath: s.appendingPathComponent("ui/secret").path, withDestinationPath: "/etc/hosts")
            }
            for (name, data) in [("dotdot", try Data(contentsOf: dotdot)), ("abs", try Data(contentsOf: abs)), ("link", link.data)] {
                let root = d.appendingPathComponent("root-\(name)"), net = Net()
                let p = Pkg(data: data, tree: String(repeating: "a", count: 64), url: link.url)
                await net.add(p); await net.set(catalog([version(p, "0.1.0")]))
                let (svc, store) = await service(root, net)
                _ = await svc.current(refresh: true)
                let r = await refusal { _ = try await svc.install(id: "notas", version: "0.1.0") }
                #expect(r?.code == .invalidArgs, "\(name): \(r?.message ?? "aceito")")
                #expect(await store.list().isEmpty && leftovers(root).isEmpty, "\(name)")
            }
            #expect(try String(contentsOf: evil, encoding: .utf8) == "x")
        }
    }

    @Test func interruptedDownloadLeavesNothing() async throws {
        try await withTemp { d in
            let root = d.appendingPathComponent("root"), net = Net()
            let p1 = try pack(d, version: "0.1.0"), p2 = try pack(d, version: "0.2.0")
            await net.add(p1)   // p2 is never served: the download fails after the staging exists
            await net.set(catalog([version(p1, "0.1.0"), version(p2, "0.2.0")]))
            let (svc, store) = await service(root, net)
            _ = await svc.current(refresh: true)
            _ = try await svc.install(id: "notas", version: "0.1.0")
            #expect(await refusal { _ = try await svc.install(id: "notas", version: "0.2.0") }?.code == .unavailable)
            #expect(leftovers(root) == ["notas"])
            #expect(await store.loaded().map(\.1.version) == ["0.1.0"])
            #expect(fm.fileExists(atPath: root.appendingPathComponent("plugins/notas/0.1.0/collie-plugin.json").path))
        }
    }

    @Test func secondInstallRefused() async throws {
        try await withTemp { d in
            let root = d.appendingPathComponent("root"), net = Net(), p = try pack(d, version: "0.1.0")
            await net.add(p); await net.set(catalog([version(p, "0.1.0")]))
            let (svc, _) = await service(root, net)
            _ = await svc.current(refresh: true)
            await net.holdNext()
            let first = Task { try await svc.install(id: "notas", version: "0.1.0") }
            await net.held()
            let r = await refusal { _ = try await svc.install(id: "notas", version: "0.1.0") }
            #expect(r?.code == .conflict && r?.message == "já instalando notas")
            await net.release()
            #expect(try await first.value.version == "0.1.0")
        }
    }

    @Test func offlineUsesStored() async throws {
        try await withTemp { d in
            let root = d.appendingPathComponent("root"), net = Net(), p = try pack(d, version: "0.1.0")
            await net.add(p); await net.set(catalog([version(p, "0.1.0")]))
            let (svc, _) = await service(root, net)
            _ = await svc.current(refresh: true)
            _ = try await svc.install(id: "notas", version: "0.1.0")
            // a recalling catalog was stored (as by a download that ended before its recalls ran), then the network went
            let (data, sig) = catalog([version(p, "0.1.0", recalled: ["reason": "ruim", "at": "2026-12-01T00:00:00Z"])], sequence: 2)
            try data.write(to: root.appendingPathComponent("plugins/catalog.json"))
            try sig.write(to: root.appendingPathComponent("plugins/catalog.json.sig"))
            await net.set(nil)
            let store2 = PluginStore(root: root)
            #expect(await store2.loaded().map(\.0.id) == ["notas"])
            let (svc2, _) = await service(root, net, store: store2)
            await svc2.applyStored()
            #expect(await store2.list()[0].recalled?.reason == "ruim")
            #expect(await store2.loaded().isEmpty)
            let c = await svc2.current(refresh: true)
            #expect(c.state == .ok && c.catalog?.sequence == 2 && c.reason?.contains("sem rede") == true)
        }
    }

    @Test func refusedCatalogKeepsStored() async throws {
        try await withTemp { d in
            let root = d.appendingPathComponent("root"), net = Net(), p = try pack(d, version: "0.1.0")
            await net.set(catalog([version(p, "0.1.0")], sequence: 5))
            let (svc, _) = await service(root, net)
            #expect(await svc.current(refresh: true).state == .ok)
            await net.set(catalog([version(p, "0.1.0")], sequence: 4))   // an older one served again
            let older = await svc.current(refresh: true)
            #expect(older.state == .unavailable && older.reason?.contains("sequence") == true && older.catalog?.sequence == 5)
            let (data, good) = catalog([version(p, "0.1.0")], sequence: 6); var sig = good; sig[0] ^= 1   // a bad signature
            await net.set((data, sig))
            let bad = await svc.current(refresh: true)
            #expect(bad.state == .unavailable && bad.reason?.contains("assinatura") == true && bad.catalog?.sequence == 5)
        }
    }

    @Test func dailyRefreshRecalls() async throws {
        try await withTemp { d in
            let root = d.appendingPathComponent("root"), net = Net(), p = try pack(d, version: "0.1.0")
            await net.add(p); await net.set(catalog([version(p, "0.1.0")]))
            let (svc, store) = await service(root, net)
            _ = await svc.current(refresh: true)
            _ = try await svc.install(id: "notas", version: "0.1.0")
            await net.set(catalog([version(p, "0.1.0", recalled: ["reason": "vaza", "at": "2026-12-01T00:00:00Z"])], sequence: 2))
            await svc.dailyRefresh()
            let e = await store.list()[0]
            #expect(!e.enabled && e.recalled?.reason == "vaza")
            #expect(await refusal { _ = try await svc.install(id: "notas", version: "0.1.0") }?.code == .conflict)
        }
    }

    @Test func staleState() async throws {
        try await withTemp { d in
            let root = d.appendingPathComponent("root"), net = Net(), p = try pack(d, version: "0.1.0")
            await net.set(catalog([version(p, "0.1.0")], generatedAt: Date().addingTimeInterval(-31 * 86400)))
            let (svc, _) = await service(root, net)
            let c = await svc.current(refresh: true)
            #expect(c.state == .stale && c.catalog != nil)
        }
    }

    @Test func helperNeedsTeam() async throws {
        try await withTemp { d in
            let p = try pack(d, version: "0.1.0") { s in
                let f = s.appendingPathComponent("collie-plugin.json")
                var m = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String: Any]
                m["helper"] = "bin/notas"; m["hooks"] = ["edit"]; m["permissions"] = ["project": "read"]
                try JSONSerialization.data(withJSONObject: m, options: .sortedKeys).write(to: f)
                try fm.createDirectory(at: s.appendingPathComponent("bin"), withIntermediateDirectories: true)
                try "#!/bin/sh\n".write(to: s.appendingPathComponent("bin/notas"), atomically: false, encoding: .utf8)
                chmod(s.appendingPathComponent("bin/notas").path, 0o755)
            }
            for team: String? in ["AG8JQAH6YB", nil] {   // unsigned helper; helper without a team in the catalog
                let root = d.appendingPathComponent("root-\(team ?? "none")"), net = Net()
                await net.add(p); await net.set(catalog([version(p, "0.1.0", team: team)]))
                let (svc, store) = await service(root, net)
                _ = await svc.current(refresh: true)
                #expect(await refusal { _ = try await svc.install(id: "notas", version: "0.1.0") }?.message.contains("assinatura do time") == true)
                #expect(await store.list().isEmpty && leftovers(root).isEmpty)
            }
        }
    }
}
