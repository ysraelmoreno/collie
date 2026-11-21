import Foundation
import CollieCore

/// M10.1: the handoff a loop leaves when it ends, `<root>/handoff/<paddock id>.md` (one per paddock, overwritten, 0600 in
/// a 0700 dir, at most `maxBytes`): the work, its tasks (done/deferred), short shas, the decisions and pitfalls saved
/// since the loop started (titles and ids, never a body) and the next wave when the repo's roadmap has its file. Only what
/// the daemon already holds; a new Shepherd session reads it with `collie work handoff`.
/// Decision (M10.1): named by the paddock's id, not its name: a name may hold any character, an id is always a safe name.
enum Handoff {
    static let maxBytes = 4096
    static let none = "Não há passagem de turno neste cercado: ela é gravada quando um laço termina."

    struct Memory: Equatable, Sendable { var id: UUID; var kind: MemoryKind; var title: String }

    static func file(root: URL, paddock: UUID) -> URL {
        root.appendingPathComponent("handoff/\(paddock.uuidString.lowercased()).md")
    }

    static func text(_ w: Work, memories: [Memory], nextWave: String?, now: Date = Date()) -> String {
        let ran = w.tasks.filter { t in w.loop?.tasks?.contains(t.id) ?? true }
        let done = ran.filter { $0.state == .done }, deferred = ran.filter { $0.state == .deferred }
        let how = w.loop?.stopReason.map { "parou (\(RerailText.clean($0.label)))" } ?? "terminou"
        let iso = ISO8601DateFormatter()
        var lines = ["# Passagem de turno",
                     "Trabalho «\(RerailText.clean(w.title))» [\(w.id.uuidString.lowercased())]: o laço \(how) em \(iso.string(from: w.loop?.endedAt ?? now)), "
                        + "\(done.count) feitas, \(deferred.count) adiadas. Estado: collie work status; resumo: collie work history --id <id>."]
        if let n = nextWave { lines.append("Próxima onda prevista: \(RerailText.clean(n, max: 200))") }
        // short shas only: a commit subject is agent text
        var seen = Set<String>()
        let shas = done.flatMap { $0.evidence?.commits ?? [] }.compactMap { $0.split(separator: " ").first.map(String.init) }
            .filter { (4...40).contains($0.count) && $0.allSatisfy(\.isHexDigit) && seen.insert($0).inserted }
        if !shas.isEmpty { lines.append("Commits: " + shas.prefix(30).joined(separator: " ")) }
        if !ran.isEmpty { lines.append("## Tarefas") }
        lines += done.map { WorkStatusText.doneLine($0) ?? "✓ \(RerailText.clean($0.title)) · marcada à mão, sem check" }
        lines += deferred.map { "– \(RerailText.clean($0.title)) · adiada: \(RerailText.clean($0.reason ?? $0.lastFailure ?? "sem razão registrada", max: 200))" }
        if !memories.isEmpty { lines.append("## Memória nova (só títulos; o corpo: collie memory get <id>)") }
        lines += memories.map { m in
            "\(m.kind == .pitfall ? "armadilha" : "decisão") \(String(m.id.uuidString.prefix(8)).lowercased()): \(RerailText.clean(m.title, max: 160))"
        }
        return bounded(lines)
    }

    /// Lines joined up to `maxBytes` UTF-8 bytes; the cut ends with "… e mais <n>".
    static func bounded(_ lines: [String]) -> String {
        var out = ""
        for (i, l) in lines.enumerated() {
            let tail = "\n… e mais \(lines.count - i)\n"
            if out.utf8.count + l.utf8.count + 1 + tail.utf8.count > maxBytes { return out + tail }
            out += l + "\n"
        }
        return out
    }

    /// "Onda <n+1> (<path>)" when `title` names "Onda <n>" and `<repo>/docs/superpowers/roadmap/*/onda<n+1>*.md` exists.
    static func nextWave(title: String, repoRoot: URL) -> String? {
        guard let r = title.range(of: #"[Oo]nda (\d+)"#, options: .regularExpression),
              let n = Int(title[r].dropFirst(5)) else { return nil }
        let roadmap = repoRoot.appendingPathComponent("docs/superpowers/roadmap"), fm = FileManager.default
        for dir in ((try? fm.contentsOfDirectory(atPath: roadmap.path)) ?? []).sorted() {
            for f in ((try? fm.contentsOfDirectory(atPath: roadmap.appendingPathComponent(dir).path)) ?? []).sorted()
            where f == "onda\(n + 1).md" || (f.hasPrefix("onda\(n + 1)-") && f.hasSuffix(".md")) {
                return "Onda \(n + 1) (docs/superpowers/roadmap/\(dir)/\(f))"
            }
        }
        return nil
    }

    /// Writes `text` to `url` (a temp file renamed over it), 0600 in a 0700 dir. false: it could not be written.
    @discardableResult
    static func write(_ text: String, to url: URL) -> Bool {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir.path, 0o700)
        let tmp = dir.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { return false }
        guard rename(tmp.path, url.path) == 0 else { unlink(tmp.path); return false }
        return true
    }
}

extension CommandRouter {
    /// M10.1: the handoff of `w`'s loop, written for `paddock`. The memories are the paddock repo's decisions and pitfalls
    /// created since the loop started (titles only). Never fails the loop's end.
    func writeHandoff(_ w: Work, paddock: UUID) async {
        let p = ws.paddocks.first(where: { $0.id == paddock })
        var mems: [Handoff.Memory] = []
        if let p, !p.isFolder, let since = w.loop?.startedAt {
            let repo = await memory.repo(for: p.repoRoot)
            let name = p.name
            mems = (try? await repo.run { m in
                m.store.all().records.filter {
                    $0.status == .active && [.decision, .pitfall].contains($0.kind) && $0.createdAt >= since
                        && MemoryService.visible($0, paddock: name, lot: nil)
                }.sorted { $0.createdAt < $1.createdAt }.map { Handoff.Memory(id: $0.id, kind: $0.kind, title: $0.title) }
            }) ?? []
        }
        let next = p.flatMap { $0.isFolder ? nil : Handoff.nextWave(title: w.title, repoRoot: URL(fileURLWithPath: $0.repoRoot)) }
        let text = Handoff.text(w, memories: mems, nextWave: next)
        if !Handoff.write(text, to: Handoff.file(root: config.paths.root, paddock: paddock)) { memoryLog("handoff: not written") }
    }
}
