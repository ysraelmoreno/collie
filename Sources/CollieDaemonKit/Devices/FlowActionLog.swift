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
/// (`<paddock>/.collie/flows/enabled` exists: `collie device flow on`). Folder 0700, files 0600. At 5 MiB the file moves
/// to `actions.1.jsonl` (`.1` to `.2`; 3 files in all: current, .1, .2); a rotation also drops lines older than 30 days.
/// The file is data an app reads (screen names, texts), never instructions.
struct FlowActionLog: Sendable {
    static let textCap = 80, mask = "•••"
    let dir: URL
    var maxBytes = 5 * 1024 * 1024
    var keep = 3
    var maxAge: TimeInterval = 30 * 86_400

    init(paddock: URL) { dir = paddock.appendingPathComponent(".collie/flows") }

    var file: URL { dir.appendingPathComponent("actions.jsonl") }
    private var flag: URL { dir.appendingPathComponent("enabled") }
    private func rotated(_ n: Int) -> URL { n == 0 ? file : dir.appendingPathComponent("actions.\(n).jsonl") }
    var enabled: Bool { FileManager.default.fileExists(atPath: flag.path) }

    func setEnabled(_ on: Bool) throws {
        if on { try makeDir(); try create(flag, Data()) }
        else if enabled { try FileManager.default.removeItem(at: flag) }   // the log stays: the user deletes it
    }

    /// The JSON line for `a` at `now` (no newline). JSONEncoder escapes a newline inside a string, so it stays one line.
    static func line(_ a: FlowAction, at now: Date) throws -> Data {
        var o: [String: String] = ["t": iso(now), "origin": a.origin, "action": a.action, "target": a.target,
                                   "sigBefore": a.sigBefore, "sigAfter": a.sigAfter, "app": a.app, "appVersion": a.appVersion]
        if let t = a.text { o["text"] = a.secure ? mask : String(t.prefix(textCap)) }
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(o)
    }

    /// Writes `a`; false (and nothing created) when the paddock did not opt in.
    @discardableResult
    func append(_ a: FlowAction, now: Date = Date()) throws -> Bool {
        guard enabled else { return false }
        let data = try Self.line(a, at: now) + Data("\n".utf8)
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int, size >= maxBytes { try rotate(now: now) }
        guard let h = FileHandle(forWritingAtPath: file.path) else { try create(file, data); return true }
        defer { try? h.close() }
        try h.seekToEnd(); try h.write(contentsOf: data)
        return true
    }

    /// current → .1 → .2 …; the last one kept falls off. Each kept file loses its lines older than `maxAge`.
    func rotate(now: Date) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: rotated(keep - 1))
        for n in stride(from: keep - 2, through: 0, by: -1) where fm.fileExists(atPath: rotated(n).path) {
            try fm.moveItem(at: rotated(n), to: rotated(n + 1))
        }
        let cutoff = now.addingTimeInterval(-maxAge)
        for n in 1..<keep where fm.fileExists(atPath: rotated(n).path) {
            let kept = try String(contentsOf: rotated(n), encoding: .utf8).split(separator: "\n").filter { l in
                guard let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any],
                      let t = (o["t"] as? String).flatMap(Self.date) else { return false }   // unreadable: dropped
                return t >= cutoff
            }
            if kept.isEmpty { try fm.removeItem(at: rotated(n)); continue }
            try Data((kept.joined(separator: "\n") + "\n").utf8).write(to: rotated(n))
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rotated(n).path)
        }
    }

    /// `device flow status`: {enabled, path, bytes}.
    func status() -> JSONValue {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int ?? 0
        return .object(["enabled": .bool(enabled), "path": .string(file.path), "bytes": .number(Double(size))])
    }

    private func makeDir() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }
    private func create(_ u: URL, _ data: Data) throws {
        guard FileManager.default.createFile(atPath: u.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ProtocolError(code: .internal, message: "não consegui criar \(u.path)")
        }
    }
    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d)
    }
    private static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: s)
    }
}
