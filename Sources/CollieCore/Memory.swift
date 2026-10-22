import Foundation
import CollieProtocol

public enum MemoryKind: String, Codable, Sendable { case decision, map, pitfall }
public enum MemoryScope: String, Codable, Sendable { case project, paddock, global }
public enum MemoryStatus: String, Codable, Sendable { case active, superseded, archived, discarded }

public struct MemoryRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: MemoryKind
    public var scope: MemoryScope
    public var paddock: String?          // paddock name when scope == .paddock
    public var subject: String         // supersession-chain key (normalized: lowercase, collapsed spaces)
    public var title: String
    public var body: String
    public var path: String?           // .map only: relative to repo root
    public var status: MemoryStatus
    public var reviewed: Bool
    public var pinned: Bool
    public var supersedes: UUID?
    public var supersededBy: UUID?
    public var origin: String          // "<terminal> (<preset>)" or "app"
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: UUID = UUID(), kind: MemoryKind, scope: MemoryScope = .project, paddock: String? = nil, subject: String,
                title: String, body: String = "", path: String? = nil, status: MemoryStatus = .active,
                reviewed: Bool = false, pinned: Bool = false, supersedes: UUID? = nil, supersededBy: UUID? = nil,
                origin: String = "app", createdAt: Date = Date(), updatedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.scope = scope; self.paddock = paddock
        self.subject = MemoryRecord.normalize(subject); self.title = title; self.body = body; self.path = path
        self.status = status; self.reviewed = reviewed; self.pinned = pinned
        self.supersedes = supersedes; self.supersededBy = supersededBy; self.origin = origin
        // ms precision: matches the on-disk format so a reloaded record == the in-memory one.
        func ms(_ d: Date) -> Date { Date(timeIntervalSince1970: (d.timeIntervalSince1970 * 1000).rounded() / 1000) }
        self.createdAt = ms(createdAt); self.updatedAt = ms(updatedAt ?? createdAt)
    }
    /// Lowercase, whitespace runs collapsed to one space, trimmed.
    public static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public enum MemoryFile {
    // Fixed key order: git diffs stay minimal.
    public static func render(_ r: MemoryRecord) -> String {
        var l = ["id: \(r.id.uuidString.lowercased())", "kind: \(r.kind.rawValue)", "scope: \(r.scope.rawValue)"]
        if let f = r.paddock { l.append("paddock: \(str(f))") }
        l.append("subject: \(str(r.subject))"); l.append("title: \(str(r.title))")
        if let p = r.path { l.append("path: \(str(p))") }
        l.append("status: \(r.status.rawValue)"); l.append("reviewed: \(r.reviewed)"); l.append("pinned: \(r.pinned)")
        if let s = r.supersedes { l.append("supersedes: \(s.uuidString.lowercased())") }
        if let s = r.supersededBy { l.append("superseded_by: \(s.uuidString.lowercased())") }
        l.append("origin: \(str(r.origin))")
        l.append("created: \(iso(r.createdAt))"); l.append("updated: \(iso(r.updatedAt))")
        return "---\n" + l.joined(separator: "\n") + "\n---\n\n" + r.body + "\n"
    }

    public static func parse(_ text: String) throws(ProtocolError) -> MemoryRecord {
        func bad(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: "memory file: \(m)") }
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { throw bad("missing frontmatter") }
        func marker(_ ls: ArraySlice<String>) -> Bool { ls.contains { $0.hasPrefix("<<<<<<<") || $0.hasPrefix(">>>>>>>") } }
        // Frontmatter: any marker. Body: only the full <<<<<<< ... ======= ... >>>>>>> triple (a body may quote one line).
        let bodyLines = lines[(end + 1)...]
        if marker(lines[1..<end]) { throw bad("merge conflict markers") }
        if let a = bodyLines.firstIndex(where: { $0.hasPrefix("<<<<<<<") }),
           let m = bodyLines[a...].firstIndex(where: { $0.hasPrefix("=======") }),
           bodyLines[m...].contains(where: { $0.hasPrefix(">>>>>>>") }) { throw bad("merge conflict markers") }
        var kv: [String: String] = [:]
        for line in lines[1..<end] where !line.isEmpty {
            guard let c = line.firstIndex(of: ":") else { throw bad("bad line '\(line)'") }
            kv[String(line[..<c])] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        // a file written before the herding vocabulary: `scope: floor` and `floor: <name>` (read, never rewritten here)
        if kv["scope"] == "floor" { kv["scope"] = MemoryScope.paddock.rawValue }
        if kv["paddock"] == nil, let f = kv["floor"] { kv["paddock"] = f }
        func req(_ k: String) throws(ProtocolError) -> String {
            guard let v = kv[k] else { throw bad("missing '\(k)'") }
            return v
        }
        func field(_ k: String) throws(ProtocolError) -> String { try unstr(try req(k), k) }
        func unstr(_ v: String, _ k: String) throws(ProtocolError) -> String {
            guard v.hasPrefix("\"") else { return v }
            guard let d = v.data(using: .utf8), let s = try? JSONDecoder().decode(String.self, from: d) else { throw bad("bad string '\(k)'") }
            return s
        }
        func uuid(_ v: String, _ k: String) throws(ProtocolError) -> UUID {
            guard let u = UUID(uuidString: v) else { throw bad("bad uuid '\(k)'") }
            return u
        }
        func enm<T: RawRepresentable>(_ k: String, _ d: T? = nil) throws(ProtocolError) -> T where T.RawValue == String {
            guard let v = kv[k] else { if let d { return d }; throw bad("missing '\(k)'") }
            guard let e = T(rawValue: v) else { throw bad("bad '\(k)'") }
            return e
        }
        func flag(_ k: String) throws(ProtocolError) -> Bool {
            switch kv[k] { case nil, "false": return false; case "true": return true; default: throw bad("bad '\(k)'") }
        }
        func date(_ k: String) throws(ProtocolError) -> Date {
            guard let d = isoDate(try req(k)) else { throw bad("bad date '\(k)'") }
            return d
        }
        var body = lines[(end + 1)...].joined(separator: "\n")
        if body.hasPrefix("\n") { body.removeFirst() }
        if body.hasSuffix("\n") { body.removeLast() }
        let created = try date("created")
        var paddock: String?, path: String?, supersedes: UUID?, supersededBy: UUID?
        if let v = kv["paddock"] { paddock = try unstr(v, "paddock") }
        if let v = kv["path"] { path = try unstr(v, "path") }
        if let v = kv["supersedes"] { supersedes = try uuid(v, "supersedes") }
        if let v = kv["superseded_by"] { supersededBy = try uuid(v, "superseded_by") }
        return MemoryRecord(
            id: try uuid(try req("id"), "id"), kind: try enm("kind"), scope: try enm("scope", MemoryScope.project),
            paddock: paddock, subject: try field("subject"), title: try field("title"),
            body: body, path: path, status: try enm("status", MemoryStatus.active),
            reviewed: try flag("reviewed"), pinned: try flag("pinned"),
            supersedes: supersedes,
            supersededBy: supersededBy,
            origin: try field("origin"), createdAt: created, updatedAt: try date("updated"))
    }

    /// "<kind>/<slug(subject) up to 48>-<id 8 hex>.md"; slug is [a-z0-9-] only.
    public static func fileName(_ r: MemoryRecord) -> String {
        var slug = ""
        for ch in r.subject.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber { slug.append(ch) } else if slug.last != "-" { slug.append("-") }
        }
        slug = String(slug.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.isEmpty { slug = "memory" }
        return "\(r.kind.rawValue)/\(slug)-\(r.id.uuidString.lowercased().prefix(8)).md"
    }

    // Plain when safe, otherwise a JSON string.
    private static func str(_ s: String) -> String {
        let plain = !s.isEmpty && s == s.trimmingCharacters(in: .whitespaces)
            && !s.contains(where: { ":#\"\\".contains($0) || $0.isNewline })
        if plain { return s }
        let e = JSONEncoder(); e.outputFormatting = .withoutEscapingSlashes
        return (try? e.encode(s)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
    private static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
