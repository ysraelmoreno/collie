import Testing
import Foundation
@testable import CollieDaemonKit

/// A temp `<config>/projects/<dir>` (never the real ~/.claude).
private func projects() throws -> (root: URL, projects: URL, dir: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tc-\(UUID().uuidString)").resolvingSymlinksInPath()
    let p = root.appendingPathComponent("projects"), d = p.appendingPathComponent("-Users-x-repo")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return (root, p, d)
}
private func line(_ o: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.withoutEscapingSlashes]), as: UTF8.self) + "\n"
}
private func user(_ text: String) -> String { line(["type": "user", "message": ["role": "user", "content": text]]) }
private func agent(_ text: String) -> String {
    line(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
}
private func write(_ s: String, _ url: URL) throws { try Data(s.utf8).write(to: url) }

@Suite struct TranscriptChunkTests {
    @Test func allowsJsonlUnderProjects() throws {
        let (_, p, d) = try projects()
        let f = d.appendingPathComponent("s.jsonl")
        try write(user("oi"), f)
        #expect(TranscriptChunk.allowed(f.path, projectsDir: p)?.path.hasSuffix("/projects/-Users-x-repo/s.jsonl") == true)
    }

    @Test func refusesOutside() throws {
        let (root, p, _) = try projects()
        #expect(TranscriptChunk.allowed("/etc/passwd", projectsDir: p) == nil)
        let out = root.appendingPathComponent("x.jsonl")
        try write(user("oi"), out)
        #expect(TranscriptChunk.allowed(out.path, projectsDir: p) == nil)
        #expect(TranscriptChunk.allowed(p.path + "/../x.jsonl", projectsDir: p) == nil)
        #expect(TranscriptChunk.allowed("relative.jsonl", projectsDir: p) == nil)
    }

    @Test func refusesSymlinkOut() throws {
        let (root, p, d) = try projects()
        let secret = root.appendingPathComponent("id_ed25519")
        try write("PRIVATE KEY", secret)
        let link = d.appendingPathComponent("s.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        #expect(TranscriptChunk.allowed(link.path, projectsDir: p) == nil)
        // a symlink to a jsonl inside projects is refused too (no-follow)
        let real = d.appendingPathComponent("r.jsonl"); try write(user("oi"), real)
        let l2 = d.appendingPathComponent("l.jsonl")
        try FileManager.default.createSymbolicLink(at: l2, withDestinationURL: real)
        #expect(TranscriptChunk.allowed(l2.path, projectsDir: p) == nil)
        // a symlinked directory leading out
        let outDir = root.appendingPathComponent("out"); try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try write(user("oi"), outDir.appendingPathComponent("s.jsonl"))
        try FileManager.default.createSymbolicLink(at: p.appendingPathComponent("evil"), withDestinationURL: outDir)
        #expect(TranscriptChunk.allowed(p.appendingPathComponent("evil/s.jsonl").path, projectsDir: p) == nil)
        // a fifo or dir named .jsonl
        try FileManager.default.createDirectory(at: d.appendingPathComponent("dir.jsonl"), withIntermediateDirectories: true)
        #expect(TranscriptChunk.allowed(d.appendingPathComponent("dir.jsonl").path, projectsDir: p) == nil)
    }

    @Test func refusesNonJsonl() throws {
        let (_, p, d) = try projects()
        let f = d.appendingPathComponent("s.json")
        try write(user("oi"), f)
        #expect(TranscriptChunk.allowed(f.path, projectsDir: p) == nil)
    }

    @Test func readsOnlyAfterOffset() throws {
        let (_, _, d) = try projects()
        let f = d.appendingPathComponent("s.jsonl"), first = user("antes") + agent("resposta antes")
        try write(first + user("depois") + agent("resposta depois"), f)
        let r = try #require(TranscriptChunk.read(f, from: UInt64(first.utf8.count), secrets: [], maxScalars: 10_000))
        #expect(r.text == "Usuário: depois\n\nAgente: resposta depois")
        #expect(r.userMessages == 1)
        #expect(r.end == UInt64((try Data(contentsOf: f)).count))
    }

    @Test func keepsUserAndAssistantTextOnly() throws {
        let (_, _, d) = try projects()
        let f = d.appendingPathComponent("s.jsonl")
        var s = user("vamos usar Postgres <system-reminder>SEGREDO-LEMBRETE</system-reminder>porque sim")
        s += line(["type": "assistant", "message": ["role": "assistant", "content": [
            ["type": "thinking", "thinking": "PENSAMENTO"], ["type": "tool_use", "name": "Bash", "input": ["command": "TOOL-INPUT"]],
            ["type": "text", "text": "ok"]]]])
        s += line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "TOOL-OUTPUT"]]]])
        s += line(["type": "user", "isMeta": true, "message": ["role": "user", "content": "META-CAVEAT"]])
        s += line(["type": "system", "content": "SYSTEM-LINE"])
        s += line(["type": "user", "message": ["role": "user", "content": "<pasted_content>" + String(repeating: "x", count: 600) + "COLA-FIM</pasted_content>"]])
        s += "{malformed\n"
        try write(s, f)
        let r = try #require(TranscriptChunk.read(f, from: 0, secrets: [], maxScalars: 10_000))
        for bad in ["SEGREDO-LEMBRETE", "PENSAMENTO", "TOOL-INPUT", "TOOL-OUTPUT", "META-CAVEAT", "SYSTEM-LINE", "COLA-FIM"] {
            #expect(!r.text.contains(bad), "\(bad)")
        }
        #expect(r.text.contains("Usuário: vamos usar Postgres porque sim"))
        #expect(r.text.contains("Agente: ok"))
        #expect(r.text.contains(String(repeating: "x", count: 500)))
    }

    @Test func countsUserMessages() throws {
        let (_, _, d) = try projects()
        let f = d.appendingPathComponent("s.jsonl")
        try write(user("um") + agent("a") + line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": "r"]]]])
                  + line(["type": "user", "message": ["role": "user", "content": [["type": "text", "text": "dois"]]]]) + user("três"), f)
        #expect(TranscriptChunk.read(f, from: 0, secrets: [], maxScalars: 10_000)?.userMessages == 3)
    }

    @Test func scrubsSecrets() throws {
        let (_, _, d) = try projects()
        let f = d.appendingPathComponent("s.jsonl")
        try write(user("o token é ADMIN-TOKEN-123 e API_KEY=abc123") + agent("link https://figcraft.local/edit?edit=deadbeef"), f)
        let r = try #require(TranscriptChunk.read(f, from: 0, secrets: ["ADMIN-TOKEN-123"], maxScalars: 10_000))
        #expect(!r.text.contains("ADMIN-TOKEN-123") && !r.text.contains("abc123") && !r.text.contains("deadbeef"))
    }

    @Test func truncatedToNewest() throws {
        let (_, _, d) = try projects()
        let f = d.appendingPathComponent("s.jsonl")
        try write(user("VELHO " + String(repeating: "a", count: 200)) + user("NOVO fim"), f)
        let r = try #require(TranscriptChunk.read(f, from: 0, secrets: [], maxScalars: 50))
        #expect(r.text.unicodeScalars.count <= 50)
        #expect(r.text.hasSuffix("NOVO fim") && !r.text.contains("VELHO"))
        #expect(r.userMessages == 2)
    }

    @Test func shorterThanOffsetResets() throws {
        let (_, _, d) = try projects()
        let f = d.appendingPathComponent("s.jsonl")
        try write(user("reescrito"), f)
        let r = try #require(TranscriptChunk.read(f, from: 1_000_000, secrets: [], maxScalars: 10_000))
        #expect(r.text == "Usuário: reescrito")
    }

    @Test func partialLastLineIgnored() throws {
        let (_, _, d) = try projects()
        let f = d.appendingPathComponent("s.jsonl"), whole = user("completa")
        try write(whole + #"{"type":"user","message":{"role":"user","content":"meia"#, f)
        let r = try #require(TranscriptChunk.read(f, from: 0, secrets: [], maxScalars: 10_000))
        #expect(r.text == "Usuário: completa")
        #expect(r.end == UInt64(whole.utf8.count))
    }
}
