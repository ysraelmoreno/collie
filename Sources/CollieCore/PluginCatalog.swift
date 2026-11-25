import Foundation
import CryptoKit
import CollieProtocol

/// The signed plug-in catalog, `plugins.json` + `plugins.json.sig` on the `plugins-catalog` release
/// (spec: docs/superpowers/specs/2026-11-24-plugin-marketplace-design.md, "Catálogo"). Dates are ISO 8601.
/// `accept` is the only way in: signature, `format`, `sequence` and coherence are checked together and any bad item
/// refuses the whole catalog, so the last accepted one keeps holding.
public struct PluginCatalog: Codable, Sendable, Equatable {
    public struct Version: Codable, Sendable, Equatable {
        public var version: String, url: URL, sha256: String, size: Int64, treeSha256: String
        public var permissions: [String: JSONValue]?       // same type as PluginManifest.permissions
        public var hooks: [String]?, helperTeamId: String?
        /// Overrides the item's `minCollie` for this version only (a newer version may need a newer Collie).
        public var minCollie: String?
        public var recalled: Recall?
    }
    public struct Recall: Codable, Sendable, Equatable { public var reason: String, at: Date }
    public struct Item: Codable, Sendable, Equatable {
        public var id: String, name: String, publisher: String, summary: String
        public var kind: Kind, minCollie: String, versions: [Version]
    }
    public enum Kind: String, Codable, Sendable { case panel, agent, engine }
    public struct Publisher: Codable, Sendable, Equatable { public var id: String, name: String, reviewedBy: String }
    public var format: Int, generatedAt: Date, sequence: Int
    public var plugins: [Item], publishers: [Publisher]

    /// Base64 of raw Ed25519 public keys (32 bytes). Several allowed for rotation; a new app version drops the old one.
    /// The placeholder is not valid base64, so until the real key lands no catalog is accepted.
    public static let publicKeys: [String] = [
        "PLACEHOLDER-chave-publica-do-catalogo", // o dono troca pela real (README, Ações do dono 3)
    ]
    public static let staleAfter: TimeInterval = 30 * 24 * 3600
    static let urlPrefix = "https://github.com/ysraelmoreno/collie/releases/download/plugin-"

    private static func refuse(_ why: String) -> ProtocolError {
        ProtocolError(code: .invalidArgs, message: "catálogo de plug-ins recusado: \(why)")
    }

    /// Checks the signature (any key of `keys`), the format and coherence. `lastSequence`: the last accepted one's.
    public static func accept(_ data: Data, signature: Data, keys: [String] = publicKeys,
                              lastSequence: Int?) throws(ProtocolError) -> PluginCatalog {
        let valid = keys.compactMap { Data(base64Encoded: $0).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) } }
        guard !valid.isEmpty else { throw refuse("nenhuma chave pública do catálogo configurada neste Collie") }
        guard valid.contains(where: { $0.isValidSignature(signature, for: data) }) else {
            throw refuse("a assinatura não confere")
        }
        struct Head: Decodable { var format: Int }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        guard let head = try? d.decode(Head.self, from: data) else { throw refuse("não é um JSON com \"format\"") }
        guard head.format == 1 else { throw refuse("formato \(head.format) não suportado (precisa de um Collie mais novo)") }
        let c: PluginCatalog
        do { c = try d.decode(PluginCatalog.self, from: data) } catch { throw refuse("JSON inválido (\(error))") }
        if let lastSequence, c.sequence < lastSequence {
            throw refuse("sequence \(c.sequence) é menor que a do último aceito (\(lastSequence))")
        }
        try c.validate()
        return c
    }

    private func validate() throws(ProtocolError) {
        let pubs = Set(publishers.map(\.id))
        var ids = Set<String>()
        for item in plugins {
            guard ids.insert(item.id).inserted else { throw Self.refuse("id \"\(item.id)\" repetido") }
            guard !item.versions.isEmpty else { throw Self.refuse("\(item.id) não tem versão") }
            guard pubs.contains(item.publisher) else {
                throw Self.refuse("\(item.id): publisher \"\(item.publisher)\" não está em publishers")
            }
            var seen = Set<String>()
            for v in item.versions {
                let at = "\(item.id) \(v.version)"
                guard seen.insert(v.version).inserted else { throw Self.refuse("\(at): versão repetida") }
                guard Self.isHex64(v.sha256) else { throw Self.refuse("\(at): sha256 não tem 64 hex") }
                guard Self.isHex64(v.treeSha256) else { throw Self.refuse("\(at): treeSha256 não tem 64 hex") }
                guard v.size > 0 else { throw Self.refuse("\(at): size inválido") }
                let u = v.url
                guard u.absoluteString.hasPrefix(Self.urlPrefix), u.query == nil, u.fragment == nil,
                      !u.pathComponents.contains(".."), !u.absoluteString.contains("%") else {
                    throw Self.refuse("\(at): url fora de \(Self.urlPrefix)…")
                }
            }
        }
    }

    private static func isHex64(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }   // 0-9 a-f
    }

    /// generatedAt + staleAfter < now; a generatedAt in the future (clock skew) is not stale.
    public func isStale(now: Date) -> Bool { generatedAt.addingTimeInterval(Self.staleAfter) < now }

    /// The recall of any item/version with this tree hash (matches a folder install of the same content too).
    public func recall(forTree treeSha256: String) -> Recall? {
        plugins.lazy.flatMap(\.versions).first { $0.treeSha256 == treeSha256 && $0.recalled != nil }?.recalled
    }

    /// The highest version of `id` not recalled whose minCollie (the version's, else the item's) ≤ `collie`.
    public func latest(_ id: String, collie: String) -> Version? {
        guard let item = plugins.first(where: { $0.id == id }) else { return nil }
        return item.versions
            .filter { $0.recalled == nil && Self.compare($0.minCollie ?? item.minCollie, collie) != .orderedDescending }
            .max { Self.compare($0.version, $1.version) == .orderedAscending }
    }

    /// Numeric per dotted component (`0.10.0 > 0.9.0`); missing or non-numeric components count as 0.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// For the CI (M4): signs with the raw private key (32 bytes, base64).
    public static func sign(_ data: Data, privateKey: String) throws(ProtocolError) -> Data {
        guard let raw = Data(base64Encoded: privateKey),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
            throw ProtocolError(code: .invalidArgs, message: "chave privada do catálogo inválida (32 bytes em base64)")
        }
        do { return try key.signature(for: data) } catch {
            throw ProtocolError(code: .internal, message: "não consegui assinar o catálogo: \(error)")
        }
    }
}
