import Foundation

/// U5: the generic ratchet, "the number may only go down" (spec 2026-11-23-fabrica-para-usuarios-design.md, fabrica/u5-catraca.md).
/// Pure: no file, no clock, no process. The daemon (CollieDaemonKit/FactoryCommands.swift) measures; the CLI writes (`BaselineWriter`).
public enum Ratchet {
    public static let maxReason = 200

    public enum Refusal: Error, Sendable, Equatable {
        /// line number (1-based) and the line, cut
        case badLine(Int, String)
        case duplicate(String)
        case badReason
    }

    /// Key (whitespace-separated fields, joined by one space; `rule path`) -> count >= 0. A zero count is the same as absent.
    public struct Baseline: Sendable, Equatable {
        public private(set) var counts: [String: Int]
        public init(_ counts: [String: Int] = [:]) { self.counts = counts.filter { $0.value > 0 } }

        /// Lines `<key fields...> <n>`: the last field is the number. Blank lines and `#` comments are ignored.
        public static func parse(_ text: String) throws(Refusal) -> Baseline {
            var out: [String: Int] = [:]
            for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count >= 2, let n = Int(fields[fields.count - 1]), n >= 0,
                      !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\t" })
                else { throw .badLine(i + 1, String(line.prefix(120))) }
                let key = fields.dropLast().joined(separator: " ")
                guard out[key] == nil else { throw .duplicate(key) }
                out[key] = n
            }
            return Baseline(out)
        }

        /// Sorted by key, one `<key> <n>` per line, zeros left out; parse(render()) == self.
        public func render() -> String {
            counts.keys.sorted().map { "\($0) \(counts[$0]!)\n" }.joined()
        }
    }

    public struct Change: Sendable, Equatable {
        public var key: String, before: Int, after: Int
        public init(key: String, before: Int, after: Int) { self.key = key; self.before = before; self.after = after }
    }

    public enum Verdict: Sendable, Equatable {
        case same
        /// something went down or left: the baseline should be lowered (`update`)
        case improved([Change])
        /// a new key or a bigger number; wins over `improved` and lists only what went up
        case worse([Change])
    }

    public static func compare(baseline: Baseline, current: Baseline) -> Verdict {
        var up: [Change] = [], down: [Change] = []
        for k in Set(baseline.counts.keys).union(current.counts.keys).sorted() {
            let b = baseline.counts[k] ?? 0, c = current.counts[k] ?? 0
            if c > b { up.append(Change(key: k, before: b, after: c)) } else if c < b { down.append(Change(key: k, before: b, after: c)) }
        }
        if !up.isEmpty { return .worse(up) }
        return down.isEmpty ? .same : .improved(down)
    }

    /// The new baseline when nothing went up (then it is `current`); nil when something did: never raised without a reason.
    public static func lowered(baseline: Baseline, current: Baseline) -> Baseline? {
        if case .worse = compare(baseline: baseline, current: current) { return nil }
        return current
    }

    public struct Raised: Sendable, Equatable {
        public var baseline: Baseline
        /// `# <ISO date>: <key> <before> -> <after>: <reason>`, one per key that went up
        public var log: [String]
    }

    /// Raise to `current` with a reason (non-empty, at most 200 characters, no control character). `date` comes in: pure.
    public static func raise(baseline: Baseline, to current: Baseline, reason: String, date: Date) throws(Refusal) -> Raised {
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty, r.count <= maxReason, !r.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw .badReason }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
        let day = f.string(from: date)
        var log: [String] = []
        if case .worse(let up) = compare(baseline: baseline, current: current) {
            log = up.map { "# \(day): \($0.key) \($0.before) -> \($0.after): \(r)" }
        }
        return Raised(baseline: current, log: log)
    }

    /// List mode (`ci-skip`): the list may only shrink; a new item is worse. Each item counts as 1.
    public static func compareList(baseline: [String], current: [String]) -> Verdict {
        func counts(_ l: [String]) -> Baseline { Baseline(l.reduce(into: [:]) { $0[$1, default: 0] += 1 }) }
        return compare(baseline: counts(baseline), current: counts(current))
    }
}

/// F7a: a project's folder opened by fd, component by component from the root with `openat(O_DIRECTORY|O_NOFOLLOW)` (the
/// root itself with `O_NOFOLLOW` too): a link anywhere on the way is refused. One rule for both sides: the daemon reads
/// the baseline through it, the CLI writes through it.
public enum ConfinedDir {
    public struct Failure: Error, Sendable, Equatable { public var message: String; public init(message: String) { self.message = message } }

    /// The project root as a fd (a link as the root is refused). The caller closes it.
    public static func openRoot(_ path: String) throws(Failure) -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure(message: tr("não consegui abrir a raiz do projeto", "could not open the project root")) }
        return fd
    }

    /// The folder of `rel` (its last component is the file) below the open `root` fd, which stays open. The caller closes the result.
    public static func openDir(_ root: Int32, rel: String) throws(Failure) -> Int32 {
        var fd = dup(root)
        guard fd >= 0 else { throw Failure(message: tr("não consegui abrir a raiz do projeto", "could not open the project root")) }
        for c in rel.split(separator: "/").dropLast() {
            let next = openat(fd, String(c), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let e = errno
            close(fd)
            guard next >= 0 else {
                throw Failure(message: e == ENOENT ? tr("a pasta do baseline '\(rel)' não existe", "the baseline folder '\(rel)' does not exist")
                              : tr("a pasta do baseline '\(rel)' não é uma pasta comum (link simbólico?)", "the baseline folder '\(rel)' is not a regular folder (symlink?)"))
            }
            fd = next
        }
        return fd
    }

    /// `openRoot` then `openDir`, the root fd closed.
    public static func openDir(root: String, rel: String) throws(Failure) -> Int32 {
        let r = try openRoot(root)
        defer { close(r) }
        return try openDir(r, rel: rel)
    }

    /// The path the kernel has for an open fd (`F_GETPATH`): what was opened, not what a path string says now.
    public static func path(of fd: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) == 0 else { return nil }
        return String(cString: buf)
    }
}

/// F6a: the baseline file written by the CLI, in the agent's process (so under the agent's own sandbox, which decides what
/// may be written). F7a: the CLI does not trust the daemon's answer: `rel` passes `FactoryProfile.confinedPath` again, the
/// folder is opened by `ConfinedDir` from `root` (no link followed on the way) and the text is at most `maxBytes`.
/// Temporary file in the same folder (`O_CREAT|O_EXCL|O_NOFOLLOW`, 0600), `fchmod` to 0644 (or the old file's mode),
/// `fsync`, `renameat`, `fsync` of the folder; a link or a non-regular file as destination is refused. No temporary is
/// left behind on failure.
public enum BaselineWriter {
    public struct Failure: Error, Sendable, Equatable { public var message: String; public init(message: String) { self.message = message } }
    /// nit 5 (round 4): extra defense; the daemon reads at most 1 MiB of baseline.
    public static let maxBytes = 2 << 20

    public static func write(_ text: String, root: String, rel: String) throws(Failure) {
        guard root.hasPrefix("/"), FactoryProfile.confinedPath(rel), let name = rel.split(separator: "/").last.map(String.init)
        else { throw Failure(message: tr("caminho do baseline inválido: \(rel)", "invalid baseline path: \(rel)")) }
        let bytes = Array(text.utf8)
        guard bytes.count <= maxBytes else { throw Failure(message: tr("o baseline novo passa de \(maxBytes) bytes", "the new baseline is over \(maxBytes) bytes")) }
        let dir: Int32
        do { dir = try ConfinedDir.openDir(root: root, rel: rel) } catch { throw Failure(message: error.message) }
        defer { close(dir) }
        var st = stat(), mode: mode_t = 0o644
        if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            guard st.st_mode & S_IFMT == S_IFREG else { throw Failure(message: tr("\(rel) não é um arquivo regular (link simbólico?)", "\(rel) is not a regular file (symlink?)")) }
            mode = st.st_mode & 0o777
        } else if errno != ENOENT {
            throw Failure(message: tr("não consegui ler \(rel): \(String(cString: strerror(errno)))", "could not read \(rel): \(String(cString: strerror(errno)))"))
        }
        let tmp = ".\(name).\(UUID().uuidString).tmp"
        let fd = openat(dir, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure(message: tr("não consegui gravar o temporário de \(rel): \(String(cString: strerror(errno)))", "could not write the temporary file for \(rel): \(String(cString: strerror(errno)))")) }
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; break }
            off += n
        }
        let synced = off == bytes.count && fchmod(fd, mode) == 0 && fsync(fd) == 0
        close(fd)
        guard synced else { unlinkat(dir, tmp, 0); throw Failure(message: tr("não consegui gravar o temporário de \(rel)", "could not write the temporary file for \(rel)")) }
        // the destination is checked again right before: a link put there meanwhile is refused, not replaced
        if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT != S_IFREG {
            unlinkat(dir, tmp, 0); throw Failure(message: tr("\(rel) não é um arquivo regular (link simbólico?)", "\(rel) is not a regular file (symlink?)"))
        }
        guard renameat(dir, tmp, dir, name) == 0 else {
            let e = errno; unlinkat(dir, tmp, 0)
            throw Failure(message: tr("rename do baseline falhou: \(String(cString: strerror(e)))", "baseline rename failed: \(String(cString: strerror(e)))"))
        }
        fsync(dir)   // nit F (round 3): the rename itself reaches the disk
    }
}
