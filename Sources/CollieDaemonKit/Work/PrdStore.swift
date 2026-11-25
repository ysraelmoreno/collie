import Foundation
import CryptoKit
import CollieCore
import CollieProtocol

/// F5, `collie work prd add`: the work's PRD, a markdown text the owner's CLI read from its file. The daemon knows no
/// Jira, Linear nor GitHub: `origin` is opaque text, shown in the summaries and in the work's notes (its audit), never
/// fetched. The text is kept immutable in the work's own folder (`<root>/work-loops/<work>/prd/<sha256>.md`, created
/// with `O_EXCL`, 0444); the work's state keeps the hash. The same hash again changes nothing; other content needs
/// `replace`, and the previous file stays (the state lists it before the new one).
enum PrdStore {
    static let folder = "prd", originMax = 200, maxBytes = 1 << 20

    enum Outcome: String { case added, same, replaced }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// The work's PRD folder under the daemon's root.
    static func dir(root: URL, work: UUID) -> URL {
        root.appendingPathComponent("work-loops").appendingPathComponent(work.uuidString.lowercased()).appendingPathComponent(folder)
    }
    static func file(_ dir: URL, _ sha: String) -> URL { dir.appendingPathComponent("\(sha).md") }

    /// Why `--origin` is refused (already trimmed); nil: taken. Not empty, at most 200 characters, no control character.
    static func originRefusal(_ o: String) -> String? {
        if o.isEmpty { return "está vazia" }
        if o.count > originMax { return "tem mais de \(originMax) caracteres" }
        if o.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return "tem caractere de controle" }
        return nil
    }

    /// `text` kept in `dir` given `current` (the work's `prd`): the work's new list and what happened. Throws the refusal.
    static func add(_ text: String, origin: String?, replace: Bool, dir: URL, current: [WorkPrd], at: Date) throws(ProtocolError) -> (prd: [WorkPrd], outcome: Outcome) {
        func invalid(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: m) }
        let data = Data(text.utf8)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("o PRD está vazio") }
        guard data.count <= maxBytes else { throw invalid("o PRD tem \(data.count) bytes; o limite é \(maxBytes)") }
        if let origin, let why = originRefusal(origin) { throw invalid("--origin " + why) }
        let sha = sha256(data)
        if let last = current.last {
            // the same content again: nothing changes (its first origin stays: the record is immutable)
            if last.sha256 == sha { try keep(data, sha, in: dir); return (current, .same) }
            guard replace else {
                throw invalid("o trabalho já tem um PRD com outro conteúdo (sha256 \(last.sha256.prefix(12))); use --replace para trocá-lo (o anterior fica guardado)")
            }
        }
        try keep(data, sha, in: dir)
        return (current + [WorkPrd(sha256: sha, origin: origin, addedAt: at, bytes: data.count)], current.isEmpty ? .added : .replaced)
    }

    /// `data` as `dir/<sha>.md`, created new (`O_EXCL`, never through a link) and 0444; already there, it must still
    /// hash to its name (a changed file is an error, never rewritten). A failed write unlinks the partial file.
    static func keep(_ data: Data, _ sha: String, in dir: URL) throws(ProtocolError) {
        func fail(_ m: String) -> ProtocolError { ProtocolError(code: .internal, message: "prd: " + m) }
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw fail("cannot create \(dir.path)") }
        let url = file(dir, sha)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o444)
        guard fd >= 0 else {
            guard errno == EEXIST else { throw fail("cannot write \(url.path)") }
            guard let old = read(url), sha256(old) == sha else { throw fail("\(url.path) was changed: its content no longer has its hash") }
            return
        }
        defer { close(fd) }
        fchmod(fd, 0o444)   // the umask cannot widen it, but make it exact
        let ok = data.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Bool in
            guard let base = p.baseAddress else { return false }
            var off = 0
            while off < p.count {
                let n = write(fd, base + off, p.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                if n == 0 { return false }
                off += n
            }
            return true
        }
        guard ok else { unlink(url.path); throw fail("cannot write \(url.path)") }
    }

    /// A kept file (a regular file, never through a link); nil: not readable.
    static func read(_ url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        return try? h.readToEnd() ?? Data()
    }

    /// The audit line the work's notes keep for a PRD added or replaced.
    static func note(_ p: WorkPrd, outcome: Outcome) -> String {
        "[prd] " + (outcome == .replaced ? "PRD trocado" : "PRD guardado") + ": sha256 \(p.sha256), \(p.bytes) bytes"
            + (p.origin.map { ", origem: \(RerailText.clean($0, max: originMax))" } ?? ", sem origem")
    }

    /// The owner's line of a work's PRD and plan (`work status`, the auto-land summary); nil: neither.
    static func line(_ w: Work) -> String? {
        guard w.prd?.last != nil || w.plan != nil else { return nil }
        var s = w.prd?.last.map { p in
            "PRD: sha256 \(p.sha256.prefix(12))" + (p.origin.map { " · origem: \(RerailText.clean($0, max: originMax))" } ?? " · sem origem")
                + ((w.prd?.count ?? 0) > 1 ? " · \((w.prd?.count ?? 1) - 1) anterior(es) guardado(s)" : "")
        } ?? "PRD: nenhum"
        if let pl = w.plan { s += " · plano \(pl.sha256.prefix(12)) aplicado (\(pl.tasks.count) tarefas)" }
        return s
    }
}
