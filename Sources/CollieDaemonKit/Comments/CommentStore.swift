import Foundation
import CryptoKit
import CollieCore
import CollieProtocol

/// The page a comment is pinned to: a kept artifact, or an HTML file of a project (the root is stored real).
enum PageRef: Codable, Sendable, Hashable {
    case artifact(UUID)
    case project(root: String, path: String)

    /// The page's file name in `<root>/comments/`: `artifact-<uuid>` or `page-<16 hex of SHA-256(real root + "\0" + path)>`.
    var key: String {
        switch self {
        case .artifact(let id): return "artifact-\(id.uuidString.lowercased())"
        case .project(let root, let path):
            let real = DiagramFile.real(URL(fileURLWithPath: root)).path
            let h = SHA256.hash(data: Data((real + "\0" + path).utf8)).map { String(format: "%02x", $0) }.joined()
            return "page-\(h.prefix(16))"
        }
    }

    private enum K: String, CodingKey { case artifact, root, path }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        if let a = try c.decodeIfPresent(UUID.self, forKey: .artifact) { self = .artifact(a); return }
        self = .project(root: try c.decode(String.self, forKey: .root), path: try c.decode(String.self, forKey: .path))
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self)
        switch self {
        case .artifact(let a): try c.encode(a, forKey: .artifact)
        case .project(let root, let path): try c.encode(root, forKey: .root); try c.encode(path, forKey: .path)
        }
    }
}

/// Where on the page: a CSS path, the point as fractions of the document (0…1) and the element's text (≤ 80 chars).
struct CommentAnchor: Codable, Sendable, Equatable {
    var selector: String?
    var x: Double
    var y: Double
    var text: String?
    init(selector: String?, x: Double, y: Double, text: String?) {
        func unit(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }
        self.selector = selector; self.x = unit(x); self.y = unit(y); self.text = text.map { String($0.prefix(80)) }
    }
}

/// `byTerminal` nil: the user ("você").
struct CommentMessage: Codable, Sendable, Equatable {
    var id: UUID
    var byTerminal: UUID?
    var byName: String
    var body: String
    var at: Date
}

/// A thread pinned to a point. `to`: the addressee terminal, fixed at creation; `delivered`: the user messages already
/// injected into its prompts.
struct PageComment: Codable, Sendable, Equatable {
    var id: UUID
    var to: UUID?
    var toName: String?
    var anchor: CommentAnchor
    var messages: [CommentMessage]
    var resolved: Bool
    var delivered: Set<UUID>
    var short: String { String(id.uuidString.lowercased().prefix(8)) }
}

/// Comments in Collie data, never in the project: `<dir>/<page key>.json` (0600, dir 0700), one file per page
/// `{page, title, comments}`. Only the daemon writes here, so a sandboxed agent cannot forge a user comment.
actor CommentStore {
    static let maxUserBody = 2_000, maxReply = 4_000, maxComments = 500, maxMessages = 200, maxSelector = 1_000, maxTitle = 200

    struct PageFile: Codable, Sendable { var page: PageRef; var title: String; var comments: [PageComment] }

    private let dir: URL
    // ponytail: every page loaded on first use and each one rewritten whole on change; fine at ≤ 500 comments a page.
    // Per-page lazy loading if the dir grows large.
    private var pages: [String: PageFile]?
    private var index: [UUID: String] = [:]   // comment id -> page key

    init(dir: URL) { self.dir = dir }

    private func all() -> [String: PageFile] {
        if let pages { return pages }
        var out: [String: PageFile] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            // R2: a malformed file is skipped (and logged), never an error for the others
            guard let d = try? Data(contentsOf: f), let p = try? JSONDecoder().decode(PageFile.self, from: d) else {
                memoryLog("comments: skipped \(f.lastPathComponent)"); continue
            }
            out[p.page.key] = p
            for c in p.comments { index[c.id] = p.page.key }
        }
        pages = out
        return out
    }

    private func save(_ p: PageFile) throws(ProtocolError) {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        guard let d = try? enc.encode(p) else { throw ProtocolError(code: .internal, message: "comments: cannot encode") }
        try DesignService.writePrivate(d, to: dir.appendingPathComponent("\(p.page.key).json"))
        chmod(dir.path, 0o700)
        pages?[p.page.key] = p
        for c in p.comments { index[c.id] = p.page.key }
    }

    private static func body(_ s: String, max: Int) throws(ProtocolError) -> String {
        let b = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty, b.count <= max else {
            throw ProtocolError(code: .invalidArgs, message: "the text must be 1-\(max) characters")
        }
        return b
    }

    /// Applies `f` to comment `id` and saves its page.
    private func edit(_ id: UUID, _ f: (inout PageComment) throws(ProtocolError) -> Void) throws(ProtocolError) -> PageComment {
        _ = all()
        guard let key = index[id], var p = pages?[key], let i = p.comments.firstIndex(where: { $0.id == id }) else {
            throw ProtocolError(code: .notFound, message: "comment \(id.uuidString.lowercased()) not found")
        }
        try f(&p.comments[i])
        try save(p)
        return p.comments[i]
    }

    func comments(_ page: PageRef) -> [PageComment] { all()[page.key]?.comments ?? [] }

    /// Every page with its title (for `comment.list`).
    func pagesList() -> [PageFile] { all().values.sorted { $0.page.key < $1.page.key } }

    func add(page: PageRef, title: String, anchor: CommentAnchor, body: String, to: UUID?, toName: String?) throws(ProtocolError) -> PageComment {
        let b = try Self.body(body, max: Self.maxUserBody)
        if let s = anchor.selector, s.count > Self.maxSelector {
            throw ProtocolError(code: .invalidArgs, message: "selector exceeds \(Self.maxSelector) characters")
        }
        var p = all()[page.key] ?? PageFile(page: page, title: "", comments: [])
        guard p.comments.count < Self.maxComments else {
            throw ProtocolError(code: .invalidArgs, message: "at most \(Self.maxComments) comments per page")
        }
        p.title = String(title.prefix(Self.maxTitle))
        let c = PageComment(id: UUID(), to: to, toName: toName, anchor: anchor,
                            messages: [CommentMessage(id: UUID(), byTerminal: nil, byName: "você", body: b, at: Date())],
                            resolved: false, delivered: [])
        p.comments.append(c)
        try save(p)
        return c
    }

    /// A user follow-up: pending again for the addressee.
    func message(_ id: UUID, body: String) throws(ProtocolError) -> PageComment {
        let b = try Self.body(body, max: Self.maxUserBody)
        return try edit(id) { c throws(ProtocolError) in
            try Self.room(c)
            c.messages.append(CommentMessage(id: UUID(), byTerminal: nil, byName: "você", body: b, at: Date()))
        }
    }

    /// Only by the addressee terminal (`unauthorized` otherwise, nothing written).
    func reply(_ id: UUID, from: UUID, name: String, body: String) throws(ProtocolError) -> PageComment {
        let b = try Self.body(body, max: Self.maxReply)
        return try edit(id) { c throws(ProtocolError) in
            guard c.to == from else { throw ProtocolError(code: .unauthorized, message: "comment \(c.short) is not addressed to you") }
            try Self.room(c)
            c.messages.append(CommentMessage(id: UUID(), byTerminal: from, byName: name, body: b, at: Date()))
        }
    }

    private static func room(_ c: PageComment) throws(ProtocolError) {
        guard c.messages.count < maxMessages else {
            throw ProtocolError(code: .invalidArgs, message: "at most \(maxMessages) messages per comment")
        }
    }

    func setResolved(_ id: UUID, _ r: Bool) throws(ProtocolError) -> PageComment { try edit(id) { $0.resolved = r } }

    /// User messages of open comments addressed to `terminal` not yet delivered, newest first.
    func pending(for terminal: UUID) -> [(page: PageRef, title: String, comment: PageComment, message: CommentMessage)] {
        var out: [(page: PageRef, title: String, comment: PageComment, message: CommentMessage)] = []
        for p in all().values {
            for c in p.comments where c.to == terminal && !c.resolved {
                for m in c.messages where m.byTerminal == nil && !c.delivered.contains(m.id) {
                    out.append((p.page, p.title, c, m))
                }
            }
        }
        return out.sorted { $0.message.at > $1.message.at }
    }

    func markDelivered(_ pairs: [(comment: UUID, message: UUID)]) throws(ProtocolError) {
        _ = all()
        var touched: Set<String> = []
        for (cid, mid) in pairs {
            guard let key = index[cid], let i = pages?[key]?.comments.firstIndex(where: { $0.id == cid }) else { continue }
            pages?[key]?.comments[i].delivered.insert(mid)
            touched.insert(key)
        }
        for k in touched { if let p = pages?[k] { try save(p) } }
    }

    /// The full id or a prefix of at least 8 hex characters: `notFound` when none matches, `invalidArgs` when several do.
    func find(_ idOrPrefix: String) throws(ProtocolError) -> (PageRef, PageComment) {
        let q = idOrPrefix.lowercased()
        guard q.count >= 8, q.count <= 36 else { throw ProtocolError(code: .invalidArgs, message: "a comment id is at least 8 characters") }
        let pages = all()
        let hits = index.keys.filter { $0.uuidString.lowercased().hasPrefix(q) }
        guard hits.count <= 1 else { throw ProtocolError(code: .invalidArgs, message: "comment id '\(idOrPrefix)' is ambiguous: give more characters") }
        guard let id = hits.first, let key = index[id], let p = pages[key], let c = p.comments.first(where: { $0.id == id }) else {
            throw ProtocolError(code: .notFound, message: "comment '\(idOrPrefix)' not found")
        }
        return (p.page, c)
    }
}
