import Foundation
import CollieProtocol

/// A user folder artifacts are kept in: up to 3 names joined by "/" ("Cliente/Landing/v2"), each 1–40 characters,
/// trimmed, no control or format characters (zero-width, bidi overrides), not "." or "..". The spelling is kept, compared
/// lowercased (the Artifacts panel's rule too). nil: "Sem pasta".
enum ArtifactFolder {
    static let maxDepth = 3, maxName = 40

    /// `s` checked and tidied; empty (or blank) is nil.
    static func normalize(_ s: String) throws(ProtocolError) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        func bad(_ m: String) -> ProtocolError { ProtocolError(code: .invalidArgs, message: "pasta inválida '\(s)': \(m)") }
        guard !t.hasPrefix("/"), !t.hasSuffix("/") else { throw bad("sem / no início ou no fim") }
        let names = t.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard names.count <= maxDepth else { throw bad("até \(maxDepth) níveis") }
        for n in names {
            guard (1...maxName).contains(n.count) else { throw bad("cada nome com 1 a \(maxName) caracteres") }
            // controlCharacters is Cc + Cf: zero-width spaces/joiners, BOM, bidi embeddings, overrides and isolates
            guard !n.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw bad("caractere de controle ou invisível") }
            guard n != ".", n != ".." else { throw bad("nome . ou .. não vale") }
        }
        return names.joined(separator: "/")
    }

    static func names(_ p: String) -> [Substring] { p.split(separator: "/") }
    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.lowercased() == b.lowercased()
    }
    /// `p` is `folder` or inside it.
    static func isUnder(_ p: String?, _ folder: String) -> Bool {
        guard let p else { return false }
        let a = names(p), f = names(folder)
        return a.count >= f.count && same(a.prefix(f.count).joined(separator: "/"), folder)
    }
    /// `p` with `from` (a folder it is in) replaced by `to`.
    static func rebase(_ p: String, from: String, to: String?) -> String? {
        let rest = names(p).dropFirst(names(from).count)
        return ((to.map { names($0) } ?? []) + rest).map(String.init).joined(separator: "/").nilIfEmpty
    }
    /// `p` spelled as the deepest `known` folder it is in.
    static func canonical(_ p: String, known: [String]) -> String {
        guard let k = known.filter({ isUnder(p, $0) }).max(by: { names($0).count < names($1).count }) else { return p }
        return rebase(p, from: k, to: k) ?? p
    }
    /// `p` and the folders it is in, outermost first.
    static func lineage(_ p: String) -> [String] {
        let n = names(p)
        return (1...n.count).map { n.prefix($0).joined(separator: "/") }
    }
}

/// One `folders.json` entry: a folder the user made or set something on. Its place in the list is its order.
/// `order`: a presentation's artifacts listed first (the rest after, by creation).
struct FolderEntry: Codable, Sendable, Equatable {
    var path: String
    var color: String? = nil
    var pinned: Bool? = nil
    var presentation: Bool? = nil
    var order: [UUID]? = nil
}

/// A folder as `artifact.folders` lists it: `count` artifacts right in it, `total` with its subfolders; `items` its own
/// artifacts in presentation order.
struct FolderInfo: Sendable, Equatable {
    var path: String, count: Int, total: Int, color: String?, pinned: Bool, presentation: Bool, items: [UUID]
}

extension String { fileprivate var nilIfEmpty: String? { isEmpty ? nil : self } }
