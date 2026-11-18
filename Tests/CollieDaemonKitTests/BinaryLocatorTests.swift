import Testing
import Foundation
@testable import CollieDaemonKit

/// A temp dir as the user's real home, with `rel/name` an executable (or a symlink to one, like `~/.local/bin/claude`).
private func home() throws -> URL {
    let h = FileManager.default.temporaryDirectory.appendingPathComponent("collie-locator-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
    return h
}
private func executable(_ at: URL) throws {
    try FileManager.default.createDirectory(at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\n".write(to: at, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: at.path)
}

struct BinaryLocatorTests {
    /// The daemon's captured env failed (empty PATH): the known dirs under the REAL home still find it, a symlink too.
    @Test func fallbackFindsSymlinkInRealHome() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h) }
        let target = h.appendingPathComponent(".local/share/claude/versions/2.1.310")
        try executable(target)
        let link = h.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(BinaryLocator.locate("claude", env: [:], home: h.path)?.path == link.path)
        #expect(BinaryLocator.locate("claude", env: ["PATH": ""], home: h.path)?.path == link.path)
        #expect(BinaryLocator.locate("cursor-agent", env: [:], home: h.path) == nil)   // by name, not claude-only
    }

    @Test func pathFirstThenFallbackInOrder() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h) }
        try executable(h.appendingPathComponent("p/tool"))
        try executable(h.appendingPathComponent(".claude/local/tool"))
        try executable(h.appendingPathComponent(".npm-global/bin/tool"))
        #expect(BinaryLocator.locate("tool", env: ["PATH": h.path + "/p"], home: h.path)?.path == h.path + "/p/tool")
        #expect(BinaryLocator.locate("tool", env: [:], home: h.path)?.path == h.path + "/.claude/local/tool")
        #expect(BinaryLocator.dirs(home: "/u") == ["/u/.local/bin", "/u/.claude/local", "/u/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin"])
    }

    /// Not executable, a dangling symlink or a directory named like it: skipped.
    @Test func skipsNonExecutables() throws {
        let h = try home(); defer { try? FileManager.default.removeItem(at: h) }
        let fm = FileManager.default
        try fm.createDirectory(at: h.appendingPathComponent("a/tool"), withIntermediateDirectories: true)
        try fm.createDirectory(at: h.appendingPathComponent("b"), withIntermediateDirectories: true)
        try "x".write(to: h.appendingPathComponent("b/tool"), atomically: false, encoding: .utf8)
        try fm.createDirectory(at: h.appendingPathComponent("c"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: h.appendingPathComponent("c/tool"), withDestinationURL: h.appendingPathComponent("gone"))
        #expect(BinaryLocator.locate("tool", env: [:], fallback: ["a", "b", "c"].map { h.path + "/" + $0 }) == nil)
    }
}
