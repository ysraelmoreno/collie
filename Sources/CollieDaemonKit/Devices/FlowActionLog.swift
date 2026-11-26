import Foundation
import CollieProtocol

/// One device action for the flow log (d4, spec docs/superpowers/specs/2026-11-26-device-flows-design.md, onda 2).
/// `secure`: the text went into a password field; it is never written.
struct FlowAction: Sendable, Equatable {
    var origin: String          // "agent:<name>" or "panel"
    var action: String          // tap, text, swipe, key, launch, ...
    var target: String = ""
    var text: String? = nil
    var secure = false
    var sigBefore: String = ""
    var sigAfter: String = ""
    var app: String = ""
    var appVersion: String = ""
}

/// Who acts on the device (`agent:<name>`) and the log of their paddock (d5).
struct FlowRecorder: Sendable { var origin: String; var log: FlowActionLog }

/// Appends one JSON line per action to `<paddock>/.collie/flows/actions.jsonl`, only when the paddock opted in
/// (`collie device flow on`). The opt-in lives in the daemon's own folder (`flag`, `<root>/flows/<paddock id>/enabled`,
/// see `CommandRouter.flowFlag`), never in the worktree, so an agent cannot turn the log on with `touch` (b2). Folder
/// 0700, files 0600. At 5 MiB the file moves to `actions.1.jsonl` (`.1` to `.2`; 3 files in all: current, .1, .2); a
/// rotation also drops lines older than 30 days. The file is data an app reads (screen names, texts), never instructions.
///
/// b2: the worktree is the agent's, so every file is reached through the folder's descriptor (`flows` opened with
/// O_NOFOLLOW, then `openat`/`renameat`/`unlinkat`): a symlink at the folder, `actions.jsonl` or `actions.N.jsonl` is
/// refused, a FIFO does not block (O_NONBLOCK) and anything but a regular file with one link is refused.
/// ponytail: `<paddock>/.collie` itself is followed; a symlink there only moves where a fresh `flows/` is created.
struct FlowActionLog: Sendable {
    static let textCap = 80, targetCap = 200, mask = "•••"
    let dir: URL
    /// The opt-in file, outside the worktree.
    let flag: URL
    var maxBytes = 5 * 1024 * 1024
    /// The most a rotation reads into memory per file. A bigger kept file (an agent can inflate it in its worktree) is
    /// only renamed, never read nor filtered by age; it falls off after `keep` rotations.
    var readCap: Int { 2 * maxBytes }
    var keep = 3
    var maxAge: TimeInterval = 30 * 86_400

    init(paddock: URL, flag: URL) { dir = paddock.appendingPathComponent(".collie/flows"); self.flag = flag }

    var file: URL { dir.appendingPathComponent("actions.jsonl") }
    private func name(_ n: Int) -> String { n == 0 ? "actions.jsonl" : "actions.\(n).jsonl" }
    var enabled: Bool { FileManager.default.fileExists(atPath: flag.path) }

    /// The flag sits in the daemon's folder (trusted), so plain FileManager is fine here.
    func setEnabled(_ on: Bool) throws {
        let fm = FileManager.default
        if on {
            let d = flag.deletingLastPathComponent()
            try fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard fm.createFile(atPath: flag.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                throw ProtocolError(code: .internal, message: "não consegui criar \(flag.path)")
            }
        } else if enabled { try fm.removeItem(at: flag) }   // the log stays: the user deletes it
    }

    /// The JSON line for `a` at `now` (no newline). JSONEncoder escapes a newline inside a string, so it stays one line.
    static func line(_ a: FlowAction, at now: Date) throws -> Data {
        var o: [String: String] = ["t": iso(now), "origin": a.origin, "action": a.action, "target": String(a.target.prefix(targetCap)),
                                   "sigBefore": a.sigBefore, "sigAfter": a.sigAfter, "app": a.app, "appVersion": a.appVersion]
        if let t = a.text { o["text"] = a.secure ? mask : String(t.prefix(textCap)) }
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(o)
    }

    /// Writes `a`; false (and nothing created) when the paddock did not opt in. Throws when the folder or the file is
    /// not what it should be (symlink, FIFO, hard link): the caller logs it, the device action goes on.
    @discardableResult
    func append(_ a: FlowAction, now: Date = Date()) throws -> Bool {
        guard enabled else { return false }
        let data = try Self.line(a, at: now) + Data("\n".utf8)
        let d = try openDir(); defer { close(d) }
        var fd = try openFile(d, name(0), O_WRONLY | O_APPEND | O_CREAT)
        if size(fd) >= maxBytes { close(fd); try rotate(d, now: now); fd = try openFile(d, name(0), O_WRONLY | O_APPEND | O_CREAT) }
        defer { close(fd) }
        try write(fd, data)
        return true
    }

    /// current → .1 → .2 …; the last one kept falls off. Each kept file loses its lines older than `maxAge`, rewritten
    /// through a new temp file renamed over it (atomic, 0600). A kept file that is not a regular one-link file is dropped.
    func rotate(now: Date) throws { let d = try openDir(); defer { close(d) }; try rotate(d, now: now) }

    private func rotate(_ d: Int32, now: Date) throws {
        unlinkat(d, name(keep - 1), 0)
        for n in stride(from: keep - 2, through: 0, by: -1) where renameat(d, name(n), d, name(n + 1)) != 0 && errno != ENOENT {
            throw fail("renameat \(name(n))")
        }
        let cutoff = now.addingTimeInterval(-maxAge)
        for n in 1..<keep {
            guard let fd = try? openFile(d, name(n), O_RDONLY) else { unlinkat(d, name(n), 0); continue }
            if size(fd) > readCap { close(fd); continue }
            let raw = read(fd, max: readCap); close(fd)
            if raw.count > readCap { continue }   // grew after fstat
            let kept = String(decoding: raw, as: UTF8.self).split(separator: "\n").filter { l in
                guard let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any],
                      let t = (o["t"] as? String).flatMap(Self.date) else { return false }   // unreadable: dropped
                return t >= cutoff
            }
            if kept.isEmpty { unlinkat(d, name(n), 0); continue }
            let tmp = name(n) + ".tmp"
            unlinkat(d, tmp, 0)
            let t = try openFile(d, tmp, O_WRONLY | O_CREAT | O_EXCL)
            do { try write(t, Data((kept.joined(separator: "\n") + "\n").utf8)); close(t) } catch { close(t); unlinkat(d, tmp, 0); throw error }
            guard renameat(d, tmp, d, name(n)) == 0 else { unlinkat(d, tmp, 0); throw fail("renameat \(tmp)") }
        }
    }

    /// `device flow status`: {enabled, path, bytes}.
    func status() -> JSONValue {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int ?? 0
        return .object(["enabled": .bool(enabled), "path": .string(file.path), "bytes": .number(Double(size))])
    }

    /// `flows/`, created 0700 when missing; a symlink (or anything but a folder) there is refused.
    private func openDir() throws -> Int32 {
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mkdir(dir.path, 0o700) != 0, errno != EEXIST { throw fail("mkdir \(dir.path)") }
        let d = open(dir.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard d >= 0 else { throw fail("\(dir.path) não é uma pasta (symlink?)") }
        fchmod(d, 0o700)
        return d
    }
    /// `name` in folder `d`, never followed nor blocking; only a regular file with one link passes.
    private func openFile(_ d: Int32, _ name: String, _ flags: Int32) throws -> Int32 {
        let fd = openat(d, name, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw fail("open \(name)") }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 else {
            close(fd); throw ProtocolError(code: .internal, message: "\(name) recusado: não é arquivo regular de um link")
        }
        return fd
    }
    private func size(_ fd: Int32) -> Int { var st = stat(); return fstat(fd, &st) == 0 ? Int(st.st_size) : 0 }
    private func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            var off = 0
            while off < b.count {
                let n = Darwin.write(fd, b.baseAddress! + off, b.count - off)
                if n < 0 { if errno == EINTR { continue }; throw fail("write") }
                off += n
            }
        }
    }
    /// At most `max + 1` bytes, so the caller sees the file went past `max`.
    private func read(_ fd: Int32, max: Int) -> Data {
        var out = Data(), buf = [UInt8](repeating: 0, count: 64 * 1024)
        while out.count <= max {
            let n = Darwin.read(fd, &buf, Swift.min(buf.count, max + 1 - out.count))
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return out }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }
    private func fail(_ what: String) -> ProtocolError {
        ProtocolError(code: .internal, message: "\(what): \(String(cString: strerror(errno)))")
    }
    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d)
    }
    private static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: s)
    }
}
