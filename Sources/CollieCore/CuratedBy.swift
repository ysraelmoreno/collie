import Foundation

/// How far the daemon trusts a curator's answer (spec 2026-11-17-curator-provider §2.3): `limited` turns creating into
/// proposing and activating, retiring or rewriting into a question.
public enum CuratorTrust: String, Codable, Sendable { case full, limited }

/// Who curated a record: the provider, its model (`""`: the provider's default) and the trust it ran under. Written in the
/// record's file as its readable history; a decision that trusts it must read the daemon's own copy once the provenance
/// ledger exists (spec 2026-11-17-cursor-memory-injection P1), since an agent can edit the file.
public struct CuratedBy: Codable, Sendable, Equatable {
    public var provider: String
    public var model: String
    public var trust: CuratorTrust
    public init(provider: String, model: String, trust: CuratorTrust) { self.provider = provider; self.model = model; self.trust = trust }
}
