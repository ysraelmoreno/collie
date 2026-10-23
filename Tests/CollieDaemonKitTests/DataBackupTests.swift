import Testing
import Foundation
import CollieCore
import CollieProtocol
@testable import CollieDaemonKit

private let fakeServer = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/fake-figcraft-server.sh")

private func tempRoot() -> URL {
    let u = URL(fileURLWithPath: "/tmp/collie-bk-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
private func put(_ root: URL, _ rel: String, _ text: String) {
    let f = root.appendingPathComponent(rel)
    try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: f)
}
private func read(_ root: URL, _ rel: String) -> String? {
    try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
}
private func exists(_ root: URL, _ rel: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path) }

/// A root with every part, plus what must stay out. `tag` marks its content.
private func populate(_ root: URL, _ tag: String, workspace: UUID = UUID()) {
    put(root, "design/files.json", #"[{"tag":"\#(tag)"},{"tag":"\#(tag)2"}]"#)
    put(root, "design/systems.json", #"[{"tag":"\#(tag)"}]"#)
    put(root, "design/server/data.db", tag)
    put(root, "artifacts/artifacts.json", #"[{"a":1},{"a":2},{"a":3}]"#)
    put(root, "artifacts/.removed/old/index.html", tag)
    put(root, "memory/\(tag).md", tag)
    put(root, "workspaces/\(workspace.uuidString)/workspace.json", tag)
    put(root, "workspaces/\(workspace.uuidString)/terminals/spill.log", "scrollback")
    put(root, "work/work.json", tag)
    put(root, "work/work-archive.jsonl", tag)
    put(root, "herds/\(tag).collieherd", tag)
    put(root, "herds/.removed/old-1.collieherd", tag)
    put(root, "lots/l1/memory/\(tag).md", tag)
    put(root, "lots/l1/board.jsonl", tag)
    put(root, "lots/l1/cache/memory.sqlite", "index")
    put(root, "default-workspace", workspace.uuidString)
    for p in ["admin.token", "run/collied.sock.x", "hooks/x.claude.json", "cache/c", "usage/providers/p.json", "screens/s.png"] { put(root, p, "machine") }
}
private func names(_ zip: URL) async throws -> [String] {
    let r = try await BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/zipinfo"), args: ["-1", zip.path],
                                         in: zip.deletingLastPathComponent(), env: [:], timeout: .seconds(30))
    return r.stdout.split(separator: "\n").map(String.init)
}
private func ditto(_ args: [String], in dir: URL) async throws {
    let r = try await BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/ditto"), args: args, in: dir, env: [:], timeout: .seconds(30))
    #expect(r.status == 0, "\(r.stderr)")
}
/// A zip of `dir`'s contents (no parent folder), like an export.
private func zip(_ dir: URL) async throws -> URL {
    let out = dir.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString.prefix(6)).colliebackup")
    try await ditto(["-c", "-k", "--norsrc", dir.path, out.path], in: dir.deletingLastPathComponent())
    return out
}
private func server(_ root: URL) -> FigcraftServer {
    FigcraftServer(binary: fakeServer, dataDir: root.appendingPathComponent("design/server"), runDir: root.appendingPathComponent("run"),
                   port: UInt16.random(in: 52000...58000))
}
private func manifest(_ parts: [String], format: Int = 1) -> String {
    #"{"format":\#(format),"createdAt":"2026-10-24T00:00:00Z","collieVersion":"t","parts":[\#(parts.map { "\"\($0)\"" }.joined(separator: ","))]}"#
}

@Suite struct DataBackupTests {
    @Test func exportHasExpectedParts() async throws {
        let root = tempRoot(), ws = UUID(); defer { try? FileManager.default.removeItem(at: root) }
        populate(root, "A", workspace: ws)
        let out = root.deletingLastPathComponent().appendingPathComponent("collie-bk-\(UUID().uuidString.prefix(8)).colliebackup")
        defer { try? FileManager.default.removeItem(at: out) }
        let s = try await DataBackup.export(root: root, to: out, server: server(root), version: "v-test")
        #expect(s == .init(designs: 2, systems: 1, artifacts: 3))
        let n = Set(try await names(out))
        for p in ["manifest.json", "design/files.json", "design/systems.json", "design/server/data.db", "artifacts/artifacts.json",
                  "artifacts/.removed/old/index.html", "memory/A.md", "workspaces/\(ws.uuidString)/workspace.json",
                  "work/work.json", "work/work-archive.jsonl", "herds/A.collieherd", "herds/.removed/old-1.collieherd",
                  "lots/l1/memory/A.md", "lots/l1/board.jsonl"] {
            #expect(n.contains(p), "\(p) missing: \(n.sorted())")
        }
        for bad in ["admin.token", "default-workspace", "run/", "hooks/", "cache/", "lots/l1/cache", "usage/", "screens/", "/terminals/", ".backup-"] {
            #expect(!n.contains { $0.hasPrefix(bad) || $0.contains(bad) }, "\(bad) leaked: \(n.sorted())")
        }
        let mode = try FileManager.default.attributesOfItem(atPath: out.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let x = tempRoot(); defer { try? FileManager.default.removeItem(at: x) }
        try await ditto(["-x", "-k", out.path, x.path], in: x)
        let m = try JSONSerialization.jsonObject(with: Data(contentsOf: x.appendingPathComponent("manifest.json"))) as? [String: Any]
        #expect(m?["format"] as? Int == 1 && m?["collieVersion"] as? String == "v-test" && m?["createdAt"] is String)
        #expect(Set(m?["parts"] as? [String] ?? []) == ["design", "artifacts", "memory", "workspaces", "work", "herds", "lots"])
        #expect(m?["workspace"] as? String == ws.uuidString)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".backup-") })
    }

    @Test func importReplacesAndKeepsOld() async throws {
        let a = tempRoot(), b = tempRoot(), wa = UUID(), wb = UUID()
        defer { for r in [a, b] { try? FileManager.default.removeItem(at: r) } }
        populate(a, "A", workspace: wa); populate(b, "B", workspace: wb)
        let out = b.appendingPathComponent("b.colliebackup")
        _ = try await DataBackup.export(root: b, to: out, server: server(b), version: "t")
        // dry run: counts only, nothing staged
        #expect(try await DataBackup.stage(root: a, from: out, dryRun: true) == .init(designs: 2, systems: 1, artifacts: 3))
        #expect(!exists(a, ".import-pending"))
        _ = try await DataBackup.stage(root: a, from: out, dryRun: false)
        #expect(read(a, "memory/A.md") == "A")   // staged: applied at the next daemon start
        #expect(DataBackup.applyPending(Paths(root: a)))
        #expect(read(a, "memory/B.md") == "B" && !exists(a, "memory/A.md"))
        #expect(read(a, "design/server/data.db") == "B" && read(a, "work/work.json") == "B")
        #expect(read(a, "workspaces/\(wb.uuidString)/workspace.json") == "B")
        #expect(read(a, "herds/B.collieherd") == "B" && !exists(a, "herds/A.collieherd"))
        #expect(read(a, "herds/.removed/old-1.collieherd") == "B")
        #expect(read(a, "default-workspace") == wb.uuidString)
        #expect(read(a, "admin.token") == "machine" && read(a, "usage/providers/p.json") == "machine")
        #expect(!exists(a, ".import-pending"))
        let old = try #require(try FileManager.default.contentsOfDirectory(atPath: a.path).first { $0.hasPrefix(".replaced-") })
        #expect(read(a, "\(old)/memory/A.md") == "A" && read(a, "\(old)/design/files.json")?.contains("\"A\"") == true)
        #expect(read(a, "\(old)/workspaces/\(wa.uuidString)/workspace.json") == "A")
        #expect(read(a, "\(old)/default-workspace") == wa.uuidString)
        #expect(read(a, "\(old)/herds/A.collieherd") == "A")
        #expect(read(a, "lots/l1/memory/B.md") == "B" && read(a, "\(old)/lots/l1/memory/A.md") == "A")   // lots too, nothing deleted
        #expect(!DataBackup.applyPending(Paths(root: a)))   // nothing pending any more
    }

    /// A lot's memory and board (written by the real stores) survive export → import into a fresh root.
    @Test func lotsRoundTrip() async throws {
        let a = tempRoot(), b = tempRoot(), lot = UUID()
        defer { for r in [a, b] { try? FileManager.default.removeItem(at: r) } }
        let mem = MemoryService(globalDir: a.appendingPathComponent("memory"))
        let rec = MemoryRecord(kind: .decision, scope: .lot, lotId: lot, subject: "css", title: "Use Tailwind", body: "")
        _ = try await mem.lotStore(lot).run { m in try m.store.save(rec) }
        _ = try await mem.lotStore(lot).run { m in m.index() != nil }   // builds lots/<id>/cache
        try await LotBoards(lotsDir: a.appendingPathComponent("lots")).post(LotPost(kind: "handoff", from: "A", text: "tela pronta"), in: lot)
        let out = a.appendingPathComponent("a.colliebackup")
        _ = try await DataBackup.export(root: a, to: out, server: server(a), version: "t")
        #expect(!(try await names(out)).contains { $0.contains("/cache/") })
        _ = try await DataBackup.stage(root: b, from: out, dryRun: false)
        #expect(DataBackup.applyPending(Paths(root: b)))
        let got = try await MemoryService(globalDir: b.appendingPathComponent("memory")).lotStore(lot).run { m in m.store.all().records.map(\.title) }
        #expect(got == ["Use Tailwind"])
        #expect(try await LotBoards(lotsDir: b.appendingPathComponent("lots")).posts(lot).map(\.text) == ["tela pronta"])
    }

    @Test func stagedImportRecheckedAtStart() async throws {
        let a = tempRoot(), b = tempRoot(); defer { for r in [a, b] { try? FileManager.default.removeItem(at: r) } }
        populate(a, "A"); populate(b, "B")
        let out = b.appendingPathComponent("b.colliebackup")
        _ = try await DataBackup.export(root: b, to: out, server: server(b), version: "t")
        _ = try await DataBackup.stage(root: a, from: out, dryRun: false)
        let staged = a.appendingPathComponent(".import-pending/data/memory/link")
        try FileManager.default.createSymbolicLink(atPath: staged.path, withDestinationPath: "/etc/passwd")
        #expect(!DataBackup.applyPending(Paths(root: a)))
        #expect(read(a, "memory/A.md") == "A" && read(a, "design/server/data.db") == "A")
        let names = try FileManager.default.contentsOfDirectory(atPath: a.path)
        #expect(exists(a, ".import-pending") && !names.contains { $0.hasPrefix(".replaced-") })
    }

    @Test func halfAppliedImportResumes() async throws {
        let a = tempRoot(), b = tempRoot(); defer { for r in [a, b] { try? FileManager.default.removeItem(at: r) } }
        populate(a, "A"); populate(b, "B")
        let out = b.appendingPathComponent("b.colliebackup")
        _ = try await DataBackup.export(root: b, to: out, server: server(b), version: "t")
        _ = try await DataBackup.stage(root: a, from: out, dryRun: false)
        // an earlier start applied `memory` and stopped
        let first = a.appendingPathComponent(".replaced-1")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: a.appendingPathComponent("memory"), to: first.appendingPathComponent("memory"))
        try FileManager.default.moveItem(at: a.appendingPathComponent(".import-pending/data/memory"), to: a.appendingPathComponent("memory"))
        #expect(DataBackup.applyPending(Paths(root: a)))
        #expect(read(a, "memory/B.md") == "B" && read(a, "design/server/data.db") == "B" && read(a, "work/work.json") == "B")
        #expect(read(a, ".replaced-1/memory/A.md") == "A" && !exists(a, ".import-pending"))
        let second = try #require(try FileManager.default.contentsOfDirectory(atPath: a.path).first { $0.hasPrefix(".replaced-") && $0 != ".replaced-1" })
        #expect(!exists(a, "\(second)/memory") && read(a, "\(second)/design/server/data.db") == "A")
    }

    @Test func exportRefusesWhatImportWould() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        populate(root, "A")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("memory/link").path, withDestinationPath: "/etc/passwd")
        let out = root.appendingPathComponent("x.colliebackup")
        do { _ = try await DataBackup.export(root: root, to: out, server: server(root), version: "t"); Issue.record("accepted") }
        catch { #expect(error.code == .invalidArgs && error.message.contains("memory/link"), "\(error)") }
        #expect(!exists(root, "x.colliebackup"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasSuffix(".partial") })
    }

    @Test func exportSkipsSpillsAndWritesInFlight() async throws {
        let root = tempRoot(), ws = UUID(); defer { try? FileManager.default.removeItem(at: root) }
        populate(root, "A", workspace: ws)
        // a spill folder is never walked: an odd entry there (a socket, a link) does not refuse the backup
        let spills = root.appendingPathComponent("workspaces/\(ws.uuidString)/terminals")
        try FileManager.default.createSymbolicLink(atPath: spills.appendingPathComponent("link").path, withDestinationPath: "/etc/passwd")
        put(root, "work/.work.json.tmp", "half")   // an atomic write in flight
        put(root, "design/.files.json.tmp", "half")
        put(root, "memory/sub/.a.tmp", "half")   // a nested write in flight keeps its siblings
        for f in ["b", "c", "m", "q", "zz"] { put(root, "memory/sub/\(f)", f) }
        let out = root.appendingPathComponent("x.colliebackup")
        put(root, "x.colliebackup.partial", "the user's")   // a file of the user's next to it is never touched
        _ = try await DataBackup.export(root: root, to: out, server: server(root), work: WorkStore(dir: root.appendingPathComponent("work")),
                                        chat: ChatLog(dir: root.appendingPathComponent("work")), version: "t")
        let n = try await names(out)
        #expect(!n.contains { $0.contains("/terminals") || $0.hasSuffix(".tmp") }, "\(n.sorted())")
        #expect(n.contains("work/work.json") && n.contains("workspaces/\(ws.uuidString)/workspace.json"))
        #expect(["b", "c", "m", "q", "zz"].allSatisfy { n.contains("memory/sub/\($0)") }, "\(n.sorted())")
        #expect(read(root, "x.colliebackup.partial") == "the user's")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".x.colliebackup.") })
    }

    @Test func daemonStartSweepsScratch() async throws {
        try await withDaemon(configure: { c in
            for n in [".backup-\(UUID().uuidString.lowercased())", ".import-\(UUID().uuidString.lowercased())", ".import-pending", ".replaced-1", ".import-mine"] {
                try? FileManager.default.createDirectory(at: c.paths.root.appendingPathComponent(n), withIntermediateDirectories: true)
            }
        }) { d, p in
            let left = try FileManager.default.contentsOfDirectory(atPath: p.root.path).filter { $0.hasPrefix(".") }.sorted()
            #expect(left == [".import-mine", ".import-pending", ".replaced-1"], "\(left)")
        }
    }

    @Test func oneExportAtATime() async throws {
        try await withDaemon { d, p in
            populate(p.root, "A")
            put(p.root, "memory/big.bin", String(repeating: "x", count: 64 << 20))   // the copy takes a while
            let dir = p.root.deletingLastPathComponent()
            let outs = (0..<3).map { _ in dir.appendingPathComponent("collie-bk-\(UUID().uuidString.prefix(8)).colliebackup") }
            defer { for o in outs { try? FileManager.default.removeItem(at: o) } }
            let rs = try await withThrowingTaskGroup(of: Response.self) { g in
                for o in outs {
                    g.addTask { try await send(p, Request(id: "e", token: d.adminToken, command: "admin.data.export", args: ["out": .string(o.path)]),
                                               timeoutSeconds: 120) }
                }
                return try await g.reduce(into: []) { $0.append($1) }
            }
            #expect(rs.filter(\.ok).count >= 1, "\(rs)")
            #expect(rs.contains { $0.error?.code == .unavailable && $0.error?.message == "export in progress" }, "\(rs)")
        }
    }

    @Test func importRefusesBadArchives() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        populate(root, "A")
        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        let work = tempRoot(); defer { try? FileManager.default.removeItem(at: work) }
        func src(_ build: (URL) throws -> Void) async throws -> URL {
            let d = work.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try build(d)
            return try await zip(d)
        }
        var bad: [(String, URL)] = []
        bad.append(("no manifest", try await src { put($0, "memory/x.md", "x") }))
        bad.append(("format 2", try await src { put($0, "manifest.json", manifest(["memory"], format: 2)); put($0, "memory/x.md", "x") }))
        bad.append(("unlisted part", try await src { put($0, "manifest.json", manifest(["memory"])); put($0, "design/x", "x") }))
        bad.append(("unknown part", try await src { put($0, "manifest.json", manifest(["evil"])); put($0, "evil/x", "x") }))
        bad.append(("symlink", try await src {
            put($0, "manifest.json", manifest(["memory"]))
            try FileManager.default.createDirectory(at: $0.appendingPathComponent("memory"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: $0.appendingPathComponent("memory/x").path, withDestinationPath: "/etc/passwd")
        }))
        // `../x`: written as `PP_x` (same length), then renamed inside the zip bytes
        let dot = try await src { put($0, "manifest.json", manifest(["memory"])); put($0, "memory/PP_x", "x") }
        var bytes = try Data(contentsOf: dot)
        while let r = bytes.range(of: Data("PP_x".utf8)) { bytes.replaceSubrange(r, with: Data("../x".utf8)) }
        try bytes.write(to: dot)
        bad.append(("dotdot", dot))
        for (why, z) in bad {
            for dry in [true, false] {
                do { _ = try await DataBackup.stage(root: root, from: z, dryRun: dry); Issue.record("\(why): accepted") }
                catch { #expect(error.code == .invalidArgs, "\(why): \(error)") }
            }
        }
        #expect(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted() == before)
        #expect(!DataBackup.applyPending(Paths(root: root)))
    }

    @Test func terminalsCannotBackup() async throws {
        try await withDaemon { d, p in
            populate(p.root, "A", workspace: UUID())
            let out = p.root.deletingLastPathComponent().appendingPathComponent("collie-bk-\(UUID().uuidString.prefix(8)).colliebackup")
            defer { try? FileManager.default.removeItem(at: out) }
            let (id, r) = try await spawn(d, p, "T")
            #expect(r.ok, "\(r)")
            let tok = try await tokenOf(d, id)
            for (cmd, args) in [("admin.data.export", ["out": JSONValue.string(out.path)]), ("admin.data.import", ["from": .string(out.path)])] {
                let t = try await send(p, Request(id: "1", terminalId: id, token: tok, command: cmd, args: args))
                #expect(t.error?.code == .unauthorized, "\(cmd) \(t)")
            }
            #expect(!FileManager.default.fileExists(atPath: out.path))
            // the app (admin token) can
            let e = try await send(p, Request(id: "2", token: d.adminToken, command: "admin.data.export", args: ["out": .string(out.path)]),
                                   timeoutSeconds: 60)
            #expect(e.ok, "\(e)")
            let i = try await send(p, Request(id: "3", token: d.adminToken, command: "admin.data.import",
                                              args: ["from": .string(out.path), "dryRun": .bool(true)]), timeoutSeconds: 60)
            guard case .object(let o)? = i.result else { Issue.record("\(i)"); return }
            #expect(o["designs"] == .number(2) && o["systems"] == .number(1) && o["artifacts"] == .number(3))
            let s = try await send(p, Request(id: "4", token: d.adminToken, command: "admin.data.import", args: ["from": .string(out.path)]),
                                   timeoutSeconds: 60)
            guard case .object(let so)? = s.result else { Issue.record("\(s)"); return }
            #expect(so["restartNeeded"] == .bool(true))
            #expect(!DataBackup.applyPending(p))   // a live daemon owns the root: applied at its next start, not under it
            #expect(FileManager.default.fileExists(atPath: p.root.appendingPathComponent(".import-pending").path))
        }
    }
}

extension DesignCommandTests {
    @Test func exportPausesServer() async throws {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        populate(root, "A")
        let s = server(root)
        _ = try await s.ensureRunning()
        let out = root.appendingPathComponent("x.colliebackup")
        let seen = Flag()
        _ = try await DataBackup.export(root: root, to: out, server: s, version: "t", paused: {
            let held: Bool
            do { _ = try await s.ensureRunning(); held = false } catch { held = (error as? ProtocolError).map { $0.code == .unavailable && $0.message.contains("backup in progress") } ?? false }
            await seen.set(!(await s.isRunning) && held)
        })
        #expect(await seen.value == true)
        #expect(await s.isRunning)
        // the copy failing (an unreadable file) still restarts it; no half-written backup
        let locked = root.appendingPathComponent("memory/locked.md")
        put(root, "memory/locked.md", "x"); chmod(locked.path, 0)
        defer { chmod(locked.path, 0o600) }
        let out2 = root.appendingPathComponent("y.colliebackup")
        await #expect(throws: ProtocolError.self) {
            try await DataBackup.export(root: root, to: out2, server: s, version: "t")
        }
        #expect(await s.isRunning)
        #expect(!FileManager.default.fileExists(atPath: out2.path))
        await s.stop()
    }
}

private actor Flag { var value: Bool?; func set(_ v: Bool) { value = v } }
