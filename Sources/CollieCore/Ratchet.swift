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

/// F6a: the baseline file written by the CLI, in the agent's process (so under the agent's own sandbox, which decides what
/// may be written: `.zshenv`, a nested `.git` and the rest are denied by it, no list copied here). The daemon only measures
/// and hands over `path` and the text. Temporary file in the same folder (`O_CREAT|O_EXCL|O_NOFOLLOW`, 0600), `fchmod` to
/// 0644 (or the old file's mode), `fsync`, `renameat`, `fsync` of the folder; a link or a non-regular file as destination is
/// refused. No temporary is left behind on failure.
public enum BaselineWriter {
    public struct Failure: Error, Sendable, Equatable { public var message: String }

    public static func write(_ text: String, to path: String) throws(Failure) {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard path.hasPrefix("/"), !name.isEmpty, name != "/", name != ".", name != ".." else { throw Failure(message: "caminho do baseline inválido: \(path)") }
        let dir = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { throw Failure(message: "não consegui abrir a pasta de \(path): \(String(cString: strerror(errno)))") }
        defer { close(dir) }
        var st = stat(), mode: mode_t = 0o644
        if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            guard st.st_mode & S_IFMT == S_IFREG else { throw Failure(message: "\(path) não é um arquivo regular (link simbólico?)") }
            mode = st.st_mode & 0o777
        } else if errno != ENOENT {
            throw Failure(message: "não consegui ler \(path): \(String(cString: strerror(errno)))")
        }
        let tmp = ".\(name).\(UUID().uuidString).tmp"
        let fd = openat(dir, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure(message: "não consegui gravar o temporário de \(path): \(String(cString: strerror(errno)))") }
        let bytes = Array(text.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; break }
            off += n
        }
        let synced = off == bytes.count && fchmod(fd, mode) == 0 && fsync(fd) == 0
        close(fd)
        guard synced else { unlinkat(dir, tmp, 0); throw Failure(message: "não consegui gravar o temporário de \(path)") }
        // the destination is checked again right before: a link put there meanwhile is refused, not replaced
        if fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT != S_IFREG {
            unlinkat(dir, tmp, 0); throw Failure(message: "\(path) não é um arquivo regular (link simbólico?)")
        }
        guard renameat(dir, tmp, dir, name) == 0 else {
            let e = errno; unlinkat(dir, tmp, 0)
            throw Failure(message: "rename do baseline falhou: \(String(cString: strerror(e)))")
        }
        fsync(dir)   // nit F (round 3): the rename itself reaches the disk
    }
}
