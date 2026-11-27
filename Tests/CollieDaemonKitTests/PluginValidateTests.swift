import Testing
import Foundation
import CollieProtocol
@testable import CollieDaemonKit

private let notas = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Examples/plugins/notas")
private var fm: FileManager { .default }

/// A writable copy of notas in a temp dir (removed afterwards), its manifest edited by `edit`.
private func withPlugin(_ edit: (inout [String: Any]) -> Void = { _ in }, _ body: (URL) async throws -> Void) async throws {
    let d = URL(fileURLWithPath: "/tmp/collie-pv-\(UUID().uuidString.prefix(8))")
    try fm.createDirectory(at: d, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: d) }
    let s = d.appendingPathComponent("notas")
    try fm.copyItem(at: notas, to: s)
    let f = s.appendingPathComponent("collie-plugin.json")
    var m = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as? [String: Any])
    edit(&m)
    try JSONSerialization.data(withJSONObject: m, options: .sortedKeys).write(to: f)
    try await body(s)
}
private func helper(_ m: inout [String: Any]) { m["helper"] = "bin/notas"; m["hooks"] = ["edit"] }
private func signed(_ identifier: String) -> PluginTree.Signature { { _ in ("ABCDE12345", identifier) } }

@Suite struct PluginValidateTests {
    @Test func goodFolderPasses() async throws {
        try await withPlugin { p in
            let r = await PluginTree.validate(p)
            #expect(r.problems.isEmpty && r.team == nil)
        }
    }

    @Test func linkIsRefused() async throws {
        try await withPlugin { p in
            try fm.createSymbolicLink(atPath: p.appendingPathComponent("ui/x.html").path, withDestinationPath: "/etc/hosts")
            let r = await PluginTree.validate(p)
            #expect(r.problems.contains { $0.contains("ui/x.html") && $0.contains("link") })
        }
    }

    @Test func networkMustBeEmpty() async throws {
        try await withPlugin({ $0["permissions"] = ["network": ["example.com"]] }) { p in
            let r = await PluginTree.validate(p)
            #expect(r.problems.contains { $0.contains("permissions.network") })
        }
        try await withPlugin({ $0["permissions"] = ["network": [String]()] }) { p in
            #expect(await PluginTree.validate(p).problems.isEmpty)
        }
    }

    @Test func helperMustBeMachO() async throws {
        try await withPlugin(helper) { p in
            try fm.createDirectory(at: p.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: p.appendingPathComponent("bin/notas"))
            let r = await PluginTree.validate(p, signature: signed("dev.collie.plugin.notas"))
            #expect(r.problems.contains { $0.contains("Mach-O") } && r.team == nil)
        }
    }

    /// A real Mach-O signed by Apple, not by a Developer ID: the real check refuses it.
    @Test func unsignedHelperIsRefused() async throws {
        try await withPlugin(helper) { p in
            try fm.createDirectory(at: p.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try fm.copyItem(atPath: "/usr/bin/true", toPath: p.appendingPathComponent("bin/notas").path)
            let r = await PluginTree.validate(p)
            #expect(r.problems.contains { $0.contains("sem assinatura Developer ID") } && r.team == nil)
        }
    }

    @Test func signedHelperGivesTeamAndChecksIdentifier() async throws {
        try await withPlugin(helper) { p in
            try fm.createDirectory(at: p.appendingPathComponent("bin"), withIntermediateDirectories: true)
            try fm.copyItem(atPath: "/usr/bin/true", toPath: p.appendingPathComponent("bin/notas").path)
            let ok = await PluginTree.validate(p, signature: signed("dev.collie.plugin.notas"))
            #expect(ok.problems.isEmpty && ok.team == "ABCDE12345")
            let wrong = await PluginTree.validate(p, signature: signed("com.example.notas"))
            #expect(wrong.problems.contains { $0.contains("dev.collie.plugin.notas") })
        }
    }
}
